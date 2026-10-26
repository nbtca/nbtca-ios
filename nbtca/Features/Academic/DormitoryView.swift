import SwiftUI

struct DormitoryView: View {
    @State private var network = CampusNetwork.shared
    @State private var store = DormitoryStore()
    @State private var loginRoute: CampusRoute?
    @State private var showLogin = false
    @State private var showLogout = false
    @State private var year = ""
    @State private var semester = ""
    @State private var keyword = ""
    @State private var selectedReport: DormitoryReport?
    @Environment(\.scenePhase) private var scenePhase
    private var years: [String] { Array(Set(store.records.map(\.inspection.year).filter { !$0.isEmpty })).sorted(by: >) }
    private var semesters: [String] { Array(Set(store.records.filter { year.isEmpty || $0.inspection.year == year }.map(\.inspection.semester).filter { !$0.isEmpty })).sorted() }
    private var filtered: [DormitoryReport] {
        store.records.filter { (year.isEmpty || $0.inspection.year == year) && (semester.isEmpty || $0.inspection.semester == semester) && $0.matches(keyword) }
    }
    var body: some View {
        AdaptivePage { columns in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Card {
                        HStack {
                            Label(network.route?.title ?? "网络未连接", systemImage: network.route == .campus ? "wifi" : "network").font(.headline)
                            Spacer()
                            Menu {
                                Picker("访问线路", selection: Binding(get: { network.mode }, set: { network.selectMode($0) })) {
                                    ForEach(CampusNetwork.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                                }
                                Button("重新检测", systemImage: "arrow.clockwise") { network.recheck() }
                            } label: { Label("线路", systemImage: "arrow.triangle.branch") }
                        }
                    }
                    if let error = store.error { NoticeView(message: error) }
                    if let notice = store.sessionNotice { NoticeView(message: notice) }
                    if network.checking || store.validating {
                        ProgressView(network.checking ? "正在检测校园线路…" : "正在校验学工登录…").frame(maxWidth: .infinity).padding(30)
                    } else if network.route == nil {
                        ContentUnavailableView("暂时无法连接", systemImage: "wifi.slash")
                    } else if !store.hasSession {
                        Card {
                            Label("登录学工系统", systemImage: "building.2.crop.circle").font(.title3.bold())
                            Button("登录寝室文明查询") { loginRoute = network.route; showLogin = true }.buttonStyle(.borderedProminent)
                            if store.hasRememberedSession {
                                Button("重试已保存的登录") { Task { await store.activate(network.route) } }
                            }
                        }
                    } else {
                        if store.loading { ProgressView("正在查询检查记录…").frame(maxWidth: .infinity).padding(30) }
                        else if store.error != nil {
                            Button("重新查询") { Task { await store.reload() } }.buttonStyle(.bordered)
                        } else {
                            filters
                            SectionHeading(title: "检查记录", detail: "\(filtered.count) 条")
                            if filtered.isEmpty {
                                ContentUnavailableView("暂无匹配的检查记录", systemImage: "checklist")
                            }
                            LazyVGrid(columns: AppLayout.columns(columns), alignment: .leading, spacing: 18) {
                                ForEach(filtered) { report in
                                    Button { selectedReport = report } label: {
                                        inspectionCard(report)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if let route = network.route {
                        Link(destination: CampusService.dormitory.entryURL(route)) {
                            Label("查看学校原始查询页", systemImage: "safari")
                        }.font(.subheadline).padding(.vertical, 8)
                    }
                }.pageContent(maxWidth: AppLayout.gridMaxWidth)
            }.refreshable {
                if store.hasSession { await store.reload() } else { await store.activate(network.route) }
                network.recheck()
            }
        }
        .background(Color.canvas).navigationTitle("寝室文明查询").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $keyword, prompt: "搜索日期、寝室、分数或扣分说明")
        .toolbar {
            if store.hasSession || store.hasRememberedSession {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("退出学校登录", systemImage: "power") { showLogout = true }
                        .labelStyle(.iconOnly)
                }
            }
        }
        .onAppear { store.resume(); network.start() }
        .onDisappear { store.clearSensitiveRecords() }
        .task(id: "\(network.route?.rawValue ?? "offline")|\(CampusSchoolSession.shared.revision)") { await store.activate(network.route) }
        .task(id: store.queryKey) { await store.reload() }
        .onChange(of: year) { _, _ in semester = "" }
        .onChange(of: store.records) { _, records in
            if !year.isEmpty && !records.contains(where: { $0.inspection.year == year }) { year = "" }
            if !semester.isEmpty && !records.contains(where: { $0.inspection.semester == semester && (year.isEmpty || $0.inspection.year == year) }) { semester = "" }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.resume(); network.recheck() }
            if phase == .background { selectedReport = nil; store.clearSensitiveRecords() }
        }
        .sheet(isPresented: $showLogin) { if let loginRoute { CampusLoginView(route: loginRoute, service: .dormitory, dormitoryStore: store) } }
        .sheet(item: $selectedReport) { report in
            NavigationStack {
                DormitoryInspectionView(report: report)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("关闭") { selectedReport = nil } }
                    }
            }.presentationSizing(.page)
        }
        .confirmationDialog("退出学校登录并清除保存的登录状态和查询结果？", isPresented: $showLogout, titleVisibility: .visible) {
            Button("退出学校登录", role: .destructive) { Task { await store.logout() } }
        }
    }
    private var filters: some View {
        HStack {
            Picker("学年", selection: $year) {
                Text("全部学年").tag("")
                ForEach(years, id: \.self) { value in
                    Text(store.records.first(where: { $0.inspection.year == value })?.inspection.yearLabel.nonEmpty ?? value).tag(value)
                }
            }
            Spacer(minLength: 8)
            Picker("学期", selection: $semester) {
                Text("全部学期").tag("")
                ForEach(semesters, id: \.self) { value in
                    Text(store.records.first(where: { $0.inspection.semester == value })?.inspection.semesterLabel.nonEmpty ?? value).tag(value)
                }
            }
        }.pickerStyle(.menu).font(.subheadline)
    }
    private func inspectionCard(_ report: DormitoryReport) -> some View {
        let record = report.inspection
        return Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.date.isEmpty ? "检查日期未公布" : record.date).font(.headline)
                    if !record.location.isEmpty { Label(record.location, systemImage: "building.2").font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                scoreSummary("宿舍", score: report.roomScore)
                scoreSummary("个人", score: report.personalScore)
                scoreSummary("总分", score: report.totalScore)
            }
            HStack(spacing: 10) {
                if !record.type.isEmpty { Text(record.type) }
                if !record.week.isEmpty { Text("第 \(record.week) 周") }
            }.font(.caption).foregroundStyle(.secondary)
            let term = [record.yearLabel, record.semesterLabel].filter { !$0.isEmpty }.joined(separator: " · ")
            if !term.isEmpty { Text(term).font(.caption).foregroundStyle(.tertiary) }
        }.foregroundStyle(.primary)
    }
    private func scoreSummary(_ title: String, score: String) -> some View {
        VStack(spacing: 6) {
            Text(score.isEmpty ? "未公布" : score).font(.title2.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Color.brand.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }

}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
