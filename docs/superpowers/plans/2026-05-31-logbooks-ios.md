# Logbooks (Mileage + WFH) — iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Ship the two AU logbook screens (vehicle Mileage via the ATO logbook method, and WFH via the fixed-rate method) with correct claim math, the new `Vehicle`/`VehicleYear` models, `tax_settings` seeding, and a hermetic UI test — all local-first through the existing generic sync.

**Architecture:** Thin SwiftUI + SwiftData client. New `@Model`s (`Vehicle`, `VehicleYear`) and three new `MileageTrip` columns flow through the *existing* outbox/`SyncEngine` by registering two new `SyncRowMapper`s in `SyncEntityRegistry`. All claim math lives in pure, unit-tested functions (`FinancialYear`, `WFHCalc`, `MileageCalc`, `Depreciation`); view-models compute hero stats; the two screens are full-screen overlays reached from new Home QuickActions. No feature-specific network calls.

**Tech Stack:** Swift 5.10, SwiftUI, SwiftData, Swift Testing (`import Testing`) for unit tests, XCTest/XCUITest for the UI test, xcodegen (`project.yml`), iPhone 16 simulator.

> **CRITICAL — Project generation (`xcodegen`), do this in EVERY task that creates a new file.**
> The `Snapceipt.xcodeproj` is **xcodegen-generated and git-ignored** (`.gitignore` has `*.xcodeproj/`); it uses **explicit `PBXFileReference` lists**, NOT folder-synchronized groups. New `.swift` files are therefore **NOT auto-picked-up by `xcodebuild`** — you MUST run `xcodegen generate` (installed at `/opt/homebrew/bin/xcodegen`) after creating ANY new file and BEFORE the next `xcodebuild`. The `project.yml` `sources` use directory globs (`path: Snapceipt`, `SnapceiptTests`, `SnapceiptUITests`), so regenerating re-globs and includes the new files automatically. Because the project is git-ignored, **never `git add` the `.xcodeproj`** — the commit steps below only stage source/test files. Scheme `Snapceipt`; targets `Snapceipt` / `SnapceiptTests` / `SnapceiptUITests`; `Snapceipt/Shared/AccessibilityID.swift` is shared into the UITest target (verified in `project.yml`). Every task that creates a file already prepends `xcodegen generate` to its first `xcodebuild` step.

---

## File structure

**Created — pure logic + models:**
- `Snapceipt/Model/Entities/Vehicle.swift` — `@Model Vehicle: Syncable` mirroring `vehicles` (§4.3).
- `Snapceipt/Model/Entities/VehicleYear.swift` — `@Model VehicleYear: Syncable` mirroring `vehicle_years` (§4.4).
- `Snapceipt/Model/FinancialYear.swift` — pure AU financial-year helper (§5.1).
- `Snapceipt/Features/Logbooks/WFHCalc.swift` — pure WFH claim + FY aggregation + this-week bucketing (§5.2).
- `Snapceipt/Features/Logbooks/MileageCalc.swift` — pure business-use-% + vehicle-year claim + odometer→km (§5.3).
- `Snapceipt/Features/Logbooks/Depreciation.swift` — pure DV/PC depreciation helper with car-limit cap + part-year proration (§5.4).
- `Snapceipt/Features/Logbooks/TaxSettingsSeeder.swift` — ensure-one-`TaxSettings`-per-profile helper (§7).

**Created — view-models + screens + sheets:**
- `Snapceipt/Features/Logbooks/MileageViewModel.swift` — hero stats + sheet drivers for Mileage.
- `Snapceipt/Features/Logbooks/WFHViewModel.swift` — hero stats + this-week chart + one-per-day upsert for WFH.
- `Snapceipt/Features/Logbooks/LogbookChrome.swift` — shared `LbHeader`, `LbLabel`, `LbHero` sub-views.
- `Snapceipt/Features/Logbooks/MileageScreen.swift` — Mileage overlay + its sheets.
- `Snapceipt/Features/Logbooks/WFHScreen.swift` — WFH overlay + its sheet.

**Created — tests:**
- `SnapceiptTests/FinancialYearTests.swift`
- `SnapceiptTests/WFHCalcTests.swift`
- `SnapceiptTests/MileageCalcTests.swift`
- `SnapceiptTests/DepreciationTests.swift`
- `SnapceiptTests/VehicleModelTests.swift` — round-trip + profile-scoping for `Vehicle`/`VehicleYear`/extended `MileageTrip`.
- `SnapceiptTests/LogbookSyncTests.swift` — enqueue + pull-upsert for the new entities + extended `mileageTrip`.
- `SnapceiptTests/TaxSettingsSeederTests.swift` — new + legacy profile seeding.
- `SnapceiptTests/MileageViewModelTests.swift`
- `SnapceiptTests/WFHViewModelTests.swift`
- `SnapceiptUITests/LogbookUITests.swift` — hermetic add-vehicle→logbook→trip→costs→claim, and log-WFH→FY-claim.

**Modified:**
- `Snapceipt/Model/EntityType.swift` — add `case vehicle`, `case vehicleYear`.
- `Snapceipt/Model/Entities/MileageTrip.swift` — add `vehicleId`/`odometerStartM`/`odometerEndM`.
- `Snapceipt/Model/Entities/TaxSettings.swift` — WFH default `67 → 70`.
- `Snapceipt/Model/ModelContainer+Snapceipt.swift` — add `Vehicle.self`, `VehicleYear.self` to `SnapceiptSchema.models`.
- `Snapceipt/Sync/SyncEntityRegistry.swift` — `VehicleSyncMapper` + `VehicleYearSyncMapper`; extend `MileageTripSyncMapper`; register both new types.
- `Snapceipt/DesignSystem/Icons.swift` — add `car`, `wfh`, `pin`, `clock`, `info`, `arrowRight` glyph paths.
- `Snapceipt/Shared/AccessibilityID.swift` — add logbook a11y identifiers.
- `Snapceipt/App/Router.swift` — add `.mileage`, `.wfh` overlay cases.
- `Snapceipt/App/RootView.swift` — render the two overlays; add Home QuickActions; lazy-ensure `TaxSettings`.
- `Snapceipt/Features/Profiles/ProfilesStore.swift` — seed `TaxSettings` on `add(_:)`.
- `Snapceipt/Features/Onboarding/OnboardingView.swift` — seed `TaxSettings` on first-profile create.
- `SnapceiptTests/EntityTypeTests.swift` + `SnapceiptTests/SwiftDataModelTests.swift` — bump `EntityType.allCases.count` 12 → 14.

---

### Task 1: Add the two new `EntityType` cases

Two new syncable types must be addable before the models compile. THREE existing test assertions break: a count assertion in `EntityTypeTests` (line 8), a count assertion in `SwiftDataModelTests` (line 139), and the EXACT raw-value-array assertion in `EntityTypeTests.rawValues` (lines 11-19). All three are updated to expect the new `vehicle` + `vehicleYear` cases (appended last, so existing rawValues stay in order).

**Files:**
- Modify: `Snapceipt/Model/EntityType.swift` (lines 5-18)
- Modify: `SnapceiptTests/EntityTypeTests.swift` (line 8 count + lines 13-17 expected array)
- Modify: `SnapceiptTests/SwiftDataModelTests.swift` (lines 137-140)

- [ ] **Step 1: Update ALL THREE failing assertions first (TDD: change the spec).**
  In `SnapceiptTests/EntityTypeTests.swift` replace line 8:
  ```swift
        #expect(EntityType.allCases.count == 14)
  ```
  In the SAME file, update the `expected` array in `rawValues()` (lines 13-17) so it ends with the two new cases — they are appended last in `EntityType` so order is preserved:
  ```swift
        let expected = [
            "transaction", "lineItem", "profile", "category", "smartRule",
            "budget", "loyaltyCard", "quote", "quoteLineItem",
            "mileageTrip", "wfhLog", "taxSettings", "vehicle", "vehicleYear",
        ]
  ```
  Also update that test's title comment from `"has exactly the 12 syncable cases"` (line 6) to `"has exactly the 14 syncable cases"`.
  In `SnapceiptTests/SwiftDataModelTests.swift` replace the body of `entityTypeCount` (lines 137-140) so it reads:
  ```swift
    @Test("EntityType still has exactly the 14 syncable cases")
    func entityTypeCount() {
        #expect(EntityType.allCases.count == 14)
    }
  ```

- [ ] **Step 2: Run the tests — expect FAIL (cases still 12).**
  ```
  xcodegen generate
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/EntityTypeTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: failures `Expectation failed: (EntityType.allCases.count → 12) == 14` AND the `rawValues` array mismatch (`allCases.map(\.rawValue)` has 12 entries, `expected` has 14).
  (`xcodegen generate` is harmless here — no new files yet — but establishes the habit; see the "Project generation" note at the top of this plan.)

- [ ] **Step 3: Add the two cases.**
  In `Snapceipt/Model/EntityType.swift`, after `case taxSettings` (line 17), add:
  ```swift
    case vehicle
    case vehicleYear
  ```
  Also update the doc comment on line 3 from "The 12 syncable entity types." to "The 14 syncable entity types.".

- [ ] **Step 4: Run — expect PASS.**
  ```
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/EntityTypeTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `Test Suite 'EntityTypeTests' passed`.

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Model/EntityType.swift SnapceiptTests/EntityTypeTests.swift SnapceiptTests/SwiftDataModelTests.swift
  git commit -m "Add vehicle + vehicleYear EntityType cases

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 2: Add the `Vehicle` + `VehicleYear` @Models, extend `MileageTrip`, bump WFH default, register in schema

Add the two new `@Model`s, the three `MileageTrip` columns, the `TaxSettings` default change, and the schema registration. Verify with a round-trip + profile-scoping test. (Verified exemplars: `MileageTrip.swift`, `TaxSettings.swift`, `SnapceiptSchema.models` in `ModelContainer+Snapceipt.swift`.)

**Files:**
- Create: `Snapceipt/Model/Entities/Vehicle.swift`
- Create: `Snapceipt/Model/Entities/VehicleYear.swift`
- Modify: `Snapceipt/Model/Entities/MileageTrip.swift`
- Modify: `Snapceipt/Model/Entities/TaxSettings.swift` (line 32)
- Modify: `Snapceipt/Model/ModelContainer+Snapceipt.swift` (lines 7-22)
- Test: `SnapceiptTests/VehicleModelTests.swift`

- [ ] **Step 1: Write the FAILING test.**
  Create `SnapceiptTests/VehicleModelTests.swift`:
  ```swift
  import Testing
  import Foundation
  import SwiftData
  @testable import Snapceipt

  @Suite("VehicleModel")
  struct VehicleModelTests {

      private func makeContext() throws -> ModelContext {
          let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
          return ModelContext(container)
      }

      @Test("Vehicle round-trips with all logbook fields + sync envelope")
      func vehicleRoundTrip() throws {
          let ctx = try makeContext()
          let v = Vehicle(
              userId: "u1", profileId: "p1",
              make: "Toyota", model: "HiLux", engineCc: 2800, registration: "ABC123",
              logbookStartDate: "2025-08-12", logbookEndDate: "2025-11-04",
              businessUsePct: 78, rev: 2, lastEditedDeviceId: "dev-1"
          )
          ctx.insert(v)
          try ctx.save()

          let rows = try ctx.fetch(FetchDescriptor<Vehicle>())
          let got = try #require(rows.first)
          #expect(got.make == "Toyota")
          #expect(got.model == "HiLux")
          #expect(got.engineCc == 2800)
          #expect(got.registration == "ABC123")
          #expect(got.logbookStartDate == "2025-08-12")
          #expect(got.logbookEndDate == "2025-11-04")
          #expect(got.businessUsePct == 78)
          #expect(got.userId == "u1")
          #expect(got.profileId == "p1")
          #expect(got.rev == 2)
          #expect(got.lastEditedDeviceId == "dev-1")
          #expect(got.entityType == .vehicle)
      }

      @Test("VehicleYear round-trips with all cost fields + claim cache")
      func vehicleYearRoundTrip() throws {
          let ctx = try makeContext()
          let vy = VehicleYear(
              userId: "u1", profileId: "p1", vehicleId: "veh-1", fyStartYear: 2025,
              odometerOpenM: 10_000_000, odometerCloseM: 25_000_000,
              fuelCents: 200_000, regoCents: 80_000, insuranceCents: 90_000,
              servicingCents: 40_000, otherCents: 2_000, depreciationCents: 0,
              businessUsePct: 78, claimCents: 321_360
          )
          ctx.insert(vy)
          try ctx.save()

          let rows = try ctx.fetch(FetchDescriptor<VehicleYear>())
          let got = try #require(rows.first)
          #expect(got.vehicleId == "veh-1")
          #expect(got.fyStartYear == 2025)
          #expect(got.fuelCents == 200_000)
          #expect(got.regoCents == 80_000)
          #expect(got.insuranceCents == 90_000)
          #expect(got.servicingCents == 40_000)
          #expect(got.otherCents == 2_000)
          #expect(got.depreciationCents == 0)
          #expect(got.businessUsePct == 78)
          #expect(got.claimCents == 321_360)
          #expect(got.entityType == .vehicleYear)
      }

      @Test("MileageTrip carries vehicleId + odometer columns and stays profile-scoped")
      func mileageTripExtended() throws {
          let ctx = try makeContext()
          let pid = "p1"
          let t = MileageTrip(
              userId: "u1", profileId: pid, tripDate: "2025-09-01",
              distanceM: 12_400, isBusiness: true,
              vehicleId: "veh-1", odometerStartM: 10_000_000, odometerEndM: 10_012_400
          )
          ctx.insert(t)
          try ctx.save()

          let rows = try ctx.fetch(
              FetchDescriptor<MileageTrip>(predicate: #Predicate { $0.profileId == pid }))
          let got = try #require(rows.first)
          #expect(got.vehicleId == "veh-1")
          #expect(got.odometerStartM == 10_000_000)
          #expect(got.odometerEndM == 10_012_400)
          #expect(got.distanceM == 12_400)
          #expect(got.entityType == .mileageTrip)
      }

      @Test("TaxSettings WFH default is now 70 cents/hour")
      func wfhDefault70() {
          let s = TaxSettings(userId: "u1", profileId: "p1")
          #expect(s.wfhRateCentsPerHour == 70)
          #expect(s.mileageRateCentsPerKm == 88)
          #expect(s.financialYearStartMonth == 7)
          #expect(s.gstRateBps == 1000)
          #expect(s.mealsDeductiblePct == 50)
      }
  }
  ```

