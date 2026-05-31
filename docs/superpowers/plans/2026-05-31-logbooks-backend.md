# Logbooks Backend (Schema + Sync) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Wire the F1 Logbooks data layer into the Cloudflare Worker — add `vehicles` + `vehicle_years` tables, three odometer/vehicle columns on `mileage_trips`, bump the WFH rate default to 70c, and register the two new entity types so the generic `/sync/push` + `/sync/pull` handle them with no new routes.

**Architecture:** The backend is a thin generic-sync server: every syncable entity flows through one `/sync/push` (LWW on `updatedAt`, soft-delete tombstones, idempotency replay) and one `/sync/pull` (keyset cursor) handler, driven entirely by the `SYNCABLE_TABLES` registry (`src/lib/syncTables.ts`), the `SCOPED_TABLES` allow-list (`src/lib/db.ts`), and the `SYNCABLE_TYPES` list (`src/schemas/entities.ts`). This plan only edits the single forward-only migration and those three registries; the route code in `src/routes/sync.ts` is untouched.

**Tech Stack:** Cloudflare Workers (Hono), D1 (SQLite), Zod, TypeScript, Vitest with `@cloudflare/vitest-pool-workers` (`cloudflare:test`), wrangler `unstable_dev` for HTTP e2e.

---

## File structure

| File | Create/Modify | Responsibility |
|---|---|---|
| `migrations/0001_init.sql` | Modify | Add `CREATE TABLE vehicles` + `CREATE TABLE vehicle_years` (with indexes), add `vehicle_id`/`odometer_start_m`/`odometer_end_m` to `mileage_trips`, change `tax_settings.wfh_rate_cents_per_hour` DEFAULT 67 → 70. |
| `src/lib/db.ts` | Modify | Add `vehicles` + `vehicle_years` to the `SCOPED_TABLES` allow-list so the scoped query/pull path may touch them. |
| `src/lib/syncTables.ts` | Modify | Add `vehicle` + `vehicleYear` to `SYNCABLE_TABLES` (camelCase→snake_case `columns` maps) and to `PROFILE_ID_REQUIRED`; extend the `mileageTrip` `columns` map with `vehicleId`/`odometerStartM`/`odometerEndM`. |
| `src/schemas/entities.ts` | Modify | Add `vehicleEntity` + `vehicleYearEntity` Zod schemas, register them in `SPECIALIZED`, and add `"vehicle"` + `"vehicleYear"` to `SYNCABLE_TYPES`. |
| `test/schema.test.ts` | Modify | Extend the migration/schema test: assert the two new tables + their indexes exist, the three new `mileage_trips` columns exist, and `tax_settings.wfh_rate_cents_per_hour` DEFAULT = 70. |
| `test/schemas.test.ts` | Modify | Update the `SYNCABLE_TYPES.length` assertion 12 → 14 and add coverage for the two new types. |
| `test/sync-push.test.ts` | Modify | Update the "all 12 syncable entity types" coverage test to 14 (+ table maps); add push tests for `vehicle`, `vehicleYear`, and the extended `mileageTrip` fields (applied/rev, idempotency replay, LWW conflict, soft-delete tombstone, profile_id-required rejection). |
| `test/sync-pull.test.ts` | Modify | Add pull tests: seed a `vehicle`, a `vehicle_year`, and a `mileage_trips` row with the new columns; assert they come back in the global keyset stream with correct camelCase wire shapes incl. a tombstone. |
| `e2e/snapceipt.e2e.test.ts` | Modify | Add a black-box push→pull round-trip over real HTTP for `vehicle` + `vehicleYear` + extended `mileageTrip`, asserting the camelCase wire shapes. |

---

### Task 1: Schema — add tables, columns, and the WFH-rate default

Edit the single forward-only init migration. Tests rebuild the DB from it via `applyD1Migrations`, so the schema test in this task drives the change. (Local dev `.wrangler` D1 must be reset once after this edit, but tests do not depend on that.)

**Files:**
- Modify: `migrations/0001_init.sql` — `mileage_trips` block (lines ~296–316), `tax_settings` block (line ~410), and append the two new tables in the "Logbooks" section (after line ~334).
- Modify (Test): `test/schema.test.ts` — `describe("0001_init schema", …)` (lines ~38–139).

**Steps:**

- [ ] **Step 1: Write the FAILING schema test.** Append these `it(...)` blocks INSIDE the existing `describe("0001_init schema", () => { … })` in `test/schema.test.ts`, just before its closing `});` on line ~139. They reuse the file's existing `columnsOf` / `indexNames` helpers. (Note: `applyD1Migrations` is idempotent and already invoked in this file's `beforeAll` and in `test/apply-migrations.ts`, so no extra setup is needed.)

```ts
  it("adds the logbook-method columns to mileage_trips", async () => {
    const cols = await columnsOf("mileage_trips");
    for (const c of ["vehicle_id", "odometer_start_m", "odometer_end_m"]) {
      expect(cols.has(c), `mileage_trips missing column ${c}`).toBe(true);
    }
  });

  it("creates the vehicles table with its sync + domain columns", async () => {
    const cols = await columnsOf("vehicles");
    for (const c of [
      "id", "user_id", "profile_id", "make", "model", "engine_cc",
      "registration", "logbook_start_date", "logbook_end_date", "business_use_pct",
      "created_at", "updated_at", "deleted_at", "rev", "last_edited_device_id",
    ]) {
      expect(cols.has(c), `vehicles missing column ${c}`).toBe(true);
    }
    const ix = await indexNames();
    expect(ix.has("ix_vehicle_user_updated")).toBe(true);
    expect(ix.has("ix_vehicle_profile")).toBe(true);
  });

  it("creates the vehicle_years table with its sync + domain columns", async () => {
    const cols = await columnsOf("vehicle_years");
    for (const c of [
      "id", "user_id", "profile_id", "vehicle_id", "fy_start_year",
      "odometer_open_m", "odometer_close_m", "fuel_cents", "rego_cents",
      "insurance_cents", "servicing_cents", "other_cents", "depreciation_cents",
      "business_use_pct", "claim_cents",
      "created_at", "updated_at", "deleted_at", "rev", "last_edited_device_id",
    ]) {
      expect(cols.has(c), `vehicle_years missing column ${c}`).toBe(true);
    }
    const ix = await indexNames();
    expect(ix.has("ux_vehicle_year")).toBe(true);
    expect(ix.has("ix_vehicle_year_user_up")).toBe(true);
  });

  it("defaults tax_settings.wfh_rate_cents_per_hour to 70 (current ATO rate)", async () => {
    const { results } = await env.DB.prepare(`PRAGMA table_info(tax_settings)`).all<{
      name: string;
      dflt_value: string | null;
    }>();
    const wfh = results.find((r) => r.name === "wfh_rate_cents_per_hour");
    expect(wfh, "wfh_rate_cents_per_hour column missing").toBeDefined();
    expect(Number(wfh!.dflt_value)).toBe(70);
  });
```

  Also add the two new tables to the file-level `SYNCABLE` list so the existing "creates every table" + "adds sync columns to every syncable table" tests cover them. Change (lines ~17–21):

```ts
const SYNCABLE = [
  "users", "devices", "profiles", "categories", "smart_rules",
  "transactions", "line_items", "receipt_images", "budgets", "loyalty_cards",
  "mileage_trips", "wfh_logs", "quotes", "quote_line_items", "tax_settings",
];
```

  to:

```ts
const SYNCABLE = [
  "users", "devices", "profiles", "categories", "smart_rules",
  "transactions", "line_items", "receipt_images", "budgets", "loyalty_cards",
  "mileage_trips", "wfh_logs", "quotes", "quote_line_items", "tax_settings",
  "vehicles", "vehicle_years",
];
```

- [ ] **Step 2: Run the test — expect FAIL.** The new tables/columns do not exist yet.

```
npm test -- test/schema.test.ts
```

  Expected: failures such as `vehicles missing column id`, `vehicle_years missing column id`, `mileage_trips missing column vehicle_id`, `expected 67 to be 70`, and `missing table vehicles` (from the "creates every table" loop).

- [ ] **Step 3: Edit the migration — add columns to `mileage_trips`.** In `migrations/0001_init.sql`, replace the `mileage_trips` `CREATE TABLE` (lines ~296–314) so the three new columns sit after `auto_tracked`, before the envelope columns:

