# BAS-Ready Export (Backend) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to execute this plan. Each Task is a self-contained TDD unit; dispatch one subagent per Task, in order, and verify the stated test command output before moving on.

**Goal:** Add a server-side BAS pack to the existing `POST /export` pipeline: a pure GST worksheet engine (`basEngine.ts`), a Simpler-BAS + working-papers PDF, a reconciling CSV, a new `format: "bas"` branch that gates on business + GST-registered, renders PDF+CSV to R2, optionally emails an accountant (graceful-degrade), and returns a new `{ pdfUrl, csvUrl, expiresAt, emailed, bas }` contract — plus the 4 new GST-treatment columns threaded through sync.

**Architecture:** Hono Worker on Cloudflare (`src/routes/export.ts` rides the existing `export` rate tier + public `GET /export/dl/:token`). The BAS computation is a **pure function** (`basEngine.ts`) pinned to a hand-derived golden-vector fixture (`test/fixtures/bas-golden.json`) that the iOS plan copies verbatim. New columns are pure `ALTER TABLE … ADD COLUMN` in `migrations/0004_bas.sql`, threaded through `src/schemas/entities.ts` + `src/lib/syncTables.ts`. No new route, no new rate tier, no new `EntityType` (`SYNCABLE_TYPES.length === 15` is untouched). No CHECK-constraint changes (the emailed pack reuses `email_outbox.kind='export_accountant'`).

**Tech Stack:** TypeScript (ESM, `type: module`), Hono 4, Zod 3, pdf-lib, jose, D1 (SQLite), R2; tests via vitest `~2.1.9` with `@cloudflare/vitest-pool-workers` (`npm test`) and a Node-env `unstable_dev` e2e project (`npm run test:e2e`). Do **not** bump the repo wrangler version (`^3.114.17`).

---

## File Structure

| File | Created/Modified | Responsibility |
|---|---|---|
| `migrations/0004_bas.sql` | **Created** | Pure `ALTER TABLE … ADD COLUMN`: `transactions.gst_free`, `transactions.capital`, `transactions.gst_source`, `categories.gst_free_default`. |
| `src/lib/basEngine.ts` | **Created** | Pure §4.3 GST worksheet: income-by-sign, G1–G20, capital G10 $1,000 threshold, `1A/1B = round(aggregate/11)`, 1A forced 0 when `!gstRegistered`. Exports `CAPITAL_THRESHOLD_CENTS` (single source of truth). |
| `test/fixtures/bas-golden.json` | **Created** | Canonical hand-derived golden vectors (frozen) asserted by BOTH the TS engine and (copied verbatim) the Swift engine. |
| `src/lib/basEngine.test.ts` | **Created** | Unit tests: `basEngine` vs the golden fixture (every label, every scenario) + a shape/version guard. |
| `src/lib/pdfBas.ts` | **Created** | BAS summary PDF: section 1 "Lodge these on your BAS" (G1/1A/1B/net 9/PAYG 5A/total), section 2 "Working papers" (G2–G20 + capital split), verbatim §4.5a disclaimer. |
| `src/lib/pdfBas.test.ts` | **Created** | Asserts `%PDF` bytes, both section headers, and the verbatim disclaimer survive into the PDF text. |
| `src/lib/csvBas.ts` | **Created** | BAS backing CSV: existing cols + `gst_free`/`capital`/`gst_source` + semicolon `bas_labels` + a totals footer that foots to the worksheet labels; keeps the formula-injection guard. Imports `CAPITAL_THRESHOLD_CENTS` from `basEngine.ts` (no duplicate const). |
| `src/lib/csvBas.test.ts` | **Created** | Asserts new columns, multi-value `bas_labels`, footer-to-worksheet reconciliation, the formula-injection guard, and the capital $1,000 boundary (G11 at exactly $1,000, G10 at $1,000.01). |
| `src/schemas/export.ts` | **Modified** (1–28) | Add `format: "bas"` + optional `bas: { paygInstalmentCents? }`; `toEmail` stays optional. |
| `src/schemas/entities.ts` | **Modified** (49–81) | Add `gstFree`/`capital`/`gstSource` as `.optional()` to `transactionEntity`. (Category needs NO change — it passthrough-validates.) |
| `src/lib/syncTables.ts` | **Modified** (16–83) | Add the 3 txn columns + `gstFreeDefault` to the `transactions`/`categories` column maps. |
| `src/routes/export.ts` | **Modified** (19–170) | Extend profile SELECT to `type, gst_registered`; add the `bas` branch (gate → query incl. new cols → `basEngine` → PDF+CSV → R2 ×2 → new response + graceful email). |
| `test/export-route.test.ts` | **Modified** (44–170) | Add `bas`-format route tests: gate, R2 ×2, new response shape, `toEmail` email path + graceful degrade. |
| `test/schemas.test.ts` | **Modified** (86–124) | Add a transaction round-trip test for the 4 new columns. |
| `test/sync-push.test.ts` | **Modified** | Add a `transactions` persistence test (`gst_free`/`capital`/`gst_source` survive `/sync/push` into D1), a `categories` persistence test (`gst_free_default`), and a table-map assertion for `category.columns.gstFreeDefault`. |
| `e2e/snapceipt-export.e2e.test.ts` | **Modified** (71–163) | Add a real-HTTP `POST /export {format:"bas"}` → `GET /export/dl/:token` round-trip for BOTH the pdf and csv links, including a `capital=true` and a `gstFree=true` purchase so dropped columns change `1B`. |

---

## Task 1 — Migration `0004_bas.sql` (pure ADD COLUMN)

**Files:**
- Create: `migrations/0004_bas.sql`

- [ ] **Step 1: Write the migration.** Create `migrations/0004_bas.sql` with exactly:
  ```sql
  -- 0004_bas.sql — BAS-ready export GST-treatment columns (spec §4.1).
  -- Pure ADD COLUMN with constant defaults (non-rewriting in SQLite/D1). Prod is
  -- live at 0003; this applies via `wrangler d1 migrations apply --remote` and both
  -- test harnesses apply it in order. No CHECK-constraint changes (the emailed BAS
  -- pack reuses email_outbox.kind='export_accountant').
  ALTER TABLE transactions ADD COLUMN gst_free   INTEGER NOT NULL DEFAULT 0;  -- 0/1
  ALTER TABLE transactions ADD COLUMN capital    INTEGER NOT NULL DEFAULT 0;  -- 0/1, expense-only meaning
  ALTER TABLE transactions ADD COLUMN gst_source TEXT;                        -- 'printed'|'derived'|'manual'|NULL
  ALTER TABLE categories   ADD COLUMN gst_free_default INTEGER NOT NULL DEFAULT 0;
  ```
- [ ] **Step 2: Apply the migration locally to confirm it parses.** Run:
  ```
  npm run migrate:local
  ```
  Expected: PASS — wrangler reports `0004_bas.sql` applied (or "No migrations to apply" if already applied); no SQL error.
