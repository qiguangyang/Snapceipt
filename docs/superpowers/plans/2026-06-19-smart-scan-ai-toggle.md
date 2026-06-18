# Smart Scan AI Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persisted "Smart Scan AI" toggle (default ON) that switches receipt recognition between DeepSeek (server `/extract`) and the on-device heuristic, with a Review-screen diagnostic line so a tester can compare the two engines back-to-back.

**Architecture:** App-only change. `CaptureViewModel.extract()` branches on `AppSettings.smartScanEnabled`: ON = today's `/extract` flow (DeepSeek); OFF = run the existing `HeuristicParser` directly and mark the draft `extractionStatus: "done"` so the pending-extraction reconciler never re-runs DeepSeek over it. A `ScanDiagnostics` value records which engine ran and is rendered on the Review screen.

**Tech Stack:** Swift / SwiftUI, SwiftData, Swift Testing (`import Testing`, `@Test`, `#expect`), Xcode 16 (`xcodebuild`).

## Global Constraints

- **No backend / Worker change.** App-only; no `/extract` schema change, no Cloudflare deploy.
- **No new files.** The Xcode project (`Snapceipt.xcodeproj`, objectVersion 77) uses **explicit** file references (no `PBXFileSystemSynchronizedRootGroup`). Adding a `.swift` file requires manual `project.pbxproj` surgery, so all new types are co-located in existing, already-targeted files. Do **not** create new `.swift` files.
- **Default ON.** The toggle defaults to ON (current behavior). `UserDefaults.bool` returns `false` for a missing key, so the accessor MUST read the object and default to `true`.
- **UserDefaults key:** exactly `sc.smartScan.enabled` (matches the app's `sc.*` convention).
- **Toggle label:** exactly `Smart Scan AI`.
- **Diagnostic line is visible to all users** (intentional product decision), shown on every Review screen.
- **Test runner:** `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17'`. Use `-only-testing:SnapceiptTests/CaptureViewModelTests` to scope to the unit tests.
- Follow existing code style: `@Observable @MainActor` VM, `#expect` assertions, `IconCircle`/`Palette`/`accent` design primitives, `AccessibilityID` constants.

---

### Task 1: Settings accessor + diagnostics value type

Adds `AppSettings.smartScanEnabled` (persisted, default ON) and the `ScanDiagnostics` value (engine + metrics + a one-line `summary`). Both co-located at the bottom of `CaptureViewModel.swift` to avoid new files. No behavior wired yet — this task delivers the two types plus their unit tests.

**Files:**
- Modify: `Snapceipt/Features/Capture/CaptureViewModel.swift` (append both types at end of file)
- Test: `SnapceiptTests/CaptureViewModelTests.swift`

**Interfaces:**
- Produces:
  - `enum AppSettings { static let smartScanEnabledKey = "sc.smartScan.enabled"; static var smartScanEnabled: Bool { get set } }`
  - `struct ScanDiagnostics: Equatable { enum Engine: String { case deepseek, onDeviceHeuristic, offlineHeuristic }; var engine: Engine; var model: String?; var clientMs: Int; var serverMs: Int?; var attempts: Int?; var stub: Bool?; var capped: Bool?; var confidence: Double; var summary: String }`

- [ ] **Step 1: Write the failing tests**

Add these three tests inside `struct CaptureViewModelTests` in `SnapceiptTests/CaptureViewModelTests.swift` (e.g. just before the closing `}` at line 164):

```swift
    @Test("AppSettings.smartScanEnabled defaults to true when the key is unset")
    func smartScanDefaultsOn() {
        UserDefaults.standard.removeObject(forKey: AppSettings.smartScanEnabledKey)
        #expect(AppSettings.smartScanEnabled == true)
    }

    @Test("ScanDiagnostics.summary renders the DeepSeek engine line")
    func diagnosticsSummaryDeepseek() {
        let d = ScanDiagnostics(engine: .deepseek, model: "deepseek-v4-flash",
                                clientMs: 850, serverMs: 700, attempts: 1,
                                stub: false, capped: false, confidence: 0.91)
        #expect(d.summary == "deepseek-v4-flash · 1 try · 700ms srv · 850ms · conf 0.91")
    }

    @Test("ScanDiagnostics.summary renders the on-device heuristic line")
    func diagnosticsSummaryHeuristic() {
        let d = ScanDiagnostics(engine: .onDeviceHeuristic, model: nil,
                                clientMs: 12, serverMs: nil, attempts: nil,
                                stub: nil, capped: nil, confidence: 0.55)
        #expect(d.summary == "on-device heuristic · 12ms · conf 0.55")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/CaptureViewModelTests 2>&1 | tail -40
```
Expected: BUILD FAILURE — `cannot find 'AppSettings' in scope` / `cannot find 'ScanDiagnostics' in scope`.

- [ ] **Step 3: Implement the two types**

Append to the very end of `Snapceipt/Features/Capture/CaptureViewModel.swift` (after the final `}` of the class):

```swift

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
        case .deepseek:          parts.append(model ?? "server")
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/CaptureViewModelTests 2>&1 | tail -40
```
Expected: the three new tests PASS (existing tests also still pass).

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Capture/CaptureViewModel.swift SnapceiptTests/CaptureViewModelTests.swift
git commit -m "feat(capture): add AppSettings.smartScanEnabled + ScanDiagnostics"
```

---

### Task 2: Branch extract() on the toggle + record diagnostics

Wires the toggle into the capture flow. ON = unchanged DeepSeek path; OFF = on-device heuristic with `extractionStatus: "done"` and no network. Every branch sets `vm.diagnostics`. Adds the `extractionStatus` parameter to the heuristic draft builder so the OFF path can produce a final ("done") result.

**Files:**
- Modify: `Snapceipt/Features/Capture/ExtractedReceipt.swift:146-160` (add `extractionStatus` param to the `parsed:` init)
- Modify: `Snapceipt/Features/Capture/CaptureViewModel.swift` (new `diagnostics` property, rewritten `extract()`, `elapsedMs` helper, reset)
- Modify: `SnapceiptTests/CaptureViewModelTests.swift` (fixture reset + 3 tests)

**Interfaces:**
- Consumes: `AppSettings.smartScanEnabled`, `ScanDiagnostics` (Task 1); `HeuristicParser.parse(_:) -> ParsedReceipt`; `ExtractionResponse.meta` (`model: String`, `latencyMs: Int`, `attempts: Int`, `stub: Bool`, `capped: Bool`, `smartScan: SmartScanMeta?`).
- Produces:
  - `ExtractedReceipt.init(parsed: ParsedReceipt, capturedAt: String, extractionStatus: String = "pending")`
  - `CaptureViewModel.diagnostics: ScanDiagnostics?` (observable, read by ReviewStep in Task 4)

- [ ] **Step 1: Add the `extractionStatus` parameter to the heuristic draft builder**

In `Snapceipt/Features/Capture/ExtractedReceipt.swift`, replace the `init(parsed:capturedAt:)` (lines 146-160) with:

```swift
    /// Build the draft from the on-device heuristic. `extractionStatus` defaults to
    /// "pending" (offline fallback → reconciler re-extracts later); pass "done" for a
    /// deliberate Smart-Scan-OFF result so the reconciler never overwrites it.
    /// `needsReview = true`, low confidence; category/deductible default to the
    /// server fallback defaults ("office"/100). `date` falls back to `capturedAt`.
    init(parsed: ParsedReceipt, capturedAt: String, extractionStatus: String = "pending") {
        let iso = ExtractedReceipt.ymd(from: parsed.date) ?? capturedAt
        self.init(
            merchant: parsed.merchant,
            date: iso,
            total: parsed.total,
            gst: parsed.tax,
            categoryKey: parsed.category.rawValue,
            deductible: 100,
            lineItems: parsed.lineItems.map { LineItemDraft(name: $0.name, price: $0.price) },
            confidence: parsed.confidence,
            needsReview: true,
            extractionStatus: extractionStatus
        )
    }
```

- [ ] **Step 2: Write the failing tests**

First, make every test default to ON by clearing the key in the `fixture` helper. In `SnapceiptTests/CaptureViewModelTests.swift`, find line 32:

```swift
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
```
and add immediately after it:
```swift
        UserDefaults.standard.removeObject(forKey: AppSettings.smartScanEnabledKey)
```

Then add these three tests inside `struct CaptureViewModelTests` (before the closing `}`):

```swift
    @Test("Smart Scan OFF -> on-device heuristic, status done, no /extract call, diagnostics onDeviceHeuristic")
    func smartScanOffUsesHeuristic() async throws {
        UserDefaults.standard.set(false, forKey: AppSettings.smartScanEnabledKey)
        defer { UserDefaults.standard.removeObject(forKey: AppSettings.smartScanEnabledKey) }
        // The handler must NOT be invoked when Smart Scan is OFF.
        let (vm, api, _, _) = try fixture { _, _, _ in
            Issue.record("extract() must not be called when Smart Scan is OFF")
            throw MockAPIClientError.unscripted
        }
        await vm.onScanned(image: image(), lines: zeroLines("WOOLWORTHS\nTOTAL 22.00"))
        #expect(vm.stage == .review)
        #expect(api.extractCalls.isEmpty)
        #expect(vm.draft?.extractionStatus == "done")
        #expect(vm.draft?.needsReview == true)
        #expect(vm.diagnostics?.engine == .onDeviceHeuristic)
    }

    @Test("Smart Scan ON success -> diagnostics deepseek with model/attempts from meta, status done")
    func smartScanOnSuccessDiagnostics() async throws {
        let (vm, api, _, _) = try fixture { _, _, _ in self.okResponse() }
        await vm.onScanned(image: image(), lines: zeroLines("CAFE\nTOTAL 10.00"))
        #expect(api.extractCalls.count == 1)
        #expect(vm.draft?.extractionStatus == "done")
        #expect(vm.diagnostics?.engine == .deepseek)
        #expect(vm.diagnostics?.model == "x")     // okResponse() meta.model == "x"
        #expect(vm.diagnostics?.attempts == 1)
    }

    @Test("Smart Scan ON failure -> offline heuristic, status pending, diagnostics offlineHeuristic")
    func smartScanOnFailureDiagnostics() async throws {
        struct Boom: Error {}
        let (vm, _, _, _) = try fixture { _, _, _ in throw Boom() }
        await vm.onScanned(image: image(), lines: zeroLines("WOOLWORTHS\nTOTAL 22.00"))
        #expect(vm.draft?.extractionStatus == "pending")
        #expect(vm.diagnostics?.engine == .offlineHeuristic)
    }
