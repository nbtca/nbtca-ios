import Foundation
import Observation
import WebKit

/// One browser and HTTP cookie jar per network route. Service cookies retain
/// their original domain and path; CAS / WebVPN cookies are shared both ways.
@MainActor @Observable
final class CampusSchoolSession {
    static let shared = CampusSchoolSession()
    private(set) var revision = 0
    @ObservationIgnored private let academicStores = NSHashTable<AcademicStore>.weakObjects()
    @ObservationIgnored private let dormitoryStores = NSHashTable<DormitoryStore>.weakObjects()
    func register(_ store: AcademicStore) { academicStores.add(store) }
    func register(_ store: DormitoryStore) { dormitoryStores.add(store) }
    @ObservationIgnored private var contexts: [CampusRoute: Context] = [:]
    @MainActor final class Context {
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let cookies = URLSessionConfiguration.ephemeral.httpCookieStorage!
        var storageNotice: String?
        init(route: CampusRoute) {
            for service in [CampusService.academic, .dormitory] {
                do { try CampusSessionStorage.read(route, service: service).forEach { cookies.setCookie($0) } }
                catch { storageNotice = error.localizedDescription }
            }
        }
    }
    func context(for route: CampusRoute) -> Context {
        if let existing = contexts[route] { return existing }
        let context = Context(route: route); contexts[route] = context; return context
    }
    func hasCredentials(for route: CampusRoute) -> Bool {
        !(context(for: route).cookies.cookies ?? []).isEmpty
    }
    func didLogin() {
        // An interactive login may select another school account. Silent CAS
        // restoration preserves the cache; a new login replaces it after fetch.
        try? TimetableCache.shared.clear()
        for store in academicStores.allObjects { store.schoolIdentityChanged() }
        for store in dormitoryStores.allObjects { store.schoolIdentityChanged() }
        revision += 1
    }
    func logout() async {
        let old = Array(contexts.values); contexts.removeAll()
        // Logout can originate from a dormitory-only window with no academic
        // page alive. The shared offline timetable must still be removed.
        try? TimetableCache.shared.clear()
        for store in academicStores.allObjects { store.resetSession() }
        for store in dormitoryStores.allObjects { store.resetSession() }
        for route in CampusRoute.allCases {
            for service in [CampusService.academic, .dormitory] { CampusSessionStorage.clear(route, service: service) }
        }
        for context in old {
            for cookie in context.cookies.cookies ?? [] { context.cookies.deleteCookie(cookie) }
            await context.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
        revision += 1
    }
}

@MainActor
final class CampusWebSession {
    let route: CampusRoute
    let service: CampusService
    private let context: CampusSchoolSession.Context
    var websiteDataStore: WKWebsiteDataStore { context.websiteDataStore }
    lazy var browser = CampusSessionBrowser(route: route, service: service, websiteDataStore: websiteDataStore)
    lazy var client: CampusClient = {
        var transport: ((URLRequest) async throws -> (Data, HTTPURLResponse))?
        if service == .dormitory {
            transport = { [weak self] request in
                guard let self else { throw CancellationError() }
                return try await self.browser.response(request)
            }
        }
        let provider: ((AcademicTerm) async -> String?)? = { await AcademicCalendarFeed.shared.weekOne(for: $0) }
        return CampusClient(route: route, service: service, sharedCookies: context.cookies,
            calendarProvider: provider, browserTransport: transport)
    }()
    var storageNotice: String? { context.storageNotice }
    var hasCredentials: Bool { CampusSchoolSession.shared.hasCredentials(for: route) }
    init(route: CampusRoute, service: CampusService = .academic) {
        self.route = route; self.service = service
        context = CampusSchoolSession.shared.context(for: route)
    }
    func prepareLogin() async {
        await captureBrowserCookies()
        for cookie in context.cookies.cookies ?? [] { await websiteDataStore.httpCookieStore.setCookie(cookie) }
    }
    func captureBrowserCookies() async {
        let cookies = await websiteDataStore.httpCookieStore.allCookies()
        for cookie in cookies where route.acceptsCookie(cookie) || route.acceptsCookie(cookie, service: .dormitory) {
            context.cookies.setCookie(cookie)
        }
    }
    func query<T>(_ operation: (CampusClient) async throws -> T) async throws -> T {
        let result: T
        do { result = try await operation(client) }
        catch AcademicError.sessionExpired {
            browser.invalidate()
            try await restoreSession()
            result = try await operation(client)
        }
        try Task.checkCancellation()
        if service == .academic {
            // Preserve any service-cookie rotation from URLSession before the
            // next WebKit -> HTTP synchronization.
            for cookie in client.cookies { await websiteDataStore.httpCookieStore.setCookie(cookie) }
        }
        await captureBrowserCookies()
        return result
    }
    func restoreSession() async throws {
        await prepareLogin()
        try await browser.prepare()
        await captureBrowserCookies()
    }
    func persist() {
        do {
            let cookies = context.cookies.cookies ?? []
            for service in [CampusService.academic, .dormitory] {
                try CampusSessionStorage.save(cookies, route: route, service: service)
            }
            context.storageNotice = nil
        } catch { context.storageNotice = error.localizedDescription }
    }
    // A service session may expire while the CAS ticket still works for the
    // other service. Only explicit logout clears the shared school identity.
    func expire() { browser.invalidate() }
    func stop() { browser.invalidate(); client.clear() }
}

/// Establish each application's own CAS service session without showing another
/// login screen. Dormitory API calls stay in this authenticated browser context.
@MainActor
final class CampusSessionBrowser: NSObject, WKNavigationDelegate {
    private let route: CampusRoute
    private let service: CampusService
    private let websiteDataStore: WKWebsiteDataStore
    private var retainedView: WKWebView?
    private var webView: WKWebView {
        if let retainedView { return retainedView }
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = websiteDataStore
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        view.navigationDelegate = self; retainedView = view; return view
    }
    private var flow = CampusLoginNavigation()
    private var continuation: CheckedContinuation<Void, Error>?
    private var preparation: Task<Void, Error>?
    private var inspection: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var ready = false
    private var activeNavigation: WKNavigation?
    init(route: CampusRoute, service: CampusService, websiteDataStore: WKWebsiteDataStore) {
        self.route = route; self.service = service
        self.websiteDataStore = websiteDataStore
        super.init()
    }
    func invalidate() {
        ready = false; preparation?.cancel(); preparation = nil
        finish(.failure(CancellationError())); retainedView?.stopLoading()
    }
    func adoptAuthenticatedPage(_ view: WKWebView) {
        guard let url = view.url, url.host == service.host(route), route.allows(url, service: service) else { return }
        // Keep the actual page that completed login, including its SPA state.
        // The sheet coordinator retains navigation ownership until dismissal.
        retainedView = view; ready = true
    }
    func prepare() async throws {
        if ready, webView.url?.host == service.host(route) { return }
        if let preparation { return try await preparation.value }
        let task = Task { @MainActor in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                self.timeout = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(35)) } catch { return }
                    self.finish(.failure(AcademicError.network(CampusConnectionDiagnostics.message(URLError(.timedOut), route: self.route, url: self.webView.url))))
                    self.webView.stopLoading()
                }
                self.flow = CampusLoginNavigation()
                self.load(self.service.entryURL(self.route))
            }
        }
        preparation = task
        defer { preparation = nil }
        try await task.value
    }
    private func load(_ url: URL) { webView.navigationDelegate = self; flow.begin(); activeNavigation = webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)) }
    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel(); inspection?.cancel()
        let pending = continuation; continuation = nil
        if case .success = result { ready = true }
        else { ready = false }
        pending?.resume(with: result)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        guard url.absoluteString == "about:blank" || route.allows(url, service: service) else {
            decisionHandler(.cancel)
            if action.targetFrame?.isMainFrame != false { finish(.failure(AcademicError.unsafeURL)) }
            return
        }
        if action.targetFrame == nil { decisionHandler(.cancel); load(url); return }
        if action.targetFrame?.isMainFrame == true { flow.begin() }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { activeNavigation = navigation; flow.begin() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard continuation != nil, navigation === activeNavigation, let url = webView.url else { return }
        inspect(url: url, token: flow.finish())
    }
    private func inspect(url: URL, token: Int) {
        let selector = service == .academic ? "select#xnm,select[name=\"xnm\"]" : "#sswsxs_grid,#grwsxs_grid"
        let rendered = service == .academic ? "true" : "Boolean(document.querySelector('\(selector)')?.childElementCount)"
        let script = """
        ({ready:Boolean(document.querySelector('\(selector)') && \(rendered)),
          login:Boolean(document.querySelector('input[type="password"],form#pwdFromId,form#loginFromId'))})
        """
        webView.evaluateJavaScript(script) { [weak self] value, error in
            guard let self, self.continuation != nil, self.flow.isCurrent(token), self.webView.url == url else { return }
            guard error == nil, let flags = value as? [String: Bool] else { self.finish(.failure(AcademicError.invalidData)); return }
            if flags["login"] == true { self.finish(.failure(AcademicError.sessionExpired)); return }
            switch self.flow.step(route: self.route, service: self.service, url: url, token: token, hasTerms: flags["ready"] == true, hasLoginForm: false) {
            case .complete: self.finish(.success(()))
            case .timetable:
                self.load(URL(string: self.route.origin + AcademicKind.timetable.indexPath + "?gnmkdm=N2151&layout=default")!)
            case .sso: self.load(self.service.entryURL(self.route))
            case .wait:
                self.inspection = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    guard let self else { return }; self.inspect(url: url, token: token)
                }
            }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if navigation === activeNavigation { failed(error) } }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if navigation === activeNavigation { failed(error) } }
    private func failed(_ error: Error) {
        guard !CampusConnectionDiagnostics.isCancellation(error), continuation != nil else { return }
        finish(.failure(AcademicError.network(CampusConnectionDiagnostics.message(error, route: route, url: webView.url))))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        if continuation != nil {
            finish(.failure(AcademicError.network(CampusConnectionDiagnostics.message(URLError(.networkConnectionLost), route: route, url: webView.url))))
        }
    }
    func response(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await prepare()
        guard let url = request.url, route.allows(url, service: service), url.host == service.host(route),
              webView.url?.host == service.host(route) else { throw AcademicError.unsafeURL }
        // Browser-generated Origin/Referer and cookies match the official SPA.
        let script = """
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 20000);
        try {
            const response = await fetch(path, {method:'POST', credentials:'same-origin', cache:'no-store', redirect:'manual',
                headers:{'Content-Type':'application/x-www-form-urlencoded; charset=UTF-8', 'X-Requested-With':'XMLHttpRequest'},
                body:body, signal:controller.signal});
            const text = await response.text();
            if (text.length > 4194304) throw new Error('Response too large');
            return {status:response.status, url:response.url, text:text};
        } finally { clearTimeout(timer); }
        """
        let value: Any
        do {
            guard let result = try await webView.callAsyncJavaScript(script, arguments: ["path": url.path, "body": String(decoding: request.httpBody ?? Data(), as: UTF8.self)], in: nil, contentWorld: .page) else { throw AcademicError.invalidData }
            value = result
        } catch {
            if (error as? WKError)?.code == .webContentProcessTerminated {
                ready = false; throw AcademicError.sessionExpired
            }
            throw AcademicError.network(CampusConnectionDiagnostics.message(URLError(.cannotLoadFromNetwork), route: route, url: url))
        }
        try Task.checkCancellation()
        guard let result = value as? [String: Any], let status = result["status"] as? Int else { throw AcademicError.invalidData }
        guard status != 0 else { ready = false; throw AcademicError.sessionExpired }
        guard let source = result["url"] as? String, let finalURL = URL(string: source), route.allows(finalURL, service: service),
              let text = result["text"] as? String,
              let response = HTTPURLResponse(url: finalURL, statusCode: status, httpVersion: nil, headerFields: nil) else { throw AcademicError.invalidData }
        return (Data(text.utf8), response)
    }
}
