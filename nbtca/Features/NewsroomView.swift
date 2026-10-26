import SwiftUI

struct NewsroomView: View {
    @State private var store = NewsroomStore.shared
    @State private var category = "全部"
    @State private var search = ""
    private var categories: [String] {
        ["全部"] + (store.feed?.categories ?? []).filter { $0 != "全部" }
    }
    private func articles(in category: String) -> [NewsArticle] {
        (store.feed?.all ?? []).filter {
            (category == "全部" || $0.category == category) &&
            (search.isEmpty || ($0.title + $0.summary).localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        AdaptivePage { columnCount in
            VStack(spacing: 0) {
                UpcomingCourseBanner()
                categoryTabs
                TabView(selection: $category) {
                    ForEach(categories, id: \.self) { item in
                        articlePage(for: item, columnCount: columnCount).tag(item)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .background(Color.canvas).navigationTitle("拔电关机")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索资讯")
        .onChange(of: categories) { _, values in
            if !values.contains(category) { category = "全部" }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新", systemImage: "arrow.clockwise") {
                    Task { await store.refresh(baseURL: AppSettings.shared.baseURL) }
                }.disabled(store.loading)
            }
        }
        .task(id: AppSettings.shared.baseURL) {
            await store.loadIfNeeded(baseURL: AppSettings.shared.baseURL)
        }
    }

    private var categoryTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(categories, id: \.self) { item in
                        Button {
                            withAnimation(.easeInOut(duration: 0.22)) { category = item }
                        } label: {
                            Text(item).font(.subheadline.weight(.medium))
                                .padding(.horizontal, 18).padding(.vertical, 9)
                                .background(category == item ? Color.brand : Color.card, in: Capsule())
                                .foregroundStyle(category == item ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(category == item ? .isSelected : [])
                        .id(item)
                    }
                }.padding(.horizontal, 20).padding(.vertical, 10)
            }
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: category) { _, selected in
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(selected, anchor: .center)
                }
            }
        }.frame(maxWidth: AppLayout.gridMaxWidth).frame(maxWidth: .infinity)
    }
    private func articlePage(for category: String, columnCount: Int) -> some View {
        let pageArticles = articles(in: category)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if store.cached {
                    HStack {
                        Label("上次加载的资讯", systemImage: "internaldrive")
                        Spacer()
                        if let date = store.savedAt { Text(AppDate.display(date)) }
                        if store.loading { ProgressView().controlSize(.small) }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if let error = store.error {
                    NoticeView(message: store.cached ? "正在展示上次加载的内容。\(error)" : error)
                    Button("重新加载") { Task { await store.refresh(baseURL: AppSettings.shared.baseURL) } }.buttonStyle(.bordered)
                }
                if let feed = store.feed, !feed.all.isEmpty {
                    SectionHeading(title: category == "全部" ? "最新动态" : category, detail: "\(pageArticles.count) 篇内容")
                    LazyVGrid(columns: AppLayout.columns(columnCount), alignment: .leading, spacing: 20) {
                        ForEach(Array(pageArticles.enumerated()), id: \.element.id) { index, article in
                            NavigationLink { ArticleDetailView(article: article) } label: {
                                ArticleCard(article: article, prominent: columnCount > 1 || (index == 0 && search.isEmpty))
                            }.buttonStyle(.plain)
                        }
                    }
                    if pageArticles.isEmpty { ContentUnavailableView.search(text: search) }
                } else if store.loading {
                    ProgressView("正在获取资讯…").frame(maxWidth: .infinity).padding(50)
                } else if store.error == nil {
                    ContentUnavailableView("暂无资讯", systemImage: "newspaper")
                }
            }.pageContent(maxWidth: AppLayout.gridMaxWidth)
        }
    }
}

