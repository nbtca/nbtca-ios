import Foundation
import Security

nonisolated enum CampusSessionStorageError: LocalizedError {
    case invalidData, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidData: "保存的学校登录状态已损坏，请重新登录"
        case .keychain(let status): "无法访问学校安全登录存储（\(status)），本次登录仍可使用"
        }
    }
}

/// Keeps the original cookie expiry, including session-only cookies. Persisting
/// a browser session never extends the university's server-side session lifetime.
nonisolated struct CampusSessionArchive: Codable {
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    private let route: CampusRoute.RawValue
    private let service: CampusService?
    private let savedAt: Date
    private let cookies: [Cookie]

    private struct Cookie: Codable {
        let name, value, domain, path: String
        let expires: Date?
        let secure, httpOnly, sessionOnly: Bool
        let sameSite: String?
        let version: Int
        init(_ cookie: HTTPCookie) {
            name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
            expires = cookie.expiresDate; secure = cookie.isSecure; httpOnly = cookie.isHTTPOnly
            sessionOnly = cookie.isSessionOnly; version = cookie.version
            sameSite = cookie.sameSitePolicy?.rawValue
        }
        var cookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path, .version: String(version)]
            if let expires { properties[.expires] = expires }
            if secure { properties[.secure] = "TRUE" }
            if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if sessionOnly { properties[.discard] = "TRUE" }
            if let sameSite { properties[.sameSitePolicy] = sameSite }
            return HTTPCookie(properties: properties)
        }
    }
    init(cookies: [HTTPCookie], route: CampusRoute, service: CampusService = .academic, now: Date = Date()) {
        self.route = route.rawValue; self.service = service; savedAt = now
        self.cookies = cookies.filter { route.acceptsCookie($0, service: service) && ($0.expiresDate.map { $0 > now } ?? true) }.map(Cookie.init)
    }
    func restored(for route: CampusRoute, service: CampusService = .academic, now: Date = Date()) -> [HTTPCookie] {
        guard self.route == route.rawValue, (self.service ?? .academic) == service, savedAt <= now, now.timeIntervalSince(savedAt) < Self.maximumAge else { return [] }
        return cookies.compactMap(\.cookie).filter { route.acceptsCookie($0, service: service) && ($0.expiresDate.map { $0 > now } ?? true) }
    }
}

/// Separate accounts in the device-only Keychain; never UserDefaults, files or iCloud.
nonisolated enum CampusSessionStorage {
    private static func query(_ route: CampusRoute, _ service: CampusService) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "space.nbtca.ios",
         kSecAttrAccount as String: service.rawValue + ".session." + route.rawValue]
    }
    static func read(_ route: CampusRoute, service: CampusService = .academic) throws -> [HTTPCookie] {
        var query = query(route, service); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw CampusSessionStorageError.keychain(status) }
        guard let data = result as? Data, data.count <= 512 * 1024,
              let archive = try? JSONDecoder().decode(CampusSessionArchive.self, from: data) else {
            clear(route, service: service); throw CampusSessionStorageError.invalidData
        }
        let cookies = archive.restored(for: route, service: service)
        if cookies.isEmpty { clear(route, service: service) }
        return cookies
    }
    static func save(_ cookies: [HTTPCookie], route: CampusRoute, service: CampusService = .academic) throws {
        let archive = CampusSessionArchive(cookies: cookies, route: route, service: service)
        guard !archive.restored(for: route, service: service).isEmpty else { clear(route, service: service); return }
        let data = try JSONEncoder().encode(archive)
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(route, service) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(route, service); values.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw CampusSessionStorageError.keychain(added) }
        } else if status != errSecSuccess { throw CampusSessionStorageError.keychain(status) }
    }
    static func clear(_ route: CampusRoute, service: CampusService = .academic) { SecItemDelete(query(route, service) as CFDictionary) }
}
