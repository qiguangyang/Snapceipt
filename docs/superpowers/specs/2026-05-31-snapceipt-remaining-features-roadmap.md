# Snapceipt — Remaining Features Roadmap (Master Plan)

- **Status:** Approved (brainstorm) — the structuring/sequencing decisions are locked; each feature still gets its own design spec.
- **Date:** 2026-05-31
- **Branch:** `foundation`
- **Builds on:** the shipped Snapceipt foundation + the receipt-capture/extraction feature. iOS (`Snapceipt/` + `SnapceiptTests/` + `SnapceiptUITests/`, XcodeGen `project.yml`, "iPhone 16" sim), Cloudflare backend (root `src/`, `migrations/`, `wrangler.jsonc`, `test/`, `e2e/`). Authoritative design references: `docs/superpowers/specs/2026-05-30-snapceipt-ios-app-design.md` and `docs/superpowers/specs/extracted/{screens,backend,critic}.md`.
- **Baselines to keep green throughout:** backend `npm test` = 185, `npm run test:e2e` = 8; iOS `xcodebuild -only-testing:SnapceiptTests` = 160 + `SnapceiptUITests/CaptureUITests`.

---

## 1. Goal & how to read this doc

This is the **master roadmap** for the seven remaining v1 features. It is deliberately *not* a per-feature design — it operates one level up:

- **What** each feature is, at scope/entity/blocker altitude (§3).
- **Shared foundations** several features depend on, and where each gets built (§4).
- **External dependencies** the user must procure, and the stub-seam strategy that lets us build without them (§5).
- **The locked build order** and the dependency reasoning behind it (§6).
- **The per-feature process** — each feature is its own design → plan → implement cycle (§7).
- **Cross-cutting invariants** every feature must honour (§8).

**Each feature below links to a spec that does not exist yet.** That spec is written when the feature reaches the front of the queue, via the brainstorming → writing-plans flow — exactly how the capture feature was built. Detailed field shapes, screen-by-screen behaviour, and per-feature decisions live *there*, not here.

---

## 2. Decisions locked in this brainstorm

1. **Structure = roadmap + per-feature specs** (not one mega-spec, not themed bundles). Each feature is shippable on its own.
2. **Build order = dependency-first** (§6): Logbooks → Reports → Budgets+push → Loyalty → Quotes → Email-in → Settings.
3. **External network deps are gated behind dev/stub seams** (the DeepSeek pattern), so a feature can be fully built and tested hermetically before its real key/domain exists.
4. **Profile scoping is non-negotiable** — every domain entity is scoped by `profileId` (display `mode` is accent-only). Carried into every feature (§8).

---

## 3. The seven features (scope capsules)

> Sizes are rough build signals: **S** (days), **M** (about a week), **L** (more). Each capsule defers its real design to a future `docs/superpowers/specs/YYYY-MM-DD-<feature>-design.md`.

### F1 — Logbooks (mileage + WFH) · **S** · no external blocker
- **Scope:** Manual trip and work-from-home entry for ATO tax claims. Mileage: from/to, purpose, km, date, business flag, hero stats (ATO cents-per-km or logbook-method claim), trip list. WFH: daily date/hours/note entries, 67c/hr fixed-rate claim, this-week bar chart, fixed-rate explainer. Both compute claimable amounts from `tax_settings` rates, **snapshotting the rate per entry**.
- **Screens:** `MileageScreen` (overlay), `WFHScreen` (overlay). GPS auto-track toggle = **placeholder "Coming soon"** (no background location in v1).
- **New entities:** `mileage_trips` (trip_date, from/to label, purpose, distance_m, is_business, rate_cents_per_km, claim_cents, auto_tracked=0), `wfh_logs` (log_date, minutes, note, rate_cents_per_hour, claim_cents). Both are Syncable @Models + D1 tables. Optional `transactions.mileage_trip_id` link.
- **Backend:** `/mileage`, `/wfh` CRUD (root-mounted, matching capture conventions — *not* the `/v1` prefix in the old `extracted/backend.md`).
- **Why first:** fully local, zero external setup, and it establishes the `tax_settings` rate-consumption + claim-calc plumbing that Reports then surfaces.

