import XCTest
@testable import nbtca

@MainActor
final class TimetableTests: XCTestCase {
    private let term = AcademicTerm(year: "2026", semester: "3", yearLabel: "2026-2027", semesterLabel: "3", current: true)
    private func course(_ id: String = "A", name: String = "数学", day: Int = 2, start: Int = 1, end: Int = 2, weeks: [Int] = Array(1...18), location: String = "A101") -> AcademicCourse {
        AcademicCourse(id: id, name: name, teacher: "教师", location: location, weekText: "1-18周", periodText: "\(start)-\(end)", weekday: day, startPeriod: start, endPeriod: end, weeks: weeks, practice: false)
    }
    private func timetable(_ courses: [AcademicCourse]? = nil, dates: [AcademicCalendarDay] = [], anchor: String? = "2026-09-14") -> AcademicTimetable {
        AcademicTimetable(courses: courses ?? [course()], periods: [
            AcademicPeriod(number: 1, start: "08:00", end: "08:45"), AcademicPeriod(number: 2, start: "08:50", end: "09:35"),
            AcademicPeriod(number: 3, start: "09:50", end: "10:35"), AcademicPeriod(number: 4, start: "10:40", end: "11:25")],
            days: dates, unrecognizedCount: 0, weekOneMonday: anchor)
    }
    func testCurrentWeekUsesSchoolCalendarAndShanghaiTime() throws {
        let schedule = timetable()
        for value in ["2026-10-20 15:18", "2026-10-24 08:00", "2026-10-25 23:59"] {
            XCTAssertEqual(schedule.currentWeek(at: try XCTUnwrap(AcademicParser.dateTime(String(value.prefix(10)), String(value.suffix(5))))), 6)
        }
        XCTAssertEqual(schedule.currentWeek(at: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T16:00:00Z"))), 7)
        XCTAssertNil(schedule.currentWeek(at: try XCTUnwrap(AcademicParser.dateTime("2026-09-13", "23:59"))))
    }
    func testCurrentWeekDoesNotFallBackToWeekOneWhenCoursesAreEmpty() throws {
        let schedule = timetable([])
        XCTAssertEqual(schedule.maxWeek, 1)
        XCTAssertEqual(schedule.currentWeek(at: try XCTUnwrap(AcademicParser.dateTime("2026-10-20", "12:00"))), 6)
        XCTAssertEqual(schedule.date(week: 6, weekday: 2), "2026-10-20")
    }
    func testWeekendIsRecognizedFromTeachingDayWithoutTodayRow() throws {
        let schedule = timetable(dates: [AcademicCalendarDay(week: 6, weekday: 2, date: "2026-10-20")], anchor: nil)
        XCTAssertEqual(schedule.currentWeek(at: try XCTUnwrap(AcademicParser.dateTime("2026-10-25", "12:00"))), 6)
        XCTAssertNil(schedule.currentWeek(at: try XCTUnwrap(AcademicParser.dateTime("2026-10-26", "12:00"))))
    }
    func testCalendarDateWinsAndConflictingAnchorIsRejected() {
        let schedule = timetable(dates: [AcademicCalendarDay(week: 1, weekday: 2, date: "2026-09-15")], anchor: nil)
        XCTAssertEqual(schedule.date(week: 1, weekday: 2), "2026-09-15")
        XCTAssertNil(schedule.date(week: 2, weekday: 2))
        XCTAssertTrue(schedule.acceptsWeekOne("2026-09-14"))
        XCTAssertFalse(schedule.acceptsWeekOne("2026-09-07"))
        XCTAssertFalse(schedule.acceptsWeekOne("2026-09-15"))
    }
    func testConflictingBackendDayIsNotFilledFromFallbackCalendar() throws {
        let object: [String: Any] = ["xsxx": ["XNM":"2026", "XQM":"3"], "kbList": [], "rqazcList": [
            ["zc":"1", "xqj":"2", "rq":"2026-09-15"], ["zc":"1", "xqj":"2", "rq":"2026-09-22"]]]
        var schedule = try AcademicParser.timetable(object, term: term)
        schedule.weekOneMonday = "2026-09-14"
        XCTAssertNil(schedule.date(week: 1, weekday: 2))
    }
    func testSchoolFeedSelectsExactSemesterWithoutUsingAnotherYear() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20250915
        SUMMARY:秋季学期开始上课
        END:VEVENT
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20260914
        SUMMARY:秋季学期开始上
         课
        END:VEVENT
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20270301
        SUMMARY:春季学期开始上课
        END:VEVENT
        END:VCALENDAR
        """
        XCTAssertEqual(AcademicCalendarParser.weekOne(ics, term: term), "2026-09-14")
        XCTAssertEqual(AcademicCalendarParser.weekOne(ics.replacingOccurrences(of: "SUMMARY:秋季", with: "SUMMARY:[NBT] 秋季"), term: term), "2026-09-14")
        let spring = AcademicTerm(year: "2026", semester: "12", yearLabel: "2026-2027", semesterLabel: "12", current: true)
        XCTAssertEqual(AcademicCalendarParser.weekOne(ics, term: spring), "2027-03-01")
    }
    func testAmbiguousNonMondayOrCancelledSemesterMarkerIsRejected() {
        func event(_ date: String, extra: String = "") -> String {
            "BEGIN:VEVENT\nDTSTART;VALUE=DATE:\(date)\nSUMMARY:秋季学期开始上课\n\(extra)END:VEVENT\n"
        }
        XCTAssertNil(AcademicCalendarParser.weekOne(event("20260914") + event("20260921"), term: term))
        XCTAssertNil(AcademicCalendarParser.weekOne(event("20260915"), term: term))
        XCTAssertNil(AcademicCalendarParser.weekOne(event("20260914", extra: "STATUS:CANCELLED\n"), term: term))
    }
    func testGridUsesMergedPeriodSpansAndSeparatesOverlappingCourses() {
        let courses = [course("A", start: 1, end: 2), course("B", start: 2, end: 4), course("C", start: 4, end: 5), course("D", start: 6, end: 7)]
        let blocks = TimetableGridLayout.blocks(courses, week: 1)
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks.first { $0.id == "A" }?.start, 1)
        XCTAssertEqual(blocks.first { $0.id == "A" }?.end, 2)
        XCTAssertEqual(blocks.first { $0.id == "D" }?.laneCount, 1)
        for a in blocks {
            XCTAssertLessThan(a.lane, a.laneCount)
            for b in blocks where a.id != b.id && a.start <= b.end && b.start <= a.end {
                XCTAssertNotEqual(a.lane, b.lane)
                XCTAssertEqual(a.laneCount, b.laneCount)
            }
        }
    }
    func testGridFiltersByTeachingWeekAndWeekday() {
        let blocks = TimetableGridLayout.blocks([course("A", weeks: [1, 3]), course("B", day: 5, weeks: [2])], week: 2)
        XCTAssertEqual(blocks.map(\.id), ["B"])
        XCTAssertEqual(blocks.first?.weekday, 5)
    }
    func testExportExpandsOddWeeksWithActualBellTimes() throws {
        let plan = TimetableExportPlan(timetable: timetable([course(weeks: [1, 3])]), term: term)
        XCTAssertEqual(plan.events.count, 2)
        XCTAssertTrue(plan.issues.isEmpty)
        XCTAssertEqual(plan.events.map(\.week), [1, 3])
        XCTAssertEqual(plan.events.first?.start, AcademicParser.dateTime("2026-09-15", "08:00"))
        XCTAssertEqual(plan.events.first?.end, AcademicParser.dateTime("2026-09-15", "09:35"))
        XCTAssertEqual(plan.events.last?.start, AcademicParser.dateTime("2026-09-29", "08:00"))
        XCTAssertEqual(plan.events.first?.location, "A101")
    }
    func testExportNeverInventsMissingDatesOrTimes() {
        let noDate = TimetableExportPlan(timetable: timetable(anchor: nil), term: term)
        XCTAssertTrue(noDate.events.isEmpty)
        XCTAssertEqual(noDate.issues.first?.reason, "缺少上课日期")
        var noTime = timetable(); noTime.periods = []
        let noClock = TimetableExportPlan(timetable: noTime, term: term)
        XCTAssertTrue(noClock.events.isEmpty)
        XCTAssertEqual(noClock.issues.first?.reason, "缺少节次时间")
    }
    func testExportListsUnscheduledPracticeInsteadOfMakingAllDayEvents() {
        let pending = AcademicCourse(id: "practice", name: "实践", teacher: "", location: "", weekText: "17-18周", periodText: "", weekday: nil, startPeriod: nil, endPeriod: nil, weeks: [17, 18], practice: true)
        let plan = TimetableExportPlan(timetable: timetable([pending]), term: term)
        XCTAssertTrue(plan.events.isEmpty)
        XCTAssertEqual(plan.issues.first?.reason, "未排定时间")
    }
    func testRepeatedExportHasStableIdentityAcrossSourceReorderingAndRoomChanges() {
        let a = TimetableExportPlan(timetable: timetable([course("source-1", weeks: [1, 3])]), term: term)
        let b = TimetableExportPlan(timetable: timetable([course("source-99", weeks: [3, 1], location: "B202")]), term: term)
        XCTAssertEqual(a.events.map(\.id), b.events.map(\.id))
        XCTAssertEqual(Set(a.events.map(\.id)).count, 2)
        XCTAssertEqual(a.termKey, b.termKey)
        XCTAssertNotEqual(a.events.first?.location, b.events.first?.location)
    }
    func testDuplicateRowsExportOnceAndConflictingRowsRemainExcluded() {
        let a = course("A", weeks: [1]), b = course("B", weeks: [1]), c = course("C", weeks: [1], location: "B202")
        XCTAssertEqual(TimetableExportPlan(timetable: timetable([a, b]), term: term).events.count, 1)
        let conflict = TimetableExportPlan(timetable: timetable([a, c, b]), term: term)
        XCTAssertTrue(conflict.events.isEmpty)
        XCTAssertFalse(conflict.issues.isEmpty)
    }
}
