# BAS History Hub Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let GST-registered business users navigate, review, and lodge prior BAS periods (not just the current one) and see an at-a-glance lodgement history.

**Architecture:** A movable "period cursor" on `BasViewModel` (anchor-shift, reload per-period PAYG + lodged on move) + a pure `BasHistory` builder + a `BasHistoryView` sheet whose rows drive the same cursor. Storage is already per-`periodKey`; export is already date-range-driven; the window math is a pure anchor-shift — so this is **client-only**.

**Tech Stack:** Swift / SwiftUI / SwiftData, Swift Testing (`import Testing`, `@Test`, `#expect`), XCTest UI tests.

## Global Constraints

- **Client-only:** no backend, migration, or sync changes; no push/notifications.
- **Soft status framing:** never the word "Overdue". Past + unmarked → `Not marked as lodged` (amber).
- **History range:** earliest period with a txn *or* a lodged snapshot → current, capped at **12 quarters / 36 months** (≈3 years).
- **Dates:** period **windows are UTC** (`Period`); **BAS due dates are Australia/Sydney** (`BasSchedule`). Never introduce a hidden `Date()` — `now` is injected into `BasViewModel`.
- **Current-period behavior must not change** at `periodOffset == 0` — the existing BAS suites are the regression net.
- **Spec:** `docs/superpowers/specs/2026-06-19-bas-history-hub-design.md`.
- **Tests:** Swift Testing; run the **whole suite** (single-method `-only-testing` selectors are flaky here). Simulator: **iPhone 17**.
- **Commits** end with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## File Structure

- `Snapceipt/Model/BasSchedule.swift` — **modify**: add `dueDate(for:period:)`.
- `Snapceipt/Features/Reports/Bas/BasHistory.swift` — **create**: pure history builder + status classifier + bounds.
- `Snapceipt/Features/Reports/Bas/BasViewModel.swift` — **modify**: period cursor, bounds, `status`, `history()`.
- `Snapceipt/DesignSystem/Icons.swift` — **modify**: add `chevL` path.
- `Snapceipt/DesignSystem/Theme.swift` — **modify**: add `Palette.warn` amber token.
- `Snapceipt/Shared/AccessibilityID.swift` — **modify**: add stepper + history ids.
- `Snapceipt/Features/Reports/Bas/BasView.swift` — **modify**: interactive stepper, status-driven headline, history link + sheet, PAYG refresh on nav.
- `Snapceipt/Features/Reports/Bas/BasHistoryView.swift` — **create**: the history list sheet.
- `SnapceiptTests/BasScheduleTests.swift` / `BasViewModelTests.swift` — **modify**: new tests.
- `SnapceiptTests/BasHistoryTests.swift` — **create**: pure builder tests.
- `SnapceiptUITests/BasUITests.swift` — **modify**: stepper + history UI test.

---

### Task 1: `BasSchedule.dueDate(for:period:)`

**Files:**
- Modify: `Snapceipt/Model/BasSchedule.swift`
- Test: `SnapceiptTests/BasScheduleTests.swift`

**Interfaces:**
- Consumes: `BasSchedule.nextDue(_:on:)` (exists), `Period.Window` (exists, `.end` is exclusive = first instant of the next period).
- Produces: `static func dueDate(for window: Period.Window, period: BasPeriod) -> Date`.

- [ ] **Step 1: Write the failing tests**

Add to `SnapceiptTests/BasScheduleTests.swift` inside `struct BasScheduleTests` (the `date(_:)` Sydney helper already exists):

```swift
    /// UTC window builder (Period windows are UTC) for the due-date tests.
    private func utc(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    @Test("dueDate maps each quarter window to its ATO lodge deadline")
    func quarterlyDueDates() {
        func q(_ nowS: String) -> Period.Window { Period.quarter.window(now: utc(nowS), startMonth: 7) }
        #expect(BasSchedule.dueDate(for: q("2025-08-15"), period: .quarterly) == date("2025-10-28")) // Jul–Sep
        #expect(BasSchedule.dueDate(for: q("2025-11-15"), period: .quarterly) == date("2026-02-28")) // Oct–Dec
        #expect(BasSchedule.dueDate(for: q("2026-02-15"), period: .quarterly) == date("2026-04-28")) // Jan–Mar
        #expect(BasSchedule.dueDate(for: q("2026-05-15"), period: .quarterly) == date("2026-07-28")) // Apr–Jun
    }

    @Test("dueDate maps a month window to the 21st of the following month")
    func monthlyDueDate() {
        let w = Period.month.window(now: utc("2026-07-10"), startMonth: 7)   // July 2026
        #expect(BasSchedule.dueDate(for: w, period: .monthly) == date("2026-08-21"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/BasScheduleTests 2>&1 | tail -20`
Expected: FAIL — `value of type 'BasSchedule' has no member 'dueDate'` (compile error).

- [ ] **Step 3: Add the implementation**