- [ ] **Step 2: Run — expect FAIL (Vehicle/VehicleYear undeclared, new init params missing).**
  ```
  xcodegen generate   # picks up the new SnapceiptTests/VehicleModelTests.swift
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/VehicleModelTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: compile errors `cannot find 'Vehicle' in scope`, `extra arguments 'vehicleId'…`. (If you forget `xcodegen generate`, the new test file is silently absent from the target and "0 tests ran" — not a real FAIL.)

- [ ] **Step 3a: Create `Snapceipt/Model/Entities/Vehicle.swift`.**
  ```swift
  import Foundation
  import SwiftData

  /// A vehicle tracked under the ATO logbook method. Mirrors D1 `vehicles` (§4.3).
  /// `businessUsePct` is cached from in-window trips; the logbook window is the
  /// formal 12-week period (valid 5 years).
  @Model
  final class Vehicle: Syncable {
      @Attribute(.unique) var id: String
      var userId: String
      var profileId: String?

      var make: String?
      var model: String?
      var engineCc: Int?
      var registration: String?
      var logbookStartDate: String?    // "YYYY-MM-DD", nil until logbook started
      var logbookEndDate: String?      // "YYYY-MM-DD", = start + ~12 weeks (editable)
      var businessUsePct: Int?         // 0..100, cached from in-window trips; nil until computed

      var createdAt: Int
      var updatedAt: Int
      var deletedAt: Int?
      var rev: Int
      var lastEditedDeviceId: String?

      var entityType: EntityType { .vehicle }

      init(
          id: String = Snapceipt.ID.uuidv7(),
          userId: String,
          profileId: String?,
          make: String? = nil,
          model: String? = nil,
          engineCc: Int? = nil,
          registration: String? = nil,
          logbookStartDate: String? = nil,
          logbookEndDate: String? = nil,
          businessUsePct: Int? = nil,
          createdAt: Int = Epoch.nowMs(),
          updatedAt: Int = Epoch.nowMs(),
          deletedAt: Int? = nil,
          rev: Int = 0,
          lastEditedDeviceId: String? = nil
      ) {
          self.id = id
          self.userId = userId
          self.profileId = profileId
          self.make = make
          self.model = model
          self.engineCc = engineCc
          self.registration = registration
          self.logbookStartDate = logbookStartDate
          self.logbookEndDate = logbookEndDate
          self.businessUsePct = businessUsePct
          self.createdAt = createdAt
          self.updatedAt = updatedAt
          self.deletedAt = deletedAt
          self.rev = rev
          self.lastEditedDeviceId = lastEditedDeviceId
      }
  }
  ```

- [ ] **Step 3b: Create `Snapceipt/Model/Entities/VehicleYear.swift`.**
  ```swift
  import Foundation
  import SwiftData

  /// One vehicle's running costs + claim for a single financial year. Mirrors D1
  /// `vehicle_years` (§4.4). `fyStartYear` 2025 => FY2025-26. `claimCents` is cached
  /// = `businessUsePct%` × sum(costs), with `businessUsePct` snapshotted at compute.
  @Model
  final class VehicleYear: Syncable {
      @Attribute(.unique) var id: String
      var userId: String
      var profileId: String?

      var vehicleId: String
      var fyStartYear: Int            // 2025 => FY2025-26
      var odometerOpenM: Int?
      var odometerCloseM: Int?
      var fuelCents: Int
      var regoCents: Int
      var insuranceCents: Int
      var servicingCents: Int
      var otherCents: Int
      var depreciationCents: Int
      var businessUsePct: Int?        // snapshot at compute time
      var claimCents: Int?            // cached = pct% * sum(costs)

      var createdAt: Int
      var updatedAt: Int
      var deletedAt: Int?
      var rev: Int
      var lastEditedDeviceId: String?

      var entityType: EntityType { .vehicleYear }

      init(
          id: String = Snapceipt.ID.uuidv7(),
          userId: String,
          profileId: String?,
          vehicleId: String,
          fyStartYear: Int,
          odometerOpenM: Int? = nil,
          odometerCloseM: Int? = nil,
          fuelCents: Int = 0,
          regoCents: Int = 0,
          insuranceCents: Int = 0,
          servicingCents: Int = 0,
          otherCents: Int = 0,
          depreciationCents: Int = 0,
          businessUsePct: Int? = nil,
          claimCents: Int? = nil,
          createdAt: Int = Epoch.nowMs(),
          updatedAt: Int = Epoch.nowMs(),
          deletedAt: Int? = nil,
          rev: Int = 0,
          lastEditedDeviceId: String? = nil
      ) {
          self.id = id
          self.userId = userId
          self.profileId = profileId
          self.vehicleId = vehicleId
          self.fyStartYear = fyStartYear
          self.odometerOpenM = odometerOpenM
          self.odometerCloseM = odometerCloseM
          self.fuelCents = fuelCents
          self.regoCents = regoCents
          self.insuranceCents = insuranceCents
          self.servicingCents = servicingCents
          self.otherCents = otherCents
          self.depreciationCents = depreciationCents
          self.businessUsePct = businessUsePct
          self.claimCents = claimCents
          self.createdAt = createdAt
          self.updatedAt = updatedAt
          self.deletedAt = deletedAt
          self.rev = rev
          self.lastEditedDeviceId = lastEditedDeviceId
      }
  }
  ```

- [ ] **Step 3c: Extend `MileageTrip`.** In `Snapceipt/Model/Entities/MileageTrip.swift`, after the `autoTracked` stored property (line 20) add three properties:
  ```swift
      var vehicleId: String?           // FK -> vehicles(id); the trip's car
      var odometerStartM: Int?         // metres
      var odometerEndM: Int?           // metres; must be > start
  ```
  In the `init` signature, after `autoTracked: Bool = false,` (line 42) add:
  ```swift
          vehicleId: String? = nil,
          odometerStartM: Int? = nil,
          odometerEndM: Int? = nil,
  ```
  In the `init` body, after `self.autoTracked = autoTracked` (line 60) add:
  ```swift
          self.vehicleId = vehicleId
          self.odometerStartM = odometerStartM
          self.odometerEndM = odometerEndM
  ```

- [ ] **Step 3d: Bump the WFH default.** In `Snapceipt/Model/Entities/TaxSettings.swift` line 32, change:
  ```swift
          wfhRateCentsPerHour: Int = 70,
  ```

- [ ] **Step 3e: Register the models.** In `Snapceipt/Model/ModelContainer+Snapceipt.swift`, in `SnapceiptSchema.models` after `MileageTrip.self,` (line 14) add:
  ```swift
          Vehicle.self,
          VehicleYear.self,
  ```
  Update the doc comment on line 4-5 from "the 12 syncable domain models" to "the 14 syncable domain models".

- [ ] **Step 4: Run — expect PASS.**
  ```
  xcodegen generate   # picks up the new Vehicle.swift + VehicleYear.swift
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/VehicleModelTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `Test Suite 'VehicleModelTests' passed` (4 tests).

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Model/Entities/Vehicle.swift Snapceipt/Model/Entities/VehicleYear.swift Snapceipt/Model/Entities/MileageTrip.swift Snapceipt/Model/Entities/TaxSettings.swift Snapceipt/Model/ModelContainer+Snapceipt.swift SnapceiptTests/VehicleModelTests.swift
  git commit -m "Add Vehicle + VehicleYear models, extend MileageTrip, WFH default 70

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 3: Register sync mappers for `Vehicle`, `VehicleYear`, extend `MileageTripSyncMapper`

Wire the new entities into the generic outbox/pull engine by copying the `MileageTripSyncMapper` pattern (verified: `upsert`/`payload`/`SyncableMutableEnvelope`+`MutableSyncRow` conformance + `register(...)` in `SyncEntityRegistry.init`). The `str`/`num`/`boolv` helpers and `sharedFields` are verified to exist in the same file. Extend the existing `MileageTripSyncMapper` with the three new fields.

**Files:**
- Modify: `Snapceipt/Sync/SyncEntityRegistry.swift` (register block lines 35-48; `MileageTripSyncMapper` lines 571-611; add two new mapper blocks at end of file before line 683)
- Test: `SnapceiptTests/LogbookSyncTests.swift`

- [ ] **Step 1: Write the FAILING test.**
  Create `SnapceiptTests/LogbookSyncTests.swift`:
  ```swift
  import Foundation
  import SwiftData
  import Testing
  @testable import Snapceipt

  @MainActor
  private func makeEngine() throws -> (SyncEngine, ModelContext, MockAPIClient, AuthStore, ToastCenter) {
      let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
      let context = ModelContext(container)
      let api = MockAPIClient()
      let auth = AuthStore()
      let toast = ToastCenter()
      let engine = SyncEngine(api: api, context: context, auth: auth, toast: toast)
      UserDefaults.standard.removeObject(forKey: "sc.syncCursor")
      return (engine, context, api, auth, toast)
  }

  /// Build a server entity envelope through PullChange's real Decodable path
  /// (it has a custom init(from:), so there is no memberwise initializer).
  private func envelope(
      type: String, id: String, userId: String = "u1",
      rev: Int, updatedAt: Int, createdAt: Int? = nil, deletedAt: Int? = nil,
      extra: [String: Any] = [:]
  ) -> PullChange {
      var fields: [String: Any] = [
          "type": type, "id": id, "userId": userId, "rev": rev,
          "createdAt": createdAt ?? updatedAt, "updatedAt": updatedAt,
          "lastEditedDeviceId": NSNull(),
      ]
      if let deletedAt { fields["deletedAt"] = deletedAt } else { fields["deletedAt"] = NSNull() }
      for (k, v) in extra { fields[k] = v }
      let data = try! JSONSerialization.data(withJSONObject: fields)
      return try! JSONDecoder().decode(PullChange.self, from: data)
  }

  @MainActor
  @Suite(.serialized)
  struct LogbookSyncTests {

      @Test func enqueueVehicleEncodesAllFields() throws {
          let (engine, context, _, _, _) = try makeEngine()
          let v = Vehicle(userId: "u1", profileId: "p1", make: "Toyota",
                          model: "HiLux", engineCc: 2800, registration: "ABC123",
                          logbookStartDate: "2025-08-12", logbookEndDate: "2025-11-04",
                          businessUsePct: 78)
          context.insert(v)
          engine.enqueue(op: "upsert", entityType: .vehicle, entity: v)

          let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
          #expect(outbox.count == 1)
          #expect(outbox[0].entityType == EntityType.vehicle.rawValue)
          #expect(outbox[0].payloadJSON.contains("HiLux"))
          #expect(outbox[0].payloadJSON.contains("logbookStartDate"))
          #expect(outbox[0].payloadJSON.contains("businessUsePct"))
      }

      @Test func pullUpsertsVehicle() async throws {
          let (engine, context, api, _, _) = try makeEngine()
          let id = ID.uuidv7()
          api.pullPages = [
              PullResponse(
                  changes: [envelope(type: "vehicle", id: id, rev: 3, updatedAt: 7000,
                                     extra: ["profileId": "p1", "make": "Toyota", "model": "HiLux",
                                             "engineCc": 2800, "registration": "ABC123",
                                             "logbookStartDate": "2025-08-12",
                                             "logbookEndDate": "2025-11-04", "businessUsePct": 78])],
                  nextCursor: "C1", hasMore: false, serverTime: 7000)
          ]
          await engine.pull()

          let rows = try context.fetch(FetchDescriptor<Vehicle>(predicate: #Predicate { $0.id == id }))
          #expect(rows.count == 1)
          #expect(rows[0].make == "Toyota")
          #expect(rows[0].businessUsePct == 78)
          #expect(rows[0].rev == 3)
      }

      @Test func pullUpsertsVehicleYear() async throws {
          let (engine, context, api, _, _) = try makeEngine()
          let id = ID.uuidv7()
          api.pullPages = [
              PullResponse(
                  changes: [envelope(type: "vehicleYear", id: id, rev: 1, updatedAt: 5000,
                                     extra: ["profileId": "p1", "vehicleId": "veh-1",
                                             "fyStartYear": 2025, "fuelCents": 200_000,
                                             "businessUsePct": 78, "claimCents": 321_360])],
                  nextCursor: "C2", hasMore: false, serverTime: 5000)
          ]
          await engine.pull()

          let rows = try context.fetch(FetchDescriptor<VehicleYear>(predicate: #Predicate { $0.id == id }))
          #expect(rows.count == 1)
          #expect(rows[0].vehicleId == "veh-1")
          #expect(rows[0].fyStartYear == 2025)
          #expect(rows[0].fuelCents == 200_000)
          #expect(rows[0].claimCents == 321_360)
      }

      @Test func mileageTripPayloadAndPullCarryNewFields() async throws {
          let (engine, context, api, _, _) = try makeEngine()
          // enqueue carries the new fields:
          let t = MileageTrip(userId: "u1", profileId: "p1", tripDate: "2025-09-01",
                              distanceM: 12_400, isBusiness: true, vehicleId: "veh-1",
                              odometerStartM: 10_000_000, odometerEndM: 10_012_400)
          context.insert(t)
          engine.enqueue(op: "upsert", entityType: .mileageTrip, entity: t)
          let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
          #expect(outbox[0].payloadJSON.contains("odometerStartM"))
          #expect(outbox[0].payloadJSON.contains("veh-1"))

          // pull applies the new fields:
          let id = ID.uuidv7()
          api.pullPages = [
              PullResponse(
                  changes: [envelope(type: "mileageTrip", id: id, rev: 1, updatedAt: 6000,
                                     extra: ["profileId": "p1", "tripDate": "2025-09-02",
                                             "distanceM": 8000, "isBusiness": false,
                                             "vehicleId": "veh-9", "odometerStartM": 1000,
                                             "odometerEndM": 9000])],
                  nextCursor: "C3", hasMore: false, serverTime: 6000)
          ]
          await engine.pull()
          let rows = try context.fetch(FetchDescriptor<MileageTrip>(predicate: #Predicate { $0.id == id }))
          #expect(rows.count == 1)
          #expect(rows[0].vehicleId == "veh-9")
          #expect(rows[0].odometerStartM == 1000)
          #expect(rows[0].odometerEndM == 9000)
      }
  }
  ```

- [ ] **Step 2: Run — expect FAIL (no handler registered → pulled rows dropped; payload lacks new fields).**
  ```
  xcodegen generate   # picks up the new SnapceiptTests/LogbookSyncTests.swift
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/LogbookSyncTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: failures `Expectation failed: (rows.count → 0) == 1` and `…payloadJSON.contains("odometerStartM")`.

- [ ] **Step 3a: Register the two new types.** In `Snapceipt/Sync/SyncEntityRegistry.swift`, in `init()` after `register(.taxSettings, TaxSettingsSyncMapper())` (line 47) add:
  ```swift
          register(.vehicle, VehicleSyncMapper())
          register(.vehicleYear, VehicleYearSyncMapper())
  ```

- [ ] **Step 3b: Extend `MileageTripSyncMapper`.** In the `upsert` method, after `if let v = env.bool("autoTracked") { row.autoTracked = v }` (line 590) add:
  ```swift
          if let v = env.string("vehicleId") { row.vehicleId = v }
          if let v = env.int("odometerStartM") { row.odometerStartM = v }
          if let v = env.int("odometerEndM") { row.odometerEndM = v }
  ```
  In the `payload` method, after `f["autoTracked"] = boolv(r.autoTracked)` (line 603) add:
  ```swift
          f["vehicleId"] = str(r.vehicleId)
          f["odometerStartM"] = num(r.odometerStartM)
          f["odometerEndM"] = num(r.odometerEndM)
  ```

- [ ] **Step 3c: Add the two new mapper blocks + conformances.** At the end of `Snapceipt/Sync/SyncEntityRegistry.swift` (after the `TaxSettings` extension on line 682), append:
  ```swift

  // MARK: - Vehicle

  private struct VehicleSyncMapper: SyncRowMapper {
      func upsert(_ context: ModelContext, _ env: PullChange) {
          let row = fetch(context, env.id) ?? {
              let x = Vehicle(userId: env.userId, profileId: env.profileId)
              x.id = env.id
              context.insert(x)
              return x
          }()
          applySharedEnvelope(row, env)
          row.profileId = env.profileId
          if let v = env.string("make") { row.make = v }
          if let v = env.string("model") { row.model = v }
          if let v = env.int("engineCc") { row.engineCc = v }
          if let v = env.string("registration") { row.registration = v }
          if let v = env.string("logbookStartDate") { row.logbookStartDate = v }
          if let v = env.string("logbookEndDate") { row.logbookEndDate = v }
          if let v = env.int("businessUsePct") { row.businessUsePct = v }
      }

      func payload(_ r: Vehicle) -> [String: JSONValue] {
          var f = sharedFields(r)
          f["make"] = str(r.make)
          f["model"] = str(r.model)
          f["engineCc"] = num(r.engineCc)
          f["registration"] = str(r.registration)
          f["logbookStartDate"] = str(r.logbookStartDate)
          f["logbookEndDate"] = str(r.logbookEndDate)
          f["businessUsePct"] = num(r.businessUsePct)
          return f
      }
  }

  extension Vehicle: SyncableMutableEnvelope, MutableSyncRow {
      func setRev(_ rev: Int) { self.rev = rev }
      func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
  }

  // MARK: - VehicleYear

  private struct VehicleYearSyncMapper: SyncRowMapper {
      func upsert(_ context: ModelContext, _ env: PullChange) {
          let row = fetch(context, env.id) ?? {
              let x = VehicleYear(userId: env.userId, profileId: env.profileId,
                                  vehicleId: env.string("vehicleId") ?? "",
                                  fyStartYear: env.int("fyStartYear") ?? 0)
              x.id = env.id
              context.insert(x)
              return x
          }()
          applySharedEnvelope(row, env)
          row.profileId = env.profileId
          if let v = env.string("vehicleId") { row.vehicleId = v }
          if let v = env.int("fyStartYear") { row.fyStartYear = v }
          if let v = env.int("odometerOpenM") { row.odometerOpenM = v }
          if let v = env.int("odometerCloseM") { row.odometerCloseM = v }
          if let v = env.int("fuelCents") { row.fuelCents = v }
          if let v = env.int("regoCents") { row.regoCents = v }
          if let v = env.int("insuranceCents") { row.insuranceCents = v }
          if let v = env.int("servicingCents") { row.servicingCents = v }
          if let v = env.int("otherCents") { row.otherCents = v }
          if let v = env.int("depreciationCents") { row.depreciationCents = v }
          if let v = env.int("businessUsePct") { row.businessUsePct = v }
          if let v = env.int("claimCents") { row.claimCents = v }
      }

      func payload(_ r: VehicleYear) -> [String: JSONValue] {
          var f = sharedFields(r)
          f["vehicleId"] = .string(r.vehicleId)
          f["fyStartYear"] = num(r.fyStartYear)
          f["odometerOpenM"] = num(r.odometerOpenM)
          f["odometerCloseM"] = num(r.odometerCloseM)
          f["fuelCents"] = num(r.fuelCents)
          f["regoCents"] = num(r.regoCents)
          f["insuranceCents"] = num(r.insuranceCents)
          f["servicingCents"] = num(r.servicingCents)
          f["otherCents"] = num(r.otherCents)
          f["depreciationCents"] = num(r.depreciationCents)
          f["businessUsePct"] = num(r.businessUsePct)
          f["claimCents"] = num(r.claimCents)
          return f
      }
  }

  extension VehicleYear: SyncableMutableEnvelope, MutableSyncRow {
      func setRev(_ rev: Int) { self.rev = rev }
      func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
  }
  ```

- [ ] **Step 4: Run — expect PASS.**
  ```
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/LogbookSyncTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `Test Suite 'LogbookSyncTests' passed` (4 tests).

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Sync/SyncEntityRegistry.swift SnapceiptTests/LogbookSyncTests.swift
  git commit -m "Wire Vehicle/VehicleYear sync mappers + extend MileageTrip payload

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 4: `FinancialYear` helper (pure, §5.1)

A pure util giving AU FY boundaries/labels/membership, driven by `tax_settings.financial_year_start_month`. Edge cases (30 Jun vs 1 Jul) pinned in tests. All dates in UTC to match the app's ISO date handling (`Formatters.swift` parses `"yyyy-MM-dd"` in UTC).

**Files:**
- Create: `Snapceipt/Model/FinancialYear.swift`
- Test: `SnapceiptTests/FinancialYearTests.swift`

