import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import nbtca

@MainActor
final class OptimizationTests: XCTestCase {
    private func directory() -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("optimization-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testAllLegacyTicketStatesMatchTheirVisibleFilter() {
        for (raw, expected) in [("pending", "open"), ("repairing", "accepted"), ("completed", "closed"), ("canceled", "cancelled")] {
            let ticket = RepairTicket(["status": raw])
            XCTAssertTrue(ticket.matchesStatus(expected)); XCTAssertTrue(ticket.matchesStatus("all"))
            XCTAssertFalse(ticket.matchesStatus("committed"))
        }
    }
    func testRefreshFailurePreservesTicketsAndPagination() async {
        var failing = false
        let store = RepairStore { _, _ in
            if failing { throw URLError(.notConnectedToInternet) }
            return (0..<50).map { RepairTicket(["id": "\($0)", "status": "open"]) }
        }
        await store.load(identity: "user", queue: false)
        failing = true
        await store.load(identity: "user", queue: false)
        XCTAssertEqual(store.tickets.count, 50); XCTAssertTrue(store.hasMore)
        XCTAssertTrue(store.error?.contains("上次") == true)
        XCTAssertTrue(store.emptyMessage(filter: "closed").contains("继续加载"))
        await store.load(identity: "another-user", queue: false)
        XCTAssertTrue(store.tickets.isEmpty); XCTAssertFalse(store.hasMore)
    }
    func testRefreshKeepsVisibleRowsUntilReplacementArrives() async {
        var pending: CheckedContinuation<[RepairTicket], Never>?
        var calls = 0
        let store = RepairStore { _, _ in
            calls += 1
            if calls == 1 { return [RepairTicket(["id": "old"])] }
            return await withCheckedContinuation { pending = $0 }
        }
        await store.load(identity: "u", queue: false)
        let task = Task { await store.load(identity: "u", queue: false) }
        while pending == nil { await Task.yield() }
        XCTAssertEqual(store.tickets.first?.id, "old"); XCTAssertTrue(store.loading)
        pending?.resume(returning: [RepairTicket(["id": "new"])])
        await task.value
        XCTAssertEqual(store.tickets.first?.id, "new")
    }
    func testOldAccountResponseCannotOverwriteNewAccount() async {
        var pending: CheckedContinuation<[RepairTicket], Never>?
        let store = RepairStore { _, _ in await withCheckedContinuation { pending = $0 } }
        let task = Task { await store.load(identity: "old", queue: false) }
        while pending == nil { await Task.yield() }
        await store.load(identity: nil, queue: false)
        pending?.resume(returning: [RepairTicket(["id": "private"])])
        await task.value
        XCTAssertTrue(store.tickets.isEmpty); XCTAssertFalse(store.loading)
    }
    func testPaginationFailureCanRetryWithoutSkippingOffset() async {
        var offsets: [Int] = [], fail = true
        let store = RepairStore { _, offset in
            offsets.append(offset)
            if offset == 50 && fail { throw URLError(.timedOut) }
            return offset == 0 ? (0..<50).map { RepairTicket(["id": "\($0)"]) } : [RepairTicket(["id": "50"])]
        }
        await store.load(identity: "u", queue: false)
        await store.load(identity: "u", queue: false, more: true)
        fail = false
        await store.load(identity: "u", queue: false, more: true)
        XCTAssertEqual(offsets, [0, 50, 50]); XCTAssertEqual(store.tickets.count, 51)
        XCTAssertNil(store.error); XCTAssertFalse(store.hasMore)
    }
    func testFeedCacheAppearsBeforeNetworkCompletes() async throws {
        let folder = directory()
        let first = NewsroomStore(cacheDirectory: folder) { _ in ["recent": [["id": "saved", "title": "缓存"]]] }
        await first.refresh(baseURL: "https://example.test")
        var pending: CheckedContinuation<JSONObject, Never>?
        let second = NewsroomStore(cacheDirectory: folder) { _ in await withCheckedContinuation { pending = $0 } }
        let task = Task { await second.refresh(baseURL: "https://example.test") }
        while pending == nil { await Task.yield() }
        XCTAssertEqual(second.feed?.all.first?.id, "saved"); XCTAssertTrue(second.cached)
        XCTAssertTrue(second.loading); XCTAssertNotNil(second.savedAt)
        pending?.resume(returning: ["recent": [["id": "updated"]]])
        await task.value
        XCTAssertEqual(second.feed?.all.first?.id, "updated"); XCTAssertFalse(second.cached)
    }
    func testArticleCachePersistsAndSeparatesServers() async {
        let folder = directory(), data = Data("article".utf8)
        let cache = ArticleCache(directory: folder)
        await cache.write(data, key: "server-a|article")
        let restored = await ArticleCache(directory: folder).read("server-a|article")
        let other = await cache.read("server-b|article")
        XCTAssertEqual(restored, data); XCTAssertNil(other)
    }
    func testArticleCacheEvictsOldEntries() async throws {
        let folder = directory(), cache = ArticleCache(directory: folder)
        for index in 0..<34 { await cache.write(Data("body".utf8), key: "\(index)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 30)
    }
    func testDraftsRestoreAndStayWithinAccountAndForm() throws {
        let folder = directory(), drafts = FormDraftStore(directory: folder)
        let draft = FormDraft(fields: ["problem": "无法开机", "phone": "fictional"])
        try drafts.save(draft, account: "a", key: "new")
        XCTAssertEqual(FormDraftStore(directory: folder).load(account: "a", key: "new"), draft)
        XCTAssertNil(drafts.load(account: "b", key: "new")); XCTAssertNil(drafts.load(account: "a", key: "edit"))
        try drafts.remove(account: "a", key: "new")
        XCTAssertNil(drafts.load(account: "a", key: "new"))
        try drafts.save(draft, account: "a", key: "new"); try drafts.clear()
        XCTAssertNil(drafts.load(account: "a", key: "new"))
    }
    func testDraftWriteFailureIsReported() throws {
        let folder = directory()
        try Data("blocked".utf8).write(to: folder)
        XCTAssertThrowsError(try FormDraftStore(directory: folder).save(FormDraft(fields: [:]), account: "a", key: "new"))
    }
    func testTodayListUsesShanghaiDateAndTeachingWeeks() {
        let course = AcademicCourse(id: "a", name: "数学", teacher: "", location: "", weekText: "", periodText: "", weekday: 3, startPeriod: 1, endPeriod: 2, weeks: [6], practice: false)
        var timetable = AcademicTimetable(courses: [course], periods: [], days: [], unrecognizedCount: 0, weekOneMonday: "2026-09-14")
        let date = AcademicParser.dateTime("2026-10-21", "00:10")!
        XCTAssertEqual(timetable.courses(on: date, from: [course]).map(\.id), ["a"])
        XCTAssertTrue(timetable.courses(on: date.addingTimeInterval(-3600), from: [course]).isEmpty)
        timetable.unavailableDays = ["6:3"]
        XCTAssertTrue(timetable.courses(on: date, from: [course]).isEmpty)
        timetable.weekOneMonday = nil
        XCTAssertTrue(timetable.courses(on: date, from: [course]).isEmpty)
    }
    func testCalendarDiffSeparatesRoomChangesReschedulesAndRemovedCourses() {
        let start = Date(timeIntervalSince1970: 1000)
        func event(_ room: String, time: Date? = nil) -> CalendarEventSnapshot {
            CalendarEventSnapshot(title: "数学", location: room, notes: "教师", start: time ?? start, end: (time ?? start).addingTimeInterval(3600))
        }
        let diff = CalendarSyncDiff(desired: ["same": event("new-room"), "moved": event("A", time: start.addingTimeInterval(86400))], existing: ["same": event("old-room"), "old-time": event("A"), "dropped": event("B")])
        XCTAssertEqual(diff.added, 1); XCTAssertEqual(diff.updated, 1); XCTAssertEqual(diff.removed, 2)
        XCTAssertEqual(diff.removedIDs, ["old-time", "dropped"])
        XCTAssertTrue(diff.removalIDs(confirmed: false, hasIssues: false).isEmpty)
        XCTAssertTrue(diff.removalIDs(confirmed: true, hasIssues: true).isEmpty)
        XCTAssertEqual(diff.removalIDs(confirmed: true, hasIssues: false), ["old-time", "dropped"])
        XCTAssertTrue(CalendarSyncDiff(desired: ["a": event("A")], existing: ["a": event("A")]).changes.isEmpty)
        XCTAssertEqual(CalendarSyncDiff(desired: [:], existing: ["a": event("A")]).removed, 1)
    }
    func testPhotoDownsamplingCreatesBoundedUploadAndSmallPreview() throws {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 3000, height: 1500, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage()), data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let processed = try PhotoProcessor.process(data as Data)
        func dimensions(_ data: Data) throws -> (Int, Int) {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            return (props[kCGImagePropertyPixelWidth] as! Int, props[kCGImagePropertyPixelHeight] as! Int)
        }
        XCTAssertEqual(try dimensions(processed.upload).0, 2000)
        XCTAssertEqual(try dimensions(processed.thumbnail).0, 160)
        XCTAssertLessThan(processed.thumbnail.count, processed.upload.count)
        XCTAssertThrowsError(try PhotoProcessor.process(Data("invalid".utf8)))
    }
}
