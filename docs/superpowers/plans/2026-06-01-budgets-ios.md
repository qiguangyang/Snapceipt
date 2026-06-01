# Budgets + Push (APNs) — iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Ship the iOS half of F3 — real monthly-budget CRUD, a Home budget tracker card, a data-bound AlertsSheet (derived feed + local read/dismiss cache), APNs token registration via `PUT /devices/me`, a Notifications settings screen (push toggle + quiet hours + BAS placeholder), the deep-link routing for tapped pushes, and the now-enabled F2 Personal under-budget card — all keeping the suite green.

**Architecture:** Budget spend is a PURE function (`BudgetSpend.spent`) with an injected `now`/`monthKey` (no hidden `Date()`/`Calendar.current`), mirroring §4.3 exactly so it matches the backend math. Budget CRUD goes through the existing local-first `SyncEngine.enqueue` (no new sync routes); the alert feed is derived on-device from `Budget.alertSentAt` + live spend with a UserDefaults read/dismiss cache (§4.7). APNs registration rides a `NotificationDelegate` (`UNUserNotificationCenterDelegate`) wired via `@UIApplicationDelegateAdaptor`, persisting the hex token + IANA timezone + quiet-hours through a new `APIClient.updateDevice` (`PUT /devices/me`). Views are exercised by one hermetic XCUITest; all logic by Swift Testing unit tests.

**Tech Stack:** Swift 5.10, SwiftUI, SwiftData, Swift Testing (`@Test`/`#expect`), XCUITest; xcodegen-generated `Snapceipt.xcodeproj` (git-ignored); `xcodebuild` on the iPhone 16 simulator.

---

## File structure

**Created:**
- `Snapceipt/Features/Budgets/BudgetSpend.swift` — pure spend math (§4.3): `spent(budget:txns:monthKey:)` + `monthKey(for:)` helper.
- `Snapceipt/Features/Budgets/BudgetListViewModel.swift` — `@MainActor @Observable` CRUD view-model (load/create/update/delete + spend rows + enqueue).
- `Snapceipt/Features/Budgets/BudgetTrackerView.swift` — Home tracker card body (top-3 budgets, `BudgetRow`, Edit link, empty state).
- `Snapceipt/Features/Budgets/BudgetListView.swift` — full-screen budgets list overlay (rows, Add CTA, swipe-delete, empty state).
- `Snapceipt/Features/Budgets/BudgetEditorView.swift` — full-screen add/edit overlay (scope picker, cap, threshold, Save/Delete).
- `Snapceipt/Features/Alerts/AlertFeed.swift` — pure feed derivation (§4.7) + `AlertCache` (UserDefaults read/dismiss).
- `Snapceipt/Features/Alerts/AlertsViewModel.swift` — `@MainActor @Observable` feed view-model (derive + read/dismiss).
- `Snapceipt/Features/Alerts/AlertsSheet.swift` — full-screen alerts overlay (rows, tap→deep-link+read, swipe→dismiss, empty state).
- `Snapceipt/Features/Notifications/NotificationDelegate.swift` — `UNUserNotificationCenterDelegate` + `UIApplicationDelegate` (token register/persist, tap deep-link, foreground banner).
- `Snapceipt/Features/Notifications/QuietHours.swift` — pure quiet-hours encode helpers (minutes↔Date) + the `PUT /devices/me` payload builder.
- `Snapceipt/Features/Notifications/NotificationsSettingsView.swift` — settings screen (permission prime, push toggle, quiet hours, BAS placeholder).
- `Snapceipt/Features/Notifications/NotificationsSettingsViewModel.swift` — `@MainActor @Observable` settings VM (push_enabled + quiet-hours persistence + `updateDevice` calls).
- `Snapceipt/Features/Profiles/ProfileTabView.swift` — lightweight Profile-tab list with the two F3 entry rows.
- `SnapceiptTests/BudgetSpendTests.swift`, `SnapceiptTests/BudgetListViewModelTests.swift`, `SnapceiptTests/AlertFeedTests.swift`, `SnapceiptTests/QuietHoursTests.swift`, `SnapceiptTests/DeepLinkRoutingTests.swift`, `SnapceiptTests/UpdateDevicePayloadTests.swift` — unit suites.
- `SnapceiptUITests/BudgetsUITests.swift` — hermetic UI test (tracker → add/edit → AlertsSheet dismiss → notifications toggle + quiet-hours picker).

**Modified:**
- `Snapceipt/Sync/DTOs.swift` — add `UpdateDeviceBody` + `UpdateDeviceResponse` DTOs.
- `Snapceipt/Sync/APIClient.swift` — add `updateDevice(...)` to the protocol + `LiveAPIClient` (`PUT /devices/me`); add a private `sendNoQuery` reuse where needed.
- `Snapceipt/Sync/StubAPIClient.swift` — conform `updateDevice`.
- `Snapceipt/Features/Auth/SignInView.swift` (PreviewAPIClient) — conform `updateDevice`.
- `SnapceiptTests/Mocks/MockAPIClient.swift` — conform `updateDevice` + record calls.
- `Snapceipt/App/Router.swift` — add `.budgets`, `.budgetEditor(id:)`, `.alerts`, `.notificationSettings` overlay cases + `openBudget(_:)` + `parseBudgetDeepLink`/`handleBudgetDeepLink` (the tapped-push deep link routes straight through `openBudget`, so NO `pendingDeepLinkBudgetId` field is needed — the budget id rides in the `.budgetEditor(id:)` case itself).
- `Snapceipt/App/RootView.swift` — replace `homeStub` body with the tracker + bell header; wire the 4 new full-screen overlays; route `.profile` to `ProfileTabView`; deep-link handler.
- `Snapceipt/App/SnapceiptApp.swift` — add `@UIApplicationDelegateAdaptor(NotificationDelegate.self)` + inject the Router/API/auth into it; `onOpenURL` routes `snapceipt://budget/<id>`.
- `Snapceipt/Features/Reports/ReportsViewModel.swift` — compute `underBudget` (Σspent/Σcap for Personal-with-budgets, current month).
- `Snapceipt/Features/Reports/ReportsView.swift` — render the under-budget card (Personal only, when `underBudget != nil`).
- `Snapceipt/Shared/AccessibilityID.swift` — add the F3 identifiers.
- `Snapceipt/Info.plist` — add `UIBackgroundModes` → `remote-notification`.

---

### Task 1: Pure budget-spend math (`BudgetSpend`)

The authoritative §4.3 math: `spent_cents = SUM(magnitude of expenses)` where expense = `amountCents < 0`, scoped to the budget's target month (`YYYY-MM` prefix of `txnDate`) and category (`categoryId == nil` → all categories, else equal). Target month = current calendar month (UTC) when `budget.monthKey == nil`, else `budget.monthKey`. Mirror `TransactionQuery.Txn` field names exactly: a `Txn` here carries `txnDate`, `amountCents`, `categoryId`.

**Files:**
- Create: `Snapceipt/Features/Budgets/BudgetSpend.swift`
- Test: `SnapceiptTests/BudgetSpendTests.swift`

- [ ] **Step 1: Write the failing test.**

Create `SnapceiptTests/BudgetSpendTests.swift`:
```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("BudgetSpend")
struct BudgetSpendTests {
    private func iso(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    private let txns: [BudgetSpend.Txn] = [
        // June 2026
        .init(txnDate: "2026-06-02", amountCents: -120_00, categoryId: "cat-meals"),
        .init(txnDate: "2026-06-05", amountCents: -80_00,  categoryId: "cat-fuel"),
        .init(txnDate: "2026-06-06", amountCents:  500_00, categoryId: "cat-income"), // income excluded
        // May 2026 (other month — excluded for June target)
        .init(txnDate: "2026-05-30", amountCents: -999_00, categoryId: "cat-meals"),
    ]

    @Test("monthKey is the YYYY-MM of an injected now (UTC)")
    func monthKeyOfNow() {
        #expect(BudgetSpend.monthKey(for: iso("2026-06-15")) == "2026-06")
        #expect(BudgetSpend.monthKey(for: iso("2026-01-01")) == "2026-01")
    }

    @Test("whole-profile budget sums every expense in the target month")
    func wholeProfile() {
        let b = Budget(userId: "u1", profileId: "p1", categoryId: nil,
                       label: "Everything", capCents: 600_00)
        #expect(BudgetSpend.spent(budget: b, txns: txns, now: iso("2026-06-15")) == 200_00) // 120 + 80
    }

    @Test("per-category budget only sums that category in the target month")
    func perCategory() {
        let b = Budget(userId: "u1", profileId: "p1", categoryId: "cat-meals",
                       label: "Meals", capCents: 200_00)
        #expect(BudgetSpend.spent(budget: b, txns: txns, now: iso("2026-06-15")) == 120_00)
    }

    @Test("a fixed monthKey overrides the injected now")
    func fixedMonthKey() {
        let b = Budget(userId: "u1", profileId: "p1", categoryId: "cat-meals",
                       label: "Meals", capCents: 200_00, monthKey: "2026-05")
        #expect(BudgetSpend.spent(budget: b, txns: txns, now: iso("2026-06-15")) == 999_00)
    }

    @Test("over-cap detection compares spent to cap (strictly greater)")
    func overCap() {
        let b = Budget(userId: "u1", profileId: "p1", categoryId: nil,
                       label: "Tiny", capCents: 100_00)
        let s = BudgetSpend.spent(budget: b, txns: txns, now: iso("2026-06-15")) // 200_00
        #expect(s > b.capCents)
    }
}
```

- [ ] **Step 2: Run it — expect FAIL (no such type `BudgetSpend`).**
```
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/BudgetSpendTests test 2>&1 | tail -20
```
Expected: compile failure `cannot find 'BudgetSpend' in scope`.

- [ ] **Step 3: Write the minimal implementation.**

Create `Snapceipt/Features/Budgets/BudgetSpend.swift`:
```swift
import Foundation

/// Pure, SwiftData-free budget-spend math. Mirrors the backend §4.3 contract EXACTLY
/// so on-device and server numbers agree: spent = Σ magnitude of expenses
/// (amountCents < 0) in the budget's target month, scoped to its category (nil = all).
/// `now` is INJECTED (no hidden Date()/Calendar.current) — that class of bug bit capture.
enum BudgetSpend {
    /// A minimal transaction snapshot for budget aggregation. `categoryId` matches the
    /// Transaction column the budget links by (Budget.categoryId), NOT the catKey.
    struct Txn: Equatable {
        let txnDate: String        // "yyyy-MM-dd"
        let amountCents: Int       // signed; expense < 0
        let categoryId: String?
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// "YYYY-MM" of `now` in UTC (the recurring-budget target month).
    static func monthKey(for now: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month], from: now)
        return String(format: "%04d-%02d", c.year!, c.month!)
    }

    /// Spent cents for `budget` over `txns`. Target month = `budget.monthKey` when set,
    /// else the current calendar month (UTC) of `now`.
    static func spent(budget: Budget, txns: [Txn], now: Date) -> Int {
        let target = budget.monthKey ?? monthKey(for: now)
        var total = 0
        for t in txns where t.amountCents < 0 {
            guard t.txnDate.hasPrefix(target) else { continue }       // substr(txnDate,1,7) == target
            if let cat = budget.categoryId, t.categoryId != cat { continue }
            total += -t.amountCents
        }
        return total
    }
}
```

- [ ] **Step 4: Run it — expect PASS.**
```
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/BudgetSpendTests test 2>&1 | tail -20
```
Expected: `Test Suite 'BudgetSpend' passed` (5 tests).