In `Snapceipt/Model/BasSchedule.swift`, inside `enum BasSchedule`, after `nextDue(_:on:)`:

```swift
    /// The lodge/pay due date for a *specific* period window: the first ATO deadline
    /// on/after the period's end. `window.end` is exclusive (the first instant of the
    /// next period), so `nextDue` resolves to that period's own deadline
    /// (e.g. Apr–Jun window.end = 1 Jul → 28 Jul).
    static func dueDate(for window: Period.Window, period: BasPeriod) -> Date {
        nextDue(period, on: window.end)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/BasScheduleTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Model/BasSchedule.swift SnapceiptTests/BasScheduleTests.swift
git commit -m "feat(bas): BasSchedule.dueDate(for:period:) — a period's lodge deadline

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `BasHistory` pure builder

**Files:**
- Create: `Snapceipt/Features/Reports/Bas/BasHistory.swift`
- Test: `SnapceiptTests/BasHistoryTests.swift`

**Interfaces:**
- Consumes: `BasEngine.Txn` / `BasEngine.compute(txns:gstRegistered:manual:)` / `BasEngine.Result`, `BasEngine.Manual()`; `BasLocalStore.Snapshot`; `Period.Window` / `Period.quarter`/`.month`; `BasPeriodKey.make(window:basPeriod:startMonth:)`; `BasSchedule.dueDate(for:period:)` (Task 1); `BasPeriod`; `ExportDateFormatter.shared` (UTC "yyyy-MM-dd").
- Produces:
  - `struct BasHistory.Row: Identifiable, Equatable { id, offset, periodKey, label, window, dueDate, netGstCents, status }`
  - `enum BasHistory.Status: Equatable { case lodged(atMs: Int, drifted: Bool); case due(Date); case notMarkedLodged(Date) }`
  - `static func cap(_:) -> Int`
  - `static func status(lodged:result:dueDate:now:) -> Status`
  - `static func earliestOffset(txns:lodged:basPeriod:startMonth:now:) -> Int`
  - `static func build(txns:lodged:gstRegistered:basPeriod:startMonth:now:) -> [Row]`

- [ ] **Step 1: Write the failing tests**

Create `SnapceiptTests/BasHistoryTests.swift`:

```swift
import Foundation
import Testing
@testable import Snapceipt

@Suite("BasHistory")
struct BasHistoryTests {
    private func now(_ s: String = "2026-05-15") -> Date {   // Apr–Jun 2026 = 2025Q4
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }
    private func txn(_ amount: Int, _ date: String, gstFree: Bool = false, capital: Bool = false) -> BasEngine.Txn {
        BasEngine.Txn(amountCents: amount, gstFree: gstFree, capital: capital, txnDate: date)
    }
    private let none: (String) -> BasLocalStore.Snapshot? = { _ in nil }

    @Test("contiguous rows from the current period back to the earliest period with data")
    func rowsSpanData() {
        let txns = [txn(1_100_000, "2026-05-01"),   // current quarter 2025Q4
                    txn(-110_000, "2026-02-10")]    // prior quarter 2025Q3
        let rows = BasHistory.build(txns: txns, lodged: none, gstRegistered: true,
                                    basPeriod: .quarterly, startMonth: 7, now: now())
        #expect(rows.map(\.periodKey) == ["2025Q4", "2025Q3"])   // most-recent first
        #expect(rows[0].offset == 0)
        #expect(rows[0].netGstCents == 100_000)                  // 1A on 1.1M income, no purchases
        #expect(rows[1].offset == -1)
        #expect(rows[1].netGstCents == -10_000)                  // 1B on a 110k purchase
    }

    @Test("status: current period is Due; a past unmarked period is Not-marked-lodged")
    func statusClassification() {
        let txns = [txn(1_100_000, "2026-05-01"), txn(-110_000, "2026-02-10")]
        let rows = BasHistory.build(txns: txns, lodged: none, gstRegistered: true,
                                    basPeriod: .quarterly, startMonth: 7, now: now())
        if case .due = rows[0].status {} else { Issue.record("current period should be .due") }
        if case .notMarkedLodged = rows[1].status {} else { Issue.record("past unmarked should be .notMarkedLodged") }
    }

    @Test("status: a lodged period reads lodged; drift flips when GST figures change")
    func lodgedAndDrift() {
        let txns = [txn(-110_000, "2026-02-10")]   // 2025Q3: oneB = 10_000, net = -10_000
        let clean = BasLocalStore.Snapshot(g1: 0, oneA: 0, oneB: 10_000, netGst: -10_000,
                                           payg: 0, total: -10_000, lodgedAtMs: 1_700_000_000_000)
        let drifted = BasLocalStore.Snapshot(g1: 0, oneA: 0, oneB: 5_000, netGst: -5_000,
                                             payg: 0, total: -5_000, lodgedAtMs: 1_700_000_000_000)
        let rowsClean = BasHistory.build(txns: txns, lodged: { $0 == "2025Q3" ? clean : nil },
                                         gstRegistered: true, basPeriod: .quarterly, startMonth: 7, now: now())
        #expect(rowsClean.first { $0.periodKey == "2025Q3" }?.status == .lodged(atMs: 1_700_000_000_000, drifted: false))
        let rowsDrift = BasHistory.build(txns: txns, lodged: { $0 == "2025Q3" ? drifted : nil },
                                         gstRegistered: true, basPeriod: .quarterly, startMonth: 7, now: now())
        #expect(rowsDrift.first { $0.periodKey == "2025Q3" }?.status == .lodged(atMs: 1_700_000_000_000, drifted: true))
    }

