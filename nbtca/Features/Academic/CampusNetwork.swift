import Foundation
import Network
import Observation

@MainActor @Observable
final class CampusNetwork {
    static let shared = CampusNetwork()
    enum Mode: String, CaseIterable {
        case automatic, campus, webVPN
        var title: String { switch self { case .automatic: "自动检测"; case .campus: "校园网直连"; case .webVPN: "WebVPN" } }
    }
    var mode: Mode = .automatic
    private(set) var route: CampusRoute?
    private(set) var checking = true
    private(set) var connected = false
    private(set) var note = "正在检测网络…"
    private let monitor = NWPathMonitor()
    private var started = false
    private var localInterface = false
    private var detectionTask: Task<Void, Never>?
    private var generation = UUID()
    private init() { }
    func start() {
        guard !started else { return }; started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let local = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            guard let owner = self else { return }
            Task { @MainActor in
                owner.connected = connected; owner.localInterface = local; owner.scheduleCheck()
            }
        }
        monitor.start(queue: DispatchQueue(label: "space.nbtca.campus-network", qos: .utility))
    }
    func selectMode(_ value: Mode) { mode = value; scheduleCheck() }
    func recheck() { start(); scheduleCheck() }
    private func scheduleCheck() {
        detectionTask?.cancel(); generation = UUID(); let current = generation
        checking = true
        detectionTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard current == generation else { return }
                guard connected else { route = nil; note = "当前无网络连接"; checking = false; return }
                let result: CampusRoute
                if mode == .campus { result = .campus }
                else if mode == .webVPN || !localInterface { result = .webVPN }
                else { result = await probeCampus() ? .campus : .webVPN }
                try Task.checkCancellation(); guard current == generation else { return }
                route = result; checking = false
                note = mode == .automatic ? (result == .campus ? "内网教务可达，已自动直连" : "内网教务不可达，已自动使用 WebVPN") : "当前手动使用" + result.title
            } catch { if current == generation { checking = false } }
        }
    }
    private func probeCampus() async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.allowsCellularAccess = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 4; configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration, delegate: CampusRedirectDelegate(route: .campus, followRedirects: false), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: CampusRoute.campus.ssoURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled, let response = response as? HTTPURLResponse, data.count < 2 * 1024 * 1024 else { return false }
            return CampusRoute.recognizesCampusProbe(url: response.url, status: response.statusCode,
                location: response.value(forHTTPHeaderField: "Location"), body: String(data: data, encoding: .utf8) ?? "")
        } catch { return false }
    }
}