private struct ArticleCard: View {
    let article: NewsArticle
    let prominent: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if prominent {
                RemoteImage(source: article.coverURL).aspectRatio(16.0 / 9, contentMode: .fit)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(article.category.uppercased()).font(.caption2.bold()).tracking(1).foregroundStyle(Color.brand)
                    Text(article.title).font(prominent ? .title3.bold() : .headline).foregroundStyle(.primary).lineLimit(3)
                    if prominent && !article.summary.isEmpty { Text(article.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
                    Text(article.published + " · " + article.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !prominent { Spacer(minLength: 0); RemoteImage(source: article.coverURL).frame(width: 88, height: 88).clipped().clipShape(RoundedRectangle(cornerRadius: 12)) }
            }.padding(20)
        }.background(Color.card, in: RoundedRectangle(cornerRadius: 22)).clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

struct ArticleDetailView: View {
    @State var article: NewsArticle
    @State private var document: String?
    @State private var loading = false
    @State private var error: String?
    @State private var readerID = UUID()
    @State private var cachedAt: Date?
    private struct Snapshot: Codable { let article: NewsArticle; let html: String?; let savedAt: Date }
    private var cacheKey: String { AppSettings.shared.baseURL + "|" + article.id + "|" + article.articleURL }
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 17
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    var body: some View {
        Group {
            if let document {
                VStack(spacing: 0) {
                    if let cachedAt {
                        Text("已保存的正文 · " + AppDate.display(cachedAt)).font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                    if let error { NoticeView(message: error).padding(.horizontal) }
                    ArticleReaderView(document: document, fontSize: fontSize, dark: colorScheme == .dark,
                        openLink: { openURL($0) }, failure: { error = $0; self.document = nil })
                        .id(readerID)
                }
            } else if loading {
                ProgressView("正在加载正文…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 18) {
                    if let error { LoadFailure(message: error) { Task { await load() } } }
                    ExternalLink(title: "在官网阅读原文", url: article.articleURL)
                }.pageContent(maxWidth: 760)
            }
        }.background(Color.canvas).navigationTitle("文章").navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                Button("更新正文", systemImage: "arrow.clockwise") { Task { await load(refresh: true) } }.disabled(loading)
                if let url = URL(string: article.articleURL), ["https", "http"].contains(url.scheme) { ShareLink(item: url) }
            }.task { if document == nil { await load() } }
    }
    private func load(refresh: Bool = false) async {
        guard !loading else { return }
        loading = true; error = nil
        let key = cacheKey
        defer { loading = false }
        if !refresh, let data = await ArticleCache.shared.read(key),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data), saved.article.id == article.id {
            do {
                document = try ArticleReaderView.document(article: saved.article, originalHTML: saved.html)
                cachedAt = saved.savedAt; readerID = UUID(); return
            } catch { /* Fetch a fresh copy if a cached document cannot render. */ }
        }
        // Fetch the original independently: the BFF may have flattened its tables
        // and paragraphs. Markdown remains available when the site is offline.
        async let page = try? ArticlePage.fetch(article.articleURL)
        if article.markdown.isEmpty {
            do { article = try await APIClient.shared.article(article.id) }
            catch is CancellationError { return }
            catch { if article.summary.isEmpty { self.error = error.localizedDescription } }
        }
        let original = await page
        guard !Task.isCancelled else { return }
        if original == nil && article.markdown.isEmpty && document != nil {
            error = "正文更新失败，正在显示已保存的内容"; return
        }
        do {
            document = try ArticleReaderView.document(article: article, originalHTML: original)
            readerID = UUID(); error = nil; cachedAt = nil
            if original != nil || !article.markdown.isEmpty {
                let saved = Snapshot(article: article, html: original, savedAt: Date())
                if let data = try? JSONEncoder().encode(saved) { await ArticleCache.shared.write(data, key: key) }
            }
        } catch { self.error = error.localizedDescription }
    }
}

private extension NewsroomStore {
    static let shared = NewsroomStore { _ in try await APIClient.shared.object("/newsroom/feed") }
}