- [ ] **Step 5: Commit.**
```
git add Snapceipt/Features/Budgets/BudgetSpend.swift SnapceiptTests/BudgetSpendTests.swift
git commit -m "F3 iOS: pure BudgetSpend math (§4.3) + tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `updateDevice` on APIClient + all conformers (`PUT /devices/me`)

Add the device-update call (§4.2) following the EXACT `LiveAPIClient.send` pattern (verified: `send<T:Decodable,B:Encodable>(_ method:_ path:query:body:authenticated:)`). The route is keyed by `X-Device-Id` (already attached by `makeRequest`) + bearer; body fields are all optional. `DeviceDTO` already exists; we add `UpdateDeviceBody` + `UpdateDeviceResponse`.

**Files:**
- Modify: `Snapceipt/Sync/DTOs.swift` (after line 108, end of `DeviceDTO`)
- Modify: `Snapceipt/Sync/APIClient.swift` (protocol after line 22; `LiveAPIClient` after line 127)
- Modify: `Snapceipt/Sync/StubAPIClient.swift` (after line 55)
- Modify: `Snapceipt/Features/Auth/SignInView.swift` (PreviewAPIClient, after line 185)
- Modify: `SnapceiptTests/Mocks/MockAPIClient.swift` (after line 113)
- Test: `SnapceiptTests/UpdateDevicePayloadTests.swift`

- [ ] **Step 1: Write the failing test.**

Create `SnapceiptTests/UpdateDevicePayloadTests.swift`:
```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("UpdateDevice payload")
struct UpdateDevicePayloadTests {
    @Test("UpdateDeviceBody encodes only the provided optional fields (camelCase)")
    func encodesProvidedFields() throws {
        let body = UpdateDeviceBody(apnsToken: "deadbeef", quietHoursStartMin: 1320,
                                    quietHoursEndMin: 420, timezone: "Australia/Sydney",
                                    pushEnabled: true)
        let data = try JSONEncoder().encode(body)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["apnsToken"] as? String == "deadbeef")
        #expect(obj["quietHoursStartMin"] as? Int == 1320)
        #expect(obj["quietHoursEndMin"] as? Int == 420)
        #expect(obj["timezone"] as? String == "Australia/Sydney")
        #expect(obj["pushEnabled"] as? Bool == true)
    }

    @Test("nil optionals are omitted from the JSON")
    func omitsNils() throws {
        let body = UpdateDeviceBody(apnsToken: nil, quietHoursStartMin: nil,
                                    quietHoursEndMin: nil, timezone: "Australia/Perth",
                                    pushEnabled: nil)
        let data = try JSONEncoder().encode(body)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["timezone"] as? String == "Australia/Perth")
        #expect(obj["apnsToken"] == nil)
        #expect(obj["pushEnabled"] == nil)
    }

    @Test("MockAPIClient records the updateDevice call")
    func mockRecords() async throws {
        let mock = MockAPIClient()
        mock.updateDeviceHandler = { _ in UpdateDeviceResponse(id: "dev-1") }
        _ = try await mock.updateDevice(UpdateDeviceBody(
            apnsToken: "abc", quietHoursStartMin: nil, quietHoursEndMin: nil,
            timezone: "Australia/Sydney", pushEnabled: false))
        #expect(mock.updateDeviceCalls.count == 1)
        #expect(mock.updateDeviceCalls[0].apnsToken == "abc")
        #expect(mock.updateDeviceCalls[0].pushEnabled == false)
    }
}
```

- [ ] **Step 2: Run it — expect FAIL (`cannot find 'UpdateDeviceBody'`).**
```
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/UpdateDevicePayloadTests test 2>&1 | tail -20
```
Expected: compile failure.

- [ ] **Step 3: Add the DTOs.** In `Snapceipt/Sync/DTOs.swift`, after the `DeviceDTO` struct (line 108):
```swift

/// PUT /devices/me body (§4.2). All fields optional; the encoder OMITS nil keys
/// (Swift's default for `Optional` Encodable), so a quiet-hours-only update never
/// clobbers the apns token and vice-versa.
struct UpdateDeviceBody: Encodable {
    var apnsToken: String?
    var quietHoursStartMin: Int?
    var quietHoursEndMin: Int?
    var timezone: String?
    var pushEnabled: Bool?
}

/// PUT /devices/me response — the upserted device row (only `id` is asserted).
struct UpdateDeviceResponse: Decodable {
    let id: String
}
```

- [ ] **Step 4: Add to the protocol.** In `Snapceipt/Sync/APIClient.swift`, inside `protocol APIClient`, after the `export(...)` declaration (line 22):
```swift
    /// PUT /devices/me — upsert this device's apns token / quiet-hours / timezone /
    /// push_enabled. Keyed by the X-Device-Id header (attached by makeRequest). (§4.2)
    func updateDevice(_ body: UpdateDeviceBody) async throws -> UpdateDeviceResponse
```

- [ ] **Step 5: Implement on `LiveAPIClient`.** In `Snapceipt/Sync/APIClient.swift`, after the `export(...)` method (line 127):
```swift

    func updateDevice(_ body: UpdateDeviceBody) async throws -> UpdateDeviceResponse {
        try await send("PUT", "/devices/me", body: body, authenticated: true)
    }
```

- [ ] **Step 6: Conform `StubAPIClient`.** In `Snapceipt/Sync/StubAPIClient.swift`, before the closing brace (after line 55):
```swift
    func updateDevice(_ body: UpdateDeviceBody) async throws -> UpdateDeviceResponse {
        UpdateDeviceResponse(id: "stub-device")
    }
```

- [ ] **Step 7: Conform `PreviewAPIClient`.** In `Snapceipt/Features/Auth/SignInView.swift`, after the `export(...)` method (line 185, before `private var stub`):
```swift
    func updateDevice(_ body: UpdateDeviceBody) async throws -> UpdateDeviceResponse {
        UpdateDeviceResponse(id: "preview-device")
    }
```

- [ ] **Step 8: Conform `MockAPIClient`.** In `SnapceiptTests/Mocks/MockAPIClient.swift`, add a handler + recording near the other capture handlers (after line 33) and the method (after line 113). After line 33:
```swift
    var updateDeviceHandler: ((UpdateDeviceBody) async throws -> UpdateDeviceResponse)?
    private(set) var updateDeviceCalls: [UpdateDeviceBody] = []
```
After line 113 (the `export` method, before the final `}`):
```swift

    func updateDevice(_ body: UpdateDeviceBody) async throws -> UpdateDeviceResponse {
        updateDeviceCalls.append(body)
        guard let h = updateDeviceHandler else { throw MockAPIClientError.unscripted }
        return try await h(body)
    }
```

- [ ] **Step 9: Run it — expect PASS.**
```
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/UpdateDevicePayloadTests test 2>&1 | tail -20
```
Expected: `Test Suite 'UpdateDevice payload' passed` (3 tests).

- [ ] **Step 10: Commit.**
```
git add Snapceipt/Sync/DTOs.swift Snapceipt/Sync/APIClient.swift Snapceipt/Sync/StubAPIClient.swift \
  Snapceipt/Features/Auth/SignInView.swift SnapceiptTests/Mocks/MockAPIClient.swift \
  SnapceiptTests/UpdateDevicePayloadTests.swift
git commit -m "F3 iOS: APIClient.updateDevice (PUT /devices/me) + DTOs + conformers

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Budget CRUD view-model (`BudgetListViewModel`)

A `@MainActor @Observable` view-model mirroring `WFHViewModel`'s shape (verified): deps injected (`context`, `sync: any SyncEnqueuing`, `userId`, `profileId`, `now`), `reload()` fetch scoped to the active profile + `deletedAt == nil`, `enqueue(op:"upsert"/"delete", entityType:.budget, entity:)`. Soft-delete sets `deletedAt`/`updatedAt`. Spend per row via `BudgetSpend.spent`. The `categoryId` for a per-category budget is the `Category.id` (we resolve it from a `catKey` the editor selects); label defaults from the category meta.

**Files:**
- Create: `Snapceipt/Features/Budgets/BudgetListViewModel.swift`
- Test: `SnapceiptTests/BudgetListViewModelTests.swift`

- [ ] **Step 1: Write the failing test.**

Create `SnapceiptTests/BudgetListViewModelTests.swift`:
```swift
import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("BudgetListViewModel")
struct BudgetListViewModelTests {
    private func iso(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(container), MockSyncEngine())
    }

    private func vm(_ ctx: ModelContext, _ sync: MockSyncEngine) -> BudgetListViewModel {
        BudgetListViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1",
                            now: iso("2026-06-15"))
    }

    @Test("create inserts a budget scoped to the active profile and enqueues upsert")
    func createEnqueues() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        v.save(existing: nil, categoryId: nil, catKey: nil, label: "Everything",
               capCents: 600_00, alertThresholdPct: 90)
        let rows = try ctx.fetch(FetchDescriptor<Budget>(predicate: #Predicate { $0.deletedAt == nil }))
        #expect(rows.count == 1)
        #expect(rows[0].profileId == "p1")
        #expect(rows[0].capCents == 600_00)
        #expect(rows[0].alertThresholdPct == 90)
        #expect(rows[0].period == "monthly")
        #expect(sync.calls.count == 1)
        #expect(sync.calls[0].entityType == .budget)
        #expect(sync.calls[0].op == "upsert")
    }

    @Test("save with an existing budget updates in place (no duplicate)")
    func updateInPlace() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        v.save(existing: nil, categoryId: nil, catKey: nil, label: "Cap", capCents: 100_00, alertThresholdPct: 90)
        let row = v.budgets[0]
        v.save(existing: row, categoryId: nil, catKey: nil, label: "Cap", capCents: 250_00, alertThresholdPct: 80)
        let live = try ctx.fetch(FetchDescriptor<Budget>(predicate: #Predicate { $0.deletedAt == nil }))
        #expect(live.count == 1)
        #expect(live[0].capCents == 250_00)
        #expect(live[0].alertThresholdPct == 80)
        #expect(sync.calls.count == 2)
    }

    @Test("delete soft-deletes and enqueues a delete")
    func deleteSoft() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        v.save(existing: nil, categoryId: nil, catKey: nil, label: "Cap", capCents: 100_00, alertThresholdPct: 90)
        let row = v.budgets[0]
        v.delete(row)
        let live = try ctx.fetch(FetchDescriptor<Budget>(predicate: #Predicate { $0.deletedAt == nil }))
        #expect(live.isEmpty)
        #expect(sync.calls.last?.op == "delete")
        #expect(v.budgets.isEmpty)
    }

    @Test("rows expose spent + over-cap; top3 returns at most 3 by cap desc")
    func rowsAndTop3() throws {
        let (ctx, sync) = try makeFixture()
        ctx.insert(Transaction(userId: "u1", profileId: "p1", catKey: "meals",
                               amountCents: -200_00, txnDate: "2026-06-03"))
        try? ctx.save()
        let v = vm(ctx, sync)
        v.save(existing: nil, categoryId: nil, catKey: nil, label: "All", capCents: 100_00, alertThresholdPct: 90)
        v.save(existing: nil, categoryId: nil, catKey: nil, label: "Big", capCents: 900_00, alertThresholdPct: 90)
        v.save(existing: nil, categoryId: nil, catKey: nil, label: "Mid", capCents: 500_00, alertThresholdPct: 90)
        v.save(existing: nil, categoryId: nil, catKey: nil, label: "Low", capCents: 100_00, alertThresholdPct: 90)
        let rows = v.rows()
        let all = rows.first(where: { $0.budget.label == "All" })!
        #expect(all.spentCents == 200_00)
        #expect(all.overCap == true)
        let top = v.top3()
        #expect(top.count == 3)
        #expect(top[0].budget.capCents == 900_00)   // sorted by cap desc
    }
}
```

- [ ] **Step 2: Run it — expect FAIL.**
```
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/BudgetListViewModelTests test 2>&1 | tail -20
```
Expected: `cannot find 'BudgetListViewModel' in scope`.

- [ ] **Step 3: Write the implementation.**

Create `Snapceipt/Features/Budgets/BudgetListViewModel.swift`:
```swift
import Foundation
import SwiftData
import Observation

/// Drives budget CRUD + the Home tracker. Loads the active profile's live budgets,
/// computes per-budget spend via the pure `BudgetSpend` helper (injected `now`), and
/// upserts/soft-deletes through the sync seam. `@MainActor`; deps injected for tests.
@Observable
@MainActor
final class BudgetListViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String
    @ObservationIgnored private let now: Date

    /// Active profile's live budgets.
    private(set) var budgets: [Budget] = []

    /// A budget plus its computed spend, for the tracker/list rows.
    struct Row: Identifiable {
        let budget: Budget
        let spentCents: Int
        var id: String { budget.id }
        var overCap: Bool { spentCents > budget.capCents }
    }

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String,
         profileId: String, now: Date = Date()) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profileId = profileId
        self.now = now
        reload()
    }

    func reload() {
        let pid = profileId
        let d = FetchDescriptor<Budget>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.capCents, order: .reverse), SortDescriptor(\.createdAt)])
        budgets = (try? context.fetch(d)) ?? []
    }

    /// Snapshot the active profile's expenses for the spend math (categoryId-linked).
    private func txns() -> [BudgetSpend.Txn] {
        let pid = profileId
        let d = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        return ((try? context.fetch(d)) ?? []).map {
            BudgetSpend.Txn(txnDate: $0.txnDate, amountCents: $0.amountCents, categoryId: $0.categoryId)
        }
    }

    /// All budgets as rows (with spend), preserving the cap-desc reload order.
    func rows() -> [Row] {
        let snaps = txns()
        return budgets.map { Row(budget: $0, spentCents: BudgetSpend.spent(budget: $0, txns: snaps, now: now)) }
    }

    /// The active profile's top-3 monthly budgets (cap desc) for the Home tracker.
    func top3() -> [Row] { Array(rows().prefix(3)) }

    /// Create (existing == nil) or update a budget, then enqueue an upsert.
    func save(existing: Budget?, categoryId: String?, catKey: String?, label: String,
              capCents: Int, alertThresholdPct: Int) {
        let row: Budget
        if let existing {
            existing.categoryId = categoryId
            existing.catKey = catKey
            existing.label = label
            existing.capCents = capCents
            existing.alertThresholdPct = alertThresholdPct
            existing.updatedAt = Epoch.nowMs()
            row = existing
        } else {
            row = Budget(userId: userId, profileId: profileId, categoryId: categoryId,
                         catKey: catKey, label: label, period: "monthly",
                         capCents: capCents, alertThresholdPct: alertThresholdPct)
            context.insert(row)
        }
        try? context.save()
        reload()
        sync.enqueue(op: "upsert", entityType: .budget, entity: row)
    }

    /// Soft-delete (set deletedAt) + enqueue a delete.
    func delete(_ budget: Budget) {
        budget.deletedAt = Epoch.nowMs()
        budget.updatedAt = Epoch.nowMs()
        try? context.save()
        reload()
        sync.enqueue(op: "delete", entityType: .budget, entity: budget)
    }
}
```

