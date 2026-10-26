import Foundation
import CoreFoundation

nonisolated enum DormitoryKind: String, CaseIterable, Identifiable, Sendable {
    case room, personal
    var id: String { rawValue }
    var title: String { self == .room ? "宿舍卫生" : "个人卫生" }
    var module: String { self == .room ? "dorm_health_student" : "person_health_student" }
    var action: String { self == .room ? "sswsxs_sswsxsbg" : "grwsxs_grwsxsbg" }
    var path: String { "/xsfw/sys/sswsapp/modules/\(module)/\(action).do" }
}

nonisolated struct DormitoryInspection: Identifiable, Equatable, Sendable {
    let id, building, room, date, type, week, score, remark, deductions: String
    let year, semester, yearLabel, semesterLabel: String
    let hasAttachments: Bool
    let kind: DormitoryKind
    let batchID, dormitoryID, typeCode: String
    let roomScore, personalScore, totalScore: String
    var location: String {
        [building.isEmpty ? "" : building + " 幢", room.isEmpty ? "" : room + " 室"].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    func matches(_ keyword: String) -> Bool {
        keyword.isEmpty || [location, date, score, roomScore, personalScore, totalScore, type, remark, deductions].joined(separator: " ").localizedCaseInsensitiveContains(keyword)
    }
    var correlationKey: [String]? {
        guard !batchID.isEmpty, !dormitoryID.isEmpty else { return nil }
        return [batchID, dormitoryID, year, semester, date, typeCode, week]
    }
}

/// The personal dataset already contains all three official scores. Join the
/// room dataset only to attach its own remarks and deductions, never to compute
/// a student's total or to pair unrelated inspections by date alone.
nonisolated struct DormitoryReport: Identifiable, Equatable, Sendable {
    let inspection: DormitoryInspection
    let matchingRoom: DormitoryInspection?
    var id: String { inspection.kind.rawValue + ":" + inspection.id }
    var roomInspection: DormitoryInspection? { inspection.kind == .room ? inspection : matchingRoom }
    var roomScore: String { inspection.roomScore.isEmpty ? roomInspection?.roomScore ?? "" : inspection.roomScore }
    var personalScore: String { inspection.personalScore }
    var totalScore: String { inspection.totalScore }
    var totalRemark: String { inspection.kind == .personal ? inspection.remark : "" }
    var personalDeductions: String { inspection.kind == .personal ? inspection.deductions : "" }
    var hasAttachments: Bool { inspection.hasAttachments || roomInspection?.hasAttachments == true }
    func matches(_ keyword: String) -> Bool { inspection.matches(keyword) || roomInspection?.matches(keyword) == true }
    static func combine(personal: [DormitoryInspection], rooms: [DormitoryInspection]) -> [DormitoryReport] {
        let roomGroups = Dictionary(grouping: rooms.filter { $0.correlationKey != nil }, by: { $0.correlationKey! })
        let personalGroups = Dictionary(grouping: personal.filter { $0.correlationKey != nil }, by: { $0.correlationKey! })
        var matched: Set<String> = []
        var result = personal.map { record in
            let room: DormitoryInspection?
            if let key = record.correlationKey, let candidates = roomGroups[key], candidates.count == 1, personalGroups[key]?.count == 1 {
                room = candidates[0]; matched.insert(candidates[0].id)
            } else { room = nil }
            return DormitoryReport(inspection: record, matchingRoom: room)
        }
        result += rooms.filter { !matched.contains($0.id) }.map { DormitoryReport(inspection: $0, matchingRoom: nil) }
        return result.sorted { a, b in
            a.inspection.date == b.inspection.date ? a.id < b.id : a.inspection.date > b.inspection.date
        }
    }
}

nonisolated struct DormitoryPage {
    let rows: [DormitoryInspection]
    let total, number, size: Int
}

nonisolated enum DormitoryResponseError: LocalizedError {
    case missingDataset, pagination, records, rejected, htmlPage, webVPNPage
    var errorDescription: String? {
        switch self {
        case .missingDataset: "学工响应中缺少寝室检查数据集，请在学校页面确认已登录后再点“继续查询”"
        case .pagination: "学工返回的分页字段格式异常，请重新加载后重试"
        case .records: "学工返回的检查记录格式异常，请在学校原始页面核对"
        case .rejected: "学工系统未接受本次查询，请在学校页面完成登录及初始化后再点“继续查询”"
        case .htmlPage: "学工查询接口返回了网页，请在学校页面完成认证后再点“继续查询”"
        case .webVPNPage: "WebVPN 返回了认证或站点密钥页面，请在学校页面完成跳转后再点“继续查询”"
        }
    }
}

nonisolated enum DormitoryParser {
    static func page(_ object: AcademicParser.Object, kind: DormitoryKind, requestedPage: Int = 1, requestedSize: Int = 50) throws -> DormitoryPage {
        if let code = object["code"], ["401", "403", "-1"].contains(String(describing: code)) { throw AcademicError.sessionExpired }
        guard object["success"] as? Bool != false else { throw DormitoryResponseError.rejected }
        guard let datasets = object["datas"] as? AcademicParser.Object,
              let result = datasets[kind.action] as? AcademicParser.Object else { throw DormitoryResponseError.missingDataset }
        // EMAP installations can encode pagination as numbers or decimal strings,
        // and can omit echoed request fields (especially for empty datasets).
        // The total remains mandatory; requested page/size are known inputs.
        let page = missing(result["pageNumber"]) ? requestedPage : integer(result["pageNumber"])
        let size = missing(result["pageSize"]) ? requestedSize : integer(result["pageSize"])
        guard let total = integer(result["totalSize"]), (0...5000).contains(total),
              let page, page > 0, let size, (1...100).contains(size) else { throw DormitoryResponseError.pagination }
        let rawRows: [AcademicParser.Object]
        if let rows = result["rows"] as? [AcademicParser.Object] { rawRows = rows }
        else if total == 0 && missing(result["rows"]) { rawRows = [] }
        else { throw DormitoryResponseError.records }
        guard rawRows.count <= size, rawRows.count <= total else { throw DormitoryResponseError.pagination }
        var seen: Set<String> = []
        let rows = try rawRows.map { row -> DormitoryInspection in
            let id = AcademicParser.text(row, "WID")
            guard !id.isEmpty, seen.insert(id).inserted else { throw AcademicError.incompletePages }
            // No student number, name, class, operator ID, attachment token or raw
            // payload is retained in the view model.
            return DormitoryInspection(id: id, building: AcademicParser.text(row, "SSLMC"), room: AcademicParser.text(row, "FJH"),
                date: AcademicParser.text(row, "JCRQ"), type: AcademicParser.text(row, "JCLXDM_DISPLAY"), week: AcademicParser.text(row, "ZC"),
                score: AcademicParser.text(row, kind == .room ? "FS" : "JCFS"), remark: AcademicParser.text(row, "BZ"), deductions: AcademicParser.text(row, "WGLXDM_DISPLAY"),
                year: AcademicParser.text(row, "XN"), semester: AcademicParser.text(row, "XQ"),
                yearLabel: AcademicParser.text(row, "XN_DISPLAY"), semesterLabel: AcademicParser.text(row, "XQ_DISPLAY"),
                hasAttachments: !AcademicParser.text(row, "FJ").isEmpty, kind: kind,
                batchID: AcademicParser.text(row, "JCBM"), dormitoryID: AcademicParser.text(row, "SSDM"), typeCode: AcademicParser.text(row, "JCLXDM"),
                roomScore: AcademicParser.text(row, kind == .room ? "FS" : "DZ_GGFS"),
                personalScore: kind == .personal ? AcademicParser.text(row, "DZ_GRFS") : "",
                totalScore: kind == .personal ? AcademicParser.text(row, "JCFS") : "")
        }
        return DormitoryPage(rows: rows, total: total, number: page, size: size)
    }
    private static func missing(_ value: Any?) -> Bool { value == nil || value is NSNull }
    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? String {
            let digits = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !digits.isEmpty, digits.count <= 6, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(digits)
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              abs(number.doubleValue) < 1_000_000 else { return nil }
        return number.intValue
    }
}

extension CampusClient {
    func dormitoryReports() async throws -> [DormitoryReport] {
        let personal = try await dormitory(.personal)
        let rooms = try await dormitory(.room)
        return DormitoryReport.combine(personal: personal, rooms: rooms)
    }
    func validateDormitorySession() async throws {
        for attempt in 0..<3 {
            do { _ = try await dormitory(.room, firstPageOnly: true); return }
            catch let error as DormitoryResponseError {
                switch error {
                case .missingDataset, .rejected:
                    guard attempt < 2 else { throw error }
                    try await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
                default: throw error
                }
            }
        }
        throw DormitoryResponseError.rejected
    }
    func dormitory(_ kind: DormitoryKind, firstPageOnly: Bool = false) async throws -> [DormitoryInspection] {
        guard service == .dormitory else { throw AcademicError.unsafeURL }
        let url = URL(string: service.origin(route) + kind.path)!
        var referer = URLComponents(url: service.entryURL(route), resolvingAgainstBaseURL: false)!
        referer.fragment = nil
        var rows: [DormitoryInspection] = [], ids: Set<String> = [], page = 1, total: Int?
        repeat {
            try Task.checkCancellation()
            let data = try await response(url, fields: ["pageSize": "50", "pageNumber": String(page)], referer: referer.url)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? AcademicParser.Object else { throw DormitoryResponseError.records }
            let result = try DormitoryParser.page(object, kind: kind, requestedPage: page, requestedSize: 50)
            guard result.number == page, total == nil || total == result.total,
                  rows.count + result.rows.count <= result.total,
                  result.rows.allSatisfy({ ids.insert($0.id).inserted }) else { throw AcademicError.incompletePages }
            total = result.total; rows += result.rows
            if firstPageOnly { return rows }
            if rows.count == result.total { break }
            // Some gateways cap each page below the requested size. Continue
            // non-empty pages until the checked total, rejecting duplicate IDs.
            guard !result.rows.isEmpty, page < 100 else { throw AcademicError.incompletePages }
            page += 1
        } while true
        return rows.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
}
