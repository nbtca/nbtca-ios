import SwiftUI

enum FavoriteShortcut: String, CaseIterable, Identifiable {
    case timetable, exams, grades, repairs, dormitory
    var id: String { rawValue }
    var title: String {
        switch self {
        case .timetable: "我的课表"
        case .exams: "考试安排"
        case .grades: "成绩查询"
        case .repairs: "维修记录"
        case .dormitory: "寝室文明"
        }
    }
    var symbol: String {
        switch self {
        case .timetable: "calendar"
        case .exams: "pencil.and.list.clipboard"
        case .grades: "chart.bar.doc.horizontal"
        case .repairs: "wrench.and.screwdriver"
        case .dormitory: "building.2.crop.circle"
        }
    }
    @ViewBuilder var destination: some View {
        switch self {
        case .timetable: AcademicView()
        case .exams: AcademicView(initialKind: .exams)
        case .grades: AcademicView(initialKind: .grades)
        case .repairs: RepairHomeView()
        case .dormitory: DormitoryView()
        }
    }
}

struct FavoriteShortcuts: View {
    @AppStorage("home.shortcuts") private var saved = "timetable,exams,repairs"
    private var favorites: [FavoriteShortcut] { saved.split(separator: ",").compactMap { FavoriteShortcut(rawValue: String($0)) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("常用入口").font(.subheadline.bold())
                Spacer()
                Menu {
                    ForEach(FavoriteShortcut.allCases) { item in
                        Toggle(item.title, isOn: Binding(get: { favorites.contains(item) }, set: { selected in
                            var values = favorites.filter { $0 != item }
                            if selected { values.append(item) }
                            saved = values.map(\.rawValue).joined(separator: ",")
                        }))
                    }
                } label: { Label("编辑", systemImage: "slider.horizontal.3").font(.caption) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { links }
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 10) { links } }
            }
            if favorites.isEmpty { Text("点按编辑，固定常用功能").font(.caption).foregroundStyle(.secondary) }
        }.padding(.horizontal, 20).padding(.vertical, 8)
            .frame(maxWidth: AppLayout.gridMaxWidth).frame(maxWidth: .infinity)
    }
    private var links: some View {
        ForEach(favorites) { item in
            NavigationLink { item.destination } label: {
                Label(item.title, systemImage: item.symbol).font(.subheadline)
                    .padding(.horizontal, 12).padding(.vertical, 10).background(Color.card, in: Capsule())
            }.buttonStyle(.plain)
        }
    }
}
