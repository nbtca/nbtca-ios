import Foundation
import CoreFoundation

nonisolated final class CampusRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let route: CampusRoute
    private let service: CampusService
    private let followRedirects: Bool
    init(route: CampusRoute, service: CampusService = .academic, followRedirects: Bool = true) { self.route = route; self.service = service; self.followRedirects = followRedirects }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(followRedirects && request.url.map { route.allows($0, service: service) } == true ? request : nil)
    }
}

@MainActor
final class CampusClient {
    static let periodPath = "/jwglxt/kbcx/xskbcx_cxRjc.html"
    let route: CampusRoute
    let service: CampusService
    private let transport: URLSession
    private let cookieStorage: HTTPCookieStorage?
    private let calendarProvider: ((AcademicTerm) async -> String?)?
    private let browserTransport: ((URLRequest) async throws -> (Data, HTTPURLResponse))?
    init(route: CampusRoute, service: CampusService = .academic, transport: URLSession? = nil,
         sharedCookies: HTTPCookieStorage? = nil, calendarProvider: ((AcademicTerm) async -> String?)? = nil, browserTransport: ((URLRequest) async throws -> (Data, HTTPURLResponse))? = nil) {
        self.route = route; self.service = service; self.browserTransport = browserTransport; self.calendarProvider = calendarProvider
        if let transport { self.transport = transport; cookieStorage = nil }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 40
            if let sharedCookies { configuration.httpCookieStorage = sharedCookies }
            configuration.httpCookieAcceptPolicy = .always
            configuration.allowsCellularAccess = route == .webVPN
            cookieStorage = configuration.httpCookieStorage
            self.transport = URLSession(configuration: configuration, delegate: CampusRedirectDelegate(route: route, service: service), delegateQueue: nil)
        }
    }
    func importCookies(_ cookies: [HTTPCookie]) {
        for cookie in cookies where route.acceptsCookie(cookie, service: service) {
            cookieStorage?.setCookie(cookie)
        }
    }
    var cookies: [HTTPCookie] { (cookieStorage?.cookies ?? []).filter { route.acceptsCookie($0, service: service) } }
    func mergeCookies(_ cookies: [HTTPCookie]) {
        for cookie in cookies where route.acceptsCookie(cookie, service: service) { cookieStorage?.setCookie(cookie) }
    }
    func clear() {
        for cookie in cookieStorage?.cookies ?? [] { cookieStorage?.deleteCookie(cookie) }
        transport.invalidateAndCancel()
    }
    static func form(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
    func url(for kind: AcademicKind, query: Bool) -> URL {
        var components = URLComponents(string: route.origin + (query ? kind.queryPath : kind.indexPath))!
        components.queryItems = [URLQueryItem(name: "gnmkdm", value: kind.code)]
        if query && kind != .timetable { components.queryItems?.append(URLQueryItem(name: "doType", value: "query")) }
        if !query && kind == .timetable { components.queryItems?.append(URLQueryItem(name: "layout", value: "default")) }
        return components.url!
    }
    func response(_ url: URL, fields: [String: String]? = nil, referer: URL? = nil) async throws -> Data {
        guard route.allows(url, service: service) else { throw AcademicError.unsafeURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let fields {
            request.httpMethod = "POST"; request.httpBody = Self.form(fields)
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
            request.setValue(service.origin(route), forHTTPHeaderField: "Origin")
        }
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        do {
            let data: Data, rawResponse: URLResponse
            if let browserTransport { (data, rawResponse) = try await browserTransport(request) }
            else { (data, rawResponse) = try await transport.data(for: request) }
            try Task.checkCancellation()
            guard let response = rawResponse as? HTTPURLResponse, let finalURL = response.url, route.allows(finalURL, service: service) else { throw AcademicError.unsafeURL }
            if [401, 403].contains(response.statusCode) || (300..<400).contains(response.statusCode) { throw AcademicError.sessionExpired }
            guard (200..<300).contains(response.statusCode) else { throw AcademicError.http(response.statusCode) }
            guard data.count <= 4 * 1024 * 1024 else { throw AcademicError.invalidData }
            let body = String(data: data, encoding: .utf8) ?? ""
            guard finalURL.host == service.host(route), !finalURL.path.contains("login"), !AcademicParser.isLoginHTML(body) else { throw AcademicError.sessionExpired }
            if service == .dormitory {
                let prefix = body.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))).lowercased()
                if prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") || prefix.hasPrefix("<a ") {
                    throw route == .webVPN && (prefix.contains("webvpn") || prefix.contains("vpn_key")) ? DormitoryResponseError.webVPNPage : DormitoryResponseError.htmlPage
                }
            }
            return data
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw AcademicError.network(CampusConnectionDiagnostics.message(error, route: route, url: url))
        }
    }
    private func json(_ data: Data) throws -> Any {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else { throw AcademicError.invalidData }
        return parsed
    }
    func terms() async throws -> [AcademicTerm] {
        let data = try await response(url(for: .timetable, query: false))
        guard let html = String(data: data, encoding: .utf8) else { throw AcademicError.invalidData }
        return try AcademicParser.terms(html)
    }
    func timetable(_ term: AcademicTerm) async throws -> AcademicTimetable {
        let fields = ["xnm": term.year, "xqm": term.semester]
        let index = url(for: .timetable, query: false)
        let data = try await response(url(for: .timetable, query: true), fields: fields, referer: index)
        guard let object = try json(data) as? AcademicParser.Object else { throw AcademicError.invalidData }
        var result = try AcademicParser.timetable(object, term: term)
        do {
            let data = try await response(URL(string: route.origin + Self.periodPath)!, fields: fields, referer: index)
            let remote = AcademicParser.periods(try json(data))
            var periods = Dictionary(result.periods.map { ($0.number, $0) }, uniquingKeysWith: { _, next in next })
            remote.forEach { periods[$0.number] = $0 }; result.periods = periods.values.sorted { $0.number < $1.number }
        } catch AcademicError.sessionExpired { throw AcademicError.sessionExpired }
        catch is CancellationError { throw CancellationError() }
        catch { /* Section numbers remain useful when the optional bell schedule is unavailable. */ }
        if let calendarProvider, let monday = await calendarProvider(term), result.acceptsWeekOne(monday) { result.weekOneMonday = monday }
        try Task.checkCancellation()
        return result
    }
    func records(_ kind: AcademicKind, term: AcademicTerm) async throws -> [AcademicParser.Object] {
        guard kind != .timetable else { throw AcademicError.invalidData }
        var rows: [AcademicParser.Object] = [], pages = 1, total: Int?
        var page = 1
        repeat {
            try Task.checkCancellation()
            let data = try await response(url(for: kind, query: true), fields: ["xnm": term.year, "xqm": term.semester,
                "queryModel.showCount": "50", "queryModel.currentPage": "\(page)",
                "queryModel.sortName": kind == .exams ? "kssj" : "kch", "queryModel.sortOrder": "asc"], referer: url(for: kind, query: false))
            guard let object = try json(data) as? AcademicParser.Object,
                  object["success"] as? Bool != false, object["type"] as? String != "error",
                  let items = object["items"] as? [AcademicParser.Object],
                  let pageCount = integer(object["totalPage"]), let resultCount = integer(object["totalResult"]),
                  let current = integer(object["currentPage"]), current == page,
                  (0...100).contains(pageCount), (0...5000).contains(resultCount),
                  resultCount == 0 || pageCount > 0, resultCount > 0 || pageCount <= 1,
                  page == 1 || (pages == pageCount && total == resultCount) else { throw AcademicError.incompletePages }
            for row in items {
                guard AcademicParser.text(row, "xnm") == term.year, AcademicParser.text(row, "xqm") == term.semester else { throw AcademicError.termMismatch }
            }
            pages = pageCount; total = resultCount; rows += items
            guard rows.count <= resultCount, page >= pages || !items.isEmpty else { throw AcademicError.incompletePages }
            page += 1
        } while page <= pages
        guard rows.count == total else { throw AcademicError.incompletePages }
        return rows
    }
    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue, abs(number.doubleValue) <= 1_000_000 else { return nil }
        return number.intValue
    }
}