- [ ] **Step 1: Write the FAILING test.**
  Create `SnapceiptTests/FinancialYearTests.swift`:
  ```swift
  import Testing
  import Foundation
  @testable import Snapceipt

  @Suite("FinancialYear")
  struct FinancialYearTests {

      /// UTC date from a "yyyy-MM-dd" string (matches the app's ISO date handling).
      private func d(_ iso: String) -> Date {
          let f = DateFormatter()
          f.locale = Locale(identifier: "en_US_POSIX")
          f.timeZone = TimeZone(identifier: "UTC")
          f.dateFormat = "yyyy-MM-dd"
          return f.date(from: iso)!
      }

      @Test("1 Jul 2025 starts FY2025-26")
      func startBoundary() {
          let fy = FinancialYear.of(d("2025-07-01"), startMonth: 7)
          #expect(fy.startYear == 2025)
          #expect(fy.label == "FY2025-26")
      }

      @Test("30 Jun 2025 belongs to the PREVIOUS FY2024-25")
      func endBoundary() {
          let fy = FinancialYear.of(d("2025-06-30"), startMonth: 7)
          #expect(fy.startYear == 2024)
          #expect(fy.label == "FY2024-25")
      }

      @Test("a mid-year date sits in the right FY")
      func midYear() {
          let fy = FinancialYear.of(d("2026-03-15"), startMonth: 7)
          #expect(fy.startYear == 2025)
          #expect(fy.label == "FY2025-26")
      }

      @Test("label wraps the century at FY1999-00")
      func centuryWrap() {
          let fy = FinancialYear.of(d("1999-09-01"), startMonth: 7)
          #expect(fy.startYear == 1999)
          #expect(fy.label == "FY1999-00")
      }

      @Test("isIn includes 1 Jul, excludes the next 1 Jul")
      func membership() {
          #expect(FinancialYear.isIn(d("2025-07-01"), fyStartYear: 2025, startMonth: 7) == true)
          #expect(FinancialYear.isIn(d("2026-06-30"), fyStartYear: 2025, startMonth: 7) == true)
          #expect(FinancialYear.isIn(d("2026-07-01"), fyStartYear: 2025, startMonth: 7) == false)
          #expect(FinancialYear.isIn(d("2025-06-30"), fyStartYear: 2025, startMonth: 7) == false)
      }

      @Test("isInString accepts a 'yyyy-MM-dd' trip date")
      func membershipString() {
          #expect(FinancialYear.isIn("2025-08-12", fyStartYear: 2025, startMonth: 7) == true)
          #expect(FinancialYear.isIn("2025-06-30", fyStartYear: 2025, startMonth: 7) == false)
          #expect(FinancialYear.isIn("not-a-date", fyStartYear: 2025, startMonth: 7) == false)
      }
  }
  ```

- [ ] **Step 2: Run — expect FAIL (`cannot find 'FinancialYear' in scope`).**
  ```
  xcodegen generate   # picks up the new SnapceiptTests/FinancialYearTests.swift
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/FinancialYearTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```

- [ ] **Step 3: Implement.** Create `Snapceipt/Model/FinancialYear.swift`:
  ```swift
  import Foundation

  /// AU financial-year boundaries/labels/membership, driven by
  /// `tax_settings.financial_year_start_month` (7 => 1 Jul..30 Jun). All dates are
  /// treated in UTC to match the app's "yyyy-MM-dd" ISO handling (Formatters.swift).
  enum FinancialYear {
      /// One financial year's window + identity.
      struct Window: Equatable {
          let start: Date       // inclusive, 00:00 UTC on the 1st of `startMonth`
          let end: Date         // exclusive, 00:00 UTC on the 1st of `startMonth` a year later
          let startYear: Int    // 2025 => FY2025-26
          let label: String     // "FY2025-26"
      }

      private static var utcCalendar: Calendar {
          var c = Calendar(identifier: .gregorian)
          c.timeZone = TimeZone(identifier: "UTC")!
          return c
      }

      private static let isoParser: DateFormatter = {
          let f = DateFormatter()
          f.locale = Locale(identifier: "en_US_POSIX")
          f.timeZone = TimeZone(identifier: "UTC")
          f.dateFormat = "yyyy-MM-dd"
          return f
      }()

      /// "FY2025-26" for startYear 2025; wraps the century ("FY1999-00").
      static func label(startYear: Int) -> String {
          let endTwo = String(format: "%02d", (startYear + 1) % 100)
          return "FY\(startYear)-\(endTwo)"
      }

      /// The financial year containing `date`.
      static func of(_ date: Date, startMonth: Int = 7) -> Window {
          let cal = utcCalendar
          let comps = cal.dateComponents([.year, .month], from: date)
          let year = comps.year!
          let month = comps.month!
          let startYear = month >= startMonth ? year : year - 1
          let start = cal.date(from: DateComponents(year: startYear, month: startMonth, day: 1))!
          let end = cal.date(from: DateComponents(year: startYear + 1, month: startMonth, day: 1))!
          return Window(start: start, end: end, startYear: startYear, label: label(startYear: startYear))
      }

      /// True when `date` falls in FY `fyStartYear` ([start, nextStart)).
      static func isIn(_ date: Date, fyStartYear: Int, startMonth: Int = 7) -> Bool {
          let cal = utcCalendar
          let start = cal.date(from: DateComponents(year: fyStartYear, month: startMonth, day: 1))!
          let end = cal.date(from: DateComponents(year: fyStartYear + 1, month: startMonth, day: 1))!
          return date >= start && date < end
      }

      /// True when a "yyyy-MM-dd" string parses and falls in FY `fyStartYear`.
      static func isIn(_ iso: String, fyStartYear: Int, startMonth: Int = 7) -> Bool {
          guard let date = isoParser.date(from: iso) else { return false }
          return isIn(date, fyStartYear: fyStartYear, startMonth: startMonth)
      }
  }
  ```

- [ ] **Step 4: Run — expect PASS.**
  ```
  xcodegen generate   # picks up the new Snapceipt/Model/FinancialYear.swift
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/FinancialYearTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `Test Suite 'FinancialYearTests' passed` (6 tests).

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Model/FinancialYear.swift SnapceiptTests/FinancialYearTests.swift
  git commit -m "Add pure FinancialYear helper (boundaries/labels/membership)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 5: `WFHCalc` (pure WFH claim + FY aggregation + this-week bucketing, §5.2)

Pure functions only — no SwiftData. Per-entry claim, FY hero aggregation, this-week minute buckets (Mon–Sun).

**Files:**
- Create: `Snapceipt/Features/Logbooks/WFHCalc.swift`
- Test: `SnapceiptTests/WFHCalcTests.swift`

- [ ] **Step 1: Write the FAILING test.**
  Create `SnapceiptTests/WFHCalcTests.swift`:
  ```swift
  import Testing
  import Foundation
  @testable import Snapceipt

  @Suite("WFHCalc")
  struct WFHCalcTests {

      @Test("per-entry claim rounds minutes/60 * rate")
      func entryClaim() {
          // 90 minutes @ 70c/hr = 1.5h * 70 = 105 cents
          #expect(WFHCalc.claimCents(minutes: 90, rateCentsPerHour: 70) == 105)
          // 25 minutes @ 70c/hr = 0.41666h * 70 = 29.16.. -> 29
          #expect(WFHCalc.claimCents(minutes: 25, rateCentsPerHour: 70) == 29)
          #expect(WFHCalc.claimCents(minutes: 0, rateCentsPerHour: 70) == 0)
      }

      @Test("FY hero aggregates minutes + claim over the FY logs")
      func heroAggregation() {
          let logs = [
              WFHCalc.Entry(logDate: "2025-07-02", minutes: 480, claimCents: 560),  // in FY25-26
              WFHCalc.Entry(logDate: "2025-08-10", minutes: 300, claimCents: 350),  // in FY25-26
              WFHCalc.Entry(logDate: "2025-06-30", minutes: 480, claimCents: 560),  // PREV FY -> excluded
          ]
          let h = WFHCalc.hero(entries: logs, fyStartYear: 2025, startMonth: 7)
          #expect(h.totalMinutes == 780)
          #expect(h.claimCents == 910)
          #expect(h.daysLogged == 2)
          // avg/day hours = (780/60) / 2 = 6.5
          #expect(abs(h.avgHoursPerDay - 6.5) < 0.0001)
      }

      @Test("empty FY hero is all-zero with avg 0")
      func heroEmpty() {
          let h = WFHCalc.hero(entries: [], fyStartYear: 2025, startMonth: 7)
          #expect(h.totalMinutes == 0)
          #expect(h.claimCents == 0)
          #expect(h.daysLogged == 0)
          #expect(h.avgHoursPerDay == 0)
      }

      @Test("this-week buckets minutes into Mon..Sun for the week containing `today`")
      func thisWeek() {
          // Week of Mon 2025-09-01 .. Sun 2025-09-07.
          let today = isoUTC("2025-09-03")  // Wednesday
          let entries = [
              WFHCalc.Entry(logDate: "2025-09-01", minutes: 360, claimCents: 420),  // Mon -> idx 0
              WFHCalc.Entry(logDate: "2025-09-03", minutes: 480, claimCents: 560),  // Wed -> idx 2
              WFHCalc.Entry(logDate: "2025-09-07", minutes: 120, claimCents: 140),  // Sun -> idx 6
              WFHCalc.Entry(logDate: "2025-08-31", minutes: 999, claimCents: 0),    // prev week -> excluded
          ]
          let week = WFHCalc.thisWeekMinutes(entries: entries, today: today)
          #expect(week == [360, 0, 480, 0, 0, 0, 120])
      }

      /// UTC date helper for the test.
      private func isoUTC(_ s: String) -> Date {
          let f = DateFormatter()
          f.locale = Locale(identifier: "en_US_POSIX")
          f.timeZone = TimeZone(identifier: "UTC")
          f.dateFormat = "yyyy-MM-dd"
          return f.date(from: s)!
      }
  }
  ```

- [ ] **Step 2: Run — expect FAIL (`cannot find 'WFHCalc' in scope`).**
  ```
  xcodegen generate   # picks up the new SnapceiptTests/WFHCalcTests.swift
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/WFHCalcTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```

- [ ] **Step 3: Implement.** Create `Snapceipt/Features/Logbooks/WFHCalc.swift`:
  ```swift
  import Foundation

  /// Pure WFH (fixed-rate method) claim math. No SwiftData — callers pass plain
  /// `Entry` snapshots so this stays unit-testable. (§5.2)
  enum WFHCalc {
      /// A minimal WFH log snapshot for aggregation.
      struct Entry: Equatable {
          let logDate: String   // "yyyy-MM-dd"
          let minutes: Int
          let claimCents: Int
      }

      /// FY hero stats.
      struct Hero: Equatable {
          let totalMinutes: Int
          let claimCents: Int
          let daysLogged: Int
          let avgHoursPerDay: Double
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
          c.firstWeekday = 2   // Monday
          return c
      }

      /// Per-entry claim = round(minutes/60 * rate). Snapshotted at create/edit.
      static func claimCents(minutes: Int, rateCentsPerHour: Int) -> Int {
          Int((Double(minutes) / 60.0 * Double(rateCentsPerHour)).rounded())
      }

      /// FY aggregation over the entries in FY `fyStartYear`.
      static func hero(entries: [Entry], fyStartYear: Int, startMonth: Int) -> Hero {
          let inFY = entries.filter {
              FinancialYear.isIn($0.logDate, fyStartYear: fyStartYear, startMonth: startMonth)
          }
          let totalMinutes = inFY.reduce(0) { $0 + $1.minutes }
          let claim = inFY.reduce(0) { $0 + $1.claimCents }
          let days = inFY.count
          let avg = days == 0 ? 0 : (Double(totalMinutes) / 60.0) / Double(days)
          return Hero(totalMinutes: totalMinutes, claimCents: claim, daysLogged: days, avgHoursPerDay: avg)
      }

      /// Minutes per weekday (index 0 = Monday … 6 = Sunday) for the Mon–Sun week
      /// containing `today`.
      static func thisWeekMinutes(entries: [Entry], today: Date) -> [Int] {
          let cal = utcCalendar
          let interval = cal.dateInterval(of: .weekOfYear, for: today)!
          let monday = interval.start
          let nextMonday = interval.end
          var buckets = [Int](repeating: 0, count: 7)
          for e in entries {
              guard let date = isoParser.date(from: e.logDate),
                    date >= monday, date < nextMonday else { continue }
              let days = cal.dateComponents([.day], from: monday, to: date).day ?? 0
              if days >= 0 && days < 7 { buckets[days] += e.minutes }
          }
          return buckets
      }
  }
  ```

- [ ] **Step 4: Run — expect PASS.**
  ```
  xcodegen generate   # picks up the new Snapceipt/Features/Logbooks/WFHCalc.swift
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/WFHCalcTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `Test Suite 'WFHCalcTests' passed` (4 tests).

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Features/Logbooks/WFHCalc.swift SnapceiptTests/WFHCalcTests.swift
  git commit -m "Add pure WFHCalc (entry claim, FY hero, this-week buckets)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 6: `MileageCalc` (pure business-use-% + vehicle-year claim + odometer→km, §5.3)

Pure functions: odometer→metres distance, business-use % from in-window trips, vehicle-year claim = pct% × sum(costs), and the FY km/trips hero.

**Files:**
- Create: `Snapceipt/Features/Logbooks/MileageCalc.swift`
- Test: `SnapceiptTests/MileageCalcTests.swift`

- [ ] **Step 1: Write the FAILING test.**
  Create `SnapceiptTests/MileageCalcTests.swift`:
  ```swift
  import Testing
  import Foundation
  @testable import Snapceipt

  @Suite("MileageCalc")
  struct MileageCalcTests {

      @Test("distance is end - start metres; nil/invalid -> nil")
      func odometerDistance() {
          #expect(MileageCalc.distanceM(startM: 10_000_000, endM: 10_012_400) == 12_400)
          #expect(MileageCalc.distanceM(startM: nil, endM: 10_012_400) == nil)
          #expect(MileageCalc.distanceM(startM: 10_012_400, endM: 10_000_000) == nil)  // end <= start
      }

      @Test("end-greater-than-start validation")
      func endGreaterThanStart() {
          #expect(MileageCalc.isValidOdometer(startM: 1000, endM: 2000) == true)
          #expect(MileageCalc.isValidOdometer(startM: 2000, endM: 2000) == false)
          #expect(MileageCalc.isValidOdometer(startM: 2000, endM: 1000) == false)
      }

      @Test("business-use % = round(business km / total km * 100) over in-window trips")
      func businessUsePct() {
          // window 2025-08-12 .. 2025-11-04
          let trips = [
              MileageCalc.Trip(tripDate: "2025-08-20", distanceM: 30_000, isBusiness: true),   // in
              MileageCalc.Trip(tripDate: "2025-09-01", distanceM: 10_000, isBusiness: false),  // in
              MileageCalc.Trip(tripDate: "2025-12-01", distanceM: 99_000, isBusiness: true),   // OUT of window
          ]
          // business 30km / total 40km = 75%
          let pct = MileageCalc.businessUsePct(trips: trips, start: "2025-08-12", end: "2025-11-04")
          #expect(pct == 75)
      }

      @Test("business-use % is nil with no in-window trips")
      func businessUsePctNilWhenNoTrips() {
          let pct = MileageCalc.businessUsePct(trips: [], start: "2025-08-12", end: "2025-11-04")
          #expect(pct == nil)
      }

      @Test("vehicle-year claim = round(pct/100 * sum(costs))")
      func vehicleYearClaim() {
          let costs = MileageCalc.Costs(fuelCents: 200_000, regoCents: 80_000, insuranceCents: 90_000,
                                        servicingCents: 40_000, otherCents: 2_000, depreciationCents: 0)
          #expect(costs.totalCents == 412_000)
          #expect(MileageCalc.claimCents(businessUsePct: 78, costs: costs) == 321_360) // 0.78 * 412000
          #expect(MileageCalc.claimCents(businessUsePct: 0, costs: costs) == 0)
      }

      @Test("FY hero sums business-trip km + counts trips in the FY")
      func fyHero() {
          let trips = [
              MileageCalc.Trip(tripDate: "2025-07-10", distanceM: 12_400, isBusiness: true),  // in FY, biz
              MileageCalc.Trip(tripDate: "2025-09-01", distanceM: 8_000, isBusiness: false),  // in FY, personal
              MileageCalc.Trip(tripDate: "2025-06-30", distanceM: 50_000, isBusiness: true),  // prev FY
          ]
          let hero = MileageCalc.hero(trips: trips, fyStartYear: 2025, startMonth: 7)
          #expect(hero.businessKm == 12.4)
          #expect(hero.tripCount == 2)   // both FY25-26 trips counted
      }
  }
  ```

- [ ] **Step 2: Run — expect FAIL (`cannot find 'MileageCalc' in scope`).**
  ```
  xcodegen generate   # picks up the new SnapceiptTests/MileageCalcTests.swift
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/MileageCalcTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```

