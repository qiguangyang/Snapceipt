import Foundation

/// Shared (main app + Share Extension) bridge over the App Group container. When a user shares a
/// receipt from another app, the extension's popup reads it on-device and writes `<uuid>.jpg` —
/// plus EITHER a `<uuid>.json` holding the parsed `ExtractedReceipt` draft (the popup extracted it)
/// OR a `<uuid>.txt` holding a PDF's embedded text (the no-draft fallback) — into `share-inbox/`.
/// The main app drains that folder on launch / foreground: a draft is filed instantly (no
/// re-extraction); otherwise it runs the normal capture→extract→save pipeline. It deletes the
/// handoff files afterward. The two processes never share the SwiftData store, so a file handoff is
/// the contract between them.
enum ShareInbox {
    /// Must match the `com.apple.security.application-groups` entry in BOTH targets' entitlements.
    static let appGroupId = "group.app.snapceipt"

    /// Test seam: when set, the inbox uses THIS directory instead of the live App Group
    /// container. The unit-test host lacks the App Group entitlement, so
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil and a round-trip test
    /// would silently no-op. Production never sets this (stays nil).
    static var containerOverride: URL?

    static var containerURL: URL? {
        containerOverride
            ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    private static var dir: URL? {
        containerURL?.appendingPathComponent("share-inbox", isDirectory: true)
    }

    /// A receipt waiting to be imported: its JPEG bytes, an optional already-parsed draft (the
    /// extension's popup read it on-device), and optional embedded text (from a PDF, no-draft path).
    struct Pending {
        let id: String
        let jpeg: Data
        let text: String?
        /// Decoded `<uuid>.json` draft if the extension extracted on-device; nil for the
        /// JPEG-only / PDF-text fallback (then the app re-extracts on open).
        let draft: ExtractedReceipt?
        let jpegURL: URL
        let textURL: URL?
        let draftURL: URL?
    }

    /// Extension side: persist a shared receipt (JPEG + optional PDF text) for the app to import.
    /// The no-draft fallback used when on-device extraction is unavailable or failed.
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

    /// Extension side: persist a shared receipt the popup already READ on-device — its JPEG plus the
    /// encoded `ExtractedReceipt` draft (`<uuid>.json`). The app files it WITHOUT re-extracting.
    static func write(jpeg: Data, draft: ExtractedReceipt) throws {
        guard let dir else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        // Write the JPEG FIRST: `pending()` keys off the `.jpg` and only then looks for a sidecar
        // `.json`, so the image is always present before the draft becomes discoverable.
        try jpeg.write(to: dir.appendingPathComponent("\(id).jpg"),
                       options: [.atomic, .completeFileProtection])
        let json = try JSONEncoder().encode(draft)
        try json.write(to: dir.appendingPathComponent("\(id).json"),
                       options: [.atomic, .completeFileProtection])
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
            let draftURL = dir.appendingPathComponent("\(id).json")
            let hasDraft = FileManager.default.fileExists(atPath: draftURL.path)
            // A corrupt/partial `.json` decodes to nil → fall back to the re-extract path
            // (the JPEG is still imported) rather than dropping the receipt.
            let draft: ExtractedReceipt? = hasDraft
                ? (try? Data(contentsOf: draftURL)).flatMap { try? JSONDecoder().decode(ExtractedReceipt.self, from: $0) }
                : nil
            return Pending(id: id, jpeg: jpeg,
                           text: hasText ? try? String(contentsOf: textURL, encoding: .utf8) : nil,
                           draft: draft,
                           jpegURL: jpegURL, textURL: hasText ? textURL : nil,
                           draftURL: hasDraft ? draftURL : nil)
        }
    }

    /// App side: remove a processed receipt (its JPEG + the text/json sidecars, if any).
    static func delete(_ p: Pending) {
        try? FileManager.default.removeItem(at: p.jpegURL)
        if let textURL = p.textURL { try? FileManager.default.removeItem(at: textURL) }
        if let draftURL = p.draftURL { try? FileManager.default.removeItem(at: draftURL) }
    }
}
