import Foundation

typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String, default fallback: String = "") -> String {
        guard let value = self[key], !(value is NSNull) else { return fallback }
        return value as? String ?? String(describing: value)
    }
    func objects(_ key: String) -> [JSONObject] { self[key] as? [JSONObject] ?? [] }
    func strings(_ key: String) -> [String] { self[key] as? [String] ?? [] }
}

struct NewsArticle: Identifiable, Codable {
    let id, title, category, published, author, summary, coverURL, articleURL, markdown: String
    let tags: [String]
    init(_ json: JSONObject) {
        id = json.string("id"); title = json.string("title")
        category = json.string("category", default: "资讯"); published = json.string("published")
        author = json.string("author", default: "NBTCA"); summary = json.string("summary")
        coverURL = json.string("cover_url"); articleURL = json.string("article_url")
        markdown = json.string("content_markdown"); tags = json.strings("tags")
    }
}

struct NewsFeed {
    let featured, recent: [NewsArticle]
    var all: [NewsArticle] {
        var seen = Set<String>()
        return (featured + recent).filter { seen.insert($0.id).inserted }
    }
    var categories: [String] { Array(Set(all.map(\.category))).sorted() }
    init(_ json: JSONObject) {
        featured = json.objects("featured").map { NewsArticle($0) }
        recent = json.objects("recent").map { NewsArticle($0) }
    }
}

struct AssociationEvent: Identifiable {
    let id, title, description, url: String
    let start, end: Date?
    let allDay: Bool
    init(_ json: JSONObject) {
        id = json.string("id"); title = json.string("title")
        description = json.string("description"); url = json.string("url")
        start = AppDate.parse(json.string("start")); end = AppDate.parse(json.string("end"))
        allDay = json["all_day"] as? Bool ?? false
    }
    var timeLabel: String {
        guard let start else { return "时间待定" }
        if allDay { return AppDate.display(start, format: "M月d日 EEEE") + " · 全天" }
        var label = AppDate.display(start, format: "M月d日 EEEE HH:mm")
        if let end { label += " – " + AppDate.display(end, format: AppDate.sameDay(start, end) ? "HH:mm" : "M月d日 HH:mm") }
        return label
    }
}

struct AssociationCalendar {
    let name, updated: String
    let events: [AssociationEvent]
    init(_ json: JSONObject) {
        name = json.string("name", default: "协会活动日历"); updated = json.string("updated")
        events = json.objects("events").map { AssociationEvent($0) }
    }
}

struct ServiceStatus {
    let state, message: String
    let updated: Double
    let groups: [ServiceGroup]
    let incidents: [ServiceIncident]
    init(_ json: JSONObject) {
        state = json.string("state", default: "unknown"); message = json.string("message")
        updated = json["updated"] as? Double ?? 0
        groups = json.objects("groups").map { ServiceGroup($0) }
        incidents = json.objects("incidents").map { ServiceIncident($0) }
    }
    var total: Int { groups.reduce(0) { $0 + $1.components.count } }
    var healthy: Int { groups.reduce(0) { $0 + $1.components.filter { $0.state == "operational" }.count } }
    static func label(_ state: String) -> String {
        switch state {
        case "operational": "运行正常"
        case "degraded", "partial": "部分异常"
        case "major", "down", "offline": "服务故障"
        default: "状态未知"
        }
    }
}
struct ServiceGroup: Identifiable {
    var id: String { name }
    let name: String
    let components: [ServiceComponent]
    init(_ json: JSONObject) { name = json.string("name"); components = json.objects("components").map { ServiceComponent($0) } }
}
struct ServiceComponent: Identifiable {
    let id, name, state, error: String
    let failed: [String]
    init(_ json: JSONObject) {
        id = json.string("id"); name = json.string("name"); state = json.string("state", default: "unknown")
        error = json.string("error"); failed = json.strings("failed")
    }
}
struct ServiceIncident: Identifiable {
    var id: String { title + updated }
    let title, impact, updated: String
    init(_ json: JSONObject) {
        title = json.string("title"); impact = json.string("impact")
        updated = json.string("updatedAt", default: json.string("updated_at"))
    }
}

