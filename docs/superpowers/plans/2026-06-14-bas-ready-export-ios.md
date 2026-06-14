# BAS-Ready Export (iOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on-device, AU-accurate Simpler-BAS surface (G1/1A/1B + due date + reconciliation + Mark-as-lodged) for GST-registered Business profiles, with per-transaction GST treatment/provenance, an offline ABN checksum, and a one-tap server BAS pack — all gated on `profile.type == "business" && gstRegistered`.

**Architecture:** A pure `BasEngine` (golden-vector-locked, identical math to the backend `basEngine.ts`) computes the worksheet over in-window `[Transaction]`; new SwiftData columns (`gstFree`/`capital`/`gstSource` on Transaction, `gstFreeDefault` on Category) flow through the existing `SyncEntityRegistry` mappers; the capture review editor + a BAS reconciliation quick-fix mutate those columns through a single `GstTreatment` authority helper; `BasView` (a `Router` full-screen overlay, like `.quotes`) and a gated Reports card render it; the pack rides the existing `POST /export` rails via a new `bas` format + `BasExportResponse` DTO across all 4 `APIClient` conformers.

**Tech Stack:** Swift 5.10, SwiftUI, SwiftData (lightweight migration of additive defaulted properties), Swift Testing (`@Test`/`#expect`), XCUITest, `xcodebuild` on the "iPhone 16" simulator.

---

## File Structure

| File | Create/Modify | Responsibility |
|---|---|---|
| `Snapceipt/Model/Entities/Transaction.swift` | Modify (`:24` `gstCents`, init `:38-90`) | Add `gstFree: Bool`, `capital: Bool`, `gstSource: String?` stored props + init params |
| `Snapceipt/Model/Entities/Category.swift` | Modify (`:17-19`, init `:29-63`) | Add `gstFreeDefault: Bool` stored prop + init param |
| `Snapceipt/Sync/SyncEntityRegistry.swift` | Modify (`TransactionSyncMapper:178-231`, `CategorySyncMapper:324-359`) | Read/write the 4 new columns via `env.bool`/`boolv` |
| `Snapceipt/Features/Settings/CategorySeeder.swift` | Modify (`:19-36`, `:53-67`) | Seed `gstFreeDefault` (groceries=true only) + new one-time `backfillGstDefaults()` |
| `Snapceipt/Features/Reports/Bas/GstTreatment.swift` | Create | Authority rule: apply gstFree/typed-GST/flip-back → derive `gstCents`+`gstSource`; confirm income |
| `Snapceipt/Features/Reports/Bas/BasEngine.swift` | Create | Pure §4.3 worksheet function `[Transaction] → BasResult` (cents) |
| `Snapceipt/Features/Reports/Bas/BasReconciliation.swift` | Create | Estimated/income-unconfirmed/printed-discrepancy helpers |
| `Snapceipt/Features/Reports/Bas/BasPeriodKey.swift` | Create | `periodKey(profileId:window:basPeriod:startMonth:)` → `<fyStartYear>Q<n>` / `<calYear>M<mm>` |
| `Snapceipt/Features/Reports/Bas/BasLocalStore.swift` | Create | UserDefaults-backed PAYG + lodged snapshot (per profile/period) |
| `Snapceipt/Features/Settings/ABNValidator.swift` | Create | ATO modulus-89 checksum (pure, offline) |
| `Snapceipt/Features/Reports/Bas/BasViewModel.swift` | Create | `@Observable @MainActor` VM: fetch txns, run engine, reconciliation, PAYG, lodge, export, quick-fix mutations |
| `Snapceipt/Features/Reports/Bas/BasView.swift` | Create | Full-screen overlay: headline, Simpler-BAS spine, full-worksheet toggle, reconcile strip (tappable quick-fix), Mark-as-lodged, Export |
| `Snapceipt/Features/Capture/ExtractedReceipt.swift` | Modify (`:41-93`) | Add editable `gstFree: Bool` + `capital: Bool` draft fields (defaulted) |
| `Snapceipt/Features/Capture/Views/ReviewStep.swift` | Modify (`:120-146`) | Surface gstFree/capital toggles + editable GST-amount field wired through `GstTreatment` |
| `Snapceipt/Features/Capture/ReceiptMapper.swift` | Modify (`:13-29`) | Thread `gstFree`/`capital` from the draft + set `gstSource` (`printed`/`manual`/nil) |
| `Snapceipt/Features/Capture/PendingExtractionReconciler.swift` | Modify (`:48-50`) | Set `gstSource` on re-extract |
| `Snapceipt/Sync/DTOs.swift` | Modify (`ExportResponse:73-78`, `ExportResult:81-84`) | Add `BasExportResponse` + `BasEcho` + `ExportResult.basPack` case |
| `Snapceipt/Sync/APIClient.swift` | Modify (protocol `:21-22`, `LiveAPIClient.export:163-175`) | Add `exportBas(...)` to protocol + Live conformer |
| `Snapceipt/Sync/StubAPIClient.swift` | Modify (`:77-84`) | `exportBas` stub (deterministic) |
| `Snapceipt/Features/Auth/SignInView.swift` | Modify (`PreviewAPIClient:182-185`) | `exportBas` preview stub |
| `SnapceiptTests/Mocks/MockAPIClient.swift` | Modify (`:34,51,126-131`) | `exportBas` handler + `exportBasCalls` recording |
| `Snapceipt/App/Router.swift` | Modify (`Overlay:11-65`) | Add `.bas` overlay case + `id` |
| `Snapceipt/App/RootView.swift` | Modify (`sheetBinding:509-544`, `sheetContent:546-586`, overlays `:252-260`) | Wire `.bas` as a full-screen overlay (exclude from sheet) |
| `Snapceipt/Shared/AccessibilityID.swift` | Modify (after `:230`) | BAS + editor a11y ids |
| `Snapceipt/Features/Reports/ReportsView.swift` | Modify (`body:30-62`, `:7-26`) | Gated BAS card at top + `onOpenBas` callback |
| `Snapceipt/Features/Reports/ExportSheet.swift` | Modify (`:8-32`, `:162-184`) | BAS-pinned path + new `.basPack` switch arm |
| `Snapceipt/App/AppLaunch.swift` | Modify (add `-uiTestBasSeed` fixture) | Seeded GST-registered business profile for the BAS UI test |
| `project.yml` | Modify (`SnapceiptTests` target) | Explicit `resources:` entry for `SnapceiptTests/Fixtures` |
| `SnapceiptTests/Fixtures/bas-golden.json` | Create (copied VERBATIM from backend) | Shared golden vectors |
| `SnapceiptTests/FixtureBundlingTests.swift` | Create | Smoke test: the golden fixture actually bundles |
| `SnapceiptTests/BasEngineTests.swift` | Create | Engine vs golden fixture (every label) |
| `SnapceiptTests/GstTreatmentTests.swift` | Create | Authority-rule unit tests (gstFree/derived/manual/confirm-income) |
| `SnapceiptTests/BasReconciliationTests.swift` | Create | Reconciliation helper tests |
| `SnapceiptTests/BasPeriodKeyTests.swift` | Create | periodKey formatting tests |
| `SnapceiptTests/BasLocalStoreTests.swift` | Create | PAYG + lodged snapshot/diff tests |
| `SnapceiptTests/ABNValidatorTests.swift` | Create | modulus-89 valid/invalid vectors |
| `SnapceiptTests/BasSyncTests.swift` | Create | 4-column round-trip (payload + pull) |
| `SnapceiptTests/CategorySeederGstTests.swift` | Create | Seed + backfill tests |
| `SnapceiptTests/BasExportClientTests.swift` | Create | `exportBas` decode + body + new `ExportResult.basPack` |
| `SnapceiptUITests/BasUITests.swift` | Create | Hermetic BAS journey (incl. confirm income → headline flips) + non-registered hides card |
| `SnapceiptUITests/ScreenshotTourUITests.swift` | Modify | New `test_area14_bas` (empty / needs-review / lodged) |

> **Cross-plan contract:** `SnapceiptTests/Fixtures/bas-golden.json` is authored by the BACKEND plan at `test/fixtures/bas-golden.json` (hand-computed per spec §4.3). Task 1 copies it VERBATIM. Do not regenerate or edit it on the iOS side.

---

## Task 1: Copy the shared golden-vector fixture + prove it bundles

**Files:**
- Create: `SnapceiptTests/Fixtures/bas-golden.json` (verbatim copy of `test/fixtures/bas-golden.json`)
- Modify: `project.yml` (`SnapceiptTests` target — explicit `resources:` for `SnapceiptTests/Fixtures`)
- Create: `SnapceiptTests/FixtureBundlingTests.swift`

> **Why this task exists as a gate:** there is NO precedent in the codebase for loading a bundled `.json` resource in tests (existing tests use inline JSON strings; no `Bundle(for:)`/`forResource:` anywhere in `SnapceiptTests`). The `SnapceiptTests` target is a host-based unit-test bundle (`TEST_HOST` set on the host app, `sources: - path: SnapceiptTests`, NO `resources:` stanza). xcodegen's auto-resource classification of a `.json` under a `sources` path is NOT guaranteed to land the file in `SnapceiptTests.xctest`. We therefore add an explicit `resources:` entry AND a smoke test that fails loudly (via `Issue.record`, never a force-unwrap) if the resource is missing — before any keystone engine test relies on it.

- [ ] **Step 1: Verify the backend fixture exists and inspect its shape**

Run: `test -f test/fixtures/bas-golden.json && python3 -c "import json,sys; d=json.load(open('test/fixtures/bas-golden.json')); print(len(d['vectors']), [v['name'] for v in d['vectors']])"`
Expected: prints the vector count and names including `canonical-registered`, `non-registered`, `refund`, `empty`, `monthly`. If the file does not exist, STOP — the backend plan's golden-vector task must land first.

- [ ] **Step 2: Copy it verbatim into the test bundle**

Run: `mkdir -p SnapceiptTests/Fixtures && cp test/fixtures/bas-golden.json SnapceiptTests/Fixtures/bas-golden.json && diff test/fixtures/bas-golden.json SnapceiptTests/Fixtures/bas-golden.json && echo IDENTICAL`
Expected: `IDENTICAL` (no diff output).

- [ ] **Step 3: Confirm the canonical first vector matches the spec §4.3 worked scenario**

Run: `python3 -c "import json; v=json.load(open('SnapceiptTests/Fixtures/bas-golden.json'))['vectors'][0]; e=v['expected']; assert e=={'g1':1100000,'g3':0,'oneA':100000,'g10':220000,'g11':143000,'g14':33000,'g17':330000,'oneB':30000,'netGst':70000,'payg':0,'totalPayable':70000}, e; print('OK', v['name'])"`
Expected: `OK canonical-registered`. If the assertion fails, the backend fixture does not match the frozen canonical numbers — STOP and reconcile with the backend plan before proceeding.

- [ ] **Step 4: Add an explicit resources entry to the test target**

