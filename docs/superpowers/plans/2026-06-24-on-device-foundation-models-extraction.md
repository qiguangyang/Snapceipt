# On-device Extraction via Apple Foundation Models — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the on-device regex `HeuristicParser` with Apple Foundation Models (iOS 26+) as the on-device extraction engine; cloud AI for non-FM devices; queue offline scans on non-FM devices; FM-first with a cloud upgrade when FM is low-confidence.

**Architecture:** A capability-and-network router in `CaptureViewModel.extract()` selects the engine. FM is wrapped behind a testable `OnDeviceExtracting` protocol (real impl `#available(iOS 26)`-gated; `nil` on non-FM devices). Low-confidence FM and non-FM-offline reuse the existing `draftRevision` in-place refresh + `PendingExtractionReconciler`.

**Tech Stack:** Swift, SwiftUI, SwiftData, Apple FoundationModels framework (iOS 26), Swift Testing (`import Testing`).

## Global Constraints

- Deployment target stays **iOS 17.0**. ALL Foundation Models code is `@available(iOS 26, *)` + runtime-availability gated; iOS 17–25 and non-eligible devices must compile and run unaffected (cloud/queue path).
- No new third-party dependencies; no app-size increase (FM ships with the OS).
- Money stays `Decimal` in app code — convert FM `Double` at the boundary.
- `UPGRADE_THRESHOLD = 0.8` (FM confidence below this triggers the cloud upgrade; matches the server `needsReview` line).
- Behavior matrix is authoritative (see spec `docs/superpowers/specs/2026-06-24-on-device-foundation-models-extraction-design.md`).
- Test runner: `xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/<Suite>` (regenerate the project with `xcodegen generate` first if files were added).
- Keep `ReceiptRows`, the cloud `/extract` path, the server-side heuristic, and the pending/reconciler machinery. Remove only the iOS `HeuristicParser`.

## File Structure

- **Create** `Snapceipt/Features/Capture/Scanner/OnDeviceExtracting.swift` — the protocol seam + `OnDeviceAI` capability gate/factory.
- **Create** `Snapceipt/Features/Capture/Scanner/FoundationModelExtractor.swift` — `@available(iOS 26, *)` FM impl + `FMReceipt`/`FMLineItem` `@Generable` types + mapping.
- **Create** `Snapceipt/Features/Capture/Scanner/OnDeviceGuards.swift` — pure GST/total guard applied to FM output.
- **Modify** `Snapceipt/Features/Capture/ExtractedReceipt.swift` — add `static func empty(capturedAt:)`; remove `init(parsed:)` (Task 6).
- **Modify** `Snapceipt/Features/Capture/CaptureViewModel.swift` — router; inject `onDeviceExtractor` + `isOnline`; `reviewNow`/`autosaveOnExitIfScanning` use `.empty`; add `.foundationModel` engine usage.
- **Modify** `Snapceipt/Features/Capture/CaptureHost.swift` — `CaptureFactory.makeViewModel` wires the real extractor + reachability.
- **Modify** `Snapceipt/Features/Capture/PendingExtractionReconciler.swift` — full-replace for FM-low-confidence pending.
- **Modify** `Snapceipt/Features/Capture/CaptureViewModel.swift` (`ScanDiagnostics`) — add `.foundationModel`; remove `.onDeviceHeuristic`/`.offlineHeuristic` (Task 6).
- **Delete** `Snapceipt/Features/Capture/Scanner/HeuristicParser.swift` + `ParsedReceipt` + `SnapceiptTests/HeuristicParserTests.swift` (Task 6).
- **Tests** `SnapceiptTests/OnDeviceGuardsTests.swift`, `SnapceiptTests/ExtractRouterTests.swift`, plus edits to `SnapceiptTests/CaptureViewModelTests.swift`, `SnapceiptTests/PendingExtractionReconcilerTests.swift`.

---

### Task 1: Guards, empty draft, and the extractor seam (pure Swift)

**Files:**
- Create: `Snapceipt/Features/Capture/Scanner/OnDeviceGuards.swift`
- Create: `Snapceipt/Features/Capture/Scanner/OnDeviceExtracting.swift`
- Modify: `Snapceipt/Features/Capture/ExtractedReceipt.swift`
- Test: `SnapceiptTests/OnDeviceGuardsTests.swift`

**Interfaces:**
- Produces: `protocol OnDeviceExtracting { func extract(ocrText: String, layoutText: String, capturedAt: String) async throws -> ExtractedReceipt }`
- Produces: `enum OnDeviceGuards { static func reconcile(_ r: ExtractedReceipt, ocrText: String) -> ExtractedReceipt }`
- Produces: `static func ExtractedReceipt.empty(capturedAt: String, extractionStatus: String) -> ExtractedReceipt`
- Consumes (existing): `ExtractedReceipt` memberwise init; `ExtractedReceipt.LineItemDraft`.

- [ ] **Step 1: Write the failing guard test**