```sql
CREATE TABLE mileage_trips (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  trip_date             TEXT NOT NULL,
  from_label            TEXT,
  to_label              TEXT,
  purpose               TEXT,
  distance_m            INTEGER NOT NULL,
  is_business           INTEGER NOT NULL DEFAULT 1,
  rate_cents_per_km     INTEGER,
  claim_cents           INTEGER,
  auto_tracked          INTEGER NOT NULL DEFAULT 0,
  vehicle_id            TEXT REFERENCES vehicles(id),
  odometer_start_m      INTEGER,
  odometer_end_m        INTEGER,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_trip_user_updated ON mileage_trips(user_id, updated_at);
CREATE INDEX ix_trip_profile_date ON mileage_trips(profile_id, trip_date) WHERE deleted_at IS NULL;
```

- [ ] **Step 4: Edit the migration — append the two new tables.** In the "Logbooks: Mileage & WFH" section, immediately AFTER the `wfh_logs` block (after `CREATE UNIQUE INDEX ux_wfh_profile_date …` on line ~334) and BEFORE the "Quotes & Quote Line Items" section header, insert:

```sql
CREATE TABLE vehicles (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  make                  TEXT,
  model                 TEXT,
  engine_cc             INTEGER,
  registration          TEXT,
  logbook_start_date    TEXT,
  logbook_end_date      TEXT,
  business_use_pct      INTEGER,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_vehicle_user_updated ON vehicles(user_id, updated_at);
CREATE INDEX ix_vehicle_profile      ON vehicles(profile_id) WHERE deleted_at IS NULL;

CREATE TABLE vehicle_years (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  vehicle_id            TEXT NOT NULL REFERENCES vehicles(id),
  fy_start_year         INTEGER NOT NULL,
  odometer_open_m       INTEGER,
  odometer_close_m      INTEGER,
  fuel_cents            INTEGER NOT NULL DEFAULT 0,
  rego_cents            INTEGER NOT NULL DEFAULT 0,
  insurance_cents       INTEGER NOT NULL DEFAULT 0,
  servicing_cents       INTEGER NOT NULL DEFAULT 0,
  other_cents           INTEGER NOT NULL DEFAULT 0,
  depreciation_cents    INTEGER NOT NULL DEFAULT 0,
  business_use_pct      INTEGER,
  claim_cents           INTEGER,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE UNIQUE INDEX ux_vehicle_year         ON vehicle_years(vehicle_id, fy_start_year) WHERE deleted_at IS NULL;
CREATE INDEX        ix_vehicle_year_user_up ON vehicle_years(user_id, updated_at);
```

  NOTE: `mileage_trips` is created (line ~296) BEFORE `vehicles` (inserted after line ~334), so `mileage_trips.vehicle_id REFERENCES vehicles(id)` forward-references a table not yet defined. This is safe: the migration opens with `PRAGMA foreign_keys = OFF;` (line 5), and SQLite only resolves FK target tables at write time, not at `CREATE TABLE` parse time — the existing `transactions.mileage_trip_id REFERENCES mileage_trips(id)` (line 184) already relies on this same forward-reference pattern. Do NOT reorder the tables.

- [ ] **Step 5: Edit the migration — bump the WFH rate default.** In the `tax_settings` `CREATE TABLE`, change line ~410:

```sql
  wfh_rate_cents_per_hour     INTEGER NOT NULL DEFAULT 67,
```

  to:

```sql
  wfh_rate_cents_per_hour     INTEGER NOT NULL DEFAULT 70,
```

- [ ] **Step 6: Run the test — expect PASS.**

```
npm test -- test/schema.test.ts
```

  Expected: all `0001_init schema` tests pass, including the four new ones and the now-extended "creates every table" / "adds sync columns" loops.

- [ ] **Step 7: Commit.**

```
git add migrations/0001_init.sql test/schema.test.ts
git commit -m "$(cat <<'EOF'
Add logbook tables/columns + WFH-rate default to 0001_init

vehicles, vehicle_years, mileage_trips odometer columns, tax_settings wfh 67->70.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `db.ts` — allow-list the two new tables

`scopedAll` / `scopedGet` and the pull route's per-table query call `assertTable`, which throws for any table not in `SCOPED_TABLES`. The new tables must be added or pull would never query them (and `scopedAll` would throw in tests).

**Files:**
- Modify: `src/lib/db.ts` — `SCOPED_TABLES` set (lines ~19–24).
- Modify (Test): `test/schema.test.ts` — add a `scopedAll` round-trip for `vehicles` to the existing `describe("0001_init schema", …)`.

**Steps:**

- [ ] **Step 1: Write the FAILING test.** Append this `it(...)` inside `describe("0001_init schema", () => { … })` in `test/schema.test.ts` (before its closing `});`). It seeds a user + profile + vehicle and reads it back through the tenant-scoped helper, mirroring the existing `month_key` round-trip test (lines ~98–124). `scopedAll`/`scopedGet` are already imported at the top of the file.

```ts
  it("round-trips a vehicle through the tenant-scoped helpers", async () => {
    await env.DB.batch([
      env.DB.prepare(`INSERT OR IGNORE INTO users(id,created_at,updated_at) VALUES('uv',1,1)`),
      env.DB.prepare(`INSERT INTO profiles(id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
                      VALUES('pv','uv','Personal','personal','#0E7C72','#DCF0ED','#0A5950',1,1)`),
      env.DB.prepare(`INSERT INTO vehicles(id,user_id,profile_id,make,model,business_use_pct,created_at,updated_at,rev)
                      VALUES('veh1','uv','pv','Toyota','HiLux',78,5,5,1)`),
      env.DB.prepare(`INSERT INTO vehicle_years(id,user_id,profile_id,vehicle_id,fy_start_year,fuel_cents,claim_cents,created_at,updated_at,rev)
                      VALUES('vy1','uv','pv','veh1',2025,412000,321360,5,5,1)`),
    ]);

    const vehicles = await scopedAll<{ id: string; make: string; business_use_pct: number }>(
      env.DB, "vehicles", "uv",
    );
    expect(vehicles).toHaveLength(1);
    expect(vehicles[0]!.make).toBe("Toyota");
    expect(vehicles[0]!.business_use_pct).toBe(78);

    const vy = await scopedGet<{ id: string; fy_start_year: number; claim_cents: number }>(
      env.DB, "vehicle_years", "uv", "vy1",
    );
    expect(vy?.fy_start_year).toBe(2025);
    expect(vy?.claim_cents).toBe(321360);
  });
```

- [ ] **Step 2: Run the test — expect FAIL.**

```
npm test -- test/schema.test.ts
```

  Expected: `db: unknown/unsafe table 'vehicles'` thrown from `assertTable`.

- [ ] **Step 3: Edit `src/lib/db.ts`.** Replace the `SCOPED_TABLES` set (lines ~19–24):

```ts
const SCOPED_TABLES = new Set([
  "users", "devices", "profiles", "categories", "smart_rules",
  "transactions", "line_items", "receipt_images", "budgets", "loyalty_cards",
  "mileage_trips", "wfh_logs", "quotes", "quote_line_items", "tax_settings",
  "auth_identities", "email_tokens", "sessions", "email_outbox",
]);
```

  with:

```ts
const SCOPED_TABLES = new Set([
  "users", "devices", "profiles", "categories", "smart_rules",
  "transactions", "line_items", "receipt_images", "budgets", "loyalty_cards",
  "mileage_trips", "wfh_logs", "vehicles", "vehicle_years", "quotes",
  "quote_line_items", "tax_settings",
  "auth_identities", "email_tokens", "sessions", "email_outbox",
]);
```

- [ ] **Step 4: Run the test — expect PASS.**

```
npm test -- test/schema.test.ts
```

  Expected: the new round-trip test passes; all other `0001_init schema` tests still pass.

- [ ] **Step 5: Commit.**

```
git add src/lib/db.ts test/schema.test.ts
git commit -m "$(cat <<'EOF'
Allow-list vehicles + vehicle_years in db SCOPED_TABLES

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `syncTables.ts` — register the two new tables + extend mileageTrip