- [ ] **Step 3: Implement.** Create `Snapceipt/Features/Logbooks/MileageCalc.swift`:
  ```swift
  import Foundation

  /// Pure ATO logbook-method mileage math. No SwiftData — callers pass `Trip`/`Costs`
  /// snapshots so this stays unit-testable. (§5.3)
  enum MileageCalc {
      /// A minimal trip snapshot for aggregation.
      struct Trip: Equatable {
          let tripDate: String   // "yyyy-MM-dd"
          let distanceM: Int
          let isBusiness: Bool
      }

      /// Annual running costs.
      struct Costs: Equatable {
          let fuelCents: Int
          let regoCents: Int
          let insuranceCents: Int
          let servicingCents: Int
          let otherCents: Int
          let depreciationCents: Int
          var totalCents: Int {
              fuelCents + regoCents + insuranceCents + servicingCents + otherCents + depreciationCents
          }
      }

      /// FY mileage hero stats.
      struct Hero: Equatable {
          let businessKm: Double
          let tripCount: Int
      }

      /// Derived distance = end - start metres, or nil when missing/non-increasing.
      static func distanceM(startM: Int?, endM: Int?) -> Int? {
          guard let s = startM, let e = endM, e > s else { return nil }
          return e - s
      }

      /// True when both odometers are present and end > start.
      static func isValidOdometer(startM: Int?, endM: Int?) -> Bool {
          guard let s = startM, let e = endM else { return false }
          return e > s
      }

      /// Business-use % over trips inside [start, end] (inclusive). Nil when no
      /// in-window km. `start`/`end` are "yyyy-MM-dd".
      static func businessUsePct(trips: [Trip], start: String, end: String) -> Int? {
          let inWindow = trips.filter { $0.tripDate >= start && $0.tripDate <= end }
          let totalM = inWindow.reduce(0) { $0 + $1.distanceM }
          guard totalM > 0 else { return nil }
          let businessM = inWindow.filter { $0.isBusiness }.reduce(0) { $0 + $1.distanceM }
          return Int((Double(businessM) / Double(totalM) * 100).rounded())
      }

      /// vehicle_year claim = round(pct/100 * sum(costs)).
      static func claimCents(businessUsePct: Int, costs: Costs) -> Int {
          Int((Double(businessUsePct) / 100.0 * Double(costs.totalCents)).rounded())
      }

      /// FY hero: business-trip km + count of trips in FY `fyStartYear`.
      static func hero(trips: [Trip], fyStartYear: Int, startMonth: Int) -> Hero {
          let inFY = trips.filter {
              FinancialYear.isIn($0.tripDate, fyStartYear: fyStartYear, startMonth: startMonth)
          }
          let businessM = inFY.filter { $0.isBusiness }.reduce(0) { $0 + $1.distanceM }
          return Hero(businessKm: Double(businessM) / 1000.0, tripCount: inFY.count)
      }
  }
  ```
  (Note: the `start`/`end` string comparison is valid for `"yyyy-MM-dd"` because ISO dates sort lexicographically.)

- [ ] **Step 4: Run — expect PASS.**
  ```
  xcodegen generate   # picks up the new Snapceipt/Features/Logbooks/MileageCalc.swift
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/MileageCalcTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `Test Suite 'MileageCalcTests' passed` (6 tests).

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Features/Logbooks/MileageCalc.swift SnapceiptTests/MileageCalcTests.swift
  git commit -m "Add pure MileageCalc (business-use %, vehicle-year claim, FY hero)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 7: `Depreciation` helper (pure, §5.4)

Diminishing-value + prime-cost first-year depreciation with the $69,674 car-cost-limit cap and day-based part-year proration.

**Files:**
- Create: `Snapceipt/Features/Logbooks/Depreciation.swift`
- Test: `SnapceiptTests/DepreciationTests.swift`

- [ ] **Step 1: Write the FAILING test.**
  Create `SnapceiptTests/DepreciationTests.swift`:
  ```swift
  import Testing
  import Foundation
  @testable import Snapceipt

  @Suite("Depreciation")
  struct DepreciationTests {

      @Test("car cost limit caps the base value at $69,674")
      func costLimit() {
          #expect(Depreciation.cappedCostCents(80_000_00) == 69_674_00)
          #expect(Depreciation.cappedCostCents(40_000_00) == 40_000_00)
      }

      @Test("full-year diminishing value = cost * 25% (8yr life)")
      func dvFullYear() {
          // 40,000 * 2/8 = 10,000 over a full year (365 days held)
          let cents = Depreciation.declineCents(
              costCents: 40_000_00, method: .diminishingValue, effectiveLifeYears: 8, daysHeld: 365)
          #expect(cents == 10_000_00)
      }

      @Test("full-year prime cost = cost * 12.5% (8yr life)")
      func pcFullYear() {
          let cents = Depreciation.declineCents(
              costCents: 40_000_00, method: .primeCost, effectiveLifeYears: 8, daysHeld: 365)
          #expect(cents == 5_000_00)
      }

      @Test("part-year prorates by daysHeld/365")
      func partYear() {
          // half a year held (182 days) on DV: 10,000 * 182/365 = 4,986.30 -> 498630 cents
          let cents = Depreciation.declineCents(
              costCents: 40_000_00, method: .diminishingValue, effectiveLifeYears: 8, daysHeld: 182)
          #expect(cents == 498_630)
      }

      @Test("cost above the limit depreciates off the capped base")
      func cappedDV() {
          // capped 69,674 * 25% full year = 17,418.50 -> 1741850 cents
          let cents = Depreciation.declineCents(
              costCents: 100_000_00, method: .diminishingValue, effectiveLifeYears: 8, daysHeld: 365)
          #expect(cents == 1_741_850)
      }
  }
  ```

- [ ] **Step 2: Run — expect FAIL (`cannot find 'Depreciation' in scope`).**
  ```
  xcodegen generate   # picks up the new SnapceiptTests/DepreciationTests.swift
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/DepreciationTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```

- [ ] **Step 3: Implement.** Create `Snapceipt/Features/Logbooks/Depreciation.swift`:
  ```swift
  import Foundation

  /// Pure, simplified first-year car depreciation helper (labelled "simplified
  /// estimate — not tax advice" in the UI). Caps the depreciable base at the FY2025-26
  /// car cost limit and prorates the first year by days held. (§5.4)
  enum Depreciation {
      enum Method: String, CaseIterable, Identifiable {
          case diminishingValue
          case primeCost
          var id: String { rawValue }
          var label: String { self == .diminishingValue ? "Diminishing value" : "Prime cost" }
      }

      /// ATO car cost limit for FY2025-26, in cents ($69,674).
      static let carCostLimitCents = 69_674_00

      /// Cost capped at the car cost limit.
      static func cappedCostCents(_ costCents: Int) -> Int {
          min(costCents, carCostLimitCents)
      }

      /// First-year decline in value, in cents.
      /// - DV: base * (2 / life) * daysHeld/365
      /// - PC: base * (1 / life) * daysHeld/365
      static func declineCents(costCents: Int, method: Method, effectiveLifeYears: Int, daysHeld: Int) -> Int {
          guard effectiveLifeYears > 0 else { return 0 }
          let base = Double(cappedCostCents(costCents))
          let rate = (method == .diminishingValue ? 2.0 : 1.0) / Double(effectiveLifeYears)
          let proration = Double(daysHeld) / 365.0
          return Int((base * rate * proration).rounded())
      }
  }
  ```

- [ ] **Step 4: Run — expect PASS.**
  ```
  xcodegen generate   # picks up the new Snapceipt/Features/Logbooks/Depreciation.swift
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/DepreciationTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `Test Suite 'DepreciationTests' passed` (5 tests).

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Features/Logbooks/Depreciation.swift SnapceiptTests/DepreciationTests.swift
  git commit -m "Add pure Depreciation helper (DV/PC, car-limit cap, part-year)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 8: `TaxSettingsSeeder` + seeding hooks (§7)

A helper that ensures exactly one live `TaxSettings` per profile with ATO defaults, enqueues the upsert through the `SyncEnqueuing` seam, and is idempotent. Hooked into both profile-creation paths (`ProfilesStore.add` and onboarding `FirstProfileForm.create`) and used as a lazy-ensure on logbook-screen load (Task 11). (Verified: `ProfilesStore.add` at lines 180-186 uses `sync.enqueue`; `SyncEnqueuing` seam exists; `TaxSettings(profileId:)` init applies ATO defaults incl. WFH 70 after Task 2.)

**Files:**
- Create: `Snapceipt/Features/Logbooks/TaxSettingsSeeder.swift`
- Modify: `Snapceipt/Features/Profiles/ProfilesStore.swift` (lines 180-186)
- Modify: `Snapceipt/Features/Onboarding/OnboardingView.swift` (lines 173-194)
- Test: `SnapceiptTests/TaxSettingsSeederTests.swift`
- Modify: `SnapceiptTests/AddProfileViewModelTests.swift` (fixture container schema line 23; assertion line 77)
- Modify: `SnapceiptTests/ProfilesStoreTests.swift` (fixture container schemas lines 14 + 66; assertion line 61)

> **LANDMINE (verified):** `ProfilesStore.add(_:)` calls `try? context.save()` and the seeder calls `context.insert(TaxSettings(...))`. The existing fixtures in `AddProfileViewModelTests` (line 23) and `ProfilesStoreTests` (lines 14, 66) build their `ModelContainer` with **`Profile.self` ONLY**. Inserting a `TaxSettings` into a container whose schema lacks it **traps at runtime** (SwiftData fatalError, not a silent `try?` no-op). Both fixtures MUST be widened to include `TaxSettings.self` (Step 4 below). Also `ProfilesStoreTests.firstIsDefaultActive` (line 61) asserts `sync.calls.count == 1` per `add`; the seeder makes it 2.

- [ ] **Step 1: Write the FAILING test.**
  Create `SnapceiptTests/TaxSettingsSeederTests.swift`:
  ```swift
  import Testing
  import Foundation
  import SwiftData
  @testable import Snapceipt

  @MainActor
  @Suite("TaxSettingsSeeder")
  struct TaxSettingsSeederTests {

      private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
          let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
          let context = ModelContext(container)
          return (context, MockSyncEngine())
      }

      @Test("ensure() creates one TaxSettings with ATO defaults + enqueues an upsert")
      func ensureCreates() throws {
          let (ctx, sync) = try makeFixture()
          TaxSettingsSeeder.ensure(profileId: "p1", userId: "u1", context: ctx, sync: sync)

          let rows = try ctx.fetch(FetchDescriptor<TaxSettings>())
          #expect(rows.count == 1)
          let s = rows[0]
          #expect(s.profileId == "p1")
          #expect(s.userId == "u1")
          #expect(s.wfhRateCentsPerHour == 70)
          #expect(s.mileageRateCentsPerKm == 88)
          #expect(s.financialYearStartMonth == 7)
          #expect(s.gstRateBps == 1000)
          #expect(s.mealsDeductiblePct == 50)
          #expect(sync.calls.count == 1)
          #expect(sync.calls.first?.op == "upsert")
          #expect(sync.calls.first?.entityType == .taxSettings)
      }

      @Test("ensure() is idempotent for the same profile (legacy already-seeded)")
      func ensureIdempotent() throws {
          let (ctx, sync) = try makeFixture()
          TaxSettingsSeeder.ensure(profileId: "p1", userId: "u1", context: ctx, sync: sync)
          TaxSettingsSeeder.ensure(profileId: "p1", userId: "u1", context: ctx, sync: sync)

          let rows = try ctx.fetch(FetchDescriptor<TaxSettings>())
          #expect(rows.count == 1)            // not duplicated
          #expect(sync.calls.count == 1)      // second call enqueues nothing
      }

      @Test("ensure() ignores a soft-deleted row and re-seeds")
      func ensureSkipsDeleted() throws {
          let (ctx, sync) = try makeFixture()
          let dead = TaxSettings(userId: "u1", profileId: "p1", deletedAt: 123)
          ctx.insert(dead)
          try ctx.save()

          TaxSettingsSeeder.ensure(profileId: "p1", userId: "u1", context: ctx, sync: sync)
          let live = try ctx.fetch(FetchDescriptor<TaxSettings>(
              predicate: #Predicate { $0.profileId == "p1" && $0.deletedAt == nil }))
          #expect(live.count == 1)
          #expect(sync.calls.count == 1)
      }
  }
  ```

- [ ] **Step 2: Run — expect FAIL (`cannot find 'TaxSettingsSeeder' in scope`).**
  ```
  xcodegen generate   # picks up the new SnapceiptTests/TaxSettingsSeederTests.swift
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/TaxSettingsSeederTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```

- [ ] **Step 3a: Implement the seeder.** Create `Snapceipt/Features/Logbooks/TaxSettingsSeeder.swift`:
  ```swift
  import Foundation
  import SwiftData

  /// Ensures every profile has exactly one live `TaxSettings` row with ATO defaults.
  /// Hooked on profile creation and lazily on logbook-screen load (legacy profiles). (§7)
  @MainActor
  enum TaxSettingsSeeder {
      /// Insert a defaulted `TaxSettings` for `profileId` if none exists (live).
      /// Idempotent; enqueues an upsert only when it inserts.
      static func ensure(profileId: String, userId: String,
                         context: ModelContext, sync: any SyncEnqueuing) {
          var d = FetchDescriptor<TaxSettings>(
              predicate: #Predicate { $0.profileId == profileId && $0.deletedAt == nil })
          d.fetchLimit = 1
          if let existing = try? context.fetch(d), existing.isEmpty == false { return }

          let settings = TaxSettings(userId: userId, profileId: profileId)  // ATO defaults
          context.insert(settings)
          try? context.save()
          sync.enqueue(op: "upsert", entityType: .taxSettings, entity: settings)
      }
  }
  ```

- [ ] **Step 3b: Hook into `ProfilesStore.add`.** In `Snapceipt/Features/Profiles/ProfilesStore.swift`, replace the body of `add(_:)` (lines 180-186) with:
  ```swift
      func add(_ p: Profile) {
          context.insert(p)
          try? context.save()
          reload()
          sync.enqueue(op: "upsert", entityType: .profile, entity: p)
          TaxSettingsSeeder.ensure(profileId: p.id, userId: userId, context: context, sync: sync)
          setActive(p.id)
      }
  ```

- [ ] **Step 3c: Hook into onboarding.** In `Snapceipt/Features/Onboarding/OnboardingView.swift`, in `FirstProfileForm.create()` after `sync?.enqueue(op: "upsert", entityType: .profile, entity: profile)` (line 192) add:
  ```swift
          if let sync {
              TaxSettingsSeeder.ensure(profileId: profile.id, userId: userId, context: context, sync: sync)
          }
  ```

- [ ] **Step 4a: Run the seeder test — expect PASS.**
  ```
  xcodegen generate   # picks up the new Snapceipt/Features/Logbooks/TaxSettingsSeeder.swift
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/TaxSettingsSeederTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `Test Suite 'TaxSettingsSeederTests' passed` (3 tests). (The seeder test's fixture uses `ModelContainer.makeSnapceiptContainer(inMemory: true)` — the full schema — so it already includes `TaxSettings.self`.)

- [ ] **Step 4b: Fix the two profile fixtures so the seeder's `TaxSettings` insert is in-schema.**
  In `SnapceiptTests/AddProfileViewModelTests.swift` (line 23) replace:
  ```swift
          let container = try ModelContainer(for: Profile.self, configurations: config)
  ```
  with:
  ```swift
          let container = try ModelContainer(for: Profile.self, TaxSettings.self, configurations: config)
  ```
  In `SnapceiptTests/ProfilesStoreTests.swift` apply the SAME change in BOTH `makeStore()` (line 14) and `rescopeToNewUserLoadsThatUsersProfilesAndPicksDefault()` (line 66):
  ```swift
          let container = try ModelContainer(for: Profile.self, TaxSettings.self, configurations: config)
  ```
  (The `rescope` test does not call `add`, but widening its schema keeps the fixtures consistent and harmless.)

- [ ] **Step 4c: Update the two enqueue-count assertions the seeder changes.**
  In `SnapceiptTests/AddProfileViewModelTests.swift` `createActivatesAndSyncs` (line 77) replace:
  ```swift
          #expect(sync.calls.count == 1)
          #expect(sync.calls.first?.op == "upsert")
          #expect(sync.calls.first?.entityType == .profile)
          #expect(sync.calls.first?.entityId == created.id)
  ```
  with:
  ```swift
          #expect(sync.calls.count == 2)  // profile upsert + taxSettings seed
          #expect(sync.calls[0].op == "upsert")
          #expect(sync.calls[0].entityType == .profile)
          #expect(sync.calls[0].entityId == created.id)
          #expect(sync.calls[1].entityType == .taxSettings)
  ```
  In `SnapceiptTests/ProfilesStoreTests.swift` `firstIsDefaultActive` (line 61) replace:
  ```swift
          #expect(sync.calls.count == 1)        // exactly one upsert per add
  ```
  with:
  ```swift
          #expect(sync.calls.count == 2)        // profile upsert + taxSettings seed
          #expect(sync.calls[0].entityType == .profile)
          #expect(sync.calls[1].entityType == .taxSettings)
  ```

- [ ] **Step 4d: Re-run both profile suites — expect PASS.**
  ```
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/AddProfileViewModelTests -only-testing:SnapceiptTests/ProfilesStoreTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: both suites pass (the seeder now runs against an in-schema `TaxSettings` and the counts expect 2).

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Features/Logbooks/TaxSettingsSeeder.swift Snapceipt/Features/Profiles/ProfilesStore.swift Snapceipt/Features/Onboarding/OnboardingView.swift SnapceiptTests/TaxSettingsSeederTests.swift SnapceiptTests/AddProfileViewModelTests.swift SnapceiptTests/ProfilesStoreTests.swift
  git commit -m "Seed TaxSettings on profile creation (+ idempotent ensure helper)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 9: `WFHViewModel` (hero stats + this-week chart + one-per-day upsert)

The WFH screen's view-model. Loads logs for the active profile, computes the FY hero (via `WFHCalc.hero`) and this-week chart (via `WFHCalc.thisWeekMinutes`), and upserts a log for a date — one-per-day, so an existing date is edited in place (mirrors D1 `ux_wfh_profile_date`). Injects `SyncEnqueuing` for testability (verified pattern: `CaptureViewModel`, `AddProfileViewModel`).

**Files:**
- Create: `Snapceipt/Features/Logbooks/WFHViewModel.swift`
- Test: `SnapceiptTests/WFHViewModelTests.swift`

