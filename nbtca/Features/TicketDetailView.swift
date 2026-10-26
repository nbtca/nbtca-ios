import SwiftUI
import PhotosUI
import UIKit

struct TicketDetailView: View {
    @State var ticket: RepairTicket
    let onChange: () -> Void
    @State private var auth = AuthStore.shared
    @State private var loading = false
    @State private var busy = false
    @State private var error: String?
    @State private var showEdit = false
    @State private var showReport = false
    @State private var alteringReport = false
    @State private var confirmation: TicketOperation?
    @State private var privateDetailLoaded = false
    @Environment(\.dismiss) private var dismiss
    private var isOwner: Bool { auth.user?.sub == ticket.clientID && !ticket.clientID.isEmpty }
    private var assignedToMe: Bool { !ticket.memberID.isEmpty && auth.user?.memberID == ticket.memberID }
    private var canWork: Bool { auth.isStaff && (assignedToMe || auth.isAdmin) }
    private var canEdit: Bool { auth.isLoggedIn && privateDetailLoaded && !auth.isStaff && ticket.isOpen }
    private var canViewContact: Bool { privateDetailLoaded && (!auth.isStaff || isOwner || auth.isAdmin || assignedToMe) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if loading { ProgressView("正在更新工单…").frame(maxWidth: .infinity) }
                if let error { NoticeView(message: error); Button("重新加载") { Task { await refresh() } }.buttonStyle(.bordered) }
                Card {
                    HStack { Label(ticket.model, systemImage: "laptopcomputer").font(.caption).foregroundStyle(.secondary); Spacer(); TicketBadge(ticket: ticket) }
                    Text(ticket.title).font(.title2.bold())
                    if ticket.problem != ticket.title { Text(ticket.problem).font(.body).lineSpacing(5).textSelection(.enabled) }
                    Divider()
                    detailRow("设备型号", value: ticket.model)
                    if !ticket.size.isEmpty { detailRow("工单大小", value: ticket.size.uppercased()) }
                    if !ticket.memberName.isEmpty { detailRow("经办技术员", value: ticket.memberName) }
                    if !ticket.closedByName.isEmpty { detailRow("结单管理员", value: ticket.closedByName) }
                    if let created = ticket.created { detailRow("提交时间", value: AppDate.display(created)) }
                    if let modified = ticket.modified { detailRow("更新时间", value: AppDate.display(modified)) }
                }
                if canViewContact {
                    Card {
                        Label("联系方式", systemImage: "person.text.rectangle").font(.headline)
                        detailRow("联系电话", value: ticket.phone.isEmpty ? "未提供" : ticket.phone)
                        detailRow("QQ", value: ticket.qq.isEmpty ? "未提供" : ticket.qq)
                    }
                }
                if !ticket.photos.isEmpty {
                    SectionHeading(title: "现场照片", detail: "\(ticket.photos.count) 张")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(ticket.photos.enumerated()), id: \.offset) { _, source in
                                NavigationLink { PhotoDetailView(source: source) } label: {
                                    RemoteImage(source: source).frame(width: 180, height: 180).clipped().clipShape(RoundedRectangle(cornerRadius: 16))
                                }.accessibilityLabel("查看现场照片")
                            }
                        }
                    }
                }
                if auth.isLoggedIn { actions }
                SectionHeading(title: "处理进度")
                Card {
                    if ticket.logs.isEmpty {
                        Label(ticket.statusName, systemImage: "clock").font(.headline)
                        Text("暂无更多处理日志").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(ticket.logs.enumerated()), id: \.offset) { index, log in
                            HStack(alignment: .top, spacing: 14) {
                                VStack(spacing: 8) {
                                    Circle().fill(index == ticket.logs.count - 1 ? Color.brand : Color.secondary.opacity(0.3)).frame(width: 10, height: 10)
                                    if index != ticket.logs.count - 1 { Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 2, height: 48) }
                                }.padding(.top, 5)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(log.title).font(.headline)
                                    if !log.detail.isEmpty { Text(log.detail).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) }
                                    if let date = log.date { Text(AppDate.display(date)).font(.caption).foregroundStyle(.tertiary) }
                                }.padding(.bottom, 12)
                            }
                        }
                    }
                }
            }.pageContent()
        }.background(Color.canvas).navigationTitle("工单 #\(ticket.id)").navigationBarTitleDisplayMode(.inline)
            .disabled(busy)
            .overlay { if busy { ProgressView("正在处理…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) } }
            .task { await refresh() }
            .onChange(of: auth.user?.sub) { _, _ in dismiss() }
            .onChange(of: auth.role) { _, _ in dismiss() }
            .refreshable { await refresh() }
            .sheet(isPresented: $showEdit) { TicketFormView(ticket: ticket, onSaved: updated) }
            .sheet(isPresented: $showReport) { ReportFormView(ticket: ticket, altering: alteringReport, onSaved: updated) }
            .confirmationDialog(confirmation?.title ?? "确认操作", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
                if let operation = confirmation {
                    Button(operation.title, role: operation.destructive ? .destructive : nil) { Task { await perform(operation) } }
                }
            }
    }
    @ViewBuilder private var actions: some View {
        if canEdit || (auth.isStaff && ticket.isOpen) || (canWork && (ticket.isAccepted || ticket.isCommitted)) || (auth.isAdmin && ticket.isCommitted) {
            Card {
                Text(auth.isStaff ? "工单操作" : "预约管理").font(.headline)
                if canEdit {
                    Button { showEdit = true } label: { Label("编辑预约信息", systemImage: "square.and.pencil") }.buttonStyle(.bordered)
                    Button("取消维修预约", role: .destructive) { confirmation = .cancel }.buttonStyle(.bordered)
                }
                if auth.isStaff && ticket.isOpen {
                    Button { confirmation = .accept } label: { Label("接取此工单", systemImage: "hand.raised.fingers.spread.fill") }.buttonStyle(.borderedProminent)
                }
                if canWork && ticket.isAccepted {
                    Button { alteringReport = false; showReport = true } label: { Label("提交维修报告", systemImage: "doc.badge.plus") }.buttonStyle(.borderedProminent)
                    Button("放弃此工单", role: .destructive) { confirmation = .drop }.buttonStyle(.bordered)
                }
                if canWork && ticket.isCommitted {
                    Button("修改维修报告") { alteringReport = true; showReport = true }.buttonStyle(.bordered)
                }
                if auth.isAdmin && ticket.isCommitted {
                    Button("审核通过并结单") { confirmation = .close }.buttonStyle(.borderedProminent)
                    Button("退回继续检修", role: .destructive) { confirmation = .reject }.buttonStyle(.bordered)
                }
            }.frame(maxWidth: .infinity)
        }
    }
    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 20)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.subheadline)
    }
    private func refresh() async {
        loading = true; defer { loading = false }
        do { ticket = try await APIClient.shared.detail(ticket.id); privateDetailLoaded = true; error = nil }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    private func updated(_ ticket: RepairTicket) { self.ticket = ticket; onChange() }
    private func perform(_ operation: TicketOperation) async {
        guard !busy else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            switch operation {
            case .cancel: try await APIClient.shared.cancel(ticket.id); onChange(); dismiss()
            case .accept: updated(try await APIClient.shared.action(ticket.id, action: "accept")); await refresh()
            case .drop: updated(try await APIClient.shared.action(ticket.id, action: "accept", method: "DELETE"))
            case .close: updated(try await APIClient.shared.action(ticket.id, action: "close"))
            case .reject: updated(try await APIClient.shared.action(ticket.id, action: "commit", method: "DELETE"))
            }
        } catch { self.error = error.localizedDescription }
    }
}