Create `SnapceiptTests/OnDeviceGuardsTests.swift`:
```swift
import Testing
import Foundation
@testable import Snapceipt

@MainActor
struct OnDeviceGuardsTests {
    private func receipt(total: Decimal, gst: Decimal?) -> ExtractedReceipt {
        ExtractedReceipt(merchant: "M", date: "2026-06-20", total: total, gst: gst,
                         categoryKey: "meals", deductible: 50, lineItems: [],
                         confidence: 0.9, needsReview: false)
    }

    @Test("honors a printed GST even slightly above total/11 (surcharge)")
    func honorsPrintedGst() {
        let out = OnDeviceGuards.reconcile(receipt(total: 117.23, gst: 99),
                                           ocrText: "Subtotal 115.50\nGST 11.55\nTotal 117.23")
        #expect(out.gst == Decimal(string: "11.55"))
    }

    @Test("clamps a hallucinated GST to total/11 when no printed GST line")
    func clampsGst() {
        let out = OnDeviceGuards.reconcile(receipt(total: 110.0, gst: 88), ocrText: "Total 110.00")
        #expect(out.gst == Decimal(string: "10.0")) // 110/11
    }

    @Test("empty() yields a blank pending draft dated capturedAt")
    func emptyDraft() {
        let e = ExtractedReceipt.empty(capturedAt: "2026-06-24", extractionStatus: "pending")
        #expect(e.merchant == "")
        #expect(e.total == 0)
        #expect(e.date == "2026-06-24")
        #expect(e.extractionStatus == "pending")
        #expect(e.needsReview == true)
        #expect(e.lineItems.isEmpty)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/OnDeviceGuardsTests`
Expected: FAIL (`OnDeviceGuards` / `empty` not found).

- [ ] **Step 3: Implement `OnDeviceGuards`** — port the server `reconcileGst` (src/lib/deepseek.ts:169) to Swift.

Create `Snapceipt/Features/Capture/Scanner/OnDeviceGuards.swift`:
```swift
import Foundation

/// Minimal deterministic safety net for an on-device LLM result (it's a small model and can
/// hallucinate). Mirrors the server's GST reconcile (src/lib/deepseek.ts reconcileGst): honor a
/// printed "GST $X" line; otherwise clamp an impossible model GST to total/11. NOT the old
/// HeuristicParser — just the AU-tax guard the cloud path also applies.
enum OnDeviceGuards {
    static func reconcile(_ r: ExtractedReceipt, ocrText: String) -> ExtractedReceipt {
        var out = r
        out.total = max(0, r.total)
        out.gst = reconcileGst(r.gst, total: out.total, ocrText: ocrText)
        return out
    }

    /// Largest amount on a line containing the word "GST" (nil if none carries an amount).
    private static func printedGst(_ ocrText: String) -> Decimal? {
        var found: Decimal?
        for line in ocrText.split(whereSeparator: \.isNewline) {
            guard line.range(of: #"\bgst\b"#, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            let matches = line.matches(of: try! Regex(#"(\d{1,3}(?:[ ,]\d{3})*\.\d{2})"#))
            if let last = matches.last,
               let v = Decimal(string: String(line[last.range]).replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")) {
                found = v
            }
        }
        return found
    }

    private static func reconcileGst(_ gst: Decimal?, total: Decimal, ocrText: String) -> Decimal? {
        guard total > 0 else { return nil }
        let cap = round2(total / 11)
        let printedCap = total * Decimal(string: "0.12")!   // surcharge/rounding allowance
        if let printed = printedGst(ocrText), printed >= 0, printed <= printedCap { return round2(printed) }
        if let gst, gst > cap + Decimal(string: "0.005")! { return cap }
        return gst
    }

    private static func round2(_ d: Decimal) -> Decimal {
        var v = d, r = Decimal()
        NSDecimalRound(&r, &v, 2, .plain)
        return r
    }
}
```

- [ ] **Step 4: Add `ExtractedReceipt.empty` + the protocol**

In `Snapceipt/Features/Capture/ExtractedReceipt.swift`, inside the existing `extension ExtractedReceipt { ... }`, add:
```swift
    /// A blank draft for the manual / queued-offline path (no on-device AI available).
    /// `date` defaults to the capture date; everything else empty; needsReview = true.
    static func empty(capturedAt: String, extractionStatus: String = "done") -> ExtractedReceipt {
        ExtractedReceipt(
            merchant: "", date: capturedAt, total: 0, gst: nil,
            categoryKey: CategoryKey.office.rawValue, deductible: 100, lineItems: [],
            confidence: 0, needsReview: true, extractionStatus: extractionStatus)
    }
```

