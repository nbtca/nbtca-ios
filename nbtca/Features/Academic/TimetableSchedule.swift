import Foundation
import CryptoKit

extension AcademicTimetable {
    nonisolated func date(week: Int, weekday: Int) -> String? {
        guard (1...60).contains(week), (1...7).contains(weekday), !unavailableDays.contains("\(week):\(weekday)") else { return nil }
        let explicit = Set(days.filter { $0.week == week && $0.weekday == weekday }.map(\.date))
        if explicit.count == 1 { return explicit.first }
        guard explicit.isEmpty, let weekOneMonday, let start = AcademicParser.dateTime(weekOneMonday, "00:00"),
              let date = AcademicParser.calendar.date(byAdding: .day, value: (week - 1) * 7 + weekday - 1, to: start) else { return nil }
        return Self.dateString(date)
    }
    nonisolated var displayMaxWeek: Int { max(maxWeek, currentWeek() ?? 1) }
    nonisolated func currentWeek(at date: Date = Date()) -> Int? {
        let today = Self.dateString(date)
        let matching = Set(days.filter { $0.date == today }.map(\.week))
        if matching.count == 1 { return matching.first }
        if matching.count > 1 { return nil }
        // A known teaching day identifies its entire Monday–Sunday week, even
        // if the backend omitted today's row (for example, on weekends).
        let active = Set(days.compactMap { day -> Int? in
            guard let known = AcademicParser.dateTime(day.date, "00:00"),
                  let monday = AcademicParser.calendar.date(byAdding: .day, value: -(day.weekday - 1), to: known),
                  let end = AcademicParser.calendar.date(byAdding: .day, value: 7, to: monday), date >= monday, date < end else { return nil }
            return day.week
        })
        if active.count == 1 { return active.first }
        if active.count > 1 { return nil }
        guard let weekOneMonday, let start = AcademicParser.dateTime(weekOneMonday, "00:00") else { return nil }
        let offset = AcademicParser.calendar.dateComponents([.day], from: start, to: AcademicParser.calendar.startOfDay(for: date)).day ?? -1
        let week = offset >= 0 ? offset / 7 + 1 : 0
        return (1...60).contains(week) ? week : nil
    }
    nonisolated func acceptsWeekOne(_ value: String) -> Bool {
        guard let start = AcademicParser.dateTime(value, "00:00"), AcademicParser.calendar.component(.weekday, from: start) == 2 else { return false }
        return days.allSatisfy { day in
            guard let expected = AcademicParser.calendar.date(byAdding: .day, value: (day.week - 1) * 7 + day.weekday - 1, to: start) else { return false }
            return Self.dateString(expected) == day.date
        }
    }
    nonisolated static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = AcademicParser.calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

nonisolated enum AcademicCalendarParser {
    static func validMonday(_ value: String, term: AcademicTerm) -> Bool {
        guard let year = Int(term.year), ["3", "12"].contains(term.semester),
              let date = AcademicParser.dateTime(value, "00:00") else { return false }
        return AcademicParser.calendar.component(.weekday, from: date) == 2 &&
            AcademicParser.calendar.component(.year, from: date) == (term.semester == "3" ? year : year + 1)
    }
    /// The public school calendar used by Prompt / @nbtca/nbtcal. Only exact,
    /// all-day semester-start markers are used; other events are irrelevant.
    static func weekOne(_ ics: String, term: AcademicTerm) -> String? {
        guard let year = Int(term.year), let title = ["3": "秋季学期开始上课", "12": "春季学期开始上课"][term.semester] else { return nil }
        let targetYear = term.semester == "3" ? year : year + 1
        let unfolded = ics.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n ", with: "").replacingOccurrences(of: "\n\t", with: "")
        var values: [String: String] = [:], inside = false, dates: Set<String> = []
        for line in unfolded.components(separatedBy: "\n") {
            if line == "BEGIN:VEVENT" { inside = true; values = [:]; continue }
            if line == "END:VEVENT" {
                if inside, AcademicParser.replacing("^\\[[^\\]\r\n]+\\]\\s*", in: values["SUMMARY"] ?? "") == title, values["STATUS"] != "CANCELLED", values["RRULE"] == nil,
                   let raw = values["DTSTART;VALUE=DATE"], raw.count == 8, raw.allSatisfy(\.isNumber), raw.hasPrefix(String(targetYear)) {
                    let source = Array(raw)
                    let date = String(source[0..<4]) + "-" + String(source[4..<6]) + "-" + String(source[6..<8])
                    if let parsed = AcademicParser.dateTime(date, "00:00"), AcademicParser.calendar.component(.weekday, from: parsed) == 2 { dates.insert(date) }
                }
                inside = false; continue
            }
            guard inside, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]), value = String(line[line.index(after: colon)...])
            values[key] = value
        }
        return dates.count == 1 ? dates.first : nil
    }
}

