import XCTest
@testable import nbtca

@MainActor
final class nbtcaTests: XCTestCase {
    func testSaturdayTicketDecodesNumericIDsNestedMembersAndMixedPhotos() {
        let ticket = RepairTicket(["eventId": 42, "model": "ThinkPad", "problem": "无法开机\n接通电源无反应", "status": "ACCEPTED", "clientId": "student", "member": ["memberId": 9, "alias": "技术员"], "photos": ["https://example.com/a.jpg", ["url": "https://example.com/b.jpg"]], "logs": [["action": "accept", "gmtCreate": "2026-10-18T09:00:00+08:00"]]])
        XCTAssertEqual(ticket.id, "42"); XCTAssertEqual(ticket.title, "无法开机")
        XCTAssertEqual(ticket.memberID, "9"); XCTAssertEqual(ticket.memberName, "技术员")
        XCTAssertEqual(ticket.photos.count, 2); XCTAssertTrue(ticket.isAccepted)
        XCTAssertEqual(ticket.logs.first?.title, "维修部已接单")
    }
    func testPublicTicketDoesNotInventContactsDatesOrMembers() {
        let ticket = RepairTicket(["id": "public", "phone": NSNull(), "status": "open"])
        XCTAssertEqual(ticket.phone, ""); XCTAssertEqual(ticket.qq, ""); XCTAssertEqual(ticket.memberID, "")
        XCTAssertNil(ticket.created); XCTAssertTrue(ticket.isOpen)
    }
    func testLegacyStatusAliases() {
        XCTAssertTrue(RepairTicket(["status": "repairing"]).isAccepted)
        XCTAssertTrue(RepairTicket(["status": "completed"]).isClosed)
        XCTAssertEqual(RepairTicket.statusName("canceled"), "已取消")
    }
    func testVerifiedProfileMergesSaturdayRole() throws {
        let user = try UserProfile(info: ["sub": "u1", "roles": ["other"]], member: ["memberId": "m1", "role": "admin", "alias": "Alice"])
        XCTAssertTrue(user.isAdmin); XCTAssertTrue(user.isStaff); XCTAssertEqual(user.memberID, "m1")
        XCTAssertEqual(user.name, "Alice")
    }
    func testRoleMatchingDoesNotGrantPermissionsForPartialNames() throws {
        let client = try UserProfile(info: ["sub": "u1", "roles": ["admin-assistant", "not-a-member"]], member: [:])
        XCTAssertFalse(client.isAdmin); XCTAssertFalse(client.isStaff)
        let staff = try UserProfile(info: ["sub": "u2", "roles": [" Repair-Member "]], member: [:])
        XCTAssertTrue(staff.isStaff); XCTAssertFalse(staff.isAdmin)
        XCTAssertThrowsError(try UserProfile(info: [:], member: [:]))
    }
    func testNewsFeedDeduplicatesFeaturedAndRecentAndDerivesCategories() {
        let feed = NewsFeed(["featured": [["id": "one", "category": "技术"]], "recent": [["id": "one"], ["id": "two", "category": "活动"]]])
        XCTAssertEqual(feed.all.map(\.id), ["one", "two"])
        XCTAssertEqual(Set(feed.categories), Set(["技术", "活动"]))
        XCTAssertTrue(NewsFeed([:]).all.isEmpty)
    }
    func testCalendarTimeZonesAndAllDay() {
        let event = AssociationEvent(["start": "2026-10-18T01:00:00Z", "end": "2026-10-18T03:00:00Z"])
        XCTAssertTrue(event.timeLabel.contains("09:00")); XCTAssertTrue(event.timeLabel.contains("11:00"))
        XCTAssertTrue(AssociationEvent(["start": "2026-10-18", "all_day": true]).timeLabel.contains("全天"))
        XCTAssertNil(AppDate.parse("invalid"))
    }
    func testStatusTotalsAndIncidentsWithNullError() {
        let status = ServiceStatus(["state": "degraded", "groups": [["name": "协会服务", "components": [["id": "a", "state": "operational", "error": NSNull()], ["id": "b", "state": "down", "failed": ["database"]]]]], "incidents": [["title": "中断", "updated_at": "2026-10-18"]]])
        XCTAssertEqual(status.total, 2); XCTAssertEqual(status.healthy, 1)
        XCTAssertEqual(status.groups.first?.components.first?.error, "")
        XCTAssertEqual(status.incidents.first?.updated, "2026-10-18")
    }
    func testPKCEAgainstRFC7636Vector() throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let url = Logto.authorizeURL(verifier: verifier, state: "state-123")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "code_challenge" }?.value, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(items.first { $0.name == "redirect_uri" }?.value, "https://nbtca.space/callback")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, "state-123")
        let random = try Logto.random()
        XCTAssertEqual(random.count, 64); XCTAssertFalse(random.contains("=")); XCTAssertNotEqual(random, try Logto.random())
    }
    func testBaseURLValidation() throws {
        XCTAssertEqual(try AppSettings.normalizeURL(" example.com/api/v1/ "), "https://example.com/api/v1")
        XCTAssertThrowsError(try AppSettings.normalizeURL("ftp://example.com"))
        XCTAssertThrowsError(try AppSettings.normalizeURL("https://user:pass@example.com"))
        XCTAssertThrowsError(try AppSettings.normalizeURL("https://example.com/api?v=1"))
        XCTAssertThrowsError(try AppSettings.normalizeURL(""))
    }
    func testBFFBusinessErrorIsNotTreatedAsSuccess() {
        XCTAssertThrowsError(try APIClient.unwrap(["code": 10, "message": "上游不可用"])) { error in
            XCTAssertEqual(error.localizedDescription, "上游不可用")
        }
    }
    func testBFFFeedEnvelopeAndDoesNotSendAccessToken() async throws {
        let client = client { request in
            XCTAssertEqual(request.url?.absoluteString, "https://bff.example/api/v1/newsroom/feed")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, ["code": 0, "data": ["featured": [["id": "a", "title": "真实内容"]], "recent": []]])
        }
        let feed = try await client.feed()
        XCTAssertEqual(feed.all.first?.title, "真实内容")
    }
    func testArticleIDContainingSlashIsEncodedAsSinglePathSegment() async throws {
        let client = client { request in
            XCTAssertTrue(request.url!.absoluteString.contains("blogs%2FTech%2Ftest"))
            return (200, ["code": 0, "data": ["id": "blogs/Tech/test"]])
        }
        let article = try await client.article("blogs/Tech/test")
        XCTAssertEqual(article.id, "blogs/Tech/test")
    }
    func testHTTPAuthorizationFailureCarriesStatusAndMessage() async throws {
        let client = client { _ in (403, ["detail": "无权操作"]) }
        do { _ = try await client.feed(); XCTFail("403 should throw") }
        catch let error as APIError { XCTAssertEqual(error.status, 403); XCTAssertEqual(error.message, "无权操作") }
    }
    func testCreateAndAdminActionsUseSaturdayInsteadOfBFF() async throws {
        let client = client { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.nbtca.space/v2/client/event")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
            return (201, ["eventId": 123, "status": "open"])
        }
        let ticket = try await client.create(["problem": "不开机", "model": "PC", "phone": "123", "qq": "", "contactPreference": "phone"])
        XCTAssertEqual(ticket.id, "123")
        MockURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/v2/events/123/commit"); XCTAssertEqual(request.httpMethod, "DELETE")
            return (200, ["eventId": 123, "status": "accepted"])
        }
        let rejected = try await client.action("123", action: "commit", method: "DELETE")
        XCTAssertTrue(rejected.isAccepted)
    }
    func testReportAmendmentAndAcceptUseMemberRoutes() async throws {
        let client = client { request in
            XCTAssertEqual(request.url?.path, "/v2/member/events/123/commit"); XCTAssertEqual(request.httpMethod, "PATCH")
            return (200, ["eventId": 123, "status": "committed"])
        }
        let report = try await client.action("123", action: "commit", method: "PATCH", body: ["content": "处理完成"])
        XCTAssertTrue(report.isCommitted)
        MockURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/v2/member/events/123/accept"); XCTAssertEqual(request.httpMethod, "POST")
            return (200, ["eventId": 123, "status": "accepted"])
        }
        _ = try await client.action("123", action: "accept")
    }
    func testCancelSupportsEmpty204Response() async throws {
        let client = client { request in
            XCTAssertEqual(request.url?.path, "/v2/client/events/123"); XCTAssertEqual(request.httpMethod, "DELETE")
            return (204, nil)
        }
        try await client.cancel("123")
    }
    func testPhotoUploadUsesMultipartAndSaturdayAuthorization() async throws {
        let client = client { request in
            XCTAssertEqual(request.url?.path, "/v2/member/events/123/photos")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=NBTCA-") == true)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
            return (200, ["eventId": 123, "photos": ["https://example.com/photo.jpg"]])
        }
        let ticket = try await client.upload("123", photos: [Data([0xff, 0xd8, 0xff])])
        XCTAssertEqual(ticket.photos.count, 1)
    }
    private func client(_ handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.setHandler(handler)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(transport: URLSession(configuration: configuration), baseURL: "https://bff.example/api/v1", tokenProvider: { "test-access-token" })
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (Int, Any?)
    private static let lock = NSLock()
    private static var handler: Handler?
    static func setHandler(_ value: @escaping Handler) { lock.lock(); defer { lock.unlock() }; handler = value }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        do {
            let (status, json) = try XCTUnwrap(handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let json { client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: json)) }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
