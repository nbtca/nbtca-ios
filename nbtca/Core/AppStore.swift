import SwiftUI
import Security
import CryptoKit

@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    // Keep in sync with the Android release workflow's NBTCA_API_BASE_URL.
    static let defaultBaseURL = "https://bff.nbtca.space/api/v1"
    var theme: String { didSet { UserDefaults.standard.set(theme, forKey: "settings.theme") } }
    var baseURL: String { didSet { UserDefaults.standard.set(baseURL, forKey: "settings.apiBaseURL") } }
    var colorScheme: ColorScheme? { theme == "light" ? .light : theme == "dark" ? .dark : nil }
    private init() {
        theme = UserDefaults.standard.string(forKey: "settings.theme") ?? "system"
        baseURL = UserDefaults.standard.string(forKey: "settings.apiBaseURL") ?? (Bundle.main.object(forInfoDictionaryKey: "NBTCAAPIBaseURL") as? String) ?? Self.defaultBaseURL
    }
    static func normalizeURL(_ value: String) throws -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw APIError(message: "请输入后端 API 地址") }
        if !value.contains("://") { value = "https://" + value }
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme),
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw APIError(message: "请输入完整的 HTTP 或 HTTPS API 地址") }
        #if !DEBUG
        guard url.scheme == "https" else { throw APIError(message: "正式版请使用 HTTPS 后端地址") }
        #endif
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

struct StoredSession: Codable {
    var accessToken: String
    var refreshToken: String?
    var expires: Date
    var profile: UserProfile
}

enum SessionKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "space.nbtca.ios",
         kSecAttrAccount as String: "logto.session"]
    }
    static func read() throws -> StoredSession? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw APIError(message: "无法读取安全登录存储（\(status)）") }
        return try JSONDecoder().decode(StoredSession.self, from: data)
    }
    static func save(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)
        let values = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as [String: Any]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; values.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw APIError(message: "无法保存登录凭证（\(added)）") }
        } else if status != errSecSuccess { throw APIError(message: "无法更新登录凭证（\(status)）") }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

enum Logto {
    static let endpoint = "https://auth.app.nbtca.space"
    static let clientID = "a3tt7oyxeounfiqqugiah"
    static let redirectURI = "https://nbtca.space/callback"
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw APIError(message: "无法生成安全登录参数，请重试") }
        return base64URL(Data(bytes))
    }
    static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func authorizeURL(verifier: String, state: String) -> URL {
        var parts = URLComponents(string: endpoint + "/oidc/auth")!
        parts.queryItems = ["client_id": clientID, "redirect_uri": redirectURI, "response_type": "code",
                            "scope": "openid profile email offline_access roles custom_data",
                            "code_challenge": base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))),
                            "code_challenge_method": "S256", "state": state].map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }
    static func token(_ fields: [String: String]) async throws -> JSONObject {
        var fields = fields; fields["client_id"] = clientID
        var body = URLComponents(); body.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: URL(string: endpoint + "/oidc/token")!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        return try await APIClient.send(request) as? JSONObject ?? [:]
    }
}

@MainActor @Observable
final class AuthStore {
    static let shared = AuthStore()
    private(set) var session: StoredSession?
    private(set) var busy = false
    var viewRole = "auto"
    var notice: String?
    private var revision = 0
    private var refreshTask: Task<String, Error>?
    var user: UserProfile? { session?.profile }
    var isLoggedIn: Bool { session != nil }
    var role: String {
        guard let user else { return "client" }
        if viewRole == "client" { return "client" }
        if viewRole == "member", user.isStaff { return "member" }
        return user.isAdmin ? "admin" : user.isStaff ? "member" : "client"
    }
    var isStaff: Bool { isLoggedIn && role != "client" }
    var isAdmin: Bool { isLoggedIn && role == "admin" }
    var roleName: String { role == "admin" ? "维修管理员" : role == "member" ? "维修技术员" : "报修用户" }
    private init() {
        do { session = try SessionKeychain.read() }
        catch { notice = error.localizedDescription }
    }
    func restore() async {
        guard session != nil else { return }
        let currentRevision = revision
        do {
            let token = try await validToken()
            let profile = try await fetchProfile(token)
            guard currentRevision == revision, var updated = session else { return }
            updated.profile = profile; try SessionKeychain.save(updated); session = updated
        } catch let error as APIError where error.status == 401 || error.status == 403 {
            if currentRevision == revision { logout(); notice = "登录已过期，请重新登录" }
        } catch { /* 网络不可用时保留已存储身份，下次请求仍校验凭证。 */ }
    }
    private func fetchProfile(_ token: String) async throws -> UserProfile {
        var infoRequest = URLRequest(url: URL(string: Logto.endpoint + "/oidc/me")!)
        infoRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let info = try await APIClient.send(infoRequest) as? JSONObject ?? [:]
        var memberRequest = URLRequest(url: URL(string: APIClient.saturday + "/member")!)
        memberRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let member = (try? await APIClient.send(memberRequest)) as? JSONObject ?? [:]
        return try UserProfile(info: info, member: member)
    }
    func login(code: String, verifier: String) async throws {
        revision += 1; let currentRevision = revision
        busy = true; defer { if currentRevision == revision { busy = false } }
        let tokens = try await Logto.token(["grant_type": "authorization_code", "code": code, "code_verifier": verifier, "redirect_uri": Logto.redirectURI])
        let token = tokens.string("access_token")
        guard !token.isEmpty else { throw APIError(message: "登录服务未返回访问凭证") }
        let profile = try await fetchProfile(token)
        guard currentRevision == revision else { throw CancellationError() }
        let newSession = StoredSession(accessToken: token, refreshToken: tokens["refresh_token"] as? String,
                                       expires: Date().addingTimeInterval(tokens["expires_in"] as? Double ?? 3600), profile: profile)
        try SessionKeychain.save(newSession); session = newSession; viewRole = "auto"; notice = nil
    }
    func validToken() async throws -> String {
        guard let session else { throw APIError(message: "请先登录 NBTCA 账号", status: 401) }
        if session.expires.timeIntervalSinceNow > 60 { return session.accessToken }
        if let refreshTask { return try await refreshTask.value }
        guard let refresh = session.refreshToken else { logout(); throw APIError(message: "登录已过期，请重新登录", status: 401) }
        let currentRevision = revision
        let task = Task<String, Error> { @MainActor in
            do {
                let tokens = try await Logto.token(["grant_type": "refresh_token", "refresh_token": refresh])
                guard currentRevision == self.revision else { throw CancellationError() }
                let token = tokens.string("access_token")
                guard !token.isEmpty else { throw APIError(message: "刷新登录凭证失败") }
                let updated = StoredSession(accessToken: token, refreshToken: tokens["refresh_token"] as? String ?? refresh,
                                            expires: Date().addingTimeInterval(tokens["expires_in"] as? Double ?? 3600), profile: session.profile)
                try SessionKeychain.save(updated); self.session = updated
                return token
            } catch let error as APIError where error.status == 400 || error.status == 401 {
                if currentRevision == self.revision { self.logout() }
                throw error
            }
        }
        refreshTask = task
        defer { if currentRevision == revision { refreshTask = nil } }
        return try await task.value
    }
    func logout() {
        revision += 1; refreshTask?.cancel(); refreshTask = nil
        session = nil; viewRole = "auto"; busy = false; SessionKeychain.clear()
        do { try FormDraftStore.shared.clear() }
        catch { notice = "维修草稿未能清除：" + error.localizedDescription }
    }
}