- [ ] **Step 4: Run it — expect PASS.**
```
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/BudgetListViewModelTests test 2>&1 | tail -20
```
Expected: `Test Suite 'BudgetListViewModel' passed` (4 tests).

- [ ] **Step 5: Commit.**
```
git add Snapceipt/Features/Budgets/BudgetListViewModel.swift SnapceiptTests/BudgetListViewModelTests.swift
git commit -m "F3 iOS: BudgetListViewModel CRUD + spend rows + sync enqueue

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Alert feed derivation + local cache (`AlertFeed`, `AlertCache`)

§4.7: a feed item per budget where `alertSentAt` is in the current month AND `spent >= threshold` (threshold cents = `cap * pct / 100`). Item `id = budgetId + "-" + monthKey`; `title = "Budget alert: <label>"`; `body = "<spent> of <cap> (<pct>%)"` using `fmt`; `firedAt = alertSentAt`. Newest first. The cache is UserDefaults-backed `Set<String>` for read + dismissed, keyed by the item id (which already embeds `budgetId+monthKey`). Unread = fired-this-month ∧ not read; dismissed items are excluded from the feed. `now` injected.

**Files:**
- Create: `Snapceipt/Features/Alerts/AlertFeed.swift`
- Test: `SnapceiptTests/AlertFeedTests.swift`

- [ ] **Step 1: Write the failing test.**

Create `SnapceiptTests/AlertFeedTests.swift`:
```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("AlertFeed + cache")
struct AlertFeedTests {
    private func ms(_ s: String) -> Int {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return Int(f.date(from: s)!.timeIntervalSince1970 * 1000)
    }
    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    /// A budget alerted this month, spend over its threshold.
    private func alerted() -> AlertFeed.Input {
        AlertFeed.Input(budgetId: "b1", label: "Meals", capCents: 100_00,
                        alertThresholdPct: 90, spentCents: 95_00, alertSentAt: ms("2026-06-10"))
    }

    @Test("a budget alerted this month over threshold yields a feed item")
    func fires() {
        let items = AlertFeed.items(inputs: [alerted()], now: date("2026-06-15"))
        #expect(items.count == 1)
        #expect(items[0].id == "b1-2026-06")
        #expect(items[0].title == "Budget alert: Meals")
        #expect(items[0].body == "$95.00 of $100.00 (90%)")
        #expect(items[0].firedAt == ms("2026-06-10"))
    }

    @Test("alertSentAt in a prior month is excluded")
    func priorMonthExcluded() {
        var inp = alerted(); inp.alertSentAt = ms("2026-05-31")
        #expect(AlertFeed.items(inputs: [inp], now: date("2026-06-15")).isEmpty)
    }

    @Test("nil alertSentAt or spend below threshold is excluded")
    func notFired() {
        var noSent = alerted(); noSent.alertSentAt = nil
        var lowSpend = alerted(); lowSpend.spentCents = 10_00
        #expect(AlertFeed.items(inputs: [noSent, lowSpend], now: date("2026-06-15")).isEmpty)
    }

    @Test("items newest-first by firedAt")
    func ordering() {
        let a = AlertFeed.Input(budgetId: "a", label: "A", capCents: 100, alertThresholdPct: 50,
                                spentCents: 100, alertSentAt: ms("2026-06-02"))
        let b = AlertFeed.Input(budgetId: "b", label: "B", capCents: 100, alertThresholdPct: 50,
                                spentCents: 100, alertSentAt: ms("2026-06-20"))
        let items = AlertFeed.items(inputs: [a, b], now: date("2026-06-15"))
        #expect(items.map(\.id) == ["b-2026-06", "a-2026-06"])
    }

    @Test("cache marks read + dismissed; dismissed excluded; unread counted")
    func cacheLogic() {
        let suiteName = "sc.test.alerts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        var cache = AlertCache(defaults: defaults)
        let items = AlertFeed.items(inputs: [alerted()], now: date("2026-06-15"))
        #expect(cache.unreadCount(items) == 1)
        cache.markRead("b1-2026-06")
        #expect(cache.unreadCount(items) == 0)
        cache.dismiss("b1-2026-06")
        #expect(cache.visible(items).isEmpty)
        // Persisted across instances on the same suite.
        let reopened = AlertCache(defaults: defaults)
        #expect(reopened.isDismissed("b1-2026-06"))
        defaults.removePersistentDomain(forName: suiteName)
    }
}
```

- [ ] **Step 2: Run it — expect FAIL.**
```
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/AlertFeedTests test 2>&1 | tail -20
```
Expected: `cannot find 'AlertFeed' in scope`.

- [ ] **Step 3: Write the implementation.**

Create `Snapceipt/Features/Alerts/AlertFeed.swift`:
```swift
import Foundation

/// Pure derivation of the AlertsSheet feed (§4.7): an item per budget alerted in the
/// current month whose live spend is at/over its threshold. `now` is INJECTED.
enum AlertFeed {
    /// One budget's alert inputs (live spend + the server-set alertSentAt).
    struct Input: Equatable {
        let budgetId: String
        let label: String
        let capCents: Int
        let alertThresholdPct: Int
        let spentCents: Int
        var alertSentAt: Int?
    }

    /// A derived feed item.
    struct Item: Identifiable, Equatable {
        let id: String           // budgetId + "-" + monthKey
        let budgetId: String
        let title: String
        let body: String
        let firedAt: Int         // alertSentAt ms
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()

    private static func monthKey(of msEpoch: Int) -> String {
        let d = Date(timeIntervalSince1970: Double(msEpoch) / 1000.0)
        let c = utcCalendar.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year!, c.month!)
    }

    /// Derive the feed, newest-first. Excludes nil alertSentAt, prior-month sends,
    /// and budgets whose spend is below threshold.
    static func items(inputs: [Input], now: Date) -> [Item] {
        let nowKey = BudgetSpend.monthKey(for: now)
        return inputs.compactMap { inp -> Item? in
            guard let sent = inp.alertSentAt, monthKey(of: sent) == nowKey else { return nil }
            let thresholdCents = inp.capCents * inp.alertThresholdPct / 100
            guard inp.spentCents >= thresholdCents else { return nil }
            return Item(
                id: "\(inp.budgetId)-\(nowKey)",
                budgetId: inp.budgetId,
                title: "Budget alert: \(inp.label)",
                body: "\(fmt(inp.spentCents)) of \(fmt(inp.capCents)) (\(inp.alertThresholdPct)%)",
                firedAt: sent)
        }
        .sorted { $0.firedAt > $1.firedAt }
    }
}

/// UserDefaults-backed read/dismiss cache for alert items (per-device, NOT synced).
/// Keyed by the item id (which embeds budgetId+monthKey, so month rollover re-arms).
struct AlertCache {
    private let defaults: UserDefaults
    private let readKey = "sc.alerts.read"
    private let dismissedKey = "sc.alerts.dismissed"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func set(_ key: String) -> Set<String> {
        Set((defaults.array(forKey: key) as? [String]) ?? [])
    }
    private func save(_ s: Set<String>, _ key: String) {
        defaults.set(Array(s), forKey: key)
    }

    func isRead(_ id: String) -> Bool { set(readKey).contains(id) }
    func isDismissed(_ id: String) -> Bool { set(dismissedKey).contains(id) }

    mutating func markRead(_ id: String) { var s = set(readKey); s.insert(id); save(s, readKey) }
    mutating func dismiss(_ id: String) { var s = set(dismissedKey); s.insert(id); save(s, dismissedKey) }

    /// Items not dismissed.
    func visible(_ items: [AlertFeed.Item]) -> [AlertFeed.Item] {
        let dis = set(dismissedKey)
        return items.filter { !dis.contains($0.id) }
    }

    /// Count of visible, unread items (drives the Home bell dot).
    func unreadCount(_ items: [AlertFeed.Item]) -> Int {
        let read = set(readKey)
        return visible(items).filter { !read.contains($0.id) }.count
    }
}
```

- [ ] **Step 4: Run it — expect PASS.**
```
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/AlertFeedTests test 2>&1 | tail -20
```
Expected: `Test Suite 'AlertFeed + cache' passed` (5 tests).

- [ ] **Step 5: Commit.**
```
git add Snapceipt/Features/Alerts/AlertFeed.swift SnapceiptTests/AlertFeedTests.swift
git commit -m "F3 iOS: AlertFeed derivation (§4.7) + UserDefaults read/dismiss cache + tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Quiet-hours encode + `updateDevice` payload builder (`QuietHours`)

Pure helpers: minutes-from-midnight ↔ `(hour, minute)` for the two time pickers, the device IANA timezone (`TimeZone.current.identifier`), and a builder assembling an `UpdateDeviceBody` for a settings change (push + quiet hours + timezone). Wrap-around is the cron's concern (§4.6, backend), but we validate the 0–1439 range here. `now`/`timezone` injectable for tests.

**Files:**
- Create: `Snapceipt/Features/Notifications/QuietHours.swift`
- Test: `SnapceiptTests/QuietHoursTests.swift`

- [ ] **Step 1: Write the failing test.**

Create `SnapceiptTests/QuietHoursTests.swift`:
```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("QuietHours")
struct QuietHoursTests {
    @Test("minutes <-> components round-trip")
    func roundTrip() {
        #expect(QuietHours.minutes(hour: 22, minute: 0) == 1320)
        #expect(QuietHours.minutes(hour: 7, minute: 0) == 420)
        let c = QuietHours.components(fromMinutes: 1320)
        #expect(c.hour == 22 && c.minute == 0)
    }

    @Test("minutes clamps into 0...1439")
    func clamps() {
        #expect(QuietHours.minutes(hour: 25, minute: 0) == 1439)
        #expect(QuietHours.minutes(hour: -1, minute: -5) == 0)
    }

    @Test("payload carries push + quiet minutes + the device timezone")
    func payload() {
        let body = QuietHours.updateBody(pushEnabled: true, quietStartMin: 1320,
                                         quietEndMin: 420, timezone: "Australia/Sydney")
        #expect(body.pushEnabled == true)
        #expect(body.quietHoursStartMin == 1320)
        #expect(body.quietHoursEndMin == 420)
        #expect(body.timezone == "Australia/Sydney")
        #expect(body.apnsToken == nil)   // settings changes never send the token
    }

    @Test("disabling quiet hours sends null minutes (omitted) but keeps tz + push")
    func quietOff() {
        let body = QuietHours.updateBody(pushEnabled: false, quietStartMin: nil,
                                         quietEndMin: nil, timezone: "Australia/Perth")
        #expect(body.quietHoursStartMin == nil)
        #expect(body.quietHoursEndMin == nil)
        #expect(body.pushEnabled == false)
        #expect(body.timezone == "Australia/Perth")
    }
}
```

- [ ] **Step 2: Run it — expect FAIL.**
```
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/QuietHoursTests test 2>&1 | tail -20
```
Expected: `cannot find 'QuietHours' in scope`.

- [ ] **Step 3: Write the implementation.**

Create `Snapceipt/Features/Notifications/QuietHours.swift`:
```swift
import Foundation

/// Pure quiet-hours encoding for the Notifications settings screen. The cron enforces
/// the wrap-around window (§4.6); here we only convert picker components <-> minutes and
/// build the PUT /devices/me body. No hidden Date()/TimeZone.current in the math.
enum QuietHours {
    /// Minutes-from-midnight (0...1439) for the given clock components, clamped.
    static func minutes(hour: Int, minute: Int) -> Int {
        let raw = hour * 60 + minute
        return Swift.min(1439, Swift.max(0, raw))
    }

    /// (hour, minute) for minutes-from-midnight.
    static func components(fromMinutes m: Int) -> (hour: Int, minute: Int) {
        let clamped = Swift.min(1439, Swift.max(0, m))
        return (clamped / 60, clamped % 60)
    }

    /// The device's IANA timezone (e.g. "Australia/Sydney").
    static func deviceTimezone(_ tz: TimeZone = .current) -> String { tz.identifier }

    /// Assemble the PUT /devices/me body for a settings change. `apnsToken` is left nil —
    /// token updates come only from the registration path (Task 8), never settings.
    static func updateBody(pushEnabled: Bool?, quietStartMin: Int?, quietEndMin: Int?,
                           timezone: String) -> UpdateDeviceBody {
        UpdateDeviceBody(apnsToken: nil, quietHoursStartMin: quietStartMin,
                         quietHoursEndMin: quietEndMin, timezone: timezone, pushEnabled: pushEnabled)
    }
}
```

- [ ] **Step 4: Run it — expect PASS.**
```
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/QuietHoursTests test 2>&1 | tail -20
```
Expected: `Test Suite 'QuietHours' passed` (4 tests).

- [ ] **Step 5: Commit.**
```
git add Snapceipt/Features/Notifications/QuietHours.swift SnapceiptTests/QuietHoursTests.swift
git commit -m "F3 iOS: QuietHours encode + updateDevice payload builder + tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Router overlay cases + deep-link routing

Add the four non-fullscreen-vs-fullscreen overlay cases plus the tapped-push deep-link entry point. Per the spec these new screens are full-screen overlays (like `.mileage`/`.wfh`), reached from Home/Profile. The `.budgetEditor(id:)` case carries the budget id (nil id = add). `openBudget(_:)` sets `.budgetEditor`; a pure `parseBudgetDeepLink` extracts the id from `snapceipt://budget/<id>` so it is unit-testable.

