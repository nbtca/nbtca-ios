import Foundation

nonisolated struct CalendarEventSnapshot: Codable, Equatable, Sendable {
    let title: String
    let location: String
    let notes: String
    let start: Date
    let end: Date
    init(title: String, location: String, notes: String, start: Date, end: Date) {
        self.title = title; self.location = location; self.notes = notes; self.start = start; self.end = end
    }
    init(_ event: TimetableCalendarEvent) {
        self.init(title: event.title, location: event.location, notes: Self.notes(for: event), start: event.start, end: event.end)
    }
    static func notes(for course: TimetableCalendarEvent) -> String {
        [course.teacher.isEmpty ? "" : "教师：" + course.teacher,
         "第\(course.week)周，第\(course.startPeriod)–\(course.endPeriod)节"].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

nonisolated struct CalendarSyncDiff: Sendable {
    enum Kind: String, Sendable { case added = "新增", updated = "更新", removed = "失效" }
    struct Change: Identifiable, Sendable {
        let id: String
        let kind: Kind
        let event: CalendarEventSnapshot
    }
    let changes: [Change]
    var added: Int { changes.filter { $0.kind == .added }.count }
    var updated: Int { changes.filter { $0.kind == .updated }.count }
    var removed: Int { changes.filter { $0.kind == .removed }.count }
    var removedIDs: Set<String> { Set(changes.filter { $0.kind == .removed }.map(\.id)) }
    func removalIDs(confirmed: Bool, hasIssues: Bool) -> Set<String> {
        confirmed && !hasIssues ? removedIDs : []
    }
    init(desired: [String: CalendarEventSnapshot], existing: [String: CalendarEventSnapshot]) {
        var changes: [Change] = []
        for (id, event) in desired {
            if let old = existing[id] {
                if old != event { changes.append(Change(id: id, kind: .updated, event: event)) }
            } else { changes.append(Change(id: id, kind: .added, event: event)) }
        }
        for (id, event) in existing where desired[id] == nil { changes.append(Change(id: id, kind: .removed, event: event)) }
        self.changes = changes.sorted { ($0.event.start, $0.event.title, $0.id) < ($1.event.start, $1.event.title, $1.id) }
    }
}
