import Foundation
import EventKit
import Observation

nonisolated enum TimetableCalendarError: LocalizedError {
    case permissionDenied, noCalendar, empty
    var errorDescription: String? {
        switch self {
        case .permissionDenied: "未获得日历访问权限，请在系统设置中允许访问日历"
        case .noCalendar: "没有可写入的日历账户"
        case .empty: "没有可导出的课程日程"
        }
    }
}

@MainActor @Observable
final class TimetableCalendarExporter {
    private let store = EKEventStore()
    private(set) var exporting = false
    private(set) var progress = 0
    private(set) var error: String?
    private(set) var completed = false
    private(set) var calendarTitle = ""
    private(set) var diff: CalendarSyncDiff?
    private(set) var checking = false
    private var managed: [String: EKEvent] = [:]
    private var preparedTerm: String?
    private func savedKey(_ plan: TimetableExportPlan) -> String { "academic.export.events.\(plan.termKey)" }
    func prepare(_ plan: TimetableExportPlan) async {
        guard !exporting, !checking else { return }
        checking = true; error = nil; diff = nil; preparedTerm = nil
        defer { checking = false }
        do {
            guard try await store.requestFullAccessToEvents() else { throw TimetableCalendarError.permissionDenied }
            try Task.checkCancellation()
            managed = [:]
            let key = "academic.export.calendar.\(plan.termKey)"
            if let id = UserDefaults.standard.string(forKey: key), let calendar = store.calendar(withIdentifier: id), calendar.allowsContentModifications {
                let saved = UserDefaults.standard.dictionary(forKey: savedKey(plan)) as? [String: String] ?? [:]
                for (courseID, eventID) in saved {
                    if let event = store.calendarItem(withIdentifier: eventID) as? EKEvent,
                       event.calendar?.calendarIdentifier == calendar.calendarIdentifier { managed[courseID] = event }
                }
            }
            let desired = Dictionary(uniqueKeysWithValues: plan.events.map { ($0.id, CalendarEventSnapshot($0)) })
            let existing = managed.mapValues { CalendarEventSnapshot(title: $0.title ?? "", location: $0.location ?? "",
                notes: $0.notes ?? "", start: $0.startDate, end: $0.endDate) }
            diff = CalendarSyncDiff(desired: desired, existing: existing); preparedTerm = plan.termKey
        } catch { self.error = error.localizedDescription }
    }
    func export(_ plan: TimetableExportPlan, removeObsolete: Bool = false) async {
        guard !exporting, !completed, preparedTerm == plan.termKey, let diff else { return }
        exporting = true; error = nil; progress = 0
        defer { exporting = false }
        do {
            let removals = diff.removalIDs(confirmed: removeObsolete, hasIssues: !plan.issues.isEmpty)
            guard !plan.events.isEmpty || !removals.isEmpty else { throw TimetableCalendarError.empty }
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw TimetableCalendarError.permissionDenied }
            let calendar = try destination(for: plan)
            calendarTitle = calendar.title
            var saved = UserDefaults.standard.dictionary(forKey: savedKey(plan)) as? [String: String] ?? [:]
            var written: [String: EKEvent] = [:]
            // Only stored identifiers in this app's target calendar can be removed.
            for id in removals {
                if let event = managed[id], event.calendar?.calendarIdentifier == calendar.calendarIdentifier {
                    try store.remove(event, span: .thisEvent, commit: false)
                    saved.removeValue(forKey: id)
                }
            }
            for (index, course) in plan.events.enumerated() {
                if index.isMultiple(of: 25) { await Task.yield(); try Task.checkCancellation() }
                let previous = managed[course.id]
                let event = previous?.calendar?.calendarIdentifier == calendar.calendarIdentifier ? previous! : EKEvent(eventStore: store)
                event.calendar = calendar; event.title = course.title; event.location = course.location
                event.startDate = course.start; event.endDate = course.end
                event.isAllDay = false; event.timeZone = AcademicParser.calendar.timeZone
                event.notes = CalendarEventSnapshot.notes(for: course)
                try store.save(event, span: .thisEvent, commit: false)
                written[course.id] = event; progress = index + 1
            }
            try Task.checkCancellation()
            try store.commit()
            for (id, event) in written { saved[id] = event.calendarItemIdentifier }
            UserDefaults.standard.set(saved, forKey: savedKey(plan))
            completed = true
        } catch {
            store.reset(); managed = [:]; self.diff = nil; preparedTerm = nil
            self.error = error.localizedDescription
        }
    }
    private func destination(for plan: TimetableExportPlan) throws -> EKCalendar {
        let key = "academic.export.calendar.\(plan.termKey)"
        if let id = UserDefaults.standard.string(forKey: key), let calendar = store.calendar(withIdentifier: id), calendar.allowsContentModifications { return calendar }
        let preferred = store.defaultCalendarForNewEvents?.source
        var sourceIDs: [String] = []
        if let preferred { sourceIDs.append(preferred.sourceIdentifier) }
        for source in store.sources where source.sourceType == .local || source.sourceType == .calDAV {
            if !sourceIDs.contains(source.sourceIdentifier) { sourceIDs.append(source.sourceIdentifier) }
        }
        var lastError: Error?
        for id in sourceIDs {
            guard let source = store.source(withIdentifier: id) else { continue }
            let calendar = EKCalendar(for: .event, eventStore: store)
            calendar.title = "课表 · " + plan.term.title; calendar.source = source
            do {
                try store.saveCalendar(calendar, commit: true)
                UserDefaults.standard.set(calendar.calendarIdentifier, forKey: key)
                return calendar
            } catch { lastError = error; store.reset() }
        }
        throw lastError ?? TimetableCalendarError.noCalendar
    }
}
