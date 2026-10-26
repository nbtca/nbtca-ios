import SwiftUI
import WebKit

struct ProfileView: View {
    @State private var auth = AuthStore.shared
    @State private var settings = AppSettings.shared
    @State private var showLogin = false
    @State private var showServer = false
    @State private var showLogout = false
    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    ZStack {
                        Circle().fill(Color.brand.opacity(0.1))
                        if let user = auth.user, !user.avatar.isEmpty { RemoteImage(source: user.avatar).clipShape(Circle()) }
                        else { Image(systemName: "person.crop.circle.fill").font(.system(size: 44)).foregroundStyle(Color.brand) }
                    }.frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(auth.user?.name ?? "未登录 NBTCA 账号").font(.title3.bold())
                        Text(auth.user?.email ?? "注册/登录后方可使用预约维修功能").font(.caption).foregroundStyle(.secondary)
                        if auth.isLoggedIn { Text(auth.roleName).font(.caption).foregroundStyle(Color.brand) }
                    }.padding(.vertical, 10)
                }.profileRowSeparator()
                if auth.isLoggedIn {
                    Button("退出登录", role: .destructive) { showLogout = true }.profileRowSeparator()
                } else {
                    Button { showLogin = true } label: { Label("登录 / 注册", systemImage: "arrow.right.circle.fill") }.profileRowSeparator()
                }
                if let notice = auth.notice { Text(notice).font(.caption).foregroundStyle(.orange).profileRowSeparator() }
            }
            Section("偏好设置") {
                Picker(selection: $settings.theme) {
                    Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                } label: { Label("外观", systemImage: "circle.lefthalf.filled") }.profileRowSeparator()
                if auth.user?.isStaff == true {
                    Picker(selection: $auth.viewRole) {
                        Text("自动（最高权限）").tag("auto")
                        if auth.user?.isAdmin == true { Text("管理员").tag("admin") }
                        Text("技术员").tag("member"); Text("报修用户").tag("client")
                    } label: { Label("界面视角", systemImage: "person.badge.key") }.profileRowSeparator()
                }
                Button { showServer = true } label: {
                    HStack {
                        Label("后端服务器", systemImage: "server.rack").foregroundStyle(.primary)
                        Spacer()
                        Text(URL(string: settings.baseURL)?.host ?? "未配置").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }.profileRowSeparator()
            }
            Section("学校服务") {
                NavigationLink { AcademicView() } label: { Label("教务查询与学校登录", systemImage: "graduationcap") }.profileRowSeparator()
                NavigationLink { DormitoryView() } label: { Label("寝室文明查询", systemImage: "building.2.crop.circle") }.profileRowSeparator()
            }
            Section("关于协会") {
                ExternalLink(title: "GitHub · nbtca", url: "https://github.com/nbtca", symbol: "chevron.left.forwardslash.chevron.right").profileRowSeparator()
                ExternalLink(title: "拔电关机官方网站", url: "https://nbtca.space", symbol: "globe").profileRowSeparator()
                ExternalLink(title: "官方维修入口", url: "https://nbtca.space/repair", symbol: "wrench.and.screwdriver").profileRowSeparator()
                NavigationLink { AboutView() } label: { Label("关于 NBTCA", systemImage: "info.circle") }.profileRowSeparator()
            }
        }.readableContent().navigationTitle("个人中心")
            .sheet(isPresented: $showLogin) { LoginView() }
            .sheet(isPresented: $showServer) { ServerSettingsView() }
            .confirmationDialog("退出当前 NBTCA 账号？", isPresented: $showLogout, titleVisibility: .visible) { Button("退出登录", role: .destructive) { auth.logout() } }
    }
}

private extension View {
    func profileRowSeparator() -> some View {
        // Keep the divider at the row inset instead of following each label's text.
        alignmentGuide(.listRowSeparatorLeading) { dimensions in dimensions[.leading] }
    }
}

struct ServerSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = AppSettings.shared.baseURL
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://服务器地址/api/v1", text: $address, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } header: { Text("后端 API 地址") }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.readableContent(maxWidth: 720).navigationTitle("后端服务器").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            do { AppSettings.shared.baseURL = try AppSettings.normalizeURL(address); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
        }.presentationSizing(.form)
    }
}

private struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image("Icon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                Text("拔电关机").font(.largeTitle.bold())
                Text("NBTCA iOS · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")").foregroundStyle(.secondary)
                Text("浙大宁波理工学院 计算机协会 官方开源移动客户端。\n整合 Newsroom 资讯、Saturday 维修系统、基础设施监测等服务。").multilineTextAlignment(.center).lineSpacing(8)
                Text("To be at the intersection of technology and liberal arts.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                ExternalLink(title: "访问 NBTCA", url: "https://nbtca.space")
            }.pageContent(maxWidth: 640, padding: 32)
        }.navigationTitle("关于 NBTCA").navigationBarTitleDisplayMode(.inline)
    }
}

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var attempt: LoginAttempt?
    @State private var error: String?
    @State private var exchanging = false
    var body: some View {
        NavigationStack {
            Group {
                if exchanging { ProgressView("正在验证身份…") }
                else if let error { LoadFailure(message: error) { begin() } }
                else if let attempt {
                    LoginWebView(url: Logto.authorizeURL(verifier: attempt.verifier, state: attempt.state), callback: { url in
                        complete(url, attempt: attempt)
                    }, failure: { error = $0 })
                } else { ProgressView("正在准备安全登录…") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("NBTCA 账号").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(exchanging) } }
                .interactiveDismissDisabled(exchanging)
                .onAppear { if attempt == nil { begin() } }
        }.presentationSizing(.page)
    }
    private func begin() {
        do { attempt = try LoginAttempt(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func complete(_ url: URL, attempt: LoginAttempt) {
        guard !exchanging else { return }
        let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard params.filter({ $0.name == "state" }).count == 1,
              params.first(where: { $0.name == "state" })?.value == attempt.state else { error = "登录校验失败，请重试"; return }
        if let authError = params.first(where: { $0.name == "error" })?.value { error = "登录未完成：" + authError; return }
        guard let code = params.first(where: { $0.name == "code" })?.value, !code.isEmpty else { error = "未收到登录授权码"; return }
        exchanging = true
        Task {
            do { try await AuthStore.shared.login(code: code, verifier: attempt.verifier); dismiss() }
            catch { self.error = error.localizedDescription }
            exchanging = false
        }
    }
}

private struct LoginAttempt {
    let verifier: String
    let state: String
    init() throws { verifier = try Logto.random(); state = try Logto.random() }
}

private struct LoginWebView: UIViewRepresentable {
    let url: URL
    let callback: (URL) -> Void
    let failure: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(callback: callback, failure: failure) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; context.coordinator.lastURL = url; view.load(URLRequest(url: url))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        if context.coordinator.lastURL != url {
            context.coordinator.lastURL = url; view.load(URLRequest(url: url))
        }
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        let callback: (URL) -> Void
        let failure: (String) -> Void
        var lastURL: URL?
        init(callback: @escaping (URL) -> Void, failure: @escaping (String) -> Void) { self.callback = callback; self.failure = failure }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, url.scheme == "https", url.host == "nbtca.space", url.path == "/callback" {
                decisionHandler(.cancel); callback(url)
            } else if action.request.url?.scheme == "https" || action.request.url?.absoluteString == "about:blank" { decisionHandler(.allow) }
            else { decisionHandler(.cancel) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { failure("登录页面加载失败，请检查网络后重试") }
        }
    }
}

#Preview("个人中心") { NavigationStack { ProfileView() }.tint(.brand) }