- [ ] **Step 3: Confirm the existing suite still builds the schema (migrations are applied by the test setup).** Run:
  ```
  npm test -- test/schemas.test.ts
  ```
  Expected: PASS — the existing schema suite stays green (the new columns don't break envelope parsing yet).
- [ ] **Step 4: Commit.**
  ```
  git add migrations/0004_bas.sql
  git commit -m "feat(bas): migration 0004 adds GST-treatment columns

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 2 — Thread the 4 columns through schema + sync tables

**Files:**
- Modify: `src/schemas/entities.ts` (49–81 — `transactionEntity`)
- Modify: `src/lib/syncTables.ts` (16–83 — `transaction` + `category` column maps)
- Modify: `test/schemas.test.ts` (86–124 — `transactionEntity` describe block)
- Modify: `test/sync-push.test.ts` (table-map asserts + push persistence)

> **Coverage note (review-driven):** The sync-table column-map additions (`gstFree→gst_free`, `capital→capital`, `gstSource→gst_source`, `gstFreeDefault→gst_free_default`) MUST be proven to actually PERSIST to D1, not just to type-check on `transactionEntity`. The Zod tests below only prove in-memory typing; Steps 5–8 add real `/sync/push` integration assertions (and a static table-map assertion for the category side, which passthrough-validates and so cannot be covered by a Zod test). Without these, a typo like `gstFreeDefault→gst_freedefault` would ship silently (spec §7 requires the round-trip).

- [ ] **Step 1: Write a single failing round-trip test for the 4 new columns (typed-field assertion, authored once).** In `test/schemas.test.ts`, inside the `describe("transactionEntity", …)` block, after the existing `it("accepts a full transaction payload with integer cents", …)` (ends line 103), add:
  ```ts
  it("accepts the BAS GST-treatment columns (gstFree/capital/gstSource)", () => {
    const r = transactionEntity.safeParse(
      env({
        type: "transaction",
        amountCents: -22000,
        catKey: "office",
        gstFree: false,
        capital: true,
        gstSource: "derived",
      }),
    );
    expect(r.success).toBe(true);
    if (r.success) {
      // Typed-field assertion: passthrough keeps unknown extras as `unknown`,
      // so these are `undefined` on the inferred type until the fields are added.
      expect(r.data.capital).toBe(true);
      expect(r.data.gstSource).toBe("derived");
    }
  });

  it("accepts gstSource null and the flags omitted (back-compat)", () => {
    const r = transactionEntity.safeParse(
      env({ type: "transaction", amountCents: -3300, catKey: "groceries", gstSource: null }),
    );
    expect(r.success).toBe(true);
  });
  ```
- [ ] **Step 2: Run the test — it must FAIL on the typed-field assertion.** Run:
  ```
  npm test -- test/schemas.test.ts
  ```
  Expected: FAIL — `r.data.capital` / `r.data.gstSource` are `undefined` on the inferred type (passthrough keeps them as unknown extras, not typed fields). (The second test already passes via passthrough; the first is the failing signal.)
- [ ] **Step 3: Add the typed fields to `transactionEntity`.** In `src/schemas/entities.ts`, inside `transactionEntity` (49–81), after the line `gstCents: cents.nullable().optional(),` (line 76) add:
  ```ts
  gstFree: z.boolean().optional(),
  capital: z.boolean().optional(),
  gstSource: z.enum(["printed", "derived", "manual"]).nullable().optional(),
  ```
- [ ] **Step 4: Run the test.**
  ```
  npm test -- test/schemas.test.ts
  ```
  Expected: PASS — both new tests green; `SYNCABLE_TYPES.length === 15` test still green (adding columns does not change the count).
- [ ] **Step 5: Add the columns to the sync table maps.** In `src/lib/syncTables.ts`, in the `transaction.columns` map (20–38), after `gstCents: "gst_cents",` (line 33) add:
  ```ts
  gstFree: "gst_free",
  capital: "capital",
  gstSource: "gst_source",
  ```
  Then in the `category.columns` map (73–82), after `isIncome: "is_income",` (line 80) add:
  ```ts
  gstFreeDefault: "gst_free_default",
  ```
- [ ] **Step 6: Write FAILING persistence + table-map tests in `test/sync-push.test.ts`.** Mirror the existing vehicle/mileageTrip column tests in that file (find the existing `tableForEntityType(...)!.columns.*` assertions and the existing upsert-then-SELECT integration tests, and follow their exact setup/imports). Add:
  ```ts
  // --- static table-map assertions (mirror the vehicle/mileageTrip tests) ---
  it("maps the new transaction BAS columns", () => {
    const cols = tableForEntityType("transaction")!.columns;
    expect(cols.gstFree).toBe("gst_free");
    expect(cols.capital).toBe("capital");
    expect(cols.gstSource).toBe("gst_source");
  });

  it("maps the category gstFreeDefault column (spec §7 — category side has no Zod coverage)", () => {
    expect(tableForEntityType("category")!.columns.gstFreeDefault).toBe("gst_free_default");
  });

  // --- real persistence through /sync/push into D1 ---
  it("persists transaction gst_free/capital/gst_source to D1", async () => {
    const { userId, accessToken } = await seedAuthed(); // use this file's existing auth+device helper
    const deviceId = crypto.randomUUID();
    const profileId = crypto.randomUUID();
    const txnId = crypto.randomUUID();
    const t = nowMs();
    // Seed a profile via push (or this file's existing profile helper), then the txn.
    await pushOne(accessToken, deviceId, {
      mutationId: crypto.randomUUID(), entityType: "profile", entityId: profileId, op: "upsert", updatedAt: t,
      payload: { id: profileId, userId, type: "profile", name: "P", profileType: "business", gstRegistered: true,
        accent1: "#000", accent2: "#111", accent3: "#222", createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId },
    });
    const res = await pushOne(accessToken, deviceId, {
      mutationId: crypto.randomUUID(), entityType: "transaction", entityId: txnId, op: "upsert", updatedAt: t,
      payload: { id: txnId, userId, profileId, type: "transaction", merchant: "M", catKey: "office",
        amountCents: -22000, gstCents: 2000, gstFree: true, capital: true, gstSource: "derived",
        currency: "AUD", txnDate: "2026-05-15", mode: "business",
        createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId },
    });
    expect(res.status).toBe(200);
    const row = await env.DB.prepare(
      `SELECT gst_free, capital, gst_source FROM transactions WHERE id = ?`,
    ).bind(txnId).first<{ gst_free: number; capital: number; gst_source: string }>();
    expect(row?.gst_free).toBe(1);
    expect(row?.capital).toBe(1);
    expect(row?.gst_source).toBe("derived");
  });

  it("persists category gst_free_default to D1", async () => {
    const { userId, accessToken } = await seedAuthed();
    const deviceId = crypto.randomUUID();
    const catId = crypto.randomUUID();
    const t = nowMs();
    const res = await pushOne(accessToken, deviceId, {
      mutationId: crypto.randomUUID(), entityType: "category", entityId: catId, op: "upsert", updatedAt: t,
      payload: { id: catId, userId, type: "category", key: "office", label: "Office", isIncome: false,
        gstFreeDefault: true, createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId },
    });
    expect(res.status).toBe(200);
    const row = await env.DB.prepare(
      `SELECT gst_free_default FROM categories WHERE id = ?`,
    ).bind(catId).first<{ gst_free_default: number }>();
    expect(row?.gst_free_default).toBe(1);
  });
  ```
  > **Adapt to the file's real helpers:** Use whatever push/seed helper `test/sync-push.test.ts` already defines (e.g. an existing `pushMutations`/`SELF.fetch("/sync/push", …)` wrapper — replace the `pushOne(...)` sketch above with it) and the file's existing `tableForEntityType` import, `env`/`SELF` bindings, and category/profile payload shape. Match the existing category upsert payload fields exactly (the `key`/`label`/`isIncome` names above must mirror the file's existing category test). Do NOT introduce a new helper if one exists.
- [ ] **Step 7: Run the tests — table-map + persistence must drive impl.** Run:
  ```
  npm test -- test/sync-push.test.ts
  ```
  Expected: FAIL FIRST if Step 5 is omitted (the table-map asserts return `undefined`; the SELECTs return defaults `0`/`null`). With Step 5 applied: PASS — the maps now persist the new columns into D1 (`gst_free=1`, `capital=1`, `gst_source='derived'`, `gst_free_default=1`).
  > Execution note: author Step 6 BEFORE applying Step 5 to observe the genuine red, then apply Step 5 to go green. (If the subagent applied Step 5 already, temporarily revert one map line to confirm the test fails, then restore.)
- [ ] **Step 8: Run the full sync/schema suites to confirm the maps are consistent.**
  ```
  npm test -- test/schemas.test.ts test/sync-push.test.ts
  ```
  Expected: PASS — schema + push contract suites green (envelope passthrough round-trips the fields; the maps persist them; the static table-map asserts lock the column names).
- [ ] **Step 9: Commit.**
  ```
  git add src/schemas/entities.ts src/lib/syncTables.ts test/schemas.test.ts test/sync-push.test.ts
  git commit -m "feat(bas): thread gstFree/capital/gstSource + gstFreeDefault through sync (+persistence tests)

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 3 — Author the canonical golden-vector fixture (hand-derived, frozen)

**Files:**
- Create: `test/fixtures/bas-golden.json`

> All values are CENTS. Each scenario's `expected` is **hand-computed per spec §4.3**, not engine-generated. The iOS plan copies this file VERBATIM to `SnapceiptTests/Fixtures/bas-golden.json`. The `txns` use `amountCents` sign for income/purchase (`>0` sale, `<0` purchase), `gstFree` (bool), `capital` (bool).

- [ ] **Step 1: Create the fixture.** Write `test/fixtures/bas-golden.json` with exactly:
  ```json
  {
    "version": 1,
    "note": "BAS golden vectors. Cents. Hand-derived per spec section 4.3. DO NOT regenerate.",
    "scenarios": [
      {
        "name": "registered_mixed_capital_income",
        "gstRegistered": true,
        "manual": { "paygInstalmentCents": 0 },
        "txns": [
          { "amountCents": 1100000, "gstFree": false, "capital": false },
          { "amountCents": -110000, "gstFree": false, "capital": false },
          { "amountCents": -220000, "gstFree": false, "capital": true },
          { "amountCents": -33000, "gstFree": true, "capital": false }
        ],
        "expected": {
          "g1": 1100000, "g2": 0, "g3": 0, "g4": 0, "g5": 0, "g6": 1100000, "g7": 0, "g8": 1100000, "g9": 100000,
          "g10": 220000, "g11": 143000, "g12": 363000, "g13": 0, "g14": 33000, "g15": 0, "g16": 33000, "g17": 330000, "g18": 0, "g19": 330000, "g20": 30000,
          "oneA": 100000, "oneB": 30000, "eightA": 100000, "eightB": 30000,
          "netGstCents": 70000, "paygCents": 0, "totalPayableCents": 70000
        }
      },
      {
        "name": "non_registered_forces_1A_zero",
        "gstRegistered": false,
        "manual": { "paygInstalmentCents": 0 },
        "txns": [
          { "amountCents": 1100000, "gstFree": false, "capital": false },
          { "amountCents": -110000, "gstFree": false, "capital": false }
        ],
        "expected": {
          "g1": 1100000, "g2": 0, "g3": 0, "g4": 0, "g5": 0, "g6": 1100000, "g7": 0, "g8": 1100000, "g9": 0,
          "g10": 0, "g11": 110000, "g12": 110000, "g13": 0, "g14": 0, "g15": 0, "g16": 0, "g17": 110000, "g18": 0, "g19": 110000, "g20": 10000,
          "oneA": 0, "oneB": 10000, "eightA": 0, "eightB": 10000,
          "netGstCents": -10000, "paygCents": 0, "totalPayableCents": -10000
        }
      },
      {
        "name": "refund_1B_gt_1A",
        "gstRegistered": true,
        "manual": { "paygInstalmentCents": 0 },
        "txns": [
          { "amountCents": 110000, "gstFree": false, "capital": false },
          { "amountCents": -330000, "gstFree": false, "capital": false }
        ],
        "expected": {
          "g1": 110000, "g2": 0, "g3": 0, "g4": 0, "g5": 0, "g6": 110000, "g7": 0, "g8": 110000, "g9": 10000,
          "g10": 0, "g11": 330000, "g12": 330000, "g13": 0, "g14": 0, "g15": 0, "g16": 0, "g17": 330000, "g18": 0, "g19": 330000, "g20": 30000,
          "oneA": 10000, "oneB": 30000, "eightA": 10000, "eightB": 30000,
          "netGstCents": -20000, "paygCents": 0, "totalPayableCents": -20000
        }
      },
      {
        "name": "empty_period_all_zero",
        "gstRegistered": true,
        "manual": { "paygInstalmentCents": 0 },
        "txns": [],
        "expected": {
          "g1": 0, "g2": 0, "g3": 0, "g4": 0, "g5": 0, "g6": 0, "g7": 0, "g8": 0, "g9": 0,
          "g10": 0, "g11": 0, "g12": 0, "g13": 0, "g14": 0, "g15": 0, "g16": 0, "g17": 0, "g18": 0, "g19": 0, "g20": 0,
          "oneA": 0, "oneB": 0, "eightA": 0, "eightB": 0,
          "netGstCents": 0, "paygCents": 0, "totalPayableCents": 0
        }
      },
      {
        "name": "monthly_window_with_payg",
        "gstRegistered": true,
        "manual": { "paygInstalmentCents": 50000 },
        "txns": [
          { "amountCents": 220000, "gstFree": false, "capital": false },
          { "amountCents": -110000, "gstFree": false, "capital": false }
        ],
        "expected": {
          "g1": 220000, "g2": 0, "g3": 0, "g4": 0, "g5": 0, "g6": 220000, "g7": 0, "g8": 220000, "g9": 20000,
          "g10": 0, "g11": 110000, "g12": 110000, "g13": 0, "g14": 0, "g15": 0, "g16": 0, "g17": 110000, "g18": 0, "g19": 110000, "g20": 10000,
          "oneA": 20000, "oneB": 10000, "eightA": 20000, "eightB": 10000,
          "netGstCents": 10000, "paygCents": 50000, "totalPayableCents": 60000
        }
      }
    ]
  }
  ```
  > **Worked check of scenario 1 (§4.3):** G1 = 1,100,000. G3 (GST-free income) = 0 → G8 = 1,100,000 → **1A = round(1100000/11) = 100,000**. Purchases: capital >$1,000 ⇒ G10 = 220,000; G11 = (110,000 + 220,000 + 33,000) − 220,000 = 143,000; G12 = 363,000. G14 (GST-free purchases) = 33,000 → G16 = 33,000 → G17 = 363,000 − 33,000 = 330,000 = G19 → **1B = round(330000/11) = 30,000**. net 9 = 100,000 − 30,000 = **70,000**; payg = 0; total = **70,000**.
- [ ] **Step 2: Validate the JSON parses.** Run:
  ```
  node -e "JSON.parse(require('fs').readFileSync('test/fixtures/bas-golden.json','utf8')); console.log('ok')"
  ```
  Expected: PASS — prints `ok`.
- [ ] **Step 3: Commit.**
  ```
  git add test/fixtures/bas-golden.json
  git commit -m "test(bas): canonical hand-derived golden-vector fixture (shared)

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 4 — `basEngine.ts` (pure §4.3 worksheet)

**Files:**
- Create: `src/lib/basEngine.test.ts`
- Create: `src/lib/basEngine.ts`

> **Single source of truth (review-driven):** `CAPITAL_THRESHOLD_CENTS` is **exported** from `basEngine.ts` and **imported** by `csvBas.ts` (Task 6) — there is no duplicated const. If the ATO threshold ever changes, the engine's G10 aggregate and the CSV's per-row `bas_labels` move together, so CSV-to-PDF reconciliation cannot silently drift.

- [ ] **Step 1: Write the failing engine test driven by the golden fixture.** Create `src/lib/basEngine.test.ts`:
  ```ts
  import { describe, it, expect } from "vitest";
  import golden from "../../test/fixtures/bas-golden.json";
  import { basEngine, CAPITAL_THRESHOLD_CENTS, type BasTxn } from "./basEngine";

  describe("basEngine — golden vectors (spec §4.3)", () => {
    it("fixture is version 1 (guard against silent drift)", () => {
      expect(golden.version).toBe(1);
    });

    it("exports the ATO capital threshold as $1,000 (shared with csvBas)", () => {
      expect(CAPITAL_THRESHOLD_CENTS).toBe(100000);
    });

    for (const sc of golden.scenarios) {
      it(`matches golden vector: ${sc.name}`, () => {
        const out = basEngine(sc.txns as BasTxn[], {
          gstRegistered: sc.gstRegistered,
          manual: sc.manual,
        });
        expect(out).toEqual(sc.expected);
      });
    }
  });

  describe("basEngine — capital $1,000 threshold (spec §4.3 G10)", () => {
    it("a capital purchase of exactly $1,000 falls to G11, not G10", () => {
      const out = basEngine(
        [{ amountCents: -100000, gstFree: false, capital: true }],
        { gstRegistered: true, manual: { paygInstalmentCents: 0 } },
      );
      expect(out.g10).toBe(0);
      expect(out.g11).toBe(100000);
    });

    it("a capital purchase of $1,000.01 lands in G10", () => {
      const out = basEngine(
        [{ amountCents: -100001, gstFree: false, capital: true }],
        { gstRegistered: true, manual: { paygInstalmentCents: 0 } },
      );
      expect(out.g10).toBe(100001);
      expect(out.g11).toBe(0);
    });
  });
  ```
- [ ] **Step 2: Run the test (no implementation yet).**
  ```
  npm test -- src/lib/basEngine.test.ts
  ```
  Expected: FAIL — `Cannot find module './basEngine'`.
- [ ] **Step 3: Implement `basEngine.ts`.** Create `src/lib/basEngine.ts`:
  ```ts
  /**
   * BAS GST worksheet (spec §4.3). Pure: aggregate the period's non-deleted txns
   * into the full G1–G20 worksheet + 1A/1B/8A/8B/9 + 5A + total, all in CENTS.
   * Income vs purchase is SIGN ONLY (amountCents > 0 = sale, < 0 = purchase).
   * 1A/1B use the worksheet method — one round(aggregate/11) on the aggregate, NOT
   * a sum of per-txn rounds. 1A is forced 0 when !gstRegistered. Mirrored byte-for-
   * byte by the Swift BasEngine; both assert test/fixtures/bas-golden.json.
   */

  /**
   * Capital purchases at or below this magnitude fall to G11 (ATO threshold,
   * <$1M turnover). EXPORTED single source of truth — csvBas.ts imports this so the
   * CSV per-row label split (G10 vs G11) cannot drift from the engine's G10 aggregate.
   */
  export const CAPITAL_THRESHOLD_CENTS = 100000; // $1,000

  /** A single transaction as the engine reads it (sign = income/purchase). */
  export interface BasTxn {
    amountCents: number;
    gstFree: boolean;
    capital: boolean;
  }

  /** Manual BAS parameters; only paygInstalmentCents is user-editable in v1 (rest default 0). */
  export interface BasManual {
    paygInstalmentCents?: number;
    exportsCents?: number;
    inputTaxedSalesCents?: number;
    salesAdjustmentCents?: number;
    inputTaxedPurchaseCents?: number;
    privateUseCents?: number;
    purchaseAdjustmentCents?: number;
  }

  export interface BasOptions {
    gstRegistered: boolean;
    manual?: BasManual;
  }

  /** The full worksheet output (cents). Field set is frozen against the golden fixture. */
  export interface BasResult {
    g1: number; g2: number; g3: number; g4: number; g5: number; g6: number; g7: number; g8: number; g9: number;
    g10: number; g11: number; g12: number; g13: number; g14: number; g15: number; g16: number; g17: number; g18: number; g19: number; g20: number;
    oneA: number; oneB: number; eightA: number; eightB: number;
    netGstCents: number; paygCents: number; totalPayableCents: number;
  }

  /** Round half-away-from-zero on a non-negative aggregate, matching round(x/11). */
  function gstOf(aggregateCents: number): number {
    return Math.round(aggregateCents / 11);
  }

  export function basEngine(txns: BasTxn[], opts: BasOptions): BasResult {
    const m = opts.manual ?? {};
    const payg = m.paygInstalmentCents ?? 0;

    // Sales (amountCents > 0).
    let g1 = 0;
    let g3 = 0; // other GST-free sales
    for (const t of txns) {
      if (t.amountCents > 0) {
        g1 += t.amountCents;
        if (t.gstFree) g3 += t.amountCents;
      }
    }
    const g2 = m.exportsCents ?? 0;
    const g4 = m.inputTaxedSalesCents ?? 0;
    const g5 = g2 + g3 + g4;
    const g6 = g1 - g5;
    const g7 = m.salesAdjustmentCents ?? 0;
    const g8 = g6 + g7;
    const g9 = opts.gstRegistered ? gstOf(g8) : 0; // 1A forced 0 when !registered

    // Purchases (amountCents < 0; magnitudes = -amountCents).
    let g10 = 0; // capital incl GST, |amount| > $1,000
    let expensesTotal = 0;
    let g14 = 0; // GST-free purchases
    for (const t of txns) {
      if (t.amountCents < 0) {
        const mag = -t.amountCents;
        expensesTotal += mag;
        if (t.capital && mag > CAPITAL_THRESHOLD_CENTS) g10 += mag;
        if (t.gstFree) g14 += mag;
      }
    }
    const g11 = expensesTotal - g10; // gstFree purchases stay in G11/G12 (G14 removes them at G16)
    const g12 = g10 + g11;
    const g13 = m.inputTaxedPurchaseCents ?? 0;
    const g15 = m.privateUseCents ?? 0;
    const g16 = g13 + g14 + g15;
    const g17 = g12 - g16;
    const g18 = m.purchaseAdjustmentCents ?? 0;
    const g19 = g17 + g18;
    const g20 = gstOf(g19);

    const oneA = g9;
    const oneB = g20;
    const eightA = oneA;
    const eightB = oneB;
    const netGstCents = eightA - eightB; // positive = pay, negative = refund
    const totalPayableCents = netGstCents + payg; // 5A kept separate, summed for headline

    return {
      g1, g2, g3, g4, g5, g6, g7, g8, g9,
      g10, g11, g12, g13, g14, g15, g16, g17, g18, g19, g20,
      oneA, oneB, eightA, eightB,
      netGstCents, paygCents: payg, totalPayableCents,
    };
  }
  ```
- [ ] **Step 4: Run the test.**
  ```
  npm test -- src/lib/basEngine.test.ts
  ```
  Expected: PASS — all 5 golden scenarios + both threshold cases + the `CAPITAL_THRESHOLD_CENTS` export assertion green.
- [ ] **Step 5: Typecheck (the JSON import needs `resolveJsonModule`; confirm tsc is clean).**
  ```
  npm run typecheck
  ```
  Expected: PASS — no errors. (If tsc reports the JSON import is not allowed, add `"resolveJsonModule": true` to `tsconfig.json` `compilerOptions` and re-run; expect PASS.)
- [ ] **Step 6: Commit.**
  ```
  git add src/lib/basEngine.ts src/lib/basEngine.test.ts
  git commit -m "feat(bas): pure basEngine worksheet locked to golden vectors

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 5 — `pdfBas.ts` (Simpler BAS spine + working papers + disclaimer)

**Files:**
- Create: `src/lib/pdfBas.test.ts`
- Create: `src/lib/pdfBas.ts`

- [ ] **Step 1: Write the failing PDF test.** Create `src/lib/pdfBas.test.ts`:
  ```ts
  import { describe, it, expect } from "vitest";
  import { PDFDocument } from "pdf-lib";
  import { buildBasPdf, BAS_DISCLAIMER } from "./pdfBas";
  import { basEngine } from "./basEngine";

  const bas = basEngine(
    [
      { amountCents: 1100000, gstFree: false, capital: false },
      { amountCents: -110000, gstFree: false, capital: false },
      { amountCents: -220000, gstFree: false, capital: true },
      { amountCents: -33000, gstFree: true, capital: false },
    ],
    { gstRegistered: true, manual: { paygInstalmentCents: 0 } },
  );

  describe("buildBasPdf", () => {
    it("emits a real %PDF byte stream that pdf-lib can re-open", async () => {
      const bytes = await buildBasPdf({
        profileName: "Acme Pty Ltd",
        abn: "12 345 678 901",
        periodLabel: "2026-04-01 to 2026-06-30",
        bas,
      });
      expect(bytes[0]).toBe(0x25); // %
      expect(bytes[1]).toBe(0x50); // P
      const reopened = await PDFDocument.load(bytes);
      expect(reopened.getPageCount()).toBeGreaterThan(0);
    });

    it("exports the verbatim disclaimer string (spec §4.5a)", () => {
      expect(BAS_DISCLAIMER).toContain("Simpler BAS summary (G1, 1A, 1B)");
      expect(BAS_DISCLAIMER).toContain("not tax advice and has not been lodged with the ATO");
      expect(BAS_DISCLAIMER).toContain("Check against your ATO BAS form before lodging.");
    });
  });
  ```
- [ ] **Step 2: Run the test.**
  ```
  npm test -- src/lib/pdfBas.test.ts
  ```
  Expected: FAIL — `Cannot find module './pdfBas'`.
- [ ] **Step 3: Implement `pdfBas.ts`.** Create `src/lib/pdfBas.ts`:
  ```ts
  import { PDFDocument, StandardFonts, rgb, type PDFFont } from "pdf-lib";
  import type { BasResult } from "./basEngine";

  /**
   * BAS summary PDF (spec §4.5a). Clones pdfExport.ts: pdf-lib A4 portrait,
   * standard Helvetica, no embedded images — pure-JS, Workers-safe. Two sections:
   * (1) "Lodge these on your BAS" = the Simpler BAS spine the user files (G1, 1A,
   * 1B → net 9, PAYG 5A, total); (2) "Working papers (not entered on Simpler BAS)"
   * = the full G2–G20 worksheet incl. the capital G10/G11 split for the accountant.
   * Returns the encoded bytes (%PDF...).
   */

  /** The footer disclaimer — verbatim per spec §4.5a. Exported so tests assert it survives. */
  export const BAS_DISCLAIMER =
    "Prepared by Snapceipt to help you lodge your BAS. These figures are a Simpler BAS summary (G1, 1A, 1B), cash basis, and assume each receipt's GST treatment is correctly classified — confirm the items flagged for review. This is not tax advice and has not been lodged with the ATO. Check against your ATO BAS form before lodging.";

  export interface BuildBasPdfInput {
    profileName: string;
    abn: string | null;
    periodLabel: string;
    bas: BasResult;
  }

  const PAGE_W = 595.28; // A4 portrait points
  const PAGE_H = 841.89;
  const MARGIN = 48;
  const LINE = 16;
  const BOTTOM = MARGIN + LINE;

  function dollars(cents: number): string {
    return `$${(cents / 100).toFixed(2)}`;
  }

  export async function buildBasPdf(input: BuildBasPdfInput): Promise<Uint8Array> {
    const doc = await PDFDocument.create();
    const font = await doc.embedFont(StandardFonts.Helvetica);
    const bold = await doc.embedFont(StandardFonts.HelveticaBold);

    let page = doc.addPage([PAGE_W, PAGE_H]);
    let y = PAGE_H - MARGIN;

    const draw = (text: string, f: PDFFont, size: number): void => {
      if (y < BOTTOM) {
        page = doc.addPage([PAGE_W, PAGE_H]);
        y = PAGE_H - MARGIN;
      }
      page.drawText(text, { x: MARGIN, y, size, font: f, color: rgb(0.07, 0.07, 0.07) });
      y -= LINE;
    };

    // Wrap the long disclaimer to the page width (Helvetica ~ size*0.5 avg char width).
    const drawWrapped = (text: string, size: number): void => {
      const maxChars = Math.floor((PAGE_W - 2 * MARGIN) / (size * 0.5));
      const words = text.split(" ");
      let lineBuf = "";
      for (const w of words) {
        if ((lineBuf + " " + w).trim().length > maxChars) {
          draw(lineBuf, font, size);
          lineBuf = w;
        } else {
          lineBuf = (lineBuf + " " + w).trim();
        }
      }
      if (lineBuf) draw(lineBuf, font, size);
    };

    const b = input.bas;

    // Header.
    draw(`Snapceipt BAS — ${input.profileName}`, bold, 18);
    if (input.abn) draw(`ABN: ${input.abn}`, font, 12);
    draw("Registered for GST", font, 12);
    draw(`Period: ${input.periodLabel}`, font, 12);
    draw("Cash basis · Simpler BAS", font, 12);
    y -= LINE / 2;

    // Section 1 — the Simpler BAS spine.
    draw("Lodge these on your BAS", bold, 14);
    draw(`G1  Total sales (incl GST):      ${dollars(b.g1)}`, font, 12);
    draw(`1A  GST on sales:                ${dollars(b.oneA)}`, font, 12);
    draw(`1B  GST on purchases:            ${dollars(b.oneB)}`, font, 12);
    draw(`9   Net GST (1A - 1B):           ${dollars(b.netGstCents)}`, bold, 12);
    draw(`5A  PAYG instalment:             ${dollars(b.paygCents)}`, font, 12);
    draw(`    Total payable/refund:        ${dollars(b.totalPayableCents)}`, bold, 13);
    y -= LINE / 2;

    // Section 2 — working papers (full worksheet, NOT entered on Simpler BAS).
    draw("Working papers (not entered on Simpler BAS)", bold, 14);
    draw(`G2  Exports:                     ${dollars(b.g2)}`, font, 11);
    draw(`G3  Other GST-free sales:        ${dollars(b.g3)}`, font, 11);
    draw(`G4  Input-taxed sales:           ${dollars(b.g4)}`, font, 11);
    draw(`G5  G2+G3+G4:                    ${dollars(b.g5)}`, font, 11);
    draw(`G6  Total sales subject to GST:  ${dollars(b.g6)}`, font, 11);
    draw(`G7  Adjustments:                 ${dollars(b.g7)}`, font, 11);
    draw(`G8  G6+G7:                       ${dollars(b.g8)}`, font, 11);
    draw(`G9  GST on sales (=1A):          ${dollars(b.g9)}`, font, 11);
    draw(`G10 Capital purchases:           ${dollars(b.g10)}`, font, 11);
    draw(`G11 Non-capital purchases:       ${dollars(b.g11)}`, font, 11);
    draw(`G12 G10+G11:                     ${dollars(b.g12)}`, font, 11);
    draw(`G13 Input-taxed purchases:       ${dollars(b.g13)}`, font, 11);
    draw(`G14 GST-free purchases:          ${dollars(b.g14)}`, font, 11);
    draw(`G15 Private-use:                 ${dollars(b.g15)}`, font, 11);
    draw(`G16 G13+G14+G15:                 ${dollars(b.g16)}`, font, 11);
    draw(`G17 Total purchases subj to GST: ${dollars(b.g17)}`, font, 11);
    draw(`G18 Adjustments:                 ${dollars(b.g18)}`, font, 11);
    draw(`G19 G17+G18:                     ${dollars(b.g19)}`, font, 11);
    draw(`G20 GST on purchases (=1B):      ${dollars(b.g20)}`, font, 11);
    y -= LINE / 2;

    // Footer disclaimer (verbatim).
    drawWrapped(BAS_DISCLAIMER, 9);

    return doc.save();
  }
  ```
- [ ] **Step 4: Run the test.**
  ```
  npm test -- src/lib/pdfBas.test.ts
  ```
  Expected: PASS — `%PDF` bytes present, pdf-lib re-opens it, and `BAS_DISCLAIMER` contains the three asserted fragments.
- [ ] **Step 5: Commit.**
  ```
  git add src/lib/pdfBas.ts src/lib/pdfBas.test.ts
  git commit -m "feat(bas): pdfBas — Simpler BAS spine + working papers + disclaimer

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 6 — `csvBas.ts` (new cols + multi-value bas_labels + worksheet footer)

**Files:**
- Create: `src/lib/csvBas.test.ts`
- Create: `src/lib/csvBas.ts`

> **Shared threshold (review-driven):** `csvBas.ts` MUST `import { CAPITAL_THRESHOLD_CENTS } from "./basEngine"` — do NOT redeclare a local copy. The boundary test below ($1,000 → G11, $1,000.01 → G10) mirrors the engine's threshold tests so any drift fails loudly.

- [ ] **Step 1: Write the failing CSV test.** Create `src/lib/csvBas.test.ts`:
  ```ts
  import { describe, it, expect } from "vitest";
  import { buildBasCsv, type BasCsvTxnRow } from "./csvBas";
  import { basEngine } from "./basEngine";

  const rows: BasCsvTxnRow[] = [
    { id: "a", txn_date: "2026-04-10", merchant: "Client Co", cat_key: "income", amount_cents: 1100000, gst_cents: 100000, deductible_pct: null, payment_method: "card", note: null, gst_free: 0, capital: 0, gst_source: "derived" },
    { id: "b", txn_date: "2026-04-12", merchant: "Officeworks", cat_key: "office", amount_cents: -110000, gst_cents: 10000, deductible_pct: 100, payment_method: "card", note: null, gst_free: 0, capital: 0, gst_source: "printed" },
    { id: "c", txn_date: "2026-05-01", merchant: "Dell", cat_key: "software", amount_cents: -220000, gst_cents: 20000, deductible_pct: 100, payment_method: "card", note: null, gst_free: 0, capital: 1, gst_source: "derived" },
    { id: "d", txn_date: "2026-05-03", merchant: "Woolworths", cat_key: "groceries", amount_cents: -33000, gst_cents: null, deductible_pct: 100, payment_method: "card", note: "=cmd|' /c calc'", gst_free: 1, capital: 0, gst_source: null },
  ];

  const bas = basEngine(
    rows.map((r) => ({ amountCents: r.amount_cents, gstFree: r.gst_free === 1, capital: r.capital === 1 })),
    { gstRegistered: true, manual: { paygInstalmentCents: 0 } },
  );

  async function build(rowsArg: BasCsvTxnRow[] = rows, basArg = bas) {
    return buildBasCsv({
      profileName: "Acme Pty Ltd",
      periodLabel: "2026-04-01 to 2026-06-30",
      rows: rowsArg,
      bas: basArg,
      receiptKeyByTxnId: new Map(),
      baseUrl: "https://api.test",
      signDownload: async () => "TOKEN",
    });
  }

  describe("buildBasCsv", () => {
    it("adds gst_free/capital/gst_source/bas_labels columns to the header", async () => {
      const csv = await build();
      const header = csv.split("\n")[1];
      expect(header).toContain("gst_free");
      expect(header).toContain("capital");
      expect(header).toContain("gst_source");
      expect(header).toContain("bas_labels");
    });

    it("labels a taxable sale G1, a non-capital purchase G11, a capital purchase G10, a GST-free purchase G11;G14", async () => {
      const csv = await build();
      const lines = csv.split("\n");
      expect(lines.find((l) => l.startsWith("2026-04-10"))).toContain("G1");
      expect(lines.find((l) => l.startsWith("2026-04-12"))).toContain("G11");
      expect(lines.find((l) => l.startsWith("2026-05-01"))).toContain("G10");
      // GST-free non-capital purchase hits both G11 and G14 (semicolon multi-value).
      expect(lines.find((l) => l.startsWith("2026-05-03"))).toContain("G11;G14");
    });

    it("splits the capital label at exactly $1,000 (G11) vs $1,000.01 (G10) — shared threshold", async () => {
      const boundaryRows: BasCsvTxnRow[] = [
        { id: "x", txn_date: "2026-06-01", merchant: "AtBoundary", cat_key: "tools", amount_cents: -100000, gst_cents: null, deductible_pct: 100, payment_method: "card", note: null, gst_free: 0, capital: 1, gst_source: null },
        { id: "y", txn_date: "2026-06-02", merchant: "OverBoundary", cat_key: "tools", amount_cents: -100001, gst_cents: null, deductible_pct: 100, payment_method: "card", note: null, gst_free: 0, capital: 1, gst_source: null },
      ];
      const boundaryBas = basEngine(
        boundaryRows.map((r) => ({ amountCents: r.amount_cents, gstFree: r.gst_free === 1, capital: r.capital === 1 })),
        { gstRegistered: true, manual: { paygInstalmentCents: 0 } },
      );
      const csv = await build(boundaryRows, boundaryBas);
      const lines = csv.split("\n");
      const atRow = lines.find((l) => l.startsWith("2026-06-01"))!;
      const overRow = lines.find((l) => l.startsWith("2026-06-02"))!;
      // Exactly $1,000 stays in G11 (NOT G10); $1,000.01 lands in G10.
      expect(atRow).toContain("G11");
      expect(atRow).not.toContain("G10");
      expect(overRow).toContain("G10");
    });

    it("foots the totals row to the worksheet labels (reconciles to the PDF)", async () => {
      const csv = await build();
      const footer = csv.split("\n").find((l) => l.startsWith("# TOTALS"));
      expect(footer).toBeDefined();
      expect(footer).toContain("G1=11000.00");
      expect(footer).toContain("1A=1000.00");
      expect(footer).toContain("1B=300.00");
    });

    it("neutralizes a formula-injection note (CWE-1236)", async () => {
      const csv = await build();
      // The malicious note starts with '=' and must be prefixed with a single quote.
      expect(csv).toContain("'=cmd|' /c calc'");
    });
  });
  ```
- [ ] **Step 2: Run the test.**
  ```
  npm test -- src/lib/csvBas.test.ts
  ```
  Expected: FAIL — `Cannot find module './csvBas'`.
- [ ] **Step 3: Implement `csvBas.ts`.** Create `src/lib/csvBas.ts`:
  ```ts
  import { CAPITAL_THRESHOLD_CENTS, type BasResult } from "./basEngine";

  /**
   * BAS backing CSV (spec §4.5b). The period txn list with the existing export
   * columns PLUS gst_free (0/1), capital (0/1), gst_source, and a bas_labels
   * column (semicolon-delimited multi-value: a txn can hit several labels, e.g. a
   * capital GST-free purchase = "G10;G14"). A "# TOTALS" footer row foots to the
   * worksheet labels (G1/1A/1B …) so the CSV reconciles to the PDF — per-txn
   * gst_cents is reference only; 1A/1B are the worksheet round(aggregate/11)
   * figures. Keeps the formula-injection guard + 7-day signed receipt_url links.
   * CAPITAL_THRESHOLD_CENTS is imported from basEngine (single source of truth) so
   * the per-row G10/G11 split cannot drift from the engine's G10 aggregate.
   */

  export interface BasCsvTxnRow {
    id: string;
    txn_date: string;
    merchant: string;
    cat_key: string;
    amount_cents: number;
    gst_cents: number | null;
    deductible_pct: number | null;
    payment_method: string | null;
    note: string | null;
    gst_free: number; // 0/1
    capital: number; // 0/1
    gst_source: string | null;
  }

  export interface BuildBasCsvInput {
    profileName: string;
    periodLabel: string;
    rows: BasCsvTxnRow[];
    bas: BasResult;
    receiptKeyByTxnId: Map<string, string>;
    baseUrl: string;
    signDownload: (r2Key: string) => Promise<string>;
  }

  const COLUMNS =
    "date,merchant,category,amount_incl_gst,gst,deductible_pct,payment_method,note,gst_free,capital,gst_source,bas_labels,receipt_url";

  /** Neutralize CSV / formula injection (CWE-1236) — identical guard to csvExport.ts. */
  function neutralizeFormula(value: string): string {
    return /^[=+\-@\t\r]/.test(value) ? `'${value}` : value;
  }

  function csvField(value: string): string {
    const safe = neutralizeFormula(value);
    if (/[",\r\n]/.test(safe)) {
      return `"${safe.replace(/"/g, '""')}"`;
    }
    return safe;
  }

  function dollars(cents: number): string {
    return (cents / 100).toFixed(2);
  }

  /** The §4.5b multi-value label set for one txn (semicolon-delimited). */
  function basLabels(r: BasCsvTxnRow): string {
    const labels: string[] = [];
    if (r.amount_cents > 0) {
      labels.push("G1");
      if (r.gst_free === 1) labels.push("G3");
    } else if (r.amount_cents < 0) {
      const mag = -r.amount_cents;
      labels.push(r.capital === 1 && mag > CAPITAL_THRESHOLD_CENTS ? "G10" : "G11");
      if (r.gst_free === 1) labels.push("G14");
    }
    return labels.join(";");
  }

  export async function buildBasCsv(input: BuildBasCsvInput): Promise<string> {
    const lines: string[] = [];
    lines.push(`# Snapceipt BAS export — ${csvField(input.profileName)} — ${csvField(input.periodLabel)}`);
    lines.push(COLUMNS);

    for (const r of input.rows) {
      let receiptUrl = "";
      const key = input.receiptKeyByTxnId.get(r.id);
      if (key) {
        const token = await input.signDownload(key);
        receiptUrl = `${input.baseUrl}/export/dl/${token}`;
      }
      const fields = [
        r.txn_date,
        csvField(r.merchant),
        r.cat_key,
        dollars(r.amount_cents),
        r.gst_cents == null ? "" : dollars(r.gst_cents),
        r.deductible_pct == null ? "" : String(r.deductible_pct),
        r.payment_method == null ? "" : csvField(r.payment_method),
        r.note == null ? "" : csvField(r.note),
        String(r.gst_free),
        String(r.capital),
        r.gst_source == null ? "" : r.gst_source,
        basLabels(r),
        receiptUrl,
      ];
      lines.push(fields.join(","));
    }

    // Totals footer — foots to the worksheet labels (NOT to Σ gst_cents). The 1A/1B
    // figures are the worksheet round(aggregate/11) values that match the PDF.
    const b = input.bas;
    lines.push(
      `# TOTALS (worksheet method, round(aggregate/11)): ` +
        `G1=${dollars(b.g1)};G10=${dollars(b.g10)};G11=${dollars(b.g11)};G14=${dollars(b.g14)};` +
        `1A=${dollars(b.oneA)};1B=${dollars(b.oneB)};net9=${dollars(b.netGstCents)};` +
        `5A=${dollars(b.paygCents)};total=${dollars(b.totalPayableCents)}`,
    );

    return lines.join("\n");
  }
  ```
- [ ] **Step 4: Run the test.**
  ```
  npm test -- src/lib/csvBas.test.ts
  ```
  Expected: PASS — header has the new columns, `bas_labels` multi-value is `G11;G14`, the boundary row at exactly $1,000 is `G11` (not `G10`) and $1,000.01 is `G10`, the `# TOTALS` footer carries `G1=11000.00`/`1A=1000.00`/`1B=300.00`, and the injection note is neutralized.
- [ ] **Step 5: Commit.**
  ```
  git add src/lib/csvBas.ts src/lib/csvBas.test.ts
  git commit -m "feat(bas): csvBas — new cols, multi-value bas_labels, worksheet footer (shared threshold)

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 7 — Extend `export.ts` schema for the `bas` format

**Files:**
- Modify: `src/schemas/export.ts` (1–28)

- [ ] **Step 1: Write a failing schema test.** Create `test/export-schema.test.ts`:
  ```ts
  import { describe, it, expect } from "vitest";
  import { exportRequestSchema } from "../src/schemas/export";

  describe("exportRequestSchema — bas format", () => {
    it("accepts format 'bas' with an optional bas.paygInstalmentCents", () => {
      const r = exportRequestSchema.safeParse({
        profileId: "p", format: "bas", from: "2026-04-01", to: "2026-06-30",
        bas: { paygInstalmentCents: 50000 },
      });
      expect(r.success).toBe(true);
    });

    it("accepts format 'bas' with no bas object and no toEmail", () => {
      const r = exportRequestSchema.safeParse({
        profileId: "p", format: "bas", from: "2026-04-01", to: "2026-06-30",
      });
      expect(r.success).toBe(true);
    });

    it("rejects a non-integer paygInstalmentCents", () => {
      const r = exportRequestSchema.safeParse({
        profileId: "p", format: "bas", from: "2026-04-01", to: "2026-06-30",
        bas: { paygInstalmentCents: 1.5 },
      });
      expect(r.success).toBe(false);
    });
  });
  ```
- [ ] **Step 2: Run the test.**
  ```
  npm test -- test/export-schema.test.ts
  ```
  Expected: FAIL — `format` enum rejects `"bas"` (first test) so `r.success` is `false`.
- [ ] **Step 3: Extend the schema.** In `src/schemas/export.ts`, change the `format` enum (line 13) and add the `bas` object (after line 16). Replace:
  ```ts
    format: z.enum(["pdf", "csv", "accountant"]),
    from: isoDate,
    to: isoDate,
    toEmail: z.string().email().optional(),
  ```
  with:
  ```ts
    format: z.enum(["pdf", "csv", "accountant", "bas"]),
    from: isoDate,
    to: isoDate,
    toEmail: z.string().email().optional(),
    // BAS pack manual params (spec §4.4). Only paygInstalmentCents is user-editable
    // in v1; absent => 0 (the engine defaults the rest to 0).
    bas: z
      .object({ paygInstalmentCents: z.number().int().nonnegative().optional() })
      .optional(),
  ```
- [ ] **Step 4: Run the test.**
  ```
  npm test -- test/export-schema.test.ts
  ```
  Expected: PASS — all three cases green.
- [ ] **Step 5: Commit.**
  ```
  git add src/schemas/export.ts test/export-schema.test.ts
  git commit -m "feat(bas): export schema accepts format=bas + bas.paygInstalmentCents

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 8 — `export.ts` route: profile gate + `bas` branch

**Files:**
- Modify: `src/routes/export.ts` (19–170)
- Modify: `test/export-route.test.ts` (44–170)

- [ ] **Step 1: Write the failing route tests.** In `test/export-route.test.ts`, add a `seedRegisteredBusiness` helper after `seedProfileData` (ends line 68) and a new `describe` block after the existing `POST /export` block (closes line 170). Insert after line 68:
  ```ts
  /** Seed a GST-REGISTERED business profile + income + capital + GST-free txns. */
  async function seedBasData(userId: string) {
    const profileId = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,gst_registered,abn,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES (?,?,'Acme Pty Ltd','business',1,'12 345 678 901','#0E7C72','#DCF0ED','#0A5950',?,?)`,
    ).bind(profileId, userId, now, now).run();
    const mk = (amt: number, gstFree: number, capital: number, src: string | null, cat: string) =>
      env.DB.prepare(
        `INSERT INTO transactions (id,user_id,profile_id,merchant,cat_key,amount_cents,gst_cents,gst_free,capital,gst_source,txn_date,created_at,updated_at)
         VALUES (?,?,?,'M',?,?,?,?,?,?,'2026-05-15',?,?)`,
      ).bind(uuidv7(), userId, profileId, cat, amt, Math.round(Math.abs(amt) / 11), gstFree, capital, src, now, now).run();
    await mk(1100000, 0, 0, "derived", "income");
    await mk(-110000, 0, 0, "derived", "office");
    await mk(-220000, 0, 1, "derived", "software");
    await mk(-33000, 1, 0, null, "groceries");
    return { profileId };
  }
  ```
  Then add the new `describe` block after line 170:
  ```ts
  describe("POST /export — bas format", () => {
    it("non-business profile -> 403 FORBIDDEN", async () => {
      const { userId, accessToken } = await seedAuthed();
      const { profileId } = await seedProfileData(userId); // business but NOT gst_registered
      await env.DB.prepare(`UPDATE profiles SET type='personal' WHERE id=?`).bind(profileId).run();
      const res = await SELF.fetch(`${BASE}/export`, {
        method: "POST",
        headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
        body: JSON.stringify({ profileId, format: "bas", from: "2026-04-01", to: "2026-06-30" }),
      });
      expect(res.status).toBe(403);
      expect(((await res.json()) as any).error.code).toBe("FORBIDDEN");
    });

    it("business but not gst_registered -> 403 FORBIDDEN (bas gate, not ownership gate)", async () => {
      const { userId, accessToken } = await seedAuthed();
      const { profileId } = await seedProfileData(userId); // business, gst_registered defaults 0
      const res = await SELF.fetch(`${BASE}/export`, {
        method: "POST",
        headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
        body: JSON.stringify({ profileId, format: "bas", from: "2026-04-01", to: "2026-06-30" }),
      });
      expect(res.status).toBe(403);
      const body = (await res.json()) as any;
      expect(body.error.code).toBe("FORBIDDEN");
      // Confirm the BAS-eligibility gate fired (not the profile-ownership gate),
      // since both arms share the FORBIDDEN code — distinguish by message text.
      expect(body.error.message).toContain("GST-registered business");
    });

    it("registered business -> 200 with pdfUrl, csvUrl, expiresAt, emailed:false, bas echo", async () => {
      const { userId, accessToken } = await seedAuthed();
      const { profileId } = await seedBasData(userId);
      const res = await SELF.fetch(`${BASE}/export`, {
        method: "POST",
        headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
        body: JSON.stringify({ profileId, format: "bas", from: "2026-04-01", to: "2026-06-30" }),
      });
      expect(res.status).toBe(200);
      const body = (await res.json()) as {
        pdfUrl: string; csvUrl: string; expiresAt: number; emailed: boolean;
        bas: { g1: number; oneA: number; oneB: number; netGst: number; payg: number; totalPayable: number };
      };
      expect(body.pdfUrl).toContain("/export/dl/");
      expect(body.csvUrl).toContain("/export/dl/");
      expect(typeof body.expiresAt).toBe("number");
      expect(body.emailed).toBe(false);
      // Worksheet math from the seeded txns (cents). The capital ($2,200 > $1,000)
      // and GST-free ($330) purchases below are only reflected correctly if the
      // gst_free/capital columns persisted — 1B = round(3300/11... )=300 only when
      // the GST-free purchase is removed from G16 (else 1B differs).
      expect(body.bas.g1).toBe(1100000);
      expect(body.bas.oneA).toBe(100000);
      expect(body.bas.oneB).toBe(30000);
      expect(body.bas.netGst).toBe(70000);
      expect(body.bas.totalPayable).toBe(70000);
    });

    it("both returned links download (pdf is %PDF, csv has bas_labels)", async () => {
      const { userId, accessToken } = await seedAuthed();
      const { profileId } = await seedBasData(userId);
      const res = await SELF.fetch(`${BASE}/export`, {
        method: "POST",
        headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
        body: JSON.stringify({ profileId, format: "bas", from: "2026-04-01", to: "2026-06-30" }),
      });
      const { pdfUrl, csvUrl } = (await res.json()) as { pdfUrl: string; csvUrl: string };
      const pdf = await SELF.fetch(pdfUrl);
      expect(pdf.headers.get("content-type")).toContain("application/pdf");
      expect(new Uint8Array(await pdf.arrayBuffer())[0]).toBe(0x25);
      const csv = await SELF.fetch(csvUrl);
      expect(csv.headers.get("content-type")).toContain("text/csv");
      expect(await csv.text()).toContain("bas_labels");
    });

    it("toEmail -> spies sendExportEmail, logs export_accountant outbox, emailed:true, links still returned", async () => {
      const sendSpy = vi.spyOn(emailModule, "sendExportEmail").mockResolvedValue(undefined);
      const { userId, accessToken, email } = await seedAuthed();
      const { profileId } = await seedBasData(userId);
      const res = await SELF.fetch(`${BASE}/export`, {
        method: "POST",
        headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
        body: JSON.stringify({ profileId, format: "bas", from: "2026-04-01", to: "2026-06-30", toEmail: "cpa@example.com" }),
      });
      expect(res.status).toBe(200);
      const body = (await res.json()) as { pdfUrl: string; csvUrl: string; emailed: boolean };
      expect(body.emailed).toBe(true);
      expect(body.pdfUrl).toContain("/export/dl/");
      expect(sendSpy).toHaveBeenCalledTimes(1);
      const arg = sendSpy.mock.calls[0]![1] as emailModule.ExportEmail;
      expect(arg.to).toBe("cpa@example.com");
      expect(arg.replyTo).toBe(email);
      const row = await env.DB.prepare(`SELECT kind, status FROM email_outbox WHERE to_email = ?`)
        .bind("cpa@example.com").first<{ kind: string; status: string }>();
      expect(row?.kind).toBe("export_accountant");
      expect(row?.status).toBe("sent");
    });

    it("toEmail but send throws -> emailed:false, outbox failed, links STILL returned (graceful degrade)", async () => {
      vi.spyOn(emailModule, "sendExportEmail").mockRejectedValue(new Error("EMAIL binding missing"));
      const { userId, accessToken } = await seedAuthed();
      const { profileId } = await seedBasData(userId);
      const res = await SELF.fetch(`${BASE}/export`, {
        method: "POST",
        headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
        body: JSON.stringify({ profileId, format: "bas", from: "2026-04-01", to: "2026-06-30", toEmail: "cpa@example.com" }),
      });
      expect(res.status).toBe(200); // does NOT hard-fail (unlike the accountant branch)
      const body = (await res.json()) as { pdfUrl: string; csvUrl: string; emailed: boolean };
      expect(body.emailed).toBe(false);
      expect(body.pdfUrl).toContain("/export/dl/");
      expect(body.csvUrl).toContain("/export/dl/");
      const row = await env.DB.prepare(`SELECT status FROM email_outbox WHERE to_email = ?`)
        .bind("cpa@example.com").first<{ status: string }>();
      expect(row?.status).toBe("failed");
    });
  });
  ```
- [ ] **Step 2: Run the new tests.**
  ```
  npm test -- test/export-route.test.ts
  ```
  Expected: FAIL — the `bas` format is not handled; the route's `format` schema now accepts it (Task 7) but the route falls through to the `accountant` branch (`body.toEmail!` is undefined for the no-email cases) and the gate/response don't exist.
- [ ] **Step 3: Extend the profile SELECT + add the bas-engine imports.** In `src/routes/export.ts`, add to the import block (after line 11):
  ```ts
  import { basEngine, type BasTxn } from "../lib/basEngine";
  import { buildBasPdf } from "../lib/pdfBas";
  import { buildBasCsv, type BasCsvTxnRow } from "../lib/csvBas";
  ```
  Then change the profile SELECT (64–67) from:
  ```ts
    const profile = await c.env.DB.prepare(
      `SELECT id, name FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
    ).bind(body.profileId, userId).first<{ id: string; name: string }>();
    if (!profile) throw new ApiError("FORBIDDEN", "Profile not found for this user");
  ```
  to:
  ```ts
    const profile = await c.env.DB.prepare(
      `SELECT id, name, type, gst_registered, abn FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
    ).bind(body.profileId, userId).first<{ id: string; name: string; type: string; gst_registered: number; abn: string | null }>();
    if (!profile) throw new ApiError("FORBIDDEN", "Profile not found for this user");
  ```
- [ ] **Step 4: Add the `bas` branch.** In `src/routes/export.ts`, insert the following block immediately before the `// accountant:` comment (line 135), so it runs after the `csv` and `pdf` branches and before the accountant fallthrough:
  ```ts
    if (body.format === "bas") {
      // Defence-in-depth gate (the UI never shows the entry for ineligible profiles).
      // Shares the FORBIDDEN code with the ownership gate above; the message text is
      // what distinguishes a BAS-eligibility rejection (asserted by the route tests).
      if (profile.type !== "business" || profile.gst_registered !== 1) {
        throw new ApiError("FORBIDDEN", "BAS export requires a GST-registered business profile");
      }

      // Re-query the slice including the BAS columns.
      const { results: basTxns } = await c.env.DB.prepare(
        `SELECT id, txn_date, merchant, cat_key, amount_cents, gst_cents, deductible_pct, payment_method, note, gst_free, capital, gst_source
           FROM transactions
          WHERE user_id = ? AND profile_id = ? AND txn_date >= ? AND txn_date <= ? AND deleted_at IS NULL
          ORDER BY txn_date DESC, id ASC`,
      ).bind(userId, body.profileId, body.from, body.to).all<BasCsvTxnRow>();

      const bas = basEngine(
        basTxns.map((r): BasTxn => ({ amountCents: r.amount_cents, gstFree: r.gst_free === 1, capital: r.capital === 1 })),
        // Pass the REAL registration flag (contract-faithful): the engine's own
        // !gstRegistered guard (forces 1A=0) stays the single enforcement point, so
        // if the gate above is ever loosened the engine still won't fabricate 1A.
        // The gate guarantees this is 1 here, so this is equivalently `true` today.
        { gstRegistered: profile.gst_registered === 1, manual: { paygInstalmentCents: body.bas?.paygInstalmentCents ?? 0 } },
      );

      const pdf = await buildBasPdf({ profileName: profile.name, abn: profile.abn, periodLabel, bas });
      const csv = await buildBasCsv({
        profileName: profile.name,
        periodLabel,
        rows: basTxns,
        bas,
        receiptKeyByTxnId,
        baseUrl: origin,
        signDownload,
      });

      const pdfKey = `${userId}/exports/${exportId}.pdf`;
      const csvKey = `${userId}/exports/${exportId}.csv`;
      await c.env.RECEIPTS.put(pdfKey, pdf, { httpMetadata: { contentType: "application/pdf" } });
      await c.env.RECEIPTS.put(csvKey, csv, { httpMetadata: { contentType: "text/csv" } });
      const pdfToken = await signDownloadToken(c.env.JWT_SIGNING_KEY, pdfKey);
      const csvToken = await signDownloadToken(c.env.JWT_SIGNING_KEY, csvKey);
      const pdfUrl = `${origin}/export/dl/${pdfToken}`;
      const csvUrl = `${origin}/export/dl/${csvToken}`;
      const expiresAt = nowMs() + DOWNLOAD_TTL_SECONDS * 1000;
      const basEcho = {
        g1: bas.g1, oneA: bas.oneA, oneB: bas.oneB,
        netGst: bas.netGstCents, payg: bas.paygCents, totalPayable: bas.totalPayableCents,
      };

      // No email requested → return the links.
      if (!body.toEmail) {
        return c.json({ pdfUrl, csvUrl, expiresAt, emailed: false, bas: basEcho });
      }

      // Email requested → reuse the export_accountant outbox kind, with the
      // QUOTE-SEND graceful-degrade (try/catch): an absent/failing env.EMAIL
      // degrades to emailed:false WITHOUT losing the links (unlike the accountant
      // branch, which hard-fails).
      const basOutboxId = uuidv7();
      const basNow = nowMs();
      await c.env.DB.prepare(
        `INSERT INTO email_outbox (id, user_id, to_email, kind, subject, status, export_format, export_r2_key, created_at)
         VALUES (?, ?, ?, 'export_accountant', ?, 'queued', 'pdf', ?, ?)`,
      ).bind(basOutboxId, userId, body.toEmail, `Snapceipt BAS — ${profile.name}`, pdfKey, basNow).run();
      const basUser = await c.env.DB.prepare(`SELECT email FROM users WHERE id = ?`)
        .bind(userId).first<{ email: string | null }>();
      let emailed = false;
      try {
        await sendExportEmail(c.env, {
          to: body.toEmail,
          replyTo: basUser?.email ?? "noreply@snapceipt.cc",
          profileName: profile.name,
          periodLabel,
          csv,
          pdf,
        });
        await c.env.DB.prepare(`UPDATE email_outbox SET status='sent', sent_at=? WHERE id=?`)
          .bind(nowMs(), basOutboxId).run();
        emailed = true;
      } catch (err) {
        await c.env.DB.prepare(`UPDATE email_outbox SET status='failed', error=? WHERE id=?`)
          .bind(String(err instanceof Error ? err.message : err), basOutboxId).run();
        emailed = false;
      }
      return c.json({ pdfUrl, csvUrl, expiresAt, emailed, bas: basEcho });
    }

  ```
