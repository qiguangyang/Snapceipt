# Logbooks (Mileage + WFH) — Design Spec

- **Status:** Approved (brainstorm) — proceeding to implementation plan(s)
- **Date:** 2026-05-31
- **Branch:** `foundation`
- **Feature:** F1 of the remaining-features roadmap (`docs/superpowers/specs/2026-05-31-snapceipt-remaining-features-roadmap.md`).
- **Builds on:** the shipped foundation + capture feature. iOS (`Snapceipt/` + `SnapceiptTests/` + `SnapceiptUITests/`), Cloudflare backend (`src/`, `migrations/`, `test/`, `e2e/`). Design reference: `docs/superpowers/specs/extracted/screens.md` (MileageScreen + WFHScreen, lines ~914–1028) and `2026-05-30-snapceipt-ios-app-design.md` §3, §12.10, §14, §16, §21.
- **Baselines to keep green:** backend `npm test` = 185, `npm run test:e2e` = 8; iOS `xcodebuild -only-testing:SnapceiptTests` = 160 + `SnapceiptUITests/CaptureUITests`.

---

## 1. Goal

Ship the two **logbook** screens that let an AU sole trader record tax-claimable **vehicle mileage** and **working-from-home hours**, with correct ATO claim calculations, all local-first and synced.

- **WFH** = ATO **fixed-rate method** (manual daily hour logging × the per-hour rate).
- **Mileage** = ATO **logbook method** at the "manual cost totals" depth: a real odometer logbook over a 12-week period that yields a business-use %, applied to a user-entered annual running-cost total (+ optional depreciation helper). *Not* cents-per-km.

GPS auto-track stays a non-functional **placeholder** ("Coming soon") per the design.

## 2. Decisions locked in brainstorming

1. **Mileage = full ATO logbook method**, not cents-per-km. Depth = **"logbook + manual cost totals"**: build the real logbook (odometer trips, 12-week period, auto business-use %, vehicle entity, 5-yr validity); the user enters the annual running-cost total (with an optional simple depreciation helper); `claim = business_use_pct × total_costs`. Auto-aggregating vehicle-expense transactions + a full depreciation engine + GST credits are explicitly **out of scope** (a later integration with Reports/expenses).
2. **WFH = fixed-rate method, 70c/hr.** The spec's 67c is stale; the current ATO rate (since 1 Jul 2024, through FY2025-26) is **70c/hr**. Fix the default + on-screen copy.
3. **Single current rates, snapshotted per entry.** No per-FY historical rate table (app is new, no pre-2026 data). Each entry/`vehicle_year` snapshots the rate/percentage so a later `tax_settings` edit (F7) never rewrites historical claims.
4. **One vehicle per profile in v1** — the entity supports many; the UI assumes one (no switcher yet).
5. **Formal 12-week logbook period** tracked on the vehicle; business-use % computed from in-window trips; 5-yr validity surfaced.
6. **Claim is FY-level** (on `vehicle_year`), not per-trip.
7. **Period control deferred to F2.** Logbook heroes use fixed periods ("this FY") via a small new `FinancialYear` helper — not the shared Month/Quarter/FY switcher.
8. **Logbooks reachable from Home for all profiles** (not hard-gated to Business). The Reports Business-only logbook section is an F2 concern.

**The data layer already exists** (the foundation scaffolded all models): `wfh_logs`, `mileage_trips`, `tax_settings` tables + iOS `WFHLog`/`MileageTrip`/`TaxSettings` @Models are sync-wired. F1 therefore = **two SwiftUI screens + claim-calc + FY helper + tax_settings seeding + the new logbook-method tables (vehicle, vehicle_year, odometer columns) + tests + the WFH-rate fix.** No new backend routes.

## 3. Architecture

**Thin client + generic sync.** All logbook data is local SwiftData flowing through the **existing** `/sync/push` + `/sync/pull` handlers (LWW on `updatedAt`, soft-delete tombstones, keyset cursor, outbox). The only backend work is **schema** (new tables/columns) + **sync metadata** (registering the new entity types). No per-resource routes.

Delivered under one shared contract: **§4 (Data model & sync) is authoritative and self-contained** — an engineer can build the iOS or backend side from §4 alone. Likely split into two implementation plans (iOS UI + claim-calc; backend schema/sync/seeding), or a single plan given the backend side is small.

## 4. Data model & sync — AUTHORITATIVE CROSS-PLAN CONTRACT

All entities carry the standard sync envelope: `id` (UUIDv7, unique), `userId`, `profileId` (NOT NULL for all logbook entities), `createdAt`, `updatedAt`, `deletedAt?`, `rev`, `lastEditedDeviceId?`. D1 columns are snake_case; iOS/JSON are camelCase. Cents are `INTEGER`; dates are `TEXT` `YYYY-MM-DD`.