```

- [ ] **Step 3: Run the tests to verify they fail**

Run:
```bash
xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/CaptureViewModelTests 2>&1 | tail -40
```
Expected: BUILD FAILURE — `value of type 'CaptureViewModel' has no member 'diagnostics'`.

- [ ] **Step 4: Add the `diagnostics` property**

In `Snapceipt/Features/Capture/CaptureViewModel.swift`, after line 16 (`var draft: ExtractedReceipt?`) add:

```swift
    /// Which engine produced the current draft (Smart Scan ON = DeepSeek, OFF =
    /// on-device heuristic, ON-but-offline = offline heuristic). Read by ReviewStep.
    var diagnostics: ScanDiagnostics?
```

- [ ] **Step 5: Rewrite `extract()` to branch + record diagnostics**

Replace the whole `extract()` method (`Snapceipt/Features/Capture/CaptureViewModel.swift:84-104`) with:

```swift
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
```

- [ ] **Step 6: Clear diagnostics on reset**

In `Snapceipt/Features/Capture/CaptureViewModel.swift`, in `reset()` (currently line 156), add `diagnostics = nil` to the reset line:

```swift
        draft = nil; capturedImage = nil; rawText = ""; recognizedLines = []; errorMessage = nil
        diagnostics = nil
```

- [ ] **Step 7: Run the tests to verify they pass**

Run:
```bash
xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/CaptureViewModelTests 2>&1 | tail -40
```
Expected: ALL `CaptureViewModelTests` PASS — the 3 new behavior tests plus the existing `successPath` (done), `failurePathFallsBack` (pending), capped/non-capped/offline-reset, and savedMode tests (default ON preserves their behavior).

- [ ] **Step 8: Commit**

```bash
git add Snapceipt/Features/Capture/ExtractedReceipt.swift Snapceipt/Features/Capture/CaptureViewModel.swift SnapceiptTests/CaptureViewModelTests.swift
git commit -m "feat(capture): branch extract() on Smart Scan toggle, record diagnostics"
```

---

### Task 3: Profile toggle row + accessibility id

Adds the user-facing "Smart Scan AI" toggle to Profile → Capture & tax, persisted with `@AppStorage` on the same key the VM reads.

**Files:**
- Modify: `Snapceipt/Shared/AccessibilityID.swift` (add `profileSmartScanToggle`)
- Modify: `Snapceipt/Features/Profiles/ProfileTabView.swift` (`@AppStorage` property, `smartScanRow`, insert into `captureAndTaxGroup`)

**Interfaces:**
- Consumes: `AppSettings.smartScanEnabledKey` (Task 1).

- [ ] **Step 1: Add the accessibility id**

In `Snapceipt/Shared/AccessibilityID.swift`, after line 40 (`captureReviewProfileToggle`) add:

```swift
    static let captureReviewDiagnostics = "capture.review.diagnostics"
