import Foundation

/// A DOM inspection may finish after a redirect has already started. Only the
/// current, fully loaded document may advance the login flow.
nonisolated struct CampusLoginNavigation {
    enum Step: Equatable { case wait, timetable, sso, complete }
    private(set) var revision = 0
    private(set) var loading = false
    private(set) var completed = false
    private var requestedTimetable = false
    private var enteredSSO = false

    mutating func begin() { revision += 1; loading = true; completed = false }
    mutating func finish() -> Int { loading = false; return revision }
    mutating func invalidate() { revision += 1 }
    func isCurrent(_ token: Int) -> Bool { token == revision && !loading && !completed }
    mutating func manualQuery() { completed = false; requestedTimetable = true; begin() }

    mutating func step(route: CampusRoute, service: CampusService = .academic, url: URL, token: Int, hasTerms: Bool, hasLoginForm: Bool) -> Step {
        guard isCurrent(token), route.allows(url, service: service), !hasLoginForm else { return .wait }
        if url.host == service.host(route) {
            if hasTerms { completed = true; return .complete }
            guard service == .academic else { return .wait }
            let landingPaths: Set<String> = ["/", "/jwglxt", "/jwglxt/", "/sso/jziotlogin", "/jwglxt/ticketlogin",
                "/jwglxt/xtgl/index_initMenu.html", "/jwglxt/xtgl/index_initMenuIndex.html"]
            if !requestedTimetable && landingPaths.contains(url.path) {
                requestedTimetable = true; return .timetable
            }
        } else if route == .webVPN, url.host == "webvpn.nbt.edu.cn", !enteredSSO,
                  ["/", "/vpn_key/update", "/users/auth/cas/callback"].contains(url.path) {
            enteredSSO = true; return .sso
        }
        return .wait
    }
}

nonisolated enum CampusConnectionDiagnostics {
    static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }
    /// Never include localizedDescription/userInfo: those can contain CAS tickets,
    /// credentials or full redirect URLs. The hostname and numeric code suffice.
    static func message(_ error: Error, route: CampusRoute, url: URL?) -> String {
        let error = error as NSError
        let reason: String
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorTimedOut: reason = "连接学校登录服务超时"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: reason = "无法解析学校登录服务的域名"
            case NSURLErrorCannotConnectToHost: reason = "无法连接学校登录服务"
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: reason = "学校登录服务的网络连接不可用"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid: reason = "学校登录服务的安全连接或证书验证失败"
            default: reason = "学校登录页面加载失败"
            }
        } else { reason = "学校登录页面加载失败" }
        let domain = error.domain == NSURLErrorDomain ? "NSURLErrorDomain" : "WebKit"
        let host = url?.host ?? route.host
        let hint = route == .campus ? "请确认校园网已认证，并允许 App 的本地网络访问；也可切换 WebVPN 后重试。" : "请检查网络后重试。"
        return "\(reason)（\(route.title) · \(host) · \(domain) \(error.code)）。\(hint)"
    }
}