- [ ] **Step 5: Run the route tests.**
  ```
  npm test -- test/export-route.test.ts
  ```
  Expected: PASS — all original `POST /export` + `GET /export/dl/:token` tests stay green and the 6 new `bas` tests pass (gates incl. the message-text assertion, R2 ×2, new response, email send + graceful degrade).
- [ ] **Step 6: Typecheck.**
  ```
  npm run typecheck
  ```
  Expected: PASS — no errors (`BasCsvTxnRow` covers the `.all<BasCsvTxnRow>()` shape; `BasTxn` import resolves).
- [ ] **Step 7: Commit.**
  ```
  git add src/routes/export.ts test/export-route.test.ts
  git commit -m "feat(bas): POST /export bas branch — gate, R2 x2, new contract, graceful email

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 9 — E2E round-trip for BAS pdf + csv

**Files:**
- Modify: `e2e/snapceipt-export.e2e.test.ts` (71–163)

> **End-to-end column-persistence proof (review-driven):** This e2e is the ONLY place that proves the `capital`/`gstFree` columns survive `/sync/push` → D1 → `bas` export with values that CHANGE the output. The push below includes a `capital=true` purchase **over $1,000** and a `gstFree=true` purchase, and the assertions on `g10`/`oneB` differ from what they would be if those columns were dropped (i.e. if `capital`/`gstFree` silently defaulted to false). This closes the gap where all-false txns make dropped columns indistinguishable from defaults.

- [ ] **Step 1: Add a failing e2e test.** In `e2e/snapceipt-export.e2e.test.ts`, inside the `describe("e2e (real HTTP): /export csv -> /export/dl round-trip", …)` block, add a new `it` after the first one (the csv round-trip, ends line 138):
  ```ts
    it("registered business -> POST /export bas -> downloads BOTH pdf and csv (capital+gstFree persist)", async () => {
      const email = `e2e-bas+${Date.now()}@example.com`;
      const deviceId = crypto.randomUUID();
      const ip = "203.0.113.79";

      const reqRes = await api("/auth/magic-link/request", {
        method: "POST", headers: { "cf-connecting-ip": ip }, body: { email },
      });
      const verifyRes = await api("/auth/magic-link/verify", {
        method: "POST", headers: { "cf-connecting-ip": ip, "x-device-id": deviceId }, body: { token: reqRes.json.devToken },
      });
      const userId: string = verifyRes.json.user.id;
      const authHeaders = { authorization: `Bearer ${verifyRes.json.accessToken}` };

      const profileId = crypto.randomUUID();
      const incomeId = crypto.randomUUID();
      const expenseId = crypto.randomUUID();
      const capitalId = crypto.randomUUID();
      const gstFreeId = crypto.randomUUID();
      const t = Date.now();
      const pushRes = await api("/sync/push", {
        method: "POST", headers: authHeaders,
        body: {
          deviceId,
          mutations: [
            {
              mutationId: crypto.randomUUID(), entityType: "profile", entityId: profileId,
              op: "upsert", updatedAt: t,
              payload: {
                id: profileId, userId, type: "profile", name: "Acme Pty Ltd",
                profileType: "business", gstRegistered: true,
                accent1: "#000", accent2: "#111", accent3: "#222",
                createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
              },
            },
            {
              mutationId: crypto.randomUUID(), entityType: "transaction", entityId: incomeId,
              op: "upsert", updatedAt: t,
              payload: {
                id: incomeId, userId, profileId, type: "transaction", merchant: "Client Co",
                catKey: "income", amountCents: 1100000, gstCents: 100000, gstFree: false, capital: false, gstSource: "derived",
                currency: "AUD", txnDate: "2026-05-10", mode: "business",
                createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
              },
            },
            {
              mutationId: crypto.randomUUID(), entityType: "transaction", entityId: expenseId,
              op: "upsert", updatedAt: t,
              payload: {
                id: expenseId, userId, profileId, type: "transaction", merchant: "Officeworks",
                catKey: "office", amountCents: -110000, gstCents: 10000, gstFree: false, capital: false, gstSource: "printed",
                currency: "AUD", txnDate: "2026-05-12", mode: "business",
                createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
              },
            },
            {
              // Capital purchase > $1,000 — MUST land in G10 (proves `capital` persists).
              mutationId: crypto.randomUUID(), entityType: "transaction", entityId: capitalId,
              op: "upsert", updatedAt: t,
              payload: {
                id: capitalId, userId, profileId, type: "transaction", merchant: "Dell",
                catKey: "software", amountCents: -220000, gstCents: 20000, gstFree: false, capital: true, gstSource: "derived",
                currency: "AUD", txnDate: "2026-05-14", mode: "business",
                createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
              },
            },
            {
              // GST-free purchase — MUST move into G14 (removed from G16), changing 1B
              // (proves `gstFree` persists). With it: G17/G19 = 330,000 → 1B = 30,000.
              // If `gstFree` were dropped (defaulted false) G19 = 363,000 → 1B = 33,000.
              mutationId: crypto.randomUUID(), entityType: "transaction", entityId: gstFreeId,
              op: "upsert", updatedAt: t,
              payload: {
                id: gstFreeId, userId, profileId, type: "transaction", merchant: "Woolworths",
                catKey: "groceries", amountCents: -33000, gstCents: null, gstFree: true, capital: false, gstSource: null,
                currency: "AUD", txnDate: "2026-05-16", mode: "business",
                createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
              },
            },
          ],
        },
      });
      expect(pushRes.status).toBe(200);

      const exportRes = await api("/export", {
        method: "POST", headers: authHeaders,
        body: { profileId, format: "bas", from: "2026-04-01", to: "2026-06-30" },
      });
      expect(exportRes.status).toBe(200);
      expect(exportRes.json.bas.g1).toBe(1100000);
      expect(exportRes.json.bas.oneA).toBe(100000);
      // 1B = 30,000 ONLY because the GST-free $330 purchase persisted into G14;
      // a dropped gstFree column would yield 1B = 33,000 (G19 = 363,000).
      expect(exportRes.json.bas.oneB).toBe(30000);
      // net = 1A - 1B = 100,000 - 30,000 = 70,000.
      expect(exportRes.json.bas.netGst).toBe(70000);
      expect(exportRes.json.emailed).toBe(false);

      const pdfPath = new URL(exportRes.json.pdfUrl).pathname;
      const pdf = await fetch(`${baseUrl}${pdfPath}`);
      expect(pdf.status).toBe(200);
      expect(pdf.headers.get("content-type")).toContain("application/pdf");
      expect(new Uint8Array(await pdf.arrayBuffer())[0]).toBe(0x25); // %

      const csvPath = new URL(exportRes.json.csvUrl).pathname;
      const csv = await fetch(`${baseUrl}${csvPath}`);
      expect(csv.status).toBe(200);
      expect(csv.headers.get("content-type")).toContain("text/csv");
      const csvText = await csv.text();
      expect(csvText).toContain("bas_labels");
      expect(csvText).toContain("# TOTALS");
      // The capital purchase persisted -> the worksheet footer carries a non-zero G10.
      expect(csvText).toContain("G10=2200.00");
      // The capital row carries the G10 label; the GST-free row carries G11;G14.
      expect(csvText.split("\n").find((l) => l.startsWith("2026-05-14"))).toContain("G10");
      expect(csvText.split("\n").find((l) => l.startsWith("2026-05-16"))).toContain("G11;G14");
    });
  ```
  > **Worked check (proves the columns matter):** sales G1 = 1,100,000 → 1A = 100,000. Purchases: $1,100 + $2,200(capital) + $330(gst-free) = $3,630. capital >$1,000 ⇒ G10 = 220,000; G11 = 363,000 − 220,000 = 143,000; G12 = 363,000. GST-free purchase ⇒ G14 = 33,000 ⇒ G16 = 33,000 ⇒ G17 = G19 = 330,000 ⇒ **1B = 30,000**. If `capital` were dropped, G10 = 0 (footer `G10=0.00` — the `G10=2200.00` assertion fails). If `gstFree` were dropped, G14 = 0 ⇒ G19 = 363,000 ⇒ 1B = round(363000/11) = 33,000 (the `oneB === 30000` assertion fails). Net = 100,000 − 30,000 = **70,000**.
- [ ] **Step 2: Run the e2e suite for this file.**
  ```
  npm run test:e2e -- e2e/snapceipt-export.e2e.test.ts
  ```
  Expected: PASS — the BAS pack is produced over real HTTP, both signed links stream back (pdf `%`, csv contains `bas_labels` + `# TOTALS` + `G10=2200.00`), and `bas.oneB === 30000` (which only holds if `capital` and `gstFree` truly persisted through sync to D1).
