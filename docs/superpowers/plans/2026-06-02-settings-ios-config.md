# F7 Settings — iOS Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Profile-tab stub into the real Settings hub with the profile-scoped config editors — Tax & GST, Categories & smart-rules, profile edit/delete + ProfileDetail — and replace the hardcoded `financialYearStartMonth` (`startMonth: 7`) wiring with the active profile's value.

**Architecture:** New `@Observable @MainActor` view-models (injected `context`/`sync`/`profileId`, mirroring `BudgetListViewModel`/`QuoteListViewModel`) drive each editor over the existing synced `@Model`s (`Profile`, `TaxSettings`, `Category`, `SmartRule`) via `SyncEnqueuing`. New full-screen `Router.Overlay` cases reach each screen from the restructured `ProfileTabView` hub. A `ProfilesStore.activeFinancialYearStartMonth()` resolver makes the FY-start a single source the views read.

**Tech Stack:** SwiftUI + SwiftData (iOS 17+), Swift Testing + XCUITest, XcodeGen (`project.yml`).

**Authoritative contract:** §2–§7 of `docs/superpowers/specs/2026-06-02-settings-design.md`. This plan touches NO backend (all entities sync via the generic `/sync`).

**Baseline:** iOS unit 319 / UI 12 (1 LiveSmoke skip). Build + test:
```bash
/opt/homebrew/bin/xcodegen generate
xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/<SuiteTypeName>'
```
Run `xcodegen generate` before any `xcodebuild`. NEVER `git add Snapceipt.xcodeproj`. `-only-testing` uses Swift TYPE names. Trust `xcodebuild`, not SourceKit. Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Do NOT push.

**Reuse exemplars (read before mirroring):** `Snapceipt/Features/Budgets/BudgetListView.swift` + `BudgetListViewModel.swift` (overlay view + VM + FetchDescriptor + enqueue), `Snapceipt/Features/Notifications/NotificationsSettingsView.swift` (SheetHeader + grouped cards + toggles), `Snapceipt/Features/EmailIn/*` (F6, the most recent overlay feature), `Snapceipt/Features/Profiles/AddProfileView.swift` + `AddProfileViewModel.swift` (the profile form to mirror for edit), `Snapceipt/Features/Profiles/ProfilesStore.swift`, `Snapceipt/Model/FinancialYear.swift`, `Snapceipt/Model/Categories.swift` (the `CategoryKey` taxonomy), `Snapceipt/Features/Logbooks/TaxSettingsSeeder.swift`.

---

### Task 1: `ProfilesStore.update` / `delete` / `activeFinancialYearStartMonth`

**Files:**
- Modify: `Snapceipt/Features/Profiles/ProfilesStore.swift`
- Test: `SnapceiptTests/ProfilesStoreTests.swift` (create if absent)

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/ProfilesStoreTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("ProfilesStore F7")
struct ProfilesStoreTests {
    private func fixture() throws -> (ModelContext, MockSyncEngine, ProfilesStore) {
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let sync = MockSyncEngine()
        let store = ProfilesStore(context: ctx, sync: sync, userId: "u1")
        return (ctx, sync, store)
    }

    @Test("update mutates the profile and enqueues an upsert")
    func update() throws {
        let (_, sync, store) = try fixture()
        let p = Profile(userId: "u1", name: "Biz", type: "business", accent1: "#0", accent2: "#1", accent3: "#2")
        store.add(p)
        sync.calls.removeAll()
        store.update(p) { $0.name = "Renamed"; $0.gstRegistered = true }
        #expect(p.name == "Renamed")
        #expect(p.gstRegistered == true)
        #expect(sync.calls.last?.op == "upsert")
        #expect(sync.calls.last?.entityType == .profile)
    }

    @Test("delete soft-deletes a non-active profile and enqueues delete")
    func delete() throws {
        let (_, sync, store) = try fixture()
        let p1 = Profile(userId: "u1", name: "A", type: "personal", accent1: "#0", accent2: "#1", accent3: "#2")
        let p2 = Profile(userId: "u1", name: "B", type: "business", accent1: "#0", accent2: "#1", accent3: "#2")
        store.add(p1); store.add(p2)
        store.setActive(p1.id)
        sync.calls.removeAll()
        let ok = store.delete(p2)
        #expect(ok == true)
        #expect(p2.deletedAt != nil)
        #expect(store.profiles.contains { $0.id == p2.id } == false)
        #expect(sync.calls.last?.op == "delete")
    }

    @Test("delete refuses the last profile and the active profile")
    func deleteGuards() throws {
        let (_, _, store) = try fixture()
        let only = Profile(userId: "u1", name: "Only", type: "personal", accent1: "#0", accent2: "#1", accent3: "#2")
        store.add(only)
        #expect(store.delete(only) == false)           // last profile
        let p2 = Profile(userId: "u1", name: "B", type: "business", accent1: "#0", accent2: "#1", accent3: "#2")
        store.add(p2); store.setActive(p2.id)
        #expect(store.delete(p2) == false)             // active profile
    }

