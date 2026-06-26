import Testing
import Foundation
@testable import Snapceipt

/// Serialized: these mutate the shared `ShareInbox.containerOverride` static.
@MainActor
@Suite(.serialized)
struct ShareInboxTests {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("share-inbox-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func draft() -> ExtractedReceipt {
        ExtractedReceipt(merchant: "Yakitori Bar", date: "2026-06-20", total: 30.00, gst: 2.70,
                         categoryKey: CategoryKey.meals.rawValue, deductible: 50,
                         lineItems: [.init(name: "Skewer", price: 3.00)],
                         confidence: 0.8, needsReview: false, extractionStatus: "pending")
    }

    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

    @Test("write(jpeg:draft:) round-trips through pending(); delete() clears it")
    func draftRoundTrip() throws {
        let dir = tempDir()
        ShareInbox.containerOverride = dir
        defer { ShareInbox.containerOverride = nil; try? FileManager.default.removeItem(at: dir) }

        try ShareInbox.write(jpeg: jpeg, draft: draft())
        let pending = ShareInbox.pending()
        #expect(pending.count == 1)
        let item = pending[0]
        #expect(item.jpeg == jpeg)
        #expect(item.draft?.merchant == "Yakitori Bar")
        #expect(item.draft?.extractionStatus == "pending")
        #expect(item.text == nil)

        ShareInbox.delete(item)
        #expect(ShareInbox.pending().isEmpty)
    }

    @Test("write(jpeg:text:) yields a pending with text and no draft")
    func textFallbackRoundTrip() throws {
        let dir = tempDir()
        ShareInbox.containerOverride = dir
        defer { ShareInbox.containerOverride = nil; try? FileManager.default.removeItem(at: dir) }

        try ShareInbox.write(jpeg: jpeg, text: "WOOLWORTHS\nTOTAL 12.00")
        let pending = ShareInbox.pending()
        #expect(pending.count == 1)
        #expect(pending[0].draft == nil)
        #expect(pending[0].text == "WOOLWORTHS\nTOTAL 12.00")

        ShareInbox.delete(pending[0])
        #expect(ShareInbox.pending().isEmpty)
    }

    @Test("a corrupt .json sidecar decodes to nil draft but the JPEG is still imported")
    func corruptDraftFallsBack() throws {
        let dir = tempDir()
        ShareInbox.containerOverride = dir
        defer { ShareInbox.containerOverride = nil; try? FileManager.default.removeItem(at: dir) }

        try ShareInbox.write(jpeg: jpeg, draft: draft())
        // Corrupt the .json on disk so decoding fails.
        let inbox = dir.appendingPathComponent("share-inbox", isDirectory: true)
        let jsonURL = try FileManager.default
            .contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" }!
        try Data("not valid json".utf8).write(to: jsonURL)

        let pending = ShareInbox.pending()
        #expect(pending.count == 1)
        #expect(pending[0].draft == nil)      // corrupt json -> nil, not a crash
        #expect(pending[0].jpeg == jpeg)       // JPEG still imported
    }
}
