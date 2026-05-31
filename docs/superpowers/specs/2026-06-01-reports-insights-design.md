# Reports & Insights — Design Spec

- **Status:** Approved (brainstorm) — proceeding to implementation plan(s)
- **Date:** 2026-06-01
- **Branch:** `foundation`
- **Feature:** F2 of the remaining-features roadmap (`docs/superpowers/specs/2026-05-31-snapceipt-remaining-features-roadmap.md`).
- **Builds on:** the shipped foundation + capture (F0) + **F1 Logbooks** (whose `VehicleYear.claimCents` + `WFHLog.claimCents` feed the Reports tax cards and logbook rows). iOS (`Snapceipt/`), Cloudflare backend (`src/`, `migrations/`, `test/`, `e2e/`). Design reference: `docs/superpowers/specs/extracted/screens.md` (ReportsScreen + ExportSheet, ~lines 325–442) and `2026-05-30-snapceipt-ios-app-design.md` §3.13/§3.16, §12.7, §14, §16; backend export at `extracted/backend.md` §3 (line ~548).
- **Baselines to keep green:** backend `npm test` 211 / `npm run test:e2e` 9; iOS `xcodebuild -only-testing:SnapceiptTests` 200 + `SnapceiptUITests` (all green).

---

## 1. Goal

Fill the stubbed **Reports tab** with a real, profile-scoped financial dashboard — income-vs-expense trend, category breakdown, AU tax stats, logbook shortcuts, and an honest insight — plus an **Export sheet** that produces a CSV + a summary PDF and can email a tax pack to the user's accountant. AUD-only.

## 2. Decisions locked in brainstorming

1. **Export = full but lean.** Backend `/export` generates **CSV + a one-page summary PDF** (server-side, pdf-lib), stores to R2 with a **7-day expiring download link**, and **emails the pack to an accountant** via the existing `env.EMAIL` binding. Recipient = free-form email + **one saved per-profile accountant address**. **Deferred** (later polish): multi-contact address book, in-app send history, re-share-expired-links.
2. **AI insight = honest heuristic, no AI call.** A real, always-truthful, mode-aware insight computed on-device from the period's data. NOT the design's fabricated static copy, and NOT a real DeepSeek call (spec defers real AI insights beyond v1).
3. **Period control (Month/Quarter/FY) rescopes the Donut + a headline "Net saved this {period}" figure.** The 5-month `BarPair` stays a fixed trend comparison; the **tax pills stay FY-to-date** (a tax/ATO concept). Default = Month. Period = the *current* month / quarter / FY (no arbitrary past-period navigation in v1).
4. **No new synced entities.** Reports is read-only aggregation over existing synced data. The only persistence touch is one column: `tax_settings.accountant_email`.
5. **Under-budget card (Personal) is OMITTED in F2** — it depends on F3 budgets; returns with F3.
6. **Activity tab is OUT of F2 scope** (it shares the period model but is a separate screen). F2 = Reports + the shared period control + export.
7. **Deductible YTD includes F1 logbook claims** (vehicle + WFH) within the FY, on top of per-transaction deductible amounts.
8. **Export inherits the currently-selected Reports period** as its `from`/`to` range.

**Reuse (already shipped):** the **Reports tab stub**; the unit-tested chart primitives **`BarPair`, `Donut`, `Segmented`, `ProgressBar`**; F1's `FinancialYear` helper; the design system (`Card`/`Palette`/`AccentPalette`/`Radius`/`fmt`/`fmtK`/`fmtDate`/`IconCircle`/`EmptyArt`/`Icon`); F1 logbook-claim models; the **`email_outbox` table** (kind `export_accountant` already present); the **`env.EMAIL`** Email Send binding (magic-link uses it) + its `vi.spyOn` test seam; the R2 `RECEIPTS` bucket + `images.ts` serve pattern.

## 3. Architecture

