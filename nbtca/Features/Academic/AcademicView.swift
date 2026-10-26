import SwiftUI

struct AcademicView: View {
    var initialKind: AcademicKind = .timetable
    var initialTermID: String?
    @State private var network = CampusNetwork.shared
    @State private var store = AcademicStore()
    @State private var loginRoute: CampusRoute?
    @State private var showLogin = false
    @State private var showLogout = false
    @State private var search = ""
    @State private var exportPlan: TimetableExportPlan?
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        AdaptivePage { columns in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    networkCard
                    if let error = store.error { NoticeView(message: error) }
                    if let notice = store.sessionNotice { NoticeView(message: notice) }
                    if let notice = store.cacheNotice { NoticeView(message: notice) }
                    if store.hasSession || store.hasSavedTimetables { queryControls }
                    if store.kind == .timetable, store.timetable != nil {
                        if store.isUsingSavedTimetable {
                            HStack {
                                Label("本地课表", systemImage: "internaldrive")
                                Spacer()
                                if let savedAt = store.savedAt { Text(AppDate.display(savedAt)) }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        if store.loading || network.checking || store.validating { ProgressView().frame(maxWidth: .infinity) }
                        timetableContent()
                        if store.hasSession, store.error != nil {
                            Button("重新查询") { Task { await store.reload() } }.buttonStyle(.bordered)
                        } else if !store.hasSession, network.route != nil, !network.checking, !store.validating {
                            Button("登录教务系统") { loginRoute = network.route; showLogin = true }.buttonStyle(.bordered)
                        }
                    } else if network.checking || store.validating {
                        ProgressView(network.checking ? "正在检测教务线路…" : "正在校验教务登录…")
                            .frame(maxWidth: .infinity).padding(30)
                    } else if network.route == nil {
                        ContentUnavailableView("暂时无法连接", systemImage: "wifi.slash")
                    } else if !store.hasSession {
                        Card {
                            Label("登录学校账号", systemImage: "person.crop.circle.badge.checkmark").font(.title3.bold())
                            Button("登录教务系统") {
                                loginRoute = network.route; showLogin = true
                            }.buttonStyle(.borderedProminent)
                        }
                    } else {
                        if store.loading || (store.error == nil && !store.hasLoadedCurrentQuery) { ProgressView("正在查询\(store.kind.title)…").frame(maxWidth: .infinity).padding(24) }
                        else if store.error != nil {
                            Button("重新查询") { Task { await store.reload() } }.buttonStyle(.bordered)
                        } else {
                            switch store.kind {
                            case .timetable: timetableContent()
                            case .exams: examsContent(columns: columns)
                            case .grades: gradesContent(columns: columns)
                            }
                        }
                    }
                }.pageContent(maxWidth: AppLayout.gridMaxWidth)
            }.refreshable { await store.reload(); network.recheck() }
        }
        .background(Color.canvas).navigationTitle("教务查询").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索课程、教师或地点")
        .toolbar {
            if store.hasSession || store.hasRememberedSession {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("退出学校登录", systemImage: "power") { showLogout = true }
                        .labelStyle(.iconOnly)
                }
            }
        }
        .onAppear {
            store.kind = initialKind
            if let initialTermID, store.terms.contains(where: { $0.id == initialTermID }) { store.selectedTermID = initialTermID }
            store.resume(); store.showCurrentWeek(); network.start()
        }
        .onDisappear { store.clearSensitiveRecords() }
        .task(id: "\(network.route?.rawValue ?? "offline")|\(CampusSchoolSession.shared.revision)") { await store.activate(network.route) }
        .task(id: store.queryKey) { await store.reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.resume(); store.showCurrentWeek(); network.recheck() }
            if phase == .background { store.clearSensitiveRecords() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in store.showCurrentWeek() }
        .sheet(item: $exportPlan) { TimetableExportView(plan: $0) }
        .sheet(isPresented: $showLogin) { if let loginRoute { CampusLoginView(route: loginRoute, academicStore: store) } }
        .confirmationDialog("退出学校登录并清除保存的登录状态和查询结果？", isPresented: $showLogout, titleVisibility: .visible) {
            Button("退出学校登录", role: .destructive) { Task { await store.logout() } }
        }
    }
    private var networkCard: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: network.route == .campus ? "wifi" : "network").font(.title2).foregroundStyle(Color.brand)
                Text(network.checking ? "正在检测线路" : network.route?.title ?? "网络未连接").font(.headline)
                Spacer()
                Menu {
                    Picker("访问线路", selection: Binding(get: { network.mode }, set: { network.selectMode($0) })) {
                        ForEach(CampusNetwork.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Button("重新检测", systemImage: "arrow.clockwise") { network.recheck() }
                } label: { Label("线路", systemImage: "arrow.triangle.branch").font(.subheadline) }
            }
        }
    }
    private var queryControls: some View {
        VStack(spacing: 14) {
            Picker("查询内容", selection: $store.kind) {
                ForEach(AcademicKind.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                Text("学期").foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Picker("学期", selection: $store.selectedTermID) {
                    ForEach(store.terms) { term in Text(term.title).tag(term.id) }
                }.pickerStyle(.menu).labelsHidden()
            }.font(.subheadline)
        }
    }
    @ViewBuilder private func timetableContent() -> some View {
        if let timetable = store.timetable {
            HStack(spacing: 12) {
                Stepper(value: $store.week, in: 1...timetable.displayMaxWeek) { Text("第 \(store.week) 周").font(.headline) }
                Button("本周") { store.showCurrentWeek() }
                    .buttonStyle(.bordered).disabled(store.selectedTerm?.current == false || timetable.currentWeek() == nil || timetable.currentWeek() == store.week)
            }
            if timetable.days.isEmpty && timetable.weekOneMonday == nil {
                Text("暂时无法确定本周，当前显示手动选择的第 \(store.week) 周。可下拉重试获取校历。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let courses = timetable.courses.filter { matches($0.name + $0.teacher + $0.location) }
            TimetableWeekView(timetable: timetable, week: store.week, courses: courses)
            if !courses.contains(where: { $0.hasTime && $0.weeks.contains(store.week) }) {
                Text("本周暂无匹配课程").font(.subheadline).foregroundStyle(.secondary)
            }
            if let term = store.selectedTerm {
                Button {
                    exportPlan = TimetableExportPlan(timetable: timetable, term: term)
                } label: { Label("导出到苹果日历", systemImage: "calendar.badge.plus") }
                    .buttonStyle(.bordered)
            }
            let pending = timetable.courses.filter { !$0.hasTime && matches($0.name + $0.teacher + $0.location) }
            if !pending.isEmpty {
                SectionHeading(title: "未排定时间的课程", detail: "\(pending.count) 门")
                ForEach(pending) { course in
                    Card {
                        Text(course.name).font(.headline)
                        if !course.weekText.isEmpty { Text(course.weekText).font(.subheadline).foregroundStyle(.secondary) }
                        if !course.teacher.isEmpty { Text(course.teacher).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if timetable.unrecognizedCount > 0 { NoticeView(message: "有 \(timetable.unrecognizedCount) 条安排尚无法完整解析，请以教务系统原始课表为准") }
        }
    }
    @ViewBuilder private func examsContent(columns: Int) -> some View {
        let exams = store.exams.filter { matches($0.name + $0.location + $0.examName) }
        SectionHeading(title: "个人考试安排", detail: "\(exams.count) 场")
        if exams.isEmpty { ContentUnavailableView("暂无考试安排", systemImage: "pencil.and.list.clipboard") }
        LazyVGrid(columns: AppLayout.columns(columns), alignment: .leading, spacing: 18) {
            ForEach(exams) { exam in
                Card {
                    Text(exam.name).font(.headline)
                    if !exam.examName.isEmpty { Text(exam.examName).font(.caption).foregroundStyle(.secondary) }
                    Label(exam.timeText.isEmpty ? "考试时间尚未公布" : exam.timeText, systemImage: "clock").font(.subheadline)
                    if !exam.location.isEmpty { Label(exam.campus + " " + exam.location, systemImage: "mappin.and.ellipse").font(.subheadline).foregroundStyle(.secondary) }
                    if !exam.seat.isEmpty { Text("座位：" + exam.seat).font(.subheadline) }
                    if !exam.assessment.isEmpty { Text("考核方式：" + exam.assessment).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
    @ViewBuilder private func gradesContent(columns: Int) -> some View {
        let grades = store.grades.filter { matches($0.name + $0.nature) }
        SectionHeading(title: "个人成绩", detail: "\(grades.count) 条")
        if grades.isEmpty { ContentUnavailableView("暂无已公布成绩", systemImage: "chart.bar.doc.horizontal") }
        LazyVGrid(columns: AppLayout.columns(columns), alignment: .leading, spacing: 18) {
            ForEach(grades) { grade in
                Card {
                    HStack(alignment: .top) {
                        Text(grade.name).font(.headline)
                        Spacer(minLength: 14)
                        Text(grade.grade.isEmpty ? "未公布" : grade.grade).font(.title3.bold()).foregroundStyle(grade.voided == true ? Color.secondary : Color.brand)
                    }
                    HStack(spacing: 20) {
                        if !grade.credits.isEmpty { Text("学分 " + grade.credits) }
                        if !grade.point.isEmpty { Text("绩点 " + grade.point) }
                    }.font(.subheadline).foregroundStyle(.secondary)
                    if !grade.nature.isEmpty { Text(grade.nature).font(.caption).foregroundStyle(.secondary) }
                    if !grade.examNature.isEmpty { Text("考试性质：" + grade.examNature).font(.caption).foregroundStyle(.secondary) }
                    if !grade.remark.isEmpty { Text(grade.remark).font(.caption).foregroundStyle(.secondary) }
                    if grade.voided == true { Label("教务系统标记为作废", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                }
            }
        }
    }
    private func matches(_ value: String) -> Bool { search.isEmpty || value.localizedCaseInsensitiveContains(search) }
}
