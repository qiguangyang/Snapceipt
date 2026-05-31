# Reports & Insights (iOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Replace the stubbed Reports tab with a real, profile-scoped financial dashboard (net-saved trend, category donut, AU tax pills, logbook shortcuts, honest insight) plus an Export sheet (PDF/CSV share + accountant email) backed by a single `POST /export` call.

**Architecture:** Pure on-device SwiftData aggregation. Period/window math and all data computations live in PURE functions (`Period`, `TransactionQuery`, `InsightBuilder`) that take an INJECTED `now` (no hidden `Date()` — the bug class that bit capture). A `@MainActor @Observable ReportsViewModel` scopes by `activeProfileId` + selected `Period`, reads transactions + F1 `VehicleYear`/`WFHLog` claims, and exposes chart data + card values + insight. `ReportsView` (a tab, not an overlay) and `ExportSheet` (a non-fullscreen Router `.export` overlay through the existing `.sheet(item:)` mechanism) render them, reusing the unit-tested `BarPair`/`Donut`/`Segmented`/`Card`/`IconCircle`/`EmptyArt` primitives + the design system. The only networked part is `APIClient.export(...)` → `POST /export`.

**Tech Stack:** Swift 5.10, SwiftUI, SwiftData, Swift Testing (`import Testing`) for unit tests, XCTest/XCUITest for the hermetic UI test, xcodegen (`project.yml`), iPhone 16 simulator.

> **CRITICAL — Project generation (`xcodegen`), do this in EVERY task that creates a new file.**
> `Snapceipt.xcodeproj` is **xcodegen-generated and git-ignored** (`.gitignore` has `*.xcodeproj/`) and uses explicit `PBXFileReference` lists, NOT folder-synchronized groups. New `.swift` files are **NOT auto-picked-up by `xcodebuild`** — you MUST run `/opt/homebrew/bin/xcodegen generate` after creating ANY new file and BEFORE the next `xcodebuild`. The `project.yml` `sources` use directory globs (`path: Snapceipt`, `SnapceiptTests`, `SnapceiptUITests`), so regenerating re-globs and includes the new files. Because the project is git-ignored, **never `git add` the `.xcodeproj`** — the commit steps stage only source/test files. Scheme `Snapceipt`; targets `Snapceipt` / `SnapceiptTests` / `SnapceiptUITests`; `Snapceipt/Shared/AccessibilityID.swift` is shared into the UITest target (verified in `project.yml`). If you forget `xcodegen generate`, a new test file is silently absent from the target and reports "0 tests ran" — not a real FAIL.

> **Baseline to keep green:** `xcodebuild -only-testing:SnapceiptTests` ≈ 200 unit (the repo currently declares ~201 `@Test` cases across 44 files — treat "baseline" as "every existing test stays green", not an exact integer); `SnapceiptUITests` all green. There is NO known pre-existing failure. After the final task, the full suite must stay green (baseline + the 6 new unit suites + `ReportsUITests`).

> **Run command shape (used throughout):**
> ```
> /opt/homebrew/bin/xcodegen generate
> xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/<SuiteFile> -destination 'platform=iOS Simulator,name=iPhone 16' test
> ```
> The UI suite uses `-only-testing:SnapceiptUITests/ReportsUITests`.

---

## File structure

**Created (app):**
- `Snapceipt/Features/Reports/Period.swift` — `Period` enum + `Window` struct + pure `window(now:startMonth:)` month/quarter/FY math + label.
- `Snapceipt/Features/Reports/TransactionQuery.swift` — pure aggregators: `netSaved`, `monthlyTrend`, `byCategory`, `deductibleYTD`, `gstYTD` (all take plain snapshots + injected `now`).
- `Snapceipt/Features/Reports/InsightBuilder.swift` — pure mode-aware truthful heuristic string + empty fallback (NO network/AI).
- `Snapceipt/Features/Reports/ReportsViewModel.swift` — `@MainActor @Observable` VM: scope by `activeProfileId` + `Period`, reads txns + F1 claims, exposes chart data + cards + insight + business layout flag.
- `Snapceipt/Features/Reports/ReportsView.swift` — the Reports tab screen (header + Export pill, Segmented, net trend `BarPair`, `Donut`, business tax pills + logbook rows, insight card, empty/shimmer states).
- `Snapceipt/Features/Reports/ExportSheet.swift` — the `.export` overlay sheet (format tiles, detail card, Generate & send CTA, share sheet / accountant email).

**Modified (app):**
- `Snapceipt/Model/Entities/TaxSettings.swift` — add `accountantEmail: String?` field + init param.
- `Snapceipt/Sync/SyncEntityRegistry.swift` — extend `TaxSettingsSyncMapper.upsert` + `.payload` with `accountantEmail`.
- `Snapceipt/Sync/DTOs.swift` — add `ExportRequestBody`, `ExportDownloadResponse`, `ExportAccountantResponse`, `ExportResult`.
- `Snapceipt/Sync/APIClient.swift` — add `export(...)` to the `APIClient` protocol + `LiveAPIClient`.
- `Snapceipt/Sync/StubAPIClient.swift` — implement `export(...)` returning a deterministic stub result.
- `Snapceipt/App/Router.swift` — add `case export` to `Overlay`.
- `Snapceipt/App/RootView.swift` — render `ReportsView` in `tabContent`; add the `.export` case to the exhaustive `sheetContent(for:)` switch (placeholder in Task 7, real `ExportSheet` in Task 8); reuse the existing `captureAPI` for the Export sheet; add an `exportWindow` helper + `saveAccountantEmail`.
- `Snapceipt/App/AppLaunch.swift` — extend `applySeedIfNeeded` to seed transactions for the business profile (Reports UI test).
- `Snapceipt/Shared/AccessibilityID.swift` — add Reports + Export a11y ids.

**Created (tests):**
- `SnapceiptTests/PeriodTests.swift`
- `SnapceiptTests/TransactionQueryTests.swift`
- `SnapceiptTests/InsightBuilderTests.swift`
- `SnapceiptTests/ReportsViewModelTests.swift`
- `SnapceiptTests/ExportClientTests.swift`
- `SnapceiptUITests/ReportsUITests.swift`

**Modified (tests):**
- `SnapceiptTests/SyncMappingTests.swift` or new assertions — covered inside `ReportsViewModelTests` + the TaxSettings round-trip in Task 2 (see below).

---

### Task 1: `Period` window math (pure)

The AU-FY quarter mapping (Q1 Jul–Sep, Q2 Oct–Dec, Q3 Jan–Mar, Q4 Apr–Jun), month, and FY windows, all from an INJECTED `now`. Reuses `FinancialYear.of(_:startMonth:)` (verified: returns `Window` with `.start`, `.end`, `.startYear`, `.label`).

**Files:**
- Test: `SnapceiptTests/PeriodTests.swift` (Create)
- Create: `Snapceipt/Features/Reports/Period.swift`

- [ ] **Step 1: Write the FAILING test.** Create `SnapceiptTests/PeriodTests.swift`:
  ```swift
  import Testing
  import Foundation
  @testable import Snapceipt

  @Suite("Period")
  struct PeriodTests {
      /// UTC date helper (mirrors FinancialYear's parser).
      private func iso(_ s: String) -> Date {
          let f = DateFormatter()
          f.locale = Locale(identifier: "en_US_POSIX")
          f.timeZone = TimeZone(identifier: "UTC")
          f.dateFormat = "yyyy-MM-dd"
          return f.date(from: s)!
      }
      /// Read a window's bounds back as ISO strings for assertions.
      private func isoOut(_ d: Date) -> String {
          let f = DateFormatter()
          f.locale = Locale(identifier: "en_US_POSIX")
          f.timeZone = TimeZone(identifier: "UTC")
          f.dateFormat = "yyyy-MM-dd"
          return f.string(from: d)
      }

      @Test("month window is the calendar month of now, [start, nextMonth)")
      func monthWindow() {
          let w = Period.month.window(now: iso("2026-06-15"), startMonth: 7)
          #expect(isoOut(w.start) == "2026-06-01")
          #expect(isoOut(w.end) == "2026-07-01")
          #expect(w.label == "June 2026")
      }

      @Test("quarter window maps to AU FY quarters")
      func quarterWindows() {
          // June -> Q4 Apr-Jun
          let q4 = Period.quarter.window(now: iso("2026-06-15"), startMonth: 7)
          #expect(isoOut(q4.start) == "2026-04-01")
          #expect(isoOut(q4.end) == "2026-07-01")
          #expect(q4.label == "Apr–Jun 2026")
          // July -> Q1 Jul-Sep
          let q1 = Period.quarter.window(now: iso("2025-07-10"), startMonth: 7)
          #expect(isoOut(q1.start) == "2025-07-01")
          #expect(isoOut(q1.end) == "2025-10-01")
          #expect(q1.label == "Jul–Sep 2025")
          // January -> Q3 Jan-Mar
          let q3 = Period.quarter.window(now: iso("2026-01-20"), startMonth: 7)
          #expect(isoOut(q3.start) == "2026-01-01")
          #expect(isoOut(q3.end) == "2026-04-01")
          #expect(q3.label == "Jan–Mar 2026")
      }

      @Test("fy window reuses FinancialYear.of and its label")
      func fyWindow() {
          let w = Period.fy.window(now: iso("2026-06-30"), startMonth: 7)
          #expect(isoOut(w.start) == "2025-07-01")
          #expect(isoOut(w.end) == "2026-07-01")
          #expect(w.label == "FY2025-26")
          // 1 Jul flips to the next FY.
          let next = Period.fy.window(now: iso("2026-07-01"), startMonth: 7)
          #expect(next.label == "FY2026-27")
      }

      @Test("headline caption is period-appropriate")
      func headlineCaption() {
          #expect(Period.month.headline(now: iso("2026-06-15"), startMonth: 7) == "This month")
          #expect(Period.quarter.headline(now: iso("2026-06-15"), startMonth: 7) == "This quarter")
          #expect(Period.fy.headline(now: iso("2026-06-15"), startMonth: 7) == "FY2025-26")
      }
  }
  ```

