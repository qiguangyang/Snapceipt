import Foundation

/// Shared (main app + Share Extension) bridge over the App Group container. When a user shares a
/// receipt from another app, the extension writes `<uuid>.jpg` — plus an optional `<uuid>.txt`
/// holding a PDF's embedded text — into `share-inbox/`. The main app drains that folder on launch
/// / foreground through the normal capture→extract→save pipeline, then deletes the files. The two
/// processes never share the SwiftData store, so a file handoff is the contract between them.
enum ShareInbox {
    /// Must match the `com.apple.security.application-groups` entry in BOTH targets' entitlements.
    static let appGroupId = "group.app.snapceipt"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    private static var dir: URL? {
        containerURL?.appendingPathComponent("share-inbox", isDirectory: true)
    }

    /// A receipt waiting to be imported: its JPEG bytes + optional embedded text (from a PDF).
    struct Pending {
        let id: String
        let jpeg: Data
        let text: String?
        let jpegURL: URL
        let textURL: URL?
    }

    /// Extension side: persist a shared receipt (JPEG + optional PDF text) for the app to import.
    static func write(jpeg: Data, text: String?) throws {
        guard let dir else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        try jpeg.write(to: dir.appendingPathComponent("\(id).jpg"),
                       options: [.atomic, .completeFileProtection])
        if let text, !text.isEmpty {
            try? text.data(using: .utf8)?.write(to: dir.appendingPathComponent("\(id).txt"),
                                                options: [.atomic, .completeFileProtection])
        }
    }

    /// App side: every pending receipt currently in the inbox (newest-agnostic; caller orders).
    static func pending() -> [Pending] {
        guard let dir,
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return urls.filter { $0.pathExtension == "jpg" }.compactMap { jpegURL in
            guard let jpeg = try? Data(contentsOf: jpegURL) else { return nil }
            let id = jpegURL.deletingPathExtension().lastPathComponent
            let textURL = dir.appendingPathComponent("\(id).txt")
            let hasText = FileManager.default.fileExists(atPath: textURL.path)
            return Pending(id: id, jpeg: jpeg,
                           text: hasText ? try? String(contentsOf: textURL, encoding: .utf8) : nil,
                           jpegURL: jpegURL, textURL: hasText ? textURL : nil)
        }
    }

    /// App side: remove a processed receipt (its JPEG + the text sidecar, if any).
    static func delete(_ p: Pending) {
        try? FileManager.default.removeItem(at: p.jpegURL)
        if let textURL = p.textURL { try? FileManager.default.removeItem(at: textURL) }
    }
}