### 4.1 Reused as-is

**`wfh_logs`** (entity type `wfhLog`) — no schema change.
`log_date` (TEXT), `minutes` (INT), `note` (TEXT?), `rate_cents_per_hour` (INT, snapshot), `claim_cents` (INT). D1 has `UNIQUE INDEX ux_wfh_profile_date (profile_id, log_date) WHERE deleted_at IS NULL` → **one WFH log per profile per day**.

### 4.2 Changed

**`tax_settings`** — change `wfh_rate_cents_per_hour` **DEFAULT 67 → 70**. (iOS `TaxSettings.init` default likewise 67 → 70.) `mileage_rate_cents_per_km` (88) stays in the schema but is **unused** under the logbook method. F1 also adds **seeding** (§7).

**`mileage_trips`** (entity type `mileageTrip`) — add three columns:
| D1 column | iOS / JSON | Type | Notes |
|---|---|---|---|
| `vehicle_id` | `vehicleId` | TEXT? / String? | FK → `vehicles(id)`; the trip's car |
| `odometer_start_m` | `odometerStartM` | INTEGER? / Int? | metres |
| `odometer_end_m` | `odometerEndM` | INTEGER? / Int? | metres; must be > start |

`distance_m` (`distanceM`) is now **derived** = `odometer_end_m − odometer_start_m`, set on save. Existing `rate_cents_per_km`/`claim_cents`/`auto_tracked` remain but are **unused** (no per-trip dollar claim under the logbook method). `from_label`/`to_label`/`purpose`/`is_business`/`trip_date` keep their meaning; `is_business` distinguishes business vs private km for the business-use %.

### 4.3 New — `vehicles` (entity type `vehicle`)

```sql
CREATE TABLE vehicles (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  make                  TEXT,
  model                 TEXT,
  engine_cc             INTEGER,
  registration          TEXT,
  logbook_start_date    TEXT,            -- YYYY-MM-DD, NULL until logbook started
  logbook_end_date      TEXT,            -- YYYY-MM-DD, = start + ~12 weeks (editable)
  business_use_pct      INTEGER,         -- 0..100, cached from in-window trips, NULL until computed
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_vehicle_user_updated ON vehicles(user_id, updated_at);
CREATE INDEX ix_vehicle_profile      ON vehicles(profile_id) WHERE deleted_at IS NULL;
```
iOS `Vehicle` @Model mirrors these (`engineCc`, `logbookStartDate`, `logbookEndDate`, `businessUsePct`, etc.). `entityType { .vehicle }`.

### 4.4 New — `vehicle_years` (entity type `vehicleYear`)

```sql
CREATE TABLE vehicle_years (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  vehicle_id            TEXT NOT NULL REFERENCES vehicles(id),
  fy_start_year         INTEGER NOT NULL,         -- 2025 => FY2025-26
  odometer_open_m       INTEGER,
  odometer_close_m      INTEGER,
  fuel_cents            INTEGER NOT NULL DEFAULT 0,
  rego_cents            INTEGER NOT NULL DEFAULT 0,
  insurance_cents       INTEGER NOT NULL DEFAULT 0,
  servicing_cents       INTEGER NOT NULL DEFAULT 0,
  other_cents           INTEGER NOT NULL DEFAULT 0,
  depreciation_cents    INTEGER NOT NULL DEFAULT 0,
  business_use_pct      INTEGER,                  -- snapshot at compute time
  claim_cents           INTEGER,                  -- cached = pct% * sum(costs)
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE UNIQUE INDEX ux_vehicle_year         ON vehicle_years(vehicle_id, fy_start_year) WHERE deleted_at IS NULL;
CREATE INDEX        ix_vehicle_year_user_updated ON vehicle_years(user_id, updated_at);
```
iOS `VehicleYear` @Model mirrors. `entityType { .vehicleYear }`. One row per (vehicle, FY).

### 4.5 Sync wiring checklist (exact files)

**Backend:**
- `migrations/0001_init.sql` — add the two `CREATE TABLE`s + the three `mileage_trips` columns + bump `tax_settings.wfh_rate_cents_per_hour` default to 70. (Repo uses a single forward-only init migration; tests rebuild from it. Local dev `.wrangler` D1 must be reset once.)
- `src/lib/syncTables.ts` — add `vehicle` + `vehicleYear` to `SYNCABLE_TABLES` (with camelCase→snake_case `columns` maps) and to `PROFILE_ID_REQUIRED`; extend the `mileageTrip` `columns` map with `vehicleId`/`odometerStartM`/`odometerEndM`.
- `src/lib/db.ts` — add `vehicles` + `vehicle_years` to `SCOPED_TABLES`.
- `src/schemas/entities.ts` — add `"vehicle"` + `"vehicleYear"` to `SYNCABLE_TYPES` (+ specialized schemas beyond `baseEnvelope` if field validation is wanted).

