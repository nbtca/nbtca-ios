import XCTest
@testable import nbtca

@MainActor
final class AcademicStoreTests: XCTestCase {
    private let term = AcademicTerm(year: "2026", semester: "3", yearLabel: "2026-2027", semesterLabel: "3", current: true)
    private func fixture(cached: Bool = true) throws -> (AcademicStore, QuerySessionStub) {
        let directory = URL.temporaryDirectory.appendingPathComponent("academic-first-load-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = TimetableCache(directory: directory)
        if cached { try cache.save(AcademicTimetable(courses: [], periods: [], days: [], unrecognizedCount: 0), term: term) }
        let session = QuerySessionStub(), offline = QuerySessionStub(route: .webVPN)
        offline.hasCredentials = false
        return (AcademicStore(cache: cache, sessionProvider: { $0 == .campus ? session : offline }), session)
    }
    func testSeparateWindowsKeepQuerySelectionAndSuspensionIndependent() async throws {
        let (first, _) = try fixture(), (second, _) = try fixture()
        first.kind = .exams; second.kind = .grades
        await first.activate(.campus); await second.activate(.campus)
        await first.reload(); await second.reload()
        first.selectedTermID = "2025-3"; first.week = 9
        first.clearSensitiveRecords()
        XCTAssertEqual(second.kind, .grades)
        XCTAssertEqual(second.selectedTermID, term.id)
        XCTAssertEqual(second.grades.count, 1)
        XCTAssertTrue(second.canQuery); XCTAssertTrue(second.hasLoadedCurrentQuery)
        XCTAssertFalse(first.canQuery)
    }
    func testSchoolIdentityChangeInvalidatesPendingPrivateResults() async throws {
        let (store, session) = try fixture()
        store.kind = .grades; await store.activate(.campus)
        var pending: CheckedContinuation<Void, Never>?
        session.beforeRecords = { await withCheckedContinuation { pending = $0 } }
        let task = Task { await store.reload() }
        while pending == nil { await Task.yield() }
        store.schoolIdentityChanged()
        pending?.resume(); await task.value
        XCTAssertTrue(store.grades.isEmpty); XCTAssertFalse(store.hasSession)
        XCTAssertFalse(store.hasLoadedCurrentQuery)
    }
    func testFirstExamsLoadRunsWhenRestoredTermMatchesCachedTerm() async throws {
        let (store, session) = try fixture()
        store.kind = .exams
        var pending: CheckedContinuation<Void, Never>?
        session.restore = { await withCheckedContinuation { pending = $0 } }
        let activation = Task { await store.activate(.campus) }
        while pending == nil { await Task.yield() }
        let waitingKey = store.queryKey
        XCTAssertTrue(store.validating)
        XCTAssertFalse(store.canQuery)
        await store.reload() // The initial SwiftUI task can run before CAS finishes.
        XCTAssertTrue(session.recordQueries.isEmpty)
        XCTAssertFalse(store.hasLoadedCurrentQuery)
        pending?.resume(); await activation.value
        XCTAssertEqual(store.selectedTermID, term.id) // No semester switch.
        XCTAssertNotEqual(store.queryKey, waitingKey) // Triggers the view's task again.
        XCTAssertTrue(store.canQuery)
        XCTAssertFalse(store.hasLoadedCurrentQuery)
        await store.reload()
        XCTAssertEqual(session.recordQueries, ["exams:2026-3"])
        XCTAssertEqual(store.exams.first?.name, "考试课程2026-3")
        XCTAssertTrue(store.hasLoadedCurrentQuery)
    }
    func testColdStartWaitsForSchoolTermsBeforeFirstQuery() async throws {
        let (store, session) = try fixture(cached: false)
        store.kind = .exams
        XCTAssertNil(store.selectedTerm)
        XCTAssertFalse(store.hasLoadedCurrentQuery)
        await store.reload()
        XCTAssertTrue(session.recordQueries.isEmpty)
        await store.activate(.campus)
        XCTAssertEqual(store.selectedTermID, term.id)
        XCTAssertFalse(store.hasLoadedCurrentQuery)
        await store.reload()
        XCTAssertEqual(store.exams.count, 1)
        XCTAssertTrue(store.hasLoadedCurrentQuery)
    }
    func testReenteringSameSemesterRestartsQueryAfterSessionValidation() async throws {
        let (store, session) = try fixture()
        store.kind = .exams
        await store.activate(.campus); await store.reload()
        XCTAssertTrue(store.hasLoadedCurrentQuery)
        store.clearSensitiveRecords()
        XCTAssertTrue(store.exams.isEmpty)
        XCTAssertFalse(store.hasLoadedCurrentQuery)
        store.resume()
        await store.activate(.campus)
        XCTAssertEqual(store.selectedTermID, term.id)
        XCTAssertFalse(store.hasLoadedCurrentQuery)
        await store.reload()
        XCTAssertEqual(session.recordQueries, ["exams:2026-3", "exams:2026-3"])
        XCTAssertEqual(store.exams.count, 1)
        XCTAssertTrue(store.hasLoadedCurrentQuery)
    }
    func testGenuineEmptyResultIsCompleteOnlyAfterSuccessfulRequest() async throws {
        let (store, session) = try fixture()
        session.empty = true; store.kind = .exams
        await store.activate(.campus)
        XCTAssertTrue(store.exams.isEmpty)
        XCTAssertFalse(store.hasLoadedCurrentQuery)
        await store.reload()
        XCTAssertTrue(store.exams.isEmpty)
        XCTAssertTrue(store.hasLoadedCurrentQuery)
        XCTAssertNil(store.error)
    }
    func testSemesterChangeImmediatelyInvalidatesPreviouslyLoadedResult() async throws {
        let (store, _) = try fixture()
        store.kind = .exams
        await store.activate(.campus); await store.reload()
        store.selectedTermID = "2025-3"
        XCTAssertFalse(store.hasLoadedCurrentQuery)
        await store.reload()
        XCTAssertEqual(store.exams.first?.name, "考试课程2025-3")
        XCTAssertTrue(store.hasLoadedCurrentQuery)
    }
    func testGradesUseTheSameReadinessAndCompletionRules() async throws {
        let (store, session) = try fixture()
        store.kind = .exams
        await store.activate(.campus); await store.reload()
        store.kind = .grades
        XCTAssertFalse(store.hasLoadedCurrentQuery)
        await store.reload()
        XCTAssertEqual(session.recordQueries.last, "grades:2026-3")
        XCTAssertEqual(store.grades.first?.grade, "90")
        XCTAssertTrue(store.exams.isEmpty)
        XCTAssertTrue(store.hasLoadedCurrentQuery)
    }
    func testOldSemesterResponseCannotCompleteNewSemesterBeforeItsTaskStarts() async throws {
        let (store, session) = try fixture()
        store.kind = .exams; await store.activate(.campus)
        var pending: CheckedContinuation<Void, Never>?
        session.beforeRecords = { await withCheckedContinuation { pending = $0 } }
        let old = Task { await store.reload() }
        while pending == nil { await Task.yield() }
        store.selectedTermID = "2025-3"
        pending?.resume(); await old.value
        XCTAssertTrue(store.exams.isEmpty)
        XCTAssertFalse(store.hasLoadedCurrentQuery)
        session.beforeRecords = nil
        await store.reload()
        XCTAssertEqual(store.exams.first?.name, "考试课程2025-3")
        XCTAssertTrue(store.hasLoadedCurrentQuery)
    }
    func testCancelledQueryIsNotTreatedAsAnEmptySuccess() async throws {
        let (store, session) = try fixture()
        store.kind = .exams; await store.activate(.campus)
        var pending: CheckedContinuation<Void, Never>?
        session.beforeRecords = { await withCheckedContinuation { pending = $0 } }
        let task = Task { await store.reload() }
        while pending == nil { await Task.yield() }
        task.cancel(); pending?.resume(); await task.value
        XCTAssertFalse(store.loading)
        XCTAssertFalse(store.hasLoadedCurrentQuery)
        XCTAssertNil(store.error)
        session.beforeRecords = nil
        await store.reload()
        XCTAssertTrue(store.hasLoadedCurrentQuery)
        XCTAssertEqual(store.exams.count, 1)
    }
    func testFailedQueryIsNotTreatedAsAnEmptySuccessAndCanBeRetried() async throws {
        let (store, session) = try fixture()
        store.kind = .exams; await store.activate(.campus)
        session.status = 503
        await store.reload()
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.hasLoadedCurrentQuery)
        XCTAssertTrue(store.exams.isEmpty)
        session.status = 200
        await store.reload()
        XCTAssertNil(store.error)
        XCTAssertTrue(store.hasLoadedCurrentQuery)
    }
}

