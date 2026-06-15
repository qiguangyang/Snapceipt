import Foundation
import SwiftData
import UIKit
import Observation

/// The 4-stage capture flow state.
enum CaptureStage: Equatable { case camera, scanning, review, saved }

/// Drives snap → OCR → extract → review → save. `@MainActor`; all deps injected as
/// protocols so it is unit-testable with mocks. Never dead-ends offline: a failed
/// `/extract` falls back to the on-device `HeuristicParser`.
@Observable
@MainActor
final class CaptureViewModel {
    private(set) var stage: CaptureStage = .camera
    var draft: ExtractedReceipt?
    private(set) var capturedImage: UIImage?
    private(set) var rawText: String = ""
    var errorMessage: String?
    /// The profile mode ("personal" | "business") the txn was actually filed under,
    /// captured at `save()` from `profiles.activeProfile` (the real save target —
    /// scope-by-active-profileId). The Saved summary reads THIS, never the cosmetic
    /// Review toggle, so the sentence can never name the wrong profile.
    private(set) var savedMode: String = ProfileType.personal.rawValue

    /// Live banner/badge state mirrored from the draft for the Scan/Review steps.
    var confidence: Double { draft?.confidence ?? 0 }
    var needsReview: Bool { draft?.needsReview ?? true }

    /// True when the saved receipt came from the offline HeuristicParser fallback
    /// (`/extract` was unreachable) and is therefore queued in the outbox awaiting a
    /// reconnect drain + server re-extract. Drives the Saved-step "Queued" badge (J18b).
    var isQueued: Bool { draft?.extractionStatus == "pending" }

    /// True when the last `/extract` call was served from the heuristic fallback
    /// because the user's monthly smart-scan cap was exhausted (`meta.capped == true`).
    /// Always false on stub/offline paths. Read by ReviewStep to show the upgrade nudge.
    private(set) var smartScanCapped = false
    /// The monthly cap limit from `meta.smartScan.cap`, used by the upgrade nudge copy.
    /// Nil when the backend omits `smartScan` (stub/offline). Defaults to nil; set
    /// alongside `smartScanCapped` on the real path.
    private(set) var smartScanCap: Int? = nil
    /// The number of smart scans used this month from `meta.smartScan.used`.
    /// Nil on stub/offline paths. Reserved for future "X of Y" display in the nudge.
    private(set) var smartScanUsed: Int? = nil

    /// The active profile's mode ("personal" | "business"), used to initialize the
    /// Review toggle so it opens on the actual save target. Defaults to personal when
    /// there is no active profile.
    var activeMode: String { profiles.activeProfile?.type ?? ProfileType.personal.rawValue }

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let reducer: ImageReducing
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let profiles: ProfilesStore
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let userId: String

    init(api: APIClient, reducer: ImageReducing, sync: any SyncEnqueuing,
         profiles: ProfilesStore, context: ModelContext, userId: String) {
        self.api = api
        self.reducer = reducer
        self.sync = sync
        self.profiles = profiles
        self.context = context
        self.userId = userId
    }

    // MARK: Capture

    /// Called with the captured page (image + already-run OCR text). Moves to
    /// `.scanning` and kicks off extraction.
    func onScanned(image: UIImage, rawText: String) async {
        self.capturedImage = image
        self.rawText = rawText
        self.stage = .scanning
        await extract()
    }

    /// Calls `/extract`; on success maps the response, on failure falls back to the
    /// on-device heuristic. Either way it ends at `.review`.
    func extract() async {
        let capturedAt = ExtractedReceipt.ymd(from: Date())
        do {
            let resp = try await api.extract(ocrText: rawText, source: "scan", capturedAt: capturedAt)
            draft = ExtractedReceipt(response: resp)
            // Thread the cap signal onto the VM so ReviewStep can show the upgrade nudge.
            smartScanCapped = resp.meta.capped
            smartScanCap = resp.meta.smartScan?.cap
            smartScanUsed = resp.meta.smartScan?.used
        } catch {
            let parsed = HeuristicParser.parse(rawText.split(separator: "\n").map {
                RecognizedLine(text: String($0), confidence: 1, boundingBox: .zero)
            })
            draft = ExtractedReceipt(parsed: parsed, capturedAt: capturedAt ?? "")
            // Offline/transport failure — not a cap situation; reset all signals.
            smartScanCapped = false
            smartScanCap = nil
            smartScanUsed = nil
        }
        stage = .review
    }

    // MARK: Save

    /// Persist the (possibly edited) draft: insert the txn + line items, enqueue each
    /// for sync, and create a local-only `PendingReceipt` (writing the reduced JPEG to
    /// Application Support). Guards on an active profile.
    func save() {
        guard let draft else { return }
        guard let profile = profiles.activeProfile else {
            errorMessage = "Select a profile before saving."
            return
        }
        let (txn, items) = ReceiptMapper.map(
            draft, mode: profile.type, profileId: profile.id, userId: userId)
        savedMode = profile.type   // the real save target, for the Saved summary

        context.insert(txn)
        sync.enqueue(op: "upsert", entityType: .transaction, entity: txn)
        for item in items {
            context.insert(item)
            sync.enqueue(op: "upsert", entityType: .lineItem, entity: item)
        }

        let (path, width, height) = persistReducedImage(for: txn.id)
        let pending = PendingReceipt(
            transactionId: txn.id, ocrText: rawText,
            imageLocalPath: path, width: width, height: height)
        context.insert(pending)
        try? context.save()

        stage = .saved
    }

    /// Reduce + write the captured JPEG under Application Support; return its path
    /// and pixel dimensions. Returns an empty path if there is no image.
    private func persistReducedImage(for transactionId: String) -> (path: String, width: Int, height: Int) {
        guard let image = capturedImage else { return ("", 0, 0) }
        let data = reducer.reduce(image)
        let dims = UIImage(data: data) ?? image
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("receipts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(transactionId).jpg")
        try? data.write(to: url, options: .atomic)
        return (url.path, Int(dims.size.width), Int(dims.size.height))
    }

    // MARK: Flow control

    /// Reset to the camera for "Snap another".
    func reset() {
        draft = nil; capturedImage = nil; rawText = ""; errorMessage = nil
        stage = .camera
    }
}
