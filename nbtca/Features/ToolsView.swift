import SwiftUI

struct ToolsView: View {
    @State private var status: ServiceStatus?
    @State private var error: String?
    @State private var loading = false
    @State private var loadGeneration = UUID()
    @State private var loadedBaseURL: String?
    var body: some View {
        AdaptivePage { columnCount in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SectionHeading(title: "教务服务")
                    LazyVGrid(columns: AppLayout.columns(2), alignment: .leading, spacing: 14) {
                        ForEach(AcademicKind.allCases) { kind in
                            NavigationLink { AcademicView(initialKind: kind) } label: {
                                toolTile(kind.title, icon: kind.symbol, color: .brand)
                            }.buttonStyle(.plain)
                        }
                        NavigationLink { DormitoryView() } label: {
                            toolTile("寝室文明查询", icon: "building.2.crop.circle", color: .brand)
                        }.buttonStyle(.plain)
                    }
                    SectionHeading(title: "协会工具")
                    HStack(alignment: .top, spacing: 14) {
                        NavigationLink { AssociationCalendarView() } label: {
                            toolTile("协会活动日历", subtitle: "events.ics 公开活动", icon: "calendar", color: .orange)
                        }
                        Link(destination: URL(string: "https://docs.nbtca.space")!) {
                            toolTile("协会文档", subtitle: "docs.nbtca.space", icon: "books.vertical", color: .brand)
                        }
                    }.buttonStyle(.plain)
                    SectionHeading(title: "服务状态")
                    if let status {
                        Card {
                            HStack(spacing: 14) {
                                Image(systemName: status.state == "operational" ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                    .font(.largeTitle).foregroundStyle(statusColor(status.state))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(ServiceStatus.label(status.state)).font(.title3.bold())
                                    Text("\(status.healthy) / \(status.total) 个组件运行正常").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            if !status.message.isEmpty { Text(status.message).font(.subheadline).foregroundStyle(.secondary) }
                            if status.updated > 0 { Text("更新于 " + AppDate.display(Date(timeIntervalSince1970: status.updated))).font(.caption).foregroundStyle(.secondary) }
                        }
                        LazyVGrid(columns: AppLayout.columns(columnCount), alignment: .leading, spacing: 20) {
                            ForEach(status.groups) { group in
                                Card {
                                    Text(group.name).font(.headline)
                                    ForEach(group.components) { component in
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack {
                                                Circle().fill(statusColor(component.state)).frame(width: 8, height: 8)
                                                Text(component.name).font(.subheadline)
                                                Spacer()
                                                Text(ServiceStatus.label(component.state)).font(.caption).foregroundStyle(.secondary)
                                            }
                                            if !component.error.isEmpty { Text(component.error).font(.caption).foregroundStyle(.secondary) }
                                            if !component.failed.isEmpty { Text("异常组件：" + component.failed.joined(separator: "、")).font(.caption).foregroundStyle(.orange) }
                                        }.padding(.vertical, 4)
                                    }
                                }
                            }
                        }
                        if !status.incidents.isEmpty {
                            SectionHeading(title: "服务事件")
                            LazyVGrid(columns: AppLayout.columns(columnCount), alignment: .leading, spacing: 20) {
                                ForEach(status.incidents) { incident in
                                    Card {
                                        Label(incident.title, systemImage: "exclamationmark.bubble").font(.headline)
                                        Text(incident.impact).font(.subheadline).foregroundStyle(.secondary)
                                        if !incident.updated.isEmpty { Text(incident.updated).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        }
                    }
                    if loading { ProgressView("正在检查服务状态…").frame(maxWidth: .infinity).padding(30) }
                    if let error { LoadFailure(message: error) { Task { await load() } } }
                    ExternalLink(title: "打开完整状态页", url: "https://status.nbtca.space")
                        .font(.subheadline).frame(maxWidth: .infinity).padding()
                }.pageContent(maxWidth: AppLayout.gridMaxWidth)
            }
        }.background(Color.canvas).navigationTitle("极客工具")
            .refreshable { await load() }.task(id: AppSettings.shared.baseURL) { await load() }
    }
    private func toolTile(_ title: String, subtitle: String? = nil, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: icon).font(.title2).foregroundStyle(color).frame(width: 46, height: 46).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).foregroundStyle(.primary)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).background(Color.card, in: RoundedRectangle(cornerRadius: 22))
    }
    private func statusColor(_ state: String) -> Color {
        state == "operational" ? .green : ["degraded", "partial"].contains(state) ? .orange : state == "unknown" ? .secondary : .red
    }
    private func load() async {
        let generation = UUID(); loadGeneration = generation
        let base = AppSettings.shared.baseURL
        if loadedBaseURL != base { status = nil; loadedBaseURL = base }
        loading = true; error = nil
        defer { if generation == loadGeneration { loading = false } }
        do {
            let result = try await APIClient.shared.status()
            try Task.checkCancellation(); guard generation == loadGeneration else { return }
            status = result
        }
        catch is CancellationError { }
        catch { if generation == loadGeneration { self.error = status == nil ? error.localizedDescription : "更新失败，正在显示上次加载的状态。" + error.localizedDescription } }
    }
}