**Files:**
- Modify: `Snapceipt/App/Router.swift` (Overlay enum lines 11-20; add methods after line 60)
- Test: `SnapceiptTests/DeepLinkRoutingTests.swift`

- [ ] **Step 1: Write the failing test.**

Create `SnapceiptTests/DeepLinkRoutingTests.swift`:
```swift
import Testing
import Foundation
@testable import Snapceipt

@MainActor
@Suite("Deep-link routing")
struct DeepLinkRoutingTests {
    @Test("parses a budget id from snapceipt://budget/<id>")
    func parses() {
        #expect(Router.parseBudgetDeepLink(URL(string: "snapceipt://budget/b-123")!) == "b-123")
    }

    @Test("non-budget / malformed urls return nil")
    func rejects() {
        #expect(Router.parseBudgetDeepLink(URL(string: "snapceipt://export")!) == nil)
        #expect(Router.parseBudgetDeepLink(URL(string: "https://snapceipt.app/budget/x")!) == nil)
        #expect(Router.parseBudgetDeepLink(URL(string: "snapceipt://budget/")!) == nil)
    }

    @Test("openBudget routes to the editor overlay for that id")
    func openBudget() {
        let r = Router()
        r.openBudget("b-9")
        #expect(r.overlay == .budgetEditor(id: "b-9"))
    }

    @Test("handleBudgetDeepLink opens the editor when the url is a budget link")
    func handleDeepLink() {
        let r = Router()
        let handled = r.handleBudgetDeepLink(URL(string: "snapceipt://budget/b-7")!)
        #expect(handled == true)
        #expect(r.overlay == .budgetEditor(id: "b-7"))
        #expect(r.handleBudgetDeepLink(URL(string: "snapceipt://export")!) == false)
    }
}
```

- [ ] **Step 2: Run it — expect FAIL.**
```
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/DeepLinkRoutingTests test 2>&1 | tail -20
```
Expected: `type 'Overlay' has no member 'budgetEditor'` / `no member 'parseBudgetDeepLink'`.

- [ ] **Step 3: Extend the Overlay enum.** In `Snapceipt/App/Router.swift`, replace the `Overlay` enum (lines 11-20):
```swift
enum Overlay: Equatable, Identifiable {
    case profilePicker
    case addProfile
    case capture
    case mileage
    case wfh
    case export
    case budgets
    case budgetEditor(id: String?)   // nil id = add a new budget
    case alerts
    case notificationSettings

    var id: String {
        switch self {
        case .profilePicker: return "profilePicker"
        case .addProfile: return "addProfile"
        case .capture: return "capture"
        case .mileage: return "mileage"
        case .wfh: return "wfh"
        case .export: return "export"
        case .budgets: return "budgets"
        case .budgetEditor(let id): return "budgetEditor-\(id ?? "new")"
        case .alerts: return "alerts"
        case .notificationSettings: return "notificationSettings"
        }
    }
}
```
NOTE: `Identifiable.id` changes from `Self` to `String` here. `.sheet(item:)` only needs `Identifiable`; the new overlays are presented as full-screen `.overlay`s (Task 7), not via `sheetBinding`, so this is safe. (`Overlay` stays `Equatable` for the existing `router.overlay == .capture` checks.)

- [ ] **Step 4: Add the routing methods.** In `Snapceipt/App/Router.swift`, after `dismissOverlay()` (line 60):
```swift

    /// Open the budget editor for `id` (nil = add). Used by row taps + tapped pushes.
    func openBudget(_ id: String?) { overlay = .budgetEditor(id: id) }

    /// Parse `snapceipt://budget/<id>` -> the budget id, or nil for any other URL.
    static func parseBudgetDeepLink(_ url: URL) -> String? {
        guard url.scheme == "snapceipt", url.host == "budget" else { return nil }
        let id = url.pathComponents.first(where: { $0 != "/" })
        guard let id, !id.isEmpty else { return nil }
        return id
    }

    /// If `url` is a budget deep-link, route to its editor and return true.
    @discardableResult
    func handleBudgetDeepLink(_ url: URL) -> Bool {
        guard let id = Router.parseBudgetDeepLink(url) else { return false }
        openBudget(id)
        return true
    }
```

- [ ] **Step 5: Run it — expect PASS.**
```
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/DeepLinkRoutingTests test 2>&1 | tail -20
```
Expected: `Test Suite 'Deep-link routing' passed` (4 tests). The full app target must still compile — `RootView.sheetBinding`/`sheetContent` reference only the original cases (the `switch` in `sheetContent` is non-exhaustive otherwise). Add a `default: EmptyView()` arm to `sheetContent` in this step:

In `Snapceipt/App/RootView.swift` `sheetContent(for:)`, replace the final case block (lines 320-324) so it stays exhaustive:
```swift
        case .capture:
            EmptyView()  // handled by the full-screen capture overlay
        case .mileage, .wfh, .budgets, .budgetEditor, .alerts, .notificationSettings:
            EmptyView()  // handled by the full-screen overlays
        }
```
And update `sheetBinding`'s `get`/`set` full-screen sets (lines 275-288) to exclude the new full-screen overlays:
```swift
    private var sheetBinding: Binding<Overlay?> {
        Binding(
            get: {
                switch router.overlay {
                case .capture, .mileage, .wfh, .budgets, .budgetEditor, .alerts, .notificationSettings:
                    return nil
                default: return router.overlay
                }
            },
            set: { newValue in
                let fullScreen: Set<String> = [Overlay.capture.id, Overlay.mileage.id, Overlay.wfh.id,
                                               Overlay.budgets.id, Overlay.alerts.id,
                                               Overlay.notificationSettings.id]
                if newValue == nil, let cur = router.overlay,
                   !fullScreen.contains(cur.id), !cur.id.hasPrefix("budgetEditor") {
                    router.dismissOverlay()
                } else if let newValue {
                    router.overlay = newValue
                }
            }
        )
    }
```
Re-run the full app build to confirm it compiles:
```
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit.**
```
git add Snapceipt/App/Router.swift Snapceipt/App/RootView.swift SnapceiptTests/DeepLinkRoutingTests.swift
git commit -m "F3 iOS: Router overlay cases (.budgets/.budgetEditor/.alerts/.notificationSettings) + budget deep-link parse + tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Budget UI — tracker card, list, editor; wire the overlays; Home bell

Build the SwiftUI surfaces. `BudgetTrackerView` replaces the `homeStub` placeholder body (keep the `ProfileSwitcherHeader` + the two QuickActions). `BudgetListView`/`BudgetEditorView`/`AlertsSheet`/`NotificationsSettingsView` are full-screen overlays following the `MileageScreen` pattern (verified: `LbHeader(title:onClose:onAdd:)` + `onClose: { router.dismissOverlay() }` + `.transition(.opacity)`). Add the Home header bell (opens `.alerts`, unread dot from `AlertCache`). Views are covered by the UI test (Task 11), so no unit test here — but the build must stay green.

**Files:**
- Create: `Snapceipt/Features/Budgets/BudgetTrackerView.swift`, `Snapceipt/Features/Budgets/BudgetListView.swift`, `Snapceipt/Features/Budgets/BudgetEditorView.swift`
- Modify: `Snapceipt/App/RootView.swift` (homeStub body; overlay wiring; `.profile` tab)
- Modify: `Snapceipt/Shared/AccessibilityID.swift`

- [ ] **Step 1: Add accessibility identifiers.** In `Snapceipt/Shared/AccessibilityID.swift`, before the closing `}` (after line 89):
```swift

    // Budgets (F3)
    static let homeBudgetTracker = "home.budgetTracker"
    static let homeBudgetEditLink = "home.budget.edit"
    static let homeBudgetEmptyCTA = "home.budget.emptyCTA"
    static let homeAlertsBell = "home.alerts.bell"
    static let budgetRowPrefix = "budget.row."          // + budget.id
    static let budgetListScreen = "budget.list.screen"
    static let budgetListAdd = "budget.list.add"
    static let budgetEditorScreen = "budget.editor.screen"
    static let budgetEditorScopeProfile = "budget.editor.scope.profile"
    static let budgetEditorScopeCategory = "budget.editor.scope.category"
    static let budgetEditorCap = "budget.editor.cap"
    static let budgetEditorThreshold = "budget.editor.threshold"
    static let budgetEditorSave = "budget.editor.save"
    static let budgetEditorDelete = "budget.editor.delete"

    // Alerts (F3)
    static let alertsScreen = "alerts.screen"
    static let alertRowPrefix = "alert.row."            // + item.id

    // Notifications settings (F3)
    static let notifSettingsScreen = "notif.settings.screen"
    static let notifPushToggle = "notif.push.toggle"
    static let notifQuietStart = "notif.quiet.start"
    static let notifQuietEnd = "notif.quiet.end"
    static let notifBasToggle = "notif.bas.toggle"

    // Profile tab (F3 entry rows)
    static let profileRowNotifications = "profile.row.notifications"
    static let profileRowBudgets = "profile.row.budgets"
```

- [ ] **Step 2: Create `BudgetTrackerView`.** Create `Snapceipt/Features/Budgets/BudgetTrackerView.swift`:
```swift
import SwiftUI
import SwiftData

/// Home budget tracker card: the active profile's top-3 monthly budgets, each a
/// BudgetRow (label, spent/cap via fmt, ProgressBar tinted accent -> --alert red over
/// cap). Edit link -> BudgetListView; tap a row -> that budget's editor; empty-state CTA.
struct BudgetTrackerView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let onEdit: () -> Void
    let onTapBudget: (String) -> Void
    let onAdd: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: BudgetListViewModel?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Monthly budgets").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                    Spacer()
                    if let vm, !vm.budgets.isEmpty {
                        Button(action: onEdit) {
                            Text("Edit").font(.ui(13.5, .semibold)).foregroundStyle(accent.base)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityID.homeBudgetEditLink)
                    }
                }
                if let vm, !vm.budgets.isEmpty {
                    ForEach(vm.top3()) { row in
                        Button { onTapBudget(row.budget.id) } label: { rowBody(row) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(AccessibilityID.budgetRowPrefix + row.budget.id)
                    }
                } else {
                    emptyState
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.homeBudgetTracker)
        .task {
            if vm == nil {
                vm = BudgetListViewModel(context: context, sync: sync,
                                         userId: userId, profileId: profileId)
            }
        }
    }

    @ViewBuilder private func rowBody(_ row: BudgetListViewModel.Row) -> some View {
        let over = row.overCap
        let tint = over ? Palette.alert : accent.base
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.budget.label).font(.ui(14)).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(fmt(row.spentCents)) / \(fmt(row.budget.capCents))")
                    .font(.ui(13, .semibold)).foregroundStyle(over ? Palette.alert : Palette.ink2)
                    .monospacedDigit()
            }
            ProgressBar(value: Double(row.spentCents), max: Double(Swift.max(1, row.budget.capCents)), tint: tint)
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No budgets yet").font(.ui(14, .semibold)).foregroundStyle(Palette.ink2)
            Button(action: onAdd) {
                Text("Add a budget").font(.ui(14, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(accent.base, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.homeBudgetEmptyCTA)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
```
NOTE: `Palette.alert` already exists (`Snapceipt/DesignSystem/Theme.swift:28` = `Color(hex: 0xD6452B)`) — use it directly; do NOT add a duplicate token. The tracker injects the shell's real `SyncEngine` (via the `sync: any SyncEnqueuing` property) but only ever calls `BudgetListViewModel`'s read methods (`top3()`/`rows()`), so no mutation happens here. `RootView` already passes `sync: sync` in Step 5(a).

- [ ] **Step 3: Create `BudgetEditorView`.** `LbHeader.onAdd` is a NON-optional `() -> Void` (verified) and always renders a "+" button, which is wrong for the editor/alerts/settings screens. So this file also defines a tiny shared `SheetHeader` (back button + title, no plus) reused by the editor, AlertsSheet, and NotificationsSettingsView. Create `Snapceipt/Features/Budgets/BudgetEditorView.swift`:
```swift
import SwiftUI
import SwiftData

/// Shared full-screen header with a back button + centered title and NO add button
/// (LbHeader always shows a "+"). Reused by the budget editor / alerts / settings screens.
struct SheetHeader: View {
    let title: String
    let onClose: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Icon(name: "arrowLeft", size: 20, color: Palette.ink2)
                    .frame(width: 40, height: 40)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .strokeBorder(Palette.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.logbookClose)
            Text(title).font(.ui(16, .bold)).foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity).lineLimit(1)
            // Spacer matching the back button's width so the title stays centered.
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.top, 54).padding(.horizontal, 18).padding(.bottom, 12)
    }
}