- [ ] **Step 2: Run it — expect FAIL (compile error).**
  ```
  /opt/homebrew/bin/xcodegen generate
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/PeriodTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `cannot find 'Period' in scope`.

- [ ] **Step 3: Write the MINIMAL implementation.** Create `Snapceipt/Features/Reports/Period.swift`:
  ```swift
  import Foundation

  /// The Reports period control. `month`/`quarter`/`fy` rescope the donut + the
  /// headline net figure. Period = the CURRENT month / quarter / FY of an INJECTED
  /// `now` (no past-period navigation in v1, no hidden `Date()`). All dates are UTC
  /// to match the app's "yyyy-MM-dd" handling (Formatters.swift / FinancialYear).
  enum Period: String, CaseIterable, Equatable {
      case month
      case quarter
      case fy

      /// One period's window + display label.
      struct Window: Equatable {
          let start: Date    // inclusive, 00:00 UTC
          let end: Date      // exclusive, 00:00 UTC
          let label: String  // "June 2026" / "Apr–Jun 2026" / "FY2025-26"
      }

      private static var utcCalendar: Calendar {
          var c = Calendar(identifier: .gregorian)
          c.timeZone = TimeZone(identifier: "UTC")!
          return c
      }

      /// AU-FY quarter index 1...4 of `month` (Q1 Jul-Sep, Q2 Oct-Dec, Q3 Jan-Mar, Q4 Apr-Jun).
      private static func quarterIndex(month: Int) -> Int {
          // Months Jul(7)..Jun(6) -> 0..11 from FY start; /3 -> 0..3 -> +1.
          let offset = (month - 7 + 12) % 12
          return offset / 3 + 1
      }

      /// The window for this period containing `now`.
      func window(now: Date, startMonth: Int = 7) -> Window {
          let cal = Period.utcCalendar
          let comps = cal.dateComponents([.year, .month], from: now)
          let year = comps.year!
          let month = comps.month!

          switch self {
          case .month:
              let start = cal.date(from: DateComponents(year: year, month: month, day: 1))!
              let end = cal.date(byAdding: .month, value: 1, to: start)!
              return Window(start: start, end: end, label: Period.monthLabel(start))
          case .quarter:
              // The quarter's first month is the FY-quarter start nearest <= now.
              let qi = Period.quarterIndex(month: month)              // 1..4
              let firstMonthOfFY = startMonth                          // 7
              let qStartMonthRaw = (firstMonthOfFY - 1 + (qi - 1) * 3) % 12 + 1 // 7,10,1,4
              // Resolve the calendar year of the quarter start relative to `now`.
              let startYearAdjust = (month >= qStartMonthRaw) ? 0 : -1
              let qStart = cal.date(from: DateComponents(year: year + startYearAdjust,
                                                         month: qStartMonthRaw, day: 1))!
              let qEnd = cal.date(byAdding: .month, value: 3, to: qStart)!
              return Window(start: qStart, end: qEnd, label: Period.quarterLabel(qStart, qEnd))
          case .fy:
              let fy = FinancialYear.of(now, startMonth: startMonth)
              return Window(start: fy.start, end: fy.end, label: fy.label)
          }
      }

      /// The trend-card caption: "This month" / "This quarter" / "FY2025-26".
      func headline(now: Date, startMonth: Int = 7) -> String {
          switch self {
          case .month: return "This month"
          case .quarter: return "This quarter"
          case .fy: return FinancialYear.of(now, startMonth: startMonth).label
          }
      }

      private static let monthFmt: DateFormatter = makeFmt("MMMM yyyy")
      private static let monAbbrFmt: DateFormatter = makeFmt("MMM")
      private static let yearFmt: DateFormatter = makeFmt("yyyy")

      private static func makeFmt(_ fmt: String) -> DateFormatter {
          let f = DateFormatter()
          f.locale = Locale(identifier: "en_AU")
          f.timeZone = TimeZone(identifier: "UTC")
          f.dateFormat = fmt
          return f
      }

      private static func monthLabel(_ start: Date) -> String { monthFmt.string(from: start) }

      /// "Apr–Jun 2026" — abbreviated start/end month + the END month's year.
      private static func quarterLabel(_ start: Date, _ end: Date) -> String {
          let cal = utcCalendar
          let lastMonth = cal.date(byAdding: .month, value: -1, to: end)! // inclusive last month
          let a = monAbbrFmt.string(from: start)
          let b = monAbbrFmt.string(from: lastMonth)
          let yr = yearFmt.string(from: lastMonth)
          return "\(a)\u{2013}\(b) \(yr)"
      }
  }
  ```
  (The en-dash `\u{2013}` matches the spec's "Apr–Jun" / "Jan–Mar".)

- [ ] **Step 4: Run it — expect PASS.**
  ```
  /opt/homebrew/bin/xcodegen generate
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/PeriodTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `Test Suite 'PeriodTests' passed`, 4 tests.

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Features/Reports/Period.swift SnapceiptTests/PeriodTests.swift
  git commit -m "Add Period window math (month/quarter/FY) for Reports

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 2: `TaxSettings.accountantEmail` field + sync mapper

The single schema add of the cross-plan contract (spec §4.1): `accountant_email` D1 column / `accountantEmail` iOS field. The backend plan owns the migration + `syncTables.ts`; this task adds the iOS `@Model` field + extends `TaxSettingsSyncMapper`.

**Files:**
- Test: `SnapceiptTests/TaxSettingsAccountantTests.swift` (Create)
- Modify: `Snapceipt/Model/Entities/TaxSettings.swift` (lines 1–54)
- Modify: `Snapceipt/Sync/SyncEntityRegistry.swift` (`TaxSettingsSyncMapper`, lines ~659–685)

- [ ] **Step 1: Write the FAILING test.** Create `SnapceiptTests/TaxSettingsAccountantTests.swift`:
  ```swift
  import Testing
  import Foundation
  @testable import Snapceipt

  @Suite("TaxSettings.accountantEmail")
  struct TaxSettingsAccountantTests {
      @Test("init defaults accountantEmail to nil and stores a set value")
      func initStores() {
          let a = TaxSettings(userId: "u1", profileId: "p1")
          #expect(a.accountantEmail == nil)
          let b = TaxSettings(userId: "u1", profileId: "p1", accountantEmail: "cpa@firm.au")
          #expect(b.accountantEmail == "cpa@firm.au")
      }

      @Test("payload includes accountantEmail; null when nil")
      func payloadField() {
          let row = TaxSettings(userId: "u1", profileId: "p1", accountantEmail: "cpa@firm.au")
          let json = SyncEntityRegistry.shared.encodePayload(entityType: .taxSettings, entity: row)
          #expect(json.contains("\"accountantEmail\":\"cpa@firm.au\""))

          let empty = TaxSettings(userId: "u1", profileId: "p1")
          let json2 = SyncEntityRegistry.shared.encodePayload(entityType: .taxSettings, entity: empty)
          #expect(json2.contains("\"accountantEmail\":null"))
      }
  }
  ```

- [ ] **Step 2: Run it — expect FAIL.**
  ```
  /opt/homebrew/bin/xcodegen generate
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/TaxSettingsAccountantTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `extra argument 'accountantEmail' in call` / `value of type 'TaxSettings' has no member 'accountantEmail'`.

- [ ] **Step 3a: Add the field + init param to `TaxSettings`.** In `Snapceipt/Model/Entities/TaxSettings.swift`, add the stored property after `var mileageRateCentsPerKm: Int` (line 16):
  ```swift
      var accountantEmail: String?    // per-profile saved accountant address; nullable
  ```
  Add the init parameter after `mileageRateCentsPerKm: Int = 88,` (line 33):
  ```swift
          accountantEmail: String? = nil,
  ```
  Add the assignment after `self.mileageRateCentsPerKm = mileageRateCentsPerKm` (line 47):
  ```swift
          self.accountantEmail = accountantEmail
  ```

- [ ] **Step 3b: Extend `TaxSettingsSyncMapper`.** In `Snapceipt/Sync/SyncEntityRegistry.swift`, in `TaxSettingsSyncMapper.upsert`, after `if let v = env.int("mileageRateCentsPerKm") { row.mileageRateCentsPerKm = v }` (line 673):
  ```swift
          if let v = env.string("accountantEmail") { row.accountantEmail = v }
  ```
  In `TaxSettingsSyncMapper.payload`, after `f["mileageRateCentsPerKm"] = num(r.mileageRateCentsPerKm)` (line 682):
  ```swift
          f["accountantEmail"] = str(r.accountantEmail)
  ```
  (`str(_:)` is the file-private helper at line 103 that emits `.null` for nil.)

- [ ] **Step 4: Run it — expect PASS.**
  ```
  /opt/homebrew/bin/xcodegen generate
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/TaxSettingsAccountantTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `passed`, 2 tests.

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Model/Entities/TaxSettings.swift Snapceipt/Sync/SyncEntityRegistry.swift SnapceiptTests/TaxSettingsAccountantTests.swift
  git commit -m "Add TaxSettings.accountantEmail field + sync mapper round-trip

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 3: `TransactionQuery` aggregators (pure)

All five aggregators over plain `Txn` snapshots (no SwiftData), mirroring the `WFHCalc.Entry`/`MileageCalc.Trip` pure-snapshot pattern. Cents are `Int`; dates `"YYYY-MM-DD"`. `monthlyTrend` takes injected `now`; the rest take a `Period.Window`. Donut tints come from `CATS[catKey].tint` (verified table in `Categories.swift`).

**Files:**
- Test: `SnapceiptTests/TransactionQueryTests.swift` (Create)
- Create: `Snapceipt/Features/Reports/TransactionQuery.swift`

- [ ] **Step 1: Write the FAILING test.** Create `SnapceiptTests/TransactionQueryTests.swift`:
  ```swift
  import Testing
  import Foundation
  @testable import Snapceipt

  @Suite("TransactionQuery")
  struct TransactionQueryTests {
      private func iso(_ s: String) -> Date {
          let f = DateFormatter()
          f.locale = Locale(identifier: "en_US_POSIX")
          f.timeZone = TimeZone(identifier: "UTC")
          f.dateFormat = "yyyy-MM-dd"
          return f.date(from: s)!
      }

      /// A small FY25-26 fixture: income + expenses across meals/fuel/software.
      private func fixture() -> [TransactionQuery.Txn] {
          [
              .init(txnDate: "2026-06-02", amountCents: 500_00, catKey: "income", deductiblePct: nil, gstCents: nil),
              .init(txnDate: "2026-06-05", amountCents: -120_00, catKey: "meals", deductiblePct: 50, gstCents: 10_91),
              .init(txnDate: "2026-06-10", amountCents: -80_00, catKey: "fuel", deductiblePct: 100, gstCents: 7_27),
              .init(txnDate: "2026-05-20", amountCents: -40_00, catKey: "software", deductiblePct: 100, gstCents: 3_64),
          ]
      }

      @Test("netSaved over the window = income - expense")
      func netSaved() {
          let w = Period.month.window(now: iso("2026-06-15"), startMonth: 7) // June
          let r = TransactionQuery.netSaved(fixture(), window: w)
          #expect(r.incomeCents == 500_00)
          #expect(r.expenseCents == 200_00)        // 120 + 80 (May software excluded)
          #expect(r.netCents == 300_00)
      }

      @Test("byCategory groups expenses desc, excludes income + out-of-window")
      func byCategory() {
          let w = Period.month.window(now: iso("2026-06-15"), startMonth: 7)
          let rows = TransactionQuery.byCategory(fixture(), window: w)
          #expect(rows.count == 2)
          #expect(rows[0].catKey == "meals" && rows[0].spendCents == 120_00)
          #expect(rows[1].catKey == "fuel" && rows[1].spendCents == 80_00)
      }

      @Test("monthlyTrend returns the last 5 calendar months anchored to now")
      func monthlyTrend() {
          let bars = TransactionQuery.monthlyTrend(fixture(), now: iso("2026-06-15"))
          #expect(bars.count == 5)                 // Feb..Jun
          #expect(bars.last?.label == "Jun")
          // June: income 500, expense 200
          #expect(bars.last?.income == 500.0)
          #expect(bars.last?.expense == 200.0)
          // May: expense 40 (software), income 0
          #expect(bars[3].label == "May")
          #expect(bars[3].expense == 40.0)
      }

      @Test("deductibleYTD sums txn deductible + F1 vehicle + WFH claims")
      func deductibleYTD() {
          let fy = Period.fy.window(now: iso("2026-06-15"), startMonth: 7) // FY2025-26
          // meals 120 @50% = 6000c ; fuel 80 @100% = 8000c ; software 40 @100% = 4000c
          // + vehicle claims 250_00 + wfh claims 90_00
          let r = TransactionQuery.deductibleYTD(
              fixture(), fyWindow: fy,
              vehicleYearClaims: [250_00],
              wfhClaims: [60_00, 30_00])
          #expect(r == 60_00 + 80_00 + 40_00 + 250_00 + 90_00)
      }

      @Test("gstYTD sums gstCents over FY expenses")
      func gstYTD() {
          let fy = Period.fy.window(now: iso("2026-06-15"), startMonth: 7)
          let r = TransactionQuery.gstYTD(fixture(), fyWindow: fy)
          #expect(r == 10_91 + 7_27 + 3_64)
      }

      @Test("empty input is all-zero / empty")
      func empties() {
          let w = Period.month.window(now: iso("2026-06-15"), startMonth: 7)
          #expect(TransactionQuery.netSaved([], window: w).netCents == 0)
          #expect(TransactionQuery.byCategory([], window: w).isEmpty)
          #expect(TransactionQuery.monthlyTrend([], now: iso("2026-06-15")).count == 5)
          #expect(TransactionQuery.gstYTD([], fyWindow: w) == 0)
      }
  }
  ```

