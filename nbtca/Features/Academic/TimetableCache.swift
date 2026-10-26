import Foundation
import Observation

nonisolated struct SavedTimetable: Codable, Identifiable, Sendable {
    let term: AcademicTerm
    let timetable: AcademicTimetable
    let savedAt: Date
    var id: String { term.id }
}

nonisolated struct UpcomingClasses: Sendable {
    let termID: String
    let events: [TimetableCalendarEvent]
    let minutesUntilStart: Int
}

nonisolated enum TimetableCacheError: LocalizedError {
    case invalidData
    var errorDescription: String? { "本地课表无法读取，请重新查询课表" }
}

@MainActor @Observable
final class TimetableCache {
    static let shared = TimetableCache()
    private(set) var entries: [SavedTimetable] = []
    private(set) var selectedTermID = ""
    private(set) var error: String?
    @ObservationIgnored private let directory: URL
    private var file: URL { directory.appendingPathComponent("timetables.json") }
    private struct Archive: Codable {
        let version: Int
        let selectedTermID: String
        let entries: [SavedTimetable]
    }
    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("Academic", isDirectory: true)) {
        self.directory = directory
        do {
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 4 * 1024 * 1024 else { throw TimetableCacheError.invalidData }
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
            guard archive.version == 1, archive.entries.count <= 20,
                  Set(archive.entries.map(\.id)).count == archive.entries.count,
                  archive.entries.allSatisfy({ Self.valid($0.timetable) }) else { throw TimetableCacheError.invalidData }
            entries = archive.entries.sorted { $0.savedAt > $1.savedAt }
            selectedTermID = entries.contains(where: { $0.id == archive.selectedTermID }) ? archive.selectedTermID : entries.first?.id ?? ""
        } catch { self.error = TimetableCacheError.invalidData.localizedDescription }
    }
    func saved(for termID: String) -> SavedTimetable? { entries.first { $0.id == termID } }
    func save(_ timetable: AcademicTimetable, term: AcademicTerm, at date: Date = Date()) throws {
        guard Self.valid(timetable) else { throw TimetableCacheError.invalidData }
        let saved = SavedTimetable(term: term, timetable: timetable, savedAt: date)
        let next = Array(([saved] + entries.filter { $0.id != term.id }).prefix(20))
        do { try write(next, selected: term.id) }
        catch { self.error = "课表未能保存：" + error.localizedDescription; throw error }
        entries = next; selectedTermID = term.id; error = nil
    }
    func select(_ termID: String) throws {
        guard termID != selectedTermID, entries.contains(where: { $0.id == termID }) else { return }
        try write(entries, selected: termID)
        selectedTermID = termID
    }
    func clear() throws {
        entries = []; selectedTermID = ""; error = nil
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    private func write(_ entries: [SavedTimetable], selected: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let data = try JSONEncoder().encode(Archive(version: 1, selectedTermID: selected, entries: entries))
        guard data.count <= 4 * 1024 * 1024 else { throw TimetableCacheError.invalidData }
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        try data.write(to: file, options: options)
    }
    /// Keep decoded disk data within the same bounds as parsed school data.
    private static func valid(_ timetable: AcademicTimetable) -> Bool {
        timetable.courses.count <= 1000 && timetable.days.count <= 420 && timetable.periods.count <= 99 &&
        timetable.courses.allSatisfy { course in
            !course.id.isEmpty && !course.name.isEmpty &&
            (course.weekday.map { (1...7).contains($0) } ?? true) &&
            (course.startPeriod.map { (1...99).contains($0) } ?? true) &&
            (course.endPeriod.map { (1...99).contains($0) } ?? true) &&
            (course.startPeriod == nil || course.endPeriod == nil || course.startPeriod! <= course.endPeriod!) &&
            course.weeks.allSatisfy { (1...60).contains($0) }
        } && Set(timetable.courses.map(\.id)).count == timetable.courses.count &&
        timetable.periods.allSatisfy { (1...99).contains($0.number) && AcademicParser.normalizeTime($0.start) == $0.start && AcademicParser.normalizeTime($0.end) == $0.end && $0.start < $0.end } &&
        Set(timetable.periods.map(\.number)).count == timetable.periods.count &&
        timetable.days.allSatisfy { day in
            (1...60).contains(day.week) && (1...7).contains(day.weekday) &&
            AcademicParser.dateTime(day.date, "00:00").map { AcademicParser.calendar.component(.weekday, from: $0) == day.weekday % 7 + 1 } == true
        } && (timetable.weekOneMonday.map { timetable.acceptsWeekOne($0) } ?? true)
    }
    func upcoming(at now: Date, within interval: TimeInterval = 30 * 60) -> UpcomingClasses? {
        guard interval > 0, interval.isFinite else { return nil }
        let end = now.addingTimeInterval(interval)
        var events: [TimetableCalendarEvent] = []
        var terms: [String: String] = [:]
        for saved in entries {
            var timetable = saved.timetable
            let weeks = Set([timetable.currentWeek(at: now), timetable.currentWeek(at: end)].compactMap { $0 })
            guard !weeks.isEmpty else { continue }
            // Expand only the weeks intersecting the short reminder window.
            timetable = AcademicTimetable(courses: timetable.courses.map { course in
                AcademicCourse(id: course.id, name: course.name, teacher: course.teacher, location: course.location,
                    weekText: course.weekText, periodText: course.periodText, weekday: course.weekday,
                    startPeriod: course.startPeriod, endPeriod: course.endPeriod,
                    weeks: course.weeks.filter { weeks.contains($0) }, practice: course.practice)
            }, periods: timetable.periods, days: timetable.days, unrecognizedCount: timetable.unrecognizedCount,
               weekOneMonday: timetable.weekOneMonday, unavailableDays: timetable.unavailableDays)
            let candidates = TimetableExportPlan(timetable: timetable, term: saved.term).events.filter { $0.start > now && $0.start <= end }
            for event in candidates { terms[event.id] = saved.term.id }
            events += candidates
        }
        guard let first = events.map(\.start).min() else { return nil }
        let next = events.filter { $0.start == first }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
        guard let event = next.first, let termID = terms[event.id] else { return nil }
        return UpcomingClasses(termID: termID, events: next, minutesUntilStart: max(1, Int(ceil(first.timeIntervalSince(now) / 60))))
    }
}