- [ ] **Step 1: Write the FAILING test.**
  Create `SnapceiptTests/WFHViewModelTests.swift`:
  ```swift
  import Testing
  import Foundation
  import SwiftData
  @testable import Snapceipt

  @MainActor
  @Suite("WFHViewModel")
  struct WFHViewModelTests {

      private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
          let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
          return (ModelContext(container), MockSyncEngine())
      }

      @Test("logHours inserts a new log with snapshotted rate + claim and enqueues it")
      func logHoursInsert() throws {
          let (ctx, sync) = try makeFixture()
          let vm = WFHViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1",
                                rateCentsPerHour: 70, startMonth: 7)
          vm.logHours(date: "2025-09-03", minutes: 90, note: "Invoices")

          let rows = try ctx.fetch(FetchDescriptor<WFHLog>())
          #expect(rows.count == 1)
          let log = rows[0]
          #expect(log.logDate == "2025-09-03")
          #expect(log.minutes == 90)
          #expect(log.note == "Invoices")
          #expect(log.rateCentsPerHour == 70)
          #expect(log.claimCents == 105)        // 1.5h * 70
          #expect(log.profileId == "p1")
          #expect(sync.calls.count == 1)
          #expect(sync.calls[0].entityType == .wfhLog)
          #expect(sync.calls[0].op == "upsert")
      }

      @Test("logHours on an existing date edits in place (one-per-day)")
      func logHoursEditsInPlace() throws {
          let (ctx, sync) = try makeFixture()
          let vm = WFHViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1",
                                rateCentsPerHour: 70, startMonth: 7)
          vm.logHours(date: "2025-09-03", minutes: 90, note: "First")
          vm.logHours(date: "2025-09-03", minutes: 120, note: "Updated")

          let rows = try ctx.fetch(FetchDescriptor<WFHLog>(
              predicate: #Predicate { $0.deletedAt == nil }))
          #expect(rows.count == 1)              // not duplicated
          #expect(rows[0].minutes == 120)
          #expect(rows[0].note == "Updated")
          #expect(rows[0].claimCents == 140)    // 2h * 70
      }

      @Test("hero aggregates FY logs for the active profile only")
      func heroScoped() throws {
          let (ctx, sync) = try makeFixture()
          // other profile log -> must be excluded
          let other = WFHLog(userId: "u1", profileId: "p2", logDate: "2025-08-01",
                             minutes: 480, rateCentsPerHour: 70, claimCents: 560)
          ctx.insert(other)
          let vm = WFHViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1",
                                rateCentsPerHour: 70, startMonth: 7)
          vm.logHours(date: "2025-08-10", minutes: 300, note: nil)   // claim 350

          let hero = vm.hero(fyStartYear: 2025)
          #expect(hero.daysLogged == 1)
          #expect(hero.totalMinutes == 300)
          #expect(hero.claimCents == 350)
      }

      @Test("existingLog(for:) returns a row to pre-fill the sheet")
      func existingLog() throws {
          let (ctx, sync) = try makeFixture()
          let vm = WFHViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1",
                                rateCentsPerHour: 70, startMonth: 7)
          vm.logHours(date: "2025-09-03", minutes: 90, note: "Note")
          let found = vm.existingLog(for: "2025-09-03")
          #expect(found?.minutes == 90)
          #expect(vm.existingLog(for: "2025-01-01") == nil)
      }
  }
  ```

- [ ] **Step 2: Run — expect FAIL (`cannot find 'WFHViewModel' in scope`).**
  ```
  xcodegen generate   # picks up the new SnapceiptTests/WFHViewModelTests.swift
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/WFHViewModelTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```

- [ ] **Step 3: Implement.** Create `Snapceipt/Features/Logbooks/WFHViewModel.swift`:
  ```swift
  import Foundation
  import SwiftData
  import Observation

  /// Drives the WFH screen: loads the active profile's logs, computes FY hero + the
  /// this-week chart, and upserts one log per day. `@MainActor`; deps injected for tests.
  @Observable
  @MainActor
  final class WFHViewModel {
      @ObservationIgnored private let context: ModelContext
      @ObservationIgnored private let sync: any SyncEnqueuing
      @ObservationIgnored private let userId: String
      @ObservationIgnored let profileId: String
      @ObservationIgnored let rateCentsPerHour: Int
      @ObservationIgnored private let startMonth: Int

      /// Active profile's live logs, newest-first.
      private(set) var logs: [WFHLog] = []

      init(context: ModelContext, sync: any SyncEnqueuing, userId: String,
           profileId: String, rateCentsPerHour: Int, startMonth: Int) {
          self.context = context
          self.sync = sync
          self.userId = userId
          self.profileId = profileId
          self.rateCentsPerHour = rateCentsPerHour
          self.startMonth = startMonth
          reload()
      }

      func reload() {
          let pid = profileId
          let d = FetchDescriptor<WFHLog>(
              predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
              sortBy: [SortDescriptor(\.logDate, order: .reverse)])
          logs = (try? context.fetch(d)) ?? []
      }

      /// The live log for a date, or nil. Drives the sheet's pre-fill/edit.
      func existingLog(for date: String) -> WFHLog? {
          logs.first(where: { $0.logDate == date })
      }

      private func entries() -> [WFHCalc.Entry] {
          logs.map { WFHCalc.Entry(logDate: $0.logDate, minutes: $0.minutes, claimCents: $0.claimCents ?? 0) }
      }

      func hero(fyStartYear: Int) -> WFHCalc.Hero {
          WFHCalc.hero(entries: entries(), fyStartYear: fyStartYear, startMonth: startMonth)
      }

      func thisWeekMinutes(today: Date = Date()) -> [Int] {
          WFHCalc.thisWeekMinutes(entries: entries(), today: today)
      }

      /// Upsert a WFH log for `date` (one-per-day). Snapshots the rate + claim.
      func logHours(date: String, minutes: Int, note: String?) {
          let claim = WFHCalc.claimCents(minutes: minutes, rateCentsPerHour: rateCentsPerHour)
          if let existing = existingLog(for: date) {
              existing.minutes = minutes
              existing.note = note
              existing.rateCentsPerHour = rateCentsPerHour
              existing.claimCents = claim
              existing.updatedAt = Epoch.nowMs()
              try? context.save()
              reload()
              sync.enqueue(op: "upsert", entityType: .wfhLog, entity: existing)
          } else {
              let log = WFHLog(userId: userId, profileId: profileId, logDate: date,
                               minutes: minutes, note: note,
                               rateCentsPerHour: rateCentsPerHour, claimCents: claim)
              context.insert(log)
              try? context.save()
              reload()
              sync.enqueue(op: "upsert", entityType: .wfhLog, entity: log)
          }
      }
  }
  ```

- [ ] **Step 4: Run — expect PASS.**
  ```
  xcodegen generate   # picks up the new Snapceipt/Features/Logbooks/WFHViewModel.swift
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/WFHViewModelTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `Test Suite 'WFHViewModelTests' passed` (4 tests).

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Features/Logbooks/WFHViewModel.swift SnapceiptTests/WFHViewModelTests.swift
  git commit -m "Add WFHViewModel (FY hero, this-week chart, one-per-day upsert)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 10: `MileageViewModel` (hero stats + vehicle/logbook/trip/costs drivers)

The Mileage screen's view-model. Owns the active profile's `Vehicle`, its trips, and the current-FY `VehicleYear`. Computes the FY hero (via `MileageCalc.hero`), recomputes + caches `vehicle.businessUsePct` whenever trips/window change, and writes vehicle/trip/costs with claim recompute. Saves a trip with derived `distanceM` (odometer end − start). All writes enqueue through `SyncEnqueuing`.

**Files:**
- Create: `Snapceipt/Features/Logbooks/MileageViewModel.swift`
- Test: `SnapceiptTests/MileageViewModelTests.swift`

- [ ] **Step 1: Write the FAILING test.**
  Create `SnapceiptTests/MileageViewModelTests.swift`:
  ```swift
  import Testing
  import Foundation
  import SwiftData
  @testable import Snapceipt

  @MainActor
  @Suite("MileageViewModel")
  struct MileageViewModelTests {

      private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
          let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
          return (ModelContext(container), MockSyncEngine())
      }

      private func makeVM(_ ctx: ModelContext, _ sync: MockSyncEngine) -> MileageViewModel {
          MileageViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1", startMonth: 7)
      }

      @Test("saveVehicle inserts a Vehicle + enqueues it")
      func saveVehicle() throws {
          let (ctx, sync) = try makeFixture()
          let vm = makeVM(ctx, sync)
          vm.saveVehicle(make: "Toyota", model: "HiLux", engineCc: 2800, registration: "ABC123")

          let rows = try ctx.fetch(FetchDescriptor<Vehicle>())
          #expect(rows.count == 1)
          #expect(rows[0].make == "Toyota")
          #expect(vm.vehicle?.id == rows[0].id)
          #expect(sync.calls.contains { $0.entityType == .vehicle && $0.op == "upsert" })
      }

      @Test("addTrip derives distance from odometer + recomputes business-use %")
      func addTripRecomputesPct() throws {
          let (ctx, sync) = try makeFixture()
          let vm = makeVM(ctx, sync)
          vm.saveVehicle(make: "Toyota", model: "HiLux", engineCc: nil, registration: nil)
          vm.startLogbook(startDate: "2025-08-12")  // 12-week end auto-derived

          // 30km business + 10km personal, both inside the window -> 75%
          vm.addTrip(date: "2025-08-20", odometerStartM: 0, odometerEndM: 30_000,
                     isBusiness: true, purpose: "Client", fromLabel: nil, toLabel: nil)
          vm.addTrip(date: "2025-09-01", odometerStartM: 30_000, odometerEndM: 40_000,
                     isBusiness: false, purpose: "Personal", fromLabel: nil, toLabel: nil)

          #expect(vm.vehicle?.businessUsePct == 75)
          let trips = try ctx.fetch(FetchDescriptor<MileageTrip>())
          #expect(trips.count == 2)
          #expect(trips.contains { $0.distanceM == 30_000 })
          #expect(sync.calls.contains { $0.entityType == .mileageTrip })
          // recompute persists the vehicle again:
          #expect(sync.calls.filter { $0.entityType == .vehicle }.count >= 2)
      }

      @Test("saveCosts recomputes the current-FY VehicleYear claim from the cached %")
      func saveCostsComputesClaim() throws {
          let (ctx, sync) = try makeFixture()
          let vm = makeVM(ctx, sync)
          vm.saveVehicle(make: "Toyota", model: "HiLux", engineCc: nil, registration: nil)
          vm.startLogbook(startDate: "2025-08-12")
          vm.addTrip(date: "2025-08-20", odometerStartM: 0, odometerEndM: 78_000,
                     isBusiness: true, purpose: "Client", fromLabel: nil, toLabel: nil)
          vm.addTrip(date: "2025-08-21", odometerStartM: 78_000, odometerEndM: 100_000,
                     isBusiness: false, purpose: "Personal", fromLabel: nil, toLabel: nil)
          #expect(vm.vehicle?.businessUsePct == 78)  // 78000/100000

          vm.saveCosts(fyStartYear: 2025, fuelCents: 200_000, regoCents: 80_000,
                       insuranceCents: 90_000, servicingCents: 40_000, otherCents: 2_000,
                       depreciationCents: 0)

          let years = try ctx.fetch(FetchDescriptor<VehicleYear>())
          #expect(years.count == 1)
          #expect(years[0].businessUsePct == 78)
          #expect(years[0].claimCents == 321_360)   // 0.78 * 412000
          #expect(sync.calls.contains { $0.entityType == .vehicleYear })
      }

      @Test("hero is empty + claim nil with no vehicle/trips")
      func emptyHero() throws {
          let (ctx, sync) = try makeFixture()
          let vm = makeVM(ctx, sync)
          let hero = vm.hero(fyStartYear: 2025)
          #expect(hero.businessKm == 0)
          #expect(hero.tripCount == 0)
          #expect(vm.vehicle == nil)
          #expect(vm.currentClaimCents(fyStartYear: 2025) == nil)
      }
  }
  ```

- [ ] **Step 2: Run — expect FAIL (`cannot find 'MileageViewModel' in scope`).**
  ```
  xcodegen generate   # picks up the new SnapceiptTests/MileageViewModelTests.swift
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/MileageViewModelTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```

- [ ] **Step 3: Implement.** Create `Snapceipt/Features/Logbooks/MileageViewModel.swift`:
  ```swift
  import Foundation
  import SwiftData
  import Observation

  /// Drives the Mileage screen: owns the active profile's single Vehicle, its trips,
  /// and the current-FY VehicleYear. Recomputes + caches `vehicle.businessUsePct` and
  /// the VehicleYear claim. `@MainActor`; deps injected for tests. (v1 = one vehicle.)
  @Observable
  @MainActor
  final class MileageViewModel {
      @ObservationIgnored private let context: ModelContext
      @ObservationIgnored private let sync: any SyncEnqueuing
      @ObservationIgnored private let userId: String
      @ObservationIgnored let profileId: String
      @ObservationIgnored private let startMonth: Int

      private(set) var vehicle: Vehicle?
      private(set) var trips: [MileageTrip] = []

      /// ~12 weeks = 84 days.
      private static let logbookDays = 84

      init(context: ModelContext, sync: any SyncEnqueuing, userId: String,
           profileId: String, startMonth: Int) {
          self.context = context
          self.sync = sync
          self.userId = userId
          self.profileId = profileId
          self.startMonth = startMonth
          reload()
      }

      func reload() {
          let pid = profileId
          var vd = FetchDescriptor<Vehicle>(
              predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
              sortBy: [SortDescriptor(\.createdAt)])
          vd.fetchLimit = 1
          vehicle = (try? context.fetch(vd))?.first

          let td = FetchDescriptor<MileageTrip>(
              predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
              sortBy: [SortDescriptor(\.tripDate, order: .reverse)])
          trips = (try? context.fetch(td)) ?? []
      }

      // MARK: hero

      private func calcTrips() -> [MileageCalc.Trip] {
          trips.map { MileageCalc.Trip(tripDate: $0.tripDate, distanceM: $0.distanceM, isBusiness: $0.isBusiness) }
      }

      func hero(fyStartYear: Int) -> MileageCalc.Hero {
          MileageCalc.hero(trips: calcTrips(), fyStartYear: fyStartYear, startMonth: startMonth)
      }

      /// Cached current-FY claim, or nil when no vehicle / no business-use %.
      func currentClaimCents(fyStartYear: Int) -> Int? {
          guard vehicle?.businessUsePct != nil else { return nil }
          return vehicleYear(fyStartYear: fyStartYear)?.claimCents
      }

      // MARK: vehicle

      func saveVehicle(make: String?, model: String?, engineCc: Int?, registration: String?) {
          let v: Vehicle
          if let existing = vehicle {
              v = existing
              v.make = make; v.model = model; v.engineCc = engineCc; v.registration = registration
              v.updatedAt = Epoch.nowMs()
          } else {
              v = Vehicle(userId: userId, profileId: profileId, make: make, model: model,
                          engineCc: engineCc, registration: registration)
              context.insert(v)
          }
          try? context.save()
          vehicle = v
          sync.enqueue(op: "upsert", entityType: .vehicle, entity: v)
      }

      /// Start (or move) the 12-week logbook window; end auto-derived, editable.
      func startLogbook(startDate: String, endDate: String? = nil) {
          guard let v = vehicle else { return }
          v.logbookStartDate = startDate
          v.logbookEndDate = endDate ?? Self.autoEnd(from: startDate)
          v.updatedAt = Epoch.nowMs()
          try? context.save()
          recomputeBusinessUsePct()
      }

      /// start + 84 days as "yyyy-MM-dd" (UTC), or the input unchanged if unparsable.
      static func autoEnd(from startDate: String) -> String {
          let f = DateFormatter()
          f.locale = Locale(identifier: "en_US_POSIX")
          f.timeZone = TimeZone(identifier: "UTC")
          f.dateFormat = "yyyy-MM-dd"
          guard let start = f.date(from: startDate) else { return startDate }
          let end = start.addingTimeInterval(Double(logbookDays) * 86_400)
          return f.string(from: end)
      }

      // MARK: trips

      func addTrip(date: String, odometerStartM: Int?, odometerEndM: Int?,
                   isBusiness: Bool, purpose: String?, fromLabel: String?, toLabel: String?) {
          let distance = MileageCalc.distanceM(startM: odometerStartM, endM: odometerEndM) ?? 0
          let t = MileageTrip(userId: userId, profileId: profileId, tripDate: date,
                              fromLabel: fromLabel, toLabel: toLabel, purpose: purpose,
                              distanceM: distance, isBusiness: isBusiness,
                              vehicleId: vehicle?.id, odometerStartM: odometerStartM,
                              odometerEndM: odometerEndM)
          context.insert(t)
          try? context.save()
          reload()
          sync.enqueue(op: "upsert", entityType: .mileageTrip, entity: t)
          recomputeBusinessUsePct()
      }

      /// Recompute + cache `vehicle.businessUsePct` from in-window trips, persist + enqueue.
      private func recomputeBusinessUsePct() {
          guard let v = vehicle, let start = v.logbookStartDate, let end = v.logbookEndDate else { return }
          let pct = MileageCalc.businessUsePct(trips: calcTrips(), start: start, end: end)
          v.businessUsePct = pct
          v.updatedAt = Epoch.nowMs()
          try? context.save()
          sync.enqueue(op: "upsert", entityType: .vehicle, entity: v)
      }

      // MARK: costs / vehicle_year

      func vehicleYear(fyStartYear: Int) -> VehicleYear? {
          guard let vid = vehicle?.id else { return nil }
          let pid = profileId
          var d = FetchDescriptor<VehicleYear>(
              predicate: #Predicate {
                  $0.profileId == pid && $0.vehicleId == vid
                      && $0.fyStartYear == fyStartYear && $0.deletedAt == nil
              })
          d.fetchLimit = 1
          return (try? context.fetch(d))?.first
      }

      func saveCosts(fyStartYear: Int, fuelCents: Int, regoCents: Int, insuranceCents: Int,
                     servicingCents: Int, otherCents: Int, depreciationCents: Int) {
          guard let v = vehicle else { return }
          let costs = MileageCalc.Costs(fuelCents: fuelCents, regoCents: regoCents,
                                        insuranceCents: insuranceCents, servicingCents: servicingCents,
                                        otherCents: otherCents, depreciationCents: depreciationCents)
          let pct = v.businessUsePct
          let claim = pct.map { MileageCalc.claimCents(businessUsePct: $0, costs: costs) }

          let vy: VehicleYear
          if let existing = vehicleYear(fyStartYear: fyStartYear) {
              vy = existing
          } else {
              vy = VehicleYear(userId: userId, profileId: profileId, vehicleId: v.id, fyStartYear: fyStartYear)
              context.insert(vy)
          }
          vy.fuelCents = fuelCents; vy.regoCents = regoCents; vy.insuranceCents = insuranceCents
          vy.servicingCents = servicingCents; vy.otherCents = otherCents; vy.depreciationCents = depreciationCents
          vy.businessUsePct = pct
          vy.claimCents = claim
          vy.updatedAt = Epoch.nowMs()
          try? context.save()
          sync.enqueue(op: "upsert", entityType: .vehicleYear, entity: vy)
      }
  }
  ```

- [ ] **Step 4: Run — expect PASS.**
  ```
  xcodegen generate   # picks up the new Snapceipt/Features/Logbooks/MileageViewModel.swift
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests/MileageViewModelTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `Test Suite 'MileageViewModelTests' passed` (4 tests).

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Features/Logbooks/MileageViewModel.swift SnapceiptTests/MileageViewModelTests.swift
  git commit -m "Add MileageViewModel (vehicle/logbook/trip/costs + cached % & claim)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 11: Icons, a11y identifiers, Router overlays, navigation wiring + lazy-ensure

