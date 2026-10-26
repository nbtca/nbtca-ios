import XCTest
@testable import nbtca

@MainActor
final class TimetableCacheTests: XCTestCase {
    private let term = AcademicTerm(year: "2026", semester: "3", yearLabel: "2026-2027", semesterLabel: "3", current: true)
    private let previous = AcademicTerm(year: "2025", semester: "3", yearLabel: "2025-2026", semesterLabel: "3", current: false)
    private func date(_ day: String, _ time: String) -> Date { AcademicParser.dateTime(day, time)! }
    private func date(_ time: String) -> Date { date("2026-10-21", time) }
    private func course(_ id: String = "A", name: String = "数学", day: Int = 3, start: Int = 1, weeks: [Int] = [6], room: String = "A101") -> AcademicCourse {
        AcademicCourse(id: id, name: name, teacher: "教师", location: room, weekText: "第6周", periodText: "1-2节",
                       weekday: day, startPeriod: start, endPeriod: start + 1, weeks: weeks, practice: false)
    }
    private func timetable(_ courses: [AcademicCourse]? = nil, days: [AcademicCalendarDay] = []) -> AcademicTimetable {
        AcademicTimetable(courses: courses ?? [course()], periods: [
            AcademicPeriod(number: 1, start: "08:00", end: "08:45"), AcademicPeriod(number: 2, start: "08:50", end: "09:35"),
            AcademicPeriod(number: 3, start: "09:50", end: "10:35"), AcademicPeriod(number: 4, start: "10:40", end: "11:25")],
            days: days, unrecognizedCount: 0, weekOneMonday: "2026-09-14")
    }
    private func withCache(_ body: (TimetableCache, URL) throws -> Void) rethrows {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("timetable-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(TimetableCache(directory: directory), directory)
    }
    func testRelaunchRestoresCompleteParsedTimetable() throws {
        try withCache { cache, directory in
            var schedule = timetable(days: [AcademicCalendarDay(week: 6, weekday: 3, date: "2026-10-21")])
            schedule.unavailableDays = ["6:4"]
            let savedAt = date("07:00")
            try cache.save(schedule, term: term, at: savedAt)
            let restored = TimetableCache(directory: directory)
            let entry = try XCTUnwrap(restored.saved(for: term.id))
            XCTAssertEqual(entry.term, term)
            XCTAssertEqual(entry.savedAt, savedAt)
            XCTAssertEqual(restored.selectedTermID, term.id)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            XCTAssertEqual(try encoder.encode(entry.timetable.courses), try encoder.encode(schedule.courses))
            XCTAssertEqual(entry.timetable.periods.map(\.start), schedule.periods.map(\.start))
            XCTAssertEqual(entry.timetable.days.first?.date, "2026-10-21")
            XCTAssertEqual(entry.timetable.weekOneMonday, schedule.weekOneMonday)
            XCTAssertEqual(entry.timetable.unavailableDays, ["6:4"])
            XCTAssertNil(restored.error)
        }
    }
    func testSavingAgainReplacesRemovedCoursesAndRoomChanges() throws {
        try withCache { cache, directory in
            try cache.save(timetable([course(), course("B", name: "物理")]), term: term)
            try cache.save(timetable([course(room: "B202")]), term: term)
            let restored = TimetableCache(directory: directory)
            XCTAssertEqual(restored.entries.count, 1)
            XCTAssertEqual(restored.entries.first?.timetable.courses.count, 1)
            XCTAssertEqual(restored.upcoming(at: date("07:45"))?.events.first?.location, "B202")
            try cache.save(timetable([]), term: term)
            XCTAssertNil(cache.upcoming(at: date("07:45")))
            XCTAssertTrue(TimetableCache(directory: directory).entries.first?.timetable.courses.isEmpty == true)
        }
    }
    func testTermSelectionPersistsWithoutReplacingOtherTerms() throws {
        try withCache { cache, directory in
            try cache.save(timetable(), term: term)
            try cache.save(timetable([]), term: previous)
            try cache.select(term.id)
            let restored = TimetableCache(directory: directory)
            XCTAssertEqual(restored.entries.count, 2)
            XCTAssertEqual(restored.selectedTermID, term.id)
            XCTAssertEqual(restored.saved(for: previous.id)?.timetable.courses.count, 0)
        }
    }
    func testCorruptOrUnsupportedArchiveDoesNotPublishPartialData() throws {
        try withCache { _, directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("timetables.json")
            for text in ["not json", "{\"version\":2,\"selectedTermID\":\"\",\"entries\":[]}"] {
                try Data(text.utf8).write(to: file)
                let restored = TimetableCache(directory: directory)
                XCTAssertTrue(restored.entries.isEmpty)
                XCTAssertNotNil(restored.error)
            }
        }
    }
    func testInvalidDatesAndPeriodsDoNotOverwriteSavedTimetable() throws {
        try withCache { cache, _ in
            try cache.save(timetable(), term: term)
            var invalid = timetable()
            invalid.periods = [AcademicPeriod(number: 1, start: "25:00", end: "26:00")]
            XCTAssertThrowsError(try cache.save(invalid, term: term))
            invalid = timetable()
            invalid.weekOneMonday = "2026-09-15"
            XCTAssertThrowsError(try cache.save(invalid, term: term))
            XCTAssertEqual(cache.saved(for: term.id)?.timetable.periods.first?.start, "08:00")
        }
    }
    func testFailedDiskWritePreservesExistingMemorySnapshot() throws {
        try withCache { cache, directory in
            try cache.save(timetable(), term: term)
            try FileManager.default.removeItem(at: directory)
            try Data("blocked".utf8).write(to: directory)
            XCTAssertThrowsError(try cache.save(timetable([]), term: term))
            XCTAssertEqual(cache.saved(for: term.id)?.timetable.courses.count, 1)
            XCTAssertNotNil(cache.error)
        }
    }
    func testOfflineStoreRestoresAndKeepsTimetableAcrossBackgrounding() throws {
        try withCache { cache, directory in
            try cache.save(timetable(), term: term)
            try cache.save(timetable([]), term: previous)
            try cache.select(term.id)
            let store = AcademicStore(cache: TimetableCache(directory: directory))
            XCTAssertFalse(store.hasSession)
            XCTAssertTrue(store.hasSavedTimetables)
            XCTAssertTrue(store.isUsingSavedTimetable)
            XCTAssertEqual(store.timetable?.courses.first?.name, "数学")
            store.showCurrentWeek(at: date("07:45"))
            XCTAssertEqual(store.week, 6)
            store.clearSensitiveRecords()
            XCTAssertEqual(store.timetable?.courses.count, 1)
            XCTAssertTrue(store.grades.isEmpty)
            XCTAssertTrue(store.exams.isEmpty)
            store.resume()
            store.selectedTermID = previous.id
            XCTAssertEqual(store.timetable?.courses.count, 0)
            XCTAssertEqual(store.week, 1)
            store.selectedTermID = term.id
            XCTAssertEqual(store.timetable?.courses.count, 1)
        }
    }
    func testLogoutClearsOfflineTimetableAndHomeReminder() throws {
        try withCache { cache, directory in
            try cache.save(timetable(), term: term)
            let store = AcademicStore(cache: cache)
            XCTAssertNotNil(cache.upcoming(at: date("07:45")))
            store.resetSession()
            XCTAssertNil(store.timetable)
            XCTAssertFalse(store.hasSavedTimetables)
            XCTAssertNil(cache.upcoming(at: date("07:45")))
            XCTAssertTrue(TimetableCache(directory: directory).entries.isEmpty)
        }
    }
    func testReminderWindowIncludesThirtyMinutesAndExcludesStartedClass() throws {
        try withCache { cache, _ in
            try cache.save(timetable(), term: term)
            XCTAssertNil(cache.upcoming(at: date("07:30").addingTimeInterval(-1)))
            XCTAssertEqual(cache.upcoming(at: date("07:30"))?.minutesUntilStart, 30)
            XCTAssertEqual(cache.upcoming(at: date("07:59").addingTimeInterval(1))?.minutesUntilStart, 1)
            XCTAssertNil(cache.upcoming(at: date("08:00")))
            XCTAssertNil(cache.upcoming(at: date("09:36")))
            XCTAssertNil(cache.upcoming(at: date("07:45"), within: 0))
            XCTAssertNil(cache.upcoming(at: date("07:45"), within: .infinity))
        }
    }
    func testEarliestCourseWinsAndSimultaneousCoursesAreKept() throws {
        try withCache { cache, _ in
            try cache.save(timetable([course(), course("B", name: "物理"), course("C", name: "化学", start: 3)]), term: term)
            let next = try XCTUnwrap(cache.upcoming(at: date("07:45")))
            XCTAssertEqual(Set(next.events.map(\.title)), ["数学", "物理"])
            XCTAssertEqual(next.events.first?.start, date("08:00"))
            XCTAssertEqual(cache.upcoming(at: date("09:30"))?.events.first?.title, "化学")
        }
    }
    func testOddWeeksAndNonTeachingDaysDoNotProduceReminders() throws {
        try withCache { cache, _ in
            try cache.save(timetable([course(weeks: [5, 7])]), term: term)
            XCTAssertNil(cache.upcoming(at: date("07:45")))
            XCTAssertNotNil(cache.upcoming(at: date("2026-10-28", "07:45")))
            var schedule = timetable()
            schedule.unavailableDays = ["6:3"]
            try cache.save(schedule, term: term)
            XCTAssertNil(cache.upcoming(at: date("07:45")))
        }
    }
    func testMissingCalendarOrBellTimeDoesNotInventReminder() throws {
        try withCache { cache, _ in
            var schedule = timetable()
            schedule.weekOneMonday = nil
            try cache.save(schedule, term: term)
            XCTAssertNil(cache.upcoming(at: date("07:45")))
            schedule = timetable()
            schedule.periods = []
            try cache.save(schedule, term: term)
            XCTAssertNil(cache.upcoming(at: date("07:45")))
        }
    }
    func testSundayNightReminderFindsMondayOfNextWeekInShanghai() throws {
        try withCache { cache, _ in
            var schedule = timetable([course(day: 1, weeks: [7])])
            schedule.periods = [AcademicPeriod(number: 1, start: "00:10", end: "00:55"), AcademicPeriod(number: 2, start: "01:00", end: "01:45")]
            try cache.save(schedule, term: term)
            let sunday = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T15:50:00Z"))
            let next = try XCTUnwrap(cache.upcoming(at: sunday))
            XCTAssertEqual(next.events.first?.week, 7)
            XCTAssertEqual(next.events.first?.start, date("2026-10-26", "00:10"))
            XCTAssertEqual(next.minutesUntilStart, 20)
        }
    }
    func testHistoricalTermSelectionDoesNotHideCurrentClass() throws {
        try withCache { cache, _ in
            try cache.save(timetable(), term: term)
            var history = timetable()
            history.weekOneMonday = "2025-09-15"
            try cache.save(history, term: previous)
            XCTAssertEqual(cache.selectedTermID, previous.id)
            XCTAssertEqual(cache.upcoming(at: date("07:45"))?.termID, term.id)
            XCTAssertEqual(cache.selectedTermID, previous.id)
        }
    }
}