/// Exercises the real CampusClient and parsers with synthetic responses only;
/// no WebKit instance, Keychain access or school network request is involved.
@MainActor
private final class QuerySessionStub: AcademicQuerySession {
    let route: CampusRoute
    var hasCredentials = true
    var storageNotice: String?
    var restore: (() async -> Void)?
    var beforeRecords: (() async -> Void)?
    var empty = false
    var status = 200
    var recordQueries: [String] = []
    lazy var client = CampusClient(route: route, browserTransport: { [unowned self] request in
        let response = HTTPURLResponse(url: request.url!, statusCode: request.httpMethod == "POST" ? self.status : 200,
                                       httpVersion: nil, headerFields: nil)!
        if request.httpMethod != "POST" {
            let html = "<select id='xnm'><option value='2025'>2025-2026</option><option value='2026' selected>2026-2027</option></select><select id='xqm'><option value='3' selected>3</option><option value='12'>12</option></select>"
            return (Data(html.utf8), response)
        }
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let fields = URLComponents(string: "https://example.test/?" + body)?.queryItems ?? []
        let year = fields.first { $0.name == "xnm" }?.value ?? ""
        let semester = fields.first { $0.name == "xqm" }?.value ?? ""
        let kind: AcademicKind = request.url!.path == AcademicKind.exams.queryPath ? .exams : .grades
        self.recordQueries.append("\(kind.rawValue):\(year)-\(semester)")
        await self.beforeRecords?()
        let prefix = kind == .exams ? "考试课程" : "成绩课程"
        let items: [JSONObject] = self.empty ? [] : [["xnm":year, "xqm":semester, "kcmc":prefix + year + "-" + semester, "kssj":"未公布", "cj":"90"]]
        let object: JSONObject = ["items":items, "currentPage":1, "totalPage":items.isEmpty ? 0 : 1, "totalResult":items.count]
        return (try JSONSerialization.data(withJSONObject: object), response)
    })
    init(route: CampusRoute = .campus) { self.route = route }
    func restoreSession() async throws { await restore?(); try Task.checkCancellation() }
    func query<T>(_ operation: (CampusClient) async throws -> T) async throws -> T { try await operation(client) }
    func persist() { }
    func expire() { }
    func stop() { client.clear() }
}
