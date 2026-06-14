# BAS-Ready Export — Design Spec

- **Status:** Approved (brainstorm 2026-06-14) → spec adversarially reviewed (4 lenses) + revised → user review → writing-plans.
- **Date:** 2026-06-14
- **Branch:** cut `feature/bas-ready-export` off `main` (the 7-feature roadmap is shipped; this is new post-1.0 scope).
- **Feature:** The strategic **BAS wedge** from the 2026-06-14 office-hours diagnostic (`memory/snapceipt-market-and-wedge.md`): *snap → AU-accurate GST/ABN extraction → one-tap BAS-ready export* for the GST-registered sole trader who files quarterly BAS and won't pay for Xero.
- **Builds on:** the shipped foundation + capture + **F2 Reports/export** (`POST /export` → `csvExport.ts`/`pdfExport.ts`/`exportToken.ts`/`email.ts` + `tax_settings.accountant_email`) + **F7 Settings** (`TaxSettings`/`Profile` carry `gstRegistered`, `abn`, `financialYearStartMonth`, `basPeriod`, `gstBasis`) + the `Period`/`FinancialYear`/`BasSchedule` helpers + `CategorySeeder`.
- **Baselines to keep green** (re-capture exact counts at plan kickoff — last-known on `main` after PR #10): backend `npm test` ≈ 328 / `npm run test:e2e` ≈ 34; iOS full `xcodebuild` ≈ 408 pass / 7 skip. Add to these; never regress.

---

## 0. Review provenance (what changed from the brainstorm)

This spec was adversarially reviewed against the ATO rules and the real codebase before plan-writing. **Material correction:** the brainstorm picked a "full worksheet" user-facing surface, but a sub-$10M GST-registered sole trader lodges **Simpler BAS** (G1, 1A, 1B only — the ATO rejects a statement that reports G2/G3/G10/G11). So the **self-lodge surface defaults to the Simpler BAS spine**; the full worksheet is computed internally, surfaced behind a "full reporting method" toggle, and included in the accountant pack working papers. The engine math (1A/1B = `round(aggregate/11)`) is unchanged and ATO-correct. Other review-driven changes are noted inline (§4.1 `gst_source`, §4.2 health→taxable, §4.4 explicit response DTO + reused outbox kind, §4.6 ABN checksum + Mark-as-lodged + editable GST, cut advanced adjustments to PAYG-only).

## 1. Goal

Turn Snapceipt's existing GST tracking + export pipeline into a **trustworthy, AU-accurate BAS deliverable** for a GST-registered Business profile, in two shapes:

1. **An on-screen Simpler BAS summary** ("Your BAS this quarter") the sole trader reads straight into the myGov / ATO BAS form when self-lodging — **G1, 1A, 1B**, the net GST and due date front-and-centre, with a trust/reconciliation step that surfaces what's *estimated* (and lets them fix it) **before** they lodge, and a **Mark-as-lodged** lock so a filed quarter doesn't silently re-drift.
2. **A one-tap BAS pack** (summary PDF + backing CSV, optionally emailed to an accountant) reusing the F2 export rails, including the fuller worksheet breakdown as working papers.

The credibility crux — the actual wedge — is **GST accuracy**: today every expense gets `gst = total ÷ 11` whenever the receipt doesn't print a GST line, silently over-claiming credits on GST-free items (basic groceries) and on mixed-supply receipts. v1 fixes this with per-transaction GST treatment defaulted from category, **GST-amount provenance** (`gst_source`) so estimates are visible, and an **editable per-txn GST amount** so a real figure overrides the guess. AUD-only. Cash basis only.

## 2. Decisions locked (brainstorm 2026-06-14, revised by review)

1. **Deliverable = BOTH** an on-screen self-lodge summary AND a downloadable/emailable BAS pack.
2. **GST accuracy = category-default treatment + per-txn toggle + editable GST amount + provenance.** Categories carry a default GST treatment (taxable vs GST-free). Extraction uses the **printed GST line** (`gst_source='printed'`) when present; otherwise `÷11` derivation runs **only for taxable categories** (`gst_source='derived'`); GST-free → `gst_cents=0` (`gst_source=NULL`). The user can toggle GST-free or type an exact GST amount (`gst_source='manual'`) in the editor/review. Income defaults taxable (1A) for GST-registered profiles, with a GST-free override.
3. **Labels = Simpler BAS spine on screen; full worksheet computed + in the pack.** The self-lodge surface shows **G1, 1A, 1B → net 9 + PAYG 5A + total**. The engine also computes the full GST calculation worksheet (G1–G20, capital G10/G11 split) used for (a) the accountant pack working papers and (b) an optional, clearly-labelled "full reporting method (≥$10M)" detail view. PAYG instalment (T7→5A) is a manual field. **Advanced adjustments/exports/input-taxed (G2/G4/G7/G13/G15/G18) are engine parameters defaulting to 0 — NOT user-editable in v1** (rare for a no-employees sole trader; the prior two-field G7/G18 model was ATO-incorrect).
4. **Placement = Reports-tab BAS card → `BasView` detail**, shown only for `type == "business"` && `gstRegistered`.
5. **Architecture = on-device screen + server pack, one shared formula.** On-device `BasEngine` (offline, instant) for the screen; the pack reuses `POST /export` with a new `bas` format running the identical `basEngine.ts` over D1. One formula, golden-vector-locked (the `QuoteTotals`/`BudgetSpend` house pattern).

**Reuse (already shipped):** `POST /export` + the `export` rate tier + public `GET /export/dl/:token`; `src/lib/csvExport.ts`/`pdfExport.ts`/`exportToken.ts`/`email.ts` (`sendExportEmail`, `email_outbox`, `env.EMAIL`); `tax_settings.accountant_email` + the F2 `ExportSheet` + `ActivityView`; `Period` (Month/Quarter/FY, AU quarters) + `FinancialYear` + `BasSchedule.nextDue`; `TransactionQuery`; the Reports tab (`ReportsView`) + `Card`/`Palette`/`AccentPalette`/`Radius`/`fmt`/`IconCircle`/`Icon`/`EmptyArt`; the `Router` full-screen-overlay pattern; the 4-conformer `APIClient`; the `@Observable @MainActor` VM pattern; `CategorySeeder`; the screenshot-tour harness.

## 3. Architecture

**Thin client compute + thin export backend, one shared engine.** The summary is pure on-device SwiftData aggregation (no network — Snapceipt is local-first; the screen must work offline). The only networked part is the pack: an extended `POST /export` that runs the identical `basEngine` over D1 and renders PDF+CSV to R2 (+ optional accountant email). The BAS computation is a **pure function defined once**, implemented twice (Swift `BasEngine` + TS `basEngine.ts`), pinned identical by a **shared golden-vector JSON fixture** asserted on both sides.

**Two implementation plans** under §4: **iOS** (`BasEngine` + GST-treatment fields/toggles + ABN checksum + `BasView` + Reports card + lodged-lock + `ExportSheet` extension) and **backend** (`0004` migration + `basEngine.ts` + `/export` `bas` format + BAS PDF/CSV builders). **§4 is the authoritative cross-plan contract.**

## 4. Authoritative cross-plan contract

### 4.1 Schema touch — migration `0004_bas.sql` (NEW migration; pure ADD COLUMN; do NOT edit `0001`)

> **Why a new migration:** prod is **live** (`api.snapceipt.cc`; D1 migrated through `0003`). Editing `0001` never runs against prod. `0004` uses only `ALTER TABLE … ADD COLUMN` with constant defaults (non-rewriting in SQLite); `wrangler d1 migrations apply --remote` applies it to prod and both test harnesses apply it in order. **No CHECK-constraint changes** (the emailed BAS pack reuses the existing `export_accountant` outbox kind — §4.4 — so `email_outbox.kind`'s `CHECK (kind IN ('magic_link','export_accountant','quote_send'))` at `0001_init.sql:440` is untouched).

`migrations/0004_bas.sql`:
```sql
ALTER TABLE transactions ADD COLUMN gst_free   INTEGER NOT NULL DEFAULT 0;  -- 0/1
ALTER TABLE transactions ADD COLUMN capital    INTEGER NOT NULL DEFAULT 0;  -- 0/1, expense-only meaning
ALTER TABLE transactions ADD COLUMN gst_source TEXT;                        -- 'printed'|'derived'|'manual'|NULL
ALTER TABLE categories   ADD COLUMN gst_free_default INTEGER NOT NULL DEFAULT 0;
```

| D1 column | iOS / JSON | Type | Notes |
|---|---|---|---|
| `transactions.gst_free` | `gstFree` | Bool (0/1) | per-txn GST-free classifier; drives G3 (income) / G14 (purchases); `true ⇒ gst_cents == 0` (authority rule) |
| `transactions.capital` | `capital` | Bool (0/1) | per-expense capital-asset flag; drives the full-worksheet G10 vs G11 split (NOT on the Simpler BAS spine); ignored for income |
| `transactions.gst_source` | `gstSource` | String? | GST-amount provenance: `printed` (receipt line), `derived` (÷11 fallback), `manual` (user-typed), `NULL` (GST-free/none). Powers "estimated GST" reconciliation |
| `categories.gst_free_default` | `gstFreeDefault` | Bool (0/1) | seeded default `gstFree` for new txns in that category |

**No new `EntityType`** — columns on the *existing* `transactions`/`categories` synced entities. The `SYNCABLE_TYPES.length === 15` guard (`test/schemas.test.ts:172`) is **unaffected** (do not touch it). Concrete touch-points (verified):
- **Backend:** add `gstFree`/`capital`/`gstSource` as `.optional()` to `transactionEntity` in `src/schemas/entities.ts:49-81`. **Category needs NO `entities.ts` change** — `category` is not in the `SPECIALIZED` map (`entities.ts:184-192`); it validates via `baseEnvelope.passthrough()`. Add all four columns to the `transactions` + `categories` `columns` maps in `src/lib/syncTables.ts`. Extend the export route's profile SELECT (`src/routes/export.ts:64-67`, currently `id, name`) to also fetch `type, gst_registered` for the server-side gate.
- **iOS:** add the fields to the `Transaction`/`Category` `@Model`s + inits, and wire reads/writes in `TransactionSyncMapper` (`Snapceipt/Sync/SyncEntityRegistry.swift:178-231`) + `CategorySyncMapper` (`…:324-359`) using the existing `env.bool(...)`/`boolv(...)` helpers (as used for `isAi`/`isIncome`). SwiftData lightweight-migrates the additive defaulted properties.

**Back-compat:** old rows/clients omit the fields → treated as column defaults (`gst_free=0`, `capital=0`, `gst_source=NULL`, category default per seed). Round-trips both ways.

### 4.2 Category GST-free seeding + one-time backfill (iOS-only — no backend seeder exists)
Categories are seeded **only on iOS** (`Snapceipt/Features/Settings/CategorySeeder.swift`) and synced up; the server is pure sync persistence (no category seed in `src/`). Seed `gstFreeDefault`: **`groceries` → true (GST-free)**; **all others (`meals`, `fuel`, `software`, `office`, `home`, `travel`, `health`, `income`) → false (taxable)**.
- **`health` is TAXABLE** (review fix): most business-recorded "health" spend (OTC pharmacy, supplements, consumer health goods) is taxable; only specific medical *services*/listed aids are GST-free — those are handled per-txn via the GST-free toggle + reconciliation, not a blanket category default.
- **`meals` is TAXABLE** as the default (restaurant/cafe/takeaway), but meals are routed into reconciliation (private-use / entertainment may be non-creditable) — the engine does not assume full creditability is "unconditionally accurate."
- `income` taxable only *materialises* as 1A when `gstRegistered`; else 1A = 0.

`CategorySeeder.ensure()` is **insert-only** (`CategorySeeder.swift:50` skips existing keys), so a NEW one-time backfill path (`backfillGstDefaults()`) is required: for existing installs, set `gstFreeDefault` on the known category rows to match the seed table (only `groceries → true`), enqueue their sync upserts, and mark done (idempotent, runs once). New txns inherit `gstFree` from their category's `gstFreeDefault` at create; the user can override per-txn.

### 4.3 The BAS engine (`BasEngine` / `basEngine.ts`) — shared, golden-vector-locked

Pure function. **Inputs:** `period` window `[start, end)` (UTC ISO `YYYY-MM-DD`), `gstRegistered: Bool`, the profile's in-window non-deleted transactions, and `manual: { paygInstalmentCents, exportsCents, inputTaxedSalesCents, salesAdjustmentCents, inputTaxedPurchaseCents, privateUseCents, purchaseAdjustmentCents }` (all default 0; **only `paygInstalmentCents` is user-editable in v1**). **Output:** the full worksheet (all G-labels + 1A/1B/8A/8B/9 + 5A + total) in **cents**; the screen/PDF round to whole dollars (ATO convention). Whole-dollar **worksheet method**.

**Income vs purchase identification = SIGN ONLY** (the existing `TransactionQuery.swift:47` convention; `isIncome` is a *category* seed prop, not a Transaction field — do not use it here): `amountCents > 0` = sale; `amountCents < 0` = purchase.

**Sales** (`amountCents > 0`):
- `G1` total sales incl GST = Σ income `amountCents`
- `G2` exports = `manual.exportsCents` (0 in v1) · `G3` other GST-free sales = Σ income where `gstFree` · `G4` input-taxed = `manual.inputTaxedSalesCents` (0)
- `G5` = G2+G3+G4 · `G6` = G1−G5 · `G7` = `manual.salesAdjustmentCents` (0) · `G8` = G6+G7
- **`G9` = 1A = `round(G8 / 11)`** *(forced 0 when `!gstRegistered`)*

**Purchases** (`amountCents < 0`; magnitudes `−amountCents`):
- `G10` capital incl GST = Σ |expense| where `capital` **and** `|amount| > $1,000` (ATO threshold for turnover <$1M; capital ≤ $1,000 falls to G11) · `G11` non-capital incl GST = everything else (Σ all expense − G10)
- `G12` = G10+G11 · `G13` = `manual.inputTaxedPurchaseCents` (0) · `G14` GST-free purchases = Σ |expense| where `gstFree` · `G15` = `manual.privateUseCents` (0)
- `G16` = G13+G14+G15 · `G17` = G12−G16 · `G18` = `manual.purchaseAdjustmentCents` (0) · `G19` = G17+G18
- **`G20` = 1B = `round(G19 / 11)`**

> **Note (G14 double-role):** a GST-free purchase is counted in G11/G12 at full value **AND** in G14; G14 then removes it at G16/G17 so it earns **no** 1B credit. Implementers must NOT exclude `gstFree` purchases from G11.

**Summary:** `8A` = 1A · `8B` = 1B · **`netGstCents` (label 9) = 8A − 8B** (positive = pay; negative = refund) · `paygCents` = `manual.paygInstalmentCents` (label **5A**) · **`totalPayableCents` = netGst + payg** (kept as two visibly-separate figures, summed for the headline — 5A is NOT folded into label 9).

**Authority rule (invariant):** a txn is either *taxable with a GST amount* or *GST-free with `gst_cents == 0`*. `gstFree = true` sets `gst_cents = 0`, `gst_source = NULL`; flipping back to taxable re-derives `gst_cents = round(total/11)`, `gst_source = 'derived'` (or keeps a `'manual'` typed value). The engine derives 1A/1B from **totals + flags** (worksheet method, one `÷11` on the aggregate → no sum-of-rounds drift), **not** from stored `gst_cents`.

> **Two rounding domains (intentional):** `gst_cents` is a per-txn accounts-method value (`round(total/11)` per txn, or a printed/typed amount) used **only** for the Reports GST pill and reconciliation. It does **not** feed 1A/1B. The BAS labels use `round(aggregate/11)`. The CSV (§4.5b) foots to the worksheet labels, not to Σ`gst_cents`.

**Golden vectors:** `test/fixtures/bas-golden.json` — scenarios covering: GST-registered mixed taxable/GST-free + capital >$1k + income; non-registered → 1A=0; refund; empty period; **a monthly window**; PAYG set. Both `BasEngineTests` (Swift) and `basEngine` (vitest) assert the **same** fixture; a tiny shape/hash guard on each side prevents silent drift.

### 4.4 Backend `POST /export` — new `bas` format (explicit NEW response contract)
Extend `src/routes/export.ts` + `src/schemas/export.ts`. **No new route/rate tier** (rides `export` + `GET /export/dl/:token`).
- **Request** adds `format: "bas"` + optional `bas: { paygInstalmentCents? }` (other manual params accepted but default 0 in v1) + `from`/`to` (the period window) + optional `toEmail`. Server gates: profile ownership **and** `type == "business"` **and** `gst_registered` (else **`FORBIDDEN`** — matching the existing ownership error; the UI never shows the entry for ineligible profiles, so this is defence-in-depth), plus `from ≤ to`.
- **Behaviour:** query the txn slice (now also selecting `gst_free`, `capital`, `gst_source`) → `basEngine(txns, { gstRegistered, manual })` → render BAS PDF (§4.5a) + BAS CSV (§4.5b) → store **both** to R2 `<userId>/exports/<exportId>.{pdf,csv}` → if `toEmail`, insert `email_outbox (kind='export_accountant', export_format='pdf', …)` + `sendExportEmail` (Reply-To = trader) wrapped in try/catch so an absent/failing `env.EMAIL` degrades to `emailed:false` **without losing the links** (the **quote-send** graceful-degrade pattern — the current F2 accountant branch hard-fails, so the `bas` branch must use the quote pattern, not "like F2").
- **Response (NEW shape, defined for both sides):**
  ```
  200 { pdfUrl: string, csvUrl: string, expiresAt: number, emailed: boolean, bas: BasEcho }
  ```
  where `BasEcho` is the cents summary `{ g1, oneA, oneB, netGst, payg, totalPayable }` (lets the caller reconcile screen-vs-pack). Both links are signed 7-day `GET /export/dl/:token` URLs. This is a **genuinely new contract** (the existing `pdf`/`csv` return a single `{url,expiresAt}`; `accountant` returns `{status,outboxId}` with no links) — it is NOT a mirror. iOS additions: a `BasExportResponse` DTO + a new `ExportResult.basPack(pdfUrl,csvUrl,expiresAt,emailed,bas)` case (`Snapceipt/Sync/DTOs.swift`), wired in all 4 `APIClient` conformers (`APIClient.swift:163-175` + Stub/Preview/Mock); the export-route tests (`test/export-route.test.ts:80,94,149-151`) get a `bas`-format case.

### 4.5 BAS pack documents
**(a) BAS summary PDF** — `src/lib/pdfBas.ts` (clone `pdfExport.ts`; pdf-lib A4, Helvetica, no images). Header: profile `name`, `ABN: <abn>` (if set; printed only — see §4.6 for client-side checksum), "Registered for GST", period label + **"Cash basis · Simpler BAS"**. Body — **two sections**: (1) **"Lodge these on your BAS"** = G1, 1A, 1B → net 9, PAYG 5A, total (the Simpler BAS spine the user actually files); (2) **"Working papers (not entered on Simpler BAS)"** = the full G2–G20 breakdown incl. the capital G10/G11 split, for the accountant. Footer disclaimer (verbatim): **"Prepared by Snapceipt to help you lodge your BAS. These figures are a Simpler BAS summary (G1, 1A, 1B), cash basis, and assume each receipt's GST treatment is correctly classified — confirm the items flagged for review. This is not tax advice and has not been lodged with the ATO. Check against your ATO BAS form before lodging."**
**(b) BAS backing CSV** — `src/lib/csvBas.ts` (or extend `csvExport.ts`): the period txn list with existing columns **plus** `gst_free` (0/1), `capital` (0/1), `gst_source`, and a **`bas_labels`** column that is a **semicolon-delimited multi-value** (a txn can hit several: e.g. a capital GST-free purchase = `G10;G14`; non-capital taxable = `G11`; taxable sale = `G1`). A **totals footer row** foots to the worksheet labels (G1/1A/1B etc.) so the CSV reconciles to the PDF (per-txn GST is shown for reference but the 1A/1B totals are the worksheet `÷11` figures, with a header note explaining the method). Keep the existing formula-injection guard + 7-day signed `receipt_url` links.

### 4.6 iOS — computations, trust layer, persistence, screen
- **`BasEngine`** (`Snapceipt/Features/Reports/Bas/BasEngine.swift`): the §4.3 pure function over `[Transaction]` → a `BasResult` (all labels, cents). Golden-fixture-tested.
- **Period selection:** granularity from `TaxSettingsViewModel.basPeriod` (quarterly/monthly). The stepper navigates prior periods by feeding a **shifted injected `now`** into `Period.window(now:startMonth:)` (Period has no prior-period API — it computes the current window of the injected `now`; `Period.quarterIndex` gives Q1–Q4). Default = the current in-progress period (with a "period in progress" hint). Due date from `BasSchedule.nextDue`.
- **Trust layer (reconciliation)** — pure helpers over the period's txns:
  - *Estimated GST:* taxable expense txns with `gstSource == 'derived'` → "N purchases used estimated GST — confirm or enter the real amount". (Now detectable via `gst_source`; previously impossible.)
  - *Income to confirm:* income txns not yet user-confirmed taxable/GST-free → "M income entries — confirm taxable vs GST-free". **The confident headline is gated on income being reviewed** (until then the headline reads "Estimated").
  - *Mixed-receipt discrepancy:* taxable expense where a **printed** GST line disagrees with `round(total/11)` by `> max(2 cents, 1% of total)` → flag to split/fix. (Derived-GST receipts surface via the Estimated-GST list instead.)
  - Each opens a quick-fix list: toggle `gstFree`/`capital`, or **type an exact GST amount** (sets `gstSource='manual'`), enqueue sync. Clean → green "Looks complete".
- **Editable per-txn GST amount** (review fix for mixed-supply over-claim): the transaction editor + capture review gain a GST-amount field (defaults to the derived/printed value) so a real receipt figure overrides blind `÷11`; editing sets `gstSource='manual'`. Plus the `gstFree` (+ `capital` for expenses) toggles.
- **ABN checksum** (`Snapceipt/Features/Settings/ABNValidator.swift`, pure, offline): the ATO **modulus-89** algorithm (subtract 1 from the first digit; weight `[10,1,3,5,7,9,11,13,15,17,19]`; sum; valid iff `sum % 89 == 0`). `TaxSettingsView` ABN field shows an inline "looks invalid" hint on a failed checksum (non-blocking). The BAS header/PDF only prints the ABN; **no network ATO Lookup in v1** (deferred).
- **Manual fields + lodged lock — local-only UserDefaults**, key `sc.bas.<profileId>.<periodKey>` where **`periodKey` = `<fyStartYear>Q<n>`** for quarterly (e.g. `2025Q4` = Apr–Jun FY2025-26) or **`<calendarYear>M<mm>`** for monthly (e.g. `2026M04`). Stored: `paygInstalmentCents`, and a **lodged snapshot** `{ g1, oneA, oneB, netGst, payg, total, lodgedAtMs }`. **Not synced** in v1 (these are read off the ATO portal / are a per-device filing record). **Mark-as-lodged** writes the snapshot; the card/screen then show "Lodged <date>"; if a later recompute differs from the snapshot, a non-destructive banner warns "Figures changed since you lodged — corrections belong on your next BAS as an adjustment." (No data is locked/edited; this is an advisory record.)
- **Per-txn editing** lives in the existing transaction edit surface + capture review, so most items are right before BAS is opened.

### 4.7 Reports card + `BasView` (Router overlay) + ExportSheet
- **Reports card** (`ReportsView`, business + `gstRegistered` only, top of the tab): `BAS · <period label>` → **Net GST to pay/refund** + **Due <date>** + a "Lodged"/"Review" state + `Review ›`. Absent otherwise.
- **`Router` overlay** `.bas` (full-screen, id `"bas"`; excluded from `sheetBinding`/`sheetContent` like `.quotes`). `BasView`: headline (net + due + period stepper; reads "Estimated" until income reviewed), the **Simpler BAS spine** (G1, 1A, 1B, net 9, PAYG 5A input, total) with per-label **Copy** + a "where to type this in myGov" caption, a collapsible **"Full reporting method (≥$10M) — not on your Simpler BAS"** section (G2–G20 + capital split), the trust/reconciliation strip, and **Mark-as-lodged**. **Export** button → `ExportSheet` pinned to the BAS window + `bas` format.
- **`ExportSheet` extension:** when launched from `BasView`, the format is **hard-pinned to `bas`** (the accountant tile is not offered there — avoids two competing email-accountant affordances). The existing `accountant` format is unchanged and remains available from the normal Reports export entry. The `bas` flow calls `POST /export {format:"bas", from, to, bas:{paygInstalmentCents}, toEmail?}` and presents both returned links via the share sheet (or "Sent to <email>").
- **AccessibilityIDs** (`Snapceipt/Shared/AccessibilityID.swift`): `reportsBasCard`, `basScreen`, `basPeriodStepper`, `basCopyG1`/`basCopy1A`/`basCopy1B`, `basReconcileRowPrefix`, `basPaygField`, `basFullWorksheetToggle`, `basMarkLodged`, `basExport`; editor `txnGstFreeToggle`, `txnCapitalToggle`, `txnGstAmountField`. Containers use `.accessibilityElement(children:.contain)`.

### 4.8 Scoping & gating invariant
Everything scopes by the active `profileId` (never by mode/type, never nil). The BAS surface (Reports card + `.bas` overlay + the `bas` export format) is reachable **only when `profile.type == "business"` && `profile.gstRegistered`**. Ineligible profiles never see the card; the server route additionally **rejects with `FORBIDDEN`** (consistent wording across §4.4/§4.8 — reject, not no-op) and the engine forces 1A = 0 when `!gstRegistered`.

### 4.9 Manual-field ↔ BAS-label map (single source of truth)
`paygInstalmentCents`=**5A/T7** · `exportsCents`=**G2** · `inputTaxedSalesCents`=**G4** · `salesAdjustmentCents`=**G7** · `inputTaxedPurchaseCents`=**G13** · `privateUseCents`=**G15** · `purchaseAdjustmentCents`=**G18**. Only **5A** is user-editable in v1; the rest are engine parameters fixed at 0.

## 5. UI summary
`ReportsView` gains the gated BAS card (layout otherwise unchanged). `BasView` is a new full-screen overlay. The transaction editor gains a GST-amount field + two toggles. `ExportSheet` gains the pinned `bas` path. `TaxSettingsView` gains the inline ABN-checksum hint. No new tab.

## 6. Error handling & edge cases
- **Offline:** summary + reconciliation are fully on-device; only the *pack* needs network → "connect to export". PAYG + lodged snapshot persist locally.
- **Net refund** (8B > 8A): headline "ATO owes you $X"; PDF/CSV say "refund".
- **Empty/zero period:** honest empty state, export disabled.
- **Mixed-supply / estimated GST:** never silently trusted — `gst_source='derived'` items surface in reconciliation with a one-tap fix (toggle GST-free or type the real GST); printed-line discrepancies flagged separately. Disclaimer warns mixed receipts may overstate GST.
- **Already lodged then edited:** advisory banner (Mark-as-lodged snapshot vs current); corrections go on the next BAS.
- **Accruals setting:** v1 computes cash basis regardless; if `gstBasis == "Accruals"`, show an advisory rather than mislabel. **Cash basis ⇒ `txn_date` is the payment/receipt date** (stated assumption).
- **Whole-dollar rounding:** engine in cents; screen/PDF whole dollars; 1A/1B = `round(aggregate/11)` once.
- **`env.EMAIL` absent (dev):** BAS pack returns links, `emailed:false`, copy degrades to "ready · View PDF" (quote-send pattern).
- **Invalid ABN:** inline non-blocking hint; never blocks BAS (registration is the gate, not ABN validity).

## 7. Testing
Keep baselines green; add:
- **Backend unit:** `basEngine` vs `bas-golden.json` (every label; registered/non-registered; refund; empty; **monthly**; capital >$1k threshold; PAYG); `pdfBas` (`%PDF` bytes, both PDF sections + disclaimer); BAS CSV (`gst_free`/`capital`/`gst_source`/multi-value `bas_labels` + footer foots to worksheet; injection guard); `POST /export {format:"bas"}` (ownership + business + `gst_registered` `FORBIDDEN` gate, `from≤to`, R2 ×2, NEW response shape, `toEmail` → `email_outbox kind='export_accountant'` + `sendExportEmail` spied, graceful degrade); transaction/category schema round-trip for the 4 new columns.
- **Backend e2e:** real `POST /export {format:"bas"}` → `GET /export/dl/:token` round-trip for both PDF and CSV; the bas+email path spied.
- **iOS unit (Swift Testing):** `BasEngine` vs the **same** `bas-golden.json`; authority rule (`gstFree ⇒ gstCents==0, gstSource=nil`; flip-back re-derives; manual override sets `gstSource='manual'`); category default seeding + the one-time `backfillGstDefaults()`; reconciliation helpers (estimated-GST via `gstSource`, income-unconfirmed headline gate, printed-line discrepancy threshold); `ABNValidator` (valid/invalid modulus-89 vectors); periodKey formatting (quarterly/monthly) + Mark-as-lodged snapshot/diff; gating (card hidden unless business+registered); the export API client (`bas` format + new `ExportResult.basPack`).
- **iOS UI (hermetic, seeded):** Business+GST-registered profile + seeded txns → Reports shows the BAS card → `BasView` → assert G1/1A/1B → fix a reconciliation item → headline flips from "Estimated" to firm → Copy 1A → Mark-as-lodged → Export → pick BAS pack (Mock) → success. A non-registered profile shows **no** card.
- **Screenshot tour:** new `BAS` area (empty / needs-review / clean+lodged states).

## 8. Non-goals (this feature)
- **Actual ATO lodgement** (SBR/online-services integration) — lodge-*ready*, not lodge-*automatic*.
- **Live ATO ABN Lookup** (offline checksum only; network lookup deferred).
- **Full reporting method as the default surface** — computed + behind a toggle + in the pack, but the on-screen default is Simpler BAS.
- **User-editable advanced adjustments/exports/input-taxed** (G2/G4/G7/G13/G15/G18 are engine params fixed at 0 in v1).
- **Accruals basis** (cash only; advisory if the setting says accruals).
- **Per-line-item GST treatment** (per-transaction classification + editable GST amount + reconciliation instead).
- **PAYG/lodged-snapshot sync** (local-only per device/period in v1).
- **PAYG withholding (W1/W2), FTC, WET, LCT** (no-employees sole-trader scope; 8A=1A, 8B=1B).
- **Multi-currency / FX** (AUD only).

## 9. Pre-implementation checklist
- Confirm prod D1 is at `0003` so `0004_bas.sql` applies via `wrangler d1 migrations apply --remote` (and reset local `.wrangler` dev D1 once; tests rebuild from migrations).
- Confirm `ALTER TABLE … ADD COLUMN … NOT NULL DEFAULT 0` is non-rewriting on the in-use SQLite/D1.
- Re-capture exact green baselines (backend `npm test`/`e2e`; iOS full `xcodebuild`) before writing the plans.
- Re-verify against current ATO guidance at build time: **Simpler BAS = G1/1A/1B for GST turnover <$10M** (default since 1 Jul 2017; G2/G3/G10/G11 cause rejection); GST = 1/11 incl-GST; 1A=G9=`round(G8/11)`, 1B=G20=`round(G19/11)`; G10/G11 capital threshold **$1,000** (<$1M turnover); net 9 = 8A−8B; PAYG **T7→5A** reported separately; quarterly due dates 28 Oct / 28 Feb / 28 Apr / 28 Jul; **ABN modulus-89** checksum.
- Confirm reusing `email_outbox.kind='export_accountant'` for the emailed BAS pack is acceptable (keeps `0004` pure ADD-COLUMN; a distinct `'export_bas'` kind would require a CHECK-rebuild migration — deferred).

## 10. Decisions log
1. **Deliverable:** on-screen Simpler BAS summary **+** downloadable/emailable BAS pack.
2. **GST accuracy:** category-default treatment (only `groceries` GST-free; `health` taxable) + receipt-printed priority + `÷11` only for taxable + **`gst_source` provenance** + **editable per-txn GST amount** + per-txn toggle; income taxable (1A) for GST-registered.
3. **Labels:** **Simpler BAS spine (G1/1A/1B) on screen**; full worksheet computed + in the pack + behind a "full reporting method" toggle; capital G10/G11 split kept with the **$1,000 threshold** but off the spine; PAYG (T7→5A) the only user-editable manual field; advanced adjustments cut to engine-params-at-0.
4. **Placement:** Reports-tab BAS card → `BasView`; gated on business + GST-registered.
5. **Architecture:** on-device `BasEngine` + server `basEngine.ts` via a new `/export` `bas` format; one formula, golden-vector-locked.
- **D-method:** 1A/1B = worksheet `round(aggregate/11)` (ATO-valid; what the user types); per-txn `gst_cents` is accounts-method reference for the Reports pill + reconciliation; the CSV foots to the worksheet.
- **D-Simpler-BAS (review):** self-lodge surface is Simpler BAS; the full worksheet would be *rejected* on a <$10M lodgement.
- **D-provenance (review):** added `gst_source` so "estimated GST" is detectable and mixed-supply over-claim is visible/fixable.
- **D-trust (review):** offline ABN checksum + Mark-as-lodged snapshot/diff added as wedge-credibility features.
- **D-migration:** new `0004` ALTER-TABLE-only (prod live); emailed pack reuses `export_accountant` to avoid a CHECK-rebuild.
