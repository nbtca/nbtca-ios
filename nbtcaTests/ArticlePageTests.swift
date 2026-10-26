import XCTest
@testable import nbtca

final class ArticlePageTests: XCTestCase {
    func testOnlyPublicAssociationArticleURLsAreFetched() {
        XCTAssertNotNil(ArticlePage.sourceURL("https://nbtca.space/posts/test/"))
        for value in ["http://nbtca.space/posts/test/", "https://example.com/posts/test/", "https://nbtca.space/login", "https://user:pass@nbtca.space/posts/test/", "https://nbtca.space:8443/posts/test/"] {
            XCTAssertNil(ArticlePage.sourceURL(value))
        }
    }
    func testOriginalHTMLIsReturnedWithoutFlatteningItsTables() async throws {
        let session = transport(status: 200, mime: "text/html", body: "<table><tr><td>原表格</td></tr></table>")
        defer { session.invalidateAndCancel() }
        let html = try await ArticlePage.fetch("https://nbtca.space/posts/test/", transport: session)
        XCTAssertEqual(html, "<table><tr><td>原表格</td></tr></table>")
    }
    func testErrorResponsesUseMarkdownFallback() async throws {
        let session = transport(status: 503, mime: "text/html", body: "error")
        defer { session.invalidateAndCancel() }
        let html = try await ArticlePage.fetch("https://nbtca.space/posts/test/", transport: session)
        XCTAssertNil(html)
    }
    func testNonHTMLResponseIsRejected() async throws {
        let session = transport(status: 200, mime: "application/json", body: "{}")
        defer { session.invalidateAndCancel() }
        let html = try await ArticlePage.fetch("https://nbtca.space/posts/test/", transport: session)
        XCTAssertNil(html)
    }
    func testResponseOutsideArticleOriginIsRejected() async throws {
        let session = transport(status: 200, mime: "text/html", body: "<p>login</p>", responseURL: "https://example.com/login")
        defer { session.invalidateAndCancel() }
        let html = try await ArticlePage.fetch("https://nbtca.space/posts/test/", transport: session)
        XCTAssertNil(html)
    }
    private func transport(status: Int, mime: String, body: String, responseURL: String? = nil) -> URLSession {
        ArticlePageMock.response = HTTPURLResponse(url: URL(string: responseURL ?? "https://nbtca.space/posts/test/")!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": mime])!
        ArticlePageMock.body = Data(body.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArticlePageMock.self]
        return URLSession(configuration: config)
    }
}

private final class ArticlePageMock: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: HTTPURLResponse!
    nonisolated(unsafe) static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: Self.response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