private enum TicketOperation {
    case accept, drop, close, reject, cancel
    var title: String {
        switch self {
        case .accept: "确认接取此工单？"
        case .drop: "确认放弃此工单？"
        case .close: "确认审核通过并结单？"
        case .reject: "确认退回继续检修？"
        case .cancel: "确认取消维修预约？"
        }
    }
    var destructive: Bool { self == .drop || self == .reject || self == .cancel }
}

private struct PhotoDetailView: View {
    let source: String
    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                RemoteImage(source: source, contentMode: .fit).frame(width: geometry.size.width, height: geometry.size.height)
            }
        }.background(.black).navigationTitle("现场照片").navigationBarTitleDisplayMode(.inline)
    }
}

struct ReportFormView: View {
    let ticket: RepairTicket
    let altering: Bool
    let onSaved: (RepairTicket) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var size = "m"
    @State private var selections: [PhotosPickerItem] = []
    @State private var photos: [ProcessedPhoto] = []
    @State private var uploadProgress = 0.0
    @State private var photoGeneration = UUID()
    @State private var busy = false
    @State private var loadingPhotos = false
    @State private var error: String?
    @State private var uploadedPhotos = false
    @State private var submitted = false
    private var draftKey: String { "report." + ticket.id + (altering ? ".edit" : ".new") }
    private var draftFields: Binding<FormDraft> {
        Binding(get: { FormDraft(fields: ["content": content, "size": size]) }, set: {
            content = $0.fields["content"] ?? ""; size = $0.fields["size"] ?? "m"
        })
    }
    @State private var photoTask: Task<Void, Never>?
    init(ticket: RepairTicket, altering: Bool, onSaved: @escaping (RepairTicket) -> Void) {
        self.ticket = ticket; self.altering = altering; self.onSaved = onSaved
        _content = State(initialValue: altering ? ticket.logs.last(where: { $0.action == "commit" })?.detail ?? "" : "")
        _size = State(initialValue: ["xs", "s", "m", "l", "xl"].contains(ticket.size) ? ticket.size : "m")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("维修报告") {
                    TextField("请填写故障原因、处理过程和检修结果", text: $content, axis: .vertical).lineLimit(8...16)
                    if !altering {
                        Picker("工单大小", selection: $size) {
                            Text("XS · 极小").tag("xs"); Text("S · 小").tag("s"); Text("M · 中").tag("m"); Text("L · 大").tag("l"); Text("XL · 极大").tag("xl")
                        }
                    }
                }
                if !altering {
                    Section {
                        PhotosPicker(selection: $selections, maxSelectionCount: max(0, 6 - ticket.photos.count), matching: .images) {
                            Label("选择现场照片（\(photos.count) 张）", systemImage: "photo.badge.plus")
                        }.disabled(uploadedPhotos || ticket.photos.count >= 6)
                        if loadingPhotos { ProgressView("正在处理照片…") }
                        if !photos.isEmpty {
                            ScrollView(.horizontal) {
                                HStack {
                                    ForEach(photos) { photo in
                                        if let image = UIImage(data: photo.thumbnail) { Image(uiImage: image).resizable().scaledToFill().frame(width: 80, height: 80).clipped().clipShape(RoundedRectangle(cornerRadius: 10)) }
                                    }
                                }
                            }
                        }
                        if busy && !uploadedPhotos && !photos.isEmpty { ProgressView("正在上传照片 \(Int(uploadProgress * 100))%", value: uploadProgress) }
                        if uploadedPhotos { Text("现场照片已上传，重试将仅提交报告。").font(.caption).foregroundStyle(.secondary) }
                    } header: { Text("现场照片") } footer: { Text("最多 6 张照片") }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button { Task { await submit() } } label: { HStack { Spacer(); if busy { ProgressView() }; Text(altering ? "保存报告" : "提交维修报告"); Spacer() } }
                        .disabled(busy || loadingPhotos || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.readableContent(maxWidth: 720).disabled(busy).navigationTitle(altering ? "修改维修报告" : "提交维修报告").navigationBarTitleDisplayMode(.inline)
                .modifier(DraftProtection(fields: draftFields, submitted: $submitted,
                    account: AuthStore.shared.user?.sub ?? "", key: draftKey, busy: busy || loadingPhotos,
                    hasAttachments: !altering, hasUnsavedAttachments: !photos.isEmpty && !uploadedPhotos))
                .onChange(of: selections) { _, values in
                    photoTask?.cancel()
                    photoTask = Task { await loadPhotos(values) }
                }
                .onDisappear { photoTask?.cancel() }
        }.presentationSizing(.form)
    }
    private func loadPhotos(_ values: [PhotosPickerItem]) async {
        let generation = UUID(); photoGeneration = generation
        loadingPhotos = true; error = nil
        defer { if photoGeneration == generation { loadingPhotos = false } }
        var loaded: [ProcessedPhoto] = []
        do {
            for item in values {
                try Task.checkCancellation()
                guard let data = try await item.loadTransferable(type: Data.self) else { throw PhotoProcessingError.invalidImage }
                let worker = Task.detached(priority: .userInitiated) { try PhotoProcessor.process(data) }
                let photo = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                loaded.append(photo)
            }
            try Task.checkCancellation()
            if photoGeneration == generation { photos = loaded }
        } catch is CancellationError { }
        catch { if photoGeneration == generation { self.error = error.localizedDescription; photos = [] } }
    }
    private func submit() async {
        guard !busy, let account = AuthStore.shared.user?.sub else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            if !photos.isEmpty && !uploadedPhotos {
                uploadProgress = 0
                let updated = try await APIClient.shared.upload(ticket.id, photos: photos.map(\.upload)) { value in
                    Task { @MainActor in uploadProgress = value }
                }
                guard AuthStore.shared.user?.sub == account else { return }
                onSaved(updated); uploadedPhotos = true
            }
            let body: JSONObject = altering ? ["content": content.trimmingCharacters(in: .whitespacesAndNewlines)] : ["content": content.trimmingCharacters(in: .whitespacesAndNewlines), "size": size]
            let updated = try await APIClient.shared.action(ticket.id, action: "commit", method: altering ? "PATCH" : "POST", body: body)
            guard AuthStore.shared.user?.sub == account else { return }
            submitted = true
            try? FormDraftStore.shared.remove(account: account, key: draftKey)
            onSaved(updated); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
