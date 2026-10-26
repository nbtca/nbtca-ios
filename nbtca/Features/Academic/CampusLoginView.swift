import SwiftUI
import WebKit

struct CampusLoginView: View {
    let route: CampusRoute
    var service: CampusService = .academic
    var academicStore: AcademicStore? = nil
    var dormitoryStore: DormitoryStore? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var attempt = UUID()
    @State private var error: String?
    @State private var validationError: String?
    @State private var validating = false
    @State private var loading = true
    @State private var pageHost = ""
    @State private var queryRequest = 0
    private var session: CampusWebSession {
        service == .academic ? (academicStore ?? .shared).session(for: route) : (dormitoryStore ?? .shared).session(for: route)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if loading && error == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在加载 · " + (pageHost.isEmpty ? service.loginURL(route).host! : pageHost))
                    }.font(.caption).foregroundStyle(.secondary).padding(10)
                }
                if let error {
                    LoadFailure(message: error) { retry() }
                    if route == .campus {
                        Button("改用 WebVPN") { CampusNetwork.shared.selectMode(.webVPN); dismiss() }
                            .padding(.bottom, 20)
                    }
                } else {
                    if let validationError {
                        NoticeView(message: validationError).padding(.horizontal, 16).padding(.bottom, 8)
                    }
                    CampusLoginWebView(session: session, queryRequest: queryRequest, onCookies: { cookies in
                        guard !validating else { return }
                        validating = true; validationError = nil
                        Task {
                            do {
                                if service == .academic { try await (academicStore ?? .shared).finishLogin(cookies: cookies, route: route) }
                                else { try await (dormitoryStore ?? .shared).finishLogin(cookies: cookies, route: route) }
                                dismiss()
                            }
                            // Keep the authenticated browser mounted when native
                            // verification fails. Removing it turns an API-format
                            // error into a blank login screen and interrupts SPA setup.
                            catch { self.validationError = error.localizedDescription }
                            validating = false
                        }
                    }, onLoading: { loading = $0; pageHost = $1 }, onFailure: { error = $0 }).id(attempt)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Button(validationError == nil ? "已完成登录，继续查询" : "继续查询") { validationError = nil; queryRequest += 1 }
                        .disabled(loading || validating).padding(12)
                }
            }
            .overlay { if validating { ProgressView("正在验证学校会话…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)) } }
            .navigationTitle(service.title + "登录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(validating) }
                ToolbarItem(placement: .topBarTrailing) { Button("重新加载") { retry() }.disabled(validating) }
            }
            .interactiveDismissDisabled(validating)
            .onChange(of: CampusNetwork.shared.route) { _, next in if next != route { dismiss() } }
        }.presentationSizing(.page)
    }
    private func retry() { error = nil; validationError = nil; loading = true; pageHost = ""; attempt = UUID() }
}

