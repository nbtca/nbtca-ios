import Foundation

nonisolated enum ArticlePage {
    static func sourceURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host?.lowercased() == "nbtca.space",
              url.path.hasPrefix("/posts/"), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        return url
    }
    /// Public article requests never share the school or NBTCA login containers.
    static func fetch(_ value: String, transport: URLSession? = nil) async throws -> String? {
        guard let url = sourceURL(value) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 10
        let session = transport ?? URLSession(configuration: config)
        defer { if transport == nil { session.invalidateAndCancel() } }
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let final = response.url, sourceURL(final.absoluteString) != nil,
              response.mimeType == "text/html", data.count <= 4 * 1024 * 1024 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
