import Foundation
import SwiftData
import UIKit
import Observation

/// The capture flow state. `.confirm` shows the just-captured image with Confirm/Retake
/// before OCR runs, so a misframed scan can be retaken without processing it.
enum CaptureStage: Equatable { case camera, confirm, scanning, review, saved }

/// A pickable profile for the Review "Assign to profile" control.
struct ProfileOption: Identifiable, Equatable {
    let id: String
    let name: String
    let type: String   // "personal" | "business"
    let gstRateBp: Int  // the profile's GST rate (basis points) for capture-GST derivation
}

/// Drives snap → OCR → extract → review → save. `@MainActor`; all deps injected as
/// protocols so it is unit-testable with mocks. Never dead-ends offline: a failed
/// `/extract` falls back to the on-device `HeuristicParser`.
@Observable
@MainActor
final class CaptureViewModel {
    private(set) var stage: CaptureStage = .camera
    var draft: ExtractedReceipt?
    /// Which engine produced the current draft (Smart Scan ON = DeepSeek, OFF =
    /// on-device heuristic, ON-but-offline = offline heuristic). Read by ReviewStep.
    var diagnostics: ScanDiagnostics?
    private(set) var capturedImage: UIImage?
    private(set) var rawText: String = ""
    private(set) var recognizedLines: [RecognizedLine] = []
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

    /// The active profile's id — the default Review "Assign to profile" selection.
    var activeProfileId: String { profiles.activeProfileId }

    /// All of the user's profiles, by name, for the Review "Assign to profile" picker.
    var profileOptions: [ProfileOption] {
        profiles.profiles.map { ProfileOption(id: $0.id, name: $0.name, type: $0.type, gstRateBp: $0.gstRateBp) }
    }

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

    /// Called with the captured page (image + already-run OCR lines with geometry).
    /// Moves to `.scanning` and kicks off extraction.
    func onScanned(image: UIImage, lines: [RecognizedLine]) async {
        self.capturedImage = image
        self.recognizedLines = lines
        self.rawText = lines.map(\.text).joined(separator: "\n")
        self.stage = .scanning
        await extract()
    }

    /// ON (Smart Scan): calls `/extract` (DeepSeek); on failure falls back to the
    /// on-device heuristic (status "pending", queued for re-extract). OFF: runs the
    /// on-device heuristic directly with status "done" (never re-extracted) and makes
    /// no network call. Every branch records `diagnostics` and ends at `.review`.
    func extract() async {
        let capturedAt = ExtractedReceipt.ymd(from: Date())
        let started = Date()

        guard AppSettings.smartScanEnabled else {
            // Deliberate OFF: on-device heuristic, FINAL ("done") so the reconciler
            // never re-runs DeepSeek over it. No network, no smart-scan slot.
            let parsed = HeuristicParser.parse(recognizedLines)
            draft = ExtractedReceipt(parsed: parsed, capturedAt: capturedAt ?? "",
                                     extractionStatus: "done")
            smartScanCapped = false
            smartScanCap = nil
            smartScanUsed = nil
            diagnostics = ScanDiagnostics(
                engine: .onDeviceHeuristic, model: nil,
                clientMs: Self.elapsedMs(since: started), serverMs: nil,
                attempts: nil, stub: nil, capped: nil,
                confidence: draft?.confidence ?? 0)
            stage = .review
            return
        }

        do {
            let resp = try await api.extract(ocrText: rawText, source: "scan", capturedAt: capturedAt)
            draft = ExtractedReceipt(response: resp)
            smartScanCapped = resp.meta.capped
            smartScanCap = resp.meta.smartScan?.cap
            smartScanUsed = resp.meta.smartScan?.used
            diagnostics = ScanDiagnostics(
                engine: .deepseek, model: resp.meta.model,
                clientMs: Self.elapsedMs(since: started), serverMs: resp.meta.latencyMs,
                attempts: resp.meta.attempts, stub: resp.meta.stub, capped: resp.meta.capped,
                confidence: draft?.confidence ?? 0)
        } catch {
            // Use the stored recognizedLines (with real bounding boxes) so the
            // offline parser benefits from OCR geometry when available.
            let parsed = HeuristicParser.parse(recognizedLines)
            draft = ExtractedReceipt(parsed: parsed, capturedAt: capturedAt ?? "")
            // Offline/transport failure — not a cap situation; reset all signals.
            smartScanCapped = false
            smartScanCap = nil
            smartScanUsed = nil
            diagnostics = ScanDiagnostics(
                engine: .offlineHeuristic, model: nil,
                clientMs: Self.elapsedMs(since: started), serverMs: nil,
                attempts: nil, stub: nil, capped: nil,
                confidence: draft?.confidence ?? 0)
        }
        stage = .review
    }