Add the `vehicle` + `vehicleYear` entries to `SYNCABLE_TABLES` (with camelCase→snake_case `columns` maps), add both to `PROFILE_ID_REQUIRED` (their `profile_id` is `NOT NULL`), and extend the `mileageTrip` `columns` map with the three new fields. The push/pull route code reads these maps generically — no route changes.

**Files:**
- Modify: `src/lib/syncTables.ts` — `mileageTrip` entry (lines ~154–168), add two new entries to `SYNCABLE_TABLES` (after the `wfhLog` entry, before `taxSettings`, lines ~169–179), and extend `PROFILE_ID_REQUIRED` (lines ~200–207).
- Modify (Test): `test/sync-push.test.ts` — the `describe("syncable table map", …)` coverage test (lines ~304–329).

**Steps:**

- [ ] **Step 1: Write the FAILING test.** In `test/sync-push.test.ts`, replace the entire `describe("syncable table map", () => { … })` block (lines ~304–329) with this version (count 12 → 14, two new mappings, asserts `PROFILE_ID_REQUIRED` membership). It imports `PROFILE_ID_REQUIRED` — add it to the existing import from `../src/lib/syncTables` at the top of the file (line ~6: `import { tableForEntityType } from "../src/lib/syncTables";` → `import { tableForEntityType, PROFILE_ID_REQUIRED } from "../src/lib/syncTables";`).

```ts
describe("syncable table map", () => {
  it("maps all 14 syncable entity types to a table (full coverage)", () => {
    const expected: Record<string, string> = {
      transaction: "transactions",
      lineItem: "line_items",
      profile: "profiles",
      category: "categories",
      smartRule: "smart_rules",
      budget: "budgets",
      loyaltyCard: "loyalty_cards",
      quote: "quotes",
      quoteLineItem: "quote_line_items",
      mileageTrip: "mileage_trips",
      wfhLog: "wfh_logs",
      taxSettings: "tax_settings",
      vehicle: "vehicles",
      vehicleYear: "vehicle_years",
    };
    expect(SYNCABLE_TYPES).toHaveLength(14);
    for (const type of SYNCABLE_TYPES) {
      const meta = tableForEntityType(type);
      expect(meta, `missing table mapping for ${type}`).not.toBeNull();
      expect(meta!.table).toBe(expected[type]);
    }
    // Unknown types map to null.
    expect(tableForEntityType("notAType")).toBeNull();
  });

  it("requires profile_id for the new vehicle + vehicleYear tables", () => {
    expect(PROFILE_ID_REQUIRED.has("vehicle")).toBe(true);
    expect(PROFILE_ID_REQUIRED.has("vehicleYear")).toBe(true);
  });

  it("maps the new mileageTrip logbook columns", () => {
    const meta = tableForEntityType("mileageTrip")!;
    expect(meta.columns.vehicleId).toBe("vehicle_id");
    expect(meta.columns.odometerStartM).toBe("odometer_start_m");
    expect(meta.columns.odometerEndM).toBe("odometer_end_m");
  });

  it("maps the vehicle + vehicleYear domain columns", () => {
    const v = tableForEntityType("vehicle")!;
    expect(v.hasProfileId).toBe(true);
    expect(v.columns.engineCc).toBe("engine_cc");
    expect(v.columns.logbookStartDate).toBe("logbook_start_date");
    expect(v.columns.businessUsePct).toBe("business_use_pct");

    const vy = tableForEntityType("vehicleYear")!;
    expect(vy.hasProfileId).toBe(true);
    expect(vy.columns.vehicleId).toBe("vehicle_id");
    expect(vy.columns.fyStartYear).toBe("fy_start_year");
    expect(vy.columns.depreciationCents).toBe("depreciation_cents");
    expect(vy.columns.claimCents).toBe("claim_cents");
  });
});
```

- [ ] **Step 2: Run the test — expect FAIL.**

```
npm test -- test/sync-push.test.ts
```

  Expected: `expected 12 to be 14` (the `SYNCABLE_TYPES` length — bumped in Task 4; for now this file will fail on length) and `tableForEntityType("vehicle")` returning `null` → `Cannot read properties of null`.

  NOTE: This task changes `syncTables.ts` only; `SYNCABLE_TYPES` (in `entities.ts`) is bumped to 14 in Task 4. Until Task 4 lands, the `toHaveLength(14)` assertion will still fail. That is expected — the other three new `it` blocks (PROFILE_ID_REQUIRED, mileageTrip columns, vehicle/vehicleYear columns) drive THIS task and will pass after Step 3. Re-run the full file at the end of Task 4 to see all 14-count assertions green.

- [ ] **Step 3: Edit `src/lib/syncTables.ts`.** First, extend the `mileageTrip` `columns` map (lines ~154–168). Replace:

```ts
  mileageTrip: {
    table: "mileage_trips",
    hasProfileId: true,
    columns: {
      tripDate: "trip_date",
      fromLabel: "from_label",
      toLabel: "to_label",
      purpose: "purpose",
      distanceM: "distance_m",
      isBusiness: "is_business",
      rateCentsPerKm: "rate_cents_per_km",
      claimCents: "claim_cents",
      autoTracked: "auto_tracked",
    },
  },
```

  with:

```ts
  mileageTrip: {
    table: "mileage_trips",
    hasProfileId: true,
    columns: {
      tripDate: "trip_date",
      fromLabel: "from_label",
      toLabel: "to_label",
      purpose: "purpose",
      distanceM: "distance_m",
      isBusiness: "is_business",
      rateCentsPerKm: "rate_cents_per_km",
      claimCents: "claim_cents",
      autoTracked: "auto_tracked",
      vehicleId: "vehicle_id",
      odometerStartM: "odometer_start_m",
      odometerEndM: "odometer_end_m",
    },
  },
```

  Then add the two new entries. Immediately AFTER the `wfhLog` entry (ends line ~179) and BEFORE the `taxSettings` entry (line ~180), insert:

```ts
  vehicle: {
    table: "vehicles",
    hasProfileId: true,
    columns: {
      make: "make",
      model: "model",
      engineCc: "engine_cc",
      registration: "registration",
      logbookStartDate: "logbook_start_date",
      logbookEndDate: "logbook_end_date",
      businessUsePct: "business_use_pct",
    },
  },
  vehicleYear: {
    table: "vehicle_years",
    hasProfileId: true,
    columns: {
      vehicleId: "vehicle_id",
      fyStartYear: "fy_start_year",
      odometerOpenM: "odometer_open_m",
      odometerCloseM: "odometer_close_m",
      fuelCents: "fuel_cents",
      regoCents: "rego_cents",
      insuranceCents: "insurance_cents",
      servicingCents: "servicing_cents",
      otherCents: "other_cents",
      depreciationCents: "depreciation_cents",
      businessUsePct: "business_use_pct",
      claimCents: "claim_cents",
    },
  },
```

  Then extend `PROFILE_ID_REQUIRED` (lines ~200–207). Replace:

```ts
export const PROFILE_ID_REQUIRED: ReadonlySet<string> = new Set([
  "transaction",
  "budget",
  "mileageTrip",
  "wfhLog",
  "quote",
  "taxSettings",
]);
```

  with:

```ts
export const PROFILE_ID_REQUIRED: ReadonlySet<string> = new Set([
  "transaction",
  "budget",
  "mileageTrip",
  "wfhLog",
  "vehicle",
  "vehicleYear",
  "quote",
  "taxSettings",
]);
```

- [ ] **Step 4: Run the test — expect PARTIAL PASS.** The three new mapping/required tests pass; the `toHaveLength(14)` assertion still fails until Task 4. Run:

```
npm test -- test/sync-push.test.ts
```

  Expected: "requires profile_id …", "maps the new mileageTrip logbook columns", and "maps the vehicle + vehicleYear domain columns" all PASS. "maps all 14 syncable entity types …" still FAILS on `expected 12 to be 14` — resolved in Task 4.

- [ ] **Step 5: Commit.**