    @Test("empty data → just the current period")
    func emptyIsCurrentOnly() {
        let rows = BasHistory.build(txns: [], lodged: none, gstRegistered: true,
                                    basPeriod: .quarterly, startMonth: 7, now: now())
        #expect(rows.count == 1)
        #expect(rows[0].offset == 0)
    }

    @Test("data older than the 3-year cap is excluded (earliestOffset clamps)")
    func capExcludesAncientData() {
        // 13 quarters back from 2025Q4 is beyond the 12-quarter cap (floor = -11).
        let txns = [txn(1_100_000, "2026-05-01"),   // current
                    txn(-110_000, "2023-02-10")]    // ~13 quarters back → beyond cap
        #expect(BasHistory.earliestOffset(txns: txns, lodged: none, basPeriod: .quarterly,
                                          startMonth: 7, now: now()) == 0)
        let rows = BasHistory.build(txns: txns, lodged: none, gstRegistered: true,
                                    basPeriod: .quarterly, startMonth: 7, now: now())
        #expect(rows.count == 1)   // only the current period; the ancient txn is past the cap
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/BasHistoryTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'BasHistory' in scope` (compile error).

- [ ] **Step 3: Create the implementation**

Create `Snapceipt/Features/Reports/Bas/BasHistory.swift`:

```swift
import Foundation

/// Pure builder for the BAS history hub (spec 2026-06-19). Given the profile's
/// engine-txns + a lodged-snapshot lookup, returns one `Row` per period from the
/// current period back to the earliest period with data, capped at ~3 years. No
/// SwiftData, no hidden `Date()` — fully unit-testable.
enum BasHistory {
    struct Row: Identifiable, Equatable {
        let id: String          // periodKey
        let offset: Int         // 0 = current, negative = past
        let periodKey: String
        let label: String       // e.g. "Apr–Jun 2026"
        let window: Period.Window
        let dueDate: Date
        let netGstCents: Int    // headline figure = 1A − 1B
        let status: Status
    }

    enum Status: Equatable {
        case lodged(atMs: Int, drifted: Bool)
        case due(Date)             // current / upcoming, not lodged — neutral
        case notMarkedLodged(Date) // past, not lodged — amber (NEVER "overdue")
    }

    /// 3-year window: 12 quarters / 36 months.
    static func cap(_ basPeriod: BasPeriod) -> Int { basPeriod == .quarterly ? 12 : 36 }
    private static func monthsPerPeriod(_ basPeriod: BasPeriod) -> Int { basPeriod == .quarterly ? 3 : 1 }

    private static var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    private static func window(offset: Int, basPeriod: BasPeriod, startMonth: Int, now: Date) -> Period.Window {
        let anchor = utcCal.date(byAdding: .month, value: offset * monthsPerPeriod(basPeriod), to: now)!
        let p: Period = basPeriod == .quarterly ? .quarter : .month
        return p.window(now: anchor, startMonth: startMonth)
    }

    private static func inWindow(_ txns: [BasEngine.Txn], _ w: Period.Window) -> [BasEngine.Txn] {
        let iso = ExportDateFormatter.shared
        return txns.filter { iso.date(from: $0.txnDate).map { $0 >= w.start && $0 < w.end } ?? false }
    }

    /// Classify a period from its lodged snapshot, recomputed figures, due date, and `now`.
    /// Drift compares only the engine-recomputed GST figures (g1/1A/1B/net) — PAYG/total are
    /// per-period manual fields loaded separately, so excluding them avoids false drift.
    static func status(lodged: BasLocalStore.Snapshot?, result: BasEngine.Result,
                       dueDate: Date, now: Date) -> Status {
        if let s = lodged {
            let drifted = s.g1 != result.g1 || s.oneA != result.oneA
                || s.oneB != result.oneB || s.netGst != result.netGstCents
            return .lodged(atMs: s.lodgedAtMs, drifted: drifted)
        }
        return now <= dueDate ? .due(dueDate) : .notMarkedLodged(dueDate)
    }

