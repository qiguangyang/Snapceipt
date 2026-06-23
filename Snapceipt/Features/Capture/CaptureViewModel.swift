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
    /// True once the user has edited the draft on the Review screen. When the user taps
    /// "Review now" the AI keeps running and updates the draft in place — but only while this
    /// is false, so a late AI result never clobbers edits the user already made.
    private(set) var draftUserEdited = false
    /// Which engine produced the current draft (Smart Scan ON = DeepSeek, OFF =
    /// on-device heuristic, ON-but-offline = offline heuristic). Read by ReviewStep.
    var diagnostics: ScanDiagnostics?
    private(set) var capturedImage: UIImage?
    private(set) var rawText: String = ""
    private(set) var layoutText: String = ""
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
    /// The in-flight `/extract` call, OWNED by the view-model (not the SwiftUI view that
    /// kicked off the scan). This decouples the AI wait from view lifecycle: dismissing
    /// the sheet or a view re-render no longer cancels the call (which the old inline
    /// `await` turned into a spurious "offline" result). Cancelled deliberately by
    /// `reviewNow()` / `autosaveOnExitIfScanning()` / `reset()`.
    @ObservationIgnored private var extractTask: Task<Void, Never>?

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
        self.draftUserEdited = false   // fresh scan — the AI result may apply in place
        // The model reads `rawText` (raw observation order) — safest for it, since merging a
        // curved photo can split decimals ("19.90"→"19","90") and merge header lines, which
        // confuses it. `layoutText` reconstructs visual rows (pairs name↔right-column price);
        // the server's deterministic line-item parser uses it for structured receipts. For PDF
        // text (zero-box lines, already in reading order) both are the same.
        self.rawText = lines.map(\.text).joined(separator: "\n")
        self.layoutText = ReceiptRows.rows(from: lines).joined(separator: "\n")
        self.stage = .scanning
        // Run extraction as an OWNED unstructured task so a torn-down view can't cancel it
        // (the old inline `await extract()` inherited the view's Task and turned dismissal
        // into a fake "offline" result). We still await the task's value so `onScanned`'s
        // completion contract — and the ScanStep→ReviewStep auto-advance — are unchanged.
        let task = Task { await self.extract() }
        extractTask = task
        await task.value
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
            let resp = try await api.extract(ocrText: rawText, layoutText: layoutText, source: "scan", capturedAt: capturedAt)
            // Cancelled (saved on exit / dismissed) → drop the result. Edited → the user has
            // taken over the draft on Review, so don't clobber it. Otherwise the AI result is
            // applied in place — including when the user tapped "Review now" and is still on
            // Review, so the screen refreshes from the on-device draft to the AI result.
            if Task.isCancelled || draftUserEdited { return }
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
            // A deliberate cancellation (autosaveOnExitIfScanning / dismiss / reset) already
            // set the UI state it wants, and an edited draft is the user's — do NOT overwrite
            // either with an "offline" draft. Only a GENUINE transport/decode failure on an
            // untouched draft falls back below. (Also fixes the spurious "offline" the old
            // catch-all produced on teardown.)
            if error is CancellationError || Task.isCancelled || draftUserEdited { return }
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
        // First resolution advances Scan → Review. If the user already tapped "Review now"
        // (stage == .review) we stay put and only the draft refreshed above; if they've moved
        // on to .saved, never yank them back.
        if stage == .scanning { stage = .review }
    }

    /// Client-measured wall time in ms (never negative).
    private static func elapsedMs(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1000).rounded()))
    }

    /// "Review now" (quit waiting): stop waiting for the AI and drop to Review with the
    /// on-device heuristic, kept `pending` so the reconciler still upgrades it when the AI
    /// lands. No-op once the AI has already resolved (stage left `.scanning`) — that guard
    /// makes the button race-safe against an extraction that finishes at the same instant.
    /// Cancels the in-flight call so it doesn't keep running (or burn a smart-scan slot).
    func reviewNow() {
        guard stage == .scanning else { return }
        let started = Date()
        let capturedAt = ExtractedReceipt.ymd(from: Date())
        draft = ExtractedReceipt(parsed: HeuristicParser.parse(recognizedLines),
                                 capturedAt: capturedAt ?? "")   // defaults to "pending"
        draftUserEdited = false   // this is the on-device draft, not a user edit
        smartScanCapped = false; smartScanCap = nil; smartScanUsed = nil
        diagnostics = ScanDiagnostics(
            engine: .onDeviceQueued, model: nil,
            clientMs: Self.elapsedMs(since: started), serverMs: nil,
            attempts: nil, stub: nil, capped: nil,
            confidence: draft?.confidence ?? 0)
        stage = .review
        // NOTE: do NOT cancel extractTask — let the AI finish and refresh the Review screen in
        // place (extract() applies the result while draftUserEdited is false). If the user
        // edits or saves first, those paths stop it (draftUserEdited guard / save() cancels).
    }

    /// Apply a user edit from the Review screen, marking the draft user-owned so a late AI
    /// result won't clobber it. Compares first so a spurious binding write (no real change)
    /// doesn't suppress the in-place AI refresh.
    func editDraft(_ newDraft: ExtractedReceipt) {
        if newDraft != draft { draftUserEdited = true }
        draft = newDraft
    }

    /// Cancel the in-flight AI extraction (e.g. the user dismissed the Review screen without
    /// saving) so it doesn't keep running / burn a smart-scan slot. No-op if already done.
    func cancelExtraction() {
        extractTask?.cancel()
    }

    /// Leaving (close or app background) DURING scanning: persist what we have as a PENDING
    /// receipt so the scan isn't lost and the reconciler upgrades it to the full AI result
    /// on its next pass (survives force-kill — it's on disk, flagged `autoSaved` so the
    /// reconciler does a full replace rather than enrich). No-op outside `.scanning`.
    func autosaveOnExitIfScanning() {
        guard stage == .scanning else { return }
        extractTask?.cancel()
        // save() needs a profile to file under; if none resolves it returns early WITHOUT
        // persisting (and there's no UI to surface its errorMessage mid-scan), which would
        // silently drop the scan — the exact data loss this feature exists to prevent. Guard
        // here and only proceed when a profile is resolvable. (Rare: profile deleted/rescoped
        // mid-scan; the app otherwise requires a profile via onboarding.)
        guard profiles.activeProfile != nil
            || profiles.profiles.contains(where: { $0.id == profiles.activeProfileId }) else {
            errorMessage = "No active profile — scan not saved."
            return
        }
        if draft == nil {
            let capturedAt = ExtractedReceipt.ymd(from: Date())
            draft = ExtractedReceipt(parsed: HeuristicParser.parse(recognizedLines),
                                     capturedAt: capturedAt ?? "")   // "pending"
        }
        save(autoSaved: true)
    }

    // MARK: Save

    /// Persist the (possibly edited) draft: insert the txn + line items, enqueue each
    /// for sync, and create a local-only `PendingReceipt` (writing the reduced JPEG to
    /// Application Support). Guards on an active profile.
    func save(toProfileId profileId: String? = nil, autoSaved: Bool = false) {
        guard let draft else { return }
        // The receipt is now persisted; if the AI is still in-flight (saved straight after
        // "Review now"), stop it — the PendingExtractionReconciler owns the upgrade from here.
        extractTask?.cancel()
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
            imageLocalPath: path, width: width, height: height,
            autoSaved: autoSaved)
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
        // Receipts are the most sensitive on-device artifact: protect at rest with
        // NSFileProtectionComplete (encrypted while the device is locked), not the
        // default CompleteUntilFirstUnlock.
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
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

    /// An imported file (Photos/Files). Imports skip the camera edge-adjust/dewarp (they're
    /// already clean documents) and go straight to extract. PDFs pass their embedded `text`
    /// so OCR is skipped entirely — far more accurate than re-OCRing a rendered page; photos
    /// and scanned (image-only) PDFs pass nil and fall back to on-device OCR.
    func ingestImport(image: UIImage, text: String?) async {
        if let text, !text.isEmpty {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map {
                RecognizedLine(text: String($0), confidence: 1, boundingBox: .zero)
            }
            await onScanned(image: image, lines: lines)
        } else {
            let lines = (try? await OCR.recognize(in: image)) ?? []
            await onScanned(image: image, lines: lines)
        }
    }

    /// Reset to the camera for "Snap another".
    func reset() {
        extractTask?.cancel()
        draftUserEdited = false
        draft = nil; capturedImage = nil; rawText = ""; layoutText = ""; recognizedLines = []; errorMessage = nil
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
    enum Engine: String, Equatable { case deepseek, onDeviceHeuristic, offlineHeuristic, onDeviceQueued }
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
        case .onDeviceQueued:    parts.append("on-device · finishing with AI…")
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