```
and after line 202 (`profileAiAutoCategorise`) add:
```swift
    static let profileSmartScanToggle = "profile.row.smartScan"
```
(Both ids are added here so Task 4 doesn't touch this file again.)

- [ ] **Step 2: Add the persisted property + the row**

In `Snapceipt/Features/Profiles/ProfileTabView.swift`, after line 26 (`@State private var aiAutoCategorise = true`) add:

```swift
    /// Persisted Smart Scan AI toggle (default ON). Controls whether a scan calls
    /// DeepSeek (`/extract`) or uses the on-device heuristic — see CaptureViewModel.extract().
    @AppStorage(AppSettings.smartScanEnabledKey) private var smartScanEnabled = true
```

Then add this computed row (place it next to `aiAutoCategoriseRow`, e.g. after line 254's `aiAutoCategoriseRow` definition):

```swift
    /// Real, persisted Smart Scan toggle (distinct from the inert aiAutoCategoriseRow).
    private var smartScanRow: some View {
        HStack(spacing: 12) {
            IconCircle(name: "sparkles", tint: accent.base, soft: accent.soft, size: 36, iconSize: 19)
            VStack(alignment: .leading, spacing: 1) {
                Text("Smart Scan AI").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                Text("Use AI to read receipts").font(.ui(12)).foregroundStyle(Palette.ink3)
            }
            Spacer()
            Toggle("", isOn: $smartScanEnabled).labelsHidden().tint(Palette.income)
        }
        .padding(.vertical, 13)
        .accessibilityIdentifier(AccessibilityID.profileSmartScanToggle)
    }
