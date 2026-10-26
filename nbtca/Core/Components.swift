import SwiftUI
import UIKit

extension Color {
    static let brand = Color(red: 0, green: 0.44, blue: 0.89)
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
}

extension View {
    /// Use the scroll viewport's width rather than an image or long line's ideal width.
    func pageContent(maxWidth: CGFloat = 800, padding: CGFloat = 20) -> some View {
        self.padding(padding)
            .containerRelativeFrame(.horizontal) { viewportWidth, _ in
                min(viewportWidth, maxWidth)
            }
            .frame(maxWidth: .infinity)
    }

    func readableContent(maxWidth: CGFloat = 760) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity).background(Color.canvas)
    }
}

enum AppLayout {
    static let gridMaxWidth: CGFloat = 1120

    static func columns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 20, alignment: .top), count: count)
    }
}

/// Measure the current window or navigation column, including Split View resizing.
struct AdaptivePage<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let content: (Int) -> Content

    init(@ViewBuilder content: @escaping (Int) -> Content) {
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            let columns = geometry.size.width >= 760 && !dynamicTypeSize.isAccessibilitySize ? 2 : 1
            content(columns)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20).background(Color.card, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct SectionHeading: View {
    let title: String
    var detail: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Spacer()
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }.padding(.top, 8)
    }
}

struct NoticeView: View {
    let message: String
    var symbol = "exclamationmark.circle"
    var body: some View {
        Label(message, systemImage: symbol).font(.subheadline)
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct LoadFailure: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("重新加载", action: retry).buttonStyle(.bordered)
        }.frame(maxWidth: .infinity).padding(28)
    }
}

struct TicketBadge: View {
    let ticket: RepairTicket
    var body: some View {
        Text(ticket.statusName).font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(color).background(color.opacity(0.1), in: Capsule())
    }
    private var color: Color { ticket.isOpen ? .orange : ticket.isAccepted ? .brand : ticket.isCommitted ? .purple : ticket.isClosed ? .green : .secondary }
}

struct RemoteImage: View {
    let source: String
    var contentMode: ContentMode = .fill
    var body: some View {
        // Overlay content cannot enlarge the layout bounds when an image finishes loading.
        Color.clear.overlay {
            Group {
                if source.hasPrefix("data:"), let comma = source.firstIndex(of: ","),
                   let data = Data(base64Encoded: String(source[source.index(after: comma)...])), let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                } else {
                    AsyncImage(url: URL(string: source)) { phase in
                        if let image = phase.image { image.resizable().aspectRatio(contentMode: contentMode) }
                        else { ZStack { Color.brand.opacity(0.08); Image(systemName: "bolt.horizontal.circle").font(.system(size: 40, weight: .light)).foregroundStyle(Color.brand.opacity(0.5)) } }
                    }
                }
            }
        }.clipped().accessibilityHidden(true)
    }
}

struct ExternalLink: View {
    let title, url: String
    var symbol = "arrow.up.right.square"
    var body: some View {
        if let target = URL(string: url), ["http", "https"].contains(target.scheme) {
            Link(destination: target) { Label(title, systemImage: symbol) }
        }
    }
}