```
git add src/lib/syncTables.ts test/sync-push.test.ts
git commit -m "$(cat <<'EOF'
Register vehicle + vehicleYear in syncTables; extend mileageTrip columns

Adds camelCase->snake_case maps + PROFILE_ID_REQUIRED entries. The 14-count
assertion stays red until SYNCABLE_TYPES is bumped in the next commit.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `entities.ts` — add Zod schemas + SYNCABLE_TYPES entries

Add specialized Zod schemas for the two new types (mirroring the `budgetEntity` / `loyaltyCardEntity` pattern: `baseEnvelope.extend({ type: z.literal(...), ... })`), register them in `SPECIALIZED`, and add both to `SYNCABLE_TYPES`. This bumps `SYNCABLE_TYPES.length` to 14 and flips the remaining Task 3 assertion green.

NOTE (verified against `src/routes/sync.ts`): the push route validates `payload` only against `baseEnvelope` (via `pushBodySchema`/`mutationSchema` in `src/schemas/sync.ts:19`) and does NOT call `entitySchemaFor()` at apply time — exactly like the existing `transaction`/`budget`/`loyaltyCard` specialized schemas, which are also registered but never run by the route. So these new schemas are exercised by the `test/schemas.test.ts` unit tests (this task) and by `entitySchemaFor`, NOT by the sync handlers. This is intentional and matches the established codebase pattern; do not wire `entitySchemaFor` into the route.

**Files:**
- Modify: `src/schemas/entities.ts` — add two schemas after `loyaltyCardEntity` (line ~122), extend `SYNCABLE_TYPES` (lines ~125–138), extend `SPECIALIZED` (lines ~142–148).
- Modify (Test): `test/schemas.test.ts` — the `SYNCABLE_TYPES.length` assertion (line ~167) + new schema coverage in `describe("entitySchemaFor / SYNCABLE_TYPES", …)`.

**Steps:**

- [ ] **Step 1: Write the FAILING test.** In `test/schemas.test.ts`, change line ~167 from `expect(SYNCABLE_TYPES.length).toBe(12);` to `expect(SYNCABLE_TYPES.length).toBe(14);` and add `expect(SYNCABLE_TYPES).toContain("vehicle"); expect(SYNCABLE_TYPES).toContain("vehicleYear");` inside that `it("exposes every syncable type", …)`. Then add the new schemas to the imports at the top (line ~2 block) and append a new `describe` block. The file's shared `env(overrides)` helper (lines ~32–45) builds a base envelope; pass `type` + domain fields as overrides.

  Imports — change the block at the top of the file:

```ts
import {
  baseEnvelope,
  transactionEntity,
  lineItemEntity,
  profileEntity,
  budgetEntity,
  loyaltyCardEntity,
  entitySchemaFor,
  SYNCABLE_TYPES,
} from "../src/schemas/entities";
```

  to:

```ts
import {
  baseEnvelope,
  transactionEntity,
  lineItemEntity,
  profileEntity,
  budgetEntity,
  loyaltyCardEntity,
  vehicleEntity,
  vehicleYearEntity,
  entitySchemaFor,
  SYNCABLE_TYPES,
} from "../src/schemas/entities";
```

  Update the coverage `it` (lines ~163–168):

```ts
  it("exposes every syncable type", () => {
    expect(SYNCABLE_TYPES).toContain("transaction");
    expect(SYNCABLE_TYPES).toContain("taxSettings");
    expect(SYNCABLE_TYPES).toContain("quoteLineItem");
    expect(SYNCABLE_TYPES).toContain("vehicle");
    expect(SYNCABLE_TYPES).toContain("vehicleYear");
    expect(SYNCABLE_TYPES.length).toBe(14);
  });
```

  Append this new `describe` block at the END of `test/schemas.test.ts`:

```ts
describe("vehicleEntity / vehicleYearEntity", () => {
  it("accepts a full vehicle payload", () => {
    const r = vehicleEntity.safeParse(
      env({
        type: "vehicle",
        make: "Toyota",
        model: "HiLux",
        engineCc: 2800,
        registration: "ABC123",
        logbookStartDate: "2025-08-12",
        logbookEndDate: "2025-11-04",
        businessUsePct: 78,
      }),
    );
    expect(r.success).toBe(true);
  });

  it("rejects a business_use_pct over 100", () => {
    const r = vehicleEntity.safeParse(env({ type: "vehicle", businessUsePct: 150 }));
    expect(r.success).toBe(false);
  });

  it("rejects a malformed logbookStartDate", () => {
    const r = vehicleEntity.safeParse(env({ type: "vehicle", logbookStartDate: "12/08/2025" }));
    expect(r.success).toBe(false);
  });

  it("accepts a full vehicleYear payload with integer cents", () => {
    const r = vehicleYearEntity.safeParse(
      env({
        type: "vehicleYear",
        vehicleId: "0190f8a0-5555-7000-8000-000000000005",
        fyStartYear: 2025,
        fuelCents: 220000,
        regoCents: 90000,
        insuranceCents: 60000,
        servicingCents: 30000,
        otherCents: 12000,
        depreciationCents: 100000,
        businessUsePct: 78,
        claimCents: 321360,
      }),
    );
    expect(r.success).toBe(true);
  });

  it("rejects a non-integer cents field on vehicleYear", () => {
    const r = vehicleYearEntity.safeParse(
      env({ type: "vehicleYear", vehicleId: "0190f8a0-5555-7000-8000-000000000005", fyStartYear: 2025, fuelCents: 12.5 }),
    );
    expect(r.success).toBe(false);
  });

  it("entitySchemaFor returns the specialized vehicle schemas", () => {
    expect(entitySchemaFor("vehicle")).toBe(vehicleEntity);
    expect(entitySchemaFor("vehicleYear")).toBe(vehicleYearEntity);
  });
});
```

- [ ] **Step 2: Run the test — expect FAIL.**

```
npm test -- test/schemas.test.ts
```

  Expected: a compile/import error `vehicleEntity is not exported` (TS) or, at runtime, `expected 12 to be 14` and `entitySchemaFor("vehicle")` returning `baseEnvelope` rather than `vehicleEntity`.

- [ ] **Step 3: Edit `src/schemas/entities.ts`.** Add the two schemas immediately AFTER the `loyaltyCardEntity` definition (ends line ~122) and BEFORE the `/** Every syncable type … */` comment (line ~124). The `isoDate`, `cents`, and `pct` helpers are already defined at the top of the file (lines 17–19); reuse them.

```ts
/** vehicle — the user's car for the ATO logbook method (one per profile in v1). */
export const vehicleEntity = baseEnvelope.extend({
  type: z.literal("vehicle"),
  make: z.string().nullable().optional(),
  model: z.string().nullable().optional(),
  engineCc: z.number().int().nonnegative().nullable().optional(),
  registration: z.string().nullable().optional(),
  logbookStartDate: isoDate.nullable().optional(),
  logbookEndDate: isoDate.nullable().optional(),
  businessUsePct: pct.nullable().optional(),
});

/** vehicleYear — one row per (vehicle, FY): annual running-cost totals + cached claim. */
export const vehicleYearEntity = baseEnvelope.extend({
  type: z.literal("vehicleYear"),
  vehicleId: uuid,
  fyStartYear: z.number().int(),
  odometerOpenM: z.number().int().nonnegative().nullable().optional(),
  odometerCloseM: z.number().int().nonnegative().nullable().optional(),
  fuelCents: cents.optional(),
  regoCents: cents.optional(),
  insuranceCents: cents.optional(),
  servicingCents: cents.optional(),
  otherCents: cents.optional(),
  depreciationCents: cents.optional(),
  businessUsePct: pct.nullable().optional(),
  claimCents: cents.nullable().optional(),
});
```

  Then extend `SYNCABLE_TYPES` (lines ~125–138). Replace:

```ts
export const SYNCABLE_TYPES = [
  "transaction",
  "lineItem",
  "profile",
  "category",
  "smartRule",
  "budget",
  "loyaltyCard",
  "quote",
  "quoteLineItem",
  "mileageTrip",
  "wfhLog",
  "taxSettings",
] as const;
```

  with:

```ts
export const SYNCABLE_TYPES = [
  "transaction",
  "lineItem",
  "profile",
  "category",
  "smartRule",
  "budget",
  "loyaltyCard",
  "quote",
  "quoteLineItem",
  "mileageTrip",
  "wfhLog",
  "taxSettings",
  "vehicle",
  "vehicleYear",
] as const;
```

  Then extend `SPECIALIZED` (lines ~142–148). Replace:

```ts
const SPECIALIZED: Partial<Record<SyncableType, z.ZodTypeAny>> = {
  transaction: transactionEntity,
  lineItem: lineItemEntity,
  profile: profileEntity,
  budget: budgetEntity,
  loyaltyCard: loyaltyCardEntity,
};
```

  with:

```ts
const SPECIALIZED: Partial<Record<SyncableType, z.ZodTypeAny>> = {
  transaction: transactionEntity,
  lineItem: lineItemEntity,
  profile: profileEntity,
  budget: budgetEntity,
  loyaltyCard: loyaltyCardEntity,
  vehicle: vehicleEntity,
  vehicleYear: vehicleYearEntity,
};
```

- [ ] **Step 4: Run the tests — expect PASS (incl. the Task 3 leftover).**

```
npm test -- test/schemas.test.ts test/sync-push.test.ts
```

  Expected: all of `test/schemas.test.ts` passes; in `test/sync-push.test.ts`, the "maps all 14 syncable entity types …" assertion now passes (and the earlier-added mapping tests stay green).

- [ ] **Step 5: Commit.**

```
git add src/schemas/entities.ts test/schemas.test.ts
git commit -m "$(cat <<'EOF'
Add vehicle + vehicleYear Zod schemas to SYNCABLE_TYPES (now 14)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: sync-push tests for the new entities + extended mileageTrip

