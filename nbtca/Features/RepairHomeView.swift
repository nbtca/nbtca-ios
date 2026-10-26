import SwiftUI

struct RepairHomeView: View {
    @State private var auth = AuthStore.shared
    @State private var store = RepairStore { queue, offset in
        try await APIClient.shared.tickets(queue: queue, offset: offset)
    }
    @State private var section = "mine"
    @State private var statusFilter = "all"
    @State private var showCreate = false
    @State private var showLogin = false
    @State private var repairDay: AssociationEvent?
    @Environment(\.scenePhase) private var scenePhase
    private var loadID: String { (auth.user?.sub ?? "guest") + auth.role + section }
    private var displayed: [RepairTicket] { store.tickets.filter { $0.matchesStatus(statusFilter) } }
    var body: some View {
        AdaptivePage { columnCount in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    hero
                    NavigationLink { AssociationCalendarView() } label: {
                        Card {
                            HStack(spacing: 14) {
                                Image(systemName: "calendar.badge.clock").font(.title2).foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(repairDay?.title ?? "协会维修日").font(.headline)
                                    Text(repairDay?.timeLabel ?? "近期暂无维修日安排，请关注协会公共日历").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.buttonStyle(.plain)
                    if auth.isLoggedIn {
                        if auth.isStaff {
                            Picker("工单范围", selection: $section) {
                                Text("已接工单").tag("mine")
                                Text(auth.isAdmin ? "管理台" : "接单大厅").tag("queue")
                            }.pickerStyle(.segmented)
                        }
                        SectionHeading(title: section == "queue" ? "工单队列" : "我的维修记录", detail: "已加载 \(store.tickets.count) 条")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(["all", "open", "accepted", "committed", "closed", "cancelled"], id: \.self) { filter in
                                    Button { statusFilter = filter } label: {
                                        Text(filter == "all" ? "全部" : RepairTicket.statusName(filter)).font(.caption.weight(.medium))
                                            .padding(.horizontal, 14).padding(.vertical, 9)
                                            .background(statusFilter == filter ? Color.brand : Color.card, in: Capsule())
                                            .foregroundStyle(statusFilter == filter ? .white : .primary)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        if let error = store.error { LoadFailure(message: error) { Task { await load() } } }
                        LazyVGrid(columns: AppLayout.columns(columnCount), alignment: .leading, spacing: 20) {
                            ForEach(displayed) { ticket in
                                NavigationLink { TicketDetailView(ticket: ticket, onChange: { Task { await load() } }) } label: {
                                    Card {
                                        HStack {
                                            Label(ticket.model, systemImage: "laptopcomputer").font(.caption).foregroundStyle(.secondary)
                                            Spacer(); TicketBadge(ticket: ticket)
                                        }
                                        Text(ticket.title).font(.headline).lineLimit(2)
                                        HStack {
                                            Text("#" + ticket.id)
                                            Spacer()
                                            Text(ticket.created.map { AppDate.display($0, format: "M月d日 HH:mm") } ?? "")
                                        }.font(.caption).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                        if store.loading { ProgressView("正在加载工单…").frame(maxWidth: .infinity).padding(24) }
                        if !store.loading && store.error == nil && displayed.isEmpty {
                            ContentUnavailableView(store.emptyMessage(filter: statusFilter), systemImage: "tray")
                        }
                        if store.hasMore { Button("加载更多工单") { Task { await load(more: true) } }.buttonStyle(.bordered).frame(maxWidth: .infinity).disabled(store.loading) }
                    } else {
                        Card {
                            Label("需要登录 NBTCA 账号", systemImage: "wrench.and.screwdriver").font(.headline)
                            Text("电脑维修服务需登录/注册 Logto 统一身份账号后方可预约，以便技术员确认维修时间并向您的邮箱同步进度。")
                                .font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                            Button("登录 / 注册") { showLogin = true }.buttonStyle(.borderedProminent)
                        }
                    }
                }.pageContent(maxWidth: AppLayout.gridMaxWidth)
            }
        }.background(Color.canvas).navigationTitle("维修服务")
            .refreshable { await load(); await loadCalendar() }
            .task(id: loadID) { await load() }
            .task(id: AppSettings.shared.baseURL) { await loadCalendar() }
            .onChange(of: scenePhase) { _, value in if value == .active { Task { await load() } } }
            .sheet(isPresented: $showLogin) { LoginView() }
            .sheet(isPresented: $showCreate) { TicketFormView(onSaved: { _ in Task { await load() } }) }
    }
    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("公益 · 免费服务").font(.caption.bold()).tracking(2)
                Spacer(); Image(systemName: "cross.case.fill").font(.title2)
            }.foregroundStyle(.white.opacity(0.8))
            Text("我们提供免费的电脑维修服务").font(.system(size: 30, weight: .bold)).lineSpacing(4)
            Text("从清理磁盘到加装硬件再到环境配置，我们都帮你搞定。").font(.subheadline).foregroundStyle(.white.opacity(0.8))
            Button {
                if auth.isLoggedIn { showCreate = true } else { showLogin = true }
            } label: { Label("预约维修", systemImage: "plus.circle.fill").font(.headline).padding(.vertical, 3) }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(Color.brand)
        }.foregroundStyle(.white).padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Color.brand, Color(red: 0.12, green: 0.28, blue: 0.68)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 26))
    }
    private func load(more: Bool = false) async {
        await store.load(identity: auth.isLoggedIn ? loadID : nil, queue: section == "queue", more: more)
    }
    private func loadCalendar() async {
        repairDay = nil
        let base = AppSettings.shared.baseURL
        if let calendar = try? await APIClient.shared.calendar(), !Task.isCancelled, base == AppSettings.shared.baseURL { repairDay = calendar.events.first { $0.title.contains("维修日") } }
    }
}

struct TicketFormView: View {
    var ticket: RepairTicket? = nil
    let onSaved: (RepairTicket) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model = ""
    @State private var problem = ""
    @State private var phone = ""
    @State private var qq = ""
    @State private var error: String?
    @State private var busy = false
    @State private var diagnosing = false
    @State private var diagnosis: Diagnosis?
    @State private var submitted = false
    private var draftKey: String { "ticket." + (ticket?.id ?? "new") }
    private var draftFields: Binding<FormDraft> {
        Binding(get: { FormDraft(fields: ["model": model, "problem": problem, "phone": phone, "qq": qq]) }, set: {
            model = $0.fields["model"] ?? ""; problem = $0.fields["problem"] ?? ""
            phone = $0.fields["phone"] ?? ""; qq = $0.fields["qq"] ?? ""
        })
    }
    init(ticket: RepairTicket? = nil, onSaved: @escaping (RepairTicket) -> Void) {
        self.ticket = ticket; self.onSaved = onSaved
        _model = State(initialValue: ticket?.model ?? "")
        _problem = State(initialValue: ticket?.problem ?? "")
        _phone = State(initialValue: ticket?.phone ?? "")
        _qq = State(initialValue: ticket?.qq ?? "")
    }
    private var valid: Bool { !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        NavigationStack {
            Form {
                Section("设备与故障") {
                    TextField("设备型号，例如 ThinkPad T14", text: $model)
                    TextField("请描述故障现象、出现时间和已尝试的操作", text: $problem, axis: .vertical).lineLimit(5...12)
                }
                Section {
                    Button { Task { await diagnose() } } label: {
                        HStack { Label("AI 故障预检", systemImage: "sparkles"); Spacer(); if diagnosing { ProgressView() } }
                    }.disabled(problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || diagnosing || busy)
                    if let diagnosis {
                        Text(diagnosis.source == "dify" ? "AI 预检建议" : "基础预检建议（\(diagnosis.source)）").font(.caption).foregroundStyle(.secondary)
                        if !diagnosis.summary.isEmpty { Text(diagnosis.summary).font(.subheadline) }
                        diagnosisRows("可能原因", values: diagnosis.causes)
                        diagnosisRows("自助排查", values: diagnosis.steps)
                        if !diagnosis.tools.isEmpty { Text("推荐工具：" + diagnosis.tools.joined(separator: "、")).font(.caption) }
                    }
                }
                Section("联系方式") {
                    TextField("联系电话（必填）", text: $phone).keyboardType(.phonePad)
                    TextField("QQ（选填）", text: $qq).keyboardType(.numberPad)
                }
                if let error { Section { Text(error).font(.subheadline).foregroundStyle(.red) } }
                Section {
                    Button { Task { await save() } } label: {
                        HStack { Spacer(); if busy { ProgressView() }; Text(ticket == nil ? "提交维修预约" : "保存修改"); Spacer() }
                    }.disabled(!valid || busy || diagnosing)
                }
            }.readableContent(maxWidth: 720).navigationTitle(ticket == nil ? "预约维修" : "编辑工单").navigationBarTitleDisplayMode(.inline)
                .modifier(DraftProtection(fields: draftFields, submitted: $submitted,
                    account: AuthStore.shared.user?.sub ?? "", key: draftKey, busy: busy || diagnosing))
                .onChange(of: problem) { _, _ in diagnosis = nil }
                .onChange(of: model) { _, _ in diagnosis = nil }
        }.presentationSizing(.form)
    }
    @ViewBuilder private func diagnosisRows(_ title: String, values: [String]) -> some View {
        if !values.isEmpty {
            Text(title).font(.subheadline.bold())
            ForEach(Array(values.enumerated()), id: \.offset) { index, text in Text("\(index + 1). \(text)").font(.subheadline).foregroundStyle(.secondary) }
        }
    }
    private func diagnose() async {
        diagnosing = true; error = nil; let text = problem; let device = model
        defer { diagnosing = false }
        do { let result = try await APIClient.shared.diagnose(model: device, problem: text); if text == problem && device == model { diagnosis = result } }
        catch { self.error = "预检暂不可用，可直接提交报修。" + error.localizedDescription }
    }
    private func save() async {
        guard valid, !busy else { return }
        guard let account = AuthStore.shared.user?.sub else { return }
        busy = true; error = nil; defer { busy = false }
        let body: JSONObject = ["model": model.trimmingCharacters(in: .whitespacesAndNewlines), "problem": problem.trimmingCharacters(in: .whitespacesAndNewlines), "phone": phone.trimmingCharacters(in: .whitespacesAndNewlines), "qq": qq.trimmingCharacters(in: .whitespacesAndNewlines), "contactPreference": "phone"]
        do {
            let saved: RepairTicket
            if let ticket { saved = try await APIClient.shared.update(ticket.id, body: body) }
            else { saved = try await APIClient.shared.create(body) }
            guard AuthStore.shared.user?.sub == account else { return }
            submitted = true
            try? FormDraftStore.shared.remove(account: account, key: draftKey)
            onSaved(saved); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

#Preview("维修服务") { NavigationStack { RepairHomeView() }.tint(.brand) }