    @Test("activeFinancialYearStartMonth reads the active profile's tax_settings, default 7")
    func fyStart() throws {
        let (ctx, sync, store) = try fixture()
        let p = Profile(userId: "u1", name: "Biz", type: "business", accent1: "#0", accent2: "#1", accent3: "#2")
        store.add(p)  // add() seeds a TaxSettings via TaxSettingsSeeder (FY start 7)
        #expect(store.activeFinancialYearStartMonth() == 7)
        // change it
        let d = FetchDescriptor<TaxSettings>(predicate: #Predicate { $0.profileId == p.id && $0.deletedAt == nil })
        let ts = try ctx.fetch(d).first!
        ts.financialYearStartMonth = 4
        try ctx.save()
        #expect(store.activeFinancialYearStartMonth() == 4)
        _ = sync
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild build-for-testing -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD FAILS — `update`/`delete`/`activeFinancialYearStartMonth` unknown.

- [ ] **Step 3: Implement in `ProfilesStore.swift`**

Add these methods to `ProfilesStore` (after `add(_:)`):

```swift
/// Mutate a profile in a closure, stamp updatedAt, persist, reload, enqueue upsert.
func update(_ profile: Profile, _ mutate: (Profile) -> Void) {
    mutate(profile)
    profile.updatedAt = Epoch.nowMs()
    try? context.save()
    reload()
    sync.enqueue(op: "upsert", entityType: .profile, entity: profile)
}

/// Soft-delete a profile. Refuses the last remaining profile or the active one
/// (the caller must switch away first). Returns true when it deleted.
@discardableResult
func delete(_ profile: Profile) -> Bool {
    guard profiles.count > 1 else { return false }
    guard profile.id != activeProfileId else { return false }
    profile.deletedAt = Epoch.nowMs()
    profile.updatedAt = Epoch.nowMs()
    try? context.save()
    reload()
    sync.enqueue(op: "delete", entityType: .profile, entity: profile)
    return true
}

/// The active profile's FY start month (1-12) from its tax_settings; 7 (July) if none.
func activeFinancialYearStartMonth() -> Int {
    let pid = activeProfileId
    var d = FetchDescriptor<TaxSettings>(predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
    d.fetchLimit = 1
    return (try? context.fetch(d))?.first?.financialYearStartMonth ?? 7
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/ProfilesStoreTests'`
Expected: PASS (4 tests). (If `add()` does not seed a TaxSettings in your build, the `fyStart` test's first assertion still holds via the `?? 7` fallback.)

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Profiles/ProfilesStore.swift SnapceiptTests/ProfilesStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(F7 iOS): ProfilesStore update/delete + activeFinancialYearStartMonth

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `BasPeriod` + `nextBasDue` pure helper

**Files:**
- Create: `Snapceipt/Model/BasSchedule.swift`
- Test: `SnapceiptTests/BasScheduleTests.swift`

ATO BAS: quarterly quarters end 30 Sep / 31 Dec / 31 Mar / 30 Jun; the lodge/pay due date is the 28th of the month after quarter-end (28 Oct / 28 Feb / 28 Apr / 28 Jul). Monthly = 21st of the following month.

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/BasScheduleTests.swift`:

```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("BAS schedule")
struct BasScheduleTests {
    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Australia/Sydney"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }
    @Test("quarterly next-due is the 28th after the current quarter end")
    func quarterly() {
        // 15 Aug 2026 → Q ending 30 Sep 2026 → due 28 Oct 2026
        #expect(BasSchedule.nextDue(.quarterly, on: date("2026-08-15")) == date("2026-10-28"))
        // 5 Jan 2026 → Q ending 31 Dec 2025 already passed → next is Q ending 31 Mar 2026 → due 28 Apr 2026
        #expect(BasSchedule.nextDue(.quarterly, on: date("2026-01-05")) == date("2026-04-28"))
    }
    @Test("monthly next-due is the 21st of the next month")
    func monthly() {
        #expect(BasSchedule.nextDue(.monthly, on: date("2026-08-15")) == date("2026-09-21"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild build-for-testing -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD FAILS — `BasSchedule` unknown.

- [ ] **Step 3: Implement `Snapceipt/Model/BasSchedule.swift`**

```swift
import Foundation

enum BasPeriod: String, CaseIterable, Sendable {
    case quarterly
    case monthly
    var label: String { self == .quarterly ? "Quarterly" : "Monthly" }
}

/// AU BAS lodge/pay due dates. Pure + deterministic (UTC-stable via an explicit calendar).
enum BasSchedule {
    private static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return c
    }

    /// The next BAS due date strictly on/after `on`.
    static func nextDue(_ period: BasPeriod, on: Date) -> Date {
        let c = cal
        switch period {
        case .monthly:
            // 21st of the month after `on`'s month.
            let comps = c.dateComponents([.year, .month], from: on)
            let firstOfThis = c.date(from: comps)!
            let nextMonth = c.date(byAdding: .month, value: 1, to: firstOfThis)!
            return c.date(byAdding: .day, value: 20, to: nextMonth)! // 1st + 20 = 21st
        case .quarterly:
            // Quarter ends: Sep(9)/Dec(12)/Mar(3)/Jun(6); due 28th of the following month.
            let dues = [ (9, 10), (12, 1), (3, 4), (6, 7) ] // (quarterEndMonth, dueMonth)
            let year = c.component(.year, from: on)
            var candidates: [Date] = []
            for y in [year - 1, year, year + 1] {
                for (endMonth, dueMonth) in dues {
                    let dueYear = dueMonth < endMonth ? y + 1 : y // Dec→Jan rolls to next year
                    var dc = DateComponents(); dc.year = dueYear; dc.month = dueMonth; dc.day = 28
                    if let d = c.date(from: dc) { candidates.append(d) }
                }
            }
            return candidates.filter { $0 >= c.startOfDay(for: on) }.min()!
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/BasScheduleTests'`
Expected: PASS (2 tests). If a boundary assertion is off by the quarter-end-vs-due mapping, adjust the `dues` mapping so each quarter's due is the 28th of the month after the quarter END (Sep→28 Oct, Dec→28 Jan, Mar→28 Apr, Jun→28 Jul) and re-run; keep the test dates as the spec of record.

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Model/BasSchedule.swift SnapceiptTests/BasScheduleTests.swift
git commit -m "$(cat <<'EOF'
feat(F7 iOS): BasPeriod + BasSchedule.nextDue (AU BAS due dates)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `TaxSettingsViewModel`

**Files:**
- Create: `Snapceipt/Features/Settings/TaxSettingsViewModel.swift`
- Test: `SnapceiptTests/TaxSettingsViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/TaxSettingsViewModelTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("TaxSettingsViewModel")
struct TaxSettingsViewModelTests {
    private func fixture(type: String) throws -> (ModelContext, MockSyncEngine, Profile) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let p = Profile(userId: "u1", name: "P", type: type, accent1: "#0", accent2: "#1", accent3: "#2")
        ctx.insert(p)
        ctx.insert(TaxSettings(userId: "u1", profileId: p.id))
        try ctx.save()
        return (ctx, MockSyncEngine(), p)
    }

    @Test("loads the row and persists an edited meals % via enqueue")
    func editMeals() throws {
        let (ctx, sync, p) = try fixture(type: "business")
        let vm = TaxSettingsViewModel(context: ctx, sync: sync, userId: "u1", profile: p)
        #expect(vm.mealsDeductiblePct == 50)
        vm.setMealsDeductiblePct(80)
        #expect(vm.mealsDeductiblePct == 80)
        let row = try ctx.fetch(FetchDescriptor<TaxSettings>(predicate: #Predicate { $0.profileId == p.id })).first!
        #expect(row.mealsDeductiblePct == 80)
        #expect(sync.calls.last?.entityType == .taxSettings)
        #expect(sync.calls.last?.op == "upsert")
    }

    @Test("business shows identity; personal hides it")
    func identityVisibility() throws {
        let (ctx, sync, biz) = try fixture(type: "business")
        #expect(TaxSettingsViewModel(context: ctx, sync: sync, userId: "u1", profile: biz).showsBusinessIdentity == true)
        let p = Profile(userId: "u1", name: "Personal", type: "personal", accent1: "#0", accent2: "#1", accent3: "#2")
        ctx.insert(p); ctx.insert(TaxSettings(userId: "u1", profileId: p.id)); try ctx.save()
        #expect(TaxSettingsViewModel(context: ctx, sync: sync, userId: "u1", profile: p).showsBusinessIdentity == false)
    }

    @Test("editing GST + ABN writes to the Profile and FY start to tax_settings")
    func gstAndFy() throws {
        let (ctx, sync, p) = try fixture(type: "business")
        let vm = TaxSettingsViewModel(context: ctx, sync: sync, userId: "u1", profile: p)
        vm.setGstRegistered(true)
        vm.setAbn("12 345 678 901")
        vm.setFinancialYearStartMonth(4)
        #expect(p.gstRegistered == true)
        #expect(p.abn == "12 345 678 901")
        let row = try ctx.fetch(FetchDescriptor<TaxSettings>(predicate: #Predicate { $0.profileId == p.id })).first!
        #expect(row.financialYearStartMonth == 4)
        // both a profile upsert and a taxSettings upsert were enqueued
        #expect(sync.calls.contains { $0.entityType == .profile })
        #expect(sync.calls.contains { $0.entityType == .taxSettings })
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild build-for-testing -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD FAILS — `TaxSettingsViewModel` unknown.

- [ ] **Step 3: Implement `Snapceipt/Features/Settings/TaxSettingsViewModel.swift`**

```swift
import Foundation
import SwiftData

/// Edits the active profile's tax_settings (+ the Profile's ABN/GST identity).
/// `@MainActor`; deps injected. Lazily ensures a tax_settings row exists.
@Observable
@MainActor
final class TaxSettingsViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored private let profile: Profile
    @ObservationIgnored private var settings: TaxSettings

    var showsBusinessIdentity: Bool { profile.type == "business" }

    // Mirrored editable state (read from the row at init).
    private(set) var mealsDeductiblePct: Int
    private(set) var wfhRateCentsPerHour: Int
    private(set) var financialYearStartMonth: Int
    private(set) var gstRegistered: Bool
    private(set) var abn: String

    // Local-only prefs (no column): entity type, GST basis, BAS period, vehicle method.
    var entityType: String { didSet { defaults.set(entityType, forKey: key("entityType")) } }
    var gstBasis: String { didSet { defaults.set(gstBasis, forKey: key("gstBasis")) } }
    var basPeriodRaw: String { didSet { defaults.set(basPeriodRaw, forKey: key("basPeriod")) } }

    @ObservationIgnored private let defaults: UserDefaults
    private func key(_ k: String) -> String { "sc.tax.\(profile.id).\(k)" }

    var basPeriod: BasPeriod { BasPeriod(rawValue: basPeriodRaw) ?? .quarterly }
    var nextBasDue: Date { BasSchedule.nextDue(basPeriod, on: Date()) }

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profile: Profile,
         defaults: UserDefaults = .standard) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profile = profile
        self.defaults = defaults

        let pid = profile.id
        var d = FetchDescriptor<TaxSettings>(predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        d.fetchLimit = 1
        if let row = (try? context.fetch(d))?.first {
            self.settings = row
        } else {
            let row = TaxSettings(userId: userId, profileId: pid)
            context.insert(row)
            try? context.save()
            sync.enqueue(op: "upsert", entityType: .taxSettings, entity: row)
            self.settings = row
        }
        self.mealsDeductiblePct = settings.mealsDeductiblePct
        self.wfhRateCentsPerHour = settings.wfhRateCentsPerHour
        self.financialYearStartMonth = settings.financialYearStartMonth
        self.gstRegistered = profile.gstRegistered
        self.abn = profile.abn ?? ""
        self.entityType = defaults.string(forKey: "sc.tax.\(pid).entityType") ?? "Sole trader"
        self.gstBasis = defaults.string(forKey: "sc.tax.\(pid).gstBasis") ?? "Cash"
        self.basPeriodRaw = defaults.string(forKey: "sc.tax.\(pid).basPeriod") ?? BasPeriod.quarterly.rawValue
    }

    private func saveSettings() {
        settings.updatedAt = Epoch.nowMs()
        try? context.save()
        sync.enqueue(op: "upsert", entityType: .taxSettings, entity: settings)
    }
    private func saveProfile() {
        profile.updatedAt = Epoch.nowMs()
        try? context.save()
        sync.enqueue(op: "upsert", entityType: .profile, entity: profile)
    }

    func setMealsDeductiblePct(_ v: Int) { let c = max(0, min(100, v)); mealsDeductiblePct = c; settings.mealsDeductiblePct = c; saveSettings() }
    func setWfhRate(_ cents: Int) { let c = max(0, cents); wfhRateCentsPerHour = c; settings.wfhRateCentsPerHour = c; saveSettings() }
    func setFinancialYearStartMonth(_ m: Int) { let c = max(1, min(12, m)); financialYearStartMonth = c; settings.financialYearStartMonth = c; saveSettings() }
    func setGstRegistered(_ on: Bool) { gstRegistered = on; profile.gstRegistered = on; saveProfile() }
    func setAbn(_ s: String) { abn = s; profile.abn = s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s; saveProfile() }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/TaxSettingsViewModelTests'`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Settings/TaxSettingsViewModel.swift SnapceiptTests/TaxSettingsViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(F7 iOS): TaxSettingsViewModel (FY start, GST/ABN, deduction defaults)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `CategorySeeder` + `CategoriesViewModel`

**Files:**
- Create: `Snapceipt/Features/Settings/CategorySeeder.swift`
- Create: `Snapceipt/Features/Settings/CategoriesViewModel.swift`
- Test: `SnapceiptTests/CategoriesViewModelTests.swift`

First READ `Snapceipt/Model/Categories.swift` to get the exact `CategoryKey` cases + their `label`/`icon`/`tint`/`soft`/`defaultDeductible`/`isIncome` metadata accessors; the seeder maps each non-`custom` case to a `Category` row.

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/CategoriesViewModelTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("CategoriesViewModel")
struct CategoriesViewModelTests {
    private func fixture() throws -> (ModelContext, MockSyncEngine) {
        let c = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(c), MockSyncEngine())
    }

    @Test("seeds built-in categories once and lists them")
    func seeds() throws {
        let (ctx, sync) = try fixture()
        let vm = CategoriesViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
        let firstCount = vm.categories.count
        #expect(firstCount >= 9) // the built-in taxonomy (custom excluded)
        // re-init: idempotent, no duplicates
        let vm2 = CategoriesViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
        #expect(vm2.categories.count == firstCount)
    }

    @Test("editing a category default deductible % persists + enqueues")
    func editDefault() throws {
        let (ctx, sync) = try fixture()
        let vm = CategoriesViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
        let cat = vm.categories.first!
        sync.calls.removeAll()
        vm.setDefaultDeductible(cat, pct: 25)
        #expect(cat.defaultDeductiblePct == 25)
        #expect(sync.calls.last?.entityType == .category)
        #expect(sync.calls.last?.op == "upsert")
    }

    @Test("receiptCount reflects email_in/manual transactions for the profile by catKey")
    func counts() throws {
        let (ctx, sync) = try fixture()
        ctx.insert(Transaction(userId: "u1", profileId: "p1", catKey: "office", amountCents: -100, txnDate: "2026-06-01"))
        ctx.insert(Transaction(userId: "u1", profileId: "p1", catKey: "office", amountCents: -200, txnDate: "2026-06-02"))
        try ctx.save()
        let vm = CategoriesViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
        let office = vm.categories.first { $0.key == "office" }!
        #expect(vm.receiptCount(office) == 2)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild build-for-testing -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD FAILS — `CategoriesViewModel` unknown.

- [ ] **Step 3: Implement `CategorySeeder.swift`**

```swift
import Foundation
import SwiftData

/// Ensures the built-in `Category` rows exist for a profile (idempotent), derived
/// from the CategoryKey taxonomy. Mirrors TaxSettingsSeeder. `custom` is excluded
/// (it is the catch-all key, not a managed category row).
@MainActor
enum CategorySeeder {
    static func ensure(profileId: String, userId: String, context: ModelContext, sync: any SyncEnqueuing) {
        let pid = profileId
        let existing = (try? context.fetch(FetchDescriptor<Category>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil }))) ?? []
        let haveKeys = Set(existing.map { $0.key })

        var sort = existing.count
        for key in CategoryKey.allCases where key != .custom {
            if haveKeys.contains(key.rawValue) { continue }
            let cat = Category(
                userId: userId,
                profileId: pid,
                key: key.rawValue,
                label: key.label,
                icon: key.icon,
                tint: key.tint,
                soft: key.soft,
                defaultDeductiblePct: key.defaultDeductible,
                isIncome: key == .income,
                sortOrder: sort)
            sort += 1
            context.insert(cat)
            sync.enqueue(op: "upsert", entityType: .category, entity: cat)
        }
        try? context.save()
    }
}
```

Note: confirm the exact `CategoryKey` metadata accessor names (`label`/`icon`/`tint`/`soft`/`defaultDeductible`) against `Snapceipt/Model/Categories.swift` and use the real names; if `defaultDeductible` is named differently (e.g. `deductible`), use that.

- [ ] **Step 4: Implement `CategoriesViewModel.swift`**

```swift
import Foundation
import SwiftData

@Observable
@MainActor
final class CategoriesViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String

    private(set) var categories: [Category] = []

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profileId = profileId
        CategorySeeder.ensure(profileId: profileId, userId: userId, context: context, sync: sync)
        reload()
    }

    func reload() {
        let pid = profileId
        let d = FetchDescriptor<Category>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.label)])
        categories = (try? context.fetch(d)) ?? []
    }

    /// Live receipt count for the active profile by this category's key.
    func receiptCount(_ cat: Category) -> Int {
        let pid = profileId
        let key = cat.key
        let d = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid && $0.catKey == key && $0.deletedAt == nil })
        return ((try? context.fetch(d)) ?? []).count
    }

    func setDefaultDeductible(_ cat: Category, pct: Int) {
        cat.defaultDeductiblePct = max(0, min(100, pct))
        cat.updatedAt = Epoch.nowMs()
        try? context.save()
        sync.enqueue(op: "upsert", entityType: .category, entity: cat)
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/CategoriesViewModelTests'`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Snapceipt/Features/Settings/CategorySeeder.swift Snapceipt/Features/Settings/CategoriesViewModel.swift SnapceiptTests/CategoriesViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(F7 iOS): CategorySeeder + CategoriesViewModel (counts + default %)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `SmartRulesViewModel`

**Files:**
- Create: `Snapceipt/Features/Settings/SmartRulesViewModel.swift`
- Test: `SnapceiptTests/SmartRulesViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/SmartRulesViewModelTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("SmartRulesViewModel")
struct SmartRulesViewModelTests {
    private func fixture() throws -> (ModelContext, MockSyncEngine) {
        let c = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(c), MockSyncEngine())
    }

    @Test("create inserts a profile-scoped rule and enqueues upsert")
    func create() throws {
        let (ctx, sync) = try fixture()
        let vm = SmartRulesViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
        let r = vm.create(matchType: "merchant_contains", matcher: "uber", categoryId: nil, setDeductiblePct: 100, setMode: "business")
        #expect(vm.rules.count == 1)
        #expect(r.profileId == "p1")
        #expect(r.matcher == "uber")
        #expect(sync.calls.last?.entityType == .smartRule)
        #expect(sync.calls.last?.op == "upsert")
    }

    @Test("update + delete enqueue accordingly")
    func updateDelete() throws {
        let (ctx, sync) = try fixture()
        let vm = SmartRulesViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
        let r = vm.create(matchType: "merchant_equals", matcher: "X", categoryId: nil, setDeductiblePct: nil, setMode: nil)
        vm.update(r) { $0.enabled = false; $0.priority = 5 }
        #expect(r.enabled == false)
        #expect(r.priority == 5)
        #expect(sync.calls.last?.op == "upsert")
        vm.delete(r)
        #expect(vm.rules.isEmpty)
        #expect(sync.calls.last?.op == "delete")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild build-for-testing -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD FAILS — `SmartRulesViewModel` unknown.

- [ ] **Step 3: Implement `SmartRulesViewModel.swift`**

```swift
import Foundation
import SwiftData

@Observable
@MainActor
final class SmartRulesViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String

    private(set) var rules: [SmartRule] = []

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profileId = profileId
        reload()
    }

    func reload() {
        let pid = profileId
        let d = FetchDescriptor<SmartRule>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.priority, order: .reverse), SortDescriptor(\.createdAt)])
        rules = (try? context.fetch(d)) ?? []
    }

    @discardableResult
    func create(matchType: String, matcher: String, categoryId: String?, setDeductiblePct: Int?, setMode: String?) -> SmartRule {
        let r = SmartRule(userId: userId, profileId: profileId, matchType: matchType, matcher: matcher,
                          categoryId: categoryId, setDeductiblePct: setDeductiblePct, setMode: setMode)
        context.insert(r)
        try? context.save()
        reload()
        sync.enqueue(op: "upsert", entityType: .smartRule, entity: r)
        return r
    }

    func update(_ rule: SmartRule, _ mutate: (SmartRule) -> Void) {
        mutate(rule)
        rule.updatedAt = Epoch.nowMs()
        try? context.save()
        reload()
        sync.enqueue(op: "upsert", entityType: .smartRule, entity: rule)
    }

    func delete(_ rule: SmartRule) {
        rule.deletedAt = Epoch.nowMs()
        rule.updatedAt = Epoch.nowMs()
        try? context.save()
        reload()
        sync.enqueue(op: "delete", entityType: .smartRule, entity: rule)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/SmartRulesViewModelTests'`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Settings/SmartRulesViewModel.swift SnapceiptTests/SmartRulesViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(F7 iOS): SmartRulesViewModel (CRUD over smart_rules)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Router overlays + AccessibilityIDs

**Files:**
- Modify: `Snapceipt/App/Router.swift` (Overlay cases + id)
- Modify: `Snapceipt/Shared/AccessibilityID.swift`

- [ ] **Step 1: Add the overlay cases**

In `Snapceipt/App/Router.swift`, add to the `Overlay` enum:

```swift
    case tax
    case categories
    case ruleEditor(id: String?)   // nil = new rule
    case profileDetail(id: String)
```

And to the `id` switch:

```swift
        case .tax: return "tax"
        case .categories: return "categories"
        case .ruleEditor(let id): return "ruleEditor-\(id ?? "new")"
        case .profileDetail(let id): return "profileDetail-\(id)"
```

(The `.privacy` and `.account` overlays are added by the iOS-account plan.)

- [ ] **Step 2: Add the AccessibilityIDs**

In `Snapceipt/Shared/AccessibilityID.swift`, add a Settings group:

```swift
    // Settings hub (F7)
    static let profileHubScreen = "profile.hub.screen"
    static let profileRowTax = "profile.row.tax"
    static let profileRowCategories = "profile.row.categories"
    static let profileRowPrivacy = "profile.row.privacy"
    static let profileRowAccount = "profile.row.account"
    static let profileSwitcherCardPrefix = "profile.switcher.card."  // + profile.id
    static let profileAddButton = "profile.add"
    static let signOutButton = "profile.signout"
    // Tax & GST
    static let taxScreen = "tax.screen"
    static let taxGstToggle = "tax.gst.toggle"
    static let taxAbnField = "tax.abn.field"
    static let taxFyStart = "tax.fy.start"
    static let taxMealsPct = "tax.meals.pct"
    // Categories & rules
    static let categoriesScreen = "categories.screen"
    static let categoryRowPrefix = "category.row."     // + category.id
    static let ruleRowPrefix = "rule.row."             // + rule.id
    static let ruleAddButton = "rule.add"
    static let ruleEditorScreen = "rule.editor.screen"
    static let ruleEditorSave = "rule.editor.save"
    // Profile detail
    static let profileDetailScreen = "profile.detail.screen"
    static let profileDetailSwitch = "profile.detail.switch"
    static let profileDetailDelete = "profile.detail.delete"
    static let profileDetailNameField = "profile.detail.name"
```

- [ ] **Step 3: Build to confirm it compiles**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild build-for-testing -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDS (the new enum cases aren't yet referenced by `RootView`'s switches — Swift `Overlay` switches with a `default`/`EmptyView` arm still compile; if `RootView` has an exhaustive switch over `Overlay`, add the new cases to the `EmptyView` arm now to keep it compiling).

- [ ] **Step 4: Commit**

```bash
git add Snapceipt/App/Router.swift Snapceipt/Shared/AccessibilityID.swift
git commit -m "$(cat <<'EOF'
feat(F7 iOS): Settings overlay routes + accessibility ids

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Restructure `ProfileTabView` into the Settings hub + RootView wiring

**Files:**
- Modify: `Snapceipt/Features/Profiles/ProfileTabView.swift`
- Modify: `Snapceipt/App/RootView.swift`
- Create (compiling placeholders, fleshed out in Tasks 8-10): `Snapceipt/Features/Settings/TaxSettingsView.swift`, `CategoriesView.swift`, `RuleEditorView.swift`, `ProfileDetailView.swift`

This task wires navigation; Tasks 8-10 replace the placeholder view bodies (same split pattern F6 used). Read `RootView.swift`'s existing `.budgets`/`.quotes` overlay blocks + `sheetBinding` + `sheetContent` and mirror them exactly for the new overlays. Read how `captureAPI`, `profiles`, `sync`, `accent` are passed.

- [ ] **Step 1: Restructure `ProfileTabView`**

Replace the body with the hub (mirror the existing `row(...)` helper + add a profile-switcher grid + grouped sections + sign-out). The struct gains closures for the new destinations and access to `ProfilesStore` + the sign-out action:

```swift
struct ProfileTabView: View {
    let profiles: ProfilesStore
    let userName: String
    let userEmail: String?
    let onOpenNotifications: () -> Void
    let onOpenBudgets: () -> Void
    let onOpenEmailIn: () -> Void
    let onOpenTax: () -> Void
    let onOpenCategories: () -> Void
    let onOpenExport: () -> Void
    let onOpenPrivacy: () -> Void
    let onOpenAccount: () -> Void
    let onOpenProfileDetail: (String) -> Void
    let onAddProfile: () -> Void
    let onSignOut: () -> Void

    @Environment(\.accent) private var accent

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("Profile").font(.display(28)).foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Identity header (data-bound; no hardcoded name).
                Card(padding: 14) {
                    HStack(spacing: 12) {
                        IconCircle(name: "user", tint: accent.base, soft: accent.soft, size: 44, iconSize: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(userName).font(.ui(16, .semibold)).foregroundStyle(Palette.ink)
                            if let e = userEmail { Text(e).font(.ui(13)).foregroundStyle(Palette.ink3) }
                        }
                        Spacer()
                    }
                }

                // Profile switcher grid.
                profileSwitcher

                groupLabel("Capture & tax")
                row(icon: "tag", title: "Categories & rules", id: AccessibilityID.profileRowCategories, action: onOpenCategories)
                row(icon: "shield", title: "Tax & GST settings", id: AccessibilityID.profileRowTax, action: onOpenTax)

                groupLabel("App")
                row(icon: "bell", title: "Notifications & alerts", id: AccessibilityID.profileRowNotifications, action: onOpenNotifications)
                row(icon: "wallet", title: "Budgets", id: AccessibilityID.profileRowBudgets, action: onOpenBudgets)
                row(icon: "envelope", title: "Email-in receipts", id: AccessibilityID.profileRowEmailIn, action: onOpenEmailIn)
                row(icon: "download", title: "Export & backup", id: "profile.row.export", action: onOpenExport)
                row(icon: "lock", title: "Privacy & security", id: AccessibilityID.profileRowPrivacy, action: onOpenPrivacy)

                groupLabel("Account")
                row(icon: "user", title: "Account", id: AccessibilityID.profileRowAccount, action: onOpenAccount)

                Button(action: onSignOut) {
                    Text("Sign out").font(.ui(15, .semibold)).foregroundStyle(Palette.alert)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.signOutButton)
                .padding(.top, 8)
            }
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 110)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
        .accessibilityIdentifier(AccessibilityID.profileHubScreen)
    }