Add the glyph paths the screens need, the a11y identifiers, the two new `Overlay` cases, the Home QuickActions entry points, the overlay rendering, and the lazy `TaxSettings` ensure on screen open. (Verified: `Icons.paths` dict; `AccessibilityID` (ends line 35) is shared into the UITest target via `project.yml`; the top-level `Overlay` enum in `Router.swift` lines 11-17 — it is `enum Overlay`, NOT nested `Router.Overlay`; `RootView`/`ShellView` overlay rendering pattern at lines 126-264; `homeStub` at lines 171-201; `ShellView` holds `@Bindable var router/profiles/sync` and `profiles.context`/`profiles.userId`/`profiles.activeProfileId` are all accessible. `SyncEngine` conforms to `SyncEnqueuing` so passing `sync` where `any SyncEnqueuing` is expected compiles.)

This task wires placeholders — the actual screen views are built in Tasks 12-13 but referenced here so navigation compiles. Build the two screen stubs first so this task compiles, then flesh them out.

**Files:**
- Modify: `Snapceipt/DesignSystem/Icons.swift` (paths dict, before line 26 closing comment)
- Modify: `Snapceipt/Shared/AccessibilityID.swift` (before closing brace line 35)
- Modify: `Snapceipt/App/Router.swift` (Overlay enum lines 11-17)
- Modify: `Snapceipt/App/RootView.swift` (homeStub lines 171-201; overlay rendering lines 132-135)

- [ ] **Step 1: Add icon paths (verbatim 24-grid `d` strings copied EXACTLY from `design-ref/snapceipt/project/app/theme.jsx` lines 32, 36, 37, 66, 67, 71 — verified character-for-character).** In `Snapceipt/DesignSystem/Icons.swift`, inside the `paths` dictionary before the closing `]` (line 25), add:
  ```swift
        "car": "M5 16.5h14M5.5 16.5v2M18.5 16.5v2M4.5 16.5l1.2-5a2 2 0 0 1 1.9-1.4h8.8a2 2 0 0 1 1.9 1.4l1.2 5M4.5 16.5h15M7.5 13.5h2M14.5 13.5h2",
        "wfh": "M3 11 12 4.5 21 11M5 9.7V19a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V9.7M9.5 20v-4.2a2.5 2.5 0 0 1 5 0V20",
        "pin": "M12 21s7-5.5 7-11a7 7 0 1 0-14 0c0 5.5 7 11 7 11ZM12 12.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5Z",
        "clock": "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18ZM12 7.5V12l3 2",
        "info": "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18ZM12 11v5M12 7.6h.01",
        "arrowRight": "M5 12h14M13 6l6 6-6 6",
  ```
  (These are the verbatim `theme.jsx` ICONS entries; `clock` and `arrowRight` already matched, the other four are now exact. This also removes the pending names from the `// ADD THE REMAINING…` TODO comment list — leave the comment as-is; it harmlessly over-lists.)

- [ ] **Step 2: Add a11y identifiers.** In `Snapceipt/Shared/AccessibilityID.swift`, before the closing `}` (line 35), add:
  ```swift

    // Home quick actions
    static let homeQuickMileage = "home.quick.mileage"
    static let homeQuickWFH = "home.quick.wfh"

    // Logbooks — shared
    static let logbookClose = "logbook.close"
    static let logbookAdd = "logbook.add"

    // Mileage
    static let mileageScreen = "mileage.screen"
    static let mileageAddVehicle = "mileage.addVehicle"
    static let mileageStartLogbook = "mileage.startLogbook"
    static let mileageEditCosts = "mileage.editCosts"
    static let mileageAddTrip = "mileage.addTrip"
    static let mileageClaim = "mileage.claim"
    static let vehicleSheetMake = "vehicle.sheet.make"
    static let vehicleSheetModel = "vehicle.sheet.model"
    static let vehicleSheetSave = "vehicle.sheet.save"
    static let logbookSheetStart = "logbook.sheet.start"
    static let logbookSheetSave = "logbook.sheet.save"
    static let tripSheetOdoStart = "trip.sheet.odoStart"
    static let tripSheetOdoEnd = "trip.sheet.odoEnd"
    static let tripSheetBusiness = "trip.sheet.business"
    static let tripSheetSave = "trip.sheet.save"
    static let costsSheetFuel = "costs.sheet.fuel"
    static let costsSheetSave = "costs.sheet.save"

    // WFH
    static let wfhScreen = "wfh.screen"
    static let wfhLogHours = "wfh.logHours"
    static let wfhClaim = "wfh.claim"
    static let wfhSheetHours = "wfh.sheet.hours"
    static let wfhSheetSave = "wfh.sheet.save"
  ```

- [ ] **Step 3: Add the Router overlay cases.** In `Snapceipt/App/Router.swift`, in the `Overlay` enum (lines 11-17) after `case capture` add:
  ```swift
      case mileage
      case wfh
  ```