/// Verified dates from the school's published calendar, limited to exact terms.
/// Remote calendar dates take precedence; unknown academic years stay unknown.
nonisolated enum VerifiedSchoolCalendar {
    private struct Archive: Decodable {
        let version: Int
        let terms: [Term]
    }
    private struct Term: Decodable {
        let year, semester, weekOneMonday: String
    }
    private static let archive: Archive? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "SchoolCalendar", withExtension: "json"),
              let data = try? Data(contentsOf: url), let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.version == 1 else { return nil }
        return archive
    }()
    static func weekOne(for term: AcademicTerm) -> String? {
        let matches = Set((archive?.terms ?? []).filter { $0.year == term.year && $0.semester == term.semester }.map(\.weekOneMonday))
        guard matches.count == 1, let value = matches.first, AcademicCalendarParser.validMonday(value, term: term) else { return nil }
        return value
    }
}

@MainActor
final class AcademicCalendarFeed {
    static let shared = AcademicCalendarFeed()
    private var text: String?
    private var request: Task<String?, Never>?
    private let defaults: UserDefaults
    private let fallback: (AcademicTerm) -> String?
    private let fetch: () async -> String?
    init(defaults: UserDefaults = .standard,
         fallback: @escaping (AcademicTerm) -> String? = { VerifiedSchoolCalendar.weekOne(for: $0) },
         fetch: @escaping () async -> String? = { await AcademicCalendarFeed.fetchRemote() }) {
        self.defaults = defaults; self.fallback = fallback; self.fetch = fetch
    }
    func weekOne(for term: AcademicTerm) async -> String? {
        let cacheKey = "academic.week-one.\(term.id)"
        if let text, let value = AcademicCalendarParser.weekOne(text, term: term) { return value }
        // Coalesce concurrent lookups, but let a later query retry a failed fetch.
        if request == nil {
            let fetch = fetch
            request = Task { @MainActor [weak self] in
                let value = await fetch()
                if let self {
                    self.text = value; self.request = nil
                    if let value, let monday = AcademicCalendarParser.weekOne(value, term: term) {
                        self.defaults.set(monday, forKey: cacheKey)
                    }
                }
                return value
            }
        }
        // A known date is immediately usable offline while the remote refresh runs.
        if let saved = defaults.string(forKey: cacheKey), AcademicCalendarParser.validMonday(saved, term: term) { return saved }
        if let saved = fallback(term), AcademicCalendarParser.validMonday(saved, term: term) { return saved }
        if let pending = request, let text = await pending.value,
           let value = AcademicCalendarParser.weekOne(text, term: term) {
            defaults.set(value, forKey: cacheKey); return value
        }
        return nil
    }
    private static func fetchRemote() async -> String? {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from: URL(string: "https://ical.nbtca.space/school.ics")!)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.scheme == "https", response.url?.host == "ical.nbtca.space", data.count <= 2 * 1024 * 1024 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }
}

nonisolated struct TimetableBlock: Identifiable {
    let course: AcademicCourse
    let weekday, start, end, lane, laneCount: Int
    var id: String { course.id }
}