Create `Snapceipt/Features/Capture/Scanner/OnDeviceExtracting.swift`:
```swift
import Foundation

/// On-device extraction engine seam. The real implementation is Foundation Models (iOS 26+);
/// the view-model holds an optional one (nil on non-FM devices) so the router stays testable.
protocol OnDeviceExtracting {
    /// Extract a receipt fully on-device. The returned draft's `confidence` drives the
    /// FM-low-confidence → cloud-upgrade decision in the router.
    func extract(ocrText: String, layoutText: String, capturedAt: String) async throws -> ExtractedReceipt
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/OnDeviceGuardsTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**
```bash
git add Snapceipt/Features/Capture/Scanner/OnDeviceGuards.swift Snapceipt/Features/Capture/Scanner/OnDeviceExtracting.swift Snapceipt/Features/Capture/ExtractedReceipt.swift SnapceiptTests/OnDeviceGuardsTests.swift
git commit -m "feat(capture): on-device guards + extractor seam + empty draft"
```

---

### Task 2: `FoundationModelExtractor` (iOS 26 real FM impl)

**Files:**
- Create: `Snapceipt/Features/Capture/Scanner/FoundationModelExtractor.swift`
- Modify: `Snapceipt/Features/Capture/Scanner/OnDeviceExtracting.swift` (add `OnDeviceAI`)

**Interfaces:**
- Consumes: `OnDeviceExtracting`, `OnDeviceGuards.reconcile`, `ExtractedReceipt`, `ReceiptRows` output (`layoutText`), `CategoryKey`.
- Produces: `enum OnDeviceAI { static func makeExtractor() -> OnDeviceExtracting? }` (returns the FM extractor when available, else `nil`).

> **API NOTE:** Foundation Models is a new iOS 26 framework. The structure below uses its documented API (`SystemLanguageModel`, `LanguageModelSession`, `@Generable`, `@Guide`, `respond(to:generating:)`). **Verify the exact symbol names/signatures against the iOS 26 SDK (Xcode 26 autocomplete + developer.apple.com/documentation/FoundationModels) while implementing** — adjust the call sites if Apple's names differ. The mapping + guard logic is fixed regardless.

- [ ] **Step 1: Write the availability+mapping seam test (pure, no FM)**

The FM call itself needs a device; unit-test only the pure mapping. Add to `SnapceiptTests/OnDeviceGuardsTests.swift`:
```swift
    @Test("FMReceipt maps to ExtractedReceipt (Double->Decimal, nil date kept) under guards")
    func fmMapping() {
        let mapped = FoundationModelMapping.toReceipt(
            merchant: "Cafe", date: nil, total: 10.0, gst: 0.91,
            category: "meals", deductible: 50,
            items: [("Latte", 5.0), ("Tart", 5.0)], confidence: 0.85,
            capturedAt: "2026-06-24",
            ocrText: "Cafe\nGST 0.91\nTotal 10.00")
        #expect(mapped.merchant == "Cafe")
        #expect(mapped.date == "2026-06-24")          // nil date backfills to capturedAt
        #expect(mapped.total == Decimal(string: "10.00"))
        #expect(mapped.gst == Decimal(string: "0.91"))
        #expect(mapped.lineItems.count == 2)
        #expect(mapped.confidence == 0.85)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodegen generate && xcodebuild test ... -only-testing:SnapceiptTests/OnDeviceGuardsTests`
Expected: FAIL (`FoundationModelMapping` not found).

- [ ] **Step 3: Implement the extractor + a pure mapping helper**

Create `Snapceipt/Features/Capture/Scanner/FoundationModelExtractor.swift`:
```swift
import Foundation

/// Pure FM-output → ExtractedReceipt mapping (no FoundationModels import) so it is unit-testable
/// without a device. Converts Double→Decimal, backfills a nil date to capturedAt, applies guards.
enum FoundationModelMapping {
    static func toReceipt(
        merchant: String, date: String?, total: Double, gst: Double?,
        category: String, deductible: Int?, items: [(String, Double)],
        confidence: Double, capturedAt: String, ocrText: String
    ) -> ExtractedReceipt {
        let cat = CategoryKey(rawValue: category)?.rawValue ?? CategoryKey.office.rawValue
        let draft = ExtractedReceipt(
            merchant: merchant,
            date: (date?.isEmpty == false ? date! : capturedAt),
            total: Decimal(total),
            gst: gst.map { Decimal($0) },
            categoryKey: cat,
            deductible: deductible,
            lineItems: items.map { .init(name: $0.0, price: Decimal($0.1)) },
            confidence: confidence,
            needsReview: confidence < 0.8,
            extractionStatus: "done")
        return OnDeviceGuards.reconcile(draft, ocrText: ocrText)
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26, *)
@Generable
struct FMReceipt {
    @Guide(description: "Merchant / store name") var merchant: String
    @Guide(description: "Date as YYYY-MM-DD, or omit if not found") var date: String?
    @Guide(description: "GST-inclusive grand total, positive number") var total: Double
    @Guide(description: "Printed GST amount, or omit if none printed") var gst: Double?
    @Guide(description: "One of: meals, groceries, fuel, software, office, home, health, travel, income")
    var category: String
    @Guide(description: "0-100 deductible percent, or omit") var deductible: Int?
    @Guide(description: "Purchased products only; exclude ABN/store/payment/totals/promos", .count(0...50))
    var lineItems: [FMLineItem]
    @Guide(description: "0..1 confidence") var confidence: Double
}

@available(iOS 26, *)
@Generable
struct FMLineItem {
    @Guide(description: "Product name") var name: String
    @Guide(description: "Line total in dollars") var price: Double
}

/// On-device extraction via Apple Foundation Models (guided generation).
@available(iOS 26, *)
struct FoundationModelExtractor: OnDeviceExtracting {
    func extract(ocrText: String, layoutText: String, capturedAt: String) async throws -> ExtractedReceipt {
        let instructions = """
        You extract structured data from noisy Australian receipt OCR text. AUD only.
        category MUST be one of: meals, groceries, fuel, software, office, home, health, travel, income.
        total is the GST-inclusive grand total. If a GST amount is printed, use it exactly.
        lineItems are ONLY purchased products — exclude ABN/store/contact, payment/card/EFTPOS/
        change, subtotals/totals, counts, and promos. Repair split decimals (e.g. 19 90 -> 19.90).
        """
        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Receipt (rows):\n" + (layoutText.isEmpty ? ocrText : layoutText)
        // VERIFY signature against the iOS 26 SDK; respond(to:generating:) returns .content.
        let result = try await session.respond(to: prompt, generating: FMReceipt.self)
        let r = result.content
        return FoundationModelMapping.toReceipt(
            merchant: r.merchant, date: r.date, total: r.total, gst: r.gst,
            category: r.category, deductible: r.deductible,
            items: r.lineItems.map { ($0.name, $0.price) },
            confidence: r.confidence, capturedAt: capturedAt,
            ocrText: ocrText.isEmpty ? layoutText : ocrText)
    }
}
#endif

/// Capability gate + factory. Returns a Foundation Models extractor only when the framework is
/// present AND the device/OS/Apple-Intelligence state allows it; otherwise nil (non-FM path).
enum OnDeviceAI {
    static func makeExtractor() -> OnDeviceExtracting? {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return FoundationModelExtractor()
            default: return nil   // .deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady
            }
        }
        #endif
        return nil
    }
}
```

- [ ] **Step 4: Run the mapping test**

Run: `xcodebuild test ... -only-testing:SnapceiptTests/OnDeviceGuardsTests`
Expected: PASS (mapping + guard tests). The FM call path is compiled but exercised only on device (Task 8).

- [ ] **Step 5: Commit**
```bash
git add Snapceipt/Features/Capture/Scanner/FoundationModelExtractor.swift Snapceipt/Features/Capture/Scanner/OnDeviceExtracting.swift SnapceiptTests/OnDeviceGuardsTests.swift
git commit -m "feat(capture): Foundation Models extractor + availability gate + pure mapping"
```

---

### Task 3: Router in `CaptureViewModel.extract()`

**Files:**
- Modify: `Snapceipt/Features/Capture/CaptureViewModel.swift`
- Test: `SnapceiptTests/ExtractRouterTests.swift`

**Interfaces:**
- Consumes: `OnDeviceExtracting`, `ExtractedReceipt.empty`, `api.extract`, `AppSettings.smartScanEnabled`, the existing `draftRevision`/`draftUserEdited`/`extractTask`.
- Produces: `CaptureViewModel.init(..., onDeviceExtractor: OnDeviceExtracting?, isOnline: @escaping () -> Bool)` (both with defaults `nil` / `{ true }`).

- [ ] **Step 1: Add the injected deps (keep existing tests compiling)**

In `CaptureViewModel.swift`, add stored props near the other `@ObservationIgnored` deps:
```swift
    @ObservationIgnored private let onDeviceExtractor: OnDeviceExtracting?
    @ObservationIgnored private let isOnline: () -> Bool
```
Extend `init` (append params with defaults so existing call sites/tests are unchanged):
```swift
    init(api: APIClient, reducer: ImageReducing, sync: any SyncEnqueuing,
         profiles: ProfilesStore, context: ModelContext, userId: String,
         onDeviceExtractor: OnDeviceExtracting? = nil, isOnline: @escaping () -> Bool = { true }) {
        self.api = api; self.reducer = reducer; self.sync = sync
        self.profiles = profiles; self.context = context; self.userId = userId
        self.onDeviceExtractor = onDeviceExtractor; self.isOnline = isOnline
    }
```

- [ ] **Step 2: Write the router tests**

Create `SnapceiptTests/ExtractRouterTests.swift`:
```swift
import Testing
import SwiftData
import UIKit
@testable import Snapceipt

@MainActor
struct ExtractRouterTests {
    final class SpySync: SyncEnqueuing {
        func enqueue(op: String, entityType: EntityType, entity: any Syncable) {}
    }
    struct PassReducer: ImageReducing { func reduce(_ i: UIImage) -> Data { Data([0xFF,0xD8,0xFF]) } }
    struct StubExtractor: OnDeviceExtracting {
        let confidence: Double
        func extract(ocrText: String, layoutText: String, capturedAt: String) async throws -> ExtractedReceipt {
            ExtractedReceipt(merchant: "FM", date: "2026-06-20", total: 10, gst: 0.9,
                             categoryKey: "meals", deductible: 50, lineItems: [],
                             confidence: confidence, needsReview: confidence < 0.8, extractionStatus: "done")
        }
    }
    private func img() -> UIImage {
        UIGraphicsImageRenderer(size: .init(width: 4, height: 4)).image { _ in }
    }
    private func lines(_ s: String) -> [RecognizedLine] {
        s.split(separator: "\n").map { RecognizedLine(text: String($0), confidence: 1, boundingBox: .zero) }
    }
    private func vm(extractor: OnDeviceExtracting?, online: Bool,
                    extractHandler: ((String, String, String?) async throws -> ExtractionResponse)?)
        throws -> (CaptureViewModel, MockAPIClient, ModelContext) {
        UserDefaults.standard.removeObject(forKey: AppSettings.smartScanEnabledKey)
        let c = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(c)
        let p = Profile(userId: "u1", name: "Me", type: "personal", accent1: "#0", accent2: "#1", accent3: "#2", isDefault: true)
        ctx.insert(p); try ctx.save()
        let store = ProfilesStore(context: ctx, sync: SpySync(), userId: "u1"); store.setActive(p.id)
        let api = MockAPIClient(); api.extractHandler = extractHandler
        let m = CaptureViewModel(api: api, reducer: PassReducer(), sync: SpySync(),
                                 profiles: store, context: ctx, userId: "u1",
                                 onDeviceExtractor: extractor, isOnline: { online })
        return (m, api, ctx)
    }
    private func ok(_ merchant: String) -> ExtractionResponse {
        let j = "{\"requestId\":\"r\",\"receipt\":{\"merchant\":\"\(merchant)\",\"date\":\"2026-05-28\",\"currencyCode\":\"AUD\",\"total\":10.0,\"gst\":0.91,\"category\":\"meals\",\"deductible\":50,\"lineItems\":[],\"confidence\":0.95,\"needsReview\":false},\"meta\":{\"model\":\"x\",\"source\":\"scan\",\"latencyMs\":1,\"attempts\":1,\"stub\":false}}"
        return try! JSONDecoder().decode(ExtractionResponse.self, from: Data(j.utf8))
    }

    @Test("FM-capable: high-confidence FM result is used, no cloud call")
    func fmHighConfidence() async throws {
        let (m, api, _) = try vm(extractor: StubExtractor(confidence: 0.95), online: true) { _,_,_ in self.ok("CLOUD") }
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(m.stage == .review)
        #expect(m.draft?.merchant == "FM")
        #expect(api.extractCalls.isEmpty)               // cloud not called
    }

    @Test("FM-capable online: low-confidence FM triggers a cloud upgrade in place")
    func fmLowConfidenceUpgrades() async throws {
        let (m, api, _) = try vm(extractor: StubExtractor(confidence: 0.4), online: true) { _,_,_ in self.ok("CLOUD") }
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(api.extractCalls.count == 1)            // cloud upgrade ran
        #expect(m.draft?.merchant == "CLOUD")           // upgraded in place
    }

    @Test("FM-capable offline: low-confidence FM is left pending (no cloud)")
    func fmLowConfidenceOfflinePending() async throws {
        let (m, api, _) = try vm(extractor: StubExtractor(confidence: 0.4), online: false) { _,_,_ in self.ok("CLOUD") }
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(api.extractCalls.isEmpty)
        #expect(m.draft?.extractionStatus == "pending")
        #expect(m.draft?.merchant == "FM")
    }

    @Test("non-FM online: cloud is used")
    func nonFmOnlineCloud() async throws {
        let (m, api, _) = try vm(extractor: nil, online: true) { _,_,_ in self.ok("CLOUD") }
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(api.extractCalls.count == 1)
        #expect(m.draft?.merchant == "CLOUD")
    }

    @Test("non-FM offline: empty pending draft, no cloud")
    func nonFmOfflinePending() async throws {
        let (m, api, _) = try vm(extractor: nil, online: false) { _,_,_ in self.ok("CLOUD") }
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(api.extractCalls.isEmpty)
        #expect(m.draft?.extractionStatus == "pending")
        #expect(m.draft?.merchant == "")                // empty draft
    }

    @Test("Smart Scan OFF, non-FM: manual empty draft, no cloud")
    func offNonFmManual() async throws {
        let (m, api, _) = try vm(extractor: nil, online: true) { _,_,_ in self.ok("CLOUD") }
        UserDefaults.standard.set(false, forKey: AppSettings.smartScanEnabledKey)
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(api.extractCalls.isEmpty)
        #expect(m.draft?.extractionStatus == "done")
        #expect(m.draft?.merchant == "")
        UserDefaults.standard.removeObject(forKey: AppSettings.smartScanEnabledKey)
    }
}
```

- [ ] **Step 3: Run to verify failures**

Run: `xcodegen generate && xcodebuild test ... -only-testing:SnapceiptTests/ExtractRouterTests`
Expected: FAIL (router not implemented; old extract still calls HeuristicParser).

- [ ] **Step 4: Rewrite `extract()` as the router**

Replace the body of `func extract() async` in `CaptureViewModel.swift` with the matrix. Keep the existing `extractTask`/`draftUserEdited`/`draftRevision`/cancellation/stage logic (the owned-task + in-place-refresh structure from the inline-wait work). New core:
```swift
    func extract() async {
        let capturedAt = ExtractedReceipt.ymd(from: Date()) ?? ""
        let started = Date()
        let smartScan = AppSettings.smartScanEnabled

        // Smart Scan OFF: on-device AI if available, else manual entry. Never cloud.
        if !smartScan {
            if let fm = onDeviceExtractor {
                await runFoundationModel(fm, capturedAt: capturedAt, started: started, allowCloudUpgrade: false)
            } else {
                applyManualDraft(capturedAt: capturedAt, started: started)
            }
            return
        }

        // Smart Scan ON.
        if let fm = onDeviceExtractor {
            await runFoundationModel(fm, capturedAt: capturedAt, started: started, allowCloudUpgrade: true)
        } else if isOnline() {
            await runCloud(capturedAt: capturedAt, started: started)   // existing cloud path
        } else {
            // non-FM offline: queue an empty pending draft for the reconciler.
            applyPendingDraft(capturedAt: capturedAt, started: started)
        }
    }
```
Add the helpers (all set `draft`, `diagnostics`, advance `stage` via the existing guard `if stage == .scanning { stage = .review }`, and bump `draftRevision` at the end exactly as today):
```swift
    private func runFoundationModel(_ fm: OnDeviceExtracting, capturedAt: String, started: Date, allowCloudUpgrade: Bool) async {
        do {
            let r = try await fm.extract(ocrText: rawText, layoutText: layoutText, capturedAt: capturedAt)
            if Task.isCancelled || draftUserEdited { return }
            draft = r
            smartScanCapped = false; smartScanCap = nil; smartScanUsed = nil
            diagnostics = ScanDiagnostics(engine: .foundationModel, model: "apple-on-device",
                clientMs: Self.elapsedMs(since: started), serverMs: nil, attempts: nil,
                stub: nil, capped: nil, confidence: r.confidence)
            if stage == .scanning { stage = .review }
            draftRevision += 1
            // Low-confidence: upgrade via cloud (online) or queue pending (offline).
            if r.confidence < 0.8 {
                if allowCloudUpgrade && isOnline() {
                    await runCloud(capturedAt: capturedAt, started: started)   // in-place upgrade
                } else {
                    draft?.extractionStatus = "pending"
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled || draftUserEdited { return }
            // FM failed (overflow / unavailable mid-run): fall back like a non-FM device.
            if AppSettings.smartScanEnabled && isOnline() { await runCloud(capturedAt: capturedAt, started: started) }
            else { applyPendingDraft(capturedAt: capturedAt, started: started) }
        }
    }

    /// The existing cloud /extract path, extracted verbatim (success sets AI draft + .deepseek
    /// diagnostics; real error -> pending draft). Used both as the primary non-FM path and as the
    /// FM low-confidence upgrade.
    private func runCloud(capturedAt: String, started: Date) async {
        do {
            let resp = try await api.extract(ocrText: rawText, layoutText: layoutText, source: "scan", capturedAt: capturedAt)
            if Task.isCancelled || draftUserEdited { return }
            draft = ExtractedReceipt(response: resp)
            smartScanCapped = resp.meta.capped; smartScanCap = resp.meta.smartScan?.cap; smartScanUsed = resp.meta.smartScan?.used
            diagnostics = ScanDiagnostics(engine: .deepseek, model: resp.meta.model,
                clientMs: Self.elapsedMs(since: started), serverMs: resp.meta.latencyMs,
                attempts: resp.meta.attempts, stub: resp.meta.stub, capped: resp.meta.capped,
                confidence: draft?.confidence ?? 0)
            if stage == .scanning { stage = .review }
            draftRevision += 1
        } catch {
            if error is CancellationError || Task.isCancelled || draftUserEdited { return }
            applyPendingDraft(capturedAt: capturedAt, started: started)
        }
    }

    private func applyPendingDraft(capturedAt: String, started: Date) {
        draft = .empty(capturedAt: capturedAt, extractionStatus: "pending")
        smartScanCapped = false; smartScanCap = nil; smartScanUsed = nil
        diagnostics = ScanDiagnostics(engine: .onDeviceQueued, model: nil,
            clientMs: Self.elapsedMs(since: started), serverMs: nil, attempts: nil,
            stub: nil, capped: nil, confidence: 0)
        if stage == .scanning { stage = .review }
        draftRevision += 1
    }

    private func applyManualDraft(capturedAt: String, started: Date) {
        draft = .empty(capturedAt: capturedAt, extractionStatus: "done")
        smartScanCapped = false; smartScanCap = nil; smartScanUsed = nil
        diagnostics = ScanDiagnostics(engine: .onDeviceQueued, model: nil,
            clientMs: Self.elapsedMs(since: started), serverMs: nil, attempts: nil,
            stub: nil, capped: nil, confidence: 0)
        if stage == .scanning { stage = .review }
        draftRevision += 1
    }
```
Also update `reviewNow()` and `autosaveOnExitIfScanning()`: replace `HeuristicParser.parse(recognizedLines)` with `ExtractedReceipt.empty(capturedAt: ExtractedReceipt.ymd(from: Date()) ?? "", extractionStatus: "pending")` (the AI populates via the in-place refresh).

- [ ] **Step 5: Run router tests**

Run: `xcodebuild test ... -only-testing:SnapceiptTests/ExtractRouterTests`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**
```bash
git add Snapceipt/Features/Capture/CaptureViewModel.swift SnapceiptTests/ExtractRouterTests.swift
git commit -m "feat(capture): route extraction by device capability + network (FM/cloud/queue)"
```

---

### Task 4: Reconciler full-replace for FM-low-confidence pending

**Files:**
- Modify: `Snapceipt/Features/Capture/PendingExtractionReconciler.swift`
- Modify: `Snapceipt/Features/Capture/PendingReceipt.swift` (reuse the existing `autoSaved` flag semantics)
- Test: `SnapceiptTests/PendingExtractionReconcilerTests.swift`

**Interfaces:**
- Consumes: `PendingReceipt.autoSaved`; the reconciler's existing full-replace branch.
- Produces: a pending FM/queued receipt is FULLY replaced by the cloud result (not classification-only), without stomping a user edit.

- [ ] **Step 1: Decide the flag.** A queued/low-confidence pending receipt was NOT user-reviewed with trusted values, so it should be fully replaced — identical to the existing `autoSaved` branch. In `CaptureViewModel.save()`, when persisting a draft whose `extractionStatus == "pending"` AND `!draftUserEdited`, pass `autoSaved: true` (the existing param) so the reconciler full-replaces. This reuses existing machinery — no new flag.

- [ ] **Step 2: Write the test**

Add to `SnapceiptTests/PendingExtractionReconcilerTests.swift`:
```swift
    @Test("a queued pending receipt (autoSaved) is fully replaced by the cloud result")
    func queuedFullyReplaced() async throws {
        let (ctx, api, sync) = try fixture()
        let txn = Transaction(userId: "u1", profileId: "p1", merchant: "", catKey: "office",
                              amountCents: 0, txnDate: "2026-06-24", source: "scan", extractionStatus: "pending")
        let pr = PendingReceipt(transactionId: txn.id, ocrText: "M\nTOTAL 20.00",
                                imageLocalPath: "/tmp/x.jpg", width: 1, height: 1, autoSaved: true)
        ctx.insert(txn); ctx.insert(pr); try ctx.save()
        api.extractHandler = { _,_,_ in self.okResponse(category: "meals", gst: "1.82", deductible: 50) }
        await PendingExtractionReconciler(api: api, context: ctx, sync: sync).reconcile()
        let u = try ctx.fetch(FetchDescriptor<Transaction>()).first { $0.id == txn.id }!
        #expect(u.extractionStatus == "done")
        #expect(u.merchant == "M")          // full replace
        #expect(u.amountCents == -2000)
    }
```

- [ ] **Step 3: Run to verify it passes (or fails)**

Run: `xcodegen generate && xcodebuild test ... -only-testing:SnapceiptTests/PendingExtractionReconcilerTests`
Expected: PASS if the existing `autoSaved` full-replace branch already covers it. If `save()` doesn't yet set `autoSaved` for queued drafts, implement Step 4.

- [ ] **Step 4: Set `autoSaved` for queued saves**

In `CaptureViewModel.save()`, default `autoSaved` to `true` when `draft.extractionStatus == "pending" && !draftUserEdited`; keep `false` otherwise. (The reconciler logic itself is unchanged — it already full-replaces `autoSaved` receipts.)

- [ ] **Step 5: Run tests**

Run: `xcodebuild test ... -only-testing:SnapceiptTests/PendingExtractionReconcilerTests`
Expected: PASS.

- [ ] **Step 6: Commit**
```bash
git add Snapceipt/Features/Capture/CaptureViewModel.swift SnapceiptTests/PendingExtractionReconcilerTests.swift
git commit -m "feat(capture): cloud-upgrade queued pending receipts via full replace"
```

---

### Task 5: `ScanDiagnostics.foundationModel` engine

**Files:**
- Modify: `Snapceipt/Features/Capture/CaptureViewModel.swift` (`ScanDiagnostics`)
- Test: `SnapceiptTests/CaptureViewModelTests.swift`

- [ ] **Step 1: Write the test**

Add to `SnapceiptTests/CaptureViewModelTests.swift`:
```swift
    @Test("ScanDiagnostics.summary renders the on-device AI (Foundation Models) line")
    func diagnosticsSummaryFoundationModel() {
        let d = ScanDiagnostics(engine: .foundationModel, model: "apple-on-device",
                                clientMs: 1200, serverMs: nil, attempts: nil,
                                stub: nil, capped: nil, confidence: 0.88)
        #expect(d.summary == "On-device AI · 1200ms · conf 0.88")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test ... -only-testing:SnapceiptTests/CaptureViewModelTests/diagnosticsSummaryFoundationModel`
Expected: FAIL (`.foundationModel` not in the enum).

- [ ] **Step 3: Add the case**

In `ScanDiagnostics.Engine`, add `foundationModel`; in `summary`, add `case .foundationModel: parts.append("On-device AI")`.

- [ ] **Step 4: Run tests**

Run: `xcodebuild test ... -only-testing:SnapceiptTests/CaptureViewModelTests/diagnosticsSummaryFoundationModel`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add Snapceipt/Features/Capture/CaptureViewModel.swift SnapceiptTests/CaptureViewModelTests.swift
git commit -m "feat(capture): add Foundation Models diagnostics engine"
```

---

### Task 6: Remove `HeuristicParser` + dead paths

**Files:**
- Delete: `Snapceipt/Features/Capture/Scanner/HeuristicParser.swift`, `SnapceiptTests/HeuristicParserTests.swift`
- Modify: `Snapceipt/Features/Capture/ExtractedReceipt.swift` (remove `init(parsed:)`), `CaptureViewModel.swift` (`ScanDiagnostics` — remove `.onDeviceHeuristic`/`.offlineHeuristic` if unused), and any remaining callers found by grep.
- Modify: `SnapceiptTests/CaptureViewModelTests.swift` (update/remove heuristic-dependent tests).

- [ ] **Step 1: Find all callers**

Run: `grep -rn "HeuristicParser\|ParsedReceipt\|onDeviceHeuristic\|offlineHeuristic\|ExtractedReceipt(parsed" Snapceipt SnapceiptTests --include="*.swift"`
Expected: a list to resolve (CaptureViewModel already migrated in Task 3; AppLaunch/SavedStep/StubAPIClient/DTOs may reference `ParsedReceipt` — convert those to the cloud/empty path or delete).

- [ ] **Step 2: Update the now-wrong tests**

In `SnapceiptTests/CaptureViewModelTests.swift`, the tests asserting the old offline/Smart-Scan-OFF heuristic behavior must move to the new contract:
- `failurePathFallsBack` / `smartScanOnFailureDiagnostics`: a non-FM device with a failing cloud → `extractionStatus == "pending"`, `merchant == ""` (no heuristic). (Or delete — `ExtractRouterTests` already covers these.)
- `smartScanOffUsesHeuristic`: Smart Scan OFF on a non-FM device → empty `done` draft, no cloud. (Covered by `ExtractRouterTests.offNonFmManual`; delete the old one.)
- `reviewNowQuitsWaiting` / `autosaveOnExitPersistsPending`: now seed `.empty(...pending)` not the heuristic — assert `extractionStatus == "pending"` and `merchant == ""` (drop the `total == 22.00` assertion).

- [ ] **Step 3: Delete the files + dead code**
```bash
git rm Snapceipt/Features/Capture/Scanner/HeuristicParser.swift SnapceiptTests/HeuristicParserTests.swift
```
Remove `ExtractedReceipt.init(parsed:)` and the unused `ScanDiagnostics.Engine` cases (`onDeviceHeuristic`, `offlineHeuristic`) and their `summary` arms. Resolve remaining grep hits.

- [ ] **Step 4: Build + full unit suite**

Run: `xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests`
Expected: BUILD + ALL tests PASS (no references to removed symbols).

- [ ] **Step 5: Commit**
```bash
git add -A
git commit -m "refactor(capture): remove the on-device HeuristicParser + dead extraction paths"
```

---

### Task 7: Wire the factory + UI states

**Files:**
- Modify: `Snapceipt/Features/Capture/CaptureHost.swift` (`CaptureFactory.makeViewModel`)
- Modify: `Snapceipt/Features/Capture/Views/ReviewStep.swift` (empty/queued messaging)
- Modify: the Smart Scan settings toggle copy (find via `grep -rn "Smart Scan" Snapceipt --include="*.swift"`)

**Interfaces:**
- Consumes: `OnDeviceAI.makeExtractor()`, `Reachability.isOnline`.

- [ ] **Step 1: Inject the real extractor + reachability**

`CaptureHost` already has `reachability: Reachability`. Update `CaptureFactory.makeViewModel` to accept `reachability` and pass:
```swift
    static func makeViewModel(api: APIClient, sync: any SyncEnqueuing, profiles: ProfilesStore,
                              context: ModelContext, userId: String, reachability: Reachability) -> CaptureViewModel {
        CaptureViewModel(api: api, reducer: ImageReducer(), sync: sync, profiles: profiles,
                         context: context, userId: userId,
                         onDeviceExtractor: OnDeviceAI.makeExtractor(),
                         isOnline: { [weak reachability] in reachability?.isOnline ?? true })
    }
```
Update the call site in `CaptureHost.body`'s `.task` to pass `reachability: reachability`.

- [ ] **Step 2: Queued/manual messaging in ReviewStep**

When `draft.extractionStatus == "pending"` and the draft is empty (merchant empty + no items), show a small line under the banner: "We'll finish this automatically when you're back online." (Reuse the existing `isQueued`/banner area; no new state machine.) Verify ReviewStep renders cleanly with an empty draft (no crash, fields editable).

- [ ] **Step 3: Smart Scan copy**

Update the toggle's subtitle to: "Use on-device AI when available, otherwise enter details manually." (No behavior change here — Task 3 already implements it.)

- [ ] **Step 4: Build + run the capture suites**

Run: `xcodegen generate && xcodebuild test ... -only-testing:SnapceiptTests/CaptureViewModelTests -only-testing:SnapceiptTests/ExtractRouterTests`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add -A
git commit -m "feat(capture): wire Foundation Models extractor + queued/manual review states"
```

---

### Task 8: Device verification (Foundation Models, real)

**Files:** none (manual verification + report).

- [ ] **Step 1: Build the Debug app for the iPhone 15 Pro Max (A17 Pro, iOS 26).**
```bash
xcodegen generate
xcodebuild -project Snapceipt.xcodeproj -scheme Snapceipt -configuration Debug \
  -destination 'id=<DEVICE_UDID>' -allowProvisioningUpdates -derivedDataPath build/DerivedData build
xcrun devicectl device install app --device <DEVICE_UDID> "build/DerivedData/Build/Products/Debug-iphoneos/Snapceipt.app"
```

- [ ] **Step 2: Confirm FM availability** — on the device (iOS 26, Apple Intelligence ON), scan the Japan City + Yakitori receipts. Verify the diagnostics line reads "On-device AI" and the result is clean (no ABN/store/"count of items" junk).

- [ ] **Step 3: Verify the low-confidence upgrade** — on a deliberately messy/angled scan, confirm a low-confidence FM result is upgraded by the cloud in place (diagnostics flips "On-device AI" → "Snapceipt AI").

- [ ] **Step 4: Verify airplane-mode behavior** — offline on the FM device: FM still works. (Optionally test a non-FM device or simulator: offline → queued pending → fills on reconnect.)

- [ ] **Step 5: Report** results; no commit unless fixes are needed (loop back to the relevant task).

---

## Self-Review

**Spec coverage:** behavior matrix → Task 3 (router) + Task 4 (queued upgrade); FM engine → Task 2; guards → Task 1; remove heuristic → Task 6; Smart Scan OFF → Task 3 + Task 7; diagnostics → Task 5; wiring/UI → Task 7; device test → Task 8. All spec sections mapped.

**Placeholder scan:** the only non-literal area is the FoundationModels SDK call signatures (Task 2), explicitly flagged to verify against the iOS 26 SDK — unavoidable for a new external API; all deterministic logic is complete code.

**Type consistency:** `OnDeviceExtracting.extract(ocrText:layoutText:capturedAt:)`, `FoundationModelMapping.toReceipt(...)`, `OnDeviceGuards.reconcile(_:ocrText:)`, `ExtractedReceipt.empty(capturedAt:extractionStatus:)`, `ScanDiagnostics.Engine.foundationModel`, and the `CaptureViewModel.init(..., onDeviceExtractor:isOnline:)` signature are used consistently across tasks.
