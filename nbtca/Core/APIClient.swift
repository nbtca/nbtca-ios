import Foundation

@MainActor
final class APIClient {
    static let shared = APIClient()
    static let saturday = "https://api.nbtca.space/v2"
    private let settings = AppSettings.shared
    private let transport: URLSession
    private let baseURLOverride: String?
    private let tokenProvider: (() async throws -> String)?
    init(transport: URLSession = .shared, baseURL: String? = nil, tokenProvider: (() async throws -> String)? = nil) {
        self.transport = transport; self.baseURLOverride = baseURL; self.tokenProvider = tokenProvider
    }
    private let auth = AuthStore.shared
    private func accessToken() async throws -> String {
        if let tokenProvider { return try await tokenProvider() }
        return try await auth.validToken()
    }
    static func send(_ request: URLRequest, using transport: URLSession = .shared, upload: Data? = nil, delegate: URLSessionTaskDelegate? = nil) async throws -> Any {
        var request = request; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let data: Data, response: URLResponse
            if let upload { (data, response) = try await transport.upload(for: request, from: upload, delegate: delegate) }
            else { (data, response) = try await transport.data(for: request) }
            guard let response = response as? HTTPURLResponse else { throw APIError(message: "服务器返回无效响应") }
            let json = (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()
            guard (200..<300).contains(response.statusCode) else {
                let body = json as? JSONObject ?? [:]
                let detail = ["detail", "message", "error_description", "title", "error"].map { body.string($0) }.first { !$0.isEmpty }
                throw APIError(message: detail ?? (response.statusCode == 401 || response.statusCode == 403 ? "登录凭证无效或无权限，请重新登录后重试" : "请求失败（\(response.statusCode)）"), status: response.statusCode)
            }
            return json
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw APIError(message: error.code == .appTransportSecurityRequiresSecureConnection ? "此地址不允许明文连接，请使用 HTTPS 后端" : "无法连接服务器，请检查网络和后端地址后重试")
        }
    }
    static func unwrap(_ value: Any) throws -> Any {
        guard let body = value as? JSONObject, let code = body["code"] as? Int else { return value }
        guard code == 0 else { throw APIError(message: body.string("message", default: "服务返回错误")) }
        return body["data"] ?? NSNull()
    }
    func request(_ path: String, method: String = "GET", body: JSONObject? = nil, saturday: Bool = false,
                 authorized: Bool = false, query: [URLQueryItem] = []) async throws -> Any {
        let base = saturday ? Self.saturday : (baseURLOverride ?? settings.baseURL)
        guard !base.isEmpty, var url = URLComponents(string: base + path), url.host != nil else { throw APIError(message: "请在个人中心配置后端服务器地址") }
        if !query.isEmpty { url.queryItems = query }
        guard let target = url.url else { throw APIError(message: "API 地址无效") }
        var request = URLRequest(url: target); request.httpMethod = method
        if authorized { request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let result = try await Self.send(request, using: transport)
        return try saturday ? result : Self.unwrap(result)
    }
    func object(_ path: String, method: String = "GET", body: JSONObject? = nil, saturday: Bool = false, authorized: Bool = false) async throws -> JSONObject {
        let data = try await request(path, method: method, body: body, saturday: saturday, authorized: authorized)
        guard let object = data as? JSONObject else { throw APIError(message: "服务器返回的数据格式不正确") }
        return object
    }
    static func segment(_ string: String) -> String { string.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    func feed() async throws -> NewsFeed { NewsFeed(try await object("/newsroom/feed")) }
    func article(_ id: String) async throws -> NewsArticle { NewsArticle(try await object("/newsroom/articles/" + Self.segment(id))) }
    func calendar() async throws -> AssociationCalendar { AssociationCalendar(try await object("/tools/association-calendar")) }
    func status() async throws -> ServiceStatus { ServiceStatus(try await object("/tools/infrastructure")) }
    func diagnose(model: String, problem: String) async throws -> Diagnosis {
        Diagnosis(try await object("/repair/diagnose", method: "POST", body: ["device_type": model, "description": problem]))
    }
    func tickets(queue: Bool = false, offset: Int = 0) async throws -> [RepairTicket] {
        guard auth.isLoggedIn else { return [] }
        guard !queue || auth.isStaff else { throw APIError(message: "无权访问维修队列", status: 403) }
        let path = queue ? "/events" : auth.isStaff ? "/member/events" : "/client/events"
        let data = try await request(path, saturday: true, authorized: !queue, query: [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "offset", value: "\(offset)"), URLQueryItem(name: "order", value: "DESC")])
        guard let array = data as? [JSONObject] else { throw APIError(message: "工单列表数据无效") }
        return array.map { RepairTicket($0) }
    }
    func detail(_ id: String) async throws -> RepairTicket {
        let prefix = auth.isStaff ? "/member/events/" : "/client/events/"
        do { return RepairTicket(try await object(prefix + Self.segment(id), saturday: true, authorized: true)) }
        catch let error as APIError where error.status == 403 || error.status == 404 {
            guard auth.isStaff else { throw error }
            return RepairTicket(try await object("/events/" + Self.segment(id), saturday: true))
        }
    }
    func create(_ body: JSONObject) async throws -> RepairTicket {
        RepairTicket(try await object("/client/event", method: "POST", body: body, saturday: true, authorized: true))
    }
    func update(_ id: String, body: JSONObject) async throws -> RepairTicket {
        RepairTicket(try await object("/client/events/" + Self.segment(id), method: "PATCH", body: body, saturday: true, authorized: true))
    }
    func cancel(_ id: String) async throws {
        _ = try await request("/client/events/" + Self.segment(id), method: "DELETE", saturday: true, authorized: true)
    }
    func action(_ id: String, action: String, method: String = "POST", body: JSONObject? = nil) async throws -> RepairTicket {
        let adminAction = action == "close" || (action == "commit" && method == "DELETE")
        let path = (adminAction ? "/events/" : "/member/events/") + Self.segment(id) + "/" + action
        return RepairTicket(try await object(path, method: method, body: body, saturday: true, authorized: true))
    }
    func upload(_ id: String, photos: [Data], progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> RepairTicket {
        let boundary = "NBTCA-" + UUID().uuidString
        var request = URLRequest(url: URL(string: Self.saturday + "/member/events/" + Self.segment(id) + "/photos")!)
        request.httpMethod = "POST"; request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        for (index, photo) in photos.enumerated() {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"photos\"; filename=\"photo-\(index).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
            body.append(photo); body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        guard let json = try await Self.send(request, using: transport, upload: body, delegate: PhotoUploadProgress(update: progress)) as? JSONObject else { throw APIError(message: "上传照片后服务器返回无效数据") }
        return RepairTicket(json)
    }
}