    /// Furthest-back offset (≤ 0, ≥ capFloor) whose period has a txn or a lodged snapshot.
    /// `0` when there is no history within the cap.
    static func earliestOffset(txns: [BasEngine.Txn], lodged: (String) -> BasLocalStore.Snapshot?,
                               basPeriod: BasPeriod, startMonth: Int, now: Date) -> Int {
        let capFloor = -(cap(basPeriod) - 1)
        var deepest = 0
        for offset in stride(from: 0, through: capFloor, by: -1) {
            let w = window(offset: offset, basPeriod: basPeriod, startMonth: startMonth, now: now)
            let key = BasPeriodKey.make(window: w, basPeriod: basPeriod, startMonth: startMonth)
            if !inWindow(txns, w).isEmpty || lodged(key) != nil { deepest = offset }
        }
        return deepest
    }

    /// Contiguous rows `[0 … earliestOffset]`, most-recent first.
    static func build(txns: [BasEngine.Txn], lodged: (String) -> BasLocalStore.Snapshot?,
                      gstRegistered: Bool, basPeriod: BasPeriod, startMonth: Int, now: Date) -> [Row] {
        let floor = earliestOffset(txns: txns, lodged: lodged, basPeriod: basPeriod,
                                   startMonth: startMonth, now: now)
        var rows: [Row] = []
        for offset in stride(from: 0, through: floor, by: -1) {
            let w = window(offset: offset, basPeriod: basPeriod, startMonth: startMonth, now: now)
            let key = BasPeriodKey.make(window: w, basPeriod: basPeriod, startMonth: startMonth)
            let result = BasEngine.compute(txns: inWindow(txns, w), gstRegistered: gstRegistered,
                                           manual: BasEngine.Manual())
            let due = BasSchedule.dueDate(for: w, period: basPeriod)
            rows.append(Row(id: key, offset: offset, periodKey: key, label: w.label, window: w,
                            dueDate: due, netGstCents: result.netGstCents,
                            status: status(lodged: lodged(key), result: result, dueDate: due, now: now)))
        }
        return rows
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/BasHistoryTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Reports/Bas/BasHistory.swift SnapceiptTests/BasHistoryTests.swift
git commit -m "feat(bas): BasHistory pure builder (rows, status, bounds)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `BasViewModel` period cursor + history + status

**Files:**
- Modify: `Snapceipt/Features/Reports/Bas/BasViewModel.swift`
- Test: `SnapceiptTests/BasViewModelTests.swift`

**Interfaces:**
- Consumes: `BasHistory` (Task 2), `BasSchedule.dueDate(for:period:)` (Task 1), existing `recompute()`, `store`, `window`, `periodKey`, `lodgedAtMs`, `paygInstalmentCents`, `Period`, `BasPeriodKey`.
- Produces (on `BasViewModel`):
  - `private(set) var periodOffset: Int`
  - `private(set) var earliestOffset: Int`
  - `var canGoForward: Bool` / `var canGoBack: Bool`
  - `var periodDueDate: Date`
  - `var isPastDue: Bool`
  - `func goToPrevious()` / `func goToNext()` / `func select(offset: Int)`
  - `func history() -> [BasHistory.Row]`

- [ ] **Step 1: Write the failing tests**

Add to `SnapceiptTests/BasViewModelTests.swift` inside `struct BasViewModelTests`. (The existing `setup(...)` seeds txns dated `2026-05-01` only → current quarter 2025Q4.) Add a helper that also seeds a prior-quarter txn and a test set:

```swift
    /// Seed the canonical current-quarter txns PLUS one prior-quarter (Jan–Mar 2026 =
    /// 2025Q3) purchase, so the cursor has somewhere to go back to.
    private func setupTwoPeriods()
        throws -> (BasViewModel, ModelContext, BasLocalStore) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let store = BasLocalStore(defaults: UserDefaults(suiteName: "sc.test.basvm.\(UUID().uuidString)")!)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        let now = f.date(from: "2026-05-15")!
        ctx.insert(Transaction(userId: "u1", profileId: "p1", catKey: "income",
                               amountCents: 1_100_000, txnDate: "2026-05-01", gstSource: "manual"))   // 2025Q4
        ctx.insert(Transaction(userId: "u1", profileId: "p1", catKey: "office",
                               amountCents: -110_000, txnDate: "2026-02-10", gstSource: "derived"))   // 2025Q3
        try ctx.save()
        let vm = BasViewModel(context: ctx, api: MockAPIClient(), store: store, userId: "u1",
                              profileId: "p1", gstRegistered: true, basPeriod: .quarterly,
                              startMonth: 7, now: now)
        return (vm, ctx, store)
    }

    @Test("cursor starts at the current period; cannot step into the future")
    func cursorStartsCurrent() throws {
        let (vm, _, _) = try setupTwoPeriods()
        #expect(vm.periodOffset == 0)
        #expect(vm.periodKey == "2025Q4")
        #expect(vm.canGoForward == false)   // no future
        #expect(vm.canGoBack == true)       // prior-quarter data exists
    }

    @Test("goToPrevious moves the window + key to the prior period and recomputes")
    func goPrevious() throws {
        let (vm, _, _) = try setupTwoPeriods()
        vm.goToPrevious()
        #expect(vm.periodOffset == -1)
        #expect(vm.periodKey == "2025Q3")
        #expect(vm.result.oneB == 10_000)       // the 110k purchase
        #expect(vm.result.g1 == 0)              // income is in the next quarter, not this one
        #expect(vm.canGoForward == true)
        #expect(vm.canGoBack == false)          // 2025Q3 is the earliest with data
        vm.goToNext()
        #expect(vm.periodOffset == 0)
        #expect(vm.periodKey == "2025Q4")
        #expect(vm.result.g1 == 1_100_000)      // back to the current quarter
    }

    @Test("navigating reloads that period's PAYG + lodged snapshot")
    func reloadsPerPeriodState() throws {
        let (vm, _, store) = try setupTwoPeriods()
        store.setPaygInstalmentCents(25_000, profileId: "p1", periodKey: "2025Q3")
        vm.goToPrevious()
        #expect(vm.paygInstalmentCents == 25_000)
        vm.goToNext()
        #expect(vm.paygInstalmentCents == 0)    // current period has no PAYG set
    }

    @Test("history lists the current + prior period, most-recent first")
    func historyRows() throws {
        let (vm, _, _) = try setupTwoPeriods()
        let rows = vm.history()
        #expect(rows.map(\.periodKey) == ["2025Q4", "2025Q3"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/BasViewModelTests 2>&1 | tail -20`
Expected: FAIL — `value of type 'BasViewModel' has no member 'periodOffset'`/`goToPrevious`/`history`.

- [ ] **Step 3a: Add stored cursor state to `BasViewModel`**

In `Snapceipt/Features/Reports/Bas/BasViewModel.swift`, add to the `private(set)` property block (next to `periodKey`):

```swift
    private(set) var periodOffset: Int = 0
    private(set) var earliestOffset: Int = 0
```

- [ ] **Step 3b: Initialise `earliestOffset` at the end of `init`**

In `init`, immediately **before** the final `recompute()` call, add:

```swift
        self.earliestOffset = BasHistory.earliestOffset(
            txns: Self.engineTxns(context: context, profileId: profileId),
            lodged: { store.lodgedSnapshot(profileId: profileId, periodKey: $0) },
            basPeriod: basPeriod, startMonth: startMonth, now: now)
```

- [ ] **Step 3c: Add the cursor + history + status API**

Add these members to `BasViewModel` (e.g. after `recompute()`):

```swift
    // MARK: - Period navigation (the history cursor)

    private static var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private var monthsPerPeriod: Int { basPeriod == .quarterly ? 3 : 1 }

    /// The selected period's lodge due date (not the global next-due).
    var periodDueDate: Date { BasSchedule.dueDate(for: window, period: basPeriod) }

    var canGoForward: Bool { periodOffset < 0 }      // 0 = current; never the future
    var canGoBack: Bool { periodOffset > earliestOffset }

    /// True when the selected period's lodge deadline has already passed (drives the soft
    /// "Not marked as lodged" line). `periodDueDate` reads the observed `window`, so the
    /// header re-renders on navigation; pairing it with the observed `lodgedAtMs` in the
    /// view avoids a stale status. (The history list classifies via `BasHistory.status`.)
    var isPastDue: Bool { now > periodDueDate }

    func goToPrevious() { guard canGoBack else { return }; moveTo(periodOffset - 1) }
    func goToNext() { guard canGoForward else { return }; moveTo(periodOffset + 1) }
    func select(offset: Int) { moveTo(min(0, max(earliestOffset, offset))) }

    private func moveTo(_ offset: Int) {
        periodOffset = offset
        let anchor = Self.utcCal.date(byAdding: .month, value: offset * monthsPerPeriod, to: now)!
        let p: Period = basPeriod == .quarterly ? .quarter : .month
        window = p.window(now: anchor, startMonth: startMonth)
        periodKey = BasPeriodKey.make(window: window, basPeriod: basPeriod, startMonth: startMonth)
        paygInstalmentCents = store.paygInstalmentCents(profileId: profileId, periodKey: periodKey)
        lodgedAtMs = store.lodgedSnapshot(profileId: profileId, periodKey: periodKey)?.lodgedAtMs
        recompute()
    }

    /// All non-deleted txns for the profile, mapped to engine txns (history + bounds span
    /// every period, not just the current window).
    private static func engineTxns(context: ModelContext, profileId: String) -> [BasEngine.Txn] {
        let pid = profileId
        let rows = (try? context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil }))) ?? []
        return rows.map { BasEngine.Txn(amountCents: $0.amountCents, gstFree: $0.gstFree,
                                        capital: $0.capital, txnDate: $0.txnDate) }
    }

    func history() -> [BasHistory.Row] {
        BasHistory.build(txns: Self.engineTxns(context: context, profileId: profileId),
                         lodged: { store.lodgedSnapshot(profileId: profileId, periodKey: $0) },
                         gstRegistered: gstRegistered, basPeriod: basPeriod,
                         startMonth: startMonth, now: now)
    }
```

- [ ] **Step 4: Run tests to verify they pass (incl. the existing BAS tests)**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/BasViewModelTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **` (the existing current-period tests AND the new nav tests).

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Reports/Bas/BasViewModel.swift SnapceiptTests/BasViewModelTests.swift
git commit -m "feat(bas): period cursor + history() + status on BasViewModel

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Interactive stepper + status headline in `BasView`

**Files:**
- Modify: `Snapceipt/DesignSystem/Icons.swift` (add `chevL`)
- Modify: `Snapceipt/DesignSystem/Theme.swift` (add `Palette.warn`)
- Modify: `Snapceipt/Shared/AccessibilityID.swift` (stepper ids)
- Modify: `Snapceipt/Features/Reports/Bas/BasView.swift`
- Verify: `SnapceiptTests/BasViewModelTests.swift` (no new test; build must stay green)

**Interfaces:**
- Consumes: `vm.goToPrevious()` / `goToNext()` / `canGoBack` / `canGoForward` / `periodOffset` / `periodDueDate` / `status` (Task 3); existing `fmtBasDue`, `Icon`, `Palette`, `accent`.
- Produces: `AccessibilityID.basPeriodPrev` / `basPeriodNext`; `Icons` `"chevL"`.

- [ ] **Step 1: Add the `chevL` icon path + a soft-amber `Palette.warn` token**

In `Snapceipt/DesignSystem/Icons.swift`, in the path dictionary next to `"chevR"`:

```swift
        "chevL": "M15 6l-6 6 6 6",
```

In `Snapceipt/DesignSystem/Theme.swift`, in the `Palette` color block (next to `alert`):

```swift
    static let warn = Color(hex: 0x9A7314)   // soft amber for "not marked as lodged" — never the alert red
```

- [ ] **Step 2: Add the accessibility ids**

In `Snapceipt/Shared/AccessibilityID.swift`, after `basPeriodStepper`:

```swift
    static let basPeriodPrev = "bas.period.prev"
    static let basPeriodNext = "bas.period.next"
```

- [ ] **Step 3: Replace the placeholder stepper**

In `Snapceipt/Features/Reports/Bas/BasView.swift`, replace the whole `periodStepper(_:)` function (the placeholder at ~lines 93–98, including its comment) with:

```swift
    // Interactive period cursor: ◀ / label / ▶, bounded by the VM (no future; back to
    // the earliest period with data, capped at ~3 years).
    @ViewBuilder private func periodStepper(_ vm: BasViewModel) -> some View {
        HStack(spacing: 8) {
            Button { vm.goToPrevious() } label: {
                Icon(name: "chevL", size: 14, color: vm.canGoBack ? accent.base : Palette.ink3)
            }
            .buttonStyle(.plain).disabled(!vm.canGoBack)
            .accessibilityIdentifier(AccessibilityID.basPeriodPrev)

            Text(vm.window.label).font(.ui(13, .semibold)).foregroundStyle(Palette.ink2)
                .accessibilityIdentifier(AccessibilityID.basPeriodStepper)

            Button { vm.goToNext() } label: {
                Icon(name: "chevR", size: 14, color: vm.canGoForward ? accent.base : Palette.ink3)
            }
            .buttonStyle(.plain).disabled(!vm.canGoForward)
            .accessibilityIdentifier(AccessibilityID.basPeriodNext)
        }
    }
```

- [ ] **Step 4: Make the headline due/lodged line period-aware + soft-status**

In `BasView.swift` `headline(_:)`, replace the block from `Text("Due \(fmtBasDue(vm.nextDue))")...` through the closing of the `if let lodgedAtMs = vm.lodgedAtMs { ... }` (the due + lodged + drift lines) with this version. It reads the **observed** `lodgedAtMs` / `hasDrifted` / `isPastDue` (so it re-renders on lodge and on navigation) and uses `vm.periodDueDate` (the selected period) instead of the global `vm.nextDue`:

```swift
                if let lodgedAtMs = vm.lodgedAtMs {
                    Text("Lodged \(fmtBasDue(Date(timeIntervalSince1970: Double(lodgedAtMs) / 1000)))")
                        .font(.ui(12.5, .semibold)).foregroundStyle(accent.base)
                    if vm.hasDrifted {
                        Text("Figures changed since you lodged — corrections belong on your next BAS as an adjustment.")
                            .font(.ui(12)).foregroundStyle(Palette.alert)
                    }
                } else if vm.isPastDue {
                    Text("Not marked as lodged · was due \(fmtBasDue(vm.periodDueDate))")
                        .font(.ui(12.5, .semibold)).foregroundStyle(Palette.warn)
                } else {
                    Text("Due \(fmtBasDue(vm.periodDueDate))")
                        .font(.ui(13.5)).foregroundStyle(Palette.ink2)
                }
```

This keeps the existing lodged + drift behavior (the current BAS tests stay green) and adds the soft past-due line.

- [ ] **Step 5: Refresh the PAYG field when the period changes**

In `BasView.swift`, on the `ScrollView` (or the outer `VStack`) in `body`, add an `onChange` that re-prefills `paygText` whenever the cursor moves. Add it right after the existing `.task { ... }` modifier on the body `ZStack`:

```swift
        .onChange(of: vm?.periodOffset) { _, _ in
            guard let vm else { return }
            paygText = vm.paygInstalmentCents == 0 ? "" : String(vm.paygInstalmentCents / 100)
        }
```

- [ ] **Step 6: Build to verify it compiles + existing tests pass**

Run: `xcodebuild build -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -aE "error:|BUILD (SUCCEEDED|FAILED)" | tail`
Expected: `** BUILD SUCCEEDED **`.

Then: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/BasViewModelTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Snapceipt/DesignSystem/Icons.swift Snapceipt/DesignSystem/Theme.swift Snapceipt/Shared/AccessibilityID.swift Snapceipt/Features/Reports/Bas/BasView.swift
git commit -m "feat(bas): interactive period stepper + soft status headline

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `BasHistoryView` sheet + drill-in

**Files:**
- Modify: `Snapceipt/Shared/AccessibilityID.swift` (history ids)
- Create: `Snapceipt/Features/Reports/Bas/BasHistoryView.swift`
- Modify: `Snapceipt/Features/Reports/Bas/BasView.swift` (link + sheet)

**Interfaces:**
- Consumes: `vm.history() -> [BasHistory.Row]` / `vm.periodOffset` / `vm.select(offset:)` (Task 3); `BasHistory.Row` / `BasHistory.Status` (Task 2); existing `Card`, `Palette`, `accent`, `Icon`, `fmt`, `fmtBasDue`.
- Produces: `AccessibilityID.basHistoryLink` / `basHistoryScreen` / `basHistoryRowPrefix`; `struct BasHistoryView`.

- [ ] **Step 1: Add the accessibility ids**

In `Snapceipt/Shared/AccessibilityID.swift`, after `basExport`:

```swift
    static let basHistoryLink = "bas.history.link"
    static let basHistoryScreen = "bas.history.screen"
    static let basHistoryRowPrefix = "bas.history.row."   // + periodKey
```

- [ ] **Step 2: Create `BasHistoryView`**

Create `Snapceipt/Features/Reports/Bas/BasHistoryView.swift`:

```swift
import SwiftUI

/// "Past BAS" history list (spec 2026-06-19). One row per period (most-recent first),
/// each showing its net-GST headline + a soft status badge. Tap → `onSelect(offset)`
/// moves the BasView cursor to that period. Presented as a sheet from BasView.
struct BasHistoryView: View {
    let rows: [BasHistory.Row]
    let currentOffset: Int
    let onSelect: (Int) -> Void
    let onClose: () -> Void

    @Environment(\.accent) private var accent

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: "Past BAS", onClose: onClose)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(rows) { row in
                            Button { onSelect(row.offset) } label: { rowBody(row) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.basHistoryRowPrefix + row.periodKey)
                        }
                    }
                    .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 60)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.basHistoryScreen)
        .transition(.opacity)
    }

    @ViewBuilder private func rowBody(_ row: BasHistory.Row) -> some View {
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(row.label).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                        if row.offset == currentOffset {
                            Text("Current").font(.ui(11, .semibold)).foregroundStyle(accent.base)
                        }
                    }
                    statusLabel(row.status)
                }
                Spacer()
                Text(netLabel(row.netGstCents)).font(.ui(14, .semibold))
                    .foregroundStyle(Palette.ink).monospacedDigit()
            }
        }
    }

    private func netLabel(_ cents: Int) -> String {
        cents < 0 ? "Refund \(fmt(-cents))" : "\(fmt(cents))"
    }

    @ViewBuilder private func statusLabel(_ status: BasHistory.Status) -> some View {
        switch status {
        case let .lodged(atMs, drifted):
            Text(drifted
                 ? "Lodged \(fmtBasDue(Date(timeIntervalSince1970: Double(atMs) / 1000))) · figures changed"
                 : "Lodged \(fmtBasDue(Date(timeIntervalSince1970: Double(atMs) / 1000)))")
                .font(.ui(12)).foregroundStyle(accent.base)
        case let .due(date):
            Text("Due \(fmtBasDue(date))").font(.ui(12)).foregroundStyle(Palette.ink3)
        case let .notMarkedLodged(date):
            Text("Not marked as lodged · was due \(fmtBasDue(date))")
                .font(.ui(12, .semibold)).foregroundStyle(Palette.warn)
        }
    }
}
```

(`Palette.warn` is the soft-amber token added in Task 4 — never `Palette.alert` red.)

- [ ] **Step 3: Add the "Past BAS" link + sheet to `BasView`**

In `BasView.swift`, add state next to the other `@State`:

```swift
    @State private var showHistory = false
