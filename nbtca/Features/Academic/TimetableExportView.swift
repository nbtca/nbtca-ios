import SwiftUI

struct TimetableExportView: View {
    let plan: TimetableExportPlan
    @Environment(\.dismiss) private var dismiss
    @State private var removeObsolete = false
    @State private var exporter = TimetableCalendarExporter()
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("学期", value: plan.term.title)
                    LabeledContent("课程日程", value: "\(plan.events.count) 条")
                    if let first = plan.events.first, let last = plan.events.last {
                        LabeledContent("日期", value: AcademicTimetable.dateString(first.start) + " — " + AcademicTimetable.dateString(last.start))
                    }
                }
                if !plan.issues.isEmpty {
                    Section("无法导出的安排") {
                        ForEach(plan.issues) { issue in
                            LabeledContent(issue.course, value: issue.reason)
                        }
                    }
                }
                if let diff = exporter.diff, !exporter.completed {
                    Section("变更预览") {
                        LabeledContent("新增", value: "\(diff.added) 条")
                        LabeledContent("更新", value: "\(diff.updated) 条")
                        LabeledContent("失效", value: "\(diff.removed) 条")
                        if diff.removed > 0 {
                            Toggle("清理本 App 导出的失效日程", isOn: $removeObsolete).disabled(!plan.issues.isEmpty)
                            if !plan.issues.isEmpty { Text("部分课程无法导出，为避免误删，本次保留旧日程。").font(.caption).foregroundStyle(.secondary) }
                        }
                        ForEach(diff.changes) { change in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(change.kind.rawValue + " · " + change.event.title).font(.subheadline)
                                Text(AppDate.display(change.event.start)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let error = exporter.error { Section { Text(error).foregroundStyle(.red) } }
                if exporter.completed {
                    Section {
                        Label("已导出 \(plan.events.count) 条日程", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        LabeledContent("日历", value: exporter.calendarTitle)
                    }
                } else {
                    Section {
                        Button {
                            Task {
                                if exporter.diff == nil { await exporter.prepare(plan) }
                                else { await exporter.export(plan, removeObsolete: removeObsolete) }
                            }
                        } label: {
                            HStack {
                                Spacer()
                                if exporter.exporting || exporter.checking { ProgressView() }
                                Text(exporter.exporting ? "\(exporter.progress) / \(plan.events.count)" : exporter.diff == nil ? "授权并检查日历变更" : "确认更新苹果日历")
                                Spacer()
                            }
                        }.disabled(exporter.exporting || exporter.checking || (exporter.diff != nil && plan.events.isEmpty && !(removeObsolete && exporter.diff!.removed > 0)))
                    }
                }
            }.readableContent(maxWidth: 720)
                .navigationTitle("导出课表").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(exporter.completed ? "完成" : "关闭") { dismiss() }.disabled(exporter.exporting || exporter.checking) } }
                .interactiveDismissDisabled(exporter.exporting || exporter.checking)
        }.presentationSizing(.form)
    }
}
