import Foundation
import Observation

@MainActor @Observable
final class RepairStore {
    private(set) var tickets: [RepairTicket] = []
    private(set) var error: String?
    private(set) var loading = false
    private(set) var hasMore = false
    private var offset = 0
    private var scope: String?
    private var generation = UUID()
    @ObservationIgnored private let fetch: (Bool, Int) async throws -> [RepairTicket]

    init(fetch: @escaping (Bool, Int) async throws -> [RepairTicket]) { self.fetch = fetch }
    func load(identity: String?, queue: Bool, more: Bool = false) async {
        let nextScope = identity.map { $0 + (queue ? "|queue" : "|mine") }
        if scope != nextScope || identity == nil {
            generation = UUID(); scope = nextScope
            tickets = []; offset = 0; hasMore = false; error = nil; loading = false
        }
        guard identity != nil, !more || (hasMore && !loading) else { return }
        let token = UUID(); generation = token
        let nextOffset = more ? offset : 0
        loading = true; error = nil
        defer { if generation == token { loading = false } }
        do {
            let page = try await fetch(queue, nextOffset)
            try Task.checkCancellation()
            guard generation == token else { return }
            var combined = more ? tickets : []
            var seen = Set(combined.map(\.id))
            combined += page.filter { seen.insert($0.id).inserted }
            tickets = combined; offset = nextOffset + page.count; hasMore = page.count == 50
        } catch is CancellationError { }
        catch {
            guard generation == token else { return }
            self.error = tickets.isEmpty ? error.localizedDescription : "更新失败，正在显示上次加载的记录。" + error.localizedDescription
        }
    }
    func emptyMessage(filter: String) -> String {
        if hasMore { return "已加载的记录中暂无匹配，请继续加载" }
        return filter == "all" ? "暂无维修记录" : "暂无此状态的维修记录"
    }
}
