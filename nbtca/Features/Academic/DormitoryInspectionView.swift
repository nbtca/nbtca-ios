import SwiftUI

struct DormitoryInspectionView: View {
    let report: DormitoryReport
    var body: some View {
        AdaptivePage { columns in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Card {
                        let record = report.inspection
                        if !record.date.isEmpty { Text(record.date).font(.headline) }
                        if !record.location.isEmpty { Label(record.location, systemImage: "building.2").font(.subheadline) }
                        HStack(spacing: 16) {
                            if !record.week.isEmpty { Text("周次：\(record.week)") }
                            if !record.type.isEmpty { Text(record.type) }
                        }.font(.subheadline).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: AppLayout.columns(columns), alignment: .leading, spacing: 18) {
                        DormitoryScoreSection(title: "宿舍检查情况", score: report.roomScore) {
                            Text("备注：" + display(report.roomInspection?.remark))
                            Text("违规类型：" + display(report.roomInspection?.deductions))
                        }
                        DormitoryScoreSection(title: "个人检查情况", score: report.personalScore) {
                            Text("个人卫生扣分情况：" + display(report.inspection.kind == .personal ? report.personalDeductions : nil))
                        }
                    }
                    DormitoryScoreSection(title: "总分", score: report.totalScore) {
                        Text("备注：" + display(report.inspection.kind == .personal ? report.totalRemark : nil))
                    }
                    if report.hasAttachments {
                        Label("检查图片可在学校原始页面查看", systemImage: "photo")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.pageContent(maxWidth: AppLayout.gridMaxWidth)
            }
        }.background(Color.canvas).navigationTitle("检查详情").navigationBarTitleDisplayMode(.inline)
    }
    private func display(_ value: String?) -> String {
        guard let value else { return "未公布" }
        return value.isEmpty ? "暂无" : value
    }
}

private struct DormitoryScoreSection<Content: View>: View {
    let title: String
    let score: String
    @ViewBuilder let content: Content
    var body: some View {
        Card {
            HStack(spacing: 10) {
                Capsule().fill(Color(red: 0.29, green: 0.75, blue: 0.77)).frame(width: 4, height: 20)
                Text(title).font(.headline)
            }
            VStack(spacing: 0) {
                Text(score.isEmpty ? "未公布" : score)
                    .font(score.isEmpty ? .headline : .system(.largeTitle, design: .rounded).bold())
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text("得分").font(.subheadline)
            }.foregroundStyle(.white).padding(12).frame(width: 112, height: 112)
                .background(Color(red: 0.96, green: 0.39, blue: 0.40), in: Circle())
                .shadow(color: Color(red: 0.96, green: 0.39, blue: 0.40).opacity(0.16), radius: 12, y: 8)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("得分，" + (score.isEmpty ? "未公布" : score))
            VStack(alignment: .leading, spacing: 6) { content }
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