struct RepairTicket: Identifiable {
    let id, model, problem, status, clientID, phone, qq, size, memberID, memberName, closedByName: String
    let created, modified: Date?
    let photos: [String]
    let logs: [TicketLog]
    var title: String { problem.split(separator: "\n").first.map(String.init) ?? model }
    var isOpen: Bool { ["open", "pending"].contains(status) }
    var isAccepted: Bool { ["accepted", "repairing"].contains(status) }
    var isCommitted: Bool { status == "committed" }
    var isClosed: Bool { ["closed", "completed"].contains(status) }
    var canonicalStatus: String {
        switch status {
        case "pending": "open"
        case "repairing": "accepted"
        case "completed": "closed"
        case "canceled": "cancelled"
        default: status
        }
    }
    func matchesStatus(_ filter: String) -> Bool { filter == "all" || canonicalStatus == filter }
    var statusName: String { Self.statusName(status) }
    static func statusName(_ status: String) -> String {
        switch status {
        case "open", "pending": "待受理"
        case "accepted", "repairing": "维修中"
        case "committed": "待审核"
        case "closed", "completed": "已完成"
        case "cancelled", "canceled": "已取消"
        default: "处理中"
        }
    }
    init(_ json: JSONObject) {
        id = json.string("eventId", default: json.string("id")); model = json.string("model", default: "设备")
        problem = json.string("problem", default: json.string("description")); status = json.string("status", default: "open").lowercased()
        clientID = json.string("clientId", default: json.string("client_id"))
        phone = json.string("phone", default: json.string("contact")); qq = json.string("qq"); size = json.string("size")
        let member = json["member"] as? JSONObject ?? [:]
        memberID = member.string("memberId", default: json.string("memberId"))
        memberName = member.string("alias", default: member.string("name", default: json.string("memberName")))
        let closed = json["closedBy"] as? JSONObject ?? [:]
        closedByName = closed.string("alias", default: closed.string("name"))
        created = AppDate.parse(json.string("gmtCreate", default: json.string("created_at")))
        modified = AppDate.parse(json.string("gmtModified", default: json.string("updated_at"))) ?? created
        photos = (json["photos"] as? [Any] ?? []).compactMap { value in
            if let string = value as? String { return string.isEmpty ? nil : string }
            return (value as? JSONObject)?["url"] as? String
        }
        logs = json.objects("logs").map { TicketLog($0) }
    }
}
struct TicketLog: Identifiable {
    var id: String { action + detail + (date?.description ?? "") + operatorID }
    let action, detail, operatorID: String
    let date: Date?
    var title: String {
        switch action {
        case "create": "工单已提交"
        case "accept": "维修部已接单"
        case "commit": "维修报告已提交"
        case "close": "工单已结单"
        case "drop": "技术员已放弃工单"
        case "reject": "报告已退回"
        case "cancel": "工单已取消"
        case "alter": "工单已更新"
        default: action
        }
    }
    init(_ json: JSONObject) {
        action = json.string("action"); detail = json.string("description"); operatorID = json.string("memberId")
        date = AppDate.parse(json.string("gmtCreate"))
    }
}

struct Diagnosis {
    let source, summary: String
    let causes, steps, tools: [String]
    init(_ json: JSONObject) {
        source = json.string("source"); summary = json.string("summary")
        causes = json.strings("possible_causes"); steps = json.strings("self_help_steps"); tools = json.strings("recommended_tools")
    }
}

struct UserProfile: Codable {
    let sub, name, email, avatar, memberID: String
    let roles: [String]
    var isAdmin: Bool { hasRole(["repair admin", "repair-admin", "repair administrator", "dev admin", "dev-admin", "devadmin", "developer admin", "admin"]) }
    var isStaff: Bool { isAdmin || hasRole(["repair member", "repair-member", "repair staff", "technician", "member"]) }
    private func hasRole(_ candidates: Set<String>) -> Bool {
        roles.contains { candidates.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
    }
    init(info: JSONObject, member: JSONObject) throws {
        sub = info.string("sub", default: member.string("memberId"))
        guard !sub.isEmpty else { throw APIError(message: "身份服务未返回用户标识") }
        name = info.string("name", default: info.string("username", default: member.string("alias", default: sub)))
        email = info.string("email"); avatar = info.string("picture", default: member.string("avatar"))
        memberID = member.string("memberId")
        var roles = info.strings("roles")
        switch member.string("role").lowercased() {
        case "admin": roles += ["Repair Admin", "Repair Member"]
        case "member": roles += ["Repair Member"]
        default: break
        }
        self.roles = Array(Set(roles)).sorted()
    }
}

struct APIError: LocalizedError {
    let message: String
    var status: Int? = nil
    var errorDescription: String? { message }
}

enum AppDate {
    static func sameDay(_ first: Date, _ second: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.isDate(first, inSameDayAs: second)
    }
    static func parse(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) { return date }
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
    static func display(_ date: Date, format: String = "yyyy年M月d日 HH:mm") -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