private struct CampusLoginWebView: UIViewRepresentable {
    let session: CampusWebSession
    let queryRequest: Int
    let onCookies: ([HTTPCookie]) -> Void
    let onLoading: (Bool, String) -> Void
    let onFailure: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(session: session, queryRequest: queryRequest, onCookies: onCookies, onLoading: onLoading, onFailure: onFailure) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = session.websiteDataStore
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        context.coordinator.start(in: view); return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        if context.coordinator.queryRequest != queryRequest {
            context.coordinator.queryRequest = queryRequest
            context.coordinator.flow.manualQuery()
            context.coordinator.load(context.coordinator.queryURL, in: view)
        }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stop(); view.navigationDelegate = nil; view.stopLoading()
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        let session: CampusWebSession
        let onCookies: ([HTTPCookie]) -> Void
        let onLoading: (Bool, String) -> Void
        let onFailure: (String) -> Void
        var flow = CampusLoginNavigation()
        var queryRequest: Int
        private var activeNavigation: WKNavigation?
        private var timeout: Task<Void, Never>?
        private var preparation: Task<Void, Never>?
        private var inspection: Task<Void, Never>?
        private var stopped = false
        private var pendingURL: URL?
        init(session: CampusWebSession, queryRequest: Int, onCookies: @escaping ([HTTPCookie]) -> Void,
             onLoading: @escaping (Bool, String) -> Void, onFailure: @escaping (String) -> Void) {
            self.session = session; self.queryRequest = queryRequest; self.onCookies = onCookies
            self.onLoading = onLoading; self.onFailure = onFailure
        }
        var queryURL: URL { session.service == .academic ? session.client.url(for: .timetable, query: false) : session.service.entryURL(session.route) }
        func stop() { stopped = true; timeout?.cancel(); preparation?.cancel(); inspection?.cancel(); flow.invalidate() }
        func start(in webView: WKWebView) {
            armTimeout(for: webView)
            preparation = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                await self.session.prepareLogin()
                guard !Task.isCancelled, !self.stopped else { return }
                self.load(self.session.service.loginURL(self.session.route), in: webView)
            }
        }
        private func fail(_ message: String) {
            guard !stopped else { return }; stop(); onFailure(message)
        }
        func load(_ url: URL, in webView: WKWebView) {
            load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30), in: webView)
        }
        private func load(_ request: URLRequest, in webView: WKWebView) {
            guard !stopped else { return }
            flow.begin(); pendingURL = request.url; armTimeout(for: webView)
            activeNavigation = webView.load(request)
        }
        private func armTimeout(for webView: WKWebView) {
            timeout?.cancel()
            timeout = Task { @MainActor [weak self, weak webView] in
                do { try await Task.sleep(for: .seconds(35)) } catch { return }
                guard let self, let webView, !self.stopped else { return }
                // Stop first: stopLoading() itself produces a cancelled-load callback.
                self.fail(CampusConnectionDiagnostics.message(URLError(.timedOut), route: self.session.route, url: self.pendingURL))
                webView.stopLoading()
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard !stopped, let url = action.request.url else { decisionHandler(.cancel); return }
            if url.absoluteString == "about:blank" || session.route.allows(url, service: session.service) {
                if action.targetFrame?.isMainFrame == true {
                    flow.begin(); pendingURL = url
                }
                // Authentication portals may use target="_blank". Keep approved
                // destinations in this web view instead of silently losing them.
                if action.targetFrame == nil {
                    decisionHandler(.cancel)
                    if url.absoluteString != "about:blank" { load(action.request, in: webView) }
                    return
                }
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                if action.targetFrame?.isMainFrame != false {
                    fail(AcademicError.unsafeURL.localizedDescription + "（" + (url.host ?? "未知主机") + "）")
                }
            }
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard !stopped else { return }
            activeNavigation = navigation; flow.begin(); armTimeout(for: webView)
            onLoading(true, pendingURL?.host ?? session.route.host)
        }
        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            guard !stopped, navigation === activeNavigation else { return }
            flow.begin(); pendingURL = webView.url ?? pendingURL
            onLoading(true, pendingURL?.host ?? session.route.host)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !stopped, !flow.completed, navigation === activeNavigation, let url = webView.url else { return }
            let token = flow.finish()
            onLoading(false, url.host ?? session.route.host)
            inspect(webView, url: url, token: token)
        }
        private func inspect(_ webView: WKWebView, url: URL, token: Int) {
            // Only inspect DOM structure; never read password, student ID or form values.
            let readySelector = session.service == .academic ? "select#xnm,select[name=\"xnm\"]" : "#sswsxs_grid,#grwsxs_grid"
            let secondSelector = session.service == .academic ? "select#xqm,select[name=\"xqm\"]" : "#sswsxs_search,#grwsxs_search"
            let renderedGrid = session.service == .academic ? "true" : "Boolean(document.querySelector('\(readySelector)')?.childElementCount)"
            let script = """
            ({terms: Boolean(document.querySelector('\(readySelector)') && document.querySelector('\(secondSelector)') && \(renderedGrid)),
              login: Boolean(document.querySelector('input[type="password"],form#pwdFromId,form#loginFromId')),
              content: Boolean(document.body && (document.body.innerText.trim().length || document.body.querySelector('input,button,img,iframe')))})
            """
            webView.evaluateJavaScript(script) { [weak self, weak webView] value, error in
                guard let self, let webView, !self.stopped, self.flow.isCurrent(token), !webView.isLoading, webView.url == url else { return }
                guard error == nil, let flags = value as? [String: Bool] else {
                    self.fail("无法检查学校登录页面（\(url.host ?? self.session.route.host)），请重新加载。")
                    return
                }
                // The student-services SPA renders its query grid after the main
                // document finishes. Wait for that view instead of treating its
                // temporary empty shell as a failed login.
                if self.session.service == .dormitory, url.host == self.session.service.host(self.session.route), flags["terms"] != true, flags["login"] != true {
                    self.inspection?.cancel()
                    self.inspection = Task { @MainActor [weak self, weak webView] in
                        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                        guard let self, let webView, !self.stopped, self.flow.isCurrent(token), webView.url == url else { return }
                        self.inspect(webView, url: url, token: token)
                    }
                    return
                }
                self.timeout?.cancel()
                guard flags["content"] == true else {
                    self.fail("学校登录服务返回了空白页面（\(url.host ?? self.session.route.host)），请重新加载或切换访问线路。")
                    return
                }
                switch self.flow.step(route: self.session.route, service: self.session.service, url: url, token: token, hasTerms: flags["terms"] == true, hasLoginForm: flags["login"] == true) {
                case .complete:
                    self.session.browser.adoptAuthenticatedPage(webView)
                    self.session.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                        guard let self, !self.stopped, self.flow.revision == token else { return }
                        self.onCookies(cookies)
                    }
                case .timetable: self.load(self.session.client.url(for: .timetable, query: false), in: webView)
                case .sso: self.load(self.session.service.entryURL(self.session.route), in: webView)
                case .wait: break
                }
            }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handle(error, navigation: navigation, in: webView)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handle(error, navigation: navigation, in: webView)
        }
        private func handle(_ error: Error, navigation: WKNavigation?, in webView: WKWebView) {
            guard !stopped, !CampusConnectionDiagnostics.isCancellation(error), navigation == nil || navigation === activeNavigation else { return }
            let failedURL = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
            fail(CampusConnectionDiagnostics.message(error, route: session.route, url: failedURL ?? pendingURL ?? webView.url))
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            fail("学校登录页面进程已退出，请点“重试”重新加载。若反复出现，可关闭其他占用内存的应用后重试。")
        }
    }
}