**iOS:**
- `Snapceipt/Model/Entities/Vehicle.swift`, `VehicleYear.swift` — new `@Model … : Syncable`.
- `Snapceipt/Model/Entities/MileageTrip.swift` — add `vehicleId`/`odometerStartM`/`odometerEndM`.
- `Snapceipt/Model/Entities/TaxSettings.swift` — WFH default 67 → 70.
- `Snapceipt/Model/EntityType.swift` — add `case vehicle`, `case vehicleYear`.
- `Snapceipt/Model/ModelContainer+Snapceipt.swift` — add `Vehicle.self`, `VehicleYear.self` to `SnapceiptSchema.models`.
- `Snapceipt/Sync/SyncEntityRegistry.swift` — add `VehicleSyncMapper`, `VehicleYearSyncMapper`; extend `MileageTripSyncMapper` payload/upsert with the new fields; conform both new models to `SyncableMutableEnvelope, MutableSyncRow`; `register(.vehicle, …)` + `register(.vehicleYear, …)`.

(Landmine: timestamp helper is `Epoch.nowMs()`, **not** `Clock`.)

## 5. Claim calculation + AU financial-year helper

### 5.1 `FinancialYear` helper (new)
A small util (consumed by F2/F7 later):
- `financialYear(of date: Date, startMonth: Int = 7) -> (start: Date, end: Date, startYear: Int, label: String)` — `startMonth = 7` ⇒ 1 Jul Y → 30 Jun Y+1, `startYear = Y`, `label = "FY\(Y)-\(Y+1 mod 100)"` (e.g. `FY2025-26`).
- `isIn(_ date: Date, fyStartYear: Int, startMonth: Int) -> Bool`.
Driven by `tax_settings.financial_year_start_month`. Edge cases pinned in tests: 30 Jun vs 1 Jul.

### 5.2 WFH
- Per entry: `claim_cents = round(minutes / 60 × rate_cents_per_hour)`, rate snapshotted from `tax_settings` (70c) at create/edit.
- Hero (FY): over `wfh_logs` in the current FY for the active profile — `hours = Σminutes / 60`; `Claimable = Σclaim_cents`; `Days logged = count`; `Avg/day = hours / days`.
- This-week chart: Σminutes per weekday for the current Mon–Sun; bars scale to `max(8h, weekMax)`.