In `project.yml`, under the `SnapceiptTests` target (currently `sources: - path: SnapceiptTests`), add a `resources:` stanza so the fixture is unambiguously classified as a test-bundle resource (not relying on xcodegen's sources globbing). The target block becomes:

```yaml
  SnapceiptTests:
    type: bundle.unit-test
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: SnapceiptTests
        excludes:
          - "Fixtures"          # excluded from sources; re-added as a resource below
      - path: SnapceiptTests/Fixtures
        buildPhase: resources
    dependencies:
      - target: Snapceipt
```

(Keep the existing `settings:`/`dependencies:` exactly as they are; only `sources:` is augmented. The `buildPhase: resources` marker forces the `Fixtures/` files into the Copy-Bundle-Resources phase of `SnapceiptTests.xctest`.)

- [ ] **Step 5: Write the bundling SMOKE test (fails soft, never force-unwraps)**

Create `SnapceiptTests/FixtureBundlingTests.swift`:

```swift
import Foundation
import Testing
@testable import Snapceipt

/// A bundle anchor so `Bundle(for:)` resolves the TEST target's resource bundle
/// (not the host app). Shared by the engine test.
final class GoldenAnchor {}

@Suite("Golden fixture bundling")
struct FixtureBundlingTests {
    @Test("bas-golden.json is bundled into the test target")
    func bundled() throws {
        let url = Bundle(for: GoldenAnchor.self).url(forResource: "bas-golden", withExtension: "json")
        guard let url else {
            Issue.record("bas-golden.json did NOT bundle into SnapceiptTests.xctest. " +
                         "Check the project.yml resources stanza for SnapceiptTests/Fixtures.")
            return
        }
        let data = try Data(contentsOf: url)
        #expect(data.count > 0)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((obj?["vectors"] as? [Any])?.count ?? 0 >= 5)
    }
}
```

- [ ] **Step 6: Regenerate the project, then build + run the smoke test**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/FixtureBundlingTests 2>&1 | tail -20`
Expected: `FixtureBundlingTests` PASS. If it reports the `Issue.record` failure, the resource is NOT bundling — fix `project.yml` (try `buildPhase: resources` vs a top-level `resources:` key) until the fixture resolves. Do NOT proceed to the engine task until this is green — it is the keystone the golden-vector lock depends on.

- [ ] **Step 7: Commit**

```bash
git add SnapceiptTests/Fixtures/bas-golden.json project.yml SnapceiptTests/FixtureBundlingTests.swift
git commit -m "test(bas): copy golden-vector fixture + prove it bundles into the test target

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Add the 4 new SwiftData columns (Transaction + Category)

**Files:**
- Modify: `Snapceipt/Model/Entities/Transaction.swift:24` (after `gstCents`), init `:38-90`
- Modify: `Snapceipt/Model/Entities/Category.swift:17-19`, init `:29-63`
- Test: `SnapceiptTests/SwiftDataModelTests.swift` (add a `@Test`)

- [ ] **Step 1: Write the failing test**

Append to `SnapceiptTests/SwiftDataModelTests.swift` (inside the existing `@Suite`/struct — match its existing `@MainActor` + `ModelContainer.makeSnapceiptContainer(inMemory: true)` setup; if no such helper exists in the suite, build the container inline as below):

```swift
@MainActor @Test func transactionAndCategoryCarryBasColumns() throws {
    let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
    let ctx = ModelContext(container)
    let t = Transaction(userId: "u1", profileId: "p1", catKey: "groceries",
                        amountCents: -33_000, txnDate: "2026-04-01",
                        gstFree: true, capital: false, gstSource: nil)
    ctx.insert(t)
    let c = Category(userId: "u1", profileId: "p1", key: "groceries", label: "Groceries",
                     icon: "tag", tint: "#C99A22", soft: "#F6EECE", gstFreeDefault: true)
    ctx.insert(c)
    try ctx.save()
    let tx = try ctx.fetch(FetchDescriptor<Transaction>()).first!
    #expect(tx.gstFree == true)
    #expect(tx.capital == false)
    #expect(tx.gstSource == nil)
    let cat = try ctx.fetch(FetchDescriptor<Category>()).first!
    #expect(cat.gstFreeDefault == true)
    // Defaults: a txn/category built WITHOUT the new params defaults to false/nil.
    let t2 = Transaction(userId: "u1", profileId: "p1", catKey: "fuel",
                         amountCents: -80_00, txnDate: "2026-04-02")
    #expect(t2.gstFree == false && t2.capital == false && t2.gstSource == nil)
    let c2 = Category(userId: "u1", profileId: "p1", key: "fuel", label: "Fuel",
                      icon: "tag", tint: "#2F6FB0", soft: "#E2ECF6")
    #expect(c2.gstFreeDefault == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/SwiftDataModelTests 2>&1 | tail -20`
Expected: FAIL — compile error "extra arguments 'gstFree', 'capital', 'gstSource' / 'gstFreeDefault' in call".

- [ ] **Step 3: Add the Transaction columns + init params**

In `Snapceipt/Model/Entities/Transaction.swift`, after line 24 (`var gstCents: Int?`):

```swift
    var gstCents: Int?
    var gstFree: Bool                // per-txn GST-free classifier (G3/G14)
    var capital: Bool                // per-expense capital flag (G10 vs G11)
    var gstSource: String?           // "printed" | "derived" | "manual" | nil
```

In the init signature, after `gstCents: Int? = nil,` (line 54):

```swift
        gstCents: Int? = nil,
        gstFree: Bool = false,
        capital: Bool = false,
        gstSource: String? = nil,
```

In the init body, after `self.gstCents = gstCents` (line 80):

```swift
        self.gstCents = gstCents
        self.gstFree = gstFree
        self.capital = capital
        self.gstSource = gstSource
```

- [ ] **Step 4: Add the Category column + init param**

In `Snapceipt/Model/Entities/Category.swift`, after line 19 (`var sortOrder: Int`):

```swift
    var sortOrder: Int
    var gstFreeDefault: Bool         // seeded default gstFree for new txns
```

In the init signature, after `sortOrder: Int = 0,` (line 40):

```swift
        sortOrder: Int = 0,
        gstFreeDefault: Bool = false,
```

In the init body, after `self.sortOrder = sortOrder` (line 57):

```swift
        self.sortOrder = sortOrder
        self.gstFreeDefault = gstFreeDefault
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/SwiftDataModelTests 2>&1 | tail -20`
Expected: PASS (`Test Suite 'SwiftDataModelTests' passed`).

- [ ] **Step 6: Commit**

```bash
git add Snapceipt/Model/Entities/Transaction.swift Snapceipt/Model/Entities/Category.swift SnapceiptTests/SwiftDataModelTests.swift
git commit -m "feat(bas): add gstFree/capital/gstSource to Transaction + gstFreeDefault to Category

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Wire the 4 columns through the sync mappers

**Files:**
- Modify: `Snapceipt/Sync/SyncEntityRegistry.swift` (`TransactionSyncMapper:178-231`, `CategorySyncMapper:324-359`)
- Test: `SnapceiptTests/BasSyncTests.swift` (Create)

> **Provenance-null note (v1 decision):** the Transaction `gstSource` upsert follows the existing nullable-string convention (`if let v = env.string("gstSource") { row.gstSource = v }`), so an incoming envelope with a NULL `gstSource` leaves the existing row value unchanged rather than clearing it. This is intentionally non-propagating in v1, matching the established `taxLabel`/`note` pattern. Consequence: a remote transition `gstSource: "derived" → null` (e.g. a user flips a row to GST-free on another device) does not clear provenance on this device. The authority-rule invariant (`gstFree=true ⇒ gstSource=NULL`) is still locally enforced by `GstTreatment` whenever the row is touched here, and `gstFree` itself DOES propagate (Bool), so the headline math stays correct; only the provenance label can briefly lag. If cross-device provenance-clearing becomes a requirement, special-case `gstSource` to honor an explicit null when the key is present — out of scope for v1.

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/BasSyncTests.swift` (mirrors `LogbookSyncTests.swift` — reuse its `makeEngine`/`envelope` shape inline):

```swift
import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor
private func makeEngine() throws -> (SyncEngine, ModelContext, MockAPIClient) {
    let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
    let context = ModelContext(container)
    let api = MockAPIClient()
    let engine = SyncEngine(api: api, context: context, auth: AuthStore(), toast: ToastCenter())
    UserDefaults.standard.removeObject(forKey: "sc.syncCursor")
    return (engine, context, api)
}

private func envelope(type: String, id: String, rev: Int, updatedAt: Int,
                      extra: [String: Any]) -> PullChange {
    var fields: [String: Any] = ["type": type, "id": id, "userId": "u1", "rev": rev,
                                 "createdAt": updatedAt, "updatedAt": updatedAt,
                                 "deletedAt": NSNull(), "lastEditedDeviceId": NSNull()]
    for (k, v) in extra { fields[k] = v }
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return try! JSONDecoder().decode(PullChange.self, from: data)
}

@MainActor
@Suite(.serialized)
struct BasSyncTests {
    @Test func transactionPayloadCarriesBasColumns() throws {
        let (engine, context, _) = try makeEngine()
        let t = Transaction(userId: "u1", profileId: "p1", catKey: "groceries",
                            amountCents: -33_000, txnDate: "2026-04-01",
                            gstFree: true, capital: false, gstSource: nil)
        context.insert(t)
        engine.enqueue(op: "upsert", entityType: .transaction, entity: t)
        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox[0].payloadJSON.contains("\"gstFree\":true"))
        #expect(outbox[0].payloadJSON.contains("\"capital\":false"))
        #expect(outbox[0].payloadJSON.contains("\"gstSource\":null"))
    }

    @Test func transactionPullAppliesBasColumns() async throws {
        let (engine, context, api) = try makeEngine()
        let id = ID.uuidv7()
        api.pullPages = [PullResponse(
            changes: [envelope(type: "transaction", id: id, rev: 2, updatedAt: 9000,
                               extra: ["profileId": "p1", "catKey": "office", "amountCents": -220_000,
                                       "txnDate": "2026-04-05", "gstFree": false, "capital": true,
                                       "gstSource": "manual"])],
            nextCursor: "C1", hasMore: false, serverTime: 9000)]
        await engine.pull()
        let row = try context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == id })).first!
        #expect(row.capital == true)
        #expect(row.gstFree == false)
        #expect(row.gstSource == "manual")
    }

    @Test func categoryRoundTripsGstFreeDefault() async throws {
        let (engine, context, api) = try makeEngine()
        let c = Category(userId: "u1", profileId: "p1", key: "groceries", label: "Groceries",
                         icon: "tag", tint: "#C99A22", soft: "#F6EECE", gstFreeDefault: true)
        context.insert(c)
        engine.enqueue(op: "upsert", entityType: .category, entity: c)
        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox[0].payloadJSON.contains("\"gstFreeDefault\":true"))

        let id = ID.uuidv7()
        api.pullPages = [PullResponse(
            changes: [envelope(type: "category", id: id, rev: 1, updatedAt: 1000,
                               extra: ["profileId": "p1", "key": "meals", "label": "Meals",
                                       "icon": "tag", "tint": "#E8602C", "soft": "#FBEADF",
                                       "gstFreeDefault": false])],
            nextCursor: "C2", hasMore: false, serverTime: 1000)]
        await engine.pull()
        let row = try context.fetch(FetchDescriptor<Category>(predicate: #Predicate { $0.id == id })).first!
        #expect(row.gstFreeDefault == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/BasSyncTests 2>&1 | tail -20`
Expected: FAIL — payload does not contain `gstFree`/`capital`/`gstSource`/`gstFreeDefault`; pull leaves them at defaults.

- [ ] **Step 3: Wire the Transaction mapper**

In `Snapceipt/Sync/SyncEntityRegistry.swift`, in `TransactionSyncMapper.upsert`, after line 203 (`if let v = env.int("gstCents") { row.gstCents = v }`):

```swift
        if let v = env.int("gstCents") { row.gstCents = v }
        if let v = env.bool("gstFree") { row.gstFree = v }
        if let v = env.bool("capital") { row.capital = v }
        // gstSource follows the nullable-string convention: a present non-null value
        // overwrites; an absent/NULL key leaves the local value untouched (v1; see
        // the task-header provenance-null note).
        if let v = env.string("gstSource") { row.gstSource = v }
```

In `TransactionSyncMapper.payload`, after line 224 (`f["gstCents"] = num(r.gstCents)`):

```swift
        f["gstCents"] = num(r.gstCents)
        f["gstFree"] = boolv(r.gstFree)
        f["capital"] = boolv(r.capital)
        f["gstSource"] = str(r.gstSource)
```

- [ ] **Step 4: Wire the Category mapper**

In `CategorySyncMapper.upsert`, after line 344 (`if let v = env.int("sortOrder") { row.sortOrder = v }`):

```swift
        if let v = env.int("sortOrder") { row.sortOrder = v }
        if let v = env.bool("gstFreeDefault") { row.gstFreeDefault = v }
```

In `CategorySyncMapper.payload`, after line 356 (`f["sortOrder"] = num(r.sortOrder)`):

```swift
        f["sortOrder"] = num(r.sortOrder)
        f["gstFreeDefault"] = boolv(r.gstFreeDefault)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/BasSyncTests 2>&1 | tail -20`
Expected: PASS (`BasSyncTests passed`).

- [ ] **Step 6: Commit**

```bash
git add Snapceipt/Sync/SyncEntityRegistry.swift SnapceiptTests/BasSyncTests.swift
git commit -m "feat(bas): wire gstFree/capital/gstSource/gstFreeDefault through sync mappers

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: CategorySeeder — seed gstFreeDefault + one-time backfill

**Files:**
- Modify: `Snapceipt/Features/Settings/CategorySeeder.swift:19-36` (SeedMeta), `:53-67` (insert)
- Test: `SnapceiptTests/CategorySeederGstTests.swift` (Create)

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/CategorySeederGstTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor
@Suite(.serialized)
struct CategorySeederGstTests {
    private func makeCtx() throws -> (ModelContext, SyncEngine) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let engine = SyncEngine(api: MockAPIClient(), context: ctx, auth: AuthStore(), toast: ToastCenter())
        return (ctx, engine)
    }

    @Test func seedSetsGroceriesGstFreeAndRestTaxable() throws {
        let (ctx, engine) = try makeCtx()
        CategorySeeder.ensure(profileId: "p1", userId: "u1", context: ctx, sync: engine)
        let cats = try ctx.fetch(FetchDescriptor<Category>())
        let byKey = Dictionary(uniqueKeysWithValues: cats.map { ($0.key, $0.gstFreeDefault) })
        #expect(byKey["groceries"] == true)
        #expect(byKey["meals"] == false)
        #expect(byKey["health"] == false)
        #expect(byKey["fuel"] == false)
        #expect(byKey["income"] == false)
    }

    @Test func backfillFlipsExistingGroceriesOnlyAndRunsOnce() throws {
        let (ctx, engine) = try makeCtx()
        // Simulate a pre-feature install: rows inserted WITHOUT gstFreeDefault (all false).
        let groceries = Category(userId: "u1", profileId: "p1", key: "groceries", label: "Groceries",
                                 icon: "tag", tint: "#C99A22", soft: "#F6EECE")
        let meals = Category(userId: "u1", profileId: "p1", key: "meals", label: "Meals",
                             icon: "tag", tint: "#E8602C", soft: "#FBEADF")
        ctx.insert(groceries); ctx.insert(meals); try ctx.save()
        let defaults = UserDefaults(suiteName: "sc.test.backfill.\(UUID().uuidString)")!

        CategorySeeder.backfillGstDefaults(profileId: "p1", context: ctx, sync: engine, defaults: defaults)
        #expect(groceries.gstFreeDefault == true)
        #expect(meals.gstFreeDefault == false)

        // Idempotent: a second run does not re-enqueue (outbox count stable after a fresh read).
        let outboxAfterFirst = try ctx.fetch(FetchDescriptor<OutboxMutation>()).count
        CategorySeeder.backfillGstDefaults(profileId: "p1", context: ctx, sync: engine, defaults: defaults)
        let outboxAfterSecond = try ctx.fetch(FetchDescriptor<OutboxMutation>()).count
        #expect(outboxAfterSecond == outboxAfterFirst)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/CategorySeederGstTests 2>&1 | tail -20`
Expected: FAIL — `backfillGstDefaults` undefined; `groceries` defaults false.

- [ ] **Step 3: Add the gstFree seed map + apply it in ensure()**

In `Snapceipt/Features/Settings/CategorySeeder.swift`, after the `seedMeta` dictionary (line 36), add a single-source map:

```swift
    /// The only GST-free-by-default category (review §4.2): groceries. Everything
    /// else (meals/fuel/software/office/home/health/travel/income) is taxable.
    static let gstFreeDefaultByKey: [CategoryKey: Bool] = [.groceries: true]
```

In `ensure()`, in the `Category(...)` init call (line 53-63), add the `gstFreeDefault:` argument after `sortOrder: sort`:

```swift
                sortOrder: sort,
                gstFreeDefault: gstFreeDefaultByKey[key] ?? false)
```

- [ ] **Step 4: Add the one-time backfill path**

In `Snapceipt/Features/Settings/CategorySeeder.swift`, before the closing `}` of `enum CategorySeeder`:

```swift
    /// One-time per-profile backfill for installs that seeded categories BEFORE
    /// gstFreeDefault existed (insert-only `ensure()` never revisits existing rows).
    /// Sets gstFreeDefault on the known category rows to match the seed table
    /// (only groceries → true), enqueues their upserts, and marks done. Idempotent.
    static func backfillGstDefaults(profileId: String, context: ModelContext,
                                    sync: any SyncEnqueuing, defaults: UserDefaults = .standard) {
        let doneKey = "sc.bas.gstDefaultsBackfilled.\(profileId)"
        if defaults.bool(forKey: doneKey) { return }
        let pid = profileId
        let rows = (try? context.fetch(FetchDescriptor<Category>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil }))) ?? []
        var changed = false
        for row in rows {
            let want = (CategoryKey(rawValue: row.key)).flatMap { gstFreeDefaultByKey[$0] } ?? false
            if row.gstFreeDefault != want {
                row.gstFreeDefault = want
                row.updatedAt = Epoch.nowMs()
                sync.enqueue(op: "upsert", entityType: .category, entity: row)
                changed = true
            }
        }
        if changed { try? context.save() }
        defaults.set(true, forKey: doneKey)
    }
```

(If the protocol used by `ensure()`'s `sync:` parameter is named differently than `SyncEnqueuing`, match the exact protocol name `ensure()` already declares — grep `func ensure(` in the file to confirm.)

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/CategorySeederGstTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Snapceipt/Features/Settings/CategorySeeder.swift SnapceiptTests/CategorySeederGstTests.swift
git commit -m "feat(bas): seed gstFreeDefault (groceries only) + one-time backfill

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: GstTreatment authority-rule helper

**Files:**
- Create: `Snapceipt/Features/Reports/Bas/GstTreatment.swift`
- Test: `SnapceiptTests/GstTreatmentTests.swift` (Create)

> This helper is the SINGLE mutation path for per-txn GST classification. Every editing surface (capture `ReviewStep`, the BAS reconciliation quick-fix, and the income-confirm affordance) routes through it so provenance stays consistent. It exposes: `applyGstFree` (toggle GST-free / re-derive), `applyManualGst` (typed exact amount → `manual`), and `confirmIncome` (mark an income row reviewed → `gstSource = "manual"`, which is what `BasViewModel.recompute` reads to clear the income-to-confirm count — see Task 13).

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/GstTreatmentTests.swift`:

```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("GstTreatment authority rule")
struct GstTreatmentTests {
    @Test("gstFree=true zeroes gstCents and nils gstSource")
    func gstFreeZeroes() {
        let r = GstTreatment.applyGstFree(true, totalCents: 33_000)
        #expect(r.gstCents == 0)
        #expect(r.gstSource == nil)
    }

    @Test("flipping back to taxable re-derives round(total/11) as derived")
    func flipBackDerives() {
        // |amount| = 110_000; round(110000/11) = 10_000.
        let r = GstTreatment.applyGstFree(false, totalCents: 110_000)
        #expect(r.gstCents == 10_000)
        #expect(r.gstSource == "derived")
    }

    @Test("typing an exact GST amount marks it manual")
    func typedIsManual() {
        let r = GstTreatment.applyManualGst(5_00)
        #expect(r.gstCents == 5_00)
        #expect(r.gstSource == "manual")
    }

    @Test("derive rounds half up at the .5 boundary")
    func deriveHalfUp() {
        // total 5 → 5/11 = 0.4545 → rounds to 0; total 6 → 0.545 → 1.
        #expect(GstTreatment.applyGstFree(false, totalCents: 5).gstCents == 0)
        #expect(GstTreatment.applyGstFree(false, totalCents: 6).gstCents == 1)
    }

    @Test("confirming income marks provenance manual (the income-reviewed signal)")
    func confirmIncome() {
        let r = GstTreatment.confirmIncome()
        #expect(r.gstSource == "manual")
        #expect(r.gstCents == nil)   // income GST is not split per-txn; provenance only
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/GstTreatmentTests 2>&1 | tail -20`
Expected: FAIL — `GstTreatment` undefined.

- [ ] **Step 3: Write the implementation**

Create `Snapceipt/Features/Reports/Bas/GstTreatment.swift`:

```swift
import Foundation

/// The per-transaction GST authority rule (spec §4.3/§4.6): a txn is either taxable
/// with a GST amount, or GST-free with gstCents == 0. The SINGLE mutation path for
/// classification — the capture editor, the BAS reconciliation quick-fix, and the
/// income-confirm affordance all route through it so provenance stays consistent.
/// Pure (no SwiftData) so it is unit-testable.
enum GstTreatment {
    struct Result: Equatable {
        let gstCents: Int?
        let gstSource: String?   // "derived" | "manual" | nil
    }

    /// round(|total| / 11), half-up. `totalCents` is the magnitude (>= 0).
    static func derivedGstCents(totalCents: Int) -> Int {
        Int((Double(totalCents) / 11.0).rounded())
    }

    /// Toggle gstFree. true ⇒ gstCents=0, gstSource=nil. false ⇒ re-derive
    /// (gstSource="derived"). `totalCents` is the magnitude of the txn amount.
    static func applyGstFree(_ gstFree: Bool, totalCents: Int) -> Result {
        if gstFree { return Result(gstCents: 0, gstSource: nil) }
        return Result(gstCents: derivedGstCents(totalCents: totalCents), gstSource: "derived")
    }

    /// User typed an exact GST amount → manual provenance (overrides ÷11).
    static func applyManualGst(_ cents: Int) -> Result {
        Result(gstCents: max(0, cents), gstSource: "manual")
    }

    /// User has reviewed an INCOME row (confirmed taxable vs GST-free). Income GST is
    /// not split per-txn, so this only stamps provenance = "manual" — the signal
    /// `BasViewModel.recompute`/`BasReconciliation` read to clear the income-to-confirm
    /// count and flip the headline from "Estimated" to firm.
    static func confirmIncome() -> Result {
        Result(gstCents: nil, gstSource: "manual")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/GstTreatmentTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Reports/Bas/GstTreatment.swift SnapceiptTests/GstTreatmentTests.swift
git commit -m "feat(bas): GstTreatment authority-rule helper (gstFree/derived/manual/confirm-income)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: BasEngine — the golden-vector-locked worksheet

**Files:**
- Create: `Snapceipt/Features/Reports/Bas/BasEngine.swift`
- Test: `SnapceiptTests/BasEngineTests.swift` (Create)

> Reuses the `GoldenAnchor` bundle anchor + the resource bundling proven in Task 1. The golden loop fails SOFT (`Issue.record` on a missing fixture) rather than force-unwrapping, so a bundling regression reports clearly instead of crashing.

- [ ] **Step 1: Write the canonical hand-checked test first**

Create `SnapceiptTests/BasEngineTests.swift` with the spec §4.3 worked scenario AND the golden-fixture loop:

```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("BasEngine")
struct BasEngineTests {
    private func txn(_ amount: Int, gstFree: Bool = false, capital: Bool = false,
                     date: String = "2026-04-15") -> BasEngine.Txn {
        BasEngine.Txn(amountCents: amount, gstFree: gstFree, capital: capital, txnDate: date)
    }

    @Test("canonical registered scenario matches the frozen §4.3 worked numbers")
    func canonical() {
        let r = BasEngine.compute(
            txns: [
                txn(1_100_000),                                  // taxable income
                txn(-110_000),                                   // taxable non-capital expense
                txn(-220_000, capital: true),                    // taxable capital (>$1,000 → G10)
                txn(-33_000, gstFree: true),                     // GST-free groceries
            ],
            gstRegistered: true,
            manual: BasEngine.Manual(paygInstalmentCents: 0))
        #expect(r.g1 == 1_100_000)
        #expect(r.g3 == 0)
        #expect(r.oneA == 100_000)
        #expect(r.g10 == 220_000)
        #expect(r.g11 == 143_000)   // (110_000 + 33_000) — capital removed from G11
        #expect(r.g14 == 33_000)
        #expect(r.g17 == 330_000)
        #expect(r.oneB == 30_000)
        #expect(r.netGstCents == 70_000)
        #expect(r.paygCents == 0)
        #expect(r.totalPayableCents == 70_000)
    }

    @Test("non-registered forces 1A = 0")
    func nonRegistered() {
        let r = BasEngine.compute(txns: [txn(1_100_000)], gstRegistered: false,
                                  manual: BasEngine.Manual(paygInstalmentCents: 0))
        #expect(r.oneA == 0)
        #expect(r.g1 == 1_100_000)   // G1 still reports total sales
    }

    @Test("refund: 1B > 1A yields a negative net (ATO owes you)")
    func refund() {
        let r = BasEngine.compute(
            txns: [txn(110_000), txn(-1_100_000)], gstRegistered: true,
            manual: BasEngine.Manual(paygInstalmentCents: 0))
        // 1A = round(110000/11)=10_000; 1B = round(1100000/11)=100_000 → net = -90_000.
        #expect(r.oneA == 10_000)
        #expect(r.oneB == 100_000)
        #expect(r.netGstCents == -90_000)
    }

    @Test("PAYG is summed into total but kept separate from net 9")
    func payg() {
        let r = BasEngine.compute(txns: [txn(1_100_000)], gstRegistered: true,
                                  manual: BasEngine.Manual(paygInstalmentCents: 25_000))
        #expect(r.netGstCents == 100_000)
        #expect(r.paygCents == 25_000)
        #expect(r.totalPayableCents == 125_000)
    }

    @Test("capital ≤ $1,000 falls into G11, not G10")
    func capitalThreshold() {
        // -100_000 cents = exactly $1,000 → NOT > $1,000 → G11.
        let r = BasEngine.compute(txns: [txn(-100_000, capital: true)], gstRegistered: true,
                                  manual: BasEngine.Manual(paygInstalmentCents: 0))
        #expect(r.g10 == 0)
        #expect(r.g11 == 100_000)
    }

    // The SHARED golden fixture (copied verbatim from the backend) — both engines
    // assert these identical numbers.
    private struct Golden: Decodable {
        struct Vector: Decodable {
            let name: String
            let gstRegistered: Bool
            let paygInstalmentCents: Int
            let txns: [GTxn]
            let expected: Expected
        }
        struct GTxn: Decodable { let amountCents: Int; let gstFree: Bool; let capital: Bool; let txnDate: String }
        struct Expected: Decodable {
            let g1, g3, oneA, g10, g11, g14, g17, oneB, netGst, payg, totalPayable: Int
        }
        let vectors: [Vector]
    }

    @Test("BasEngine matches every label of every golden vector")
    func goldenVectors() throws {
        // GoldenAnchor + the bundled resource are proven in FixtureBundlingTests.
        guard let url = Bundle(for: GoldenAnchor.self).url(forResource: "bas-golden", withExtension: "json") else {
            Issue.record("bas-golden.json missing from the test bundle — see FixtureBundlingTests/project.yml.")
            return
        }
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
        #expect(golden.vectors.count >= 5)   // canonical/non-registered/refund/empty/monthly
        for v in golden.vectors {
            let r = BasEngine.compute(
                txns: v.txns.map { BasEngine.Txn(amountCents: $0.amountCents, gstFree: $0.gstFree,
                                                 capital: $0.capital, txnDate: $0.txnDate) },
                gstRegistered: v.gstRegistered,
                manual: BasEngine.Manual(paygInstalmentCents: v.paygInstalmentCents))
            let e = v.expected
            #expect(r.g1 == e.g1, "\(v.name) g1")
            #expect(r.g3 == e.g3, "\(v.name) g3")
            #expect(r.oneA == e.oneA, "\(v.name) 1A")
            #expect(r.g10 == e.g10, "\(v.name) g10")
            #expect(r.g11 == e.g11, "\(v.name) g11")
            #expect(r.g14 == e.g14, "\(v.name) g14")
            #expect(r.g17 == e.g17, "\(v.name) g17")
            #expect(r.oneB == e.oneB, "\(v.name) 1B")
            #expect(r.netGstCents == e.netGst, "\(v.name) net9")
            #expect(r.paygCents == e.payg, "\(v.name) payg")
            #expect(r.totalPayableCents == e.totalPayable, "\(v.name) total")
        }
    }
}
```

(`GoldenAnchor` is defined once in `FixtureBundlingTests.swift` from Task 1 — do NOT redeclare it here.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/BasEngineTests 2>&1 | tail -20`
Expected: FAIL — `BasEngine` undefined.

- [ ] **Step 3: Write the implementation**

Create `Snapceipt/Features/Reports/Bas/BasEngine.swift`:

```swift
import Foundation

/// Pure AU GST calculation worksheet (spec §4.3), identical math to the backend
/// `basEngine.ts`, golden-vector-locked. Income vs purchase = SIGN ONLY
/// (amountCents > 0 = sale, < 0 = purchase). All values in cents; the screen/PDF
/// round to whole dollars. Worksheet method: 1A/1B = round(aggregate / 11) once.
enum BasEngine {
    /// Minimal txn snapshot the engine needs (caller filters to the period window).
    struct Txn: Equatable {
        let amountCents: Int     // signed
        let gstFree: Bool
        let capital: Bool
        let txnDate: String      // "yyyy-MM-dd" (caller already in-window)
    }

    /// Manual worksheet parameters (only paygInstalmentCents is user-editable in v1;
    /// the rest are engine params fixed at 0 per spec §4.9).
    struct Manual: Equatable {
        var paygInstalmentCents: Int = 0
        var exportsCents: Int = 0
        var inputTaxedSalesCents: Int = 0
        var salesAdjustmentCents: Int = 0
        var inputTaxedPurchaseCents: Int = 0
        var privateUseCents: Int = 0
        var purchaseAdjustmentCents: Int = 0
    }

    /// The full worksheet result (cents).
    struct Result: Equatable {
        let g1, g2, g3, g4, g5, g6, g7, g8: Int
        let oneA: Int            // G9
        let g10, g11, g12, g13, g14, g15, g16, g17, g18, g19: Int
        let oneB: Int            // G20
        let eightA, eightB: Int
        let netGstCents: Int     // label 9 = 8A − 8B
        let paygCents: Int       // label 5A
        let totalPayableCents: Int
    }

    /// ATO capital threshold for turnover < $1M: > $1,000 → G10, else G11.
    static let capitalThresholdCents = 100_000

    /// round(value / 11), half-up.
    private static func divEleven(_ value: Int) -> Int { Int((Double(value) / 11.0).rounded()) }

    static func compute(txns: [Txn], gstRegistered: Bool, manual: Manual) -> Result {
        // Sales (amount > 0).
        let g1 = txns.filter { $0.amountCents > 0 }.reduce(0) { $0 + $1.amountCents }
        let g2 = manual.exportsCents
        let g3 = txns.filter { $0.amountCents > 0 && $0.gstFree }.reduce(0) { $0 + $1.amountCents }
        let g4 = manual.inputTaxedSalesCents
        let g5 = g2 + g3 + g4
        let g6 = g1 - g5
        let g7 = manual.salesAdjustmentCents
        let g8 = g6 + g7
        let oneA = gstRegistered ? divEleven(g8) : 0

        // Purchases (amount < 0; magnitudes are −amount).
        let expenses = txns.filter { $0.amountCents < 0 }
        let totalExpense = expenses.reduce(0) { $0 + (-$1.amountCents) }
        let g10 = expenses.filter { $0.capital && (-$0.amountCents) > capitalThresholdCents }
            .reduce(0) { $0 + (-$1.amountCents) }
        let g11 = totalExpense - g10
        let g12 = g10 + g11
        let g13 = manual.inputTaxedPurchaseCents
        let g14 = expenses.filter { $0.gstFree }.reduce(0) { $0 + (-$1.amountCents) }
        let g15 = manual.privateUseCents
        let g16 = g13 + g14 + g15
        let g17 = g12 - g16
        let g18 = manual.purchaseAdjustmentCents
        let g19 = g17 + g18
        let oneB = divEleven(g19)

        let eightA = oneA
        let eightB = oneB
        let net = eightA - eightB
        let payg = manual.paygInstalmentCents
        return Result(g1: g1, g2: g2, g3: g3, g4: g4, g5: g5, g6: g6, g7: g7, g8: g8,
                      oneA: oneA, g10: g10, g11: g11, g12: g12, g13: g13, g14: g14, g15: g15,
                      g16: g16, g17: g17, g18: g18, g19: g19, oneB: oneB,
                      eightA: eightA, eightB: eightB, netGstCents: net,
                      paygCents: payg, totalPayableCents: net + payg)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/BasEngineTests 2>&1 | tail -25`
Expected: PASS — all `BasEngineTests` cases including `goldenVectors`. If a golden vector fails, the iOS engine and the backend `basEngine.ts` disagree — fix the engine math (NOT the fixture).

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Reports/Bas/BasEngine.swift SnapceiptTests/BasEngineTests.swift
git commit -m "feat(bas): pure BasEngine worksheet, golden-vector-locked to backend

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: BasReconciliation helpers

**Files:**
- Create: `Snapceipt/Features/Reports/Bas/BasReconciliation.swift`
- Test: `SnapceiptTests/BasReconciliationTests.swift` (Create)

> **Income-confirmed semantics:** an income row counts as "reviewed" once its provenance is user-touched (`gstSource == "manual"`, written by `GstTreatment.confirmIncome`) OR it is explicitly GST-free. Receipt-captured income arrives `gstSource == "printed"`/`"derived"` and is taxable → unconfirmed until the user taps Confirm. This is the signal `Item.incomeConfirmed` carries; the VM (Task 13) maps it from `gstSource`. The income-to-confirm count is therefore clearable in-app (via the confirm affordance in Tasks 13/15), which flips the headline from "Estimated" to firm — covered end-to-end by the Task 18 UI test.

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/BasReconciliationTests.swift`:

```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("BAS reconciliation")
struct BasReconciliationTests {
    private func item(_ amount: Int, gstFree: Bool = false, gstSource: String? = nil,
                      gstCents: Int? = nil, confirmed: Bool = false) -> BasReconciliation.Item {
        BasReconciliation.Item(id: UUID().uuidString, amountCents: amount, gstFree: gstFree,
                               gstSource: gstSource, gstCents: gstCents, incomeConfirmed: confirmed)
    }

    @Test("estimated GST = taxable expenses whose gstSource == derived")
    func estimated() {
        let items = [item(-110_00, gstSource: "derived"), item(-50_00, gstSource: "manual"),
                     item(-30_00, gstFree: true, gstSource: nil)]
        #expect(BasReconciliation.estimatedGstCount(items) == 1)
    }

    @Test("income-to-confirm gates the firm headline")
    func incomeGate() {
        let unconfirmed = [item(500_00, confirmed: false)]
        #expect(BasReconciliation.incomeToConfirmCount(unconfirmed) == 1)
        #expect(BasReconciliation.isHeadlineEstimated(unconfirmed) == true)
        let confirmed = [item(500_00, confirmed: true)]
        #expect(BasReconciliation.incomeToConfirmCount(confirmed) == 0)
        #expect(BasReconciliation.isHeadlineEstimated(confirmed) == false)
    }

    @Test("printed-line discrepancy flags when |printed − round(total/11)| > max(2c, 1% of total)")
    func discrepancy() {
        // total 100_00 → round/11 = 9_09; threshold = max(2, 1% of 100_00=100) = 100c.
        // printed 9_50 → |950 − 909| = 41 ≤ 100 → NOT flagged.
        #expect(BasReconciliation.isPrintedDiscrepant(totalCents: 100_00, printedGstCents: 9_50) == false)
        // printed 12_00 → |1200 − 909| = 291 > 100 → flagged.
        #expect(BasReconciliation.isPrintedDiscrepant(totalCents: 100_00, printedGstCents: 12_00) == true)
        // tiny total 100c → round/11 = 9; threshold = max(2, 1%=1) = 2c.
        // printed 12 → |12 − 9| = 3 > 2 → flagged.
        #expect(BasReconciliation.isPrintedDiscrepant(totalCents: 100, printedGstCents: 12) == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/BasReconciliationTests 2>&1 | tail -20`
Expected: FAIL — `BasReconciliation` undefined.

- [ ] **Step 3: Write the implementation**

Create `Snapceipt/Features/Reports/Bas/BasReconciliation.swift`:

```swift
import Foundation

/// Pure trust-layer helpers over a period's transactions (spec §4.6). Drives the
/// reconciliation strip + the "Estimated" → firm headline gate.
enum BasReconciliation {
    /// One reconcilable txn snapshot.
    struct Item: Equatable {
        let id: String
        let amountCents: Int       // signed
        let gstFree: Bool
        let gstSource: String?     // "printed" | "derived" | "manual" | nil
        let gstCents: Int?
        let incomeConfirmed: Bool  // user has confirmed taxable/GST-free for income
    }

    /// Taxable expenses whose GST was the ÷11 fallback (gstSource == "derived").
    static func estimatedGstCount(_ items: [Item]) -> Int {
        items.filter { $0.amountCents < 0 && $0.gstSource == "derived" }.count
    }

    /// Income entries not yet confirmed taxable/GST-free.
    static func incomeToConfirmCount(_ items: [Item]) -> Int {
        items.filter { $0.amountCents > 0 && !$0.incomeConfirmed }.count
    }

    /// The confident headline is gated on income being reviewed.
    static func isHeadlineEstimated(_ items: [Item]) -> Bool {
        incomeToConfirmCount(items) > 0
    }

    /// A printed GST line disagrees with round(total/11) by more than the tolerance
    /// max(2 cents, 1% of total). `totalCents` is the magnitude (>= 0).
    static func isPrintedDiscrepant(totalCents: Int, printedGstCents: Int) -> Bool {
        let derived = Int((Double(totalCents) / 11.0).rounded())
        let tolerance = max(2, Int((Double(totalCents) * 0.01).rounded()))
        return abs(printedGstCents - derived) > tolerance
    }

    /// Printed-line discrepancies among the period items (printed source only).
    static func printedDiscrepancyCount(_ items: [Item]) -> Int {
        items.filter {
            $0.amountCents < 0 && $0.gstSource == "printed"
            && isPrintedDiscrepant(totalCents: -$0.amountCents, printedGstCents: $0.gstCents ?? 0)
        }.count
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/BasReconciliationTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Reports/Bas/BasReconciliation.swift SnapceiptTests/BasReconciliationTests.swift
git commit -m "feat(bas): reconciliation helpers (estimated/income-gate/printed-discrepancy)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: BasPeriodKey

**Files:**
- Create: `Snapceipt/Features/Reports/Bas/BasPeriodKey.swift`
- Test: `SnapceiptTests/BasPeriodKeyTests.swift` (Create)

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/BasPeriodKeyTests.swift`:

```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("BasPeriodKey")
struct BasPeriodKeyTests {
    private func utc(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    @Test("quarterly key is <fyStartYear>Q<n>")
    func quarterly() {
        // Apr–Jun 2026 = Q4 of FY2025-26 → "2025Q4".
        let w = Period.quarter.window(now: utc("2026-05-15"), startMonth: 7)
        #expect(BasPeriodKey.make(window: w, basPeriod: .quarterly, startMonth: 7) == "2025Q4")
        // Jul–Sep 2025 = Q1 of FY2025-26 → "2025Q1".
        let w2 = Period.quarter.window(now: utc("2025-08-10"), startMonth: 7)
        #expect(BasPeriodKey.make(window: w2, basPeriod: .quarterly, startMonth: 7) == "2025Q1")
    }

    @Test("monthly key is <calendarYear>M<mm>")
    func monthly() {
        let w = Period.month.window(now: utc("2026-04-09"), startMonth: 7)
        #expect(BasPeriodKey.make(window: w, basPeriod: .monthly, startMonth: 7) == "2026M04")
        let w2 = Period.month.window(now: utc("2026-12-31"), startMonth: 7)
        #expect(BasPeriodKey.make(window: w2, basPeriod: .monthly, startMonth: 7) == "2026M12")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/BasPeriodKeyTests 2>&1 | tail -20`
Expected: FAIL — `BasPeriodKey` undefined.

- [ ] **Step 3: Write the implementation**

Create `Snapceipt/Features/Reports/Bas/BasPeriodKey.swift` (computes its own quarter index — `Period.quarterIndex` is private):

```swift
import Foundation

/// The stable per-period storage key (spec §4.6). Quarterly → "<fyStartYear>Q<n>"
/// (e.g. 2025Q4 = Apr–Jun FY2025-26); monthly → "<calendarYear>M<mm>" (e.g. 2026M04).
/// Derived from the period WINDOW's start so it matches whatever window the stepper
/// navigated to (no hidden Date()).
enum BasPeriodKey {
    private static var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    /// AU-FY quarter index 1...4 of `month` for FY starting `startMonth`.
    private static func quarterIndex(month: Int, startMonth: Int) -> Int {
        let offset = (month - startMonth + 12) % 12
        return offset / 3 + 1
    }

    static func make(window: Period.Window, basPeriod: BasPeriod, startMonth: Int) -> String {
        let comps = utcCal.dateComponents([.year, .month], from: window.start)
        let year = comps.year!, month = comps.month!
        switch basPeriod {
        case .monthly:
            return String(format: "%dM%02d", year, month)
        case .quarterly:
            let qi = quarterIndex(month: month, startMonth: startMonth)
            // FY start year: if the quarter-start month is on/after startMonth it is
            // the same calendar year; otherwise the FY started the previous year.
            let fyStartYear = month >= startMonth ? year : year - 1
            return "\(fyStartYear)Q\(qi)"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/BasPeriodKeyTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Reports/Bas/BasPeriodKey.swift SnapceiptTests/BasPeriodKeyTests.swift
git commit -m "feat(bas): BasPeriodKey (quarterly fyStartYear / monthly calendar key)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: BasLocalStore — PAYG + lodged snapshot/diff

**Files:**
- Create: `Snapceipt/Features/Reports/Bas/BasLocalStore.swift`
- Test: `SnapceiptTests/BasLocalStoreTests.swift` (Create)

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/BasLocalStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("BasLocalStore")
struct BasLocalStoreTests {
    private func store() -> BasLocalStore {
        BasLocalStore(defaults: UserDefaults(suiteName: "sc.test.bas.\(UUID().uuidString)")!)
    }

    @Test("payg persists per profile+period and defaults to 0")
    func payg() {
        let s = store()
        #expect(s.paygInstalmentCents(profileId: "p1", periodKey: "2025Q4") == 0)
        s.setPaygInstalmentCents(25_000, profileId: "p1", periodKey: "2025Q4")
        #expect(s.paygInstalmentCents(profileId: "p1", periodKey: "2025Q4") == 25_000)
        // Different period is independent.
        #expect(s.paygInstalmentCents(profileId: "p1", periodKey: "2025Q3") == 0)
    }

    @Test("mark-as-lodged stores a snapshot and reports drift")
    func lodged() {
        let s = store()
        #expect(s.lodgedSnapshot(profileId: "p1", periodKey: "2025Q4") == nil)
        let snap = BasLocalStore.Snapshot(g1: 1_100_000, oneA: 100_000, oneB: 30_000,
                                          netGst: 70_000, payg: 0, total: 70_000, lodgedAtMs: 123)
        s.markLodged(snap, profileId: "p1", periodKey: "2025Q4")
        let read = s.lodgedSnapshot(profileId: "p1", periodKey: "2025Q4")
        #expect(read?.oneA == 100_000)
        #expect(read?.lodgedAtMs == 123)
        // Drift detection: a later recompute differing from the snapshot flags changed.
        #expect(s.hasDrifted(current: BasLocalStore.Snapshot(g1: 1_100_000, oneA: 100_000,
                 oneB: 30_000, netGst: 70_000, payg: 0, total: 70_000, lodgedAtMs: 999),
                 profileId: "p1", periodKey: "2025Q4") == false)
        #expect(s.hasDrifted(current: BasLocalStore.Snapshot(g1: 1_100_000, oneA: 99_000,
                 oneB: 30_000, netGst: 69_000, payg: 0, total: 69_000, lodgedAtMs: 999),
                 profileId: "p1", periodKey: "2025Q4") == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/BasLocalStoreTests 2>&1 | tail -20`
Expected: FAIL — `BasLocalStore` undefined.

- [ ] **Step 3: Write the implementation**

Create `Snapceipt/Features/Reports/Bas/BasLocalStore.swift`:

```swift
import Foundation

/// Local-only (NOT synced in v1) per-profile/period BAS state (spec §4.6): the
/// editable PAYG instalment + a Mark-as-lodged snapshot. Keyed
/// `sc.bas.<profileId>.<periodKey>`. Drift is advisory (the snapshot never locks
/// data; corrections go on the next BAS).
final class BasLocalStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The filed-quarter snapshot stored at Mark-as-lodged.
    struct Snapshot: Codable, Equatable {
        let g1, oneA, oneB, netGst, payg, total: Int
        let lodgedAtMs: Int
    }

    private func base(_ profileId: String, _ periodKey: String) -> String {
        "sc.bas.\(profileId).\(periodKey)"
    }

    func paygInstalmentCents(profileId: String, periodKey: String) -> Int {
        defaults.integer(forKey: base(profileId, periodKey) + ".payg")
    }

    func setPaygInstalmentCents(_ cents: Int, profileId: String, periodKey: String) {
        defaults.set(max(0, cents), forKey: base(profileId, periodKey) + ".payg")
    }

    func markLodged(_ snapshot: Snapshot, profileId: String, periodKey: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: base(profileId, periodKey) + ".lodged")
    }

    func lodgedSnapshot(profileId: String, periodKey: String) -> Snapshot? {
        guard let data = defaults.data(forKey: base(profileId, periodKey) + ".lodged") else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// True iff a snapshot exists and any reportable figure differs from `current`
    /// (lodgedAtMs is excluded from the comparison — it is a timestamp, not a figure).
    func hasDrifted(current: Snapshot, profileId: String, periodKey: String) -> Bool {
        guard let snap = lodgedSnapshot(profileId: profileId, periodKey: periodKey) else { return false }
        return snap.g1 != current.g1 || snap.oneA != current.oneA || snap.oneB != current.oneB
            || snap.netGst != current.netGst || snap.payg != current.payg || snap.total != current.total
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/BasLocalStoreTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Reports/Bas/BasLocalStore.swift SnapceiptTests/BasLocalStoreTests.swift
git commit -m "feat(bas): BasLocalStore (per-period PAYG + Mark-as-lodged snapshot/diff)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: ABNValidator (modulus-89) + inline hint in TaxSettingsView

**Files:**
- Create: `Snapceipt/Features/Settings/ABNValidator.swift`
- Modify: `Snapceipt/Features/Settings/TaxSettingsView.swift:67-88` (ABN field)
- Test: `SnapceiptTests/ABNValidatorTests.swift` (Create)

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/ABNValidatorTests.swift`:

```swift
import Testing
@testable import Snapceipt

@Suite("ABNValidator modulus-89")
struct ABNValidatorTests {
    @Test("a known-valid ABN passes (ATO example 51 824 753 556)")
    func valid() {
        #expect(ABNValidator.isValid("51824753556") == true)
        #expect(ABNValidator.isValid("51 824 753 556") == true)   // spaces ignored
    }

    @Test("a one-digit-off ABN fails the checksum")
    func invalid() {
        #expect(ABNValidator.isValid("51824753557") == false)
    }

    @Test("wrong length or non-digits is invalid")
    func malformed() {
        #expect(ABNValidator.isValid("123") == false)
        #expect(ABNValidator.isValid("5182475355X") == false)
    }

    @Test("empty is treated as not-invalid (no hint shown)")
    func empty() {
        // Empty means "unset" — the field hint is non-blocking, so empty is NOT invalid.
        #expect(ABNValidator.looksInvalid("") == false)
        #expect(ABNValidator.looksInvalid("   ") == false)
        #expect(ABNValidator.looksInvalid("51824753557") == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/ABNValidatorTests 2>&1 | tail -20`
Expected: FAIL — `ABNValidator` undefined.

- [ ] **Step 3: Write the implementation**

Create `Snapceipt/Features/Settings/ABNValidator.swift`:

```swift
import Foundation

/// Offline ATO ABN checksum (modulus-89): strip non-digits; require 11 digits;
/// subtract 1 from the first digit; multiply by weights [10,1,3,5,7,9,11,13,15,17,19];
/// sum; valid iff sum % 89 == 0. No network lookup in v1 (spec §4.6/§8).
enum ABNValidator {
    private static let weights = [10, 1, 3, 5, 7, 9, 11, 13, 15, 17, 19]

    static func isValid(_ raw: String) -> Bool {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 11 else { return false }
        var nums = digits.compactMap { $0.wholeNumberValue }
        guard nums.count == 11 else { return false }
        nums[0] -= 1
        let sum = zip(nums, weights).reduce(0) { $0 + $1.0 * $1.1 }
        return sum % 89 == 0
    }

    /// Non-blocking hint predicate: an EMPTY/whitespace field is not "invalid"
    /// (it is simply unset); a non-empty field that fails the checksum is.
    static func looksInvalid(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        return !isValid(trimmed)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/ABNValidatorTests 2>&1 | tail -20`
Expected: PASS. (If the ATO example `51824753556` does not validate, the canonical ABN test vector is wrong — verify the weights/first-digit-minus-1 order against the test before changing the algorithm.)

- [ ] **Step 5: Add the inline hint to TaxSettingsView**

In `Snapceipt/Features/Settings/TaxSettingsView.swift`, replace the ABN field `VStack` (lines 71-77) with one that appends a hint below the field. Use the literal `"tax.abn.hint"` for this task; Task 13 introduces the `AccessibilityID.taxAbnHint` constant and swaps it back:

```swift
                VStack(alignment: .leading, spacing: 4) {
                    Text("ABN").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                    TextField("00 000 000 000", text: $abnText)
                        .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                        .onChange(of: abnText) { _, v in vm.setAbn(v) }
                        .accessibilityIdentifier(AccessibilityID.taxAbnField)
                    if ABNValidator.looksInvalid(abnText) {
                        Text("This ABN doesn't look right — check the digits.")
                            .font(.ui(12)).foregroundStyle(Palette.alert)
                            .accessibilityIdentifier("tax.abn.hint")
                    }
                }
```

- [ ] **Step 6: Build to confirm the view compiles**

Run: `xcodebuild build -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Snapceipt/Features/Settings/ABNValidator.swift Snapceipt/Features/Settings/TaxSettingsView.swift SnapceiptTests/ABNValidatorTests.swift
git commit -m "feat(bas): ABNValidator modulus-89 + inline non-blocking ABN hint

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: APIClient — BasExportResponse DTO + ExportResult.basPack + exportBas (with ExportSheet switch fixed)

**Files:**
- Modify: `Snapceipt/Sync/DTOs.swift:73-84`
- Modify: `Snapceipt/Sync/APIClient.swift:21-22` (protocol), `:163-175` (Live)
- Modify: `Snapceipt/Sync/StubAPIClient.swift:77-84`
- Modify: `Snapceipt/Features/Auth/SignInView.swift:182-185` (Preview)
- Modify: `SnapceiptTests/Mocks/MockAPIClient.swift:34,51,126-131`
- Modify: `Snapceipt/Features/Reports/ExportSheet.swift:168-178` (add the `.basPack` switch arm in the SAME commit)
- Test: `SnapceiptTests/BasExportClientTests.swift` (Create)

> **CRITICAL ORDERING FIX:** the ONLY exhaustive `switch` over `ExportResult` in the app target is `ExportSheet.generate()` (verified at `Snapceipt/Features/Reports/ExportSheet.swift:168`, cases `.download` and `.sent`). Adding `case basPack(...)` to the enum makes that switch non-exhaustive, so the WHOLE app target stops compiling — and Step 8 of this task runs `xcodebuild test` which builds the app target. We therefore add a placeholder `.basPack` arm to `ExportSheet.generate()` IN THIS SAME COMMIT (Step 3 below). Task 17 later replaces that placeholder with the real BAS-pinned behavior. Without this, this task is not green.

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/BasExportClientTests.swift` (mirrors `ExportClientTests.swift`, reusing `MockURLProtocol`):

```swift
import Foundation
import Testing
@testable import Snapceipt

@Suite(.serialized)
struct BasExportClientTests {
    private func makeClient() -> LiveAPIClient {
        let auth = AuthStore(); auth.clear()
        auth.save(SessionResponse(accessToken: "acc", refreshToken: "refresh-0123456789abcdef0123456789abcdef",
                                  expiresIn: 900, user: SessionUser(id: "u1", email: "a@b.com", displayName: "Ada")))
        return LiveAPIClient(baseURL: URL(string: "https://api.test")!, auth: auth,
                             session: MockURLProtocol.makeSession())
    }
    private func json(_ s: String) -> Data { Data(s.utf8) }

    @Test("bas export decodes the basPack result + posts the bas body")
    func basPack() async throws {
        let client = makeClient()
        MockURLProtocol.setHandler { _ in
            (200, ["Content-Type": "application/json"],
             self.json(#"{"pdfUrl":"/export/dl/p","csvUrl":"/export/dl/c","expiresAt":1790000000000,"emailed":false,"bas":{"g1":1100000,"oneA":100000,"oneB":30000,"netGst":70000,"payg":0,"totalPayable":70000}}"#))
        }
        let result = try await client.exportBas(profileId: "p1", from: "2026-04-01", to: "2026-06-30",
                                                paygInstalmentCents: 0, toEmail: nil)
        guard case let .basPack(pdfUrl, csvUrl, expiresAt, emailed, bas) = result else {
            Issue.record("expected .basPack"); return
        }
        #expect(pdfUrl == "/export/dl/p")
        #expect(csvUrl == "/export/dl/c")
        #expect(expiresAt == 1790000000000)
        #expect(emailed == false)
        #expect(bas.oneA == 100000 && bas.netGst == 70000 && bas.totalPayable == 70000)
        // body assertions
        let bodyData = MockURLProtocol.lastRequest?.httpBodyData() ?? Data()
        let obj = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(obj?["format"] as? String == "bas")
        #expect(obj?["from"] as? String == "2026-04-01")
        let basBody = obj?["bas"] as? [String: Any]
        #expect(basBody?["paygInstalmentCents"] as? Int == 0)
    }
}

private extension URLRequest {
    func httpBodyData() -> Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(); let bufSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize); defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize); if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/BasExportClientTests 2>&1 | tail -20`
Expected: FAIL — `exportBas`/`.basPack`/`BasEcho` undefined.

- [ ] **Step 3: Add the DTOs + the new enum case + the ExportSheet placeholder arm (same commit)**

In `Snapceipt/Sync/DTOs.swift`, after `ExportResponse` (line 78), add:

```swift
/// The cents summary echoed by the bas-format export so the caller can reconcile
/// screen-vs-pack (spec §4.4).
struct BasEcho: Decodable, Equatable {
    let g1: Int
    let oneA: Int
    let oneB: Int
    let netGst: Int
    let payg: Int
    let totalPayable: Int
}

/// Decoded POST /export {format:"bas"} response (a genuinely new shape — two links
/// + an echoed summary, NOT the pdf/csv {url} or accountant {status} shape).
struct BasExportResponse: Decodable {
    let pdfUrl: String
    let csvUrl: String
    let expiresAt: Int
    let emailed: Bool
    let bas: BasEcho
}

/// POST /export body for the bas format: { profileId, format:"bas", from, to, bas:{paygInstalmentCents}, toEmail? }.
struct BasExportRequestBody: Encodable {
    let profileId: String
    let format: String   // always "bas"
    let from: String
    let to: String
    let bas: Payload
    var toEmail: String?
    struct Payload: Encodable { let paygInstalmentCents: Int }
}
```

In `ExportResult` (line 81-84), add the `basPack` case:

```swift
enum ExportResult: Equatable {
    case download(url: String, expiresAt: Int)
    case sent(status: String, outboxId: String)
    case basPack(pdfUrl: String, csvUrl: String, expiresAt: Int, emailed: Bool, bas: BasEcho)
}
```

(`BasEcho: Equatable` keeps `ExportResult: Equatable` synthesizable.)

**Now, in the SAME commit, keep the app target compiling.** In `Snapceipt/Features/Reports/ExportSheet.swift`, in `generate()`'s `switch result` (line 168-178), add a placeholder arm so the switch stays exhaustive. Task 17 replaces the body of this arm:

```swift
            switch result {
            case let .download(url, _):
                // Resolve a shareable URL (absolute or app-host-relative).
                let full = url.hasPrefix("http") ? url : "https://api.snapceipt.cc\(url)"
                shareURL = URL(string: full)
                phase = .idle
            case .sent:
                onSaveAccountantEmail(email)
                phase = .idle
                onClose()
            case .basPack:
                // Placeholder: the non-pinned export() never returns .basPack. The
                // real BAS-pinned path is wired in Task 17.
                phase = .idle
            }
```

- [ ] **Step 4: Add to the protocol + LiveAPIClient**

In `Snapceipt/Sync/APIClient.swift`, after the `export(...)` protocol method (line 22):

```swift
    func export(profileId: String, format: String, from: String, to: String,
                toEmail: String?) async throws -> ExportResult
    /// POST /export {format:"bas"} — render the BAS pack (PDF + CSV to R2, optional
    /// accountant email) and return both links + the echoed cents summary. (spec §4.4)
    func exportBas(profileId: String, from: String, to: String,
                   paygInstalmentCents: Int, toEmail: String?) async throws -> ExportResult
```

In `LiveAPIClient`, after the `export(...)` method (line 175):

```swift
    func exportBas(profileId: String, from: String, to: String,
                   paygInstalmentCents: Int, toEmail: String?) async throws -> ExportResult {
        let body = BasExportRequestBody(profileId: profileId, format: "bas", from: from, to: to,
                                        bas: .init(paygInstalmentCents: paygInstalmentCents),
                                        toEmail: toEmail)
        let resp: BasExportResponse = try await send("POST", "/export", body: body, authenticated: true)
        return .basPack(pdfUrl: resp.pdfUrl, csvUrl: resp.csvUrl, expiresAt: resp.expiresAt,
                        emailed: resp.emailed, bas: resp.bas)
    }
```

- [ ] **Step 5: Add to the Stub conformer**

In `Snapceipt/Sync/StubAPIClient.swift`, after the `export(...)` method (line 84):

```swift
    func exportBas(profileId: String, from: String, to: String,
                   paygInstalmentCents: Int, toEmail: String?) async throws -> ExportResult {
        .basPack(pdfUrl: "/export/dl/stub-bas-pdf", csvUrl: "/export/dl/stub-bas-csv",
                 expiresAt: 1_790_000_000_000, emailed: toEmail != nil,
                 bas: BasEcho(g1: 1_100_000, oneA: 100_000, oneB: 30_000,
                              netGst: 70_000, payg: paygInstalmentCents, totalPayable: 70_000 + paygInstalmentCents))
    }
```

- [ ] **Step 6: Add to the Preview conformer**

In `Snapceipt/Features/Auth/SignInView.swift`, after the `export(...)` preview method (line 185):

```swift
    func exportBas(profileId: String, from: String, to: String,
                   paygInstalmentCents: Int, toEmail: String?) async throws -> ExportResult {
        .basPack(pdfUrl: "/export/dl/preview-bas-pdf", csvUrl: "/export/dl/preview-bas-csv",
                 expiresAt: 1_790_000_000_000, emailed: false,
                 bas: BasEcho(g1: 0, oneA: 0, oneB: 0, netGst: 0, payg: 0, totalPayable: 0))
    }
```

- [ ] **Step 7: Add to the Mock conformer**

In `SnapceiptTests/Mocks/MockAPIClient.swift`, after `exportHandler` (line 34):

```swift
    var exportBasHandler: ((_ profileId: String, _ from: String, _ to: String, _ paygInstalmentCents: Int, _ toEmail: String?) async throws -> ExportResult)?
```

After `exportCalls` (line 51):

```swift
    private(set) var exportBasCalls: [(profileId: String, from: String, to: String, paygInstalmentCents: Int, toEmail: String?)] = []
```

After the `export(...)` method (line 131):

```swift
    func exportBas(profileId: String, from: String, to: String,
                   paygInstalmentCents: Int, toEmail: String?) async throws -> ExportResult {
        exportBasCalls.append((profileId, from, to, paygInstalmentCents, toEmail))
        guard let h = exportBasHandler else { throw MockAPIClientError.unscripted }
        return try await h(profileId, from, to, paygInstalmentCents, toEmail)
    }
```

- [ ] **Step 8: Run test to verify it passes (and the app target still compiles)**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/BasExportClientTests 2>&1 | tail -20`
Expected: PASS — and no compile error in `ExportSheet.swift` (the placeholder `.basPack` arm keeps the app target's exhaustive switch valid).

- [ ] **Step 9: Commit**

```bash
git add Snapceipt/Sync/DTOs.swift Snapceipt/Sync/APIClient.swift Snapceipt/Sync/StubAPIClient.swift Snapceipt/Features/Auth/SignInView.swift Snapceipt/Features/Reports/ExportSheet.swift SnapceiptTests/Mocks/MockAPIClient.swift SnapceiptTests/BasExportClientTests.swift
git commit -m "feat(bas): BasExportResponse DTO + ExportResult.basPack + exportBas (4 conformers) + ExportSheet switch arm

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Editable per-txn GST controls on capture + gstSource provenance

**Files:**
- Modify: `Snapceipt/Features/Capture/ExtractedReceipt.swift:41-93` (add `gstFree`/`capital` draft fields)
- Modify: `Snapceipt/Features/Capture/Views/ReviewStep.swift:120-146` (toggles + editable GST amount via `GstTreatment`)
- Modify: `Snapceipt/Features/Capture/ReceiptMapper.swift:13-29` (thread `gstFree`/`capital` + set `gstSource`)
- Modify: `Snapceipt/Features/Capture/PendingExtractionReconciler.swift:48-50` (set `gstSource` on re-extract)
- Test: `SnapceiptTests/ReceiptMapperTests.swift` (add `@Test`s)

> This is the spec §4.6/§5 editable-per-txn-GST surface. The repo's only transaction-editing surface today is the capture `ReviewStep` (verified — there is NO standalone transaction-edit view; `ReviewStep` edits an `ExtractedReceipt` draft via `@Binding` and `CaptureViewModel.swift:95` maps it through `ReceiptMapper.map`). We add `gstFree`/`capital` to the draft, surface the three controls (`txnGstFreeToggle`/`txnCapitalToggle`/`txnGstAmountField`) wired through `GstTreatment`, and thread the result into the mapped `Transaction`.

- [ ] **Step 1: Write the failing test**

Append to `SnapceiptTests/ReceiptMapperTests.swift` (match its existing `@Suite`/struct + `ExtractedReceipt` construction):

```swift
@Test("a printed GST line sets gstSource = printed; no GST line leaves it nil")
func gstSourceFromCapture() {
    let withGst = ExtractedReceipt(
        merchant: "The Grounds", date: "2026-05-28", total: 42.50, gst: 3.86,
        categoryKey: "meals", deductible: 50, lineItems: [], confidence: 0.9, needsReview: false)
    let (t1, _) = ReceiptMapper.map(withGst, mode: "business", profileId: "p1", userId: "u1")
    #expect(t1.gstSource == "printed")
    #expect(t1.gstCents == 3_86)
    #expect(t1.gstFree == false)
    #expect(t1.capital == false)

    let noGst = ExtractedReceipt(
        merchant: "Cash sale", date: "2026-05-28", total: 10.00, gst: nil,
        categoryKey: "office", deductible: 100, lineItems: [], confidence: 0.9, needsReview: false)
    let (t2, _) = ReceiptMapper.map(noGst, mode: "business", profileId: "p1", userId: "u1")
    #expect(t2.gstSource == nil)
    #expect(t2.gstCents == nil)
}

@Test("a gst-free draft maps to gstFree=true, gstCents=0, gstSource=nil")
func gstFreeDraftMaps() {
    var draft = ExtractedReceipt(
        merchant: "Woolworths", date: "2026-05-28", total: 33.00, gst: 3.00,
        categoryKey: "groceries", deductible: 100, lineItems: [], confidence: 0.9, needsReview: false)
    draft.gstFree = true
    let (t, _) = ReceiptMapper.map(draft, mode: "business", profileId: "p1", userId: "u1")
    #expect(t.gstFree == true)
    #expect(t.gstCents == 0)
    #expect(t.gstSource == nil)
}

@Test("a capital draft maps capital=true through to the txn")
func capitalDraftMaps() {
    var draft = ExtractedReceipt(
        merchant: "Apple", date: "2026-05-28", total: 2200.00, gst: 200.00,
        categoryKey: "software", deductible: 100, lineItems: [], confidence: 0.9, needsReview: false)
    draft.capital = true
    let (t, _) = ReceiptMapper.map(draft, mode: "business", profileId: "p1", userId: "u1")
    #expect(t.capital == true)
}
```

(Match the real `ExtractedReceipt` initializer argument labels exactly — read `Snapceipt/Features/Capture/ExtractedReceipt.swift:86-92` and adjust the calls; the verified init order is `merchant, date, total, gst, categoryKey, deductible, lineItems, confidence, needsReview, ...`. The fields that matter for these tests are `gst:`, `total:`, plus the new mutable `gstFree`/`capital`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/ReceiptMapperTests 2>&1 | tail -20`
Expected: FAIL — `draft.gstFree`/`draft.capital` undefined; `gstSource` nil even with a printed GST line.

- [ ] **Step 3: Add the editable draft fields**

In `Snapceipt/Features/Capture/ExtractedReceipt.swift`, add two mutable fields to the struct (after `taxLabel` ~line 54), defaulted so existing decode/init sites are unaffected:

```swift
    var paymentMethod: String? = nil
    var taxLabel: String? = nil
    /// User-editable GST treatment (spec §4.6). Defaulted so existing init/decode
    /// callers are unchanged; surfaced in ReviewStep.
    var gstFree: Bool = false
    var capital: Bool = false
```

Add the same two as defaulted trailing params on the memberwise `init` (after `extractionStatus` in the init signature, ~line 86-90) so they can be set inline in tests, and assign them in the body:

```swift
         taxLabel: String? = nil,
         gstFree: Bool = false,
         capital: Bool = false,
         extractionStatus: String = "done") {
        // ...existing assignments...
        self.gstFree = gstFree
        self.capital = capital
```

(Do NOT add them to `CodingKeys`/`Decodable` — they are local UI state, not wire fields. Confirm the existing custom `init(from:)` leaves them at their defaults.)

- [ ] **Step 4: Thread gstFree/capital + gstSource through ReceiptMapper**

In `Snapceipt/Features/Capture/ReceiptMapper.swift`, in the `Transaction(...)` init, replace the `gstCents:` line (line 26) and add the three new fields, routing GST through `GstTreatment` so provenance is consistent:

```swift
        let magnitude = cents(draft.total)
        let signed = draft.categoryKey == CategoryKey.income.rawValue ? magnitude : -magnitude

        // GST authority rule: gst-free ⇒ 0/nil; else honor the printed line as the
        // manual/printed amount (provenance "printed" when a line was extracted).
        let treatment: GstTreatment.Result = draft.gstFree
            ? GstTreatment.applyGstFree(true, totalCents: magnitude)
            : GstTreatment.Result(gstCents: draft.gst.map(cents),
                                  gstSource: draft.gst != nil ? "printed" : nil)

        let txn = Transaction(
            userId: userId,
            profileId: profileId,
            merchant: draft.merchant,
            catKey: draft.categoryKey,
            amountCents: signed,
            currency: "AUD",
            txnDate: draft.date,
            mode: mode.lowercased(),
            taxLabel: draft.taxLabel,
            deductiblePct: draft.deductible,
            paymentMethod: draft.paymentMethod,
            isAi: true,
            gstCents: treatment.gstCents,
            gstFree: draft.gstFree,
            capital: draft.capital,
            gstSource: treatment.gstSource,
            source: "scan",
            extractionStatus: draft.extractionStatus
        )
```

(Confirm the exact existing argument ORDER of the `Transaction(...)` call when inserting `gstFree`/`capital`/`gstSource` — they were added in Task 2 right after `gstCents:`. The labelled-init makes ordering forgiving, but keep them adjacent to `gstCents:` for readability.)

- [ ] **Step 5: Set gstSource on re-extract**

In `Snapceipt/Features/Capture/PendingExtractionReconciler.swift`, after `txn.gstCents = r.gst.map(ReceiptMapper.cents)` (line 48):

```swift
            txn.gstCents = r.gst.map(ReceiptMapper.cents)
            txn.gstSource = r.gst != nil ? "printed" : nil
```

- [ ] **Step 6: Surface the controls in ReviewStep**

In `Snapceipt/Features/Capture/Views/ReviewStep.swift`, add the three GST controls to the editable field stack (after the `taxLabel` field block at lines 142-145, before `profileToggle` at line 146). They are only meaningful in business mode, so gate on `mode == "business"`:

```swift
            if mode == "business" {
                Toggle("GST-free (no GST)", isOn: Binding(
                    get: { draft.gstFree },
                    set: { isFree in
                        draft.gstFree = isFree
                        // Authority rule: keep the displayed GST in sync immediately.
                        let r = GstTreatment.applyGstFree(isFree, totalCents: Int((draft.total as NSDecimalNumber).doubleValue * 100))
                        draft.gst = r.gstCents.map { Decimal($0) / 100 }
                    }))
                    .accessibilityIdentifier(AccessibilityID.txnGstFreeToggle)

                Toggle("Capital purchase (asset)", isOn: $draft.capital)
                    .accessibilityIdentifier(AccessibilityID.txnCapitalToggle)

                if !draft.gstFree {
                    field("GST amount") {
                        TextField("GST", text: Binding(
                            get: { draft.gst.map { "\($0)" } ?? "" },
                            set: { s in
                                let cents = Int((Double(s) ?? 0) * 100)
                                let r = GstTreatment.applyManualGst(cents)
                                draft.gst = r.gstCents.map { Decimal($0) / 100 }
                            }))
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier(AccessibilityID.txnGstAmountField)
                    }
                }
            }
```

(`field(_:_:)` is the existing private helper in this file at line 265; reuse it. The `AccessibilityID.txn*` constants are introduced in Task 13 — until then this file references them; to keep THIS task independently green, add the three constants now in Task 13's file OR use the literals `"txn.gstFree.toggle"`, `"txn.capital.toggle"`, `"txn.gstAmount.field"` here and swap to constants in Task 13. Use the literals here.)

Replace the three `AccessibilityID.txn*` references above with the literals `"txn.gstFree.toggle"`, `"txn.capital.toggle"`, `"txn.gstAmount.field"` for this task.

- [ ] **Step 7: Run test + build to verify**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/ReceiptMapperTests 2>&1 | tail -10 && xcodebuild build -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" 2>&1 | tail -5`
Expected: ReceiptMapper tests PASS, then `** BUILD SUCCEEDED **` (ReviewStep compiles with the new controls).

- [ ] **Step 8: Commit**

```bash
git add Snapceipt/Features/Capture/ExtractedReceipt.swift Snapceipt/Features/Capture/Views/ReviewStep.swift Snapceipt/Features/Capture/ReceiptMapper.swift Snapceipt/Features/Capture/PendingExtractionReconciler.swift SnapceiptTests/ReceiptMapperTests.swift
git commit -m "feat(bas): editable per-txn GST (gstFree/capital/amount) in capture review + gstSource provenance

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: AccessibilityIDs for BAS + editor

**Files:**
- Modify: `Snapceipt/Shared/AccessibilityID.swift` (after line 230)
- Modify: `Snapceipt/Features/Settings/TaxSettingsView.swift` (swap the Task 10 literal)
- Modify: `Snapceipt/Features/Capture/Views/ReviewStep.swift` (swap the Task 12 literals)
- Test: `SnapceiptTests/AccessibilityIDBasTests.swift` (Create — a presence check)

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/AccessibilityIDBasTests.swift`:

```swift
import Testing
@testable import Snapceipt

@Suite("AccessibilityID BAS ids")
struct AccessibilityIDBasTests {
    @Test("BAS + editor ids exist with stable string values")
    func ids() {
        #expect(AccessibilityID.reportsBasCard == "reports.bas.card")
        #expect(AccessibilityID.basScreen == "bas.screen")
        #expect(AccessibilityID.basPeriodStepper == "bas.period.stepper")
        #expect(AccessibilityID.basCopyG1 == "bas.copy.g1")
        #expect(AccessibilityID.basCopy1A == "bas.copy.1a")
        #expect(AccessibilityID.basCopy1B == "bas.copy.1b")
        #expect(AccessibilityID.basReconcileRowPrefix == "bas.reconcile.row.")
        #expect(AccessibilityID.basConfirmIncome == "bas.reconcile.confirmIncome")
        #expect(AccessibilityID.basPaygField == "bas.payg.field")
        #expect(AccessibilityID.basFullWorksheetToggle == "bas.fullWorksheet.toggle")
        #expect(AccessibilityID.basMarkLodged == "bas.markLodged")
        #expect(AccessibilityID.basExport == "bas.export")
        #expect(AccessibilityID.txnGstFreeToggle == "txn.gstFree.toggle")
        #expect(AccessibilityID.txnCapitalToggle == "txn.capital.toggle")
        #expect(AccessibilityID.txnGstAmountField == "txn.gstAmount.field")
        #expect(AccessibilityID.taxAbnHint == "tax.abn.hint")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/AccessibilityIDBasTests 2>&1 | tail -20`
Expected: FAIL — these constants are undefined.

- [ ] **Step 3: Add the constants**

In `Snapceipt/Shared/AccessibilityID.swift`, before the final closing `}` (after line 230):

```swift

    // BAS (F8)
    static let reportsBasCard = "reports.bas.card"
    static let basScreen = "bas.screen"
    static let basPeriodStepper = "bas.period.stepper"
    static let basCopyG1 = "bas.copy.g1"
    static let basCopy1A = "bas.copy.1a"
    static let basCopy1B = "bas.copy.1b"
    static let basReconcileRowPrefix = "bas.reconcile.row."          // + transaction.id / "income"/"estimated"/"printed"
    static let basConfirmIncome = "bas.reconcile.confirmIncome"      // confirm-all-income quick-fix
    static let basPaygField = "bas.payg.field"
    static let basFullWorksheetToggle = "bas.fullWorksheet.toggle"
    static let basMarkLodged = "bas.markLodged"
    static let basExport = "bas.export"
    // Transaction editor GST fields (F8)
    static let txnGstFreeToggle = "txn.gstFree.toggle"
    static let txnCapitalToggle = "txn.capital.toggle"
    static let txnGstAmountField = "txn.gstAmount.field"
    // Tax & GST ABN hint (F8)
    static let taxAbnHint = "tax.abn.hint"
```

- [ ] **Step 4: Swap the Task 10 + Task 12 literals to constants**

In `Snapceipt/Features/Settings/TaxSettingsView.swift`, replace `.accessibilityIdentifier("tax.abn.hint")` with `.accessibilityIdentifier(AccessibilityID.taxAbnHint)`.

In `Snapceipt/Features/Capture/Views/ReviewStep.swift`, replace the three literals with constants: `"txn.gstFree.toggle"` → `AccessibilityID.txnGstFreeToggle`, `"txn.capital.toggle"` → `AccessibilityID.txnCapitalToggle`, `"txn.gstAmount.field"` → `AccessibilityID.txnGstAmountField`.

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/AccessibilityIDBasTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Snapceipt/Shared/AccessibilityID.swift Snapceipt/Features/Settings/TaxSettingsView.swift Snapceipt/Features/Capture/Views/ReviewStep.swift SnapceiptTests/AccessibilityIDBasTests.swift
git commit -m "feat(bas): BAS + GST-editor accessibility identifiers

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 14: BasViewModel (with income-confirm + reconciliation quick-fix)

**Files:**
- Create: `Snapceipt/Features/Reports/Bas/BasViewModel.swift`
- Test: `SnapceiptTests/BasViewModelTests.swift` (Create)

> **incomeConfirmed FIX:** receipt-captured income arrives `gstSource == "printed"`/`"derived"` and is taxable (not gstFree), so under a naive rule it would NEVER be `incomeConfirmed` and the headline would read "Estimated" forever with no way to clear it. This VM exposes an explicit `confirmIncome(itemId:)` (and `confirmAllIncome()`) action that stamps the income txn's `gstSource = "manual"` via `GstTreatment.confirmIncome()` and re-runs `recompute()`. `recompute()` maps `incomeConfirmed` from exactly that signal (`gstSource == "manual" || gstFree`), so the income-to-confirm count is reachable to 0 and the headline flips to firm. The same VM exposes `fixEstimatedAsGstFree`/`setManualGst` quick-fixes for the reconciliation strip. All mutations route through `GstTreatment` and persist via SwiftData, then `recompute()`.

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/BasViewModelTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor
@Suite(.serialized)
struct BasViewModelTests {
    private func setup(gstRegistered: Bool, confirmedIncome: Bool = false)
        throws -> (BasViewModel, ModelContext, MockAPIClient, BasLocalStore) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let api = MockAPIClient()
        let store = BasLocalStore(defaults: UserDefaults(suiteName: "sc.test.basvm.\(UUID().uuidString)")!)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        let now = f.date(from: "2026-05-15")!   // Apr–Jun 2026 → Q4 FY2025-26
        func t(_ a: Int, gstFree: Bool = false, capital: Bool = false, incomeConfirmed: Bool = false) {
            ctx.insert(Transaction(userId: "u1", profileId: "p1", catKey: a > 0 ? "income" : "office",
                                   amountCents: a, txnDate: "2026-05-01",
                                   gstFree: gstFree, capital: capital,
                                   gstSource: a > 0 ? (incomeConfirmed ? "manual" : "derived") : "derived"))
        }
        t(1_100_000, incomeConfirmed: confirmedIncome)
        t(-110_000)
        t(-220_000, capital: true)
        t(-33_000, gstFree: true)
        try ctx.save()
        let vm = BasViewModel(context: ctx, api: api, store: store, userId: "u1", profileId: "p1",
                              gstRegistered: gstRegistered, basPeriod: .quarterly, startMonth: 7, now: now)
        return (vm, ctx, api, store)
    }

    @Test("computes the canonical worksheet for a registered profile")
    func registered() throws {
        let (vm, _, _, _) = try setup(gstRegistered: true, confirmedIncome: true)
        #expect(vm.result.g1 == 1_100_000)
        #expect(vm.result.oneA == 100_000)
        #expect(vm.result.oneB == 30_000)
        #expect(vm.result.netGstCents == 70_000)
        #expect(vm.periodKey == "2025Q4")
    }

    @Test("non-registered forces 1A = 0")
    func nonRegistered() throws {
        let (vm, _, _, _) = try setup(gstRegistered: false)
        #expect(vm.result.oneA == 0)
    }

    @Test("unconfirmed income keeps the headline Estimated; confirming flips it to firm")
    func confirmIncomeFlipsHeadline() throws {
        let (vm, _, _, _) = try setup(gstRegistered: true, confirmedIncome: false)
        #expect(vm.isHeadlineEstimated == true)
        #expect(vm.incomeToConfirmCount == 1)
        vm.confirmAllIncome()
        #expect(vm.incomeToConfirmCount == 0)
        #expect(vm.isHeadlineEstimated == false)
    }

    @Test("estimated-GST quick-fix to GST-free clears the estimated count")
    func estimatedQuickFix() throws {
        let (vm, _, _, _) = try setup(gstRegistered: true, confirmedIncome: true)
        // The three expenses are all gstSource=derived except the gst-free one.
        let before = vm.estimatedGstCount
        #expect(before >= 1)
        let firstEstimated = vm.reconcileItems.first { $0.amountCents < 0 && $0.gstSource == "derived" }!
        vm.fixEstimatedAsGstFree(itemId: firstEstimated.id)
        #expect(vm.estimatedGstCount == before - 1)
    }

    @Test("PAYG round-trips through the local store and feeds the total")
    func payg() throws {
        let (vm, _, _, store) = try setup(gstRegistered: true, confirmedIncome: true)
        vm.setPaygInstalmentCents(25_000)
        #expect(vm.result.totalPayableCents == 95_000)
        #expect(store.paygInstalmentCents(profileId: "p1", periodKey: "2025Q4") == 25_000)
    }

    @Test("mark-as-lodged writes a snapshot; later edit drifts")
    func lodged() throws {
        let (vm, ctx, _, _) = try setup(gstRegistered: true, confirmedIncome: true)
        vm.markAsLodged()
        #expect(vm.lodgedAtMs != nil)
        #expect(vm.hasDrifted == false)
        let income = try ctx.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.amountCents > 0 })).first!
        income.amountCents = 1_200_000
        vm.recompute()
        #expect(vm.hasDrifted == true)
    }

    @Test("export calls exportBas with the window + payg and surfaces the pack")
    func export() async throws {
        let (vm, _, api, _) = try setup(gstRegistered: true, confirmedIncome: true)
        api.exportBasHandler = { _, _, _, payg, _ in
            .basPack(pdfUrl: "/p", csvUrl: "/c", expiresAt: 1, emailed: false,
                     bas: BasEcho(g1: 1_100_000, oneA: 100_000, oneB: 30_000,
                                  netGst: 70_000, payg: payg, totalPayable: 70_000 + payg))
        }
        vm.setPaygInstalmentCents(0)
        await vm.export(toEmail: nil)
        #expect(api.exportBasCalls.count == 1)
        #expect(api.exportBasCalls[0].from == "2026-04-01")
        #expect(api.exportBasCalls[0].to == "2026-06-30")
        #expect(vm.exportPdfUrl == "/p")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/BasViewModelTests 2>&1 | tail -20`
Expected: FAIL — `BasViewModel` undefined.

- [ ] **Step 3: Write the implementation**

Create `Snapceipt/Features/Reports/Bas/BasViewModel.swift`:

```swift
import Foundation
import SwiftData

/// Drives `BasView` (spec §4.6/§4.7). Fetches in-window non-deleted txns for the
/// active profile, runs `BasEngine`, derives reconciliation, persists PAYG + the
/// Mark-as-lodged snapshot via `BasLocalStore`, and calls `exportBas`. It also owns
/// the per-txn quick-fix mutations (confirm income, mark gst-free, type manual GST),
/// all routed through `GstTreatment` and re-running `recompute()`. `now` is injected
/// (no hidden Date()).
@Observable
@MainActor
final class BasViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let store: BasLocalStore
    @ObservationIgnored private let userId: String
    @ObservationIgnored private let profileId: String
    @ObservationIgnored private let gstRegistered: Bool
    @ObservationIgnored private let basPeriod: BasPeriod
    @ObservationIgnored private let startMonth: Int
    @ObservationIgnored private var now: Date

    private(set) var window: Period.Window
    private(set) var periodKey: String
    private(set) var result: BasEngine.Result
    private(set) var reconcileItems: [BasReconciliation.Item]
    private(set) var lodgedAtMs: Int?
    private(set) var exportInProgress = false
    private(set) var exportError: String?
    private(set) var exportPdfUrl: String?
    private(set) var exportCsvUrl: String?
    private(set) var exportEmailed = false

    private(set) var paygInstalmentCents: Int

    init(context: ModelContext, api: APIClient, store: BasLocalStore, userId: String,
         profileId: String, gstRegistered: Bool, basPeriod: BasPeriod, startMonth: Int, now: Date) {
        self.context = context; self.api = api; self.store = store
        self.userId = userId; self.profileId = profileId; self.gstRegistered = gstRegistered
        self.basPeriod = basPeriod; self.startMonth = startMonth; self.now = now
        let p: Period = (basPeriod == .quarterly) ? .quarter : .month
        let w = p.window(now: now, startMonth: startMonth)
        self.window = w
        self.periodKey = BasPeriodKey.make(window: w, basPeriod: basPeriod, startMonth: startMonth)
        self.paygInstalmentCents = 0
        self.result = BasEngine.compute(txns: [], gstRegistered: gstRegistered, manual: BasEngine.Manual())
        self.reconcileItems = []
        self.lodgedAtMs = nil
        self.paygInstalmentCents = store.paygInstalmentCents(profileId: profileId, periodKey: periodKey)
        self.lodgedAtMs = store.lodgedSnapshot(profileId: profileId, periodKey: periodKey)?.lodgedAtMs
        recompute()
    }

    /// "yyyy-MM-dd" UTC for the inclusive window end (end is exclusive → minus one day).
    var fromISO: String { ExportDateFormatter.shared.string(from: window.start) }
    var toISO: String { ExportDateFormatter.shared.string(from: window.end.addingTimeInterval(-86_400)) }

    var nextDue: Date { BasSchedule.nextDue(basPeriod, on: now) }
    var isHeadlineEstimated: Bool { BasReconciliation.isHeadlineEstimated(reconcileItems) }
    var estimatedGstCount: Int { BasReconciliation.estimatedGstCount(reconcileItems) }
    var incomeToConfirmCount: Int { BasReconciliation.incomeToConfirmCount(reconcileItems) }
    var printedDiscrepancyCount: Int { BasReconciliation.printedDiscrepancyCount(reconcileItems) }

    var hasDrifted: Bool {
        store.hasDrifted(current: currentSnapshot(), profileId: profileId, periodKey: periodKey)
    }

    /// In-window non-deleted txns for the active profile.
    private func windowTxns() -> [Transaction] {
        let pid = profileId
        let rows = (try? context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil }))) ?? []
        let iso = ExportDateFormatter.shared
        return rows.filter {
            iso.date(from: $0.txnDate).map { $0 >= window.start && $0 < window.end } ?? false
        }
    }

    func recompute() {
        let inWindow = windowTxns()
        let engineTxns = inWindow.map {
            BasEngine.Txn(amountCents: $0.amountCents, gstFree: $0.gstFree,
                          capital: $0.capital, txnDate: $0.txnDate)
        }
        result = BasEngine.compute(txns: engineTxns, gstRegistered: gstRegistered,
                                   manual: BasEngine.Manual(paygInstalmentCents: paygInstalmentCents))
        reconcileItems = inWindow.map {
            // Income is "confirmed" once the user has reviewed it — signalled by a
            // user-touched provenance (gstSource == "manual", written by
            // GstTreatment.confirmIncome) OR an explicit gst-free flag. Derived income
            // (the capture default) is unconfirmed until the user taps Confirm.
            BasReconciliation.Item(id: $0.id, amountCents: $0.amountCents, gstFree: $0.gstFree,
                                   gstSource: $0.gstSource, gstCents: $0.gstCents,
                                   incomeConfirmed: $0.gstFree || $0.gstSource == "manual")
        }
    }

    // MARK: - Reconciliation quick-fixes (mutate the txn, then recompute)

    private func txn(_ id: String) -> Transaction? {
        windowTxns().first { $0.id == id }
    }

    private func persist(_ row: Transaction) {
        row.updatedAt = Epoch.nowMs()
        try? context.save()
        recompute()
    }

    /// Confirm a single income row as reviewed (stamps provenance manual).
    func confirmIncome(itemId: String) {
        guard let row = txn(itemId), row.amountCents > 0 else { return }
        let r = GstTreatment.confirmIncome()
        row.gstSource = r.gstSource
        persist(row)
    }

    /// Confirm ALL unreviewed income in the window in one tap (the strip's quick-fix).
    func confirmAllIncome() {
        var changed = false
        for row in windowTxns() where row.amountCents > 0 && !(row.gstFree || row.gstSource == "manual") {
            row.gstSource = GstTreatment.confirmIncome().gstSource
            row.updatedAt = Epoch.nowMs()
            changed = true
        }
        if changed { try? context.save() }
        recompute()
    }

    /// Quick-fix an estimated expense as GST-free (zeroes GST, clears provenance).
    func fixEstimatedAsGstFree(itemId: String) {
        guard let row = txn(itemId), row.amountCents < 0 else { return }
        row.gstFree = true
        let r = GstTreatment.applyGstFree(true, totalCents: -row.amountCents)
        row.gstCents = r.gstCents; row.gstSource = r.gstSource
        persist(row)
    }

    /// Quick-fix an expense with an exact typed GST amount (manual provenance).
    func setManualGst(itemId: String, cents: Int) {
        guard let row = txn(itemId), row.amountCents < 0 else { return }
        row.gstFree = false
        let r = GstTreatment.applyManualGst(cents)
        row.gstCents = r.gstCents; row.gstSource = r.gstSource
        persist(row)
    }

    func setPaygInstalmentCents(_ cents: Int) {
        paygInstalmentCents = max(0, cents)
        store.setPaygInstalmentCents(paygInstalmentCents, profileId: profileId, periodKey: periodKey)
        recompute()
    }

    private func currentSnapshot() -> BasLocalStore.Snapshot {
        BasLocalStore.Snapshot(g1: result.g1, oneA: result.oneA, oneB: result.oneB,
                               netGst: result.netGstCents, payg: result.paygCents,
                               total: result.totalPayableCents, lodgedAtMs: lodgedAtMs ?? 0)
    }

    func markAsLodged() {
        let ms = Epoch.nowMs()
        let snap = BasLocalStore.Snapshot(g1: result.g1, oneA: result.oneA, oneB: result.oneB,
                                          netGst: result.netGstCents, payg: result.paygCents,
                                          total: result.totalPayableCents, lodgedAtMs: ms)
        store.markLodged(snap, profileId: profileId, periodKey: periodKey)
        lodgedAtMs = ms
    }

    func export(toEmail: String?) async {
        exportInProgress = true; exportError = nil
        do {
            let r = try await api.exportBas(profileId: profileId, from: fromISO, to: toISO,
                                            paygInstalmentCents: paygInstalmentCents, toEmail: toEmail)
            if case let .basPack(pdfUrl, csvUrl, _, emailed, _) = r {
                exportPdfUrl = pdfUrl; exportCsvUrl = csvUrl; exportEmailed = emailed
            }
            exportInProgress = false
        } catch let e as APIError {
            exportError = e.message; exportInProgress = false
        } catch {
            exportError = "Export failed. Try again."; exportInProgress = false
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/BasViewModelTests 2>&1 | tail -25`
Expected: PASS — including `confirmIncomeFlipsHeadline` and `estimatedQuickFix`.

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Reports/Bas/BasViewModel.swift SnapceiptTests/BasViewModelTests.swift
git commit -m "feat(bas): BasViewModel (engine + reconciliation + income-confirm + quick-fix + PAYG + lodge + export)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 15: Router `.bas` overlay case

**Files:**
- Modify: `Snapceipt/App/Router.swift` (`Overlay` enum `:11-65`)
- Test: `SnapceiptTests/RouterBasTests.swift` (Create)

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/RouterBasTests.swift`:

```swift
import Testing
@testable import Snapceipt

@MainActor
@Suite("Router .bas overlay")
struct RouterBasTests {
    @Test("presenting .bas sets the overlay with a stable id")
    func present() {
        let r = Router()
        r.present(.bas)
        #expect(r.overlay == .bas)
        #expect(r.overlay?.id == "bas")
        r.dismissOverlay()
        #expect(r.overlay == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/RouterBasTests 2>&1 | tail -20`
Expected: FAIL — `Overlay.bas` undefined.

- [ ] **Step 3: Add the case**

In `Snapceipt/App/Router.swift`, in `enum Overlay`, after the `case quotes` declaration:

```swift
    case quotes
    case bas
```

In the `id` switch, after the `case .quotes: return "quotes"` arm:

```swift
        case .quotes: return "quotes"
        case .bas: return "bas"
```

(Rely on the anchor TEXT `case .quotes: return "quotes"` — do not depend on a specific line number.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/RouterBasTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/App/Router.swift SnapceiptTests/RouterBasTests.swift
git commit -m "feat(bas): add Router .bas full-screen overlay case

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 16: BasView (full-screen overlay, with tappable reconciliation quick-fix)

**Files:**
- Create: `Snapceipt/Features/Reports/Bas/BasView.swift`

> UI-only; behavior is covered by the Task 14 VM tests and the Task 18 UI test. The automated gate here is a green compile. The reconciliation strip rows are TAPPABLE: the income row triggers `vm.confirmAllIncome()` (flipping the headline), the estimated row opens an inline GST-free quick-fix via `vm.fixEstimatedAsGstFree`. These call the same `GstTreatment`-backed VM mutations proven in Task 14.

- [ ] **Step 1: Write BasView**

Create `Snapceipt/Features/Reports/Bas/BasView.swift` (chrome mirrors `ExportSheet`/`TaxSettingsView`: `Palette.cream`, `Card`, `fmt`, `Icon`, `accent`). It owns its `BasViewModel`:

```swift
import SwiftUI
import SwiftData

/// Full-screen BAS overlay (spec §4.7). Headline (net + due; "Estimated" until income
/// reviewed) + Simpler BAS spine (G1, 1A, 1B → net 9, PAYG 5A, total) with per-label
/// Copy + a myGov caption + a collapsible full-worksheet section + a TAPPABLE
/// reconciliation strip (confirm income / fix estimated GST) + Mark-as-lodged +
/// Export. Shown only for business + gstRegistered (gated by the caller).
struct BasView: View {
    let context: ModelContext
    let api: APIClient
    let userId: String
    let profileId: String
    let profileName: String
    let gstRegistered: Bool
    let basPeriod: BasPeriod
    let startMonth: Int
    let onOpenExport: () -> Void
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: BasViewModel?
    @State private var showFullWorksheet = false
    @State private var paygText = ""

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: "BAS", onClose: onClose)
                if let vm {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            headline(vm)
                            spine(vm)
                            paygCard(vm)
                            reconcileStrip(vm)
                            fullWorksheetToggle(vm)
                            if showFullWorksheet { fullWorksheet(vm) }
                            actions(vm)
                        }
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 60)
                    }
                } else { Color.clear }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.basScreen)
        .transition(.opacity)
        .task {
            if vm == nil {
                let model = BasViewModel(context: context, api: api, store: BasLocalStore(),
                                         userId: userId, profileId: profileId,
                                         gstRegistered: gstRegistered, basPeriod: basPeriod,
                                         startMonth: startMonth, now: Epoch.now())
                paygText = model.paygInstalmentCents == 0 ? "" : fmtPlainDollars(model.paygInstalmentCents)
                vm = model
            }
        }
    }

    // MARK: Headline

    @ViewBuilder private func headline(_ vm: BasViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(vm.isHeadlineEstimated ? "Estimated" : "BAS this \(basPeriod == .quarterly ? "quarter" : "month")")
                        .font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                    Spacer()
                    periodStepper(vm)
                }
                Text(netHeadline(vm)).font(.display(30)).foregroundStyle(Palette.ink).monospacedDigit()
                Text("Due \(fmtBasDue(vm.nextDue))").font(.ui(13.5)).foregroundStyle(Palette.ink2)
                if let lodgedAtMs = vm.lodgedAtMs {
                    Text("Lodged \(fmtBasDue(Date(timeIntervalSince1970: Double(lodgedAtMs) / 1000)))")
                        .font(.ui(12.5, .semibold)).foregroundStyle(accent.base)
                    if vm.hasDrifted {
                        Text("Figures changed since you lodged — corrections belong on your next BAS as an adjustment.")
                            .font(.ui(12)).foregroundStyle(Palette.alert)
                    }
                }
            }
        }
    }

    private func netHeadline(_ vm: BasViewModel) -> String {
        let net = vm.result.netGstCents
        return net < 0 ? "ATO owes you \(fmt(-net))" : "\(fmt(net)) to pay"
    }

    // The stepper is a non-functional placeholder in v1 (Period has no prior-period
    // API; the default window is the current in-progress period). Present for a11y.
    @ViewBuilder private func periodStepper(_ vm: BasViewModel) -> some View {
        Text(vm.window.label).font(.ui(13, .semibold)).foregroundStyle(Palette.ink2)
            .accessibilityIdentifier(AccessibilityID.basPeriodStepper)
    }

    // MARK: Simpler BAS spine

    @ViewBuilder private func spine(_ vm: BasViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Lodge these on your BAS").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                copyRow("G1 Total sales", vm.result.g1, id: AccessibilityID.basCopyG1)
                copyRow("1A GST on sales", vm.result.oneA, id: AccessibilityID.basCopy1A)
                copyRow("1B GST on purchases", vm.result.oneB, id: AccessibilityID.basCopy1B)
                Divider()
                plainRow("9 Net GST", vm.result.netGstCents)
                plainRow("5A PAYG instalment", vm.result.paygCents)
                plainRow("Total", vm.result.totalPayableCents)
                Text("Type these into the matching boxes in the myGov / ATO BAS form.")
                    .font(.ui(12)).foregroundStyle(Palette.ink3)
            }
        }
    }

    private func copyRow(_ label: String, _ cents: Int, id: String) -> some View {
        HStack {
            Text(label).font(.ui(14)).foregroundStyle(Palette.ink2)
            Spacer()
            Text(fmt(cents)).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
            Button {
                UIPasteboard.general.string = String(format: "%.0f", Double(cents) / 100.0)
            } label: { Icon(name: "chart", size: 15, color: accent.base) }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
        }
    }

    private func plainRow(_ label: String, _ cents: Int) -> some View {
        HStack {
            Text(label).font(.ui(14)).foregroundStyle(Palette.ink2); Spacer()
            Text(fmt(cents)).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
        }
    }

    // MARK: PAYG

    @ViewBuilder private func paygCard(_ vm: BasViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text("PAYG instalment (5A)").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                TextField("0", text: $paygText).keyboardType(.numberPad)
                    .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: paygText) { _, v in vm.setPaygInstalmentCents((Int(v) ?? 0) * 100) }
                    .accessibilityIdentifier(AccessibilityID.basPaygField)
            }
        }
    }

    // MARK: Reconciliation strip (tappable quick-fix)

    @ViewBuilder private func reconcileStrip(_ vm: BasViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                if vm.estimatedGstCount == 0 && vm.incomeToConfirmCount == 0 && vm.printedDiscrepancyCount == 0 {
                    Text("Looks complete").font(.ui(14.5, .semibold)).foregroundStyle(accent.base)
                } else {
                    if vm.incomeToConfirmCount > 0 {
                        Button { vm.confirmAllIncome() } label: {
                            reconcileRowLabel(
                                "\(vm.incomeToConfirmCount) income entries — tap to confirm taxable",
                                cta: "Confirm")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityID.basConfirmIncome)
                    }
                    if vm.estimatedGstCount > 0 {
                        // Quick-fix: mark the first estimated expense GST-free. (A richer
                        // per-row editor lives in capture review; this is the in-strip fast path.)
                        Button {
                            if let item = vm.reconcileItems.first(where: { $0.amountCents < 0 && $0.gstSource == "derived" }) {
                                vm.fixEstimatedAsGstFree(itemId: item.id)
                            }
                        } label: {
                            reconcileRowLabel(
                                "\(vm.estimatedGstCount) purchases used estimated GST — tap to mark GST-free",
                                cta: "Fix")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityID.basReconcileRowPrefix + "estimated")
                    }
                    if vm.printedDiscrepancyCount > 0 {
                        Text("\(vm.printedDiscrepancyCount) receipts where the printed GST disagrees — check the split in the receipt")
                            .font(.ui(13.5)).foregroundStyle(Palette.ink2)
                            .accessibilityIdentifier(AccessibilityID.basReconcileRowPrefix + "printed")
                    }
                }
            }
        }
    }

    private func reconcileRowLabel(_ text: String, cta: String) -> some View {
        HStack {
            Text(text).font(.ui(13.5)).foregroundStyle(Palette.ink2).multilineTextAlignment(.leading)
            Spacer()
            Text(cta).font(.ui(13, .semibold)).foregroundStyle(accent.base)
        }
    }

    // MARK: Full worksheet (≥$10M) toggle

    @ViewBuilder private func fullWorksheetToggle(_ vm: BasViewModel) -> some View {
        Button { showFullWorksheet.toggle() } label: {
            HStack {
                Text("Full reporting method (≥$10M) — not on your Simpler BAS")
                    .font(.ui(13.5, .semibold)).foregroundStyle(accent.base)
                Spacer()
                Icon(name: "chevD", size: 14, color: accent.base)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.basFullWorksheetToggle)
    }

    @ViewBuilder private func fullWorksheet(_ vm: BasViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                plainRow("G2 Exports", vm.result.g2)
                plainRow("G3 Other GST-free sales", vm.result.g3)
                plainRow("G10 Capital purchases", vm.result.g10)
                plainRow("G11 Non-capital purchases", vm.result.g11)
                plainRow("G14 GST-free purchases", vm.result.g14)
                plainRow("G17 Total purchases subject to GST", vm.result.g17)
            }
        }
    }

    // MARK: Actions

    @ViewBuilder private func actions(_ vm: BasViewModel) -> some View {
        VStack(spacing: 10) {
            Button { vm.markAsLodged() } label: {
                Text("Mark as lodged").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                        .strokeBorder(Palette.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.basMarkLodged)

            Button { onOpenExport() } label: {
                Text("Export BAS pack").font(.ui(15.5, .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(accent.base, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.basExport)
        }
    }
}

/// Whole-dollar plain string for the PAYG field prefill (no currency symbol).
private func fmtPlainDollars(_ cents: Int) -> String { String(cents / 100) }
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `xcodebuild build -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" 2>&1 | tail -8`
Expected: `** BUILD SUCCEEDED **`. (If `fmtBasDue` or `SheetHeader` is not in scope here, confirm their definitions are app-target — they are used by `TaxSettingsView`/`BasScheduleTests`, so they are.)

- [ ] **Step 3: Commit**

```bash
git add Snapceipt/Features/Reports/Bas/BasView.swift
git commit -m "feat(bas): BasView overlay (spine + Copy + tappable reconcile quick-fix + lodge + export)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 17: Wire `.bas` overlay + the BAS-pinned ExportSheet in RootView

**Files:**
- Modify: `Snapceipt/App/RootView.swift` (`sheetBinding:509-544`, `sheetContent:546-586`, overlay block after `:260`, ExportSheet wiring `:561-576`)
- Modify: `Snapceipt/Features/Reports/ExportSheet.swift:8-32, 162-184` (BAS-pinned path — replaces the Task 11 placeholder arm)

> The Task 11 commit added a placeholder `.basPack: phase = .idle` arm to keep the app target compiling. This task replaces that placeholder with the real BAS-pinned behavior (`exportBas` + share-URL resolution) and adds the `basPinned`/`paygInstalmentCents` inputs. **PAYG periodKey fix:** the pinned export derives its BAS period and window from the SAME pref-backed value the Reports card uses (`basPeriodForActive` / `basWindowForActive`, added in Task 18) so the PAYG `periodKey` is identical to what `BasViewModel`/`BasLocalStore` persisted. Do NOT hardcode `.quarterly` here.

- [ ] **Step 1: Add a BAS-pinned mode to ExportSheet + the real pinned generate path**

In `Snapceipt/Features/Reports/ExportSheet.swift`, add a stored flag after `let onClose` (line 21):

```swift
    let onClose: () -> Void
    /// When true (launched from BasView), the format is hard-pinned to `bas`: the
    /// tiles are hidden and Generate calls exportBas (spec §4.7). Default false.
    var basPinned: Bool = false
    var paygInstalmentCents: Int = 0
```

In `body`, gate the format tiles (line 39 `formatTiles`):

```swift
                VStack(spacing: 14) {
                    if !basPinned { formatTiles }
                    detailCard
                    if format == .accountant && !basPinned { emailField }
                    cta
                    statusLine
                }
```

In `generate()`, branch on `basPinned` and replace the Task 11 placeholder `.basPack` arm with the real behavior:

```swift
    private func generate() async {
        phase = .inProgress
        do {
            if basPinned {
                let result = try await api.exportBas(profileId: profileId, from: from, to: to,
                                                     paygInstalmentCents: paygInstalmentCents, toEmail: nil)
                if case let .basPack(url, _, _, _, _) = result {
                    let full = url.hasPrefix("http") ? url : "https://api.snapceipt.cc\(url)"
                    shareURL = URL(string: full)
                }
                phase = .idle
                return
            }
            let result = try await api.export(profileId: profileId, format: format.rawValue,
                                               from: from, to: to,
                                               toEmail: format == .accountant ? email : nil)
            switch result {
            case let .download(url, _):
                let full = url.hasPrefix("http") ? url : "https://api.snapceipt.cc\(url)"
                shareURL = URL(string: full)
                phase = .idle
            case .sent:
                onSaveAccountantEmail(email)
                phase = .idle
                onClose()
            case .basPack:
                phase = .idle   // unreachable via the non-pinned export()
            }
        } catch let e as APIError {
            phase = .error(e.message)
        } catch {
            phase = .error("Export failed. Try again.")
        }
    }
```

- [ ] **Step 2: Add the `.bas` full-screen overlay block in RootView**

In `Snapceipt/App/RootView.swift`, after the `.quotes` overlay block (closes at line 260), add (deriving `basPeriod`/`startMonth` from the same helpers the Reports card uses — Task 18 adds `basPeriodForActive`):

```swift
        .overlay {
            if router.overlay == .bas {
                BasView(context: profiles.context, api: captureAPI, userId: profiles.userId,
                        profileId: profiles.activeProfileId,
                        profileName: profiles.activeProfile?.name ?? "",
                        gstRegistered: profiles.activeProfile?.gstRegistered ?? false,
                        basPeriod: basPeriodForActive,
                        startMonth: profiles.activeFinancialYearStartMonth(),
                        onOpenExport: { basExportPinned = true; router.present(.export) },
                        onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
```

Add a `@State` flag near `exportPeriod` (line 109):

```swift
    @State private var exportPeriod: Period = .month
    /// When set, the next `.export` sheet renders as the BAS-pinned pack (spec §4.7).
    @State private var basExportPinned = false
```

- [ ] **Step 3: Exclude `.bas` from the sheet binding**

In `sheetBinding` (line 513), add `.bas` to the `case` list that returns nil:

```swift
                case .capture, .mileage, .wfh, .budgets, .budgetEditor, .alerts, .notificationSettings,
                     .loyalty, .loyaltyAdd, .loyaltyCard, .quotes, .bas, .quoteEditor,
                     .emailIn, .emailInReview,
                     .tax, .categories, .ruleEditor, .profileDetail,
                     .account, .privacy, .changeEmail:
                    return nil
```

In the `fullScreen` set (line 526), add `Overlay.bas.id`:

```swift
                                               Overlay.quotes.id, Overlay.bas.id, Overlay.emailIn.id,
```

In `sheetContent`'s trailing `EmptyView` case list (line 579), add `.bas`:

```swift
        case .mileage, .wfh, .budgets, .budgetEditor, .alerts, .notificationSettings,
             .loyalty, .loyaltyAdd, .loyaltyCard, .quotes, .bas, .quoteEditor,
             .emailIn, .emailInReview,
             .tax, .categories, .ruleEditor, .profileDetail,
             .account, .privacy, .changeEmail:
            EmptyView()
```

- [ ] **Step 4: Pass the BAS-pinned flag + the CORRECT PAYG periodKey into ExportSheet**

In `sheetContent`'s `.export` case (line 561-576), pass the flag + payg (using `basWindowForActive`/`basPeriodForActive` from Task 18, NOT a hardcoded `.quarterly`/`exportPeriod`) + reset the flag on close:

```swift
        case .export:
            ExportSheet(
                api: captureAPI,
                profileId: profiles.activeProfileId,
                profileName: profiles.activeProfile?.name ?? "",
                from: exportWindow.from,
                to: exportWindow.to,
                periodLabel: exportWindow.label,
                receiptsCount: exportWindow.receiptsCount,
                deductibleCents: exportWindow.deductibleCents,
                savedAccountantEmail: exportWindow.savedAccountantEmail,
                onSaveAccountantEmail: { saveAccountantEmail($0) },
                onClose: { basExportPinned = false; router.dismissOverlay() },
                basPinned: basExportPinned,
                paygInstalmentCents: basExportPinned
                    ? BasLocalStore().paygInstalmentCents(
                        profileId: profiles.activeProfileId,
                        periodKey: BasPeriodKey.make(
                            window: basWindowForActive,
                            basPeriod: basPeriodForActive,
                            startMonth: profiles.activeFinancialYearStartMonth()))
                    : 0
            )
            .frame(maxHeight: .infinity, alignment: .bottom)
            .background(Palette.cream)
```

(`basWindowForActive`/`basPeriodForActive` are added in Task 18; since Tasks 17 and 18 both touch RootView, if the executing agent finds this task fails to compile because those helpers don't exist yet, swap the Task 17 and Task 18 ordering — both end green together. Simplest: add the two computed helpers from Task 18 Step 4 in THIS commit if they're not yet present. The periodKey MUST be built from the BAS window/period, never from `exportPeriod` or a literal `.quarterly`.)

- [ ] **Step 5: Build to confirm everything compiles**

Run: `xcodebuild build -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" 2>&1 | tail -8`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Snapceipt/App/RootView.swift Snapceipt/Features/Reports/ExportSheet.swift
git commit -m "feat(bas): wire .bas overlay + BAS-pinned ExportSheet (period-matched PAYG key)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 18: Gated Reports BAS card

**Files:**
- Modify: `Snapceipt/Features/Reports/ReportsView.swift:7-26` (add `onOpenBas` + gating inputs), `body:30-62` (card)
- Modify: `Snapceipt/App/RootView.swift` (`ReportsView(...)` callsite `:363-373` + computed helpers)
- Test: `SnapceiptTests/BasCardGateTests.swift` (Create)

- [ ] **Step 1: Write the failing test (pure gating predicate)**

Create `SnapceiptTests/BasCardGateTests.swift`:

```swift
import Testing
@testable import Snapceipt

@Suite("BAS card gate")
struct BasCardGateTests {
    @Test("card shows only for business + gstRegistered")
    func gate() {
        #expect(ReportsView.showsBasCard(profileType: "business", gstRegistered: true) == true)
        #expect(ReportsView.showsBasCard(profileType: "business", gstRegistered: false) == false)
        #expect(ReportsView.showsBasCard(profileType: "personal", gstRegistered: true) == false)
        #expect(ReportsView.showsBasCard(profileType: "personal", gstRegistered: false) == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/BasCardGateTests 2>&1 | tail -20`
Expected: FAIL — `ReportsView.showsBasCard` undefined.

- [ ] **Step 3: Add the gating predicate + card inputs to ReportsView**

In `Snapceipt/Features/Reports/ReportsView.swift`, add to the property block (after line 15 `onOpenWFH`):

```swift
    let onOpenWFH: () -> Void
    /// Business + gstRegistered identity (drives the BAS card gate, spec §4.8).
    let profileType: String
    let gstRegistered: Bool
    let basDue: Date
    let basNetCents: Int
    let basLodged: Bool
    let onOpenBas: () -> Void
```

Add the static gate (after line 25, before `var body`):

```swift
    /// The BAS card is reachable ONLY for a GST-registered Business profile (spec §4.8).
    static func showsBasCard(profileType: String, gstRegistered: Bool) -> Bool {
        profileType == "business" && gstRegistered
    }
```

In `body`, render the card at the TOP of the stack (after `header`, before `Segmented`, line 33-34):

```swift
                        header
                        if Self.showsBasCard(profileType: profileType, gstRegistered: gstRegistered) {
                            basCard
                        }
                        Segmented(options: periodOptions, selection: $periodSelection)
```

Add the card view (after the `header` computed property, line 79):

```swift
    private var basCard: some View {
        Button { onOpenBas() } label: {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("BAS · this quarter").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                        Spacer()
                        Text(basLodged ? "Lodged" : "Review").font(.ui(12.5, .semibold)).foregroundStyle(accent.base)
                    }
                    Text(basNetCents < 0 ? "ATO owes you \(fmt(-basNetCents))" : "\(fmt(basNetCents)) to pay")
                        .font(.display(24)).foregroundStyle(Palette.ink).monospacedDigit()
                    HStack {
                        Text("Due \(fmtBasDue(basDue))").font(.ui(13)).foregroundStyle(Palette.ink2)
                        Spacer()
                        Text("Review ›").font(.ui(13, .semibold)).foregroundStyle(accent.base)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.reportsBasCard)
    }
```

- [ ] **Step 4: Pass the inputs from RootView + add the shared BAS-period/window helpers**

In `Snapceipt/App/RootView.swift`, in the `ReportsView(...)` callsite (line 363-372), add the new arguments:

```swift
        case .reports:
            ReportsView(
                context: profiles.context,
                userId: profiles.userId,
                profileId: profiles.activeProfileId,
                profileName: profiles.activeProfile?.name ?? "",
                startMonth: profiles.activeFinancialYearStartMonth(),
                onOpenExport: { period in exportPeriod = period; router.present(.export) },
                onOpenMileage: { router.present(.mileage) },
                onOpenWFH: { router.present(.wfh) },
                profileType: profiles.activeProfile?.type ?? "personal",
                gstRegistered: profiles.activeProfile?.gstRegistered ?? false,
                basDue: BasSchedule.nextDue(basPeriodForActive, on: Epoch.now()),
                basNetCents: basNetCentsForActive,
                basLodged: basLodgedForActive,
                onOpenBas: { router.present(.bas) }
            )
            .environment(\.accent, accent)
```

Add the shared computed helpers near `exportWindow` (after line 655). These are the SINGLE source of the active profile's BAS period/window, reused by Task 17's pinned-export PAYG key:

```swift
    /// The active profile's BAS period (local pref; defaults quarterly).
    private var basPeriodForActive: BasPeriod {
        BasPeriod(rawValue: UserDefaults.standard
            .string(forKey: "sc.tax.\(profiles.activeProfileId).basPeriod") ?? "") ?? .quarterly
    }

    /// The active profile's BAS window (current in-progress period).
    private var basWindowForActive: Period.Window {
        let p: Period = (basPeriodForActive == .quarterly) ? .quarter : .month
        return p.window(now: Epoch.now(), startMonth: profiles.activeFinancialYearStartMonth())
    }

    /// Net GST cents for the Reports BAS card (one engine pass over the in-window txns).
    private var basNetCentsForActive: Int {
        guard profiles.activeProfile?.type == "business",
              profiles.activeProfile?.gstRegistered == true else { return 0 }
        let pid = profiles.activeProfileId
        let rows = (try? profiles.context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil }))) ?? []
        let iso = ExportDateFormatter.shared
        let w = basWindowForActive
        let txns = rows.filter { iso.date(from: $0.txnDate).map { $0 >= w.start && $0 < w.end } ?? false }
            .map { BasEngine.Txn(amountCents: $0.amountCents, gstFree: $0.gstFree,
                                 capital: $0.capital, txnDate: $0.txnDate) }
        let payg = BasLocalStore().paygInstalmentCents(
            profileId: pid,
            periodKey: BasPeriodKey.make(window: w, basPeriod: basPeriodForActive,
                                         startMonth: profiles.activeFinancialYearStartMonth()))
        return BasEngine.compute(txns: txns, gstRegistered: true,
                                 manual: BasEngine.Manual(paygInstalmentCents: payg)).netGstCents
    }

    /// Whether the active profile's current BAS period has a lodged snapshot.
    private var basLodgedForActive: Bool {
        let w = basWindowForActive
        let key = BasPeriodKey.make(window: w, basPeriod: basPeriodForActive,
                                    startMonth: profiles.activeFinancialYearStartMonth())
        return BasLocalStore().lodgedSnapshot(profileId: profiles.activeProfileId, periodKey: key) != nil
    }
```

- [ ] **Step 5: Run the gate test + build**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/BasCardGateTests 2>&1 | tail -8 && xcodebuild build -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" 2>&1 | tail -5`
Expected: gate test PASS, then `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Snapceipt/Features/Reports/ReportsView.swift Snapceipt/App/RootView.swift SnapceiptTests/BasCardGateTests.swift
git commit -m "feat(bas): gated Reports BAS card (business + gstRegistered only)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 19: Hermetic BAS UI test + seeded fixture (incl. fix-item → headline flips)

**Files:**
- Modify: `Snapceipt/App/AppLaunch.swift` (add a `-uiTestBasSeed` GST-registered business fixture)
- Modify: `SnapceiptUITests/UITestCase.swift` (add `launchBasSeed()`)
- Create: `SnapceiptUITests/BasUITests.swift`

> Covers the spec §7 iOS UI-test step "fix a reconciliation item → headline flips from Estimated to firm": the seed leaves income UNCONFIRMED (`gstSource == "derived"`) so the headline reads "Estimated"; tapping the confirm-income quick-fix (`basConfirmIncome`) flips it to firm. The test asserts the "Estimated" label disappears after the fix.

- [ ] **Step 1: Add the BAS seed fixture flag + builder in AppLaunch**

In `Snapceipt/App/AppLaunch.swift`, near the other launch-arg flags (around line 44-47), add:

```swift
        basSeed = arguments.contains("-uiTestBasSeed")
```

Add the stored property next to `seed`/`tour` (match their declaration style):

```swift
    let basSeed: Bool
```

Add a builder method (mirrors `applySeedIfNeeded` — clone the seed body but make `p1` GST-registered and add a capital + GST-free txn so the BAS card + reconciliation render). Income is left UNCONFIRMED so the headline starts "Estimated". Place it after the existing seed method:

```swift
    /// BAS fixture: a GST-registered Business profile p1 with the canonical scenario
    /// (income left unconfirmed → headline "Estimated") + a NON-registered business p2
    /// to verify the card is hidden. Under -uiTestBasSeed.
    func applyBasSeedIfNeeded(authStore: AuthStore, context: ModelContext) {
        guard basSeed else { return }
        authStore.save(SessionResponse(
            accessToken: "basseed-access", refreshToken: "basseed-refresh", expiresIn: 900,
            user: SessionUser(id: DevAccount.userId, email: DevAccount.email, displayName: "Dev")))
        let p1 = Profile(userId: DevAccount.userId, name: "Studio North", type: "business",
                         initials: "SN", accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950",
                         gstRegistered: true, sortOrder: 0, isDefault: true)
        let p2 = Profile(userId: DevAccount.userId, name: "Side Hustle", type: "business",
                         initials: "SH", accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A",
                         gstRegistered: false, sortOrder: 1, isDefault: false)
        context.insert(p1); context.insert(p2)
        let cal: Calendar = {
            var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
        }()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let iso: DateFormatter = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"; return f
        }()
        func day(_ d: Int) -> String { iso.string(from: cal.date(byAdding: .day, value: d, to: monthStart)!) }
        // Income (unconfirmed → headline reads "Estimated" until reviewed).
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, catKey: "income",
                                   amountCents: 1_100_000, txnDate: day(1), gstSource: "derived"))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "Officeworks",
                                   catKey: "office", amountCents: -110_000, txnDate: day(2), gstSource: "derived"))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "Apple",
                                   catKey: "software", amountCents: -220_000, txnDate: day(3),
                                   capital: true, gstSource: "derived"))
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "Woolworths",
                                   catKey: "groceries", amountCents: -33_000, txnDate: day(4),
                                   gstFree: true, gstSource: nil))
    }
```

Wire `applyBasSeedIfNeeded(...)` into the same launch path where `applySeedIfNeeded`/`applyTourSeedIfNeeded` are invoked (grep `applySeedIfNeeded(` and add the BAS call alongside it).

- [ ] **Step 2: Add the launch helper to UITestCase**

In `SnapceiptUITests/UITestCase.swift`, after `launchSeeded()` (line 32):

```swift
    /// Launch directly into the BAS fixture: a GST-registered Business profile p1
    /// active + a non-registered Business p2 — for BasUITests.
    func launchBasSeed() {
        app.launchArguments += ["-uiTestStub", "-uiTestBasSeed"]
        app.launch()
    }
```

- [ ] **Step 3: Write the UI test (incl. confirm-income → headline flips)**

Create `SnapceiptUITests/BasUITests.swift`:

```swift
import XCTest

final class BasUITests: UITestCase {
    @MainActor func test_basCardOpensBasViewFixesIncomeAndLodges() {
        launchBasSeed()
        app.buttons[AccessibilityID.tabReports].tap()
        let card = app.descendants(matching: .any)[AccessibilityID.reportsBasCard]
        XCTAssertTrue(card.waitForExistence(timeout: 8), "BAS card missing for registered business")
        card.tap()
        // BasView spine.
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.basScreen].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.basCopy1A].waitForExistence(timeout: 4),
                      "1A copy control missing")

        // Headline starts "Estimated" (income unconfirmed).
        XCTAssertTrue(app.staticTexts["Estimated"].waitForExistence(timeout: 4),
                      "headline should start Estimated with unconfirmed income")
        // Fix the reconciliation item: confirm income → headline flips to firm.
        let confirm = app.descendants(matching: .any)[AccessibilityID.basConfirmIncome]
        XCTAssertTrue(confirm.waitForExistence(timeout: 4), "confirm-income quick-fix missing")
        confirm.tap()
        // "Estimated" label is gone once income is reviewed.
        let stillEstimated = app.staticTexts["Estimated"]
        XCTAssertFalse(stillEstimated.waitForExistence(timeout: 3),
                       "headline must flip from Estimated to firm after confirming income")

        // Copy 1A (no crash; pasteboard write is best-effort under test).
        app.descendants(matching: .any)[AccessibilityID.basCopy1A].tap()
        // Mark-as-lodged.
        app.descendants(matching: .any)[AccessibilityID.basMarkLodged].tap()
        // Export button exists.
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.basExport].waitForExistence(timeout: 4))
    }

    @MainActor func test_nonRegisteredProfileHidesBasCard() {
        launchBasSeed()
        app.buttons[AccessibilityID.tabHome].tap()
        app.descendants(matching: .any)[AccessibilityID.profileSwitcher].tap()
        let p2 = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", AccessibilityID.profileSwitcherCardPrefix)).element(boundBy: 1)
        if p2.waitForExistence(timeout: 6) { p2.tap() }
        app.buttons[AccessibilityID.tabReports].tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.reportsScreen].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)[AccessibilityID.reportsBasCard].exists,
                       "BAS card must be hidden for a non-registered profile")
    }
}
```

- [ ] **Step 4: Regenerate the project, then run the UI tests**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptUITests/BasUITests 2>&1 | tail -25`
Expected: both `BasUITests` methods PASS, including the headline flip. (If the "Estimated" `staticText` match is brittle because the label is composed differently, assert via an a11y label/value on the headline instead — but the load-bearing assertion is that the income-confirm tap clears the estimated state. If the profile-switcher selection in test 2 is flaky, fall back to asserting only `reportsBasCard` absence on whichever profile is active after the switch.)

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/App/AppLaunch.swift SnapceiptUITests/UITestCase.swift SnapceiptUITests/BasUITests.swift
git commit -m "test(bas): hermetic BAS journey (confirm income -> headline flips) + non-registered hides card

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 20: Screenshot-tour BAS area