struct AssociationCalendarView: View {
    @State private var calendar: AssociationCalendar?
    @State private var error: String?
    @State private var loading = false
    @State private var loadGeneration = UUID()
    var body: some View {
        AdaptivePage { columnCount in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Card {
                        Label("协会活动与线下聚会", systemImage: "calendar.badge.clock").font(.title2.bold())
                        ExternalLink(title: "订阅协会日历", url: "https://ical.nbtca.space/events.ics", symbol: "calendar.badge.plus")
                    }
                    if loading { ProgressView("正在加载活动…").frame(maxWidth: .infinity).padding(40) }
                    if let error { LoadFailure(message: error) { Task { await load() } } }
                    if let calendar {
                        SectionHeading(title: "近期活动", detail: "\(calendar.events.count) 项安排")
                        if calendar.events.isEmpty { ContentUnavailableView("近期暂无协会活动", systemImage: "calendar") }
                        LazyVGrid(columns: AppLayout.columns(columnCount), alignment: .leading, spacing: 20) {
                            ForEach(calendar.events) { event in
                                Card {
                                    HStack(alignment: .top, spacing: 16) {
                                        VStack(spacing: 3) {
                                            Text(event.start.map { AppDate.display($0, format: "M月") } ?? "待定").font(.caption.bold()).foregroundStyle(.orange)
                                            Text(event.start.map { AppDate.display($0, format: "dd") } ?? "—").font(.title.bold())
                                        }.frame(width: 52).padding(.vertical, 12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                                        VStack(alignment: .leading, spacing: 9) {
                                            Text(event.title).font(.headline)
                                            Text(event.timeLabel).font(.caption).foregroundStyle(.secondary)
                                        }.padding(.top, 8)
                                    }
                                    if !event.description.isEmpty { Text(event.description).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) }
                                    ExternalLink(title: "查看活动详情", url: event.url)
                                }
                            }
                        }
                    }
                }.pageContent(maxWidth: AppLayout.gridMaxWidth)
            }
        }.background(Color.canvas).navigationTitle("协会活动日历").navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }.task { await load() }
    }
    private func load() async {
        let generation = UUID(); loadGeneration = generation
        loading = true; defer { if generation == loadGeneration { loading = false } }
        do {
            let result = try await APIClient.shared.calendar()
            try Task.checkCancellation(); guard generation == loadGeneration else { return }
            calendar = result; error = nil
        }
        catch is CancellationError { }
        catch { if generation == loadGeneration { self.error = error.localizedDescription } }
    }
}

#Preview("极客工具") { NavigationStack { ToolsView() }.tint(.brand) }