Add push-handler tests for `vehicle`, `vehicleYear`, and the extended `mileageTrip` fields, copying the helpers and style from the existing `test/sync-push.test.ts` (the `seedUserAndProfile` / `authHeader` / `push` helpers and the per-mutation envelope shape from `txnMutation`). Cover applied/rev, idempotency replay, LWW conflict, soft-delete tombstone, and profile_id-required rejection.

**Files:**
- Modify (Test): `test/sync-push.test.ts` — add a new `describe` block after the existing `describe("POST /sync/push", …)` (ends line ~302). Reuses `seedUserAndProfile`, `authHeader`, `push`, `USER_ID`, `PROFILE_ID`, `DEVICE_ID`, `uuidv7` already in the file.

**Steps:**

- [ ] **Step 1: Write the FAILING tests.** Append this `describe` block to `test/sync-push.test.ts`. It defines local `vehicleMutation` / `vehicleYearMutation` builders mirroring `txnMutation` (full envelope payload; the server overwrites `updatedAt`/`rev`/`lastEditedDeviceId`). Its own `beforeEach` resets the touched tables + reseeds, matching the existing block's pattern (lines ~83–90).

```ts
describe("POST /sync/push — logbook entities (vehicle, vehicleYear, extended mileageTrip)", () => {
  beforeEach(async () => {
    await env.DB.exec("DELETE FROM processed_mutations");
    await env.DB.exec("DELETE FROM mileage_trips");
    await env.DB.exec("DELETE FROM vehicle_years");
    await env.DB.exec("DELETE FROM vehicles");
    await env.DB.exec("DELETE FROM profiles");
    await env.DB.exec("DELETE FROM users");
    await seedUserAndProfile();
  });

  function vehicleMutation(overrides: Record<string, unknown> = {}) {
    const entityId = (overrides.entityId as string) ?? uuidv7();
    return {
      mutationId: uuidv7(),
      entityType: "vehicle",
      entityId,
      op: "upsert" as const,
      updatedAt: 1_000,
      payload: {
        id: entityId,
        userId: USER_ID,
        profileId: PROFILE_ID,
        type: "vehicle",
        createdAt: 1_000,
        updatedAt: 1_000,
        deletedAt: null,
        rev: 0,
        lastEditedDeviceId: DEVICE_ID,
        make: "Toyota",
        model: "HiLux",
        engineCc: 2800,
        registration: "ABC123",
        logbookStartDate: "2025-08-12",
        logbookEndDate: "2025-11-04",
        businessUsePct: 78,
      } as Record<string, unknown>,
      ...overrides,
    };
  }

  function vehicleYearMutation(vehicleId: string, overrides: Record<string, unknown> = {}) {
    const entityId = (overrides.entityId as string) ?? uuidv7();
    return {
      mutationId: uuidv7(),
      entityType: "vehicleYear",
      entityId,
      op: "upsert" as const,
      updatedAt: 1_000,
      payload: {
        id: entityId,
        userId: USER_ID,
        profileId: PROFILE_ID,
        type: "vehicleYear",
        createdAt: 1_000,
        updatedAt: 1_000,
        deletedAt: null,
        rev: 0,
        lastEditedDeviceId: DEVICE_ID,
        vehicleId,
        fyStartYear: 2025,
        fuelCents: 220000,
        regoCents: 90000,
        insuranceCents: 60000,
        servicingCents: 30000,
        otherCents: 12000,
        depreciationCents: 100000,
        businessUsePct: 78,
        claimCents: 321360,
      } as Record<string, unknown>,
      ...overrides,
    };
  }

  it("inserts a vehicle: applied, rev 1, columns persisted", async () => {
    const m = vehicleMutation();
    const json = (await (await push({ deviceId: DEVICE_ID, mutations: [m] })).json()) as any;
    expect(json.error).toBeUndefined();
    const r = json.results[0];
    expect(r.status).toBe("applied");
    expect(r.entity.rev).toBe(1);
    expect(r.entity.make).toBe("Toyota");
    expect(r.entity.businessUsePct).toBe(78);
    expect(r.entity.profileId).toBe(PROFILE_ID);

    const row = await env.DB.prepare(
      `SELECT make, model, engine_cc, business_use_pct, logbook_start_date FROM vehicles WHERE id = ?`,
    )
      .bind(m.entityId)
      .first<any>();
    expect(row.make).toBe("Toyota");
    expect(row.engine_cc).toBe(2800);
    expect(row.business_use_pct).toBe(78);
    expect(row.logbook_start_date).toBe("2025-08-12");
  });

  it("inserts a vehicleYear referencing a vehicle: cents + claim persisted", async () => {
    const v = vehicleMutation();
    await push({ deviceId: DEVICE_ID, mutations: [v] });

    const m = vehicleYearMutation(v.entityId);
    const json = (await (await push({ deviceId: DEVICE_ID, mutations: [m] })).json()) as any;
    const r = json.results[0];
    expect(r.status).toBe("applied");
    expect(r.entity.fyStartYear).toBe(2025);
    expect(r.entity.claimCents).toBe(321360);

    const row = await env.DB.prepare(
      `SELECT vehicle_id, fy_start_year, fuel_cents, depreciation_cents, claim_cents FROM vehicle_years WHERE id = ?`,
    )
      .bind(m.entityId)
      .first<any>();
    expect(row.vehicle_id).toBe(v.entityId);
    expect(row.fy_start_year).toBe(2025);
    expect(row.fuel_cents).toBe(220000);
    expect(row.depreciation_cents).toBe(100000);
    expect(row.claim_cents).toBe(321360);
  });

  it("persists the new mileageTrip logbook columns (vehicleId, odometer start/end)", async () => {
    const v = vehicleMutation();
    await push({ deviceId: DEVICE_ID, mutations: [v] });

    const tripId = uuidv7();
    const m = {
      mutationId: uuidv7(),
      entityType: "mileageTrip",
      entityId: tripId,
      op: "upsert" as const,
      updatedAt: 1_000,
      payload: {
        id: tripId,
        userId: USER_ID,
        profileId: PROFILE_ID,
        type: "mileageTrip",
        createdAt: 1_000,
        updatedAt: 1_000,
        deletedAt: null,
        rev: 0,
        lastEditedDeviceId: DEVICE_ID,
        tripDate: "2025-09-01",
        purpose: "Client visit",
        distanceM: 23000,
        isBusiness: true,
        vehicleId: v.entityId,
        odometerStartM: 45000000,
        odometerEndM: 45023000,
      } as Record<string, unknown>,
    };
    const json = (await (await push({ deviceId: DEVICE_ID, mutations: [m] })).json()) as any;
    const r = json.results[0];
    expect(r.status).toBe("applied");
    expect(r.entity.vehicleId).toBe(v.entityId);
    expect(r.entity.odometerStartM).toBe(45000000);
    expect(r.entity.odometerEndM).toBe(45023000);

    const row = await env.DB.prepare(
      `SELECT vehicle_id, odometer_start_m, odometer_end_m, distance_m FROM mileage_trips WHERE id = ?`,
    )
      .bind(tripId)
      .first<any>();
    expect(row.vehicle_id).toBe(v.entityId);
    expect(row.odometer_start_m).toBe(45000000);
    expect(row.odometer_end_m).toBe(45023000);
    expect(row.distance_m).toBe(23000);
  });

  it("replaying the same vehicle mutationId is a duplicate no-op", async () => {
    const m = vehicleMutation();
    const first = (await (await push({ deviceId: DEVICE_ID, mutations: [m] })).json()) as any;
    expect(first.results[0].status).toBe("applied");

    const second = (await (await push({ deviceId: DEVICE_ID, mutations: [m] })).json()) as any;
    expect(second.results[0].status).toBe("duplicate");
    expect(second.results[0].entity.rev).toBe(1);

    const row = await env.DB.prepare(`SELECT rev FROM vehicles WHERE id = ?`)
      .bind(m.entityId)
      .first<any>();
    expect(row.rev).toBe(1);
  });

  it("stale updatedAt loses LWW on a vehicle: conflict, server row echoed", async () => {
    const entityId = uuidv7();
    const win = vehicleMutation({ entityId, updatedAt: 9_999_999_999_999 });
    win.payload.id = entityId;
    const a = (await (await push({ deviceId: DEVICE_ID, mutations: [win] })).json()) as any;
    expect(a.results[0].status).toBe("applied");
    const serverUpdatedAt = a.results[0].entity.updatedAt;

    const stale = vehicleMutation({ entityId, updatedAt: 1 });
    stale.payload.id = entityId;
    stale.payload.make = "Should Not Persist";
    const b = (await (await push({ deviceId: DEVICE_ID, mutations: [stale] })).json()) as any;
    expect(b.results[0].status).toBe("conflict");
    expect(b.results[0].entity.updatedAt).toBe(serverUpdatedAt);
    expect(b.results[0].entity.make).toBe("Toyota");

    const row = await env.DB.prepare(`SELECT make, rev FROM vehicles WHERE id = ?`)
      .bind(entityId)
      .first<any>();
    expect(row.make).toBe("Toyota");
    expect(row.rev).toBe(1);
  });

  it("delete tombstones a vehicleYear, bumps rev, never hard-deletes", async () => {
    const v = vehicleMutation();
    await push({ deviceId: DEVICE_ID, mutations: [v] });
    const m = vehicleYearMutation(v.entityId);
    await push({ deviceId: DEVICE_ID, mutations: [m] });

    const delTs = Date.now() + 60_000;
    const del = {
      mutationId: uuidv7(),
      entityType: "vehicleYear",
      entityId: m.entityId,
      op: "delete" as const,
      updatedAt: delTs,
      payload: {
        id: m.entityId,
        userId: USER_ID,
        profileId: PROFILE_ID,
        type: "vehicleYear",
        createdAt: 1_000,
        updatedAt: delTs,
        deletedAt: delTs,
        rev: 1,
        lastEditedDeviceId: DEVICE_ID,
      } as Record<string, unknown>,
    };
    const res = (await (await push({ deviceId: DEVICE_ID, mutations: [del] })).json()) as any;
    expect(res.results[0].status).toBe("applied");
    expect(res.results[0].entity.deletedAt).not.toBeNull();
    expect(res.results[0].entity.rev).toBe(2);

    const row = await env.DB.prepare(`SELECT deleted_at, rev FROM vehicle_years WHERE id = ?`)
      .bind(m.entityId)
      .first<any>();
    expect(row).not.toBeNull();
    expect(row.deleted_at).not.toBeNull();
    expect(row.rev).toBe(2);
  });

  it("rejects a vehicle upsert that omits profileId (NOT NULL profile_id table)", async () => {
    const m = vehicleMutation();
    delete m.payload.profileId;
    const res = await push({ deviceId: DEVICE_ID, mutations: [m] });
    expect(res.status).toBe(200);
    const json = (await res.json()) as any;
    expect(json.error).toBeUndefined();
    expect(json.results[0].status).toBe("rejected");
    expect(json.results[0].reason).toBe("VALIDATION_FAILED");

    const row = await env.DB.prepare(`SELECT id FROM vehicles WHERE id = ?`)
      .bind(m.entityId)
      .first<any>();
    expect(row).toBeNull();
  });
});
```

