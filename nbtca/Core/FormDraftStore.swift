import Foundation
import CryptoKit

nonisolated struct FormDraft: Codable, Equatable, Sendable {
    var fields: [String: String]
}

@MainActor
final class FormDraftStore {
    static let shared = FormDraftStore()
    private let directory: URL
    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("Drafts")) { self.directory = directory }
    private func file(account: String, key: String) -> URL {
        let hash = SHA256.hash(data: Data((account + "|" + key).utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }
    func load(account: String, key: String) -> FormDraft? {
        guard !account.isEmpty, let data = try? Data(contentsOf: file(account: account, key: key)) else { return nil }
        return try? JSONDecoder().decode(FormDraft.self, from: data)
    }
    func save(_ draft: FormDraft, account: String, key: String) throws {
        guard !account.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        try JSONEncoder().encode(draft).write(to: file(account: account, key: key), options: options)
    }
    func remove(account: String, key: String) throws {
        let url = file(account: account, key: key)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}