- [ ] **Step 2: Run it — expect FAIL.**
  ```
  /opt/homebrew/bin/xcodegen generate
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/TransactionQueryTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `cannot find 'TransactionQuery' in scope`.

- [ ] **Step 3: Write the MINIMAL implementation.** Create `Snapceipt/Features/Reports/TransactionQuery.swift`:
  ```swift
  import Foundation

  /// Pure SwiftData-free transaction aggregation for Reports. Callers pass plain
  /// `Txn` snapshots + a `Period.Window` (or injected `now`) so this stays
  /// unit-testable (no hidden `Date()`). All amounts are signed cents (expense < 0,
  /// income > 0); dates are "yyyy-MM-dd" UTC. (spec §4.6)
  enum TransactionQuery {
      /// A minimal transaction snapshot for aggregation.
      struct Txn: Equatable {
          let txnDate: String       // "yyyy-MM-dd"
          let amountCents: Int      // signed
          let catKey: String        // CategoryKey raw value or "custom"
          let deductiblePct: Int?
          let gstCents: Int?
      }

      struct Net: Equatable {
          let incomeCents: Int
          let expenseCents: Int
          let netCents: Int
      }

      private static let isoParser: DateFormatter = {
          let f = DateFormatter()
          f.locale = Locale(identifier: "en_US_POSIX")
          f.timeZone = TimeZone(identifier: "UTC")
          f.dateFormat = "yyyy-MM-dd"
          return f
      }()

      private static var utcCalendar: Calendar {
          var c = Calendar(identifier: .gregorian)
          c.timeZone = TimeZone(identifier: "UTC")!
          return c
      }

      /// True when `txnDate` parses and falls in [window.start, window.end).
      private static func inWindow(_ txnDate: String, _ window: Period.Window) -> Bool {
          guard let d = isoParser.date(from: txnDate) else { return false }
          return d >= window.start && d < window.end
      }

      /// income = Σ amount>0; expense = Σ −amount over amount<0; net = income − expense.
      static func netSaved(_ txns: [Txn], window: Period.Window) -> Net {
          var income = 0, expense = 0
          for t in txns where inWindow(t.txnDate, window) {
              if t.amountCents > 0 { income += t.amountCents }
              else if t.amountCents < 0 { expense += -t.amountCents }
          }
          return Net(incomeCents: income, expenseCents: expense, netCents: income - expense)
      }

      /// The last 5 calendar months anchored to `now`, each {label, income, expense}.
      /// Period-independent (drives the fixed `BarPair`).
      static func monthlyTrend(_ txns: [Txn], now: Date) -> [BarPairDatum] {
          let cal = utcCalendar
          let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
          let labelFmt = DateFormatter()
          labelFmt.locale = Locale(identifier: "en_AU")
          labelFmt.timeZone = TimeZone(identifier: "UTC")
          labelFmt.dateFormat = "MMM"

          var bars: [BarPairDatum] = []
          for offset in stride(from: -4, through: 0, by: 1) {
              let mStart = cal.date(byAdding: .month, value: offset, to: monthStart)!
              let mEnd = cal.date(byAdding: .month, value: 1, to: mStart)!
              var income = 0.0, expense = 0.0
              for t in txns {
                  guard let d = isoParser.date(from: t.txnDate), d >= mStart, d < mEnd else { continue }
                  if t.amountCents > 0 { income += Double(t.amountCents) / 100.0 }
                  else if t.amountCents < 0 { expense += Double(-t.amountCents) / 100.0 }
              }
              bars.append(BarPairDatum(label: labelFmt.string(from: mStart),
                                       income: income, expense: expense))
          }
          return bars
      }

      /// Expenses grouped by catKey, Σ −amount, sorted desc.
      static func byCategory(_ txns: [Txn], window: Period.Window) -> [(catKey: String, spendCents: Int)] {
          var sums: [String: Int] = [:]
          for t in txns where inWindow(t.txnDate, window) && t.amountCents < 0 {
              sums[t.catKey, default: 0] += -t.amountCents
          }
          return sums.map { ($0.key, $0.value) }
              .sorted { a, b in a.spendCents == b.spendCents ? a.catKey < b.catKey : a.spendCents > b.spendCents }
      }

      /// Σ round(−amount × pct/100) over FY expenses (when pct != nil) + Σ vehicle
      /// claims + Σ wfh claims. FY-to-date; period-independent.
      static func deductibleYTD(_ txns: [Txn], fyWindow: Period.Window,
                                vehicleYearClaims: [Int], wfhClaims: [Int]) -> Int {
          var total = 0
          for t in txns where inWindow(t.txnDate, fyWindow) && t.amountCents < 0 {
              guard let pct = t.deductiblePct else { continue }
              total += Int((Double(-t.amountCents) * Double(pct) / 100.0).rounded())
          }
          total += vehicleYearClaims.reduce(0, +)
          total += wfhClaims.reduce(0, +)
          return total
      }

      /// Σ gstCents over FY expenses. FY-to-date.
      static func gstYTD(_ txns: [Txn], fyWindow: Period.Window) -> Int {
          var total = 0
          for t in txns where inWindow(t.txnDate, fyWindow) && t.amountCents < 0 {
              total += t.gstCents ?? 0
          }
          return total
      }
  }
  ```
  (`BarPairDatum` is the verified primitive: `init(label:income:expense:)`, `income`/`expense` are `Double` dollars — see `BarPair.swift`.)

- [ ] **Step 4: Run it — expect PASS.**
  ```
  /opt/homebrew/bin/xcodegen generate
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/TransactionQueryTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `passed`, 7 tests.

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Features/Reports/TransactionQuery.swift SnapceiptTests/TransactionQueryTests.swift
  git commit -m "Add TransactionQuery aggregators (netSaved/trend/byCategory/deductibleYTD/gstYTD)

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 4: `InsightBuilder` (pure, truthful, mode-aware)

A real, always-truthful heuristic computed on-device: top category this period and/or a period-over-period delta, with an empty-data fallback. NO AI/network. Mode-aware tone (Business vs Personal). Reuses `CATS[key].label` (verified) + `fmt(_:)` (verified, `fmt(Int)` → "$120.00").

**Files:**
- Test: `SnapceiptTests/InsightBuilderTests.swift` (Create)
- Create: `Snapceipt/Features/Reports/InsightBuilder.swift`

- [ ] **Step 1: Write the FAILING test.** Create `SnapceiptTests/InsightBuilderTests.swift`:
  ```swift
  import Testing
  import Foundation
  @testable import Snapceipt

  @Suite("InsightBuilder")
  struct InsightBuilderTests {
      private func iso(_ s: String) -> Date {
          let f = DateFormatter()
          f.locale = Locale(identifier: "en_US_POSIX")
          f.timeZone = TimeZone(identifier: "UTC")
          f.dateFormat = "yyyy-MM-dd"
          return f.date(from: s)!
      }

      private func fixtureThisMonth() -> [TransactionQuery.Txn] {
          [
              .init(txnDate: "2026-06-05", amountCents: -120_00, catKey: "meals", deductiblePct: 50, gstCents: nil),
              .init(txnDate: "2026-06-10", amountCents: -80_00, catKey: "fuel", deductiblePct: 100, gstCents: nil),
          ]
      }
      private func fixturePrevMonth() -> [TransactionQuery.Txn] {
          [ .init(txnDate: "2026-05-09", amountCents: -300_00, catKey: "meals", deductiblePct: 50, gstCents: nil) ]
      }

      @Test("empty data -> onboarding fallback")
      func emptyFallback() {
          let w = Period.month.window(now: iso("2026-06-15"), startMonth: 7)
          let prev = Period.month.window(now: iso("2026-05-15"), startMonth: 7)
          let s = InsightBuilder.insight(mode: .business, txns: [], window: w, prevWindow: prev)
          #expect(s == "Add a few receipts and your insights will appear here.")
      }

      @Test("names the top category this period with its amount")
      func topCategory() {
          let w = Period.month.window(now: iso("2026-06-15"), startMonth: 7)
          let prev = Period.month.window(now: iso("2026-05-15"), startMonth: 7)
          let s = InsightBuilder.insight(mode: .business, txns: fixtureThisMonth(),
                                         window: w, prevWindow: prev)
          #expect(s.contains("Meals & Coffee"))
          #expect(s.contains("$120.00"))
      }

      @Test("reports a period-over-period delta when prior data exists")
      func delta() {
          let w = Period.month.window(now: iso("2026-06-15"), startMonth: 7)
          let prev = Period.month.window(now: iso("2026-05-15"), startMonth: 7)
          let all = fixtureThisMonth() + fixturePrevMonth()
          // This month spend 200, last month 300 -> spent 100 less.
          let s = InsightBuilder.insight(mode: .personal, txns: all, window: w, prevWindow: prev)
          #expect(s.contains("less"))
          #expect(s.contains("$100.00"))
      }
  }
  ```