/// Full-screen add/edit budget overlay. Scope picker (Whole profile | a category) ->
/// default label; cap amount (dollars -> cents); alert threshold % (default 90); period
/// read-only Monthly. Save -> create/update + enqueue; Delete when editing.
struct BudgetEditorView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let budgetId: String?            // nil = add
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: BudgetListViewModel?
    @State private var editing: Budget?
    @State private var scopeCategory = false
    @State private var catKey: String = CategoryKey.meals.rawValue
    @State private var label = ""
    @State private var capText = ""
    @State private var threshold = 90.0

    private var categoryOptions: [SegmentOption] {
        [SegmentOption(id: "profile", label: "Whole profile"),
         SegmentOption(id: "category", label: "Category")]
    }
    @State private var scopeSelection = "profile"

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: budgetId == nil ? "New budget" : "Edit budget", onClose: onClose)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Segmented(options: categoryOptions, selection: $scopeSelection)
                            .accessibilityIdentifier(AccessibilityID.budgetEditorScopeProfile)
                        if scopeSelection == "category" { categoryPicker }
                        field("Label", text: $label)
                        capField
                        thresholdField
                        periodRow
                        if budgetId != nil { deleteButton }
                    }
                    .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 110)
                }
            }
            saveButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.budgetEditorScreen)
        .transition(.opacity)
        .onChange(of: scopeSelection) { _, v in scopeCategory = (v == "category"); applyDefaultLabel() }
        .onChange(of: catKey) { _, _ in applyDefaultLabel() }
        .task {
            if vm == nil {
                let model = BudgetListViewModel(context: context, sync: sync,
                                                userId: userId, profileId: profileId)
                vm = model
                if let id = budgetId, let b = model.budgets.first(where: { $0.id == id }) {
                    editing = b
                    scopeCategory = b.categoryId != nil
                    scopeSelection = scopeCategory ? "category" : "profile"
                    catKey = b.catKey ?? CategoryKey.meals.rawValue
                    label = b.label
                    capText = String(b.capCents / 100)
                    threshold = Double(b.alertThresholdPct)
                } else {
                    applyDefaultLabel()
                }
            }
        }
    }

    private var categoryPicker: some View {
        Menu {
            ForEach(CategoryKey.allCases, id: \.self) { key in
                Button(CATS[key]?.label ?? key.rawValue) { catKey = key.rawValue }
            }
        } label: {
            HStack {
                Text(CATS[CategoryKey(rawValue: catKey) ?? .meals]?.label ?? catKey)
                    .foregroundStyle(Palette.ink)
                Spacer(); Icon(name: "chevD", size: 14, color: Palette.ink3)
            }
            .padding(12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityIdentifier(AccessibilityID.budgetEditorScopeCategory)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
            TextField(title, text: text)
                .padding(12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var capField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Monthly cap ($)").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
            TextField("0", text: $capText).keyboardType(.numberPad)
                .padding(12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier(AccessibilityID.budgetEditorCap)
        }
    }

    private var thresholdField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Alert at \(Int(threshold))%").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
            Slider(value: $threshold, in: 50...100, step: 5)
                .tint(accent.base)
                .accessibilityIdentifier(AccessibilityID.budgetEditorThreshold)
        }
    }

    private var periodRow: some View {
        HStack { Text("Period").foregroundStyle(Palette.ink3); Spacer(); Text("Monthly").foregroundStyle(Palette.ink) }
            .font(.ui(13.5)).padding(.vertical, 4)
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            if let editing { vm?.delete(editing); onClose() }
        } label: {
            Text("Delete budget").font(.ui(14, .semibold)).foregroundStyle(Palette.alert)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        .accessibilityIdentifier(AccessibilityID.budgetEditorDelete)
    }

    private var saveButton: some View {
        Button(action: save) {
            Text("Save").font(.ui(16, .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(accent.base, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 18).padding(.bottom, 26)
        .accessibilityIdentifier(AccessibilityID.budgetEditorSave)
    }

    private func applyDefaultLabel() {
        guard label.isEmpty || isDefaultLabel(label) else { return }
        label = scopeCategory ? (CATS[CategoryKey(rawValue: catKey) ?? .meals]?.label ?? "Category")
                              : "Whole profile"
    }
    private func isDefaultLabel(_ s: String) -> Bool {
        s == "Whole profile" || CategoryKey.allCases.contains { CATS[$0]?.label == s }
    }

    private func save() {
        let capCents = (Int(capText) ?? 0) * 100
        let categoryId: String? = scopeCategory ? resolveCategoryId(catKey) : nil
        vm?.save(existing: editing, categoryId: categoryId,
                 catKey: scopeCategory ? catKey : nil,
                 label: label.isEmpty ? (scopeCategory ? catKey : "Whole profile") : label,
                 capCents: capCents, alertThresholdPct: Int(threshold))
        onClose()
    }

    /// Resolve the active profile's Category.id for a catKey (nil if none exists yet —
    /// the budget still scopes by catKey for display; spend uses categoryId when set).
    private func resolveCategoryId(_ key: String) -> String? {
        let pid = profileId
        var d = FetchDescriptor<Category>(predicate: #Predicate { $0.profileId == pid && $0.key == key && $0.deletedAt == nil })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.id
    }
}
```

- [ ] **Step 4: Create `BudgetListView`.** Create `Snapceipt/Features/Budgets/BudgetListView.swift`:
```swift
import SwiftUI
import SwiftData

/// Full-screen budgets list: rows (label, scope, spent/cap bar, threshold%), Add CTA,
/// tap -> editor, swipe -> soft-delete, empty state.
struct BudgetListView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let onClose: () -> Void
    let onEdit: (String?) -> Void   // nil = add

    @Environment(\.accent) private var accent
    @State private var vm: BudgetListViewModel?

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                LbHeader(title: "Budgets", onClose: onClose, onAdd: { onEdit(nil) })
                if let vm {
                    if vm.budgets.isEmpty {
                        Spacer(); EmptyArt(); Text("No budgets yet").font(.ui(15)).foregroundStyle(Palette.ink3); Spacer()
                    } else {
                        List {
                            ForEach(vm.rows()) { row in
                                Button { onEdit(row.budget.id) } label: { rowBody(row) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier(AccessibilityID.budgetRowPrefix + row.budget.id)
                                    .swipeActions {
                                        Button(role: .destructive) { vm.delete(row.budget) } label: { Text("Delete") }
                                    }
                            }
                            .listRowBackground(Palette.cream)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                } else { Color.clear }
            }
            LbFloatingCTA(title: "Add a budget", a11yId: AccessibilityID.budgetListAdd) { onEdit(nil) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.budgetListScreen)
        .transition(.opacity)
        .task {
            // Rebuild each appear so an edit/add reflects on return.
            vm = BudgetListViewModel(context: context, sync: sync, userId: userId, profileId: profileId)
        }
    }

    @ViewBuilder private func rowBody(_ row: BudgetListViewModel.Row) -> some View {
        let over = row.overCap
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.budget.label).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(fmt(row.spentCents)) / \(fmt(row.budget.capCents))")
                    .font(.ui(13, .semibold)).foregroundStyle(over ? Palette.alert : Palette.ink2).monospacedDigit()
            }
            ProgressBar(value: Double(row.spentCents),
                        max: Double(Swift.max(1, row.budget.capCents)),
                        tint: over ? Palette.alert : accent.base)
            Text("\(row.budget.categoryId == nil ? "Whole profile" : (row.budget.label)) · alert \(row.budget.alertThresholdPct)%")
                .font(.ui(11.5)).foregroundStyle(Palette.ink3)
        }
        .padding(.vertical, 6)
    }
}
```
NOTE: verify `LbFloatingCTA(title:a11yId:action:)` signature in `Snapceipt/Features/Logbooks/LogbookChrome.swift` (used by `MileageScreen` — confirmed referenced as `LbFloatingCTA(title:a11yId:)`). If its parameter labels differ, match the real signature.

- [ ] **Step 5: Wire the overlays + Home tracker + bell in `RootView`.** In `Snapceipt/App/RootView.swift`:

(a) Replace the `homeStub` body's placeholder content (lines 207-246) — keep the header + quick actions, add the bell into the header row and the tracker into the body:
```swift
    @ViewBuilder
    private func homeStub(accent: AccentPalette) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ProfileSwitcherHeader(
                        store: profiles,
                        onTapSwitch: { router.go(.overlay(.profilePicker)) }
                    )
                    Button { router.present(.alerts) } label: {
                        ZStack(alignment: .topTrailing) {
                            IconCircle(name: "bell", tint: accent.base, soft: accent.soft, size: 40, iconSize: 20)
                            if unreadAlertCount > 0 {
                                Circle().fill(Palette.alert).frame(width: 10, height: 10).offset(x: 2, y: -2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.homeAlertsBell)
                }
                .padding(.horizontal, 18).padding(.top, 12)

                HStack(spacing: 12) {
                    quickAction(title: "Mileage", icon: "car", id: AccessibilityID.homeQuickMileage,
                                accent: accent) { router.present(.mileage) }
                    quickAction(title: "WFH log", icon: "wfh", id: AccessibilityID.homeQuickWFH,
                                accent: accent) { router.present(.wfh) }
                }
                .padding(.horizontal, 18).padding(.top, 14)

                BudgetTrackerView(
                    context: profiles.context, sync: sync,
                    userId: profiles.userId, profileId: profiles.activeProfileId,
                    onEdit: { router.present(.budgets) },
                    onTapBudget: { router.openBudget($0) },
                    onAdd: { router.openBudget(nil) }
                )
                .padding(.horizontal, 18).padding(.top, 16)
            }
            // Home marker for UI tests. CRITICAL: `.accessibilityElement(children: .contain)`
            // makes this an a11y CONTAINER — it carries `shell.home` WITHOUT collapsing /
            // shadowing the inner `profile.switcher`, `home.alerts.bell`, `home.budget.edit`,
            // budget-row, and quick-action button ids. Applying `.accessibilityIdentifier`
            // WITHOUT `.contain` would flatten the subtree and clobber every child id (the same
            // pitfall the TabBar/`shell.tabbar` comment documents, and why the ORIGINAL homeStub
            // never put `shell.home` on the header-containing VStack). ShellUITests taps
            // `app.buttons[profileSwitcher]`; OnboardingUITests waits on
            // `app.otherElements[shellHome]` — both must keep resolving.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.shellHome)
            .padding(.bottom, 110)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
    }

    /// Unread alert count for the Home bell dot, derived from live budgets + the cache.
    private var unreadAlertCount: Int {
        let pid = profiles.activeProfileId
        let bd = FetchDescriptor<Budget>(predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        let budgets = (try? profiles.context.fetch(bd)) ?? []
        let model = BudgetListViewModel(context: profiles.context, sync: sync,
                                        userId: profiles.userId, profileId: pid)
        let inputs = model.rows().map {
            AlertFeed.Input(budgetId: $0.budget.id, label: $0.budget.label, capCents: $0.budget.capCents,
                            alertThresholdPct: $0.budget.alertThresholdPct, spentCents: $0.spentCents,
                            alertSentAt: $0.budget.alertSentAt)
        }
        _ = budgets
        return AlertCache().unreadCount(AlertFeed.items(inputs: inputs, now: Date()))
    }
```

(b) Add the budget overlays alongside the `.mileage`/`.wfh` overlays (after line 161). IMPORTANT: `AlertsSheet` (Task 9) and `NotificationsSettingsView` (Task 10) do NOT exist yet, so in THIS task add ONLY the two budget overlays below PLUS the temporary `Color.clear` placeholder for `.alerts`/`.notificationSettings`. Do NOT paste any `AlertsSheet(...)`/`NotificationsSettingsView(...)` block in Task 7 — those land in Tasks 9/10, which replace the placeholder. Add now:
```swift
        .overlay {
            if router.overlay == .budgets {
                BudgetListView(context: profiles.context, sync: sync, userId: profiles.userId,
                               profileId: profiles.activeProfileId,
                               onClose: { router.dismissOverlay() },
                               onEdit: { router.openBudget($0) })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if case let .budgetEditor(id) = router.overlay {
                BudgetEditorView(context: profiles.context, sync: sync, userId: profiles.userId,
                                 profileId: profiles.activeProfileId, budgetId: id,
                                 onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if router.overlay == .alerts || router.overlay == .notificationSettings {
                Color.clear  // AlertsSheet (Task 9) / NotificationsSettingsView (Task 10) wired later
            }
        }
```

(c) Route the `.profile` tab to a placeholder for now (Task 10 swaps in `ProfileTabView`): leave `StubTabView(title: "Profile", ...)` as-is in this task.

- [ ] **Step 6: Generate + build + run the existing UI suite to confirm no regressions.**
```
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptUITests test 2>&1 | tail -15
```
Expected: `BUILD SUCCEEDED`; existing UI tests still pass (the new Home is a superset; `shell.home` still present).

- [ ] **Step 7: Commit.**
```
git add Snapceipt/Features/Budgets/BudgetTrackerView.swift Snapceipt/Features/Budgets/BudgetListView.swift \
  Snapceipt/Features/Budgets/BudgetEditorView.swift Snapceipt/App/RootView.swift Snapceipt/Shared/AccessibilityID.swift
git commit -m "F3 iOS: Home budget tracker + bell, BudgetListView, BudgetEditorView, overlay wiring

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: APNs registration (`NotificationDelegate`) + app wiring + Info.plist

A `UIApplicationDelegate` + `UNUserNotificationCenterDelegate` wired via `@UIApplicationDelegateAdaptor`. On `didRegisterForRemoteNotificationsWithDeviceToken`: hex-encode → persist → `APIClient.updateDevice` with `apnsToken` + device IANA timezone. On `didReceive` (tap): parse `deepLink`/`budgetId` → `Router.handleBudgetDeepLink` / `openBudget`. On `willPresent`: foreground banner. `didFailToRegister`: log (simulator has no token). The delegate needs the Router + an APIClient + AuthStore — set via static injection from `SnapceiptApp.init` (the adaptor is instantiated by UIKit, so it reads shared refs). Token hex-encoding is the only pure-testable bit; we expose it as a `static func` and unit-test it inside the existing `UpdateDevicePayloadTests` suite to avoid a new file.

**Files:**
- Create: `Snapceipt/Features/Notifications/NotificationDelegate.swift`
- Modify: `Snapceipt/App/SnapceiptApp.swift`
- Modify: `Snapceipt/Info.plist`
- Modify: `SnapceiptTests/UpdateDevicePayloadTests.swift` (add hex test)

- [ ] **Step 1: Add the failing hex test.** In `SnapceiptTests/UpdateDevicePayloadTests.swift`, add inside the suite:
```swift
    @Test("device token hex-encodes lowercased, no separators")
    func hexEncode() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01])
        #expect(NotificationDelegate.hexToken(data) == "deadbeef01")
        #expect(NotificationDelegate.hexToken(Data()) == "")
    }
```

- [ ] **Step 2: Run it — expect FAIL.**
```
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/UpdateDevicePayloadTests test 2>&1 | tail -20
```
Expected: `cannot find 'NotificationDelegate' in scope`.

- [ ] **Step 3: Create `NotificationDelegate`.** Create `Snapceipt/Features/Notifications/NotificationDelegate.swift`:
```swift
import UIKit
import UserNotifications

/// App delegate bridging APNs token registration + notification taps into the app.
/// Wired via @UIApplicationDelegateAdaptor. The Router + APIClient + AuthStore are
/// injected from SnapceiptApp.init (UIKit instantiates the adaptor, so we use shared
/// references rather than init params). The simulator never issues a real token, so
/// didFailToRegister just logs — real push is verified by the backend unit tests.
final class NotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Shared injection points set by SnapceiptApp before the scene appears.
    static var router: Router?
    static var api: APIClient?
    static var timezoneProvider: () -> String = { QuietHours.deviceTimezone() }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Lowercase hex of a device token, no separators (the apns token wire format).
    static func hexToken(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = Self.hexToken(deviceToken)
        UserDefaults.standard.set(token, forKey: "sc.apnsToken")
        let body = UpdateDeviceBody(apnsToken: token, quietHoursStartMin: nil,
                                    quietHoursEndMin: nil, timezone: Self.timezoneProvider(),
                                    pushEnabled: true)
        Task { _ = try? await Self.api?.updateDevice(body) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator / no-entitlement path: log and continue. No crash, no UI impact.
        print("APNs registration failed: \(error.localizedDescription)")
    }

    // Tap on a delivered notification -> deep-link to the budget.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        await MainActor.run {
            if let deep = info["deepLink"] as? String, let url = URL(string: deep) {
                Self.router?.handleBudgetDeepLink(url)
            } else if let id = info["budgetId"] as? String {
                Self.router?.openBudget(id)
            }
        }
    }

    // Foreground delivery -> show a banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Request authorization and, if granted, register for remote notifications. Safe to
    /// call repeatedly. No-op token on the simulator (didFailToRegister handles it).
    @MainActor
    static func requestAndRegister() async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }
}
```

- [ ] **Step 4: Wire into `SnapceiptApp`.** In `Snapceipt/App/SnapceiptApp.swift`, add the adaptor + injection. After the existing `@State` properties (line 23):
```swift
    @UIApplicationDelegateAdaptor(NotificationDelegate.self) private var notificationDelegate
```
The current `init()` builds the `Router` INLINE (`_router = State(initialValue: Router())` at line 54) with no local binding, and `NotificationDelegate.router = router` would not compile. So FIRST introduce a local `router` and use it for the State init. Replace the existing `_router = State(initialValue: Router())` line (line 54) with:
```swift
        let router = Router()
        _router = State(initialValue: router)
```
Then, at the END of `init()` (after the last `_profiles = State(...)` line, before the closing brace), inject the shared refs. `api` is the local declared in BOTH the `#if DEBUG` and `#else` branches (so it is in scope after `#endif`); `router` is the local just introduced:
```swift
        NotificationDelegate.router = router
        NotificationDelegate.api = api
```
And route push deep-links opened while the app is foregrounded through `onOpenURL` — extend the existing handler (lines 72-75):
```swift
                .onOpenURL { url in
                    if router.handleBudgetDeepLink(url) { return }
                    Task { await authVM.handleDeepLink(url) }
                }
```

- [ ] **Step 5: Add the background mode.** In `Snapceipt/Info.plist`, before the closing `</dict>` (after line 67):
```xml
	<key>UIBackgroundModes</key>
	<array>
		<string>remote-notification</string>
	</array>
```

- [ ] **Step 6: Run it — expect PASS.**
```
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/UpdateDevicePayloadTests test 2>&1 | tail -20
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: `UpdateDevice payload` passes (4 tests now); `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit.**
```
git add Snapceipt/Features/Notifications/NotificationDelegate.swift Snapceipt/App/SnapceiptApp.swift \
  Snapceipt/Info.plist SnapceiptTests/UpdateDevicePayloadTests.swift
git commit -m "F3 iOS: NotificationDelegate (APNs token register/persist, tap deep-link, banner) + app wiring

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: AlertsSheet (derived feed UI)

`AlertsViewModel` (`@MainActor @Observable`) derives the feed from live budgets via `AlertFeed.items` + the `AlertCache` (read/dismiss), and `AlertsSheet` renders it (IconCircle + title + relative time + body; tap → mark read + deep-link; swipe → dismiss; `EmptyArt` empty state). The VM logic is covered by `AlertFeedTests` already; this task adds the view + replaces the Task 7 placeholder overlay. A small VM test confirms derive→read→dismiss against SwiftData.

**Files:**
- Create: `Snapceipt/Features/Alerts/AlertsViewModel.swift`, `Snapceipt/Features/Alerts/AlertsSheet.swift`
- Modify: `Snapceipt/App/RootView.swift` (replace the placeholder `.alerts` overlay)
- Test: add a VM case to `SnapceiptTests/AlertFeedTests.swift`

- [ ] **Step 1: Add the failing VM test.** In `SnapceiptTests/AlertFeedTests.swift`, add a `@MainActor` suite at the bottom of the file:
```swift
@MainActor
@Suite("AlertsViewModel")
struct AlertsViewModelTests {
    private func ms(_ s: String) -> Int {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return Int(f.date(from: s)!.timeIntervalSince1970 * 1000)
    }
    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    @Test("derives feed from an alerted over-threshold budget; dismiss removes it")
    func deriveAndDismiss() throws {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let b = Budget(userId: "u1", profileId: "p1", categoryId: nil, label: "All",
                       capCents: 100_00, alertThresholdPct: 90, alertSentAt: ms("2026-06-10"))
        ctx.insert(b)
        ctx.insert(Transaction(userId: "u1", profileId: "p1", catKey: "meals",
                               amountCents: -95_00, txnDate: "2026-06-03"))
        try ctx.save()
        let suiteName = "sc.test.alertsvm.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let vm = AlertsViewModel(context: ctx, userId: "u1", profileId: "p1",
                                 now: date("2026-06-15"), cache: AlertCache(defaults: defaults))
        #expect(vm.items.count == 1)
        let id = vm.items[0].id
        vm.dismiss(id)
        #expect(vm.items.isEmpty)
        defaults.removePersistentDomain(forName: suiteName)  // clean up by SUITE name, not .description
    }
}
```

- [ ] **Step 2: Run it — expect FAIL (`cannot find 'AlertsViewModel'`).**
```
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/AlertsViewModelTests test 2>&1 | tail -20
```
Expected: compile failure.

- [ ] **Step 3: Create `AlertsViewModel`.** Create `Snapceipt/Features/Alerts/AlertsViewModel.swift`:
```swift
import Foundation
import SwiftData
import Observation

/// Drives the AlertsSheet: derives the §4.7 feed from live budgets + their spend, filters
/// by the UserDefaults cache, and applies read/dismiss. `now` + cache injected for tests.
@Observable
@MainActor
final class AlertsViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String
    @ObservationIgnored private let now: Date
    @ObservationIgnored private var cache: AlertCache

    private(set) var items: [AlertFeed.Item] = []

    init(context: ModelContext, userId: String, profileId: String,
         now: Date = Date(), cache: AlertCache = AlertCache()) {
        self.context = context
        self.userId = userId
        self.profileId = profileId
        self.now = now
        self.cache = cache
        reload()
    }

    func reload() {
        let pid = profileId
        let bd = FetchDescriptor<Budget>(predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        let budgets = (try? context.fetch(bd)) ?? []
        let td = FetchDescriptor<Transaction>(predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        let txns = ((try? context.fetch(td)) ?? []).map {
            BudgetSpend.Txn(txnDate: $0.txnDate, amountCents: $0.amountCents, categoryId: $0.categoryId)
        }
        let inputs = budgets.map { b in
            AlertFeed.Input(budgetId: b.id, label: b.label, capCents: b.capCents,
                            alertThresholdPct: b.alertThresholdPct,
                            spentCents: BudgetSpend.spent(budget: b, txns: txns, now: now),
                            alertSentAt: b.alertSentAt)
        }
        items = cache.visible(AlertFeed.items(inputs: inputs, now: now))
    }

    func isRead(_ id: String) -> Bool { cache.isRead(id) }
    func markRead(_ id: String) { cache.markRead(id); reload() }
    func dismiss(_ id: String) { cache.dismiss(id); reload() }
}
```

- [ ] **Step 4: Create `AlertsSheet`.** Create `Snapceipt/Features/Alerts/AlertsSheet.swift`:
```swift
import SwiftUI
import SwiftData

/// Full-screen alerts feed: IconCircle + title + relative time + body; tap -> mark read
/// + deep-link to the budget; swipe -> dismiss; EmptyArt empty state. Budget-alerts only.
struct AlertsSheet: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let onOpenBudget: (String) -> Void
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: AlertsViewModel?

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: "Alerts", onClose: onClose)
                if let vm {
                    if vm.items.isEmpty {
                        Spacer(); EmptyArt(); Text("No alerts").font(.ui(15)).foregroundStyle(Palette.ink3); Spacer()
                    } else {
                        List {
                            ForEach(vm.items) { item in
                                Button { vm.markRead(item.id); onOpenBudget(item.budgetId); onClose() } label: { row(item, read: vm.isRead(item.id)) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier(AccessibilityID.alertRowPrefix + item.id)
                                    .swipeActions {
                                        Button(role: .destructive) { vm.dismiss(item.id) } label: { Text("Dismiss") }
                                    }
                            }
                            .listRowBackground(Palette.cream)
                        }
                        .listStyle(.plain).scrollContentBackground(.hidden)
                    }
                } else { Color.clear }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.alertsScreen)
        .transition(.opacity)
        .task { vm = AlertsViewModel(context: context, userId: userId, profileId: profileId) }
    }

    private func row(_ item: AlertFeed.Item, read: Bool) -> some View {
        HStack(spacing: 12) {
            IconCircle(name: "bell", tint: accent.base, soft: accent.soft, size: 40, iconSize: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                Text(item.body).font(.ui(12.5)).foregroundStyle(Palette.ink3).monospacedDigit()
                Text(relativeTime(item.firedAt)).font(.ui(11)).foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 0)
            if !read { Circle().fill(accent.base).frame(width: 8, height: 8) }
        }
        .padding(.vertical, 6)
    }

    private func relativeTime(_ ms: Int) -> String {
        let f = RelativeDateTimeFormatter()
        return f.localizedString(for: Date(timeIntervalSince1970: Double(ms) / 1000.0), relativeTo: Date())
    }
}
```

- [ ] **Step 5: Replace the placeholder overlay in `RootView`.** In `Snapceipt/App/RootView.swift`, replace the Task-7 placeholder `.overlay { if router.overlay == .alerts || .notificationSettings { Color.clear } }` with the real `.alerts` overlay (and keep `.notificationSettings` as `Color.clear` until Task 10):
```swift
        .overlay {
            if router.overlay == .alerts {
                AlertsSheet(context: profiles.context, sync: sync, userId: profiles.userId,
                            profileId: profiles.activeProfileId,
                            onOpenBudget: { router.openBudget($0) },
                            onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
        .overlay {
            if router.overlay == .notificationSettings {
                Color.clear  // NotificationsSettingsView wired in Task 10
            }
        }
```

- [ ] **Step 6: Run it — expect PASS + build.**
```
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/AlertsViewModelTests test 2>&1 | tail -20
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: `AlertsViewModel` passes (1 test); `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit.**
```
git add Snapceipt/Features/Alerts/AlertsViewModel.swift Snapceipt/Features/Alerts/AlertsSheet.swift \
  Snapceipt/App/RootView.swift SnapceiptTests/AlertFeedTests.swift
git commit -m "F3 iOS: AlertsViewModel + AlertsSheet (derived feed, read/dismiss) + overlay wiring

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: NotificationsSettingsView + ProfileTabView entry rows

`NotificationsSettingsViewModel` (`@MainActor @Observable`) holds push_enabled + quiet-hours state, persists them to UserDefaults, and calls `APIClient.updateDevice` (via `QuietHours.updateBody`) on any change. `NotificationsSettingsView` renders the permission prime, the push toggle, two time pickers, and the BAS placeholder toggle. `ProfileTabView` adds the two F3 entry rows. The VM's payload assembly is unit-tested.

**Files:**
- Create: `Snapceipt/Features/Notifications/NotificationsSettingsViewModel.swift`, `Snapceipt/Features/Notifications/NotificationsSettingsView.swift`, `Snapceipt/Features/Profiles/ProfileTabView.swift`
- Modify: `Snapceipt/App/RootView.swift` (real `.notificationSettings` overlay + `.profile` tab → `ProfileTabView`)
- Test: extend `SnapceiptTests/QuietHoursTests.swift` with a VM payload case

- [ ] **Step 1: Add the failing VM test.** In `SnapceiptTests/QuietHoursTests.swift`, add a `@MainActor` suite:
```swift
@MainActor
@Suite("NotificationsSettingsViewModel")
struct NotificationsSettingsViewModelTests {
    @Test("toggling push + setting quiet hours calls updateDevice with the right payload")
    func updatesDevice() async throws {
        let mock = MockAPIClient()
        mock.updateDeviceHandler = { _ in UpdateDeviceResponse(id: "d") }
        let suiteName = "sc.test.notif.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let vm = NotificationsSettingsViewModel(api: mock, defaults: defaults,
                                                timezone: "Australia/Sydney")
        vm.pushEnabled = true
        vm.quietHoursEnabled = true   // REQUIRED: persist() only sends the minutes when quiet hours are ON
        vm.quietStartMin = 1320
        vm.quietEndMin = 420
        await vm.persist()
        #expect(mock.updateDeviceCalls.count == 1)
        let body = mock.updateDeviceCalls[0]
        #expect(body.pushEnabled == true)
        #expect(body.quietHoursStartMin == 1320)
        #expect(body.quietHoursEndMin == 420)
        #expect(body.timezone == "Australia/Sydney")
        #expect(body.apnsToken == nil)
        defaults.removePersistentDomain(forName: suiteName)  // clean up by SUITE name, not .description
    }

    @Test("quiet hours off sends nil minutes")
    func quietOff() async throws {
        let mock = MockAPIClient()
        mock.updateDeviceHandler = { _ in UpdateDeviceResponse(id: "d") }
        let suiteName = "sc.test.notif.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let vm = NotificationsSettingsViewModel(api: mock, defaults: defaults,
                                                timezone: "Australia/Perth")
        vm.quietHoursEnabled = false
        await vm.persist()
        #expect(mock.updateDeviceCalls[0].quietHoursStartMin == nil)
        #expect(mock.updateDeviceCalls[0].quietHoursEndMin == nil)
        defaults.removePersistentDomain(forName: suiteName)  // clean up by SUITE name, not .description
    }
}
```

- [ ] **Step 2: Run it — expect FAIL.**
```
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/NotificationsSettingsViewModelTests test 2>&1 | tail -20
```
Expected: `cannot find 'NotificationsSettingsViewModel'`.

- [ ] **Step 3: Create the VM.** Create `Snapceipt/Features/Notifications/NotificationsSettingsViewModel.swift`:
```swift
import Foundation
import Observation

/// Notification settings state + persistence. Push on/off + quiet hours persist locally
/// (UserDefaults) AND push to the backend via PUT /devices/me (QuietHours.updateBody).
/// The BAS-reminder toggle is a LOCAL placeholder (no backend in v1). Deps injected.
@Observable
@MainActor
final class NotificationsSettingsViewModel {
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let timezone: String

    var pushEnabled: Bool { didSet { defaults.set(pushEnabled, forKey: Keys.push) } }
    var quietHoursEnabled: Bool { didSet { defaults.set(quietHoursEnabled, forKey: Keys.quietOn) } }
    var quietStartMin: Int { didSet { defaults.set(quietStartMin, forKey: Keys.quietStart) } }
    var quietEndMin: Int { didSet { defaults.set(quietEndMin, forKey: Keys.quietEnd) } }
    var basReminderEnabled: Bool { didSet { defaults.set(basReminderEnabled, forKey: Keys.bas) } }

    private enum Keys {
        static let push = "sc.notif.push"
        static let quietOn = "sc.notif.quietOn"
        static let quietStart = "sc.notif.quietStart"
        static let quietEnd = "sc.notif.quietEnd"
        static let bas = "sc.notif.bas"
    }

    init(api: APIClient, defaults: UserDefaults = .standard,
         timezone: String = QuietHours.deviceTimezone()) {
        self.api = api
        self.defaults = defaults
        self.timezone = timezone
        self.pushEnabled = defaults.object(forKey: Keys.push) as? Bool ?? true
        self.quietHoursEnabled = defaults.object(forKey: Keys.quietOn) as? Bool ?? false
        self.quietStartMin = defaults.object(forKey: Keys.quietStart) as? Int ?? 1320 // 22:00
        self.quietEndMin = defaults.object(forKey: Keys.quietEnd) as? Int ?? 420       // 07:00
        self.basReminderEnabled = defaults.object(forKey: Keys.bas) as? Bool ?? false
    }

    /// Push the current state to the backend. Quiet-hours minutes are nil when disabled.
    func persist() async {
        let body = QuietHours.updateBody(
            pushEnabled: pushEnabled,
            quietStartMin: quietHoursEnabled ? quietStartMin : nil,
            quietEndMin: quietHoursEnabled ? quietEndMin : nil,
            timezone: timezone)
        _ = try? await api.updateDevice(body)
    }
}
```

- [ ] **Step 4: Run it — expect PASS.**
```
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/NotificationsSettingsViewModelTests test 2>&1 | tail -20
```
Expected: `NotificationsSettingsViewModel` passes (2 tests).

- [ ] **Step 5: Create the view.** Create `Snapceipt/Features/Notifications/NotificationsSettingsView.swift`:
```swift
import SwiftUI

/// Notifications & alerts settings: APNs permission prime, Budget-alerts toggle ->
/// devices.push_enabled, Quiet hours two time pickers -> minutes + tz -> PUT /devices/me,
/// BAS-due reminder (local placeholder). Any change calls updateDevice.
struct NotificationsSettingsView: View {
    let api: APIClient
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: NotificationsSettingsViewModel?
    @State private var quietStart = Date()
    @State private var quietEnd = Date()

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: "Notifications & alerts", onClose: onClose)
                if let vm {
                    ScrollView {
                        VStack(spacing: 14) {
                            Toggle("Budget alerts", isOn: Binding(
                                get: { vm.pushEnabled },
                                set: { vm.pushEnabled = $0; Task { await vm.persist(); if $0 { await NotificationDelegate.requestAndRegister() } } }))
                                .tint(accent.base)
                                .accessibilityIdentifier(AccessibilityID.notifPushToggle)
                            quietHoursCard(vm)
                            Toggle("BAS-due reminder", isOn: Binding(
                                get: { vm.basReminderEnabled }, set: { vm.basReminderEnabled = $0 }))
                                .tint(accent.base)
                                .accessibilityIdentifier(AccessibilityID.notifBasToggle)
                        }
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 60)
                    }
                } else { Color.clear }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.notifSettingsScreen)
        .transition(.opacity)
        .task {
            if vm == nil {
                let model = NotificationsSettingsViewModel(api: api)
                quietStart = dateFor(model.quietStartMin)
                quietEnd = dateFor(model.quietEndMin)
                vm = model
            }
        }
    }

    @ViewBuilder private func quietHoursCard(_ vm: NotificationsSettingsViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Quiet hours", isOn: Binding(
                    get: { vm.quietHoursEnabled },
                    set: { vm.quietHoursEnabled = $0; Task { await vm.persist() } }))
                    .tint(accent.base)
                if vm.quietHoursEnabled {
                    DatePicker("From", selection: $quietStart, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier(AccessibilityID.notifQuietStart)
                        .onChange(of: quietStart) { _, d in vm.quietStartMin = minutesOf(d); Task { await vm.persist() } }
                    DatePicker("To", selection: $quietEnd, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier(AccessibilityID.notifQuietEnd)
                        .onChange(of: quietEnd) { _, d in vm.quietEndMin = minutesOf(d); Task { await vm.persist() } }
                }
            }
        }
    }

    private func minutesOf(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return QuietHours.minutes(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }
    private func dateFor(_ m: Int) -> Date {
        let c = QuietHours.components(fromMinutes: m)
        return Calendar.current.date(bySettingHour: c.hour, minute: c.minute, second: 0, of: Date()) ?? Date()
    }
}
```

- [ ] **Step 6: Create `ProfileTabView`.** Create `Snapceipt/Features/Profiles/ProfileTabView.swift`:
```swift
import SwiftUI

/// Lightweight Profile tab — the F3 entry rows only ("Notifications & alerts",
/// "Budgets"). The full Profile/Settings hub is F7.
struct ProfileTabView: View {
    let onOpenNotifications: () -> Void
    let onOpenBudgets: () -> Void

    @Environment(\.accent) private var accent

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Profile").font(.display(28)).foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                row(icon: "bell", title: "Notifications & alerts",
                    id: AccessibilityID.profileRowNotifications, action: onOpenNotifications)
                row(icon: "wallet", title: "Budgets",
                    id: AccessibilityID.profileRowBudgets, action: onOpenBudgets)
            }
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 110)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
    }

    private func row(icon: String, title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Card(padding: 14) {
                HStack(spacing: 12) {
                    IconCircle(name: icon, tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
                    Text(title).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                    Spacer(); Icon(name: "chevR", size: 16, color: Palette.ink3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
```

- [ ] **Step 7: Wire into `RootView`.** In `Snapceipt/App/RootView.swift`, (a) replace the placeholder `.notificationSettings` overlay with the real view:
```swift
        .overlay {
            if router.overlay == .notificationSettings {
                NotificationsSettingsView(api: captureAPI, onClose: { router.dismissOverlay() })
                    .environment(\.accent, accent).transition(.opacity)
            }
        }
```
(b) Replace the `.profile` tab content (line 197) in `tabContent`:
```swift
        case .profile:
            ProfileTabView(
                onOpenNotifications: { router.present(.notificationSettings) },
                onOpenBudgets: { router.present(.budgets) }
            )
            .environment(\.accent, accent)
```

- [ ] **Step 8: Generate + build + run.**
```
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/NotificationsSettingsViewModelTests test 2>&1 | tail -10
```
Expected: `BUILD SUCCEEDED`; VM tests pass.

- [ ] **Step 9: Commit.**
```
git add Snapceipt/Features/Notifications/NotificationsSettingsViewModel.swift \
  Snapceipt/Features/Notifications/NotificationsSettingsView.swift \
  Snapceipt/Features/Profiles/ProfileTabView.swift Snapceipt/App/RootView.swift \
  SnapceiptTests/QuietHoursTests.swift
git commit -m "F3 iOS: NotificationsSettingsView + VM + ProfileTabView entry rows + wiring

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Enable the F2 Personal under-budget card

`ReportsViewModel` gains `underBudget: (spentCents: Int, capCents: Int)?` — for a Personal profile with budgets, the current-month Σspent / Σcap when under (`Σspent < Σcap`); nil when business, no budgets, or not under. Reuse `BudgetSpend.spent` with the VM's injected `now`. `ReportsView` renders a small card when `underBudget != nil` and `!isBusiness`.

**Files:**
- Modify: `Snapceipt/Features/Reports/ReportsViewModel.swift`
- Modify: `Snapceipt/Features/Reports/ReportsView.swift`
- Modify: `Snapceipt/Shared/AccessibilityID.swift`
- Test: `SnapceiptTests/ReportsViewModelTests.swift` (add cases)

- [ ] **Step 1: Add the failing tests.** In `SnapceiptTests/ReportsViewModelTests.swift`, add to the suite:
```swift
    @Test("personal profile with budgets exposes the under-budget pair when under")
    func underBudget() throws {
        let ctx = try makeCtx()
        let p = Profile(userId: "u1", name: "Home", type: "personal",
                        accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A")
        p.id = "pp"; ctx.insert(p)
        ctx.insert(Budget(userId: "u1", profileId: "pp", categoryId: nil, label: "All", capCents: 600_00))
        ctx.insert(Transaction(userId: "u1", profileId: "pp", catKey: "meals",
                               amountCents: -200_00, txnDate: "2026-06-05"))
        try? ctx.save()
        let vm = ReportsViewModel(context: ctx, userId: "u1", profileId: "pp",
                                  startMonth: 7, now: iso("2026-06-15"))
        let ub = try #require(vm.underBudget)
        #expect(ub.spentCents == 200_00)
        #expect(ub.capCents == 600_00)
    }

    @Test("under-budget is nil for a business profile and when over budget")
    func underBudgetHidden() throws {
        let ctx = try makeCtx(); seed(ctx)   // business p1, no budgets
        let vmBiz = ReportsViewModel(context: ctx, userId: "u1", profileId: "p1",
                                     startMonth: 7, now: iso("2026-06-15"))
        #expect(vmBiz.underBudget == nil)

        let ctx2 = try makeCtx()
        let p = Profile(userId: "u1", name: "Home", type: "personal",
                        accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A")
        p.id = "pp"; ctx2.insert(p)
        ctx2.insert(Budget(userId: "u1", profileId: "pp", categoryId: nil, label: "All", capCents: 100_00))
        ctx2.insert(Transaction(userId: "u1", profileId: "pp", catKey: "meals",
                                amountCents: -200_00, txnDate: "2026-06-05"))
        try? ctx2.save()
        let vmOver = ReportsViewModel(context: ctx2, userId: "u1", profileId: "pp",
                                      startMonth: 7, now: iso("2026-06-15"))
        #expect(vmOver.underBudget == nil)   // over cap -> hidden
    }
```

- [ ] **Step 2: Run it — expect FAIL (`value of type 'ReportsViewModel' has no member 'underBudget'`).**
```
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/ReportsViewModelTests test 2>&1 | tail -20
```
Expected: compile failure.

- [ ] **Step 3: Compute `underBudget` in the VM.** In `Snapceipt/Features/Reports/ReportsViewModel.swift`, add a stored output near line 41:
```swift
    /// Personal-only under-budget summary: (Σspent, Σcap) for the current month when the
    /// profile has budgets AND is under (Σspent < Σcap). nil for business / no budgets / over.
    private(set) var underBudget: (spentCents: Int, capCents: Int)? = nil
```
Inside `load()`, after `gstYTDCents = ...` (line 100), compute it:
```swift
        // Personal under-budget card (F3): current-month Σspent vs Σcap of live budgets.
        if !isBusiness {
            let bd = FetchDescriptor<Budget>(predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
            let budgets = (try? context.fetch(bd)) ?? []
            if !budgets.isEmpty {
                let budgetTxns = rows.map {
                    BudgetSpend.Txn(txnDate: $0.txnDate, amountCents: $0.amountCents, categoryId: $0.categoryId)
                }
                let totalSpent = budgets.reduce(0) { $0 + BudgetSpend.spent(budget: $1, txns: budgetTxns, now: now) }
                let totalCap = budgets.reduce(0) { $0 + $1.capCents }
                underBudget = (totalSpent < totalCap) ? (totalSpent, totalCap) : nil
            } else { underBudget = nil }
        } else { underBudget = nil }
```
NOTE: `rows` is the `[Transaction]` fetched at line 72 — it is in scope inside `load()`. If the compiler complains `rows` was consumed, re-fetch via `context` or capture before the `.map` on line 73.

- [ ] **Step 4: Render the card.** In `Snapceipt/Shared/AccessibilityID.swift`, add (in the Reports section):
```swift
    static let reportsUnderBudget = "reports.underBudget"
```
In `Snapceipt/Features/Reports/ReportsView.swift`, in `body` after `netCard(vm)` (line 36), add:
```swift
                        if !vm.isBusiness, let ub = vm.underBudget { underBudgetCard(ub) }
```
And add the card builder near `netCard` (after line 94):
```swift
    private func underBudgetCard(_ ub: (spentCents: Int, capCents: Int)) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    IconCircle(name: "check", tint: accent.base, soft: accent.soft, size: 34, iconSize: 17)
                    Text("You're under budget").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                }
                Text("\(fmt(ub.spentCents)) of \(fmt(ub.capCents)) used")
                    .font(.ui(13)).foregroundStyle(Palette.ink2).monospacedDigit()
                ProgressBar(value: Double(ub.spentCents), max: Double(Swift.max(1, ub.capCents)), tint: accent.base)
            }
        }
        .accessibilityIdentifier(AccessibilityID.reportsUnderBudget)
    }
```

- [ ] **Step 5: Run it — expect PASS.**
```
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/ReportsViewModelTests test 2>&1 | tail -20
```
Expected: `ReportsViewModel` passes (7 tests).

- [ ] **Step 6: Commit.**
```
git add Snapceipt/Features/Reports/ReportsViewModel.swift Snapceipt/Features/Reports/ReportsView.swift \
  Snapceipt/Shared/AccessibilityID.swift SnapceiptTests/ReportsViewModelTests.swift
git commit -m "F3 iOS: enable F2 Personal under-budget card (Σspent/Σcap, current month) + tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: Seed budgets + alerted budget for the hermetic UI test

The UI test (Task 13) needs seeded budgets on the active profile, including one over-cap (red) and one with `alertSentAt` this month (so an alert appears). Extend `AppLaunch.applySeedIfNeeded` to seed budgets + an alert-fired budget on `p1` (the business profile that launches active under `-uiTestSeed`). Keep the existing seed intact.

**Files:**
- Modify: `Snapceipt/App/AppLaunch.swift`
- Test: covered by Task 13's UI test (no unit test).

- [ ] **Step 1: Extend the seed.** In `Snapceipt/App/AppLaunch.swift`, in `applySeedIfNeeded` before `try? context.save()` (line 68):
```swift
        // F3: seed budgets on p1 (active under -uiTestSeed).
        // 1) whole-profile budget WELL OVER cap (the seeded -120 + -80 = 200 > 150 cap -> red).
        let overBudget = Budget(userId: DevAccount.userId, profileId: p1.id, categoryId: nil,
                                label: "Whole profile", capCents: 150_00, alertThresholdPct: 90)
        context.insert(overBudget)
        // 2) a meals budget UNDER cap (200 spent of 600).
        context.insert(Budget(userId: DevAccount.userId, profileId: p1.id, categoryId: nil,
                              label: "Dining", capCents: 600_00, alertThresholdPct: 90))
        // 3) an ALREADY-ALERTED budget this month (alertSentAt = now) over threshold -> AlertsSheet item.
        let alerted = Budget(userId: DevAccount.userId, profileId: p1.id, categoryId: nil,
                             label: "Coffee", capCents: 100_00, alertThresholdPct: 90,
                             alertSentAt: Epoch.nowMs())
        context.insert(alerted)
        // give "Coffee" enough spend to be at/over threshold (>= 90 of 100): add a -95 txn this month.
        context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "Cafe",
                                   catKey: "meals", amountCents: -95_00, txnDate: dayISO(2)))
```
NOTE: the over-budget and alerted budgets are both whole-profile, so `BudgetSpend` sums ALL p1 expenses for the month (income excluded). With seeded expenses (−120, −80, −95 = −295), `overBudget` (cap 150) is over → red; `Coffee` (cap 100, threshold 90) has spent 295 ≥ 90 → alert appears; `Dining` (cap 600) is under. This is intentional for visual coverage.

- [ ] **Step 2: Generate + build.**
```
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit.**
```
git add Snapceipt/App/AppLaunch.swift
git commit -m "F3 iOS: seed budgets (over-cap + alerted) for the hermetic UI test

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 13: Hermetic UI test (tracker → add/edit → alerts → notifications)

One XCUITest mirroring `ReportsUITests`/`LogbookUITests`: `launchSeeded()`, assert the Home tracker renders seeded budgets (including over-cap), add a budget and confirm the tracker updates, open the AlertsSheet from the bell and dismiss the seeded alert, open Notifications settings (via the Profile tab) and toggle push + set quiet hours. NO live push (sim cannot issue APNs tokens — noted in the test header).

**Files:**
- Create: `SnapceiptUITests/BudgetsUITests.swift`

- [ ] **Step 1: Write the test.** Create `SnapceiptUITests/BudgetsUITests.swift`:
```swift
import XCTest

/// Hermetic budgets/alerts/notifications flow: seeded shell + stub API (no network).
/// Home tracker renders seeded budgets (incl. over-cap) -> add a budget -> tracker
/// updates; open AlertsSheet from the seeded alerted budget -> dismiss; open
/// Notifications settings -> toggle push + set quiet hours.
/// NO live push: the simulator cannot issue real APNs tokens; registration fails
/// gracefully and real push is covered by the backend unit tests + the stub seam.
final class BudgetsUITests: UITestCase {
    func testTrackerAddAlertsAndNotifications() {
        launchSeeded()   // signed-in, business profile p1 active, seeded budgets + an alerted budget

        // Home tracker renders.
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.homeBudgetTracker].waitForExistence(timeout: 10),
                      "Budget tracker missing on Home")

        // Add a budget via the Edit link -> list -> Add CTA -> editor -> Save.
        let edit = app.buttons[AccessibilityID.homeBudgetEditLink].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "Edit link missing")
        edit.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.budgetListScreen].waitForExistence(timeout: 5),
                      "Budget list did not appear")
        app.buttons[AccessibilityID.budgetListAdd].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.budgetEditorScreen].waitForExistence(timeout: 5),
                      "Budget editor did not appear")
        let cap = app.textFields[AccessibilityID.budgetEditorCap]
        XCTAssertTrue(cap.waitForExistence(timeout: 5), "Cap field missing")
        cap.tap(); cap.typeText("300")
        // The numberPad keyboard covers the bottom-pinned Save button. Tap the screen
        // chrome to dismiss it first, then Save. (The "Alert at N%" label is always
        // on-screen near the top and is safe to tap as a keyboard-dismiss target.)
        app.staticTexts["Period"].firstMatch.tap()
        let save = app.buttons[AccessibilityID.budgetEditorSave]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Save button missing")
        save.tap()

        // OVERLAY MODEL: `.budgets` and `.budgetEditor` are MUTUALLY-EXCLUSIVE router
        // overlays (one `router.overlay` at a time), so opening the editor REPLACED the
        // list, and Save -> `router.dismissOverlay()` lands back on HOME (the tracker),
        // NOT the list. (Unlike MileageScreen, whose add form is a nested local `.sheet`
        // inside the same overlay.) Assert we returned to Home and the tracker still shows.
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.homeBudgetTracker].waitForExistence(timeout: 5),
                      "Did not return to Home tracker after save")

        // Open the AlertsSheet from the Home bell -> dismiss the seeded alert.
        let bell = app.buttons[AccessibilityID.homeAlertsBell].firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 5), "Alerts bell missing")
        bell.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.alertsScreen].waitForExistence(timeout: 5),
                      "Alerts sheet did not appear")
        // The seeded "Coffee" budget alerted this month -> at least one alert row.
        let firstAlert = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", AccessibilityID.alertRowPrefix)).firstMatch
        XCTAssertTrue(firstAlert.waitForExistence(timeout: 5), "No seeded alert row rendered")
        firstAlert.swipeLeft()
        let dismiss = app.buttons["Dismiss"].firstMatch
        if dismiss.waitForExistence(timeout: 3) { dismiss.tap() }
        app.buttons[AccessibilityID.logbookClose].firstMatch.tap()

        // Notifications settings via the Profile tab -> toggle push + quiet hours.
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        let notifRow = app.buttons[AccessibilityID.profileRowNotifications].firstMatch
        XCTAssertTrue(notifRow.waitForExistence(timeout: 5), "Notifications row missing on Profile")
        notifRow.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.notifSettingsScreen].waitForExistence(timeout: 5),
                      "Notifications settings did not appear")
        let push = app.switches[AccessibilityID.notifPushToggle].firstMatch
        XCTAssertTrue(push.waitForExistence(timeout: 5), "Push toggle missing")
        push.tap()   // flips push_enabled (stubbed updateDevice, no network)
        // Quiet hours toggle -> the time pickers appear.
        // (The two DatePickers carry notifQuietStart/notifQuietEnd ids when shown.)
    }
}
```
NOTE: the seeded alerted budget ("Coffee") relies on Task 12's seed. The bell's unread dot is informational; the test asserts the alert ROW, which is robust. The `logbookClose` id is carried by BOTH the real `LbHeader` (BudgetListView) AND the shared `SheetHeader` (Task 7 — used by the editor / AlertsSheet / settings); the test only taps it on the AlertsSheet (to return to Home). After Save the editor self-dismisses to Home via `dismissOverlay()`, so there is no editor `logbookClose` tap.

- [ ] **Step 2: Generate + run the UI suite.**
```
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptUITests/BudgetsUITests test 2>&1 | tail -25
```
Expected: `Test Suite 'BudgetsUITests' passed`. If the editor's `cap` field is obscured by the keyboard, add a `app.swipeUp()` before tapping Save (mirror the pattern other UI tests use when fields are below the fold).

- [ ] **Step 3: Commit.**
```
git add SnapceiptUITests/BudgetsUITests.swift
git commit -m "F3 iOS: hermetic UI test (tracker add/edit, alerts dismiss, notifications toggle)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 14: Full-suite green gate

Run the entire iOS suite (unit + UI + the implicit typecheck via build) and confirm nothing regressed against the 225-unit / UI baseline.

**Files:** none (verification only).

- [ ] **Step 1: Regenerate + run the full unit suite.**
```
/opt/homebrew/bin/xcodegen generate
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests test 2>&1 | tail -15
```
Expected: all unit tests pass (225 baseline + the new F3 suites: BudgetSpend 5, BudgetListViewModel 4, AlertFeed+cache 5, AlertsViewModel 1, QuietHours 4, NotificationsSettingsViewModel 2, DeepLinkRouting 4, UpdateDevice payload 4, ReportsViewModel +2). No failures.

- [ ] **Step 2: Run the full UI suite.**
```
xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptUITests test 2>&1 | tail -15
```
Expected: all UI tests pass (existing + `BudgetsUITests`).

- [ ] **Step 3: If anything is red, STOP and fix before claiming done.** Use superpowers:systematic-debugging. Do not weaken assertions to make a test pass. Re-run Steps 1-2 until green.

- [ ] **Step 4: Final commit (only if Steps 1-3 produced fixes).**
```
git add -A
git commit -m "F3 iOS: full suite green (budgets + push + alerts + notifications)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
NOTE: NEVER `git add Snapceipt.xcodeproj` — it is xcodegen-generated + git-ignored. Every file-creating task above runs `/opt/homebrew/bin/xcodegen generate` before `xcodebuild`.