```

- [ ] **Step 3: Insert the row into the Capture & tax card**

In `captureAndTaxGroup` (`Snapceipt/Features/Profiles/ProfileTabView.swift:84-97`), insert the new row after `aiAutoCategoriseRow`:

```swift
                VStack(spacing: 0) {
                    aiAutoCategoriseRow
                    rowDivider
                    smartScanRow
                    rowDivider
                    settingRow(icon: "tag", title: "Categories & rules", detail: nil,
                               tint: categoriesTint, soft: categoriesSoft,
                               id: AccessibilityID.profileRowCategories, action: onOpenCategories)
```
(Only the `smartScanRow` + its `rowDivider` are new; the rest is unchanged context.)

- [ ] **Step 4: Build to verify it compiles**

Run:
```bash
xcodebuild build -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Shared/AccessibilityID.swift Snapceipt/Features/Profiles/ProfileTabView.swift
git commit -m "feat(profile): add persisted Smart Scan AI toggle row"
```

---

### Task 4: Review-screen diagnostic line

Renders `vm.diagnostics.summary` on the Review screen so the tester can see which engine ran and how confidence/fields differ.

**Files:**
- Modify: `Snapceipt/Features/Capture/Views/ReviewStep.swift` (`diagnosticLine` view + insert into body)

**Interfaces:**
- Consumes: `CaptureViewModel.diagnostics` (Task 2), `ScanDiagnostics.summary` (Task 1), `AccessibilityID.captureReviewDiagnostics` (Task 3).

- [ ] **Step 1: Add the diagnostic line view**

In `Snapceipt/Features/Capture/Views/ReviewStep.swift`, add this computed view next to `aiBanner` (e.g. after the `aiBanner` definition ends at line 136):

```swift
    /// Developer diagnostic line: which engine produced this draft + timing/confidence.
    /// Visible to all users by product decision; reads `vm.diagnostics`.
    @ViewBuilder
    private var diagnosticLine: some View {
        if let d = vm.diagnostics {
            Text(d.summary)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityIdentifier(AccessibilityID.captureReviewDiagnostics)
        }
    }
```

- [ ] **Step 2: Render it in the body**

In the `body` (`Snapceipt/Features/Capture/Views/ReviewStep.swift:35-49`), insert `diagnosticLine` immediately after the `if/else` banner block and before `fieldsCard`:

```swift
                    if vm.smartScanCapped && !entitlement.isPro {
                        upgradeNudge
                    } else {
                        aiBanner
                    }
                    diagnosticLine
                    fieldsCard
```

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
xcodebuild build -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Snapceipt/Features/Capture/Views/ReviewStep.swift
git commit -m "feat(capture): show scan engine diagnostic line on Review screen"
```

---

### Task 5: Full regression run + manual verification note

Confirms the whole unit suite is green and documents the in-app manual check (the user tests on device/TestFlight).

**Files:** none (verification only).

- [ ] **Step 1: Run the full unit-test suite**

Run:
```bash
xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **` (no failures across `SnapceiptTests`).

- [ ] **Step 2: Manual verification checklist (in-app / TestFlight)**

Record results in the PR description:
- Profile → Capture & tax shows the **Smart Scan AI** toggle, default ON.
- ON: scan a receipt → diagnostic line shows `deepseek-v4-flash · … · conf …`; fields well-populated.
- OFF: scan the SAME receipt → diagnostic line shows `on-device heuristic · … · conf …`; `extractionStatus` stays "done" (the result is NOT silently re-extracted to DeepSeek after a sync/relaunch).
- Airplane mode + ON: scan → diagnostic shows `on-device (offline) … queued` (unchanged offline behavior).

- [ ] **Step 3: (Optional) Push branch + open PR**

```bash
git push -u origin feature/smart-scan-ai-toggle
```

---

## Self-Review

**1. Spec coverage:**
- Toggle (everyone, Profile → Capture & tax, default ON, label "Smart Scan AI") → Task 3. ✓
- OFF = on-device heuristic, app-only, no backend → Tasks 1–2. ✓
- Critical: OFF result `extractionStatus: "done"` so reconciler doesn't overwrite → Task 2 Steps 1, 5. ✓
- Diagnostic line on Review (engine/model/latency/attempts/confidence) → Tasks 1 (`summary`) + 4. ✓
- Persisted via `UserDefaults` `sc.smartScan.enabled`, default true → Task 1. ✓
- Tests: OFF (no extract call, done, engine), ON success (done, engine), ON failure (pending, engine), default-true → Tasks 1–2. ✓
- isAi edge case → intentionally descoped (Global Constraints / spec note): `ReceiptMapper.map` hard-codes `isAi: true` for all saves incl. the existing offline path; changing it is out of scope and only affects cosmetic history badges, not the Review comparison. ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows full code; every run step shows the command + expected output. ✓

**3. Type consistency:** `AppSettings.smartScanEnabledKey` / `AppSettings.smartScanEnabled`, `ScanDiagnostics(engine:model:clientMs:serverMs:attempts:stub:capped:confidence:)` and `.summary`, `ScanDiagnostics.Engine.{deepseek,onDeviceHeuristic,offlineHeuristic}`, `CaptureViewModel.diagnostics`, `ExtractedReceipt.init(parsed:capturedAt:extractionStatus:)`, `AccessibilityID.{profileSmartScanToggle,captureReviewDiagnostics}` — all defined before use and referenced identically across tasks. `okResponse()` `meta.model == "x"` matches the ON-success test assertion. ✓