- [ ] **Step 2: Run it — expect FAIL.**
  ```
  /opt/homebrew/bin/xcodegen generate
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/InsightBuilderTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `cannot find 'InsightBuilder' in scope`.

- [ ] **Step 3: Write the MINIMAL implementation.** Create `Snapceipt/Features/Reports/InsightBuilder.swift`:
  ```swift
  import Foundation

  /// On-device, always-truthful, mode-aware insight for the Reports card. Computes a
  /// top-category line and/or a period-over-period delta from the period's data. NO
  /// network / AI (spec defers real AI insights beyond v1). (spec §4.6)
  enum InsightBuilder {
      enum Mode { case business, personal }

      /// Build the insight string. `window` is the current period; `prevWindow` is the
      /// same-length immediately-prior period (used for the delta). Empty data -> fallback.
      static func insight(mode: Mode, txns: [TransactionQuery.Txn],
                          window: Period.Window, prevWindow: Period.Window) -> String {
          let cats = TransactionQuery.byCategory(txns, window: window)
          guard let top = cats.first else {
              return "Add a few receipts and your insights will appear here."
          }

          let label = catLabel(top.catKey)
          let periodWord = (mode == .business) ? "period" : "month"
          var line = "\(label) is your biggest expense this \(periodWord) — \(fmt(top.spendCents))."

          // Period-over-period delta (current vs prior window total expense).
          let cur = TransactionQuery.netSaved(txns, window: window).expenseCents
          let prevTotal = TransactionQuery.netSaved(txns, window: prevWindow).expenseCents
          if prevTotal > 0 {
              let diff = cur - prevTotal
              if diff != 0 {
                  let dir = diff < 0 ? "less" : "more"
                  line += " You spent \(fmt(abs(diff))) \(dir) than last \(periodWord)."
              }
          }
          return line
      }

      /// Human label for a catKey via CATS, falling back to the raw key.
      private static func catLabel(_ key: String) -> String {
          if let ck = CategoryKey(rawValue: key), let meta = CATS[ck] { return meta.label }
          return key.capitalized
      }
  }
  ```

- [ ] **Step 4: Run it — expect PASS.**
  ```
  /opt/homebrew/bin/xcodegen generate
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/InsightBuilderTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `passed`, 3 tests.

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Features/Reports/InsightBuilder.swift SnapceiptTests/InsightBuilderTests.swift
  git commit -m "Add InsightBuilder (truthful mode-aware on-device insight)

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 5: `ReportsViewModel` (scope + reads + exposed view state)

A `@MainActor @Observable` VM mirroring `WFHViewModel`'s shape (injected `context`, `userId`, `profileId`, `startMonth`; reads via `FetchDescriptor` filtered by `profileId && deletedAt == nil`). Injects `now` (default `Date()`) so tests are deterministic. Reads transactions + F1 `VehicleYear`/`WFHLog` claims, exposes chart data + card values + insight + a Business-vs-Personal layout flag (any non-`personal` profile type ⇒ business).

**Files:**
- Test: `SnapceiptTests/ReportsViewModelTests.swift` (Create)
- Create: `Snapceipt/Features/Reports/ReportsViewModel.swift`

- [ ] **Step 1: Write the FAILING test.** Create `SnapceiptTests/ReportsViewModelTests.swift`:
  ```swift
  import Testing
  import Foundation
  import SwiftData
  @testable import Snapceipt

  @MainActor
  @Suite("ReportsViewModel")
  struct ReportsViewModelTests {
      private func iso(_ s: String) -> Date {
          let f = DateFormatter()
          f.locale = Locale(identifier: "en_US_POSIX")
          f.timeZone = TimeZone(identifier: "UTC")
          f.dateFormat = "yyyy-MM-dd"
          return f.date(from: s)!
      }

      private func makeCtx() throws -> ModelContext {
          let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
          return ModelContext(container)
      }

      /// Seed a business profile p1 + a personal profile p2, plus scoped data.
      private func seed(_ ctx: ModelContext) {
          ctx.insert(Profile(userId: "u1", name: "Studio", type: "business",
                             accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950"))
          // p1 txns
          ctx.insert(Transaction(userId: "u1", profileId: "p1", catKey: "income",
                                 amountCents: 500_00, txnDate: "2026-06-02"))
          ctx.insert(Transaction(userId: "u1", profileId: "p1", catKey: "meals",
                                 amountCents: -120_00, txnDate: "2026-06-05",
                                 deductiblePct: 50, gstCents: 10_91))
          // other-profile txn -> must be excluded
          ctx.insert(Transaction(userId: "u1", profileId: "p2", catKey: "meals",
                                 amountCents: -999_00, txnDate: "2026-06-06"))
          // F1 claims for p1, FY2025-26
          ctx.insert(VehicleYear(userId: "u1", profileId: "p1", vehicleId: "v1",
                                 fyStartYear: 2025, claimCents: 250_00))
          ctx.insert(WFHLog(userId: "u1", profileId: "p1", logDate: "2026-05-10",
                            minutes: 480, claimCents: 90_00))
          try? ctx.save()
      }

      @Test("scopes by profile + computes net for the selected period")
      func netForPeriod() throws {
          let ctx = try makeCtx(); seed(ctx)
          let vm = ReportsViewModel(context: ctx, userId: "u1", profileId: "p1",
                                    startMonth: 7, now: iso("2026-06-15"))
          vm.period = .month
          #expect(vm.netCents == 380_00)          // 500 income - 120 meals (p2's 999 excluded)
          #expect(vm.donutSegments.count == 1)     // meals only
          #expect(vm.barData.count == 5)
      }

      @Test("deductible/gst pills include F1 claims, FY-to-date")
      func taxPills() throws {
          let ctx = try makeCtx(); seed(ctx)
          let vm = ReportsViewModel(context: ctx, userId: "u1", profileId: "p1",
                                    startMonth: 7, now: iso("2026-06-15"))
          // meals 120 @50% = 6000c + vehicle 250_00 + wfh 90_00
          #expect(vm.deductibleYTDCents == 60_00 + 250_00 + 90_00)
          #expect(vm.gstYTDCents == 10_91)
      }

      @Test("business layout flag is true for a non-personal profile")
      func businessLayout() throws {
          let ctx = try makeCtx(); seed(ctx)
          let vm = ReportsViewModel(context: ctx, userId: "u1", profileId: "p1",
                                    startMonth: 7, now: iso("2026-06-15"))
          #expect(vm.isBusiness == true)
      }

      @Test("personal profile -> business layout flag false")
      func personalLayout() throws {
          let ctx = try makeCtx()
          ctx.insert(Profile(userId: "u1", name: "Home", type: "personal",
                             accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A"))
          try? ctx.save()
          // find its id
          let p = try ctx.fetch(FetchDescriptor<Profile>()).first!
          let vm = ReportsViewModel(context: ctx, userId: "u1", profileId: p.id,
                                    startMonth: 7, now: iso("2026-06-15"))
          #expect(vm.isBusiness == false)
      }

      @Test("changing period recomputes the donut + net")
      func periodRecompute() throws {
          let ctx = try makeCtx(); seed(ctx)
          let vm = ReportsViewModel(context: ctx, userId: "u1", profileId: "p1",
                                    startMonth: 7, now: iso("2026-06-15"))
          vm.period = .month
          let monthNet = vm.netCents
          vm.period = .fy
          // FY includes the same June rows here, so net unchanged but recompute ran.
          #expect(vm.netCents == monthNet)
          #expect(vm.insight.isEmpty == false)
      }
  }
  ```
  NOTE: `Profile.id` defaults to a UUIDv7, so the test seeds `profileId: "p1"` on transactions directly and inserts a `Profile` whose `type` the VM reads via a fetch on its OWN `profileId`. To make `netForPeriod`/`taxPills`/`businessLayout` deterministic, the seed's `Profile` must have `id == "p1"`. Adjust the seed insert to set the id:
  ```swift
          let prof = Profile(userId: "u1", name: "Studio", type: "business",
                             accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950")
          prof.id = "p1"
          ctx.insert(prof)
  ```
  (Replace the first `ctx.insert(Profile(...))` line in `seed` with the three lines above.)

