import Foundation
import CryptoKit

/// Bounded public-content cache. Disk access never runs on the UI thread.
actor ArticleCache {
    static let shared = ArticleCache()
    private let directory: URL
    init(directory: URL = URL.cachesDirectory.appendingPathComponent("Articles")) { self.directory = directory }
    private func file(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }
    func read(_ key: String) -> Data? {
        let url = file(key)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024 else { return nil }
        return try? Data(contentsOf: url)
    }
    func write(_ data: Data, key: String) {
        guard data.count <= 8 * 1024 * 1024 else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file(key), options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            let sorted = files.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            for old in sorted.dropFirst(30) { try? FileManager.default.removeItem(at: old) }
        } catch { /* Public cache failure must not prevent reading. */ }
    }
}