- [ ] **Step 2: Run the tests — expect PASS.** The implementation (Tasks 1–4) is already in place, so these tests should pass on the first run. (If you are running this task standalone before Tasks 1–4 land, they would FAIL with `db: unknown/unsafe table 'vehicles'` / null mappings — confirm Tasks 1–4 are committed first.)

```
npm test -- test/sync-push.test.ts
```

  Expected: all logbook-entity tests pass alongside the existing transaction tests.

- [ ] **Step 3: Commit.**

```
git add test/sync-push.test.ts
git commit -m "$(cat <<'EOF'
Add sync-push tests for vehicle, vehicleYear, extended mileageTrip

Covers applied/rev, idempotency replay, LWW conflict, soft-delete tombstone,
and profile_id-required rejection.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: sync-pull tests for the new entities + extended mileageTrip

Add pull-handler tests that seed rows directly into D1 (mirroring the existing `seedTxn` helper in `test/sync-pull.test.ts`) and assert they come back in the merged keyset stream with correct camelCase wire shapes, including a tombstone. Covers the global ordering, profile-scoping (already proven for txns), and that the new columns map to camelCase via `rowToEntity`.

NOTE on keyset pagination (spec §8): the cursor/limit pagination is fully table-agnostic — the pull route loops over `SYNCABLE_TABLES` with one identical bound query per table, so adding `vehicles`/`vehicle_years` to that registry (Task 3) puts them through the SAME keyset machinery already exhaustively covered by the existing pull tests ("cursor advances…", "breaks updatedAt ties by id", "paginates a mixed-table set…"). The "orders the logbook stream globally" test below additionally proves the new tables merge correctly into that global stream. No separate per-table limit/cursor walk is needed.

**Files:**
- Modify (Test): `test/sync-pull.test.ts` — add seed helpers + a new `describe` block after the existing `describe("GET /sync/pull", …)` (ends line ~270). Reuses `tokenFor`, `seedUser`, `seedProfile`, `pull`, `USER_A`, `DEVICE_A`, `uuidv7`.

**Steps:**

- [ ] **Step 1: Write the FAILING tests.** Append this `describe` block to `test/sync-pull.test.ts`. It adds `seedVehicle` / `seedVehicleYear` / `seedMileageTrip` helpers (matching `seedTxn`'s INTEGER/TEXT column style) and its own `beforeEach` cleanup of the new tables. `seedProfile`/`seedUser` are already in the file.

```ts
describe("GET /sync/pull — logbook entities", () => {
  async function seedVehicle(opts: {
    id: string;
    userId: string;
    profileId: string;
    updatedAt: number;
    deletedAt?: number | null;
    businessUsePct?: number;
  }) {
    await env.DB.prepare(
      `INSERT INTO vehicles
         (id, user_id, profile_id, make, model, engine_cc, registration,
          logbook_start_date, logbook_end_date, business_use_pct,
          created_at, updated_at, deleted_at, rev, last_edited_device_id)
       VALUES (?, ?, ?, 'Toyota', 'HiLux', 2800, 'ABC123',
               '2025-08-12', '2025-11-04', ?, ?, ?, ?, 1, ?)`,
    )
      .bind(
        opts.id, opts.userId, opts.profileId, opts.businessUsePct ?? 78,
        opts.updatedAt, opts.updatedAt, opts.deletedAt ?? null, DEVICE_A,
      )
      .run();
  }

  async function seedVehicleYear(opts: {
    id: string;
    userId: string;
    profileId: string;
    vehicleId: string;
    updatedAt: number;
    deletedAt?: number | null;
  }) {
    await env.DB.prepare(
      `INSERT INTO vehicle_years
         (id, user_id, profile_id, vehicle_id, fy_start_year,
          fuel_cents, rego_cents, insurance_cents, servicing_cents, other_cents,
          depreciation_cents, business_use_pct, claim_cents,
          created_at, updated_at, deleted_at, rev, last_edited_device_id)
       VALUES (?, ?, ?, ?, 2025, 220000, 90000, 60000, 30000, 12000,
               100000, 78, 321360, ?, ?, ?, 1, ?)`,
    )
      .bind(
        opts.id, opts.userId, opts.profileId, opts.vehicleId,
        opts.updatedAt, opts.updatedAt, opts.deletedAt ?? null, DEVICE_A,
      )
      .run();
  }

  async function seedMileageTrip(opts: {
    id: string;
    userId: string;
    profileId: string;
    vehicleId: string;
    updatedAt: number;
  }) {
    await env.DB.prepare(
      `INSERT INTO mileage_trips
         (id, user_id, profile_id, trip_date, purpose, distance_m, is_business,
          auto_tracked, vehicle_id, odometer_start_m, odometer_end_m,
          created_at, updated_at, deleted_at, rev, last_edited_device_id)
       VALUES (?, ?, ?, '2025-09-01', 'Client visit', 23000, 1,
               0, ?, 45000000, 45023000, ?, ?, NULL, 1, ?)`,
    )
      .bind(
        opts.id, opts.userId, opts.profileId, opts.vehicleId,
        opts.updatedAt, opts.updatedAt, DEVICE_A,
      )
      .run();
  }

  beforeEach(async () => {
    await env.DB.exec("DELETE FROM mileage_trips");
    await env.DB.exec("DELETE FROM vehicle_years");
    await env.DB.exec("DELETE FROM vehicles");
    await env.DB.exec("DELETE FROM transactions");
    await env.DB.exec("DELETE FROM profiles");
    await seedUser(USER_A);
  });

  it("pulls a vehicle with camelCase wire fields", async () => {
    const token = await tokenFor(USER_A);
    const profileId = uuidv7();
    const vehicleId = uuidv7();
    await seedProfile(profileId, USER_A, 1000);
    await seedVehicle({ id: vehicleId, userId: USER_A, profileId, updatedAt: 2000 });

    const body = (await (await pull(token)).json()) as any;
    const v = body.changes.find((c: any) => c.type === "vehicle");
    expect(v).toBeDefined();
    expect(v.id).toBe(vehicleId);
    expect(v.profileId).toBe(profileId);
    expect(v.make).toBe("Toyota");
    expect(v.engineCc).toBe(2800);
    expect(v.logbookStartDate).toBe("2025-08-12");
    expect(v.businessUsePct).toBe(78);
    expect(v.userId).toBe(USER_A);
  });

  it("pulls a vehicleYear with camelCase cents + claim fields", async () => {
    const token = await tokenFor(USER_A);
    const profileId = uuidv7();
    const vehicleId = uuidv7();
    const vyId = uuidv7();
    await seedProfile(profileId, USER_A, 1000);
    await seedVehicle({ id: vehicleId, userId: USER_A, profileId, updatedAt: 2000 });
    await seedVehicleYear({ id: vyId, userId: USER_A, profileId, vehicleId, updatedAt: 3000 });

    const body = (await (await pull(token)).json()) as any;
    const vy = body.changes.find((c: any) => c.type === "vehicleYear");
    expect(vy).toBeDefined();
    expect(vy.id).toBe(vyId);
    expect(vy.vehicleId).toBe(vehicleId);
    expect(vy.fyStartYear).toBe(2025);
    expect(vy.fuelCents).toBe(220000);
    expect(vy.depreciationCents).toBe(100000);
    expect(vy.claimCents).toBe(321360);
  });

  it("pulls a mileageTrip with the new odometer/vehicle wire fields", async () => {
    const token = await tokenFor(USER_A);
    const profileId = uuidv7();
    const vehicleId = uuidv7();
    await seedProfile(profileId, USER_A, 1000);
    await seedVehicle({ id: vehicleId, userId: USER_A, profileId, updatedAt: 2000 });
    await seedMileageTrip({ id: uuidv7(), userId: USER_A, profileId, vehicleId, updatedAt: 4000 });

    const body = (await (await pull(token)).json()) as any;
    const trip = body.changes.find((c: any) => c.type === "mileageTrip");
    expect(trip).toBeDefined();
    expect(trip.vehicleId).toBe(vehicleId);
    expect(trip.odometerStartM).toBe(45000000);
    expect(trip.odometerEndM).toBe(45023000);
    expect(trip.distanceM).toBe(23000);
  });

  it("includes a vehicle tombstone and orders the logbook stream globally", async () => {
    const token = await tokenFor(USER_A);
    const profileId = uuidv7();
    const vehicleId = uuidv7();
    const vyId = uuidv7();
    await seedProfile(profileId, USER_A, 1000);
    await seedVehicle({ id: vehicleId, userId: USER_A, profileId, updatedAt: 2000 });
    await seedVehicleYear({
      id: vyId,
      userId: USER_A,
      profileId,
      vehicleId,
      updatedAt: 3000,
      deletedAt: 3000, // tombstone MUST be returned
    });

    const body = (await (await pull(token)).json()) as any;
    expect(body.changes).toHaveLength(3); // profile + vehicle + vehicleYear(tombstone)
    const updatedAts = body.changes.map((c: any) => c.updatedAt);
    expect(updatedAts).toEqual([1000, 2000, 3000]);
    const tomb = body.changes.find((c: any) => c.type === "vehicleYear");
    expect(tomb.deletedAt).toBe(3000);
    expect(body.hasMore).toBe(false);
  });

  it("scopes logbook rows to the authed user only", async () => {
    const tokenA = await tokenFor(USER_A);
    await seedUser(USER_B);
    const profA = uuidv7();
    const profB = uuidv7();
    await seedProfile(profA, USER_A, 1000);
    await seedProfile(profB, USER_B, 1000);
    await seedVehicle({ id: uuidv7(), userId: USER_A, profileId: profA, updatedAt: 2000 });
    await seedVehicle({ id: uuidv7(), userId: USER_B, profileId: profB, updatedAt: 2000 });

    const body = (await (await pull(tokenA)).json()) as any;
    const vehicles = body.changes.filter((c: any) => c.type === "vehicle");
    expect(vehicles).toHaveLength(1);
    for (const c of body.changes) expect(c.userId).toBe(USER_A);
  });
});
```

  NOTE: the `beforeEach` in the existing top-level `describe("GET /sync/pull", …)` (lines ~94–101) only seeds `USER_A` + `USER_B`; this nested block's own `beforeEach` re-seeds `USER_A` after clearing tables (and seeds `USER_B` inside the scoping test). Both `beforeEach`es run for tests in the nested block (outer first, then inner), which is intentional and harmless — both use `INSERT OR IGNORE` for users.

- [ ] **Step 2: Run the tests — expect PASS.** Implementation from Tasks 1–4 is in place.

```
npm test -- test/sync-pull.test.ts
```

  Expected: all logbook pull tests pass alongside the existing transaction pull tests.

- [ ] **Step 3: Commit.**

```
git add test/sync-pull.test.ts
git commit -m "$(cat <<'EOF'
Add sync-pull tests for vehicle, vehicleYear, extended mileageTrip