**Files:**
- Modify: `SnapceiptUITests/ScreenshotTourUITests.swift` (add `test_area14_bas`)

- [ ] **Step 1: Add the tour method**

In `SnapceiptUITests/ScreenshotTourUITests.swift`, add a new method after the last existing `test_areaNN_*` method (use `launchBasSeed()` rather than the rich tour fixture, since the tour fixture's p1 is NOT GST-registered):

```swift
    // Area 14 — BAS. Uses the -uiTestBasSeed fixture (GST-registered business p1)
    // so the gated card + BasView render. Shoots the card, the spine, and the
    // post-lodge state.
    @MainActor func test_area14_bas() {
        launchBasSeed()
        require(app.buttons[AccessibilityID.tabReports], "tab.reports")
        app.buttons[AccessibilityID.tabReports].tap()
        require(app.descendants(matching: .any)[AccessibilityID.reportsBasCard], "reports.bas.card")
        shoot(app, "bas-card-needsreview")
        app.descendants(matching: .any)[AccessibilityID.reportsBasCard].tap()
        require(app.descendants(matching: .any)[AccessibilityID.basScreen], "bas.screen")
        shoot(app, "bas-screen-estimated")
        app.descendants(matching: .any)[AccessibilityID.basMarkLodged].tap()
        shoot(app, "bas-screen-lodged")
    }
```

- [ ] **Step 2: Run the tour method**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptUITests/ScreenshotTourUITests/test_area14_bas 2>&1 | tail -15`
Expected: `test_area14_bas` PASS (3 attachments captured).

- [ ] **Step 3: Commit**

```bash
git add SnapceiptUITests/ScreenshotTourUITests.swift
git commit -m "test(bas): screenshot-tour BAS area (card / estimated / lodged)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 21: Full green test run + final commit

**Files:** none (verification only)

- [ ] **Step 1: Run the FULL unit + UI test suite on the iPhone 16 simulator**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" 2>&1 | tail -40`
Expected: `** TEST SUCCEEDED **`. Confirm the pass count is ≥ the baseline (~408 pass / 7 skip on `main` before this feature, plus the new BAS tests) with no new failures. Pay particular attention that `FixtureBundlingTests` and `BasEngineTests/goldenVectors` are both green (the resource-bundling keystone). If any test fails, fix it before proceeding (do NOT skip).

- [ ] **Step 2: Confirm no placeholder strings leaked into shipped code**

Run: `grep -rn "TODO\|FIXME\|TBD" Snapceipt/Features/Reports/Bas Snapceipt/Features/Settings/ABNValidator.swift 2>/dev/null; echo "exit:$?"`
Expected: no matches (`exit:1` from grep means nothing found).

- [ ] **Step 3: Confirm the Task 11 ExportSheet placeholder was actually replaced**

Run: `grep -n "basPinned\|unreachable via the non-pinned" Snapceipt/Features/Reports/ExportSheet.swift; echo "exit:$?"`
Expected: matches showing the real BAS-pinned path exists (Task 17 replaced the Task 11 `case .basPack: phase = .idle` placeholder). If the only `.basPack` arm is still the bare `phase = .idle` placeholder with no `basPinned` branch, Task 17 did not land — fix before shipping.

- [ ] **Step 4: Final verification commit (only if Step 1 produced uncommitted formatting/fixups)**

If the working tree is clean after Tasks 1-20, skip this step. Otherwise:

```bash
git add -A
git commit -m "chore(bas): finalize BAS-ready export iOS feature — full suite green

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage (§4 iOS):**
- §4.1 schema columns → Tasks 2-3. `SYNCABLE_TYPES`/15-model count untouched (columns only; `SnapceiptSchema.models` unchanged). ✓
- §4.2 seeding + backfill → Task 4 (`groceries=true`; health/meals taxable; `backfillGstDefaults` distinct from insert-only `ensure`). ✓
- §4.3 engine + golden vectors → Tasks 1, 6 (resource bundling proven by `FixtureBundlingTests` BEFORE the engine relies on it; canonical numbers asserted; non-registered/refund/empty/monthly/capital/PAYG covered; identical fixture; fail-soft load). ✓
- §4.3 authority rule → Task 5 (`GstTreatment`, incl. `confirmIncome`). ✓
- §4.4 export DTO/result/conformers → Task 11 (`BasExportResponse`, `BasEcho`, `.basPack`, all 4 conformers + Mock recording + ExportSheet switch arm in the SAME commit so the app target keeps compiling). ✓
- §4.6 ABN modulus-89 + hint → Task 10; reconciliation → Task 7; periodKey → Task 8; BasLocalStore PAYG + lodged snapshot/diff → Task 9; **editable per-txn GST controls (gstFree/capital/typed-amount) wired into capture ReviewStep → Task 12**; **reconciliation quick-fix + income-confirm wired into BasViewModel + BasView → Tasks 14, 16**; editable GST provenance on capture → Task 12. ✓
- §4.7 Router `.bas` + BasView + Reports card + pinned ExportSheet (period-matched PAYG key) → Tasks 15-18. ✓
- §4.8 gating (business + gstRegistered) → Task 18 (`showsBasCard` + UI test) + RootView overlay reads `gstRegistered`. ✓
- §4.6 AccessibilityIDs → Task 13. ✓
- §7 iOS tests (Swift Testing) + UI + screenshot tour, INCLUDING "fix a reconciliation item → headline flips from Estimated to firm" → Tasks 2-20 (the flip is asserted in Task 19's `test_basCardOpensBasViewFixesIncomeAndLodges` and covered at the VM layer by `BasViewModelTests.confirmIncomeFlipsHeadline`). ✓

**Resolved review findings:**
- **BLOCKER (Task 11/17 ordering):** Task 11 Step 3 now adds the `case .basPack: phase = .idle` arm to `ExportSheet.generate()` IN THE SAME COMMIT as the enum case, so the app target stays compilable; Task 11 Step 8's `xcodebuild test` builds green. Task 17 replaces the placeholder with the real pinned path; Task 21 Step 3 verifies the replacement landed. ✓
- **MAJOR (editable GST controls + reconciliation quick-fix never wired):** new Task 12 surfaces `txnGstFreeToggle`/`txnCapitalToggle`/`txnGstAmountField` in the capture `ReviewStep` (the only txn-editing surface, verified) through `GstTreatment`; Task 14's `BasViewModel` adds `confirmIncome`/`confirmAllIncome`/`fixEstimatedAsGstFree`/`setManualGst`; Task 16's `BasView` reconcile rows are tappable into those mutations; Task 19 extends the UI test to fix an item and assert the headline flips. ✓
- **MAJOR (incomeConfirmed permanently "Estimated"):** an explicit income-reviewed signal (`gstSource = "manual"` via `GstTreatment.confirmIncome`) plus the `confirmAllIncome` affordance makes `incomeToConfirmCount` reach 0; `recompute()` maps `incomeConfirmed` from exactly that signal; covered by `BasViewModelTests.confirmIncomeFlipsHeadline` and the UI test. ✓
- **MAJOR (golden-fixture bundling unverified):** Task 1 adds an explicit `resources:` stanza to the `SnapceiptTests` target in `project.yml`, builds + runs `FixtureBundlingTests` as a keystone gate, and both the smoke test and `BasEngineTests.goldenVectors` fail SOFT via `Issue.record` (no force-unwrap). ✓
- **MINOR (Task 15 line numbers):** the Router edits now rely on anchor TEXT (`case .quotes: return "quotes"`) with no cited line numbers. ✓
- **MINOR (Task 3 gstSource null):** documented as intentionally non-propagating in v1 (matches the nullable-string convention) in the Task 3 header + inline comment. ✓
- **MINOR (Task 17 hardcoded .quarterly PAYG key):** the pinned export now derives period + window from `basPeriodForActive`/`basWindowForActive` (the same pref-backed helpers Task 18 uses), so the PAYG `periodKey` matches what `BasViewModel`/`BasLocalStore` persisted. ✓

**Type consistency:** `BasEngine.Result`/`Txn`/`Manual`, `BasReconciliation.Item`, `BasLocalStore.Snapshot`, `GstTreatment.Result`, `BasExportResponse`/`BasEcho`/`ExportResult.basPack`, `exportBas(profileId:from:to:paygInstalmentCents:toEmail:)`, `GoldenAnchor` (defined once in `FixtureBundlingTests.swift`, reused by `BasEngineTests`), `AccessibilityID.basCopy1A`/`basConfirmIncome`/`txn*` — all defined once and referenced consistently. `fmtBasDue`, `SheetHeader`, `Card`, `fmt`, `Epoch.now/nowMs`, `Period.Window`, `BasSchedule.nextDue`, `ExportDateFormatter.shared`, `field(_:_:)` in ReviewStep are pre-existing (verified).

**Execution notes:**
- Tasks 17 and 18 both touch `RootView.swift` and share the `basPeriodForActive`/`basWindowForActive` helpers. If executed in number order, add those two computed helpers in whichever task lands first (Task 17 Step 4 calls this out); both end green together. The load-bearing invariant: the pinned-export PAYG `periodKey` is built from the BAS window/period, never from `exportPeriod` or a literal.
- Each task ends green (failing test → minimal impl → passing test → commit) and the app target compiles at every commit, including the Task 11 enum-case introduction (placeholder switch arm) — the previously broken ordering is fixed.
