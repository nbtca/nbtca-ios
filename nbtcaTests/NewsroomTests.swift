import XCTest
@testable import nbtca

@MainActor
final class NewsroomTests: XCTestCase {
    func testReturningToHomeOnlyLoadsOnceUntilManualRefresh() async throws {
        var calls = 0
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let store = NewsroomStore(cacheDirectory: cache) { _ in
            calls += 1
            return ["recent": [["id": "article-\(calls)", "title": "新闻"]]]
        }
        await store.loadIfNeeded(baseURL: "https://example.test/api/v1")
        await store.loadIfNeeded(baseURL: "https://example.test/api/v1")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.feed?.all.first?.id, "article-1")
        await store.refresh(baseURL: "https://example.test/api/v1")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.feed?.all.first?.id, "article-2")
        await store.loadIfNeeded(baseURL: "https://example.test/api/v1")
        XCTAssertEqual(calls, 2)
    }
    func testFailedHomeLoadWaitsForManualRetry() async {
        var calls = 0
        let store = NewsroomStore(cacheDirectory: .temporaryDirectory.appendingPathComponent(UUID().uuidString)) { _ in
            calls += 1; throw URLError(.notConnectedToInternet)
        }
        await store.loadIfNeeded(baseURL: "https://offline.test/api/v1")
        await store.loadIfNeeded(baseURL: "https://offline.test/api/v1")
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(store.error)
        await store.refresh(baseURL: "https://offline.test/api/v1")
        XCTAssertEqual(calls, 2)
    }
    func testServerChangeLoadsNewFeedWithoutMixingPreviousContent() async {
        let store = NewsroomStore(cacheDirectory: .temporaryDirectory.appendingPathComponent(UUID().uuidString)) { base in
            if base.contains("new") { throw URLError(.notConnectedToInternet) }
            return ["recent": [["id": "old-server", "title": "旧内容"]]]
        }
        await store.loadIfNeeded(baseURL: "https://old.test/api/v1")
        XCTAssertEqual(store.feed?.all.count, 1)
        await store.loadIfNeeded(baseURL: "https://new.test/api/v1")
        XCTAssertNil(store.feed)
        XCTAssertNotNil(store.error)
    }
    func testLeavingHomeDoesNotCancelFirstLoadOrDuplicateIt() async {
        var calls = 0
        var pending: CheckedContinuation<JSONObject, Never>?
        let store = NewsroomStore(cacheDirectory: .temporaryDirectory.appendingPathComponent(UUID().uuidString)) { _ in
            calls += 1
            return await withCheckedContinuation { pending = $0 }
        }
        let first = Task { await store.loadIfNeeded(baseURL: "https://example.test/api/v1") }
        while pending == nil { await Task.yield() }
        first.cancel()
        await store.loadIfNeeded(baseURL: "https://example.test/api/v1")
        XCTAssertEqual(calls, 1)
        pending?.resume(returning: ["recent": [["id": "loaded", "title": "新闻"]]])
        await first.value
        XCTAssertEqual(store.feed?.all.first?.id, "loaded")
        XCTAssertFalse(store.loading)
    }
    func testManualRefreshFailureKeepsAlreadyLoadedFeed() async {
        var calls = 0
        let store = NewsroomStore(cacheDirectory: .temporaryDirectory.appendingPathComponent(UUID().uuidString)) { _ in
            calls += 1
            if calls > 1 { throw URLError(.notConnectedToInternet) }
            return ["recent": [["id": "retained", "title": "新闻"]]]
        }
        await store.loadIfNeeded(baseURL: "https://example.test/api/v1")
        await store.refresh(baseURL: "https://example.test/api/v1")
        XCTAssertEqual(store.feed?.all.first?.id, "retained")
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.cached)
    }
}