Asserts camelCase wire shapes, tombstone inclusion, global keyset ordering,
and tenant scoping.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: e2e push→pull round-trip over real HTTP

Add a black-box e2e test that boots the real worker (already done in the file's `beforeAll` via `unstable_dev` + applied migrations), authenticates via the magic-link seam, pushes a profile → vehicle → vehicleYear → mileageTrip, then pulls them back and asserts the camelCase wire shapes match the iOS Codable contract. This is the cross-plan wire-shape guarantee.

**Files:**
- Modify (Test): `e2e/snapceipt.e2e.test.ts` — add one `it(...)` inside the existing `describe(...)` (ends line ~310). Reuses the `api(...)` helper and the magic-link auth flow already in the file.

**Steps:**

- [ ] **Step 1: Write the FAILING test.** Append this `it(...)` inside the existing `describe("e2e (real HTTP): …", () => { … })` block (before its closing `});` on line ~310). It self-authenticates (the worker boot in `beforeAll` already migrated the fresh persist dir, which now includes the new tables/columns), then exercises the full logbook round-trip.

```ts
  it("round-trips logbook entities (vehicle, vehicleYear, mileageTrip) push -> pull", async () => {
    const email = `e2e-logbook+${Date.now()}@example.com`;
    const deviceId = crypto.randomUUID();
    const ip = "203.0.113.42";

    // Authenticate via the e2e magic-link seam.
    const reqRes = await api("/auth/magic-link/request", {
      method: "POST",
      headers: { "cf-connecting-ip": ip },
      body: { email },
    });
    expect(reqRes.status).toBe(202);
    const verifyRes = await api("/auth/magic-link/verify", {
      method: "POST",
      headers: { "cf-connecting-ip": ip, "x-device-id": deviceId },
      body: { token: reqRes.json.devToken },
    });
    expect(verifyRes.status).toBe(200);
    const userId: string = verifyRes.json.user.id;
    const authHeaders = { authorization: `Bearer ${verifyRes.json.accessToken}` };

    const profileId = crypto.randomUUID();
    const vehicleId = crypto.randomUUID();
    const vehicleYearId = crypto.randomUUID();
    const tripId = crypto.randomUUID();
    const t = Date.now();

    // Push profile -> vehicle -> vehicleYear -> mileageTrip (FK order: vehicle before its year/trip).
    const pushRes = await api("/sync/push", {
      method: "POST",
      headers: authHeaders,
      body: {
        deviceId,
        mutations: [
          {
            mutationId: crypto.randomUUID(),
            entityType: "profile",
            entityId: profileId,
            op: "upsert",
            updatedAt: t,
            payload: {
              id: profileId, userId, type: "profile", name: "Business",
              profileType: "business", accent1: "#000", accent2: "#111", accent3: "#222",
              createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
            },
          },
          {
            mutationId: crypto.randomUUID(),
            entityType: "vehicle",
            entityId: vehicleId,
            op: "upsert",
            updatedAt: t,
            payload: {
              id: vehicleId, userId, profileId, type: "vehicle",
              make: "Toyota", model: "HiLux", engineCc: 2800, registration: "ABC123",
              logbookStartDate: "2025-08-12", logbookEndDate: "2025-11-04", businessUsePct: 78,
              createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
            },
          },
          {
            mutationId: crypto.randomUUID(),
            entityType: "vehicleYear",
            entityId: vehicleYearId,
            op: "upsert",
            updatedAt: t,
            payload: {
              id: vehicleYearId, userId, profileId, type: "vehicleYear",
              vehicleId, fyStartYear: 2025, fuelCents: 220000, regoCents: 90000,
              insuranceCents: 60000, servicingCents: 30000, otherCents: 12000,
              depreciationCents: 100000, businessUsePct: 78, claimCents: 321360,
              createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
            },
          },
          {
            mutationId: crypto.randomUUID(),
            entityType: "mileageTrip",
            entityId: tripId,
            op: "upsert",
            updatedAt: t,
            payload: {
              id: tripId, userId, profileId, type: "mileageTrip",
              tripDate: "2025-09-01", purpose: "Client visit", distanceM: 23000, isBusiness: true,
              vehicleId, odometerStartM: 45000000, odometerEndM: 45023000,
              createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
            },
          },
        ],
      },
    });
    expect(pushRes.status).toBe(200);
    expect(pushRes.json.results.map((r: any) => r.status)).toEqual([
      "applied", "applied", "applied", "applied",
    ]);

    // Pull everything back and assert the camelCase wire shapes.
    const pullRes = await api("/sync/pull?limit=500", { headers: authHeaders });
    expect(pullRes.status).toBe(200);
    const changes = pullRes.json.changes as any[];

    const pulledVehicle = changes.find((c) => c.id === vehicleId && c.type === "vehicle");
    expect(pulledVehicle).toBeDefined();
    expect(pulledVehicle.make).toBe("Toyota");
    expect(pulledVehicle.engineCc).toBe(2800);
    expect(pulledVehicle.logbookStartDate).toBe("2025-08-12");
    expect(pulledVehicle.businessUsePct).toBe(78);

    const pulledYear = changes.find((c) => c.id === vehicleYearId && c.type === "vehicleYear");
    expect(pulledYear).toBeDefined();
    expect(pulledYear.vehicleId).toBe(vehicleId);
    expect(pulledYear.fyStartYear).toBe(2025);
    expect(pulledYear.fuelCents).toBe(220000);
    expect(pulledYear.claimCents).toBe(321360);

    const pulledTrip = changes.find((c) => c.id === tripId && c.type === "mileageTrip");
    expect(pulledTrip).toBeDefined();
    expect(pulledTrip.vehicleId).toBe(vehicleId);
    expect(pulledTrip.odometerStartM).toBe(45000000);
    expect(pulledTrip.odometerEndM).toBe(45023000);
    expect(pulledTrip.distanceM).toBe(23000);
  });
```

- [ ] **Step 2: Run the e2e test — expect PASS.** The `beforeAll` migrates a fresh isolated persist dir from `migrations/0001_init.sql` (which now contains the new tables/columns after Task 1), so the round-trip works.

```
npm run test:e2e
```

  Expected: 9 e2e tests pass (the original 8 + this new one). If you run this BEFORE Task 1 is committed, the push would return `rejected`/the pull would omit the new fields — confirm Task 1 landed first.

- [ ] **Step 3: Commit.**

```
git add e2e/snapceipt.e2e.test.ts
git commit -m "$(cat <<'EOF'
Add e2e logbook push->pull round-trip asserting wire shapes

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Full-suite verification + local D1 reset note

Confirm both suites are green at their new totals and typecheck is clean. Reset the local dev D1 once (editing the existing migration means the local `.wrangler` DB is stale).

**Files:** none (verification only).

**Steps:**

- [ ] **Step 1: Run the full unit suite.**

```
npm test
```

  Expected: PASS. Baseline is **185** (verified by running `npm test` on the pre-change tree: 22 files, 185 tests). This plan adds tests in `test/schema.test.ts` (4 schema + 1 round-trip = 5), `test/schemas.test.ts` (6), `test/sync-push.test.ts` (3 mapping/required + 7 logbook = 10), `test/sync-pull.test.ts` (5) = **26 new tests**, for **211 passing, 0 failing**. Confirm no pre-existing test regressed (especially the `SYNCABLE_TYPES.length` / "all 14 syncable entity types" assertions now read 14, not 12).

- [ ] **Step 2: Run the e2e suite.**

```
npm run test:e2e
```

  Expected: PASS, 9 tests (baseline 8 + the new logbook round-trip).

- [ ] **Step 3: Typecheck.**

```
npm run typecheck
```

  Expected: no errors (`tsc --noEmit` clean).

- [ ] **Step 4: Reset the local dev D1 (one-time, after editing the existing migration).** The unit/e2e suites rebuild the DB from the migration each run, so they were unaffected — but a developer's local `wrangler dev` D1 in `.wrangler/state` is now stale. Reset it once so local manual testing reflects the new schema:

```
rm -rf .wrangler/state/v3/d1
npm run migrate:local
```

  Expected: `wrangler d1 migrations apply snapceipt --local` reports `0001_init.sql` applied to a fresh local DB. (If `.wrangler/state/v3/d1` does not exist, the `rm -rf` is a harmless no-op and `migrate:local` simply creates the DB.)

- [ ] **Step 5: Final commit (if any uncommitted changes remain).** All code/test changes were committed in Tasks 1–7; this task only verifies and resets local state (no tracked files change). If `git status` is clean, skip. Otherwise:

```
git status
```

  Expected: clean working tree (nothing to commit).

---

## Done criteria
- `npm test` green at the new total (211; was 185 — both verified by running the suite).
- `npm run test:e2e` green at 9 (was 8 — verified).
- `npm run typecheck` clean.
- `migrations/0001_init.sql` contains `vehicles` + `vehicle_years` (with indexes), the three `mileage_trips` odometer/vehicle columns, and `tax_settings.wfh_rate_cents_per_hour DEFAULT 70`.
- `vehicle` + `vehicleYear` are registered in `SYNCABLE_TABLES`, `PROFILE_ID_REQUIRED`, `SCOPED_TABLES`, and `SYNCABLE_TYPES`; `mileageTrip`'s `columns` map carries `vehicleId`/`odometerStartM`/`odometerEndM`.
- No new routes added; `src/routes/sync.ts` untouched.
- The unused `mileage_rate_cents_per_km` (88) column is preserved in `tax_settings` (logbook method does not use it, but it stays).