**Thin client + thin export backend.** The dashboard is pure SwiftData aggregation on-device (no network for Reports itself). Export is the only networked part: a single `POST /export` Worker route that generates files, stores them in R2, and (for the accountant format) emails them. No new sync entities; the read path is the existing local store + sync.

Likely **two implementation plans** under §4: **iOS** (Period + aggregators + ReportsView + ExportSheet UI) and **backend** (`/export` route + CSV/PDF/R2/email). **§4 is the authoritative cross-plan contract.**

## 4. Authoritative cross-plan contract

### 4.1 Schema touch (the only one)
Add to `tax_settings` (D1 + iOS `TaxSettings` @Model + its `SyncRowMapper`):
| D1 column | iOS / JSON | Type | Notes |
|---|---|---|---|
| `accountant_email` | `accountantEmail` | TEXT? / String? | per-profile saved accountant address; nullable |
Migration: extend `0001_init.sql` `tax_settings` block (repo convention; tests rebuild from migrations). Add `accountantEmail` to `tax_settings` `columns` map in `src/lib/syncTables.ts` and to the iOS mapper + `TaxSettings` init. No new `SYNCABLE_TYPES`/entities.

### 4.2 `POST /export` (backend)
- **Auth:** Bearer (not in `PUBLIC_PATHS`). **Rate limit:** new `export` tier (60/user/hr) in `src/middleware/rateLimit.ts`, mounted on `/export` + `/export/*` in `src/app.ts`.
- **Request** (`application/json`): `{ profileId, format: "pdf"|"csv"|"accountant", from: "YYYY-MM-DD", to: "YYYY-MM-DD", toEmail?: string }`. `toEmail` required iff `format === "accountant"`. Server enforces the profile belongs to `c.var.userId` (scoped query) and `from ≤ to`; else `VALIDATION_FAILED`/`FORBIDDEN`.
- **Behavior:**
  1. Query `transactions` `(user_id, profile_id, txn_date ∈ [from,to], deleted_at IS NULL)` desc + `receipt_images` in range.
  2. Generate via `src/lib/csvExport.ts` and/or `src/lib/pdfExport.ts` (pdf-lib).
  3. Store to `RECEIPTS` R2 at `<userId>/exports/<exportId>.{csv,pdf}`.
  4. `pdf`/`csv` → `200 { url, expiresAt }` where `url` is `GET /export/dl/:token`. `accountant` → generate both, insert `email_outbox` (`kind=export_accountant`, `status=queued`, `export_format`, `export_r2_key`), call `sendExportEmail`, update `sent`/`failed`, → `200 { status:"sent", outboxId }`.
- **`GET /export/dl/:token`** — PUBLIC (in `PUBLIC_PATHS`), unauthenticated. `token` is a signed `{ r2Key, exp }` (HMAC via the existing JWT signing key; 7-day exp). Validates signature + exp (else `403`), streams the R2 object with the right `content-type` + `content-disposition`. Mirrors how `images.ts` serves R2.

