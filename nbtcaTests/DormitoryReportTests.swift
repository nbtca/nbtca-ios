import XCTest
@testable import nbtca

@MainActor
final class DormitoryReportTests: XCTestCase {
    private func row(_ id: String, batch: String = "check-A", dorm: String = "room-A") -> JSONObject {
        ["WID": id, "JCBM": batch, "SSDM": dorm, "SSLMC": "A", "FJH": "101",
         "JCRQ": "2026-10-01", "JCLXDM": "regular", "JCLXDM_DISPLAY": "定期检查", "ZC": "4",
         "XN": "2026", "XQ": "1", "XN_DISPLAY": "2026-2027学年", "XQ_DISPLAY": "第一学期",
         "FS": "8.5", "DZ_GGFS": "8.5", "DZ_GRFS": "9", "JCFS": "8.72",
         "BZ": "检查备注", "WGLXDM_DISPLAY": "扣分说明"]
    }
    private func page(_ rows: [JSONObject], _ kind: DormitoryKind, number: Int = 1, total: Int? = nil, size: Int = 50) -> JSONObject {
        ["datas": [kind.action: ["rows": rows, "totalSize": total ?? rows.count, "pageNumber": number, "pageSize": size]]]
    }
    private func parse(_ row: JSONObject, _ kind: DormitoryKind) throws -> DormitoryInspection {
        try XCTUnwrap(DormitoryParser.page(page([row], kind), kind: kind).rows.first)
    }
    func testPersonalDatasetUsesThreeActualSchoolFieldsAndNeverRecalculatesTotal() throws {
        let record = try parse(row("person"), .personal)
        XCTAssertEqual(record.roomScore, "8.5")
        XCTAssertEqual(record.personalScore, "9")
        XCTAssertEqual(record.totalScore, "8.72")
        XCTAssertEqual(record.score, "8.72")
        XCTAssertNotEqual(record.totalScore, "8.75")
    }
    func testRoomDatasetDoesNotMislabelRoomScoreAsPersonalOrTotal() throws {
        let record = try parse(row("room"), .room)
        XCTAssertEqual(record.roomScore, "8.5")
        XCTAssertEqual(record.score, "8.5")
        XCTAssertEqual(record.personalScore, "")
        XCTAssertEqual(record.totalScore, "")
    }
    func testNullScoresRemainUnpublishedAndZeroIsNotDropped() throws {
        var pending = row("pending")
        pending["DZ_GGFS"] = NSNull(); pending["DZ_GRFS"] = NSNull(); pending["JCFS"] = NSNull()
        let a = try parse(pending, .personal)
        XCTAssertEqual([a.roomScore, a.personalScore, a.totalScore, a.score], ["", "", "", ""])
        var zero = row("zero")
        zero["DZ_GGFS"] = 0; zero["DZ_GRFS"] = 0; zero["JCFS"] = 0
        let b = try parse(zero, .personal)
        XCTAssertEqual([b.roomScore, b.personalScore, b.totalScore], ["0", "0", "0"])
    }
    func testMissingTotalIsNotFilledFromFSOrAnAverage() throws {
        var missing = row("no-total"); missing.removeValue(forKey: "JCFS")
        let record = try parse(missing, .personal)
        XCTAssertEqual(record.totalScore, "")
        XCTAssertEqual(record.score, "")
    }
    func testMatchedReportKeepsRoomAndPersonalRemarksSeparate() throws {
        var p = row("person"), r = row("room")
        p["WGLXDM_DISPLAY"] = "个人扣分"; p["BZ"] = "总分备注"
        r["WGLXDM_DISPLAY"] = "宿舍违规"; r["BZ"] = "宿舍备注"
        let reports = DormitoryReport.combine(personal: [try parse(p, .personal)], rooms: [try parse(r, .room)])
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(report.personalDeductions, "个人扣分")
        XCTAssertEqual(report.totalRemark, "总分备注")
        XCTAssertEqual(report.roomInspection?.deductions, "宿舍违规")
        XCTAssertEqual(report.roomInspection?.remark, "宿舍备注")
        XCTAssertEqual(report.totalScore, "8.72")
    }
    func testSameDateIsInsufficientToMergeDifferentInspectionsOrDormitories() throws {
        let p = try parse(row("person"), .personal)
        for r in [row("other-check", batch: "check-B"), row("other-room", dorm: "room-B")] {
            let reports = DormitoryReport.combine(personal: [p], rooms: [try parse(r, .room)])
            XCTAssertEqual(reports.count, 2)
            XCTAssertNil(reports.first { $0.inspection.kind == .personal }?.matchingRoom)
        }
    }
    func testTermDateTypeAndWeekConflictsNeverAttachWrongRoomRemarks() throws {
        let p = try parse(row("person"), .personal)
        for (field, value) in [("XN", "2025"), ("XQ", "2"), ("JCRQ", "2026-10-02"), ("JCLXDM", "spot"), ("ZC", "5")] {
            var r = row("room"); r[field] = value
            let reports = DormitoryReport.combine(personal: [p], rooms: [try parse(r, .room)])
            XCTAssertEqual(reports.count, 2)
            XCTAssertNil(reports.first { $0.inspection.kind == .personal }?.matchingRoom)
        }
    }
    func testMissingCorrelationIDsDoNotGuessByWeekOrDate() throws {
        var p = row("person"), r = row("room")
        p.removeValue(forKey: "JCBM"); r.removeValue(forKey: "JCBM")
        let reports = DormitoryReport.combine(personal: [try parse(p, .personal)], rooms: [try parse(r, .room)])
        XCTAssertEqual(reports.count, 2)
        XCTAssertTrue(reports.allSatisfy { $0.matchingRoom == nil })
    }
    func testAmbiguousRecordsRemainSeparateInsteadOfSelectingArbitraryRemarks() throws {
        let p = try parse(row("person"), .personal)
        let rooms = try [parse(row("room-1"), .room), parse(row("room-2"), .room)]
        let a = DormitoryReport.combine(personal: [p], rooms: rooms)
        XCTAssertEqual(a.count, 3)
        XCTAssertTrue(a.allSatisfy { $0.matchingRoom == nil })
        let b = DormitoryReport.combine(personal: [p, try parse(row("person-2"), .personal)], rooms: [rooms[0]])
        XCTAssertEqual(b.count, 3)
        XCTAssertTrue(b.allSatisfy { $0.matchingRoom == nil })
    }
    func testOfficialPersonalRoomScoreWinsOverAnotherRoomScoreSnapshot() throws {
        var r = row("room"); r["FS"] = "10"
        let report = try XCTUnwrap(DormitoryReport.combine(personal: [try parse(row("person"), .personal)], rooms: [try parse(r, .room)]).first)
        XCTAssertEqual(report.roomScore, "8.5")
        XCTAssertEqual(report.totalScore, "8.72")
    }
    func testRoomOnlyReportDoesNotInventOtherScores() throws {
        let report = try XCTUnwrap(DormitoryReport.combine(personal: [], rooms: [try parse(row("room"), .room)]).first)
        XCTAssertEqual(report.roomScore, "8.5")
        XCTAssertEqual(report.personalScore, "")
        XCTAssertEqual(report.totalScore, "")
    }
    func testSearchIncludesAllScoresAndBothDeductionDescriptions() throws {
        var p = row("person"), r = row("room")
        p["WGLXDM_DISPLAY"] = "个人扣分"; r["WGLXDM_DISPLAY"] = "宿舍违规"
        let report = try XCTUnwrap(DormitoryReport.combine(personal: [try parse(p, .personal)], rooms: [try parse(r, .room)]).first)
        for query in ["8.5", "8.72", "个人扣分", "宿舍违规"] { XCTAssertTrue(report.matches(query)) }
        XCTAssertFalse(report.matches("不存在的内容"))
    }
    func testCombinedQueryLoadsCompletePagesForBothDatasets() async throws {
        var calls: [String] = []
        let client = CampusClient(route: .campus, service: .dormitory, browserTransport: { request in
            let kind: DormitoryKind = request.url!.path.contains("person_health_student") ? .personal : .room
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            let number = body.contains("pageNumber=2") ? 2 : 1
            calls.append("\(kind.rawValue)-\(number)")
            let row = self.row("\(kind.rawValue)-\(number)", batch: "check-\(number)")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (try JSONSerialization.data(withJSONObject: self.page([row], kind, number: number, total: 2, size: 1)), response)
        })
        let reports = try await client.dormitoryReports()
        XCTAssertEqual(calls, ["personal-1", "personal-2", "room-1", "room-2"])
        XCTAssertEqual(reports.count, 2)
        XCTAssertTrue(reports.allSatisfy { $0.matchingRoom != nil && $0.totalScore == "8.72" })
    }
    func testCombinedQueryDoesNotPublishPartialDataWhenRoomQueryFails() async throws {
        let client = CampusClient(route: .campus, service: .dormitory, browserTransport: { request in
            let personal = request.url!.path.contains("person_health_student")
            let response = HTTPURLResponse(url: request.url!, statusCode: personal ? 200 : 503, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (try JSONSerialization.data(withJSONObject: self.page([self.row("person")], .personal)), response)
        })
        do { _ = try await client.dormitoryReports(); XCTFail("Both checked datasets must complete") }
        catch AcademicError.http(503) { }
    }
}