    private var profileSwitcher: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(profiles.profiles, id: \.id) { p in
                Button { onOpenProfileDetail(p.id) } label: {
                    Card(padding: 12) {
                        HStack(spacing: 10) {
                            IconCircle(name: p.type == "business" ? "shield" : "wallet", tint: accent.base, soft: accent.soft, size: 32, iconSize: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.ui(13.5, .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                                Text(p.id == profiles.activeProfileId ? "Active" : p.type.capitalized)
                                    .font(.ui(11.5)).foregroundStyle(p.id == profiles.activeProfileId ? accent.base : Palette.ink3)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.profileSwitcherCardPrefix + p.id)
            }
            Button(action: onAddProfile) {
                Card(padding: 12) {
                    HStack(spacing: 8) {
                        Icon(name: "plus", size: 16, color: accent.base, lineWidth: 2.2)
                        Text("Add profile").font(.ui(13.5, .semibold)).foregroundStyle(accent.base)
                        Spacer(minLength: 0)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.profileAddButton)
        }
    }

    private func groupLabel(_ s: String) -> some View {
        Text(s).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
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

Note: confirm icon names (`user`, `shield`, `tag`, `lock`, `download`, `chevR`, `plus`, `wallet`, `bell`, `envelope`) exist in `Icons.swift`; substitute the nearest valid key for any that don't (the F6 review found `exclamationmark` invalid → `info`; do the same check here).

- [ ] **Step 2: Create compiling placeholder views**

Create each of `Snapceipt/Features/Settings/{TaxSettingsView,CategoriesView,RuleEditorView,ProfileDetailView}.swift` as a minimal overlay that compiles (Tasks 8-10 flesh them out). Example for `TaxSettingsView.swift`:

```swift
import SwiftUI
import SwiftData

struct TaxSettingsView: View {
    let profiles: ProfilesStore
    let sync: any SyncEnqueuing
    let onClose: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Tax & GST", onClose: onClose)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.cream)
        .accessibilityIdentifier(AccessibilityID.taxScreen)
    }
}
```

Create `CategoriesView` (id `categoriesScreen`, closure `onEditRule: (String?) -> Void` + `onClose`), `RuleEditorView` (id `ruleEditorScreen`, `ruleId: String?`, `onClose`), `ProfileDetailView` (id `profileDetailScreen`, `profileId: String`, `onClose`) as the same minimal `SheetHeader + Spacer` shape with the right init params (so RootView's calls in Step 3 compile).

- [ ] **Step 3: Wire RootView**

Update the `.profile` tab construction of `ProfileTabView` to pass all the new closures (mirror the existing onOpen wiring), e.g.:

```swift
ProfileTabView(
    profiles: profiles,
    userName: auth.session?.displayName ?? "You",
    userEmail: auth.session?.email,
    onOpenNotifications: { router.present(.notificationSettings) },
    onOpenBudgets: { router.present(.budgets) },
    onOpenEmailIn: { router.present(.emailIn) },
    onOpenTax: { router.present(.tax) },
    onOpenCategories: { router.present(.categories) },
    onOpenExport: { router.present(.export) },
    onOpenPrivacy: { router.present(.privacy) },       // .privacy added by the account plan; if not yet present, route to .account or omit until then
    onOpenAccount: { router.present(.account) },        // .account added by the account plan
    onOpenProfileDetail: { router.present(.profileDetail(id: $0)) },
    onAddProfile: { router.present(.addProfile) },
    onSignOut: { Task { await authVM.signOut() } })
```

If `.privacy`/`.account` don't exist yet (they're added in the account plan), temporarily point both at `.account` is impossible until that case exists — so for THIS plan, wire only `.tax`/`.categories`/`.profileDetail` and leave the Privacy/Account rows calling a no-op closure `{}` with a `// TODO(account-plan)` — the account plan replaces them. (This is the one cross-plan seam; the account plan owns Privacy/Account.)

Add the four overlay blocks (mirror `.budgets`):

```swift
.overlay { if router.overlay == .tax {
    TaxSettingsView(profiles: profiles, sync: sync, onClose: { router.dismissOverlay() })
        .environment(\.accent, accent).transition(.opacity) } }
.overlay { if router.overlay == .categories {
    CategoriesView(context: profiles.context, sync: sync, userId: profiles.userId, profileId: profiles.activeProfileId,
                   onEditRule: { router.present(.ruleEditor(id: $0)) }, onClose: { router.dismissOverlay() })
        .environment(\.accent, accent).transition(.opacity) } }
.overlay { if case let .ruleEditor(id) = router.overlay {
    RuleEditorView(context: profiles.context, sync: sync, userId: profiles.userId, profileId: profiles.activeProfileId,
                   ruleId: id, onClose: { router.dismissOverlay() })
        .environment(\.accent, accent).transition(.opacity) } }
.overlay { if case let .profileDetail(id) = router.overlay {
    ProfileDetailView(profiles: profiles, sync: sync, profileId: id,
                      onClose: { router.dismissOverlay() }, onExport: { router.present(.export) })
        .environment(\.accent, accent).transition(.opacity) } }
```

Add `.tax, .categories, .ruleEditor, .profileDetail` to the `sheetBinding` getter's `nil`-returning case, the `fullScreen` set (`Overlay.tax.id`, `Overlay.categories.id`), the setter `hasPrefix` guards (`ruleEditor`, `profileDetail`), and the `sheetContent` `EmptyView` arm — exactly as `.budgets`/`.quotes` are handled.

- [ ] **Step 4: Build + run a VM suite to confirm compilation**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/TaxSettingsViewModelTests'`
Expected: PASS (build succeeds; VM tests still pass).

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Profiles/ProfileTabView.swift Snapceipt/App/RootView.swift Snapceipt/Features/Settings/TaxSettingsView.swift Snapceipt/Features/Settings/CategoriesView.swift Snapceipt/Features/Settings/RuleEditorView.swift Snapceipt/Features/Settings/ProfileDetailView.swift
git commit -m "$(cat <<'EOF'
feat(F7 iOS): Settings hub restructure + overlay wiring (placeholder screens)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: `TaxSettingsView` (the editor)

**Files:**
- Modify: `Snapceipt/Features/Settings/TaxSettingsView.swift` (replace placeholder)

Build the screen against `TaxSettingsViewModel` (Task 3). Mirror `NotificationsSettingsView`'s `SheetHeader` + grouped `Card`s + `Toggle`/`Picker` layout. No new unit tests (VM covered); verified by build + the UI test (Task 13).

- [ ] **Step 1: Replace the body**

Implement the screen: `@State private var vm: TaxSettingsViewModel?` built in `.task`/`.onAppear` from `profiles.activeProfile` (resolve the active `Profile` via `profiles.profiles.first { $0.id == profiles.activeProfileId }`). Groups:
- **Business identity** (only when `vm.showsBusinessIdentity`): an ABN `TextField` (`AccessibilityID.taxAbnField`, `.onSubmit`/`.onChange` → `vm.setAbn`), a "Registered for GST" `Toggle` (`AccessibilityID.taxGstToggle` → `vm.setGstRegistered`), Entity type + GST basis `Picker`s bound to `vm.entityType`/`vm.gstBasis`.
- **Financial year**: a Tax-year-start `Picker` over months 1–12 (`AccessibilityID.taxFyStart` → `vm.setFinancialYearStartMonth`), a BAS-period `Picker` bound to `vm.basPeriodRaw` (`BasPeriod.allCases`), and a read-only "Next BAS due" row showing `vm.nextBasDue` formatted (accent-coloured value).
- **Deduction defaults**: a meals % `Stepper`/`Picker` (`AccessibilityID.taxMealsPct` → `vm.setMealsDeductiblePct`), a WFH c/hr field → `vm.setWfhRate`, mileage shown read-only (`vm` exposes the value via the row — or display the constant 88c).

Use the exact `Card`, `.font(.ui(...))`, `Palette`, `accent` helpers from `NotificationsSettingsView`. Keep `.accessibilityIdentifier(AccessibilityID.taxScreen)` on the root and `.accessibilityElement(children: .contain)`.

- [ ] **Step 2: Build + run**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/TaxSettingsViewModelTests'`
Expected: PASS (build succeeds).

- [ ] **Step 3: Commit**

```bash
git add Snapceipt/Features/Settings/TaxSettingsView.swift
git commit -m "$(cat <<'EOF'
feat(F7 iOS): Tax & GST editor screen

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: `CategoriesView` + `RuleEditorView`

**Files:**
- Modify: `Snapceipt/Features/Settings/CategoriesView.swift`, `RuleEditorView.swift` (replace placeholders)

- [ ] **Step 1: `CategoriesView`** — `@State var vm: CategoriesViewModel` (init from `context/sync/userId/profileId`). Two sections: **Categories** (a row per `vm.categories`: icon + label + `vm.receiptCount(cat)` + an inline default-% control → `vm.setDefaultDeductible`, `AccessibilityID.categoryRowPrefix + cat.id`) and **Smart rules** (a row per rule via a `SmartRulesViewModel` — list matcher + target; tap → `onEditRule(rule.id)`; a `+` `ruleAddButton` → `onEditRule(nil)`; swipe-to-delete → `rulesVM.delete`). `SheetHeader(title: "Categories & rules", onClose:)`, root id `categoriesScreen`. Build a `SmartRulesViewModel` alongside the categories VM (both injected the same deps).

- [ ] **Step 2: `RuleEditorView`** — `ruleId: String?`. Builds a `SmartRulesViewModel`; for an existing id, prefill from `rulesVM.rules.first { $0.id == ruleId }`. `Form` with: matchType `Picker` (merchant_contains/equals/regex), matcher `TextField`, target-category `Picker` (over `CategoriesViewModel.categories`), set-deductible % field, set-mode `Picker` (business/personal/none), enabled `Toggle`, priority `Stepper`. **Save** (`AccessibilityID.ruleEditorSave`) → `rulesVM.create(...)` or `rulesVM.update(existing){...}` then `onClose()`. Root id `ruleEditorScreen`.

- [ ] **Step 3: Build + run**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/SmartRulesViewModelTests'`
Expected: PASS (build succeeds).

- [ ] **Step 4: Commit**

```bash
git add Snapceipt/Features/Settings/CategoriesView.swift Snapceipt/Features/Settings/RuleEditorView.swift
git commit -m "$(cat <<'EOF'
feat(F7 iOS): Categories list (counts + default %) + smart-rule editor

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: `ProfileDetailView` (edit + delete + stats)

**Files:**
- Modify: `Snapceipt/Features/Settings/ProfileDetailView.swift` (replace placeholder)

- [ ] **Step 1: Implement** against `ProfilesStore`. Resolve the `Profile` via `profiles.profiles.first { $0.id == profileId }`. Sections:
  - **Hero** (profile palette gradient): initials + name + "{type} profile"; if active, an "Active" pill; else a "Switch to this profile" button (`AccessibilityID.profileDetailSwitch` → `profiles.setActive(profileId)` + `onClose()`).
  - **Details** (editable): "Profile name" `TextField` (`AccessibilityID.profileDetailNameField`) → on commit `profiles.update(p) { $0.name = ... }`; "Type" read-only; if business: "ABN" field + "Registered for GST" toggle → `profiles.update(p) { $0.abn = ...; $0.gstRegistered = ... }`; an accent picker (mirror `AddProfileView`'s `AccentSwatch` picker) → `profiles.update(p) { $0.accent1/2/3 = swatch... }`.
  - **This profile** (stats): receipt count + spent/deductible derived via `FetchDescriptor<Transaction>` for `profileId` (real counts).
  - **Manage**: "Export this profile" → `onExport()` (routes to the F2 `.export` sheet); "Delete profile" (`AccessibilityID.profileDetailDelete`, `Palette.alert`) → a `confirmationDialog` with a destructive "Delete" that calls `profiles.delete(p)` then `onClose()`. If `profiles.delete` returns false (last/active profile), show an inline note ("Switch to another profile first" / "You can't delete your only profile") instead of deleting.
  `SheetHeader(title: "Profile", onClose:)`, root id `profileDetailScreen`.

- [ ] **Step 2: Build + run**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/ProfilesStoreTests'`
Expected: PASS (build succeeds).

- [ ] **Step 3: Commit**

```bash
git add Snapceipt/Features/Settings/ProfileDetailView.swift
git commit -m "$(cat <<'EOF'
feat(F7 iOS): ProfileDetail (edit name/abn/gst/accent, stats, delete)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: FY-start wiring cleanup

**Files:**
- Modify: `Snapceipt/App/RootView.swift` (3 sites), `Snapceipt/Features/Reports/ReportsView.swift`, `Snapceipt/Features/Logbooks/MileageScreen.swift`, `Snapceipt/App/AppLaunch.swift`
- Test: `SnapceiptTests/FinancialYearWiringTests.swift`

Replace each hardcoded `startMonth: 7` with the active profile's value. The owning view already has `profiles` in scope (or can be passed it); use `profiles.activeFinancialYearStartMonth()` (Task 1).

- [ ] **Step 1: Write a guard test**

Create `SnapceiptTests/FinancialYearWiringTests.swift`:

```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("FinancialYear wiring")
struct FinancialYearWiringTests {
    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }
    @Test("a non-July FY start changes the computed financial year")
    func nonJuly() {
        // With FY start = 7 (July): 2026-08-01 is in FY 2026-27.
        // With FY start = 1 (Jan): 2026-08-01 is in FY 2026.
        let july = FinancialYear.of(date("2026-08-01"), startMonth: 7)
        let jan = FinancialYear.of(date("2026-08-01"), startMonth: 1)
        #expect(july.startYear != jan.startYear || july.label != jan.label)
    }
}
```

(Confirm the `FinancialYear` property names — `startYear`/`label` — against `FinancialYear.swift`; use the real accessors.)

- [ ] **Step 2: Run to verify it passes against existing code** (it's a characterization test of the existing `of(_:startMonth:)`):

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/FinancialYearWiringTests'`
Expected: PASS.

- [ ] **Step 3: Thread the real FY start at every site**

In `RootView.swift` replace the three `startMonth: 7` usages with `profiles.activeFinancialYearStartMonth()` (the Mileage init, the WFH init, and the export window). In `ReportsView.swift` and `MileageScreen.swift`, pass the active FY-start in from the constructing site (these views are built in `RootView`, so pass `startMonth: profiles.activeFinancialYearStartMonth()` as an init arg, or give the view a `ProfilesStore` and read it). In `AppLaunch.swift`, the dev seed can keep `startMonth: 7` (seed data) OR seed a non-7 value on one profile to exercise the path — keep 7 for determinism unless a UI test needs otherwise. Leave `FinancialYear.of`'s `startMonth: Int = 7` DEFAULT as the safe fallback.

- [ ] **Step 4: Build + full relevant suites**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/FinancialYearWiringTests' -only-testing 'SnapceiptTests/ReportsViewModelTests'`
Expected: PASS (Reports + the new wiring test; substitute the real Reports test type name).

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/App/RootView.swift Snapceipt/Features/Reports/ReportsView.swift Snapceipt/Features/Logbooks/MileageScreen.swift Snapceipt/App/AppLaunch.swift SnapceiptTests/FinancialYearWiringTests.swift
git commit -m "$(cat <<'EOF'
refactor(F7 iOS): thread tax_settings FY-start through the hardcoded startMonth sites

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: `SettingsUITests` (hermetic) + full-suite gate

**Files:**
- Create: `SnapceiptUITests/SettingsUITests.swift`

- [ ] **Step 1: Write the UI test** (mirror `BudgetsUITests`/`EmailInUITests` navigation; `launchSeeded`):

```swift
import XCTest

final class SettingsUITests: UITestCase {
    func testHubOpensTaxAndCategoriesAndProfileDetail() {
        launchSeeded()
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.profileHubScreen].waitForExistence(timeout: 10))

        // Tax & GST
        app.buttons[AccessibilityID.profileRowTax].tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.taxScreen].waitForExistence(timeout: 5))
        // toggle GST (business profile is active in the seed)
        let gst = app.switches[AccessibilityID.taxGstToggle]
        if gst.waitForExistence(timeout: 3) { gst.tap() }
        app.buttons[AccessibilityID.logbookClose].firstMatch.tap()

        // Categories
        app.buttons[AccessibilityID.profileRowCategories].tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.categoriesScreen].waitForExistence(timeout: 5))
        app.buttons[AccessibilityID.logbookClose].firstMatch.tap()

        // Profile detail via switcher card (seed profile p1)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.profileSwitcherCardPrefix)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.profileDetailScreen].waitForExistence(timeout: 5))
    }
}
```

(Confirm the SheetHeader close button's accessibility id — the explore showed `AccessibilityID.logbookClose`; use the real one.)

- [ ] **Step 2: Run the UI test**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptUITests/SettingsUITests'`
Expected: PASS (1 test).

- [ ] **Step 3: Full suite gate**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: all pass (baseline 319 unit + the new VM/helper tests; UI 12 + SettingsUITests). `git status --short` shows no `Snapceipt.xcodeproj`.

- [ ] **Step 4: Commit**

```bash
git add SnapceiptUITests/SettingsUITests.swift
git commit -m "$(cat <<'EOF'
test(F7 iOS): hermetic SettingsUITests (hub -> tax/categories/profile-detail)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:** hub restructure (§2) → Task 7; profile edit/delete/detail (§3) → Tasks 1,10; Tax editor + BAS (§4) → Tasks 2,3,8; Categories + rules (§5) → Tasks 4,5,9; FY-start cleanup (§7) → Task 11; nav (§2) → Task 6; tests (§10.2) → each VM task + Task 12. Privacy/Account rows are owned by the account plan (§6, §8) — Task 7 leaves their closures as a documented seam. ✓
**Placeholder scan:** VMs/seeders/helpers have full code; the SwiftUI screens (Tasks 8-10) are spec'd by structure + exact AccessibilityIDs + the VM calls + the exemplar to mirror (the proven F6 approach), not vague prose. Conditional notes (icon-name validity, `CategoryKey` accessor names, `FinancialYear` property names, SheetHeader close id, Reports test type name) each name the real-source check. ✓
**Type consistency:** `MockSyncEngine.Call{op,entityType,entityId}` used across all VM tests; `activeFinancialYearStartMonth()` defined in Task 1 + consumed in Task 11; `BasPeriod`/`BasSchedule.nextDue` defined in Task 2 + used in Task 3's VM; the new `Overlay` cases (Task 6) are consumed by Task 7's RootView blocks; AccessibilityIDs declared in Task 6 are referenced in Tasks 7-12. ✓
