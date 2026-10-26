import SwiftUI

struct TodayCoursesView: View {
    let timetable: AcademicTimetable
    let courses: [AcademicCourse]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let today = timetable.courses(on: context.date, from: courses)
            let weekday = (AcademicParser.calendar.component(.weekday, from: context.date) + 5) % 7 + 1
            let calendarDate = timetable.currentWeek(at: context.date).flatMap { timetable.date(week: $0, weekday: weekday) }
            VStack(alignment: .leading, spacing: 14) {
                Text(AppDate.display(context.date, format: "M月d日 EEEE")).font(.headline)
                if calendarDate != AcademicTimetable.dateString(context.date) {
                    NoticeView(message: "缺少当前日期对应的校历，暂时无法确定今日课程")
                } else if today.isEmpty {
                    ContentUnavailableView("今日暂无匹配课程", systemImage: "calendar")
                }
                ForEach(today) { course in
                    Card {
                        Text(course.name).font(.title3.bold())
                        Label(timetable.time(for: course) ?? course.periodText, systemImage: "clock").font(.body)
                        if !course.location.isEmpty { Label(course.location, systemImage: "mappin.and.ellipse") }
                        if !course.teacher.isEmpty { Label(course.teacher, systemImage: "person") }
                    }.accessibilityElement(children: .combine)
                }
            }
        }
    }
}