### 4.3 CSV format (`csvExport.ts`)
Header line documents profile name + period. Columns: `date, merchant, category, amount_incl_gst, gst, deductible_pct, payment_method, note, receipt_url`. `receipt_url` = a **7-day signed `GET /export/dl/:token`** link (same token scheme, with the receipt image's R2 key) so the unauthenticated accountant can open it — NOT the authed `/images/*` route. Empty when the transaction has no receipt image. Amounts in dollars (from cents). Deterministic ordering (date desc, then id).

### 4.4 PDF summary (`pdfExport.ts`, pdf-lib)
One page (paginated only if the txn list overflows): profile name + period header; **Deductible total** + **GST on purchases** for the range; **top-5 category breakdown** (label + amount); a transaction list (date / merchant / amount / GST / deductible%). No embedded receipt images. Output `Uint8Array` (`%PDF` bytes).

### 4.5 `sendExportEmail` (`src/lib/email.ts`)
`sendExportEmail(env, { to, replyTo, profileName, periodLabel, csv, pdf })` — builds a MIME message via `mimetext` (`createMimeMessage()`), attaches the CSV + PDF (≤ 25 MiB total), `from` = the magic-link sender, `replyTo` = the user's email, and `await env.EMAIL.send(new EmailMessage(...))`. Stubbed in tests via `vi.spyOn(emailModule, "sendExportEmail")`, exactly like `sendMagicLinkEmail`.

### 4.6 iOS data computations (pure, in `TransactionQuery` + `Period` + `InsightBuilder`)
All scoped to `activeProfileId`, `deletedAt == nil`. Cents are `Int`; dates `"YYYY-MM-DD"` (UTC, via `FinancialYear`/ISO parser).
- **`Period`**: `month | quarter | fy`. `window(now, startMonth) -> (start, end, label)`. Month = the calendar month of `now`. Quarter = the AU-FY quarter of `now` (Q1 Jul–Sep, Q2 Oct–Dec, Q3 Jan–Mar, Q4 Apr–Jun). FY = `FinancialYear.of(now, startMonth)`. `label` e.g. "June 2026" / "Apr–Jun 2026" / "FY2025-26".
- **`TransactionQuery.netSaved(txns, window) -> (incomeCents, expenseCents, netCents)`**: income = Σ `amountCents>0`; expense = Σ `−amountCents` over `amountCents<0`; net = income − expense. (Drives the period headline figure.)
- **`TransactionQuery.monthlyTrend(txns, now) -> [BarPairDatum]`**: the **last 5 calendar months** (anchored to `now`), each `{label, income, expense}`. Period-independent (drives `BarPair`).
- **`TransactionQuery.byCategory(txns, window) -> [(catKey, spendCents)]`**: expenses (`amountCents<0`) grouped by `catKey`, Σ `−amountCents`, sorted desc. Donut segments use `CATS[catKey].tint`; legend = top 5; center total = Σ all expense in window. (Recomputed per period.)
- **`TransactionQuery.deductibleYTD(txns, fyWindow, vehicleYearClaims, wfhClaims) -> Int`**: Σ over FY expense txns of `round(−amountCents × deductiblePct/100)` (when `deductiblePct != nil`) **+** Σ `VehicleYear.claimCents` for the current `fyStartYear` **+** Σ `WFHLog.claimCents` for logs in the FY window. (FY-to-date; period-independent.)
- **`TransactionQuery.gstYTD(txns, fyWindow) -> Int`**: Σ `gstCents` over FY expense txns. (FY-to-date.)
- **`InsightBuilder.insight(mode, txns, window, prevWindow) -> String`**: a truthful heuristic — e.g. top category this period (`"<Category> is your biggest expense this <period> — <amount>."`) and/or a period-over-period delta (`"You spent <amount> <less|more> than last <period>."`); empty-data fallback (`"Add a few receipts and your insights will appear here."`). Mode-aware tone (Business vs Personal). NO network/AI.

## 5. UI — Reports screen
`ReportsView` replaces the Reports `StubTabView` (it's a **tab**, not an overlay). Top → bottom (per `screens.md`), accent re-skinned to the active profile:
1. **Header** — H1 "Reports" + **Export pill** (share icon) → presents `ExportSheet`.
2. **`Segmented` period control** — Month / Quarter / FY (default Month). Rescopes the Donut + the §3 headline net figure.
3. **Net-saved trend card** — caption "Net saved · {This month|This quarter|FY2025-26}", big number = period net (§4.6 `netSaved`), In/Out legend, then **`BarPair`** = rolling 5-month `monthlyTrend` (fixed).
4. **"Where it went" donut** — **`Donut`** over `byCategory(window)` (center = period total) + top-5 legend. Recomputes with the period.
5. **Business-only — tax stat pills**: Deductible YTD (`deductibleYTD`, incl. F1 claims) + GST on purchases (`gstYTD`). FY-to-date.
6. **Business-only — Logbooks section**: Vehicle + WFH rows with **real F1 data** (FY claim + km/hours for the active profile) → tap opens the existing F1 `MileageScreen`/`WFHScreen` overlays (Router `.mileage`/`.wfh`).
7. **Personal-only — under-budget card**: **omitted** (F3).
8. **AI insight card** (always) — designed gradient card rendering `InsightBuilder.insight(...)`.
9. **States** — donut empty ring + "$0" and pills "$0" on no data; light shimmer while the query resolves; `BarPair` always renders.

Business-vs-Personal layout keys off `profile.type` (any non-`personal` → Business layout). Everything scoped by `activeProfileId`.

## 6. UI — Export sheet
`ExportSheet` bottom-sheet (opened from the Export pill):
- **Format tiles** (one selected): PDF report (default) / CSV file / To accountant.
- **Detail card** scoped to the **currently-selected Reports period**: Period (range label), Receipts included (real `receipt_images` count in range), Deductible total (period deductible).
- **"Generate & send" CTA** with in-progress / success / error:
  - **PDF / CSV** → `POST /export` → present the returned `url` via the iOS **share sheet** (save/open/share).
  - **To accountant** → recipient = `tax_settings.accountantEmail` (editable) or an inline email field; tap → `POST /export {format:"accountant", toEmail}` → success ("Sent to <email>") / error (retry). On success, save the email to `tax_settings.accountantEmail`.
- **Lean scope:** one saved address per profile; no address book, no send-history list, no re-share UI. Failures use the existing toast + CTA retry.

## 7. Testing
Keep baselines green (backend 211/9, iOS 200 + UI); add:
- **Backend unit:** CSV shape (headers/rows/`receipt_url` column, dollar conversion); PDF (`%PDF` bytes, contains period + totals); `GET /export/dl/:token` (valid token streams; expired/forged → 403); accountant path (`email_outbox` queued→sent; `sendExportEmail` spy called with both attachments; profile-ownership + `from≤to` validation; `toEmail` required for accountant).
- **Backend e2e:** real `POST /export` (csv) → `GET /export/dl/:token` round-trip returns the CSV; accountant path with the email send spied.
- **iOS unit:** `Period` windows (Month/Quarter/FY incl. AU quarters, label formatting, 30 Jun↔1 Jul edges); `TransactionQuery` (byCategory sorted, period netSaved, rolling-5 trend, deductibleYTD **incl. F1 claims**, gstYTD); `InsightBuilder` (per-mode truthful output + empty fallback); `ReportsViewModel` (profile+period scoping, Business-vs-Personal layout, logbook claim sums); the export API client.
- **iOS UI** (hermetic, CaptureUITests-style): Reports tab → toggle period (donut + net recompute) → open Export sheet → pick CSV → (stubbed network) assert the flow; a Business profile shows tax pills + logbook rows.

## 8. Non-goals (this feature)
- Budgets / the Personal under-budget card (F3).
- The Activity tab.
- Real AI/DeepSeek insights.
- Accountant address book, in-app send history, re-share-expired-links (lean recipient only).
- Arbitrary past-period navigation (period = current month/quarter/FY).
- Embedding receipt images into the PDF (CSV links to them via the download route).
- The full Tax & GST settings editor (F7) — F2 only reads `tax_settings` + writes `accountantEmail`.
- S3-style R2 presigning (we use a signed Worker download route instead).

## 9. Pre-implementation checklist
- Confirm `pdf-lib` is acceptable as a Worker dependency (pure-JS, no Node APIs) for the summary PDF.
- Confirm Cloudflare **Email Send** is provisioned for `snapceipt.app` (SPF/DKIM/DMARC) for real accountant delivery — the binding + magic-link path already work; the seam keeps build/tests green regardless.
- Confirm `mimetext` (for MIME attachments) is available/added as a Worker dependency.
- Editing `0001_init.sql` for the `accountant_email` column → reset local `.wrangler` dev D1 once (tests rebuild from migrations).