### 5.3 Mileage (logbook method)
- **Business-use %** (per `vehicle`): over trips with `trip_date ∈ [logbook_start_date, logbook_end_date]` → `pct = round(Σbusiness_km / Σtotal_km × 100)`; `km = distance_m / 1000`. Cached on `vehicle.business_use_pct`; recomputed whenever in-window trips or the window change. Undefined (NULL) until ≥1 in-window trip.
- **FY claim** (per `vehicle_year` for the current FY): `total_cents = fuel+rego+insurance+servicing+other+depreciation`; `claim_cents = round(business_use_pct/100 × total_cents)`; `business_use_pct` snapshotted onto the row. Cached.
- Hero (FY): `Claimable = vehicle_year.claim_cents` (current FY); `Business use % = vehicle.business_use_pct`; `km = Σ business-trip km this FY`; `Trips = count this FY`.
- **No 5,000-km cap** applies — that cap is a cents-per-km rule; the logbook method has no km cap (it's a % of actual costs).

### 5.4 Depreciation helper (optional, labelled "simplified estimate — not tax advice")
Inputs: purchase price (capped at the **car cost limit $69,674 for FY2025-26**), purchase date (first-year part-year proration by days held / 365), method.
- Diminishing value: `decline = baseValue × daysHeld/365 × (2 / effectiveLifeYears)` (car effective life 8 yrs ⇒ 25%).
- Prime cost: `decline = cost × daysHeld/365 × (1 / effectiveLifeYears)` (⇒ 12.5%).
User may bypass the helper and type a depreciation figure directly into `depreciation_cents`.

## 6. UI

Both screens are full-screen overlays (`overlay='mileage'/'wfh'`), accent re-skinned to the active profile, matching `screens.md`. Empty states use `EmptyArt`. Edit = tap row → pre-filled sheet; delete = swipe → soft-delete (set `deletedAt`, enqueue delete). All writes are local-first through the outbox; **no feature-specific network calls**.

### 6.1 MileageScreen (scroll, top → bottom)
1. **Hero** (designed gradient) — label "This financial year"; pill "Logbook method"; big number = FY business km; stats = **Claimable $ · Business use % · Trips**.
2. **Vehicle card** (compact) — empty → "Add your vehicle"; set → "2021 Toyota HiLux · ABC123" → vehicle sheet.
3. **Logbook period card** (compact) — not started → "Start your 12-week logbook"; active/done → "12 Aug – 4 Nov 2025 · 78% business use · valid to 2030" → logbook-period sheet.
4. **GPS auto-track card** — **placeholder** exactly per design ("Coming soon", non-functional toggle, no location/network).
5. **Car expenses & claim card** (compact) — "Running costs FY25–26: $4,120 → claim $3,214 (78%)" → running-costs sheet. Costs are editable once a vehicle exists; the **claim amount** shows "—" with a "Start your logbook" prompt until `business_use_pct` is computed (no % ⇒ no claim).
6. **Recent trips list** (designed) — `from → to` / `purpose` / `km` / Business|Personal tag.
7. **Floating "Add a trip" CTA** (designed).

**Sheets:** Add/Edit trip (date, odometer start, odometer end → km shown, purpose, Business/Private, optional from/to; validation end > start); Vehicle (make, model, engine cc optional, registration); Logbook period (start date, auto 12-week end editable, live business-use % + 5-yr validity note); Running costs (Fuel/Registration/Insurance/Servicing/Other + Depreciation w/ optional helper).

### 6.2 WFHScreen (scroll)
1. **Hero** (designed) — label "This financial year"; pill **"70c / hour"**; big number = FY hours; stats = **Claimable $ · Days logged · Avg/day**.
2. **This-week bar chart** (designed; scale `max(8h, weekMax)`).
3. **Logged-days list** (designed) — date / note / hours.
4. **Fixed-rate explainer** (designed, updated): "The 70c fixed rate covers electricity, gas, internet, phone & stationery. No need to keep separate bills."
5. **Floating "Log hours" CTA** (designed).
6. **Empty state** + a quiet note that hours should be logged as worked (ATO no longer accepts after-the-fact estimates).

**Sheet:** Log hours (date default today, hours, optional note). A date that already has a log **pre-fills and edits** it (one-per-day unique constraint).

### 6.3 Navigation
Home QuickActions → Mileage / WFH (verify the app shell already has QuickActions; add the two if not). Reports logbook-shortcut rows = F2.

## 7. `tax_settings` seeding (the gap)
Profiles are currently created with no `tax_settings` row. F1 adds:
- **On profile creation** (iOS profiles feature): also insert `TaxSettings(profileId:)` with ATO defaults (mileage 88, **wfh 70**, FY-start 7, GST 1000bps, meals 50%) + enqueue upsert.
- **Lazy-ensure** on logbook-screen load: if the active profile has no `TaxSettings`, create one (covers profiles made before F1). The existing `TaxSettingsSyncMapper` already materializes a row on pull when the server has one.

## 8. Testing
Keep baselines green (185 backend / 8 e2e / 160 iOS + CaptureUITests); add:
- **iOS unit:** `FinancialYear` boundaries/labels/membership (30 Jun↔1 Jul); WFH calc + FY aggregation + this-week bucketing + rate snapshot; mileage business-use-% from in-window trips, `vehicle_year` claim = pct × costs, depreciation helper (DV/PC, car-limit cap, part-year), odometer→km; model round-trip + profile-scoping for `Vehicle`/`VehicleYear`/extended `MileageTrip`; sync enqueue + pull-upsert for the new entities; `tax_settings` seeding (new + legacy profile).
- **iOS UI** (hermetic, CaptureUITests-style): add vehicle → start logbook → add trip → enter running costs → see claim; log WFH hours → see FY claim.
- **Backend:** `sync-push`/`sync-pull` for `vehicle`, `vehicleYear`, extended `mileageTrip` (idempotency, LWW, soft-delete, profile_id-required, keyset pagination); e2e push→pull round-trip asserting wire shapes match the iOS Codable contract; migration test (new tables/columns exist; `tax_settings` WFH default = 70).

## 9. Non-goals (this feature)
- Cents-per-km method; the 5,000-km cap.
- Auto-aggregating vehicle-expense transactions; a full depreciation engine; GST input-credit calc.
- Multiple vehicles per profile (entity supports it; UI is single-vehicle).
- GPS auto-track (placeholder only — no location, no network).
- The shared Month/Quarter/FY period switcher (F2); the Reports logbook section (F2).
- The full `tax_settings` editor UI (F7) — F1 only seeds defaults + lazy-ensures.
- Per-FY historical rate tables.

## 10. Pre-implementation checklist
- Confirm the app shell exposes **Home QuickActions** to wire Mileage/WFH entry (add if absent).
- Confirm editing `0001_init.sql` (vs a new `0002`) is acceptable — note local `.wrangler` dev D1 reset.
- Confirm the WFH-rate default change (67 → 70) is desired now (it is — current ATO rate).
- ATO record-retention policy (5-year keep) is a cross-feature decision tracked in the roadmap; not blocking F1.