    /// Client-measured wall time in ms (never negative).
    private static func elapsedMs(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1000).rounded()))
    }

    // MARK: Save

    /// Persist the (possibly edited) draft: insert the txn + line items, enqueue each
    /// for sync, and create a local-only `PendingReceipt` (writing the reduced JPEG to
    /// Application Support). Guards on an active profile.
    func save(toProfileId profileId: String? = nil) {
        guard let draft else { return }
        // File under the chosen profile (Review "Assign to profile"); fall back to the
        // active profile when no explicit target is given (callers/tests that omit it).
        let targetId = profileId ?? profiles.activeProfileId
        guard let profile = profiles.profiles.first(where: { $0.id == targetId })
            ?? profiles.activeProfile else {
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

    /// A page was captured (scan or import): hold it for the Confirm/Retake step before
    /// running OCR, so a misframed shot can be retaken without processing it.
    func presentCapture(image: UIImage) {
        capturedImage = image
        stage = .confirm
    }

    /// "Retake" from the confirm step: discard the captured image and reopen the camera.
    func retake() {
        capturedImage = nil
        stage = .camera
    }

    /// Reset to the camera for "Snap another".
    func reset() {
        draft = nil; capturedImage = nil; rawText = ""; recognizedLines = []; errorMessage = nil
        diagnostics = nil
        stage = .camera
    }
}

/// App-wide persisted settings (UserDefaults-backed, `sc.*` keys).
enum AppSettings {
    /// Persisted "Smart Scan AI" toggle key.
    static let smartScanEnabledKey = "sc.smartScan.enabled"

    /// Whether scans use DeepSeek (`/extract`) vs the on-device heuristic.
    /// Default ON: `UserDefaults.bool` returns false for a missing key, so read
    /// the object and fall back to `true`.
    static var smartScanEnabled: Bool {
        get { UserDefaults.standard.object(forKey: smartScanEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: smartScanEnabledKey) }
    }
}

/// Which engine produced the current Review draft, plus timing/confidence, surfaced
/// on the Review screen so DeepSeek (Smart Scan ON) and the on-device heuristic
/// (Smart Scan OFF / offline fallback) can be compared back-to-back.
struct ScanDiagnostics: Equatable {
    enum Engine: String, Equatable { case deepseek, onDeviceHeuristic, offlineHeuristic }
    var engine: Engine
    var model: String?      // meta.model (ON path only)
    var clientMs: Int       // client-measured wall time (all paths)
    var serverMs: Int?      // meta.latencyMs (ON path only)
    var attempts: Int?      // meta.attempts (ON path only)
    var stub: Bool?         // meta.stub (ON path only)
    var capped: Bool?       // meta.capped (ON path only)
    var confidence: Double  // draft.confidence (all paths)

    /// One-line monospaced summary for the Review diagnostic row.
    var summary: String {
        var parts: [String] = []
        switch engine {
        case .deepseek:          parts.append("Snapceipt AI")
        case .onDeviceHeuristic: parts.append("on-device heuristic")
        case .offlineHeuristic:  parts.append("on-device (offline)")
        }
        if let attempts { parts.append("\(attempts) try") }
        if let serverMs { parts.append("\(serverMs)ms srv") }
        parts.append("\(clientMs)ms")
        parts.append(String(format: "conf %.2f", confidence))
        if stub == true { parts.append("stub") }
        if capped == true { parts.append("capped") }
        if engine == .offlineHeuristic { parts.append("queued") }
        return parts.joined(separator: " · ")
    }
}