- [ ] **Step 4: Add Home QuickActions + overlay rendering + lazy-ensure.**
  In `Snapceipt/App/RootView.swift`, in `homeStub` (lines 171-201), insert a QuickActions row after the `ProfileSwitcherHeader` block (after line 178's `.padding(.top, 12)`):
  ```swift

            HStack(spacing: 12) {
                quickAction(title: "Mileage", icon: "car", id: AccessibilityID.homeQuickMileage,
                            accent: accent) { router.present(.mileage) }
                quickAction(title: "WFH log", icon: "wfh", id: AccessibilityID.homeQuickWFH,
                            accent: accent) { router.present(.wfh) }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
  ```
  Add the `quickAction` builder as a method on `ShellView` (after `homeStub`, before `// MARK: - Overlays` on line 203):
  ```swift
      /// One Home quick-action tile -> opens a logbook overlay.
      @ViewBuilder
      private func quickAction(title: String, icon: String, id: String,
                               accent: AccentPalette, action: @escaping () -> Void) -> some View {
          Button(action: action) {
              HStack(spacing: 10) {
                  IconCircle(name: icon, tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
                  Text(title).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                  Spacer(minLength: 0)
              }
              .padding(12)
              .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
              .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                  .strokeBorder(Palette.line2, lineWidth: 1))
              .cardShadow()
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier(id)
      }
  ```
  Replace the capture-only overlay block (lines 132-135) with all three full-screen overlays:
  ```swift
          // --- Full-screen overlays ---
          .overlay {
              if router.overlay == .capture { captureCover(accent: accent) }
          }
          .overlay {
              if router.overlay == .mileage {
                  MileageScreen(context: profiles.context, sync: sync,
                                userId: profiles.userId,
                                profileId: profiles.activeProfileId,
                                startMonth: 7,
                                onClose: { router.dismissOverlay() })
                      .environment(\.accent, accent)
                      .transition(.opacity)
              }
          }
          .overlay {
              if router.overlay == .wfh {
                  WFHScreen(context: profiles.context, sync: sync,
                            userId: profiles.userId,
                            profileId: profiles.activeProfileId,
                            startMonth: 7,
                            onClose: { router.dismissOverlay() })
                      .environment(\.accent, accent)
                      .transition(.opacity)
              }
          }
  ```
  In `sheetBinding` (lines 208-220) the `get` excludes `.capture`; extend it so the new full-screen overlays also do not route to `.sheet(item:)`. Replace the `get` closure with:
  ```swift
              get: {
                  switch router.overlay {
                  case .capture, .mileage, .wfh: return nil
                  default: return router.overlay
                  }
              },
  ```
  And in the `set` closure replace the guard `router.overlay != .capture` so it does not stomp the new overlays:
  ```swift
              set: { newValue in
                  let fullScreen: Set<Overlay> = [.capture, .mileage, .wfh]
                  if newValue == nil, let cur = router.overlay, !fullScreen.contains(cur) {
                      router.dismissOverlay()
                  } else if let newValue {
                      router.overlay = newValue
                  }
              }
  ```
  In `sheetContent(for:)` (lines 222-237) add the two new cases so the switch stays exhaustive:
  ```swift
          case .mileage, .wfh:
              EmptyView()  // handled by the full-screen overlays
  ```

- [ ] **Step 5: Build (screens not yet implemented — this step depends on Task 12/13).**
  Build will fail until `MileageScreen`/`WFHScreen` exist. To keep Task 11 self-contained, FIRST create minimal compiling stubs and replace them in Tasks 12-13. Create `Snapceipt/Features/Logbooks/MileageScreen.swift` and `WFHScreen.swift` as stubs:
  ```swift
  // MileageScreen.swift
  import SwiftUI
  import SwiftData

  struct MileageScreen: View {
      let context: ModelContext
      let sync: any SyncEnqueuing
      let userId: String
      let profileId: String
      let startMonth: Int
      let onClose: () -> Void
      var body: some View {
          Color.clear.accessibilityIdentifier(AccessibilityID.mileageScreen)
      }
  }
  ```
  ```swift
  // WFHScreen.swift
  import SwiftUI
  import SwiftData

  struct WFHScreen: View {
      let context: ModelContext
      let sync: any SyncEnqueuing
      let userId: String
      let profileId: String
      let startMonth: Int
      let onClose: () -> Void
      var body: some View {
          Color.clear.accessibilityIdentifier(AccessibilityID.wfhScreen)
      }
  }
  ```
  Then build:
  ```
  xcodegen generate   # picks up MileageScreen.swift + WFHScreen.swift stubs
  xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
  ```
  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit.**
  ```
  git add Snapceipt/DesignSystem/Icons.swift Snapceipt/Shared/AccessibilityID.swift Snapceipt/App/Router.swift Snapceipt/App/RootView.swift Snapceipt/Features/Logbooks/MileageScreen.swift Snapceipt/Features/Logbooks/WFHScreen.swift
  git commit -m "Wire logbook navigation: icons, a11y ids, overlays, Home quick actions

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 12: `MileageScreen` + shared chrome + its sheets (§6.1)

Build the real Mileage overlay: shared `LbHeader`/`LbLabel`/`LbHero` chrome, vehicle/logbook/GPS-placeholder/costs cards, the recent-trips list, the Add-a-trip CTA, and four sheets. The Running-costs sheet wires the optional `Depreciation` helper (§5.4) so the DV/PC util built in Task 7 is actually reachable from the UI (the user can still type a figure directly). Lazy-ensures `TaxSettings` on appear. Views are covered by the hermetic UI test (Task 14); no pure unit tests here (math is already tested in Tasks 6-7-10). Tokens copied verbatim from `screens.md` MILEAGE section. (Verified primitives: `Card(padding:content:)`, `IconCircle(name:tint:soft:size:iconSize:)`, `Icon(name:size:color:lineWidth:)` — note `Icon` has NO `tint`/`soft` params, `Palette` (`.cream/.paper/.paper2/.ink/.ink2/.ink3/.line/.line2/.alert`), `Radius` (`.card/.inner/.chip`), `.cardShadow()`, `.display`/`.ui` fonts, `\.accent` (with `.base/.soft/.deep`), `fmt(_:Int)`/`fmtDate(_:style:)` with `DateStyle.short/.long`, `EmptyArt(size:)`. Note: the input sheets use SwiftUI `Form`/`NavigationStack` `.sheet`, NOT the app's `BottomSheet` primitive — deliberate, for input ergonomics + reliable a11y-id targeting; flag for design review if pixel-fidelity on the sheets is required.)

**Files:**
- Create: `Snapceipt/Features/Logbooks/LogbookChrome.swift`
- Modify: `Snapceipt/Features/Logbooks/MileageScreen.swift` (replace the stub)

- [ ] **Step 1: Create `LogbookChrome.swift`.**
  ```swift
  import SwiftUI

  /// Shared logbook header: back button + centered title + accent plus button.
  struct LbHeader: View {
      let title: String
      let onClose: () -> Void
      let onAdd: () -> Void
      @Environment(\.accent) private var accent

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

              Button(action: onAdd) {
                  Icon(name: "plus", size: 20, color: .white, lineWidth: 2.3)
                      .frame(width: 40, height: 40)
                      .background(accent.base, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                      .shadow(color: accent.base.opacity(0.4), radius: 7, x: 0, y: 6)
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier(AccessibilityID.logbookAdd)
          }
          .padding(.top, 54).padding(.horizontal, 18).padding(.bottom, 12)
      }
  }

  /// Uppercase section label.
  struct LbLabel: View {
      let text: String
      var body: some View {
          Text(text.uppercased())
              .font(.ui(12.5, .bold)).foregroundStyle(Palette.ink3)
              .kerning(0.3)
              .padding(.top, 20).padding(.horizontal, 2).padding(.bottom, 10)
              .frame(maxWidth: .infinity, alignment: .leading)
      }
  }

  /// One hero stat group (label + value).
  struct LbStat: View {
      let label: String
      let value: String
      var body: some View {
          VStack(alignment: .leading, spacing: 1) {
              Text(label).font(.ui(12, .semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
              Text(value).font(.display(18, .bold)).foregroundStyle(.white)
          }
      }
  }

  /// Gradient logbook hero: icon + label + method pill, big number + unit, 3 stats.
  struct LbHero: View {
      let icon: String
      let label: String
      let pill: String
      let bigNumber: String
      let unit: String
      let stats: [(String, String)]
      @Environment(\.accent) private var accent

      var body: some View {
          ZStack(alignment: .topTrailing) {
              VStack(alignment: .leading, spacing: 0) {
                  HStack(spacing: 8) {
                      Icon(name: icon, size: 20, color: .white)
                      Text(label).font(.ui(13, .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                      Spacer()
                      Text(pill).font(.ui(11.5, .bold)).foregroundStyle(.white)
                          .padding(.vertical, 4).padding(.horizontal, 10)
                          .background(Color.white.opacity(0.2), in: Capsule())
                  }
                  HStack(alignment: .firstTextBaseline, spacing: 4) {
                      Text(bigNumber).font(.display(38, .bold)).foregroundStyle(.white)
                      Text(unit).font(.display(20, .semibold)).foregroundStyle(.white.opacity(0.85))
                  }
                  .padding(.top, 6)
                  HStack(spacing: 18) {
                      ForEach(Array(stats.enumerated()), id: \.offset) { idx, s in
                          if idx > 0 { Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 34) }
                          LbStat(label: s.0, value: s.1)
                      }
                  }
                  .padding(.top, 14)
              }
              .padding(18)
          }
          .background(
              LinearGradient(colors: [accent.base, accent.deep],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
          )
          .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
          .shadow(color: accent.base.opacity(0.5), radius: 15, x: 0, y: 14)
      }
  }

  /// The cream fade scrim + a full-width accent CTA pinned to the bottom of a logbook.
  struct LbFloatingCTA: View {
      let title: String
      let a11yId: String
      let action: () -> Void
      @Environment(\.accent) private var accent

      var body: some View {
          Button(action: action) {
              HStack(spacing: 8) {
                  Icon(name: "plus", size: 20, color: .white, lineWidth: 2.3)
                  Text(title).font(.ui(16, .semibold)).foregroundStyle(.white)
              }
              .frame(maxWidth: .infinity, minHeight: 54)
              .background(accent.base, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
              .shadow(color: accent.base.opacity(0.5), radius: 12, x: 0, y: 12)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier(a11yId)
          .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 34)
          .background(
              LinearGradient(colors: [Palette.cream.opacity(0), Palette.cream],
                             startPoint: .top, endPoint: .bottom)
          )
      }
  }
  ```

- [ ] **Step 2: Implement `MileageScreen.swift` (replace the stub).**
  ```swift
  import SwiftUI
  import SwiftData

  /// Full-screen vehicle-logbook overlay (ATO logbook method). (§6.1)
  struct MileageScreen: View {
      let context: ModelContext
      let sync: any SyncEnqueuing
      let userId: String
      let profileId: String
      let startMonth: Int
      let onClose: () -> Void

      @Environment(\.accent) private var accent
      @State private var vm: MileageViewModel?
      @State private var sheet: MileageSheet?

      private enum MileageSheet: Identifiable {
          case vehicle, logbook, trip, costs
          var id: Int { hashValue }
      }

      private var fyStartYear: Int { FinancialYear.of(Date(), startMonth: startMonth).startYear }

      var body: some View {
          ZStack(alignment: .bottom) {
              Palette.cream.ignoresSafeArea()
              if let vm {
                  VStack(spacing: 0) {
                      LbHeader(title: "Vehicle logbook", onClose: onClose, onAdd: { sheet = .trip })
                      ScrollView {
                          VStack(spacing: 0) {
                              hero(vm)
                              vehicleCard(vm).padding(.top, 14)
                              logbookCard(vm).padding(.top, 14)
                              gpsCard.padding(.top, 14)
                              costsCard(vm).padding(.top, 14)
                              LbLabel(text: "Recent trips")
                              tripsList(vm)
                          }
                          .padding(.horizontal, 18).padding(.bottom, 110)
                      }
                  }
                  LbFloatingCTA(title: "Add a trip", a11yId: AccessibilityID.mileageAddTrip) { sheet = .trip }
              } else {
                  Color.clear
              }
          }
          .accessibilityIdentifier(AccessibilityID.mileageScreen)
          .transition(.opacity)
          .task {
              TaxSettingsSeeder.ensure(profileId: profileId, userId: userId, context: context, sync: sync)
              if vm == nil {
                  vm = MileageViewModel(context: context, sync: sync, userId: userId,
                                        profileId: profileId, startMonth: startMonth)
              }
          }
          .sheet(item: $sheet) { which in sheetView(which) }
      }

      // MARK: cards

      @ViewBuilder private func hero(_ vm: MileageViewModel) -> some View {
          let h = vm.hero(fyStartYear: fyStartYear)
          let claim = vm.currentClaimCents(fyStartYear: fyStartYear)
          LbHero(icon: "car", label: "This financial year", pill: "Logbook method",
                 bigNumber: String(format: "%.1f", h.businessKm), unit: "km",
                 stats: [
                      ("Claimable", claim.map { fmt($0) } ?? "—"),
                      ("Business use", vm.vehicle?.businessUsePct.map { "\($0)%" } ?? "—"),
                      ("Trips", "\(h.tripCount)"),
                 ])
      }

      @ViewBuilder private func vehicleCard(_ vm: MileageViewModel) -> some View {
          Button { sheet = .vehicle } label: {
              Card(padding: 14) {
                  HStack(spacing: 12) {
                      IconCircle(name: "car", tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
                      VStack(alignment: .leading, spacing: 1) {
                          if let v = vm.vehicle, (v.make != nil || v.model != nil) {
                              Text([v.make, v.model].compactMap { $0 }.joined(separator: " "))
                                  .font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                              Text(v.registration ?? "Tap to edit")
                                  .font(.ui(12.5)).foregroundStyle(Palette.ink3)
                          } else {
                              Text("Add your vehicle").font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                              Text("Make, model & rego").font(.ui(12.5)).foregroundStyle(Palette.ink3)
                          }
                      }
                      Spacer(minLength: 0)
                      Icon(name: "chevR", size: 18, color: Palette.ink3)
                  }
              }
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier(AccessibilityID.mileageAddVehicle)
      }

      @ViewBuilder private func logbookCard(_ vm: MileageViewModel) -> some View {
          Button { sheet = .logbook } label: {
              Card(padding: 14) {
                  HStack(spacing: 12) {
                      IconCircle(name: "clock", tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
                      VStack(alignment: .leading, spacing: 1) {
                          if let s = vm.vehicle?.logbookStartDate, let e = vm.vehicle?.logbookEndDate {
                              Text("\(fmtDate(s)) – \(fmtDate(e))").font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                              Text(vm.vehicle?.businessUsePct.map { "\($0)% business use" } ?? "Add trips to compute %")
                                  .font(.ui(12.5)).foregroundStyle(Palette.ink3)
                          } else {
                              Text("Start your 12-week logbook").font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                              Text("Builds your business-use %").font(.ui(12.5)).foregroundStyle(Palette.ink3)
                          }
                      }
                      Spacer(minLength: 0)
                      Icon(name: "chevR", size: 18, color: Palette.ink3)
                  }
              }
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier(AccessibilityID.mileageStartLogbook)
      }

      /// GPS auto-track — non-functional placeholder (no location, no network).
      @ViewBuilder private var gpsCard: some View {
          Card(padding: 14) {
              HStack(spacing: 12) {
                  IconCircle(name: "pin", tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
                  VStack(alignment: .leading, spacing: 1) {
                      Text("Auto-track with GPS").font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                      Text("Coming soon").font(.ui(12.5)).foregroundStyle(Palette.ink3)
                  }
                  Spacer(minLength: 0)
                  Capsule().fill(Palette.line).frame(width: 46, height: 28)
                      .overlay(Circle().fill(Palette.paper).frame(width: 22).padding(3), alignment: .leading)
              }
          }
          .opacity(0.7)
      }

      @ViewBuilder private func costsCard(_ vm: MileageViewModel) -> some View {
          let vy = vm.vehicleYear(fyStartYear: fyStartYear)
          let total = vy.map { $0.fuelCents + $0.regoCents + $0.insuranceCents + $0.servicingCents + $0.otherCents + $0.depreciationCents } ?? 0
          let claim = vm.currentClaimCents(fyStartYear: fyStartYear)
          Button { sheet = .costs } label: {
              Card(padding: 14) {
                  HStack(spacing: 12) {
                      IconCircle(name: "wallet", tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
                      VStack(alignment: .leading, spacing: 1) {
                          Text("Running costs \(FinancialYear.label(startYear: fyStartYear))")
                              .font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                          if let claim {
                              Text("\(fmt(total)) → claim \(fmt(claim))")
                                  .font(.ui(12.5)).foregroundStyle(Palette.ink3)
                                  .accessibilityIdentifier(AccessibilityID.mileageClaim)
                          } else {
                              Text("\(fmt(total)) · start your logbook for a claim")
                                  .font(.ui(12.5)).foregroundStyle(Palette.ink3)
                          }
                      }
                      Spacer(minLength: 0)
                      Icon(name: "chevR", size: 18, color: Palette.ink3)
                  }
              }
          }
          .buttonStyle(.plain)
          .disabled(vm.vehicle == nil)
          .opacity(vm.vehicle == nil ? 0.5 : 1)
          .accessibilityIdentifier(AccessibilityID.mileageEditCosts)
      }

      @ViewBuilder private func tripsList(_ vm: MileageViewModel) -> some View {
          if vm.trips.isEmpty {
              VStack(spacing: 12) {
                  EmptyArt(size: 110)
                  Text("No trips yet").font(.ui(14, .semibold)).foregroundStyle(Palette.ink2)
              }
              .frame(maxWidth: .infinity).padding(.vertical, 24)
          } else {
              Card(padding: 0) {
                  VStack(spacing: 0) {
                      ForEach(Array(vm.trips.enumerated()), id: \.element.id) { idx, t in
                          HStack(spacing: 12) {
                              IconCircle(name: "car",
                                         tint: t.isBusiness ? accent.base : Palette.ink3,
                                         soft: t.isBusiness ? accent.soft : Palette.paper2,
                                         size: 40, iconSize: 20)
                              VStack(alignment: .leading, spacing: 1) {
                                  Text(tripTitle(t)).font(.ui(14, .bold)).foregroundStyle(Palette.ink).lineLimit(1)
                                  Text("\(fmtDate(t.tripDate)) · \(t.purpose ?? "")")
                                      .font(.ui(12.5)).foregroundStyle(Palette.ink3).lineLimit(1)
                              }
                              Spacer(minLength: 0)
                              VStack(alignment: .trailing, spacing: 1) {
                                  Text(String(format: "%.1f km", Double(t.distanceM) / 1000))
                                      .font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                                  Text(t.isBusiness ? "Business" : "Personal")
                                      .font(.ui(11, .bold))
                                      .foregroundStyle(t.isBusiness ? accent.base : Palette.ink3)
                              }
                          }
                          .padding(.vertical, 13).padding(.horizontal, 14)
                          if idx < vm.trips.count - 1 { Rectangle().fill(Palette.line2).frame(height: 1) }
                      }
                  }
              }
          }
      }

      private func tripTitle(_ t: MileageTrip) -> String {
          if let f = t.fromLabel, let to = t.toLabel { return "\(f) → \(to)" }
          return t.purpose ?? "Trip"
      }

      // MARK: sheets

      @ViewBuilder private func sheetView(_ which: MileageSheet) -> some View {
          if let vm {
              switch which {
              case .vehicle: VehicleSheet(vm: vm) { sheet = nil }
              case .logbook: LogbookPeriodSheet(vm: vm) { sheet = nil }
              case .trip: AddTripSheet(vm: vm) { sheet = nil }
              case .costs: RunningCostsSheet(vm: vm, fyStartYear: fyStartYear) { sheet = nil }
              }
          }
      }
  }
  ```

- [ ] **Step 3: Append the four sheets to `MileageScreen.swift`.**
  ```swift

  // MARK: - Vehicle sheet

  private struct VehicleSheet: View {
      @Bindable var vm: MileageViewModel
      let onDone: () -> Void
      @State private var make = ""
      @State private var model = ""
      @State private var engineCc = ""
      @State private var registration = ""

      var body: some View {
          NavigationStack {
              Form {
                  TextField("Make", text: $make).accessibilityIdentifier(AccessibilityID.vehicleSheetMake)
                  TextField("Model", text: $model).accessibilityIdentifier(AccessibilityID.vehicleSheetModel)
                  TextField("Engine (cc, optional)", text: $engineCc).keyboardType(.numberPad)
                  TextField("Registration", text: $registration)
              }
              .navigationTitle("Vehicle")
              .toolbar {
                  ToolbarItem(placement: .confirmationAction) {
                      Button("Save") {
                          vm.saveVehicle(make: make.nilIfBlank, model: model.nilIfBlank,
                                         engineCc: Int(engineCc), registration: registration.nilIfBlank)
                          onDone()
                      }
                      .accessibilityIdentifier(AccessibilityID.vehicleSheetSave)
                  }
              }
          }
          .onAppear {
              make = vm.vehicle?.make ?? ""
              model = vm.vehicle?.model ?? ""
              engineCc = vm.vehicle?.engineCc.map(String.init) ?? ""
              registration = vm.vehicle?.registration ?? ""
          }
      }
  }

  // MARK: - Logbook period sheet

  private struct LogbookPeriodSheet: View {
      @Bindable var vm: MileageViewModel
      let onDone: () -> Void
      @State private var start = Date()

      var body: some View {
          NavigationStack {
              Form {
                  DatePicker("Start date", selection: $start, displayedComponents: .date)
                      .accessibilityIdentifier(AccessibilityID.logbookSheetStart)
                  Text("12-week period ends \(fmtDate(MileageViewModel.autoEnd(from: ymd(start))))")
                      .font(.ui(12.5)).foregroundStyle(Palette.ink3)
                  Text("A logbook is valid for 5 years.").font(.ui(12.5)).foregroundStyle(Palette.ink3)
                  if let pct = vm.vehicle?.businessUsePct {
                      Text("Business use so far: \(pct)%").font(.ui(13, .semibold)).foregroundStyle(Palette.ink)
                  }
              }
              .navigationTitle("Logbook period")
              .toolbar {
                  ToolbarItem(placement: .confirmationAction) {
                      Button("Save") { vm.startLogbook(startDate: ymd(start)); onDone() }
                          .accessibilityIdentifier(AccessibilityID.logbookSheetSave)
                  }
              }
          }
      }
  }

  // MARK: - Add trip sheet

  private struct AddTripSheet: View {
      @Bindable var vm: MileageViewModel
      let onDone: () -> Void
      @State private var date = Date()
      @State private var odoStart = ""
      @State private var odoEnd = ""
      @State private var purpose = ""
      @State private var isBusiness = true

      private var startM: Int? { Double(odoStart).map { Int($0 * 1000) } }
      private var endM: Int? { Double(odoEnd).map { Int($0 * 1000) } }
      private var valid: Bool { MileageCalc.isValidOdometer(startM: startM, endM: endM) }
      private var km: Double { Double((endM ?? 0) - (startM ?? 0)) / 1000 }

      var body: some View {
          NavigationStack {
              Form {
                  DatePicker("Date", selection: $date, displayedComponents: .date)
                  TextField("Odometer start (km)", text: $odoStart).keyboardType(.decimalPad)
                      .accessibilityIdentifier(AccessibilityID.tripSheetOdoStart)
                  TextField("Odometer end (km)", text: $odoEnd).keyboardType(.decimalPad)
                      .accessibilityIdentifier(AccessibilityID.tripSheetOdoEnd)
                  if valid {
                      Text(String(format: "Distance: %.1f km", km)).font(.ui(13, .semibold))
                  } else if !odoStart.isEmpty || !odoEnd.isEmpty {
                      Text("End must be greater than start").font(.ui(12.5)).foregroundStyle(Palette.alert)
                  }
                  TextField("Purpose", text: $purpose)
                  Toggle("Business trip", isOn: $isBusiness)
                      .accessibilityIdentifier(AccessibilityID.tripSheetBusiness)
              }
              .navigationTitle("Add a trip")
              .toolbar {
                  ToolbarItem(placement: .confirmationAction) {
                      Button("Save") {
                          vm.addTrip(date: ymd(date), odometerStartM: startM, odometerEndM: endM,
                                     isBusiness: isBusiness, purpose: purpose.nilIfBlank,
                                     fromLabel: nil, toLabel: nil)
                          onDone()
                      }
                      .disabled(!valid)
                      .accessibilityIdentifier(AccessibilityID.tripSheetSave)
                  }
              }
          }
      }
  }

  // MARK: - Running costs sheet

  private struct RunningCostsSheet: View {
      @Bindable var vm: MileageViewModel
      let fyStartYear: Int
      let onDone: () -> Void
      @State private var fuel = ""
      @State private var rego = ""
      @State private var insurance = ""
      @State private var servicing = ""
      @State private var other = ""
      @State private var depreciation = ""

      // Optional simplified depreciation helper (§5.4). Off by default — the user
      // can type a figure directly; toggling the helper computes it from the pure
      // `Depreciation` util and writes the result into `depreciation`.
      @State private var useHelper = false
      @State private var purchasePrice = ""
      @State private var purchaseDate = Date()
      @State private var method: Depreciation.Method = .diminishingValue

      private func cents(_ s: String) -> Int { Double(s).map { Int($0 * 100) } ?? 0 }

      /// Days from purchase to the end of the chosen FY (capped to a 365-day year),
      /// used for first-year part-year proration.
      private var daysHeld: Int {
          let fyEnd = FinancialYear.of(purchaseDate, startMonth: 7).end  // exclusive 1 Jul next year
          let secs = fyEnd.timeIntervalSince(purchaseDate)
          let days = Int(secs / 86_400)
          return Swift.max(0, Swift.min(days, 365))
      }

      /// Recompute the depreciation figure from the helper inputs (8-yr car life).
      private func applyHelper() {
          let computed = Depreciation.declineCents(
              costCents: cents(purchasePrice), method: method,
              effectiveLifeYears: 8, daysHeld: daysHeld)
          depreciation = computed == 0 ? "" : String(format: "%.2f", Double(computed) / 100)
      }

      var body: some View {
          NavigationStack {
              Form {
                  Section("Annual running costs (\(FinancialYear.label(startYear: fyStartYear)))") {
                      TextField("Fuel", text: $fuel).keyboardType(.decimalPad)
                          .accessibilityIdentifier(AccessibilityID.costsSheetFuel)
                      TextField("Registration", text: $rego).keyboardType(.decimalPad)
                      TextField("Insurance", text: $insurance).keyboardType(.decimalPad)
                      TextField("Servicing", text: $servicing).keyboardType(.decimalPad)
                      TextField("Other", text: $other).keyboardType(.decimalPad)
                  }
                  Section("Depreciation (simplified estimate — not tax advice)") {
                      TextField("Depreciation", text: $depreciation).keyboardType(.decimalPad)
                      Toggle("Estimate it for me", isOn: $useHelper)
                      if useHelper {
                          TextField("Purchase price", text: $purchasePrice).keyboardType(.decimalPad)
                          DatePicker("Purchase date", selection: $purchaseDate, displayedComponents: .date)
                          Picker("Method", selection: $method) {
                              ForEach(Depreciation.Method.allCases) { m in Text(m.label).tag(m) }
                          }
                          Text("Capped at the $69,674 car cost limit; first year prorated by days held.")
                              .font(.ui(12)).foregroundStyle(Palette.ink3)
                      }
                  }
                  .onChange(of: useHelper) { _, on in if on { applyHelper() } }
                  .onChange(of: purchasePrice) { _, _ in if useHelper { applyHelper() } }
                  .onChange(of: purchaseDate) { _, _ in if useHelper { applyHelper() } }
                  .onChange(of: method) { _, _ in if useHelper { applyHelper() } }
              }
              .navigationTitle("Running costs")
              .toolbar {
                  ToolbarItem(placement: .confirmationAction) {
                      Button("Save") {
                          vm.saveCosts(fyStartYear: fyStartYear, fuelCents: cents(fuel),
                                       regoCents: cents(rego), insuranceCents: cents(insurance),
                                       servicingCents: cents(servicing), otherCents: cents(other),
                                       depreciationCents: cents(depreciation))
                          onDone()
                      }
                      .accessibilityIdentifier(AccessibilityID.costsSheetSave)
                  }
              }
          }
          .onAppear {
              guard let vy = vm.vehicleYear(fyStartYear: fyStartYear) else { return }
              fuel = dollars(vy.fuelCents); rego = dollars(vy.regoCents)
              insurance = dollars(vy.insuranceCents); servicing = dollars(vy.servicingCents)
              other = dollars(vy.otherCents); depreciation = dollars(vy.depreciationCents)
          }
      }

      private func dollars(_ cents: Int) -> String { cents == 0 ? "" : String(format: "%.2f", Double(cents) / 100) }
  }

  // MARK: - Sheet helpers

  /// "yyyy-MM-dd" (UTC) for a Date — matches the app's ISO date storage.
  private func ymd(_ date: Date) -> String {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = TimeZone(identifier: "UTC")
      f.dateFormat = "yyyy-MM-dd"
      return f.string(from: date)
  }

  private extension String {
      var nilIfBlank: String? {
          let t = trimmingCharacters(in: .whitespacesAndNewlines)
          return t.isEmpty ? nil : t
      }
  }
  ```

- [ ] **Step 4: Build — expect success.**
  ```
  xcodegen generate   # picks up the new Snapceipt/Features/Logbooks/LogbookChrome.swift
  xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
  ```
  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit.**
  ```
  git add Snapceipt/Features/Logbooks/LogbookChrome.swift Snapceipt/Features/Logbooks/MileageScreen.swift
  git commit -m "Build MileageScreen + shared chrome + vehicle/logbook/trip/costs sheets

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 13: `WFHScreen` + Log-hours sheet (§6.2)

Build the real WFH overlay: hero pill "70c / hour", the this-week bar chart scaled to `max(8h, weekMax)`, the logged-days list, the updated fixed-rate explainer, the Log-hours CTA + empty state, and the one-per-day Log-hours sheet (pre-fills an existing date). Lazy-ensures `TaxSettings`. The hero rate label uses the seeded `TaxSettings.wfhRateCentsPerHour` (70). Covered by the UI test in Task 14.

**Files:**
- Modify: `Snapceipt/Features/Logbooks/WFHScreen.swift` (replace the stub)

- [ ] **Step 1: Implement `WFHScreen.swift` (replace the stub).**
  ```swift
  import SwiftUI
  import SwiftData

  /// Full-screen work-from-home overlay (ATO fixed-rate method, 70c/hr). (§6.2)
  struct WFHScreen: View {
      let context: ModelContext
      let sync: any SyncEnqueuing
      let userId: String
      let profileId: String
      let startMonth: Int
      let onClose: () -> Void

      @Environment(\.accent) private var accent
      @State private var vm: WFHViewModel?
      @State private var showSheet = false

      private static let dow = ["M", "T", "W", "T", "F", "S", "S"]
      private var fyStartYear: Int { FinancialYear.of(Date(), startMonth: startMonth).startYear }

      private func rate() -> Int {
          let pid = profileId
          var d = FetchDescriptor<TaxSettings>(
              predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
          d.fetchLimit = 1
          return (try? context.fetch(d))?.first?.wfhRateCentsPerHour ?? 70
      }

      var body: some View {
          ZStack(alignment: .bottom) {
              Palette.cream.ignoresSafeArea()
              if let vm {
                  VStack(spacing: 0) {
                      LbHeader(title: "Work from home", onClose: onClose, onAdd: { showSheet = true })
                      ScrollView {
                          VStack(spacing: 0) {
                              hero(vm)
                              weekChart(vm).padding(.top, 14)
                              LbLabel(text: "Logged days")
                              daysList(vm)
                              explainer(vm).padding(.top, 16)
                          }
                          .padding(.horizontal, 18).padding(.bottom, 110)
                      }
                  }
                  LbFloatingCTA(title: "Log hours", a11yId: AccessibilityID.wfhLogHours) { showSheet = true }
              } else {
                  Color.clear
              }
          }
          .accessibilityIdentifier(AccessibilityID.wfhScreen)
          .transition(.opacity)
          .task {
              TaxSettingsSeeder.ensure(profileId: profileId, userId: userId, context: context, sync: sync)
              if vm == nil {
                  vm = WFHViewModel(context: context, sync: sync, userId: userId,
                                    profileId: profileId, rateCentsPerHour: rate(), startMonth: startMonth)
              }
          }
          .sheet(isPresented: $showSheet) {
              if let vm { LogHoursSheet(vm: vm) { showSheet = false } }
          }
      }

      @ViewBuilder private func hero(_ vm: WFHViewModel) -> some View {
          let h = vm.hero(fyStartYear: fyStartYear)
          let hours = Double(h.totalMinutes) / 60.0
          LbHero(icon: "wfh", label: "This financial year",
                 pill: "\(vm.rateCentsPerHour)c / hour",
                 bigNumber: String(format: "%.1f", hours), unit: "hrs",
                 stats: [
                      ("Claimable", fmt(h.claimCents)),
                      ("Days logged", "\(h.daysLogged)"),
                      ("Avg / day", String(format: "%.1fh", h.avgHoursPerDay)),
                 ])
      }

      @ViewBuilder private func weekChart(_ vm: WFHViewModel) -> some View {
          let minutes = vm.thisWeekMinutes()
          let hoursPerDay = minutes.map { Double($0) / 60.0 }
          let weekMax = hoursPerDay.max() ?? 0
          let scale = Swift.max(8.0, weekMax)
          let weekTotal = hoursPerDay.reduce(0, +)
          Card(padding: 18) {
              VStack(spacing: 0) {
                  HStack {
                      Text("This week").font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                      Spacer()
                      Text(String(format: "%.1f hrs", weekTotal))
                          .font(.ui(13, .semibold)).foregroundStyle(Palette.ink3)
                  }
                  HStack(alignment: .bottom, spacing: 8) {
                      ForEach(0..<7, id: \.self) { i in
                          VStack(spacing: 6) {
                              ZStack(alignment: .bottom) {
                                  Color.clear.frame(height: 70)
                                  RoundedRectangle(cornerRadius: 7)
                                      .fill(hoursPerDay[i] > 0 ? accent.base : Palette.line)
                                      .frame(height: Swift.max(hoursPerDay[i] / scale * 70, 3))
                              }
                              .frame(maxWidth: 26)
                              Text(Self.dow[i]).font(.ui(11, .semibold)).foregroundStyle(Palette.ink3)
                          }
                          .frame(maxWidth: .infinity)
                      }
                  }
                  .frame(height: 96).padding(.top, 14)
              }
          }
      }

      @ViewBuilder private func daysList(_ vm: WFHViewModel) -> some View {
          if vm.logs.isEmpty {
              VStack(spacing: 12) {
                  EmptyArt(size: 110)
                  Text("No hours logged yet").font(.ui(14, .semibold)).foregroundStyle(Palette.ink2)
                  Text("Log hours as you work them — the ATO no longer accepts after-the-fact estimates.")
                      .font(.ui(12.5)).foregroundStyle(Palette.ink3).multilineTextAlignment(.center)
              }
              .frame(maxWidth: .infinity).padding(.vertical, 24).padding(.horizontal, 16)
          } else {
              Card(padding: 0) {
                  VStack(spacing: 0) {
                      ForEach(Array(vm.logs.enumerated()), id: \.element.id) { idx, log in
                          HStack(spacing: 12) {
                              IconCircle(name: "clock", tint: accent.base, soft: accent.soft, size: 40, iconSize: 20)
                              VStack(alignment: .leading, spacing: 1) {
                                  Text(fmtDate(log.logDate, style: .long)).font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                                  if let note = log.note, !note.isEmpty {
                                      Text(note).font(.ui(12.5)).foregroundStyle(Palette.ink3).lineLimit(1)
                                  }
                              }
                              Spacer(minLength: 0)
                              Text(String(format: "%.1f h", Double(log.minutes) / 60))
                                  .font(.ui(15, .bold)).foregroundStyle(Palette.ink)
                          }
                          .padding(.vertical, 13).padding(.horizontal, 14)
                          if idx < vm.logs.count - 1 { Rectangle().fill(Palette.line2).frame(height: 1) }
                      }
                  }
              }
          }
      }

      @ViewBuilder private func explainer(_ vm: WFHViewModel) -> some View {
          HStack(alignment: .top, spacing: 10) {
              Icon(name: "info", size: 18, color: Palette.ink3).padding(.top, 1)
              Text("The \(vm.rateCentsPerHour)c fixed rate covers electricity, gas, internet, phone & stationery. No need to keep separate bills.")
                  .font(.ui(12.5)).foregroundStyle(Palette.ink2).lineSpacing(2)
          }
          .padding(14)
          .background(Palette.paper2, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
      }
  }

  // MARK: - Log hours sheet

  private struct LogHoursSheet: View {
      @Bindable var vm: WFHViewModel
      let onDone: () -> Void
      @State private var date = Date()
      @State private var hours = ""
      @State private var note = ""

      private var minutes: Int { Int((Double(hours) ?? 0) * 60) }

      var body: some View {
          NavigationStack {
              Form {
                  DatePicker("Date", selection: $date, displayedComponents: .date)
                  TextField("Hours", text: $hours).keyboardType(.decimalPad)
                      .accessibilityIdentifier(AccessibilityID.wfhSheetHours)
                  TextField("Note (optional)", text: $note)
              }
              .navigationTitle("Log hours")
              .toolbar {
                  ToolbarItem(placement: .confirmationAction) {
                      Button("Save") {
                          vm.logHours(date: ymdWFH(date), minutes: minutes, note: note.isEmpty ? nil : note)
                          onDone()
                      }
                      .disabled(minutes <= 0)
                      .accessibilityIdentifier(AccessibilityID.wfhSheetSave)
                  }
              }
              .onChange(of: date) { _, _ in prefill() }
              .onAppear { prefill() }
          }
      }

      /// Pre-fill the form when the chosen date already has a log (one-per-day edit).
      private func prefill() {
          if let existing = vm.existingLog(for: ymdWFH(date)) {
              hours = String(format: "%.1f", Double(existing.minutes) / 60)
              note = existing.note ?? ""
          }
      }
  }

  /// "yyyy-MM-dd" (UTC) for a Date.
  private func ymdWFH(_ date: Date) -> String {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = TimeZone(identifier: "UTC")
      f.dateFormat = "yyyy-MM-dd"
      return f.string(from: date)
  }
  ```

- [ ] **Step 2: Build — expect success.**
  ```
  xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
  ```
  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full unit suite — confirm the baseline holds + new tests pass.**
  ```
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: all tests pass (baseline 160 + the new FinancialYear/WFHCalc/MileageCalc/Depreciation/VehicleModel/LogbookSync/TaxSettingsSeeder/WFHViewModel/MileageViewModel tests; the two count assertions now expect 14).

- [ ] **Step 4: Commit.**
  ```
  git add Snapceipt/Features/Logbooks/WFHScreen.swift
  git commit -m "Build WFHScreen + this-week chart + one-per-day Log-hours sheet

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 14: Hermetic UI test (`LogbookUITests`)

A camera-less XCUITest in the `CaptureUITests` style: launch the seeded shell, open Mileage from Home QuickActions, add a vehicle → start the logbook → add a trip → enter running costs → assert the claim shows; then open WFH, log hours → assert the FY claim hero updates. Uses `launchSeeded()` (signed-in, 2 profiles, StubAPIClient whose `syncPull` returns empty so no remote rows interfere). (Verified seam: `UITestCase.launchSeeded()`, `AccessibilityID` shared into the UITest target via `project.yml`.)

**Files:**
- Create: `SnapceiptUITests/LogbookUITests.swift`

- [ ] **Step 1: Write the UI test (it will fail until the build includes Tasks 11-13).**
  Create `SnapceiptUITests/LogbookUITests.swift`:
  ```swift
  import XCTest

  /// Hermetic logbook flow: seeded shell + stub API (no network).
  /// Mileage: add vehicle -> start logbook -> add trip -> enter costs -> see claim.
  /// WFH: log hours -> see the FY claim hero update.
  final class LogbookUITests: UITestCase {

      func testMileageAddVehicleLogbookTripCostsClaim() {
          launchSeeded()

          // Open Mileage from the Home quick action.
          let mileage = app.buttons[AccessibilityID.homeQuickMileage].firstMatch
          XCTAssertTrue(mileage.waitForExistence(timeout: 10), "Mileage quick action missing")
          mileage.tap()
          XCTAssertTrue(app.otherElements[AccessibilityID.mileageScreen].waitForExistence(timeout: 5)
                        || app.scrollViews.firstMatch.waitForExistence(timeout: 5),
                        "Mileage screen did not appear")

          // Add a vehicle.
          app.buttons[AccessibilityID.mileageAddVehicle].tap()
          let make = app.textFields[AccessibilityID.vehicleSheetMake]
          XCTAssertTrue(make.waitForExistence(timeout: 5), "Vehicle make field missing")
          make.tap(); make.typeText("Toyota")
          app.textFields[AccessibilityID.vehicleSheetModel].tap()
          app.textFields[AccessibilityID.vehicleSheetModel].typeText("HiLux")
          app.buttons[AccessibilityID.vehicleSheetSave].tap()

          // Start the logbook.
          app.buttons[AccessibilityID.mileageStartLogbook].tap()
          let lbSave = app.buttons[AccessibilityID.logbookSheetSave]
          XCTAssertTrue(lbSave.waitForExistence(timeout: 5), "Logbook period sheet missing")
          lbSave.tap()

          // Add a business trip (odometer in km -> distance).
          app.buttons[AccessibilityID.mileageAddTrip].firstMatch.tap()
          let odoStart = app.textFields[AccessibilityID.tripSheetOdoStart]
          XCTAssertTrue(odoStart.waitForExistence(timeout: 5), "Trip sheet missing")
          odoStart.tap(); odoStart.typeText("0")
          let odoEnd = app.textFields[AccessibilityID.tripSheetOdoEnd]
          odoEnd.tap(); odoEnd.typeText("100")
          app.buttons[AccessibilityID.tripSheetSave].tap()

          // Enter running costs.
          app.buttons[AccessibilityID.mileageEditCosts].tap()
          let fuel = app.textFields[AccessibilityID.costsSheetFuel]
          XCTAssertTrue(fuel.waitForExistence(timeout: 5), "Costs sheet missing")
          fuel.tap(); fuel.typeText("4120")
          app.buttons[AccessibilityID.costsSheetSave].tap()

          // The claim line renders (business-use % computed from the single business trip).
          XCTAssertTrue(app.staticTexts[AccessibilityID.mileageClaim].waitForExistence(timeout: 5),
                        "Claim line did not render after entering costs")
      }

      func testWFHLogHoursShowsFYClaim() {
          launchSeeded()

          let wfh = app.buttons[AccessibilityID.homeQuickWFH].firstMatch
          XCTAssertTrue(wfh.waitForExistence(timeout: 10), "WFH quick action missing")
          wfh.tap()

          let logBtn = app.buttons[AccessibilityID.wfhLogHours]
          XCTAssertTrue(logBtn.waitForExistence(timeout: 5), "Log hours CTA missing")
          logBtn.tap()

          let hours = app.textFields[AccessibilityID.wfhSheetHours]
          XCTAssertTrue(hours.waitForExistence(timeout: 5), "Hours field missing")
          hours.tap(); hours.typeText("8")
          app.buttons[AccessibilityID.wfhSheetSave].tap()

          // After logging, the logged-days list shows the entry (hero claim > $0).
          XCTAssertTrue(app.staticTexts["8.0 h"].waitForExistence(timeout: 5),
                        "Logged day did not appear after saving hours")
      }
  }
  ```

- [ ] **Step 2: Run the UI test — expect PASS.**
  ```
  xcodegen generate   # picks up the new SnapceiptUITests/LogbookUITests.swift
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptUITests/LogbookUITests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `Test Suite 'LogbookUITests' passed` (2 tests). If a sheet's text field is occluded by the keyboard, the harness scrolls automatically; if a `typeText` cannot find focus, add a `.tap()` on the field first (already done). The DatePicker defaults to today, which is inside the current FY, so no date manipulation is needed.

- [ ] **Step 3: Run the existing UI suite to confirm no regressions.**
  ```
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptUITests/CaptureUITests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: `Test Suite 'CaptureUITests' passed`.

- [ ] **Step 4: Commit.**
  ```
  git add SnapceiptUITests/LogbookUITests.swift
  git commit -m "Add hermetic logbook UI test (mileage flow + WFH log-hours)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 15: Full regression pass

Run the whole iOS test plan to confirm the unit baseline (now 160 + the new unit tests) and both UI suites are green together.

**Files:** none (verification only).

- [ ] **Step 1: Run the full unit suite.**
  ```
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptTests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: all `SnapceiptTests` pass.

- [ ] **Step 2: Run the full UI suite.**
  ```
  xcodebuild -scheme Snapceipt -only-testing:SnapceiptUITests -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```
  Expected: all `SnapceiptUITests` pass (`CaptureUITests`, `LogbookUITests`, and the pre-existing onboarding/launch/shell/smoke suites).

- [ ] **Step 3: Confirm a clean tree and finish.**
  All source/test commits happened in Tasks 1-14. The `.xcodeproj` is **git-ignored** (`.gitignore` has `*.xcodeproj/`), so it is NEVER committed — there is nothing to regenerate-and-track here. Verify nothing is left dangling:
  ```
  git status
  ```
  Expected: working tree clean (only the ignored `Snapceipt.xcodeproj/` may show as untracked-and-ignored, which `git status` hides by default). If any source/test file is unexpectedly modified, investigate before declaring done. No commit is needed in this task.