### F2 — Reports & insights · **M** · external: Email Send (export only)
- **Scope:** Reports tab for the active profile: 5-month income-vs-expense trend (BarPair), category spend breakdown (Donut), profile-specific tax stat cards (Business: Deductible YTD + GST on purchases; Personal: under-budget encouragement). Shared period control (Month/Quarter/FY, AU FY boundaries). AI insight card with mode-specific copy. Export sheet (PDF / CSV / send-to-accountant).
- **Screens:** `ReportsScreen` (tab), `ExportSheet` (bottom sheet).
- **New entities:** none — aggregates `transactions` (by `cat_key`, `deductible_pct`, `gst_cents`) plus logbook claims (F1). Server-only `email_outbox` table to track export sends.
- **Backend:** `/export` (generate PDF/CSV, send-to-accountant email). Charts/aggregation are client-side over synced data.
- **External:** Cloudflare Email Send for send-to-accountant (build behind stub; core charts + PDF/CSV don't need it).

### F3 — Budgets + push (APNs) · **M–L** · external: APNs key
- **Scope:** Budget CRUD (per-category or whole-profile caps, monthly period, alert-threshold %). Home 3-row tracker card. A Worker cron recomputes spend vs cap per profile and fires an APNs push when crossing threshold (with send-dedup); tapping deep-links to the budget. Notifications settings (per-type toggle, optional BAS reminder, quiet hours). `AlertsSheet` with persisted read/unread + dismiss + deep-link.
- **Screens:** budget list/editor, Notifications settings, `AlertsSheet`.
- **New entities:** `budgets` (cap_cents, alert_threshold_pct, alert_sent_at) Syncable; an alert/read-state log; `devices.apns_token` column.
- **Backend:** `scheduled` cron handler; `PUT /devices/me` (apns_token). APNs JWT (RS256) signed in-Worker from a `.p8` secret.
- **External:** APNs `.p8` auth key (build budget CRUD + tracker local-first; gate push behind the key).

### F4 — Loyalty barcodes · **S–M** · no external blocker
- **Scope:** Loyalty wallet of branded cards (gradient, points label, mini barcode). Add-a-card via VisionKit barcode scan (Code-128/EAN-13/QR/Aztec/PDF417) or manual entry. Immersive full-screen card detail that renders a POS-grade barcode and boosts screen brightness; Share/Done. Store detected `barcode_format` for correct re-render.
- **Screens:** `LoyaltyScreen` (wallet), `AddLoyaltyScreen`, `LoyaltyCardDetail`.
- **New entities:** `loyalty_cards` (brand, number, barcode_format, color_1/2, points_label) Syncable + D1 table.
- **Backend:** `/loyalty` CRUD. Brand catalog = static seed (no backend catalog in v1).
- **External:** none — VisionKit detect + CoreImage generate are native (Aztec/PDF417 generation may need a fallback lib; decide in its spec).

### F5 — Quotes (Business-only) · **M** · external: Email Send + PDF
- **Scope:** Compose invoices/quotes — client picker (saved address book), editable line items (desc/qty/unit price), GST 10% toggle, live totals (server-recomputed). **Server-authoritative sequential numbering** (`SN-####`) to avoid offline-duplicate numbers. Draft/Sent status + send history. Send → generate PDF → email via Email Send. Model the accepted→invoice path (invoice UI deferred).
- **Screens:** `CreateQuoteScreen` (overlay) + quote list.
- **New entities:** `quotes` (number, client_name/email, gst_enabled, subtotal/gst/total cents, status, valid_until, sent_at) + `quote_line_items` (soft-delete children). Both Syncable + D1.
- **Backend:** `/quotes` CRUD, `/quotes/:id/send`. Per-user number counter (server).
- **External:** Email Send (shared with F2) + a PDF generation approach (decide in its spec).

### F6 — Email-in receipts · **L** · external: Email Routing subdomain + Workers AI
- **Scope:** Each user gets `r.<inboxId>@in.snapceipt.app`. Inbound mail → Email Routing → Worker `email` handler → extract image attachment → Workers AI vision OCR → same DeepSeek extractor as the app path → auto-create transaction (`source='email_in'`). Failed extraction still creates a reviewable stub (`extraction_status='failed'`). Push-notify on arrival (reuses F3 APNs). Settings row shows the inbound address with copy/share/rotate token. Review queue surfaces email-in receipts (esp. failures).
- **Screens:** email-in review queue + a Settings row.
- **New entities:** none — reuses `receipt_images` (`source='email_in'`, `extraction_status='failed'`). Inbox token storage on the user.
- **Backend:** `export { email }` handler (MIME parse via `postal-mime`), Workers AI `@cf/meta/llama-3.2-11b-vision-instruct`, reuse extract logic, `/email-in/rotate`.
- **External:** Email Routing on `in.snapceipt.app` (separate MX/SPF) + Workers AI (metered). **PDF attachments deferred** (JPEG/PNG only in v1).

### F7 — Settings detail · **M–L** · no external blocker
- **Scope:** The settings hub off the Profile tab. **Profile-scoped:** Categories & smart-rules CRUD, Tax & GST settings (Business: ABN/entity/GST/basis/FY/BAS due; Personal hides ABN/GST). **App-scoped:** Notifications & alerts (ties to F3), Export & backup (ties to F2), Privacy & security (Face ID lock), Help (external link). **Account:** change email, manage devices/sessions (from `devices`), delete account. Sign-out is already wired.
- **Screens:** `ProfileScreen` sections, `CategoriesScreen`, `TaxScreen`, `NotificationsScreen`, `AccountSettingsScreen`, `ProfileDetailScreen`.
- **New entities:** none — reuses `categories`, `smart_rules`, `tax_settings`, `devices`.
- **Backend:** `GET /auth/me` (+devices), `/devices` list, `DELETE /devices/:id`, `PATCH /users/me` (email), `DELETE` account.
- **Why last:** it's the editor surface for config (categories, tax rates, notifications, devices) that earlier features consume via **seeded defaults / minimal stubs**. Settings turns those into real editing UI and consolidates account management.

---

## 4. Shared foundations (build once, reuse)

These are consumed by multiple features. Each is built inside the **first** feature that needs it, then reused — *not* as a separate up-front phase.

| Foundation | Built in | Reused by |
|---|---|---|
| `tax_settings` config (ATO rates 88c/km · 67c/hr · 50% meals, FY=1 Jul, GST/ABN) | F1 (minimal, seeded defaults) → full editor in F7 | F1, F2, F5, F7 |
| Period control (Month / Quarter / FY, AU FY boundaries) | F2 (reusable component) | F2, F3, Activity |
| Category taxonomy + smart rules (9-key enum) | already partly present (txn `cat_key`); editor in F7 | F2, F3, F7 |
| `devices` table + APNs token plumbing | F3 | F3, F6, F7 (device mgmt) |
| Cloudflare Email Send seam | F2 (export) | F2, F5 |
| Sync envelope on every new @Model (`id, user_id, profile_id, created_at, updated_at, deleted_at`) | each feature's entities | all |

**Implication:** F1 and F2 deliberately seed `tax_settings`/categories with sensible defaults and a thin editing path; F7 replaces the stubs with the full editor. Each feature's spec states exactly which stub it leaves for F7.

---

## 5. External dependencies — procurement checklist

These gate the **network** behaviour, not the build. Every one is hidden behind a dev/stub seam (the DeepSeek pattern) so the feature is fully buildable and hermetically testable before the real dependency exists. Procure these in parallel with the build.

- [ ] **Cloudflare Email Send (beta)** + verified `snapceipt.app` domain (DKIM/SPF/DMARC). → gates F2 send-to-accountant, F5 quote send.
- [ ] **APNs `.p8` auth key** from the Apple Developer account, stored as a Worker secret. → gates F3 push, F6 arrival push.
- [ ] **Email Routing on `in.snapceipt.app`** (separate MX/SPF, catch-all → Worker). → gates F6.
- [ ] **Workers AI** access for `@cf/meta/llama-3.2-11b-vision-instruct` (metered Neurons). → gates F6 OCR.
- [ ] **DeepSeek API key** + confirmed real model id (carried over from capture; `wrangler secret put DEEPSEEK_API_KEY`). → activates F2/F6 extraction quality.
- [ ] **ATO record-retention decision** (how long receipts/exports persist; affects account-deletion in F7 and export in F2). → policy decision, not infra.

---

## 6. Build order (locked) + dependency reasoning

```
F1 Logbooks ──► F2 Reports ──► F3 Budgets+push ──► F4 Loyalty ──► F5 Quotes ──► F6 Email-in ──► F7 Settings
```

- **F1 first** — fully local, no blockers; establishes tax-rate/claim plumbing that F2 surfaces (Deductible YTD, logbook shortcuts).
- **F2 after F1** — its tax cards + logbook shortcuts are richer once trips/WFH exist; core charts only need transactions (already present). Introduces the period control + Email Send seam.
- **F3 after F2** — budgets feed the Reports under-budget card; introduces `devices`/APNs, reused by F6/F7.
- **F4 anywhere** — independent and native; placed here as a self-contained palette-cleanser between the tax-heavy block and the email-heavy block.
- **F5 after F4** — first heavy use of Email Send + PDF (shares the F2 seam).
- **F6 after F5** — heaviest external setup; reuses F3 APNs (arrival push) and the capture extract pipeline.
- **F7 last** — surfaces/edits config that F1–F6 consumed via stubs (categories, tax rates, notifications, device mgmt, email-in inbox row) and consolidates account management.

**Soft dependencies, not hard blocks:** F2's core charts work without F1; F3's CRUD works without push. Where a feature can ship a degraded-but-useful slice before its dependency, its spec will say so.

---

## 7. Per-feature process

Each feature, when it reaches the front of the queue, runs the same cycle that built capture:

1. **Brainstorm** (this skill) → a focused `docs/superpowers/specs/YYYY-MM-DD-<feature>-design.md`, with an authoritative cross-plan contract section (like capture spec §9) when it spans iOS + backend.
2. **writing-plans** → one or two implementation plans under `docs/superpowers/plans/`.
3. **Implement** task-by-task with review; **integration review** of the whole feature.
4. **Verify** — keep the test baselines (§ header) green and add the feature's own tests; gate any network dep behind its stub seam.

This roadmap is updated (check the box / note the spec path) as each feature lands.

---

## 8. Cross-cutting invariants (every feature honours these)

1. **Profile scoping (CRITICAL):** scope all domain data by **`profileId`**, never by `mode`/`type`. `mode` is display-only (accent: Personal terracotta `#E8602C`, Business teal `#0E7C72`). The Worker additionally enforces `WHERE user_id = :authedUser`.
2. **Sync envelope:** every new @Model Syncable carries `id, user_id, profile_id, created_at, updated_at, deleted_at` and flows through the existing local-first sync (LWW on `updated_at`, soft-delete tombstones, keyset cursor). Mutations go through the outbox.
3. **AU tax model:** GST 10% (prefer printed; infer only for AUD-no-printed, flag `gst_inferred`); deductible % per transaction (0–100); FY 1 Jul–30 Jun; ATO rates 88c/km · 67c/hr · 50% meals rule. Snapshot rates onto entries.
4. **Currency:** AUD only in v1. No multi-currency/FX.
5. **Backend conventions:** root-mounted routes (no `/v1`), the implemented category set, Hono + D1 + R2/AI/Email bindings, per-tier rate limiting, auth via Bearer with `PUBLIC_PATHS`.
6. **Offline-first UX:** toast system, sync-status indicator, offline banner, pending-upload badge, retry on extract/send failures, loading skeletons.
7. **Designed empty states:** every list screen (budgets, loyalty, mileage, WFH, reports, categories) ships its first-run empty state via the `EmptyArt` primitive.
8. **Out of scope (v1):** multi-currency/FX, monetization/paywall, OS dark mode, GPS auto-track (UI placeholder only), connected banks/reconcile (UI placeholder only).

---

## 9. Status tracker

| # | Feature | Spec | Plan(s) | Status |
|---|---|---|---|---|
| F1 | Logbooks (mileage + WFH) | [design](2026-05-31-logbooks-design.md) | [backend](../plans/2026-05-31-logbooks-backend.md) · [ios](../plans/2026-05-31-logbooks-ios.md) | ✅ **implemented** (backend `npm test` 211 / e2e 9; iOS 200 unit + UI green) |
| F2 | Reports & insights | — | — | queued |
| F3 | Budgets + push | — | — | queued |
| F4 | Loyalty barcodes | — | — | queued |
| F5 | Quotes | — | — | queued |
| F6 | Email-in receipts | — | — | queued |
| F7 | Settings detail | — | — | queued |
