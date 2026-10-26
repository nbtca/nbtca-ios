import SwiftUI
import WebKit

private enum ArticleReaderResources {
    static func text(_ name: String, _ ext: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "ArticleReader")
                ?? Bundle.main.url(forResource: name, withExtension: ext) else { throw CocoaError(.fileNoSuchFile) }
        return try String(contentsOf: url, encoding: .utf8)
    }
    static let assets: Result<(String, String), Error> = Result {
        let css = try text("article-reader", "css")
        let js = try [text("markdown-it.min", "js"), text("purify.min", "js"), text("article-reader", "js")].joined(separator: "\n;\n")
        return (css, js)
    }
    static func document(article: NewsArticle, originalHTML: String?) throws -> String {
        let (css, js) = try assets.get()
        let payload: [String: Any] = ["title": article.title, "category": article.category,
            "author": article.author, "published": article.published, "tags": article.tags,
            "cover": article.coverURL, "url": article.articleURL, "summary": article.summary,
            "markdown": article.markdown, "originalHTML": originalHTML ?? ""]
        // Base64 keeps article text (including </script>) out of executable HTML.
        let data = try JSONSerialization.data(withJSONObject: payload).base64EncodedString()
        let nonce = UUID().uuidString
        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; img-src https: http: data:; font-src 'none'; connect-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'">
        <style>\(css)</style></head><body><main id="reader"></main>
        <script nonce="\(nonce)">\(js)
        ArticleReader.render(JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(data)'), c => c.charCodeAt(0)))));
        </script></body></html>
        """
    }
}

struct ArticleReaderView: UIViewRepresentable {
    let document: String
    let fontSize: CGFloat
    let dark: Bool
    let openLink: (URL) -> Void
    let failure: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(openLink: openLink, failure: failure) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "articleLink")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.backgroundColor = .clear
        view.allowsLinkPreview = false
        view.loadHTMLString(document, baseURL: nil)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.fontSize = fontSize; context.coordinator.dark = dark
        context.coordinator.openLink = openLink; context.coordinator.failure = failure
        if !view.isLoading { context.coordinator.updateAppearance(view) }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "articleLink")
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var fontSize: CGFloat = 17
        var dark = false
        var openLink: (URL) -> Void
        var failure: (String) -> Void
        init(openLink: @escaping (URL) -> Void, failure: @escaping (String) -> Void) { self.openLink = openLink; self.failure = failure }
        func updateAppearance(_ view: WKWebView) {
            view.evaluateJavaScript("ArticleReader.appearance(\(fontSize), \(dark));", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { updateAppearance(webView) }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let value = message.body as? String, let url = URL(string: value),
                  ["https", "http", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") else { return }
            openLink(url)
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .other, action.request.url?.absoluteString == "about:blank" { decisionHandler(.allow) }
            else { decisionHandler(.cancel) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { failure(error.localizedDescription) }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failure("正文加载失败，请重试") }
    }
    static func document(article: NewsArticle, originalHTML: String?) throws -> String {
        try ArticleReaderResources.document(article: article, originalHTML: originalHTML)
    }
}
