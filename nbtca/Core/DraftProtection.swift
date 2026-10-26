import SwiftUI

/// Saves only editable text. Attachments must be selected again after reopening.
struct DraftProtection: ViewModifier {
    @Binding var fields: FormDraft
    @Binding var submitted: Bool
    let account: String
    let key: String
    let busy: Bool
    var hasAttachments = false
    var hasUnsavedAttachments = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var initial: FormDraft?
    @State private var owner = ""
    @State private var restored = false
    @State private var discarded = false
    @State private var showClose = false
    @State private var error: String?
    @State private var saveTask: Task<Void, Never>?
    private var dirty: Bool { hasUnsavedAttachments || (initial.map { fields != $0 } ?? false) }
    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if restored {
                    Text(hasAttachments ? "已恢复文字草稿，照片请重新选择" : "已恢复上次未提交的草稿")
                        .font(.caption).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity).background(.bar)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        if dirty { showClose = true } else { dismiss() }
                    }.disabled(busy)
                }
            }
            .interactiveDismissDisabled(busy || dirty)
            .onAppear {
                guard initial == nil else { return }
                initial = fields; owner = account
                if let saved = FormDraftStore.shared.load(account: owner, key: key) {
                    fields = saved; restored = true
                }
            }
            .onChange(of: fields) { _, _ in
                saveTask?.cancel()
                saveTask = Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                    persist()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { saveTask?.cancel(); persist() }
            }
            .onChange(of: account) { _, next in
                if next != owner { discarded = true; dismiss() }
            }
            .onDisappear {
                saveTask?.cancel()
                if submitted { try? FormDraftStore.shared.remove(account: owner, key: key) }
                else { persist() }
            }
            .confirmationDialog("还有未提交的内容", isPresented: $showClose, titleVisibility: .visible) {
                Button("保存草稿并关闭") { if persist() { dismiss() } }
                Button("放弃草稿", role: .destructive) {
                    do {
                        try FormDraftStore.shared.remove(account: owner, key: key)
                        discarded = true; dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                Button("继续填写", role: .cancel) { }
            } message: {
                Text(hasAttachments ? "文字内容可保存为草稿，未上传的照片需要重新选择。" : "保存后可在下次打开时继续填写。")
            }
            .alert("草稿未能保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
    }
    @discardableResult private func persist() -> Bool {
        guard initial != nil, account == owner, AuthStore.shared.user?.sub == owner,
              !submitted, !discarded else { return true }
        do {
            if dirty { try FormDraftStore.shared.save(fields, account: owner, key: key) }
            else { try FormDraftStore.shared.remove(account: owner, key: key) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