nonisolated enum TimetableGridLayout {
    static func blocks(_ courses: [AcademicCourse], week: Int) -> [TimetableBlock] {
        var result: [TimetableBlock] = []
        for day in 1...7 {
            let daily = courses.filter { $0.hasTime && $0.weekday == day && $0.weeks.contains(week) }
                .sorted { ($0.startPeriod!, $0.endPeriod!, $0.id) < ($1.startPeriod!, $1.endPeriod!, $1.id) }
            var cluster: [(AcademicCourse, Int)] = [], laneEnds: [Int] = [], clusterEnd = 0
            func flush() {
                for (course, lane) in cluster { result.append(TimetableBlock(course: course, weekday: day, start: course.startPeriod!, end: course.endPeriod!, lane: lane, laneCount: laneEnds.count)) }
                cluster = []; laneEnds = []; clusterEnd = 0
            }
            for course in daily {
                let start = course.startPeriod!, end = course.endPeriod!
                if !cluster.isEmpty && start > clusterEnd { flush() }
                let lane = laneEnds.firstIndex(where: { $0 < start }) ?? laneEnds.count
                if lane == laneEnds.count { laneEnds.append(end) } else { laneEnds[lane] = end }
                cluster.append((course, lane)); clusterEnd = max(clusterEnd, end)
            }
            flush()
        }
        return result
    }
}

nonisolated struct TimetableCalendarEvent: Identifiable, Equatable, Sendable {
    let id, title, location, teacher: String
    let start, end: Date
    let week, startPeriod, endPeriod: Int
}
nonisolated struct TimetableExportIssue: Identifiable, Sendable {
    let id, course, reason: String
}
nonisolated struct TimetableExportPlan: Identifiable, Sendable {
    var id: String { termKey }
    let term: AcademicTerm
    let events: [TimetableCalendarEvent]
    let issues: [TimetableExportIssue]
    var termKey: String { Self.digest([term.year, term.semester]) }
    init(timetable: AcademicTimetable, term: AcademicTerm) {
        self.term = term
        var conflicted: Set<String> = []
        var events: [String: TimetableCalendarEvent] = [:], issues: [TimetableExportIssue] = []
        for course in timetable.courses {
            guard course.hasTime, let weekday = course.weekday, let first = course.startPeriod, let last = course.endPeriod else {
                issues.append(TimetableExportIssue(id: course.id, course: course.name, reason: "未排定时间")); continue
            }
            guard let begin = timetable.periods.first(where: { $0.number == first })?.start,
                  let finish = timetable.periods.first(where: { $0.number == last })?.end else {
                issues.append(TimetableExportIssue(id: course.id, course: course.name, reason: "缺少节次时间")); continue
            }
            var missingDate = false, invalidTime = false
            for week in Set(course.weeks).sorted() {
                guard let day = timetable.date(week: week, weekday: weekday) else { missingDate = true; continue }
                guard let start = AcademicParser.dateTime(day, begin), let end = AcademicParser.dateTime(day, finish), end > start else { invalidTime = true; continue }
                let id = Self.digest([term.year, term.semester, course.name, course.teacher, day, String(first), String(last)])
                let event = TimetableCalendarEvent(id: id, title: course.name, location: course.location, teacher: course.teacher, start: start, end: end, week: week, startPeriod: first, endPeriod: last)
                if conflicted.contains(id) { invalidTime = true; continue }
                if let previous = events[id], previous != event {
                    invalidTime = true; events.removeValue(forKey: id); conflicted.insert(id)
                } else { events[id] = event }
            }
            if missingDate || invalidTime { issues.append(TimetableExportIssue(id: course.id, course: course.name, reason: invalidTime ? "日期或时间冲突" : "缺少上课日期")) }
        }
        self.events = events.values.sorted { ($0.start, $0.title, $0.id) < ($1.start, $1.title, $1.id) }
        self.issues = issues
    }
    static func digest(_ fields: [String]) -> String {
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