```

In `actions(_:)`, add a third button **below** the Export button (still inside the `VStack`):

```swift
            Button { showHistory = true } label: {
                HStack(spacing: 6) {
                    Icon(name: "chart", size: 14, color: accent.base)
                    Text("Past BAS").font(.ui(14.5, .semibold)).foregroundStyle(accent.base)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.basHistoryLink)
```

Add the sheet modifier on the body `ZStack`, right after the `.onChange(of: vm?.periodOffset)` from Task 4:

```swift
        .sheet(isPresented: $showHistory) {
            if let vm {
                BasHistoryView(rows: vm.history(), currentOffset: vm.periodOffset,
                               onSelect: { vm.select(offset: $0); showHistory = false },
                               onClose: { showHistory = false })
                    .environment(\.accent, accent)
            }
        }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild build -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -aE "error:|BUILD (SUCCEEDED|FAILED)" | tail`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Shared/AccessibilityID.swift Snapceipt/Features/Reports/Bas/BasHistoryView.swift Snapceipt/Features/Reports/Bas/BasView.swift
git commit -m "feat(bas): Past-BAS history sheet with drill-in to the cursor

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: UI test — stepper + history drill-in

**Files:**
- Modify: `SnapceiptUITests/BasUITests.swift`

**Interfaces:**
- Consumes: `AccessibilityID.basPeriodPrev` / `basPeriodNext` / `basHistoryLink` / `basHistoryScreen` / `basHistoryRowPrefix` (Tasks 4–5); existing `launchBasSeed(pro:)`, `scrollToHittable`, `tabReports`, `reportsBasCard`, `basScreen`.

- [ ] **Step 1: Write the UI test**

Add to `SnapceiptUITests/BasUITests.swift` inside `final class BasUITests`:

```swift
    @MainActor func test_basPeriodStepperAndHistoryDrillIn() {
        launchBasSeed(pro: true)
        app.buttons[AccessibilityID.tabReports].tap()
        let reportsScroll = app.descendants(matching: .any)[AccessibilityID.reportsScreen].firstMatch
        XCTAssertTrue(reportsScroll.waitForExistence(timeout: 8), "Reports never appeared")
        let card = app.buttons[AccessibilityID.reportsBasCard].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8), "BAS card missing")
        XCTAssertTrue(scrollToHittable(card, within: reportsScroll), "BAS card not hittable")
        card.tap()

        let basScroll = app.descendants(matching: .any)[AccessibilityID.basScreen].firstMatch
        XCTAssertTrue(basScroll.waitForExistence(timeout: 8), "BAS screen never appeared")

        // The period stepper controls exist (◀ may be disabled if the seed has no prior data).
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.basPeriodNext].waitForExistence(timeout: 4),
                      "period next control missing")
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.basPeriodPrev].exists,
                      "period prev control missing")

        // Open the Past-BAS history sheet.
        let historyLink = app.descendants(matching: .any)[AccessibilityID.basHistoryLink]
        XCTAssertTrue(scrollToHittable(historyLink, within: basScroll, timeout: 4), "Past BAS link not reachable")
        historyLink.tap()
        let historyScreen = app.descendants(matching: .any)[AccessibilityID.basHistoryScreen].firstMatch
        XCTAssertTrue(historyScreen.waitForExistence(timeout: 5), "history sheet did not open")

        // At least the current period row exists; tapping a row returns to the BAS screen.
        let firstRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.basHistoryRowPrefix))
            .firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "no history rows")
        firstRow.tap()
        XCTAssertTrue(basScroll.waitForExistence(timeout: 5), "did not return to the BAS screen after drill-in")
    }
