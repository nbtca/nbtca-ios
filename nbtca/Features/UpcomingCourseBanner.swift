import SwiftUI

struct UpcomingCourseBanner: View {
    @State private var cache = TimetableCache.shared
    var body: some View {
        TimelineView(.periodic(from: Calendar.current.startOfDay(for: Date()), by: 30)) { context in
            if let upcoming = cache.upcoming(at: context.date) {
                NavigationLink { AcademicView(initialKind: .timetable, initialTermID: upcoming.termID) } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("下一节课", systemImage: "calendar.badge.clock").font(.subheadline.weight(.medium)).foregroundStyle(Color.brand)
                            Spacer(minLength: 8)
                            Text("\(upcoming.minutesUntilStart) 分钟后").font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        ForEach(upcoming.events) { event in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(event.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 12) {
                                        time(event)
                                        if !event.location.isEmpty { Label(event.location, systemImage: "mappin.and.ellipse") }
                                    }
                                    VStack(alignment: .leading, spacing: 5) {
                                        time(event)
                                        if !event.location.isEmpty { Label(event.location, systemImage: "mappin.and.ellipse") }
                                    }
                                }.font(.subheadline).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain)
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)
                    .frame(maxWidth: AppLayout.gridMaxWidth)
                    .frame(maxWidth: .infinity)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func time(_ event: TimetableCalendarEvent) -> some View {
        Label(AppDate.display(event.start, format: "HH:mm") + "–" + AppDate.display(event.end, format: "HH:mm"), systemImage: "clock")
            .monospacedDigit()
    }
}
