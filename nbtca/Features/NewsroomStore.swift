import Foundation
import Observation

@MainActor @Observable
final class NewsroomStore {
    private(set) var feed: NewsFeed?
    private(set) var error: String?
    private(set) var loading = false
    private(set) var cached = false
    private(set) var baseURL: String?
    private(set) var savedAt: Date?
    private struct Archive: Codable { let savedAt: Date; let payload: Data }
    @ObservationIgnored private let fetch: (String) async throws -> JSONObject
    @ObservationIgnored private let cacheDirectory: URL
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    init(cacheDirectory: URL = .cachesDirectory, fetch: @escaping (String) async throws -> JSONObject) {
        self.cacheDirectory = cacheDirectory; self.fetch = fetch
    }
    func loadIfNeeded(baseURL: String) async {
        guard self.baseURL != baseURL else { return }
        await refresh(baseURL: baseURL)
    }
    func refresh(baseURL: String) async {
        if self.baseURL == baseURL, loading { await request?.value; return }
        request?.cancel()
        let token = UUID(); generation = token
        if self.baseURL != baseURL { feed = nil; error = nil; cached = false; savedAt = nil }
        self.baseURL = baseURL; loading = true
        let name = Data(baseURL.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        let cache = cacheDirectory.appendingPathComponent("news-\(name).json")
        // Publish the disk snapshot before starting the network request.
        if feed == nil, let data = try? Data(contentsOf: cache) {
            let archive = try? JSONDecoder().decode(Archive.self, from: data)
            if let json = (try? JSONSerialization.jsonObject(with: archive?.payload ?? data)) as? JSONObject {
                feed = NewsFeed(json); cached = true; savedAt = archive?.savedAt
            }
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.loading = false; self.request = nil } }
            do {
                let json = try await self.fetch(baseURL)
                try Task.checkCancellation(); guard self.generation == token else { return }
                self.feed = NewsFeed(json); self.cached = false; self.error = nil; self.savedAt = Date()
                if let payload = try? JSONSerialization.data(withJSONObject: json),
                   let data = try? JSONEncoder().encode(Archive(savedAt: self.savedAt!, payload: payload)) {
                    try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
                    try? data.write(to: cache, options: .atomic)
                }
            } catch is CancellationError { }
            catch {
                guard self.generation == token else { return }
                self.cached = self.feed != nil
                self.error = error.localizedDescription
            }
        }
        request = task
        await task.value
    }
}