```

- [ ] **Step 2: Run the UI test**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptUITests/BasUITests/test_basPeriodStepperAndHistoryDrillIn 2>&1 | tail -20`
Expected: the test passes (`Test Case '-[BasUITests test_basPeriodStepperAndHistoryDrillIn]' passed`). If `launchBasSeed` seeds only the current period, the ◀ stays disabled — that's fine; this test asserts the controls + history plumbing, while prior-period correctness is covered by the unit tests in Tasks 2–3.

- [ ] **Step 3: Commit**

```bash
git add SnapceiptUITests/BasUITests.swift
git commit -m "test(bas): UI test for period stepper + history drill-in

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Full-suite green + branch verification

**Files:** none (verification only).

- [ ] **Step 1: Run the whole iOS unit suite**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests 2>&1 | grep -aE "Test run with|TEST (SUCCEEDED|FAILED)" | tail`
Expected: `** TEST SUCCEEDED **` (no regressions; new BasSchedule/BasHistory/BasViewModel tests included).

- [ ] **Step 2: Run the BAS UI tests**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptUITests/BasUITests 2>&1 | grep -aE "passed|failed|TEST (SUCCEEDED|FAILED)" | tail`
Expected: both existing BAS UI tests + the new one pass.

- [ ] **Step 3: No commit** (verification task). If anything failed, return to the owning task.
