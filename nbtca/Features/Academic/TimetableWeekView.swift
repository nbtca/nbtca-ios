import SwiftUI

struct TimetableWeekView: View {
    let timetable: AcademicTimetable
    let week: Int
    let courses: [AcademicCourse]
    @ScaledMetric(relativeTo: .caption) private var rowHeight = 64.0
    @State private var selection: AcademicCourse?
    private let axisWidth = 38.0
    private let headerHeight = 48.0
    private var periodCount: Int {
        let lastPeriod: Int = timetable.periods.map(\.number).max() ?? 0
        let lastCoursePeriod: Int = timetable.courses.compactMap(\.endPeriod).max() ?? 0
        return max(12, lastPeriod, lastCoursePeriod)
    }
    private var blocks: [TimetableBlock] { TimetableGridLayout.blocks(courses, week: week) }
    private static let weekdayTitles = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    private static let weekdayNames = ["一", "二", "三", "四", "五", "六", "日"]
    var body: some View {
        GeometryReader { geometry in
            grid(columnWidth: max(1, (geometry.size.width - axisWidth) / 7))
        }.frame(height: headerHeight + Double(periodCount) * rowHeight)
        .sheet(item: $selection) { course in detail(course) }
    }
    private func grid(columnWidth: Double) -> some View {
        ZStack(alignment: .topLeading) {
            gridLines(columnWidth: columnWidth)
            dayHeaders(columnWidth: columnWidth)
            periodAxis
            ForEach(blocks) { block in blockButton(block, columnWidth: columnWidth) }
        }.background(Color.card).clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private func gridLines(columnWidth: Double) -> some View {
        Canvas { context, size in
            var lines = Path()
            for column in 0...7 {
                let x = axisWidth + Double(column) * columnWidth
                lines.move(to: CGPoint(x: x, y: 0)); lines.addLine(to: CGPoint(x: x, y: size.height))
            }
            for row in 0...periodCount {
                let y = headerHeight + Double(row) * rowHeight
                lines.move(to: CGPoint(x: 0, y: y)); lines.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(lines, with: .color(Color.secondary.opacity(0.16)), lineWidth: 0.5)
        }
    }
    private func dayHeaders(columnWidth: Double) -> some View {
        HStack(spacing: 0) {
            Text("节次").font(.caption2).foregroundStyle(.secondary).frame(width: axisWidth, height: headerHeight)
            ForEach(1...7, id: \.self) { day in dayHeader(day, columnWidth: columnWidth) }
        }
    }
    private func dayHeader(_ day: Int, columnWidth: Double) -> some View {
        let date = timetable.date(week: week, weekday: day)
        let today = date == AcademicTimetable.dateString(Date())
        let label: String = "星期" + Self.weekdayNames[day - 1] + (date.map { "，" + $0 } ?? "")
        return VStack(spacing: 4) {
            Text(Self.weekdayTitles[day - 1]).font(.caption.bold())
            if let date { Text(String(date.suffix(5)).replacingOccurrences(of: "-", with: "/")).font(.system(size: 9)).monospacedDigit() }
        }.foregroundStyle(today ? Color.brand : .primary)
            .frame(width: columnWidth, height: headerHeight)
            .background(today ? Color.brand.opacity(0.10) : .clear)
            .accessibilityLabel(label)
    }
    private var periodAxis: some View {
        ForEach(1...periodCount, id: \.self) { number in
            VStack(spacing: 3) {
                Text("\(number)").font(.caption.bold()).monospacedDigit()
                if let period = timetable.periods.first(where: { $0.number == number }) {
                    Text(period.start + "\n" + period.end).font(.system(size: 8)).monospacedDigit().foregroundStyle(.secondary)
                }
            }.frame(width: axisWidth, height: rowHeight)
                .offset(y: headerHeight + Double(number - 1) * rowHeight)
        }
    }
    private func blockButton(_ block: TimetableBlock, columnWidth: Double) -> some View {
        let width = columnWidth / Double(block.laneCount)
        let height = Double(block.end - block.start + 1) * rowHeight
        let color = courseColor(block.course.name)
        let label = "星期\(block.weekday)，第\(block.start)至\(block.end)节，\(block.course.name)，\(block.course.location)，\(block.course.teacher)"
        let x: Double = axisWidth + Double(block.weekday - 1) * columnWidth + Double(block.lane) * width + 2
        let y: Double = headerHeight + Double(block.start - 1) * rowHeight + 2
        return Button { selection = block.course } label: {
            blockLabel(block, columnWidth: columnWidth, width: width, height: height, color: color)
        }.buttonStyle(.plain)
            .accessibilityLabel(label)
            .offset(x: x, y: y)
    }
    private func blockLabel(_ block: TimetableBlock, columnWidth: Double, width: Double, height: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(block.course.name).font(.system(size: columnWidth < 70 ? 11 : 14, weight: .semibold))
                .lineLimit(max(2, Int(height / 18) - 2))
            if !block.course.location.isEmpty { Text(block.course.location).font(.system(size: columnWidth < 70 ? 9 : 11)).lineLimit(2) }
            if columnWidth >= 80, !block.course.teacher.isEmpty { Text(block.course.teacher).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
            Spacer(minLength: 0)
        }.foregroundStyle(.primary).padding(columnWidth < 70 ? 4 : 8)
            .frame(width: max(1, width - 4), height: max(1, height - 4), alignment: .topLeading)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 2).padding(.vertical, 5) }
            .clipped()
    }
    private func detail(_ course: AcademicCourse) -> some View {
        NavigationStack {
            Form {
                Section { Text(course.name).font(.headline) }
                Section {
                    if !course.teacher.isEmpty { LabeledContent("教师", value: course.teacher) }
                    if !course.location.isEmpty { LabeledContent("地点", value: course.location) }
                    LabeledContent("节次", value: course.periodText)
                    if let time = timetable.time(for: course) { LabeledContent("时间", value: time) }
                    if !course.weekText.isEmpty { LabeledContent("教学周", value: course.weekText) }
                }
            }.navigationTitle("课程").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { selection = nil } } }
        }.presentationSizing(.form).presentationDetents([.medium, .large])
    }
    private func courseColor(_ name: String) -> Color {
        let index = name.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 6 }
        return [Color.blue, .indigo, .teal, .orange, .purple, .pink][index]
    }
}