- [ ] **Step 3: Commit.**
  ```
  git add e2e/snapceipt-export.e2e.test.ts
  git commit -m "test(bas): e2e POST /export bas -> dl round-trip proving capital+gstFree persist

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 10 — Final verification (typecheck + full suites green) + close-out commit

**Files:**
- (no source changes — verification only; fix-forward if anything is red)

- [ ] **Step 1: Typecheck the whole project.**
  ```
  npm run typecheck
  ```
  Expected: PASS — `tsc --noEmit` reports no errors.
- [ ] **Step 2: Run the full workers-pool suite.**
  ```
  npm test
  ```
  Expected: PASS — all suites green, including the existing baseline plus the new `basEngine`/`pdfBas`/`csvBas`/`export-schema`/`export-route`/`schemas`/`sync-push` tests. Confirm `test/schemas.test.ts`'s `SYNCABLE_TYPES.length === 15` assertion is still green (unchanged).
- [ ] **Step 3: Run the full e2e suite.**
  ```
  npm run test:e2e
  ```
  Expected: PASS — all e2e specs green, including the new BAS round-trip in `snapceipt-export.e2e.test.ts`.
- [ ] **Step 4: Confirm a clean tree and a single ship commit if anything was touched during verification.** If Steps 1–3 required no edits, skip the commit. Otherwise:
  ```
  git add -A
  git commit -m "chore(bas): backend verification — typecheck + npm test + e2e green

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```