- [ ] **Step 2: Run it — expect FAIL.**
  ```
  /opt/homebrew/bin/xcodegen generate
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/ReportsViewModelTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `cannot find 'ReportsViewModel' in scope`.

- [ ] **Step 3: Write the MINIMAL implementation.** Create `Snapceipt/Features/Reports/ReportsViewModel.swift`:
  ```swift
  import Foundation
  import SwiftData
  import Observation
  import SwiftUI

  /// Drives the Reports tab: loads the active profile's transactions + F1 logbook
  /// claims, then exposes chart data + card values + the insight for the selected
  /// `Period`. `@MainActor`; deps injected for tests. `now` is injected (no hidden
  /// `Date()`) so windows are deterministic. (spec §5)
  @Observable
  @MainActor
  final class ReportsViewModel {
      @ObservationIgnored private let context: ModelContext
      @ObservationIgnored private let userId: String
      @ObservationIgnored let profileId: String
      @ObservationIgnored private let startMonth: Int
      @ObservationIgnored private let now: Date

      /// Selected period; setting it recomputes the period-scoped outputs.
      var period: Period = .month { didSet { recompute() } }

      /// True when the active profile is anything other than "personal".
      private(set) var isBusiness: Bool = false

      // Period-scoped outputs.
      private(set) var netCents: Int = 0
      private(set) var incomeCents: Int = 0
      private(set) var expenseCents: Int = 0
      private(set) var donutSegments: [DonutSegment] = []
      private(set) var legend: [(catKey: String, spendCents: Int)] = []
      private(set) var donutTotalCents: Int = 0
      private(set) var insight: String = ""

      // Fixed / FY-to-date outputs.
      private(set) var barData: [BarPairDatum] = []
      private(set) var deductibleYTDCents: Int = 0
      private(set) var gstYTDCents: Int = 0

      /// Active-profile FY logbook hero numbers for the logbook rows.
      private(set) var vehicleClaimCents: Int = 0
      private(set) var wfhClaimCents: Int = 0

      private var txns: [TransactionQuery.Txn] = []

      init(context: ModelContext, userId: String, profileId: String,
           startMonth: Int, now: Date = Date()) {
          self.context = context
          self.userId = userId
          self.profileId = profileId
          self.startMonth = startMonth
          self.now = now
          load()
      }

      /// The trend-card caption ("This month" / "This quarter" / "FY2025-26").
      var headline: String { period.headline(now: now, startMonth: startMonth) }
      /// The current period's range label (for the donut + export).
      var periodLabel: String { period.window(now: now, startMonth: startMonth).label }
      /// FY start year for the active profile's FY claims.
      var fyStartYear: Int { FinancialYear.of(now, startMonth: startMonth).startYear }

      func load() {
          let pid = profileId
          // Profile type -> layout flag.
          var pd = FetchDescriptor<Profile>(predicate: #Predicate { $0.id == pid })
          pd.fetchLimit = 1
          isBusiness = ((try? context.fetch(pd))?.first?.type ?? "personal") != "personal"

          // Transactions for this profile.
          let td = FetchDescriptor<Transaction>(
              predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
          let rows = (try? context.fetch(td)) ?? []
          txns = rows.map {
              TransactionQuery.Txn(txnDate: $0.txnDate, amountCents: $0.amountCents,
                                   catKey: $0.catKey, deductiblePct: $0.deductiblePct,
                                   gstCents: $0.gstCents)
          }

          // F1 vehicle-year claims for the active profile + current FY.
          let fy = fyStartYear
          let vd = FetchDescriptor<VehicleYear>(
              predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil && $0.fyStartYear == fy })
          let vehicleClaims = ((try? context.fetch(vd)) ?? []).compactMap { $0.claimCents }
          vehicleClaimCents = vehicleClaims.reduce(0, +)

          // F1 WFH claims for the active profile (FY-filtered below via deductibleYTD).
          let wd = FetchDescriptor<WFHLog>(
              predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
          let wfhLogs = (try? context.fetch(wd)) ?? []
          let fyWindow = Period.fy.window(now: now, startMonth: startMonth)
          let wfhClaimsInFY: [Int] = wfhLogs.compactMap { log in
              guard FinancialYear.isIn(log.logDate, fyStartYear: fy, startMonth: startMonth) else { return nil }
              return log.claimCents
          }
          wfhClaimCents = wfhClaimsInFY.reduce(0, +)

          // FY-to-date pills (period-independent).
          deductibleYTDCents = TransactionQuery.deductibleYTD(
              txns, fyWindow: fyWindow, vehicleYearClaims: vehicleClaims, wfhClaims: wfhClaimsInFY)
          gstYTDCents = TransactionQuery.gstYTD(txns, fyWindow: fyWindow)

          // Fixed rolling-5 trend.
          barData = TransactionQuery.monthlyTrend(txns, now: now)

          recompute()
      }

      /// Recompute the period-scoped outputs (net headline, donut, insight).
      private func recompute() {
          let window = period.window(now: now, startMonth: startMonth)
          let net = TransactionQuery.netSaved(txns, window: window)
          netCents = net.netCents
          incomeCents = net.incomeCents
          expenseCents = net.expenseCents

          legend = TransactionQuery.byCategory(txns, window: window)
          donutTotalCents = legend.reduce(0) { $0 + $1.spendCents }
          donutSegments = legend.prefix(5).map { row in
              DonutSegment(id: row.catKey, value: Double(row.spendCents), tint: tint(row.catKey))
          }

          // Prior window = the same period one step earlier (for the delta).
          let prevNow = prevAnchor(window: window)
          let prevWindow = period.window(now: prevNow, startMonth: startMonth)
          insight = InsightBuilder.insight(mode: isBusiness ? .business : .personal,
                                           txns: txns, window: window, prevWindow: prevWindow)
      }

      /// An anchor date inside the immediately-prior period (one day before this
      /// window's start), so `Period.window(now:)` resolves the previous window.
      private func prevAnchor(window: Period.Window) -> Date {
          window.start.addingTimeInterval(-86_400)
      }

      private func tint(_ catKey: String) -> Color {
          if let ck = CategoryKey(rawValue: catKey), let meta = CATS[ck] { return meta.tint }
          return Palette.ink3
      }
  }
  ```
  (`DonutSegment(id:value:tint:)` and `Palette.ink3` are verified. `FinancialYear.isIn(_:fyStartYear:startMonth:)` is verified.)

- [ ] **Step 4: Run it — expect PASS.**
  ```
  /opt/homebrew/bin/xcodegen generate
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/ReportsViewModelTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `passed`, 5 tests.

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Features/Reports/ReportsViewModel.swift SnapceiptTests/ReportsViewModelTests.swift
  git commit -m "Add ReportsViewModel (profile+period scoping, F1 claim sums, layout flag)

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 6: `APIClient.export(...)` + DTOs + stub

Add the `export(...)` method to the `APIClient` protocol, `LiveAPIClient` (POST `/export`, the spec §4.2 contract), and `StubAPIClient`. The request is `{ profileId, format, from, to, toEmail? }`; the response is either `{ url, expiresAt }` (pdf/csv) or `{ status, outboxId }` (accountant). Both shapes decode into one `ExportResult` enum.

**Files:**
- Test: `SnapceiptTests/ExportClientTests.swift` (Create)
- Modify: `Snapceipt/Sync/DTOs.swift` (add bodies/responses after line 52)
- Modify: `Snapceipt/Sync/APIClient.swift` (protocol line ~18; `LiveAPIClient` after `uploadImage`, ~line 109)
- Modify: `Snapceipt/Sync/StubAPIClient.swift` (add `export`)

- [ ] **Step 1: Write the FAILING test.** Create `SnapceiptTests/ExportClientTests.swift`:
  ```swift
  import Foundation
  import Testing
  @testable import Snapceipt

  @Suite(.serialized)
  struct ExportClientTests {
      private func makeClient() -> LiveAPIClient {
          let auth = AuthStore()
          auth.clear()
          auth.save(SessionResponse(accessToken: "acc", refreshToken: "refresh-0123456789abcdef0123456789abcdef",
                                    expiresIn: 900, user: SessionUser(id: "u1", email: "a@b.com", displayName: "Ada")))
          return LiveAPIClient(baseURL: URL(string: "https://api.test")!, auth: auth,
                               session: MockURLProtocol.makeSession())
      }
      private func json(_ s: String) -> Data { Data(s.utf8) }

      @Test("csv export decodes the download result + posts the right body")
      func csvDownload() async throws {
          let client = makeClient()
          MockURLProtocol.setHandler { _ in
              (200, ["Content-Type": "application/json"],
               self.json(#"{"url":"/export/dl/tok123","expiresAt":1790000000}"#))
          }
          let result = try await client.export(profileId: "p1", format: "csv",
                                                from: "2026-06-01", to: "2026-06-30", toEmail: nil)
          guard case let .download(url, expiresAt) = result else {
              Issue.record("expected .download"); return
          }
          #expect(url == "/export/dl/tok123")
          #expect(expiresAt == 1790000000)
          #expect(MockURLProtocol.lastRequest?.url?.path == "/export")
          #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
      }

      @Test("accountant export decodes the sent result")
      func accountantSent() async throws {
          let client = makeClient()
          MockURLProtocol.setHandler { _ in
              (200, [:], self.json(#"{"status":"sent","outboxId":"ob-9"}"#))
          }
          let result = try await client.export(profileId: "p1", format: "accountant",
                                               from: "2026-06-01", to: "2026-06-30", toEmail: "cpa@firm.au")
          guard case let .sent(status, outboxId) = result else {
              Issue.record("expected .sent"); return
          }
          #expect(status == "sent")
          #expect(outboxId == "ob-9")
      }

      @Test("a backend error surfaces as APIError")
      func validationError() async throws {
          let client = makeClient()
          MockURLProtocol.setHandler { _ in
              // Backend maps VALIDATION_FAILED -> 400 (src/lib/errors.ts); the
              // backend plan returns 400 for from > to. Match that contract here.
              (400, [:], self.json(#"{"error":{"code":"VALIDATION_FAILED","message":"from > to","requestId":"r1"}}"#))
          }
          do {
              _ = try await client.export(profileId: "p1", format: "csv",
                                          from: "2026-06-30", to: "2026-06-01", toEmail: nil)
              Issue.record("expected throw")
          } catch let e as APIError {
              #expect(e.code == "VALIDATION_FAILED")
              #expect(e.status == 400)
          }
      }
  }
  ```

- [ ] **Step 2: Run it — expect FAIL.**
  ```
  /opt/homebrew/bin/xcodegen generate
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/ExportClientTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `value of type ... has no member 'export'`.

- [ ] **Step 3a: Add DTOs.** In `Snapceipt/Sync/DTOs.swift`, after the `RefreshBody` block (line 52), add:
  ```swift
  // MARK: - Export (spec §4.2)

  /// POST /export body: { profileId, format, from, to, toEmail? }.
  /// `toEmail` required iff format == "accountant".
  struct ExportRequestBody: Encodable {
      let profileId: String
      let format: String    // "pdf" | "csv" | "accountant"
      let from: String      // "YYYY-MM-DD"
      let to: String        // "YYYY-MM-DD"
      var toEmail: String?
  }

  /// Decoded POST /export response (the union of both server shapes; one side present).
  /// pdf/csv -> { url, expiresAt }; accountant -> { status, outboxId }.
  struct ExportResponse: Decodable {
      let url: String?
      let expiresAt: Int?
      let status: String?
      let outboxId: String?
  }

  /// The normalized export outcome the UI consumes.
  enum ExportResult: Equatable {
      case download(url: String, expiresAt: Int)
      case sent(status: String, outboxId: String)
  }
  ```

- [ ] **Step 3b: Add to the `APIClient` protocol.** In `Snapceipt/Sync/APIClient.swift`, after `func uploadImage(...)` (line 18), add:
  ```swift
      /// POST /export — generate a CSV/PDF (share via the returned download url) or
      /// email the accountant pack. Returns the normalized `ExportResult`. (spec §4.2)
      func export(profileId: String, format: String, from: String, to: String,
                  toEmail: String?) async throws -> ExportResult
  ```

- [ ] **Step 3c: Implement in `LiveAPIClient`.** In `Snapceipt/Sync/APIClient.swift`, after the `uploadImage` method (after line 109), add:
  ```swift
      func export(profileId: String, format: String, from: String, to: String,
                  toEmail: String?) async throws -> ExportResult {
          let body = ExportRequestBody(profileId: profileId, format: format,
                                       from: from, to: to, toEmail: toEmail)
          let resp: ExportResponse = try await send("POST", "/export", body: body, authenticated: true)
          if let url = resp.url, let expiresAt = resp.expiresAt {
              return .download(url: url, expiresAt: expiresAt)
          }
          if let status = resp.status, let outboxId = resp.outboxId {
              return .sent(status: status, outboxId: outboxId)
          }
          throw APIError.decoding
      }
  ```

- [ ] **Step 3d: Implement in `StubAPIClient`.** In `Snapceipt/Sync/StubAPIClient.swift`, before the closing `}` of the class (after `uploadImage`, line 47), add:
  ```swift
      func export(profileId: String, format: String, from: String, to: String,
                  toEmail: String?) async throws -> ExportResult {
          // Deterministic stub for the hermetic UI test (no network).
          if format == "accountant" {
              return .sent(status: "sent", outboxId: "stub-outbox")
          }
          return .download(url: "/export/dl/stub-token", expiresAt: 1_790_000_000)
      }
  ```

- [ ] **Step 4: Run it — expect PASS.**
  ```
  /opt/homebrew/bin/xcodegen generate
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/ExportClientTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `passed`, 3 tests.

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Sync/DTOs.swift Snapceipt/Sync/APIClient.swift Snapceipt/Sync/StubAPIClient.swift SnapceiptTests/ExportClientTests.swift
  git commit -m "Add APIClient.export(...) + export DTOs + stub

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 7: a11y ids + Router `.export` overlay + ExportSheet

Add the Reports/Export accessibility identifiers, the `.export` overlay case (routed through the EXISTING non-fullscreen `.sheet(item:)` mechanism — like `profilePicker`/`addProfile`), and the `ExportSheet` view. The ExportSheet takes an injected `APIClient`, the current period range (`from`/`to`/label), a deductible-total, a transactions-in-range count, a saved accountant email + a save callback, and a `profileName`.

**Files:**
- Modify: `Snapceipt/Shared/AccessibilityID.swift` (after line 68)
- Modify: `Snapceipt/App/Router.swift` (`Overlay` enum, lines 11–19)
- Modify: `Snapceipt/App/RootView.swift` (`sheetContent(for:)` exhaustive switch, line 280 — add the placeholder `.export` case so the app keeps compiling; Task 8 replaces it)
- Create: `Snapceipt/Features/Reports/ExportSheet.swift`

- [ ] **Step 1: Add the a11y ids.** In `Snapceipt/Shared/AccessibilityID.swift`, before the closing `}` (after line 68), add:
  ```swift

      // Reports
      static let reportsScreen = "reports.screen"
      static let reportsExportPill = "reports.exportPill"
      static let reportsPeriod = "reports.period"
      static let reportsNet = "reports.net"
      static let reportsDonut = "reports.donut"
      static let reportsDeductiblePill = "reports.pill.deductible"
      static let reportsGstPill = "reports.pill.gst"
      static let reportsLogbookVehicle = "reports.logbook.vehicle"
      static let reportsLogbookWFH = "reports.logbook.wfh"
      static let reportsInsight = "reports.insight"

      // Export sheet
      static let exportSheet = "export.sheet"
      static let exportFormatPDF = "export.format.pdf"
      static let exportFormatCSV = "export.format.csv"
      static let exportFormatAccountant = "export.format.accountant"
      static let exportEmailField = "export.emailField"
      static let exportGenerate = "export.generate"
      static let exportStatus = "export.status"
  ```

- [ ] **Step 2: Add the `.export` overlay case + keep RootView compiling.** In `Snapceipt/App/Router.swift`, add a case to `Overlay` (after `case wfh`, line 16):
  ```swift
      case export
  ```
  **CRITICAL — `sheetContent(for:)` is an EXHAUSTIVE switch over `Overlay` (RootView.swift line 280, no `default`).** Adding `.export` to the enum makes that switch non-exhaustive and the **app target stops compiling** (this task's Step 4 build would fail). So in the SAME edit, add a *temporary placeholder* case to `Snapceipt/App/RootView.swift` `sheetContent(for:)` — insert it right before `case .capture:` (line 290). Task 8 replaces this placeholder with the real `ExportSheet(...)` call:
  ```swift
        case .export:
            EmptyView()  // real ExportSheet wired in Task 8
  ```
  (`sheetBinding`'s `get` uses `default` and its `set` uses a `Set<Overlay>`, so neither needs editing here — `.export` already falls through `get`'s `default` to be presented as a non-fullscreen sheet, and is NOT in the `fullScreen` set so swipe-to-dismiss clears the router. Only the exhaustive `sheetContent` switch must learn `.export`.)

- [ ] **Step 3: Write the `ExportSheet` view.** Create `Snapceipt/Features/Reports/ExportSheet.swift`:
  ```swift
  import SwiftUI

  /// Bottom-sheet export flow (spec §6). Format tiles (PDF default / CSV / accountant),
  /// a detail card scoped to the current Reports period, and a Generate & send CTA that
  /// calls `POST /export`. pdf/csv -> share sheet on the returned URL; accountant ->
  /// email the saved/edited accountant address (saved back on success). Presented as a
  /// non-fullscreen Router `.export` overlay via the shell's `.sheet(item:)`.
  struct ExportSheet: View {
      let api: APIClient
      let profileId: String
      let profileName: String
      /// The current Reports period range + label (spec §3.8: export inherits the period).
      let from: String
      let to: String
      let periodLabel: String
      let receiptsCount: Int
      let deductibleCents: Int
      /// Saved per-profile accountant email (prefill) + a persist-on-success callback.
      let savedAccountantEmail: String?
      let onSaveAccountantEmail: (String) -> Void
      let onClose: () -> Void

      @Environment(\.accent) private var accent

      private enum Format: String { case pdf, csv, accountant }
      private enum Phase: Equatable { case idle, inProgress, error(String) }

      @State private var format: Format = .pdf
      @State private var email: String = ""
      @State private var phase: Phase = .idle
      @State private var shareURL: URL?

      var body: some View {
          VStack(spacing: 0) {
              header
              ScrollView {
                  VStack(spacing: 14) {
                      formatTiles
                      detailCard
                      if format == .accountant { emailField }
                      cta
                      statusLine
                  }
                  .padding(18)
              }
          }
          .frame(maxHeight: .infinity, alignment: .top)
          .background(Palette.cream)
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier(AccessibilityID.exportSheet)
          .onAppear { email = savedAccountantEmail ?? "" }
          .sheet(item: shareItem) { item in ActivityView(url: item.url) }
      }

      private var header: some View {
          HStack {
              Text("Export").font(.display(22)).foregroundStyle(Palette.ink)
              Spacer()
              Button { onClose() } label: {
                  Icon(name: "close", size: 18, color: Palette.ink2)
              }.buttonStyle(.plain)
          }
          .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 6)
      }

      private var formatTiles: some View {
          HStack(spacing: 10) {
              tile(.pdf, title: "PDF report", icon: "receipt", id: AccessibilityID.exportFormatPDF)
              tile(.csv, title: "CSV file", icon: "chart", id: AccessibilityID.exportFormatCSV)
              tile(.accountant, title: "To accountant", icon: "bell", id: AccessibilityID.exportFormatAccountant)
          }
      }

      private func tile(_ f: Format, title: String, icon: String, id: String) -> some View {
          let selected = format == f
          return Button { format = f } label: {
              VStack(spacing: 8) {
                  IconCircle(name: icon, tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
                  Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink)
                      .multilineTextAlignment(.center)
              }
              .frame(maxWidth: .infinity).padding(.vertical, 14)
              .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
              .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                  .strokeBorder(selected ? accent.base : Palette.line2, lineWidth: selected ? 2 : 1))
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier(id)
      }

      private var detailCard: some View {
          Card {
              VStack(spacing: 10) {
                  detailRow("Period", periodLabel)
                  detailRow("Receipts included", "\(receiptsCount)")
                  detailRow("Deductible total", fmt(deductibleCents))
              }
          }
      }

      private func detailRow(_ label: String, _ value: String) -> some View {
          HStack {
              Text(label).font(.ui(13.5)).foregroundStyle(Palette.ink2)
              Spacer()
              Text(value).font(.ui(14, .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
          }
      }

      private var emailField: some View {
          Card {
              VStack(alignment: .leading, spacing: 6) {
                  Text("Accountant email").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink2)
                  TextField("name@firm.com.au", text: $email)
                      .font(.ui(15)).foregroundStyle(Palette.ink)
                      .textInputAutocapitalization(.never)
                      .keyboardType(.emailAddress)
                      .accessibilityIdentifier(AccessibilityID.exportEmailField)
              }
          }
      }

      private var cta: some View {
          Button { Task { await generate() } } label: {
              HStack {
                  if phase == .inProgress { ProgressView().tint(.white) }
                  Text(ctaTitle).font(.ui(15.5, .semibold)).foregroundStyle(.white)
              }
              .frame(maxWidth: .infinity).padding(.vertical, 14)
              .background(accent.base, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
          }
          .buttonStyle(.plain)
          .disabled(phase == .inProgress || (format == .accountant && email.isEmpty))
          .accessibilityIdentifier(AccessibilityID.exportGenerate)
      }

      private var ctaTitle: String { format == .accountant ? "Generate & send" : "Generate" }

      @ViewBuilder private var statusLine: some View {
          if case let .error(message) = phase {
              Text(message).font(.ui(13)).foregroundStyle(Palette.alert)
                  .accessibilityIdentifier(AccessibilityID.exportStatus)
          }
      }

      private func generate() async {
          phase = .inProgress
          do {
              let result = try await api.export(profileId: profileId, format: format.rawValue,
                                                 from: from, to: to,
                                                 toEmail: format == .accountant ? email : nil)
              switch result {
              case let .download(url, _):
                  // Resolve a shareable URL (absolute or app-host-relative).
                  let full = url.hasPrefix("http") ? url : "https://api.snapceipt.app\(url)"
                  shareURL = URL(string: full)
                  phase = .idle
              case .sent:
                  onSaveAccountantEmail(email)
                  phase = .idle
                  onClose()
              }
          } catch let e as APIError {
              phase = .error(e.message)
          } catch {
              phase = .error("Export failed. Try again.")
          }
      }

      /// Identifiable wrapper so `.sheet(item:)` presents the share sheet for a URL.
      private struct ShareItem: Identifiable { let id = UUID(); let url: URL }
      private var shareItem: Binding<ShareItem?> {
          Binding(get: { shareURL.map { ShareItem(url: $0) } },
                  set: { if $0 == nil { shareURL = nil } })
      }
  }

  /// UIActivityViewController bridge for the export share sheet.
  private struct ActivityView: UIViewControllerRepresentable {
      let url: URL
      func makeUIViewController(context: Context) -> UIActivityViewController {
          UIActivityViewController(activityItems: [url], applicationActivities: nil)
      }
      func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
  }
  ```
  NOTE: icon names are keys in `Icons.paths` (`Snapceipt/DesignSystem/Icons.swift`). The VERIFIED key set is: `arrowLeft, arrowRight, bell, building, camera, car, chart, check, chevD, chevR, clock, close, gear, home, info, pin, plus, receipt, sparkles, star, user, wallet, wfh`. The names used above (`close`, `chart`, `bell`, `receipt`) are all in that set. An unknown name renders an empty path (no crash), so this is safe, but stay within the verified keys.

- [ ] **Step 4: Build the app target to typecheck (no test yet — UI covered in Task 9).**
  ```
  /opt/homebrew/bin/xcodegen generate
  xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
  ```
  Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Shared/AccessibilityID.swift Snapceipt/App/Router.swift Snapceipt/App/RootView.swift Snapceipt/Features/Reports/ExportSheet.swift
  git commit -m "Add Export a11y ids, Router .export overlay, ExportSheet view

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 8: `ReportsView` + wire into RootView (replace the Reports stub)

Build the Reports tab screen and replace the `StubTabView(title: "Reports")` render site. Route `.export` through the non-fullscreen `.sheet(item:)` mechanism (`sheetBinding`/`sheetContent`), and reuse the shell's existing `captureAPI` for the Export sheet (no duplicate API property).

**Files:**
- Create: `Snapceipt/Features/Reports/ReportsView.swift`
- Modify: `Snapceipt/App/RootView.swift` (`tabContent` `.reports` case line 181; `sheetBinding` get/set lines 259–276 — UNCHANGED, `.export` already routes via `default`; `sheetContent(for:)` lines 278–295 — replace the Task 7 `.export` placeholder with the real `ExportSheet`; add `exportWindow` + `saveAccountantEmail` + `ExportDateFormatter` near `captureAPI` line 326)

- [ ] **Step 1: Write `ReportsView`.** Create `Snapceipt/Features/Reports/ReportsView.swift`:
  ```swift
  import SwiftUI
  import SwiftData

  /// The Reports tab (spec §5). Header + Export pill, Segmented period control, net-saved
  /// trend (BarPair), "Where it went" Donut, Business-only tax pills + logbook rows, and
  /// the AI insight card. Personal under-budget card is OMITTED (F3). A tab, not an overlay.
  struct ReportsView: View {
      let context: ModelContext
      let userId: String
      let profileId: String
      let profileName: String
      let startMonth: Int
      let onOpenExport: () -> Void
      let onOpenMileage: () -> Void
      let onOpenWFH: () -> Void

      @Environment(\.accent) private var accent
      @State private var vm: ReportsViewModel?
      @State private var periodSelection: String = Period.month.rawValue

      private let periodOptions = [
          SegmentOption(id: Period.month.rawValue, label: "Month"),
          SegmentOption(id: Period.quarter.rawValue, label: "Quarter"),
          SegmentOption(id: Period.fy.rawValue, label: "FY"),
      ]

      var body: some View {
          ZStack {
              Palette.cream.ignoresSafeArea()
              if let vm {
                  ScrollView {
                      VStack(spacing: 14) {
                          header
                          Segmented(options: periodOptions, selection: $periodSelection)
                              .accessibilityIdentifier(AccessibilityID.reportsPeriod)
                          netCard(vm)
                          donutCard(vm)
                          if vm.isBusiness {
                              taxPills(vm)
                              logbookRows(vm)
                          }
                          insightCard(vm)
                      }
                      .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 110)
                  }
              } else {
                  Color.clear
              }
          }
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier(AccessibilityID.reportsScreen)
          .task {
              if vm == nil {
                  vm = ReportsViewModel(context: context, userId: userId,
                                        profileId: profileId, startMonth: startMonth)
              }
          }
          .onChange(of: periodSelection) { _, newValue in
              vm?.period = Period(rawValue: newValue) ?? .month
          }
      }

      private var header: some View {
          HStack {
              Text("Reports").font(.display(28)).foregroundStyle(Palette.ink)
              Spacer()
              Button { onOpenExport() } label: {
                  HStack(spacing: 6) {
                      Icon(name: "chart", size: 16, color: accent.base)
                      Text("Export").font(.ui(13.5, .semibold)).foregroundStyle(accent.base)
                  }
                  .padding(.horizontal, 12).padding(.vertical, 8)
                  .background(accent.soft, in: Capsule())
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier(AccessibilityID.reportsExportPill)
          }
      }

      private func netCard(_ vm: ReportsViewModel) -> some View {
          Card {
              VStack(alignment: .leading, spacing: 10) {
                  Text("Net saved · \(vm.headline)").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                  Text(fmt(vm.netCents)).font(.display(30)).foregroundStyle(Palette.ink)
                      .monospacedDigit()
                      .accessibilityIdentifier(AccessibilityID.reportsNet)
                  HStack(spacing: 14) {
                      legendDot(color: Palette.income, label: "In \(fmt(vm.incomeCents))")
                      legendDot(color: accent.base, label: "Out \(fmt(vm.expenseCents))")
                  }
                  BarPair(data: vm.barData)
              }
          }
      }

      private func donutCard(_ vm: ReportsViewModel) -> some View {
          Card {
              VStack(spacing: 12) {
                  HStack {
                      Text("Where it went").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                      Spacer()
                  }
                  Donut(segments: vm.donutSegments, size: 150, thickness: 22) {
                      VStack(spacing: 2) {
                          Text(fmt(vm.donutTotalCents, showCents: false))
                              .font(.display(20)).foregroundStyle(Palette.ink).monospacedDigit()
                          Text("spent").font(.ui(11, .semibold)).foregroundStyle(Palette.ink3)
                      }
                  }
                  .accessibilityIdentifier(AccessibilityID.reportsDonut)
                  legend(vm)
              }
          }
      }

      @ViewBuilder private func legend(_ vm: ReportsViewModel) -> some View {
          VStack(spacing: 6) {
              ForEach(Array(vm.legend.prefix(5).enumerated()), id: \.offset) { _, row in
                  HStack(spacing: 8) {
                      Circle().fill(tint(row.catKey)).frame(width: 9, height: 9)
                      Text(label(row.catKey)).font(.ui(13)).foregroundStyle(Palette.ink2)
                      Spacer()
                      Text(fmt(row.spendCents)).font(.ui(13, .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
                  }
              }
          }
      }

      private func taxPills(_ vm: ReportsViewModel) -> some View {
          HStack(spacing: 10) {
              pill("Deductible YTD", fmt(vm.deductibleYTDCents), id: AccessibilityID.reportsDeductiblePill)
              pill("GST on purchases", fmt(vm.gstYTDCents), id: AccessibilityID.reportsGstPill)
          }
      }

      private func pill(_ caption: String, _ value: String, id: String) -> some View {
          Card {
              VStack(alignment: .leading, spacing: 4) {
                  Text(caption).font(.ui(11.5, .semibold)).foregroundStyle(Palette.ink3)
                  Text(value).font(.display(18)).foregroundStyle(Palette.ink).monospacedDigit()
              }
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .accessibilityIdentifier(id)
      }

      private func logbookRows(_ vm: ReportsViewModel) -> some View {
          VStack(spacing: 10) {
              logbookRow(icon: "car", title: "Vehicle logbook",
                         value: fmt(vm.vehicleClaimCents), id: AccessibilityID.reportsLogbookVehicle,
                         action: onOpenMileage)
              logbookRow(icon: "wfh", title: "Work from home",
                         value: fmt(vm.wfhClaimCents), id: AccessibilityID.reportsLogbookWFH,
                         action: onOpenWFH)
          }
      }

      private func logbookRow(icon: String, title: String, value: String, id: String,
                              action: @escaping () -> Void) -> some View {
          Button(action: action) {
              Card(padding: 14) {
                  HStack(spacing: 12) {
                      IconCircle(name: icon, tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
                      VStack(alignment: .leading, spacing: 1) {
                          Text(title).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                          Text("FY claim \(value)").font(.ui(12)).foregroundStyle(Palette.ink3).monospacedDigit()
                      }
                      Spacer()
                      Icon(name: "chevR", size: 16, color: Palette.ink3)
                  }
              }
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier(id)
      }

      private func insightCard(_ vm: ReportsViewModel) -> some View {
          Card {
              HStack(alignment: .top, spacing: 12) {
                  IconCircle(name: "sparkles", tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
                  Text(vm.insight).font(.ui(14)).foregroundStyle(Palette.ink2)
                  Spacer(minLength: 0)
              }
          }
          .accessibilityIdentifier(AccessibilityID.reportsInsight)
      }

      private func legendDot(color: Color, label: String) -> some View {
          HStack(spacing: 6) {
              Circle().fill(color).frame(width: 9, height: 9)
              Text(label).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink2).monospacedDigit()
          }
      }

      private func tint(_ key: String) -> Color {
          if let ck = CategoryKey(rawValue: key), let m = CATS[ck] { return m.tint }
          return Palette.ink3
      }
      private func label(_ key: String) -> String {
          if let ck = CategoryKey(rawValue: key), let m = CATS[ck] { return m.label }
          return key.capitalized
      }
  }
  ```
  NOTE: icon names are keys in `Icons.paths` (`Snapceipt/DesignSystem/Icons.swift`). The names used above (`chart`, `car`, `wfh`, `chevR`, `sparkles`, `receipt`) are all in the VERIFIED key set: `arrowLeft, arrowRight, bell, building, camera, car, chart, check, chevD, chevR, clock, close, gear, home, info, pin, plus, receipt, sparkles, star, user, wallet, wfh`. Stay within that set (an unknown name renders an empty path, no crash).

- [ ] **Step 2: Wire into `RootView`.** In `Snapceipt/App/RootView.swift`:
  - Replace the Reports case in `tabContent` (line 182):
    ```swift
          case .reports:
              ReportsView(
                  context: profiles.context,
                  userId: profiles.userId,
                  profileId: profiles.activeProfileId,
                  profileName: profiles.activeProfile?.name ?? "",
                  startMonth: 7,
                  onOpenExport: { router.present(.export) },
                  onOpenMileage: { router.present(.mileage) },
                  onOpenWFH: { router.present(.wfh) }
              )
              .environment(\.accent, accent)
    ```
  - In `sheetBinding`'s `get` (line 262), keep `.export` OUT of the excluded set so it routes to the sheet — change the switch to:
    ```swift
                  switch router.overlay {
                  case .capture, .mileage, .wfh: return nil
                  default: return router.overlay
                  }
    ```
    (Unchanged — `.export` falls into `default` and is presented as a sheet. The `fullScreen` set in `set` already lists only `.capture, .mileage, .wfh`, so `.export` dismisses correctly.)
  - In `sheetContent(for:)` (line 279), REPLACE the temporary `case .export: EmptyView()` placeholder added in Task 7 with the real sheet:
    ```swift
          case .export:
              ExportSheet(
                  api: captureAPI,   // reuse the shell's existing live/stub APIClient (no duplicate property)
                  profileId: profiles.activeProfileId,
                  profileName: profiles.activeProfile?.name ?? "",
                  from: exportWindow.from,
                  to: exportWindow.to,
                  periodLabel: exportWindow.label,
                  receiptsCount: exportWindow.receiptsCount,
                  deductibleCents: exportWindow.deductibleCents,
                  savedAccountantEmail: exportWindow.savedAccountantEmail,
                  onSaveAccountantEmail: { saveAccountantEmail($0) },
                  onClose: { router.dismissOverlay() }
              )
              .frame(maxHeight: .infinity, alignment: .bottom)
              .background(Palette.cream)
    ```
  - (The Export sheet reuses the existing `captureAPI` computed property — verified present at `RootView.swift` line 326, `#if DEBUG AppLaunch.current.makeAPIClient(auth:)` else `LiveAPIClient(...)`. No new `reportsAPI` property is needed.)
  - Add an `exportWindow` helper + `saveAccountantEmail` next to `captureAPI` (after line 332) (these compute the current-Month period range + counts from the active profile's data, mirroring `ReportsViewModel`'s reads — the ExportSheet always opens on the default Month period per spec §6 detail card / §3.8):
    ```swift
      /// The default-period (Month) export range + detail-card values, scoped to the
      /// active profile. The Reports default period is Month (spec §3); the Export sheet
      /// inherits it (spec §3.8). Receipts count = transactions in range with a note/gst
      /// signal of a real receipt is a backend concept; locally we show the in-range txn count.
      private var exportWindow: (from: String, to: String, label: String,
                                 receiptsCount: Int, deductibleCents: Int,
                                 savedAccountantEmail: String?) {
          let now = Date()
          let window = Period.month.window(now: now, startMonth: 7)
          let iso = ExportDateFormatter.shared
          let pid = profiles.activeProfileId
          let td = FetchDescriptor<Transaction>(
              predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
          let rows = (try? profiles.context.fetch(td)) ?? []
          let snaps = rows.map {
              TransactionQuery.Txn(txnDate: $0.txnDate, amountCents: $0.amountCents,
                                   catKey: $0.catKey, deductiblePct: $0.deductiblePct, gstCents: $0.gstCents)
          }
          let inRange = rows.filter { iso.date(from: $0.txnDate).map { $0 >= window.start && $0 < window.end } ?? false }
          // "Deductible total" for the export DETAIL card = the per-transaction deductible
          // over the SELECTED (Month) period only — NOT the FY-to-date pill. We reuse
          // `deductibleYTD` by passing the Month window as `fyWindow:` with EMPTY logbook
          // claims, so it reduces to Σ round(−amount × pct/100) over in-window txns. (spec §6)
          let deductible = TransactionQuery.deductibleYTD(snaps, fyWindow: window,
                                                          vehicleYearClaims: [], wfhClaims: [])
          var sd = FetchDescriptor<TaxSettings>(predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
          sd.fetchLimit = 1
          let saved = (try? profiles.context.fetch(sd))?.first?.accountantEmail
          return (iso.string(from: window.start), iso.string(from: window.end.addingTimeInterval(-86_400)),
                  window.label, inRange.count, deductible, saved)
      }

      /// Persist the accountant email on the active profile's TaxSettings + enqueue sync.
      /// Mirrors `TaxSettingsSeeder.ensure`'s fetch-then-branch (no `modelContext` probing).
      private func saveAccountantEmail(_ email: String) {
          let pid = profiles.activeProfileId
          var sd = FetchDescriptor<TaxSettings>(predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
          sd.fetchLimit = 1
          let row: TaxSettings
          if let existing = (try? profiles.context.fetch(sd))?.first {
              row = existing
          } else {
              row = TaxSettings(userId: profiles.userId, profileId: pid)
              profiles.context.insert(row)
          }
          row.accountantEmail = email
          row.updatedAt = Epoch.nowMs()
          try? profiles.context.save()
          sync.enqueue(op: "upsert", entityType: .taxSettings, entity: row)
      }
    ```
    Add a tiny date formatter helper at the bottom of `RootView.swift` (file scope, after the `ShellView` struct):
    ```swift
    /// Shared "yyyy-MM-dd" UTC formatter for export range parsing/formatting.
    enum ExportDateFormatter {
        static let shared: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()
    }
    ```
    (`SyncEngine.enqueue` signature verified: `enqueue(op:entityType:entity:)`. `Epoch.nowMs()` is used throughout the entities. `to` is the inclusive last day = `end - 1 day`, matching `[from, to]` in the spec §4.2 request.)

- [ ] **Step 3: Build the app target.**
  ```
  /opt/homebrew/bin/xcodegen generate
  xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
  ```
  Expected: `BUILD SUCCEEDED`. (All icon names used — `chart`, `car`, `wfh`, `chevR`, `sparkles`, `receipt`, `close`, `bell` — are verified keys in `Icons.paths`.)

- [ ] **Step 4: Run the full unit suite to confirm no regressions.**
  ```
  /opt/homebrew/bin/xcodegen generate
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: all pass (every existing suite stays green + the new Period/TransactionQuery/InsightBuilder/ReportsViewModel/ExportClient/TaxSettingsAccountant suites).

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Features/Reports/ReportsView.swift Snapceipt/App/RootView.swift
  git commit -m "Add ReportsView and wire the Reports tab + .export sheet into RootView

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 9: Seed transactions + hermetic Reports UI test

Extend `applySeedIfNeeded` to seed business-profile transactions (so the seeded shell renders real donut/net/pills), then add the hermetic XCUITest: open Reports → toggle period (donut + net recompute) → open Export → pick CSV → (stubbed network) assert the flow; a Business profile shows tax pills + logbook rows.

**Files:**
- Modify: `Snapceipt/App/AppLaunch.swift` (`applySeedIfNeeded`, lines 34–47)
- Test: `SnapceiptUITests/ReportsUITests.swift` (Create)

- [ ] **Step 1: Seed transactions for the business profile.** In `Snapceipt/App/AppLaunch.swift`, inside `applySeedIfNeeded`, after `context.insert(p1); context.insert(p2)` (line 45) and before `try? context.save()`, add:
  ```swift
          // Seed a handful of transactions on the business profile so Reports renders
          // a real donut/net/pills under -uiTestSeed. Dates anchored to the current month
          // so the default Month period shows them.
          let cal: Calendar = {
              var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
          }()
          let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
          let isoFmt: DateFormatter = {
              let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
              f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"; return f
          }()
          func dayISO(_ d: Int) -> String { isoFmt.string(from: cal.date(byAdding: .day, value: d, to: monthStart)!) }
          context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, catKey: "income",
                                     amountCents: 500_00, txnDate: dayISO(1)))
          context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "The Grounds",
                                     catKey: "meals", amountCents: -120_00, txnDate: dayISO(3),
                                     deductiblePct: 50, gstCents: 10_91))
          context.insert(Transaction(userId: DevAccount.userId, profileId: p1.id, merchant: "BP",
                                     catKey: "fuel", amountCents: -80_00, txnDate: dayISO(5),
                                     deductiblePct: 100, gstCents: 7_27))
          context.insert(VehicleYear(userId: DevAccount.userId, profileId: p1.id, vehicleId: "v1",
                                     fyStartYear: FinancialYear.of(Date(), startMonth: 7).startYear, claimCents: 250_00))
  ```
  (`Transaction`/`VehicleYear` inits verified; `p1` is the business profile, default + sortOrder 0, so it is the active profile in the seeded shell.)

- [ ] **Step 2: Write the FAILING UI test.** Create `SnapceiptUITests/ReportsUITests.swift`:
  ```swift
  import XCTest

  /// Hermetic Reports flow: seeded shell + stub API (no network).
  /// Reports tab -> toggle period (donut + net recompute) -> open Export -> pick CSV ->
  /// stubbed export. A Business profile shows tax pills + logbook rows.
  final class ReportsUITests: UITestCase {
      func testReportsTabTogglePeriodAndExportCSV() {
          launchSeeded()   // signed-in, business profile p1 active, seeded transactions

          // Open the Reports tab.
          let reports = app.buttons[AccessibilityID.tabReports].firstMatch
          XCTAssertTrue(reports.waitForExistence(timeout: 10), "Reports tab not found")
          reports.tap()

          XCTAssertTrue(app.otherElements[AccessibilityID.reportsScreen].waitForExistence(timeout: 5),
                        "Reports screen did not appear")

          // Net headline + donut render.
          XCTAssertTrue(app.staticTexts[AccessibilityID.reportsNet].waitForExistence(timeout: 5),
                        "Net figure missing")
          XCTAssertTrue(app.otherElements[AccessibilityID.reportsDonut].exists
                        || app.staticTexts[AccessibilityID.reportsDonut].exists,
                        "Donut missing")

          // Business layout: tax pills + logbook rows present.
          XCTAssertTrue(app.otherElements[AccessibilityID.reportsDeductiblePill].exists
                        || app.staticTexts[AccessibilityID.reportsDeductiblePill].exists,
                        "Deductible pill missing for a business profile")
          XCTAssertTrue(app.buttons[AccessibilityID.reportsLogbookVehicle].exists,
                        "Vehicle logbook row missing")

          // Toggle to FY -> the screen still renders the net figure (recompute ran).
          let fySeg = app.buttons["FY"].firstMatch
          if fySeg.exists { fySeg.tap() }
          XCTAssertTrue(app.staticTexts[AccessibilityID.reportsNet].waitForExistence(timeout: 5),
                        "Net figure missing after period toggle")

          // Open the Export sheet.
          app.buttons[AccessibilityID.reportsExportPill].tap()
          XCTAssertTrue(app.otherElements[AccessibilityID.exportSheet].waitForExistence(timeout: 5),
                        "Export sheet did not appear")

          // Pick CSV, then Generate (stubbed network returns a download url -> share sheet).
          app.buttons[AccessibilityID.exportFormatCSV].tap()
          let generate = app.buttons[AccessibilityID.exportGenerate]
          XCTAssertTrue(generate.waitForExistence(timeout: 5), "Generate CTA missing")
          generate.tap()

          // The stubbed export resolves without error: the sheet stays up (no error status)
          // and the system share sheet may appear. Assert no error status line is shown.
          XCTAssertFalse(app.staticTexts[AccessibilityID.exportStatus].waitForExistence(timeout: 3),
                         "Export reported an error under the stub")
      }
  }
  ```

- [ ] **Step 3: Run it — expect FAIL first (before Step 1 seed is correct / before the screen wiring), then PASS.** First confirm it compiles + runs:
  ```
  /opt/homebrew/bin/xcodegen generate
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptUITests/ReportsUITests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  If the donut/pill assertions fail because XCUITest surfaces the identifiers as a different element class, relax the failing assertion to probe `app.descendants(matching: .any)[AccessibilityID.xxx]` and re-run (this is the standard a11y-container caveat seen in `CaptureUITests`/`LogbookUITests`).
  Expected (final): `Test Suite 'ReportsUITests' passed`.

- [ ] **Step 4: Run the FULL suite (unit + UI) to confirm the baseline stays green.**
  ```
  /opt/homebrew/bin/xcodegen generate
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptUITests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: all green (every existing unit suite + the 6 new unit suites; existing UI suites + `ReportsUITests`).

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/App/AppLaunch.swift SnapceiptUITests/ReportsUITests.swift
  git commit -m "Seed Reports transactions + add hermetic Reports UI test

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Verification checklist (run before claiming done)
- [ ] `/opt/homebrew/bin/xcodegen generate` then `xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests -destination 'platform=iOS Simulator,name=iPhone 16' test` → all green.
- [ ] `xcodebuild -scheme Snapceipt -only-testing:SnapceiptUITests -destination 'platform=iOS Simulator,name=iPhone 16' test` → all green.
- [ ] No `.xcodeproj` staged in any commit (`git status` shows it untracked/ignored).
- [ ] The Reports `StubTabView` render site is gone (RootView `tabContent` `.reports` returns `ReportsView`).
- [ ] `Period`/`TransactionQuery`/`InsightBuilder` take an injected `now`/`Window` — grep the three files for `Date()` and confirm none appears in their computation paths.
