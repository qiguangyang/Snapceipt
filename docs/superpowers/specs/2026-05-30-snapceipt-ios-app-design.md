# Snapceipt — Whole-App Design Spec

- **Status:** Draft for review
- **Date:** 2026-05-30
- **Author:** Brainstormed with Claude (Snapceipt project)
- **Tagline:** *Snap it. Sort it. Sorted.*
- **Design source:** Claude Design handoff bundle (`design-ref/snapceipt/`). Exhaustive pixel-level extraction of every screen + backend contracts lives in [`extracted/`](./extracted/) (`screens.md`, `backend.md`, `critic.md`, `_raw-result.json`). **This spec is the design contract; `extracted/` is the pixel reference for implementation.**

---

## 1. Product summary

Snapceipt is a calm, trustworthy **AUD** fintech app for Australian freelancers and sole traders to capture receipts and track expenses & income across **Personal and Business profiles**. Switching the active profile re-skins the whole app's accent (Personal = terracotta `#E8602C`, Business = teal `#0E7C72`; other profiles carry their own palette). Cream canvas, Schibsted Grotesk (numbers/headings) + Hanken Grotesk (UI), line icons, 22px rounded cards, soft shadows, a raised-center "Snap" tab bar. Target device: iPhone, iOS 17+.

The core loop: **Snap a receipt → on-device OCR → DeepSeek extracts merchant/date/total/GST/category → review → save**, with friendly empty states and an AI "98% match" auto-categorize moment. Around it: an Activity ledger, Reports (charts + AU tax stats), multi-profile management, AU tax tooling (GST, deductibles, mileage & WFH logbooks, BAS), loyalty cards, quotes, manual entry, and a Cloudflare backend providing accounts, cloud sync, server-side extraction, email-in receipts, and send-to-accountant exports.

---

## 2. Locked decisions (from brainstorming)

| # | Decision |
|---|----------|
| D1 | **Accounts + cloud sync.** Sign in with Apple (primary) + email magic-link. D1 + R2 are the source of truth. |
| D2 | **Sync = local-first.** Writes hit SwiftData instantly + an offline mutation queue; pull deltas via a per-user cursor; last-write-wins (LWW) on `updatedAt`; soft-delete tombstones. |
| D3 | **Extraction.** App path: on-device Apple Vision OCR text → `POST /extract` → DeepSeek `deepseek-v4-flash` (JSON mode). Email-in path: Email Routing → Cloudflare Workers AI vision OCR → **same** DeepSeek extractor. |
| D4 | **Email service powers:** (a) magic-link sign-in, (b) send-to-accountant exports (PDF/CSV), (c) email-in receipts. **No emailed reminders** — the Alerts feed stays in-app; budget alerts are push (APNs). |
| D5 | **Real in v1:** loyalty barcodes, budgets + push alerts. **Placeholder (UI-only):** GPS mileage auto-track, bank reconcile / connected banks. |
| D6 | **Scope:** spec the **whole app**; implement in phases (§17). |
| D7 | **Currency = AUD only in v1** (see §14, resolves the multi-currency contradiction). |
| D8 | **Drop the design-only Tweaks panel.** Ship fixed production values (see §6.6). |

---

## 3. Resolved design decisions (closing the critic's gaps & contradictions)

The handoff prototype is a clickable mockup; several flows are inert stubs and a few model choices conflict. These are resolved here and are **first-class spec items**, not afterthoughts. (Source: `extracted/critic.md`.)

1. **Identity model — partition by profile, not mode (R-CRITICAL).** All ledgers, reports, budgets, tax settings, quotes, logbooks, and loyalty are scoped by **`profileId`**, never by `type`/`mode`. "Mode" is purely a display concept = the active profile's `type`, which selects the accent palette and the mode-aware quick-action set. The prototype filters transactions by `mode`, which would commingle/hide data for users with multiple business profiles (Studio/Lumen/Rentals all `type='business'`). **Fix:** Home, Activity, Reports, budgets, and the deductible tracker all read `WHERE profileId == activeProfileId`.
2. **Auth + onboarding screens (new, undesigned in prototype).** Spec a full first-run flow: launch/splash, **Sign in with Apple** + **email magic-link** entry, "check your email" waiting state, magic-link **verify/landing** (Universal Link), expired/invalid-link error, and cold-start onboarding (create first profile, prime Camera + Notifications permissions). Sign-out returns here. See §9.
3. **Transaction edit + capture-review edit = one reusable editable form.** Mirrors `ReceiptScanner.swift`'s editable fields: merchant, date (picker), category (picker), amount, GST (with **inferred-vs-printed** flag), tax-deductible %, profile/mode reassignment, attach/replace receipt, note. Drives both the capture **Review** step and **TxnDetail → Edit**. Delete uses a confirmation + soft-delete tombstone + undo toast. See §12.3 / §12.4.
4. **Budgets are real (CRUD).** A budget list/editor reachable from Home's "Edit" link and Profile: per-category caps, period (monthly + FY), over-cap alert threshold (drives push), empty/first-budget state. Spent is **computed** from transactions (never stored). See §12.6.
5. **Notifications & alerts system.** APNs permission priming; a Notifications settings screen (which events push vs in-app, per-budget thresholds, optional BAS reminder, quiet hours); push deep-link targets; the in-app **AlertsSheet becomes data-bound** (read/unread, per-item tap action, dismiss, empty state). **Reconciliation of D4:** budget-threshold crossings (and optional BAS-due) fire as **APNs push**; tapping a push deep-links into the app; the AlertsSheet is the persistent in-app feed of those same events. "No emailed reminders" stands — reminders are push + in-app only.
6. **GST correctness (AU).** Prefer **printed GST** over inference. Only infer `round(total/11, 2)` when the receipt is AUD, taxable, and GST is not printed; **flag inferred GST for review** (`gst_inferred`). Handle GST-free / mixed baskets (e.g. supermarket fresh food) by allowing `gst = null`/0 and surfacing the flag in the review UI. See §10 + §14.
7. **Currency scope = AUD (D7).** Default `currencyCode = 'AUD'`. Update `ReceiptScanner.swift`'s default from `"USD"` to `"AUD"` and bias the OCR currency sniff to AUD. Foreign-currency receipts are **flagged for review** (`foreign_currency`) and stored but **excluded from aggregates** (no silent FX); a clear "not in AUD" badge appears. Multi-currency rollups are out of scope for v1.
8. **Extraction category enum = the design's 9 keys.** `meals, groceries, fuel, software, office, home, health, travel, income` (matches `theme.jsx` `CATS`). The extraction-contract agent invented a different taxonomy (`dining/transport/...`) — **discard it**. The `/extract` response `category` is exactly one of these 9 — there is **no** `other` value; when unmappable, the extractor picks the closest of the 9 and sets `needsReview`, and the user can re-pick in the Review screen.
9. **Placeholder UX is honest.** GPS mileage auto-track, Connected Banks, and the capture **"Add to mileage" / "Match to bank"** chips render as visibly **"Coming soon"** (disabled or an info sheet), with **no live-looking sync states** and **no network calls** (fully client-stubbed; the `/banks` API returns `501` if ever called). **Note:** mileage *trips* and *WFH logs* are **real, manually-entered data** — only the *GPS auto-track* toggle is placeholder; only *bank linking/reconcile* is placeholder.
10. **Empty / first-run states everywhere.** Every list designs a day-one empty state (Home recent, Activity, Loyalty wallet, Mileage trips, WFH days, Categories, Reports donut, quotes) using the `EmptyArt` primitive. A brand-new account is a designed experience, not a blank screen.
11. **Sync / offline / error UI (cross-cutting).** Global toast system, a sync-status indicator, an offline banner, a "pending upload" badge on queued mutations, the LWW "updated elsewhere" toast, capture extract-failure retry, and list loading skeletons (`sc-shimmer`). See §15.
12. **Email-in surface.** Settings shows the user's personal inbound address (`r.<inboxId>@in.snapceipt.app`) with copy/share/rotate; an email-in **review queue**; failed extraction still creates a reviewable transaction stub (`extraction_status = 'failed'`) so nothing is lost; a push notification on arrival. See §11 + §12.10.
13. **Send-to-accountant recipient flow.** Accountant email entry + saved address book, send-history/"sent" confirmation, re-share for expired links, date-range/profile scope, and in-progress/success/error states for the generate+email call. See §12.7.
14. **Loyalty barcode symbology (real in v1).** Capture/detect symbology via the scan path (Code-128 / EAN-13 / QR / Aztec / PDF417), store a `barcode_format` column, render with a vetted generator at scanner-grade resolution + quiet zone, and provide a **number-only fallback** when a format can't be generated. Boost screen brightness on the card-detail screen. See §12.9.
15. **Account & settings depth.** Identity is **data-bound to the signed-in user** (remove hardcoded "Maya Reyes"). Account settings: change email, manage devices/sessions (from the `devices` table), delete account. **Monetization is descoped for v1** — the "Pro" pill is hidden (or shown as a static non-interactive label) and there is no paywall. Real destinations for the Export & backup / Privacy & security / Help & support rows; Sign-out is wired (confirm → clear Keychain → return to auth).
16. **Shared period model.** One period/date-range model shared across Activity, Reports, and Export: Month / Quarter / **FY** (AU FY = **1 Jul – 30 Jun**) + a custom range picker, with correct FY boundary handling. The prototype's three independent period controls are unified.
17. **LWW data-loss accepted for v1.** Concurrent offline edits to the same record on two devices: last writer wins; the loser is overwritten and an "updated elsewhere" toast is shown. No field-level merge/CRDT in v1 — documented as an accepted limitation (§19).

---

## 4. Goals & non-goals

**Goals (v1):** pixel-faithful SwiftUI rebuild of every prototype screen; the full Snap→extract→review→save loop reusing `ReceiptScanner.swift`; accounts + cloud sync; AU GST/deductible/FY tooling; real budgets + push; real loyalty barcodes; send-to-accountant + email-in via Cloudflare; honest placeholders for GPS-mileage-auto and bank reconcile.

**Non-goals (v1):** multi-currency rollups/FX; live bank feeds (Basiq etc.); GPS auto-tracking of drives; monetization/paywall; Android/web/iPad-optimized layouts; OS dark mode (design renders light; dark is a later phase); CRDT/field-level merge sync.

---

## 5. Architecture

### 5.1 System & data flow

```
 iPhone — SwiftUI, iOS 17+ (SwiftData local-first)        Cloudflare
 ┌──────────────────────────────────────────┐     ┌──────────────────────────────────────┐
 │ Capture: VisionKit + Vision OCR            │ OCR │ Worker (Hono) — snapceipt-api          │
 │   (reuses ReceiptScanner.swift)            │text │  /v1/auth/* (Apple, magic-link)        │
 │ DesignSystem · Feature modules             │────▶│  /v1/sync/push · /v1/sync/pull         │
 │ SwiftData store  ◀── SyncEngine ──▶ APIClient│◀──▶│  /v1/extract  /v1/export  /v1/images  │
 │ OutboxQueue (offline mutations)            │sync │   ├─ D1   (structured data, tenant)    │
 │ Keychain (session + refresh + deviceId)    │     │   ├─ R2   (receipt images + thumbs)   │
 └──────────────────────────────────────────┘     │   ├─ Email Send (magic-link, exports)  │
                                                    │   ├─ Email Routing → email() (email-in)│
                                                    │   ├─ Workers AI (vision OCR, email-in) │
                                                    │   ├─ KV (magic-link nonces, rate limit)│
                                                    │   └─ DeepSeek V4 over HTTPS (secret)   │
                                                    │  scheduled: budget push cron + GC      │
                                                    └──────────────────────────────────────┘
```

Extraction sends **only OCR text** to `/extract`; images upload separately to R2. The DeepSeek API key and all secrets live **only** in Worker secrets.

### 5.2 iOS app

- **Tech:** SwiftUI, iOS 17+, SwiftData, Swift Concurrency. `@Observable` view models + a service layer; no third-party reactive framework. Reuse `ReceiptScanner.swift` (VisionKit `VNDocumentCameraViewController` + `VNRecognizeTextRequest`) for capture + OCR.
- **Modules (suggested Swift packages / folders):**
  - `DesignSystem` — tokens, fonts, `Icon` (vector paths from `theme.jsx` ICONS), primitives (`Card`, `IconCircle`, `Chip`, `Progress`, `Segmented`, `Donut`, `BarPair`, `EmptyArt`), the raised-center `TabBar`, bottom sheets, animations. (§6)
  - `Model` — SwiftData `@Model` types mirroring D1 (§7), the `OutboxMutation` model, AU tax helpers, AUD/date formatters (`fmt`, `fmtK`, `fmtDate` ports).
  - `Sync` — `SyncEngine` (push/pull), `APIClient`, `Keychain` wrapper, reachability/offline state. (§8)
  - `Capture` — `ReceiptScanner.swift` (kept), capture flow state machine, `/extract` client.
  - `Features/*` — one module per tab + overlays (Home, Activity, Reports, Profile, Capture, AddProfile, Settings pages, Logbooks, Quote, Manual, Loyalty, Auth/Onboarding, Notifications).
  - `App` — root, routing, environment (active profile → accent), permission priming.
- **Routing:** matches the prototype's overlay model — a root `TabView`-equivalent (5 tabs, custom raised tab bar) hosting tab screens, with full-screen covers / bottom sheets for overlays (capture, alerts, profile picker, add-profile, categories, tax, banks, mileage, wfh, quote, manual, loyalty, profile-detail, txn-detail, export). The center Snap button always opens Capture and does **not** change tab.
- **Theming:** active profile palette → `--accent/-soft/-deep` equivalents injected via the SwiftUI environment; switching profile re-keys the screen so the enter animation replays.

### 5.3 Cloudflare backend

Single Worker `snapceipt-api` (Hono router). Bindings (verified, `extracted/backend.md`): D1 `DB`, R2 `RECEIPTS`, Workers AI `AI`, Email Send `EMAIL` (`send_email`, restricted sender addresses), KV `MAGIC_TOKENS`/rate-limit, secrets `DEEPSEEK_API_KEY`, `JWT_SIGNING_KEY`, `APPLE_BUNDLE_ID`, APNs auth key (`.p8`), R2 S3 keys (only for accountant presigned links). `wrangler.jsonc` (JSON config), `wrangler types` for `Env`, `nodejs_compat`, `observability.enabled`, `triggers.crons` for the budget-push + GC cron. Exports `{ fetch, email, scheduled }`.

Two hostnames: **`snapceipt.app`** (sending identity + Universal Links) and **`in.snapceipt.app`** (inbound email-in, isolated reputation). See §11 for DNS/SPF/DKIM/DMARC.

---

## 6. Design system

Full token/primitive/animation detail: `extracted/screens.md` ("iOS Device Frame + Design System" section) and `theme.jsx`. Summary:

### 6.1 Color tokens (hex)
`cream #FBF6F0`, `paper #FFFFFF`, `paper-2 #F6EEE4`, `ink #211C18`, `ink-2 #6B6258`, `ink-3 #A99F93`, `line #ECE3D8`, `line-2 #F3EBE1`. Personal `#E8602C / #FDEBE0 / #C2461A`; Business `#0E7C72 / #DCF0ED / #0A5950`; `income #1F9D6B / #DEF3E9`; `alert #D6452B`. `accent/-soft/-deep` = active profile `palette[0/1/2]` at runtime. Category tints (9) and the 8 `AP_ACCENTS` palettes are in `theme.jsx`.

### 6.2 Typography
Bundle **Schibsted Grotesk** (`--display`: numbers, headings, initials; tabular figures via `.monospacedDigit()`, tracking ≈ −0.01em; weights 400–800) and **Hanken Grotesk** (`--ui`: all body/UI; 400–700). Apply tabular figures to every numeric.

### 6.3 Radii & shadows
`r-card 22`, `r-inner 16`, `r-chip 12`, pills/circles 999 (ad-hoc 14/15/17/18 on some buttons). `sh-card`, `sh-pop`, `sh-fab` (accent-tinted) per `theme.jsx`.

### 6.4 Icons
~60 line icons on a 24-grid (`theme.jsx` `ICONS`). Render as SwiftUI `Shape`/`Path` from the exact `d` strings (default stroke width 1.85, round caps/joins) for pixel fidelity. Active tab item bumps stroke to 2.1.

### 6.5 Primitives & animations
`Card, IconCircle, Chip, Progress, Segmented` (sliding thumb), `Donut` (SVG arcs, −90° start, 3px gaps, rounded caps), `BarPair`, `EmptyArt`, raised-center `TabBar` (frosted, blur(18) saturate(180), center FAB 58×58 r20 raised −26, 3px cream ring, `sh-fab`). Animations: `sc-fade-up`, `sc-fade`, `sc-scan`, `sc-pop-in`, `sc-shimmer`, `sc-pulse`, `sc-check`, `sc-ring`, `sc-spin`, `sc-rise`, `sc-confetti` (map cubic-bezier `(.22,.61,.36,1)` → `Animation.timingCurve(0.22,0.61,0.36,1)`).

### 6.6 Fixed production values (Tweaks panel dropped, D8)
`snapStyle = feature`, `toggleStyle = segmented`, icon weight regular (1.85). Profiles are a **real SwiftData list (1..n)**, not a fixed count; profile switcher uses the **header dropdown → ProfilePickerSheet** pattern (the landed design). Default startup profile = the user's default/first profile (Personal-type on a fresh account). Accent palettes come from the 8 `AP_ACCENTS`. The device-frame chrome (bezel, status bar, island, home indicator) is **OS-provided** — honor safe-area insets (~59pt top, ~34pt bottom), do not draw it.

---

## 7. Data model

Authoritative schema: `extracted/backend.md` §"D1 Schema". SwiftData mirrors it 1:1 (same fields + the shared sync envelope). Conventions: `id` = client-generated **UUIDv7** (sortable, offline-safe); **money = INTEGER cents** + ISO-4217 `currency` (never float); timestamps = epoch ms (UTC); calendar dates = `'YYYY-MM-DD'`; booleans = 0/1; enums = `CHECK(... IN ...)`. Every domain row carries `user_id` (tenant boundary) and, where applicable, `profile_id` (UI sub-scope). **The Worker scopes every query `WHERE user_id = :authedUser`** and never trusts a client `profile_id` alone.

**Tables:** `users`, `auth_identities`, `email_tokens` (server-only), `devices` (APNs + per-device sync cursor), `profiles` (name, type, initials, accent_1/2/3, abn, gst_registered, is_default), `categories` (9 seeds, per-user editable), `smart_rules` (matcher→category/deductible), `transactions` (+ `cat_key`, `month_key` generated, `mode`, `gst_cents`, `deductible_pct`, `source`, `extraction_status`, `mileage_trip_id`), `line_items`, `receipt_images` (R2 keys + `ocr_text` + `extraction_json`), `budgets` (cap_cents, alert_threshold_pct, `alert_sent_at`; spent computed), `loyalty_cards` (+ `barcode_format`, color_1/2), `mileage_trips` (metres, `auto_tracked=0` in v1), `wfh_logs` (minutes, `rate_cents_per_hour`), `quotes` + `quote_line_items` (server-recomputed totals), `tax_settings` (per profile: `gst_rate_bps=1000`, `financial_year_start_month=7`, `meals_deductible_pct=50`, `wfh_rate_cents_per_hour=67`, `mileage_rate_cents_per_km=88`), `email_outbox` (server-only), `mutation_queue` (idempotency log; mirrors the on-device outbox).

**Sync columns on every synced table:** `id, user_id, created_at, updated_at` (server-stamped, the cursor + LWW key), `deleted_at` (tombstone). Indexing backbone: `ix_<t>_user_updated(user_id, updated_at)` per table + partial `WHERE deleted_at IS NULL` read indexes by `profile_id`. **Open model questions** (categories/rules per-profile vs per-user; loyalty number at-rest encryption; rate snapshot vs derive; personal-profile tax_settings) are listed in §21.

---

## 8. Sync protocol (local-first)

Authoritative: `extracted/backend.md` §"Worker API + Local-First Sync". Principle: every user-visible mutation **(1)** writes to SwiftData synchronously and **(2)** appends an `OutboxMutation` (stable `mutationId` idempotency key, `op`, full snapshot for upsert / id for delete, `baseRev`). A background `SyncEngine` drains the queue (push) and applies server deltas (pull); the UI never blocks on network.

- **Push** `POST /v1/sync/push` — batch ≤ 200 mutations. Server per mutation: idempotency check (`processed_mutations`, 30-day TTL) → ownership check → **LWW** on `updatedAt` (server stamps monotonic server-time on accept; client time is a tiebreak; `id` final tiebreak) → tombstone on delete. Returns per-mutation `applied|conflict|duplicate|rejected` + server-canonical entity. Client: on applied/duplicate drop outbox row + write back server `rev/updatedAt`; on conflict overwrite local + show "updated elsewhere" toast; on rejected surface error.
- **Pull** `GET /v1/sync/pull?cursor&limit=500` — composite keyset cursor `(updatedAt, id)`; tombstones included. Client applies with LWW vs local, but **keeps local** if an unsynced newer outbox edit exists for that id; persists `nextCursor` only after the whole page commits (crash-safe); loops until `hasMore=false`.
- **Children** (`line_items`, `quote_line_items`) are owned by their parent and replaced wholesale on parent change (no per-item conflict).
- **GC (must build):** a scheduled Worker job purges tombstones + `processed_mutations` older than the **oldest device cursor** for that user; R2 objects for tombstoned receipts are reclaimed only after the delete has synced to all devices (grace ≥ 30 days).
- **Sync-status UI:** §15.

---

## 9. Auth & onboarding (new)

Authoritative: `extracted/backend.md` §"Auth". **Token model:** app-issued JWT access token (15 min) + opaque rotating refresh token (60-day sliding, reuse-detection revokes the session family), both in **Keychain** (`kSecAttrAccessibleAfterFirstUnlock`, access group for a future share extension). Every session is bound to a `deviceId` (Keychain-persisted UUID; registers APNs token).

- **Sign in with Apple** — client sends `identityToken + authorizationCode + rawNonce`; server fetches Apple JWKS (cached in KV), verifies signature/`iss`/`aud`(bundle id)/`exp`/`sha256(nonce)`, upserts `users` by Apple `sub`. **Persist name/email on first authorization** (Apple only sends them once) — if missing, collect in onboarding.
- **Email magic-link** — `POST /v1/auth/magic-link/request {email}` stores `sha256(token)` in KV (10-min TTL, single-use), sends a Universal Link `https://snapceipt.app/auth/verify?token=…` + 6-digit OTP fallback (always 202, no enumeration; rate-limited 3/email/hr, 10/IP/hr). `…/verify {token}` consumes single-use, issues a session.

**Screens (new):** Launch/splash → **Sign-in** (Apple button + "Continue with email") → magic-link **"Check your email"** waiting → **verify/landing** (deep-link success / expired-or-invalid error with resend) → **Onboarding**: create first profile (reuse AddProfileScreen, §12.5), prime **Camera** (before first scan) and **Notifications** (before enabling budget alerts) permissions with rationale. Sign-out: confirm → revoke session → clear Keychain → return to Sign-in. **Magic-link strictness:** same-device-only by default (tighter); confirm in §21.

---

## 10. Extraction pipeline

Authoritative: `extracted/backend.md` §"Extraction Pipeline". **One extractor for both paths.**

- **App path:** `ReceiptScanner.swift` does VisionKit capture + Vision OCR on-device → `POST /v1/extract { ocrText, source:'ios_vision', defaultCurrency:'AUD', locale:'en-AU', capturedAt, requestId }`.
- **Email-in path:** Email Routing → `email()` handler → Workers AI vision OCR (`@cf/meta/llama-3.2-11b-vision-instruct`, image as byte array, `max_tokens` raised to ~1024–2048) → same extractor with `source:'email_workers_ai'`.
- **DeepSeek call:** `POST https://api.deepseek.com/chat/completions`, model `deepseek-v4-flash`, `response_format:{type:'json_object'}`, `temperature:0`, `max_tokens:1500`, `Authorization: Bearer <secret>`. The word "json" appears in the system prompt (JSON-mode requirement). Exact verbatim system + user prompts are in `extracted/backend.md` §2 — adopt them, **with the category enum replaced by the design's 9 keys** (§3.8).
- **Response (`/extract`):** `{ requestId, receipt: { merchant, date (YYYY-MM-DD), currencyCode (default AUD), total, tax|null, gst|null, category (one of the 9), deductible 0–100|null, lineItems:[{name,price}], confidence, needsReview }, meta:{ model, ocrModel?, source, latencyMs, attempts, reviewReasons[], fieldConfidence? } }`.
- **Validation + retry ladder (mandatory):** JSON mode guarantees syntactic JSON, **not** schema conformance, and can return empty content — so the Worker runs a strict validator and a ≤3-attempt retry ladder (corrective reprompt → fence-strip/largest-`{…}` → safe fallback receipt with `needsReview:true, reviewReasons:['extraction_failed']`). 20s hard timeout; transient 5xx/429 backoff.
- **Confidence / needsReview (Worker-computed, not blind model self-grade):** `finalConfidence = clamp(0.55·model + 0.25·ocr + 0.20·arithmeticConsistency)`. `needsReview` true on low confidence, missing/zero total, guessed date, `foreign_currency`, no line items on a multi-line receipt, totals-don't-reconcile, unknown merchant; `gst_inferred` is informational. **The "98% match" hero** shows `round(finalConfidence·100)` (capped at 99%) only when model+OCR+arithmetic agree — making the moment trustworthy. `needsReview` opens the editable Review screen with flagged fields highlighted (§12.3).
- **GST:** prefer printed; infer `round(total/11,2)` only for AUD taxable with no printed GST; `null` for GST-free/foreign (§14).
- **Security/cost:** key server-only; `ocrText` ≤ 50k chars; rate-limit `/extract` per device; don't log raw OCR/responses (log `requestId` + metrics); flash tier ≈ fractions of a cent/extract; Workers AI metered in Neurons (email path only).

---

## 11. Email & R2

Authoritative: `extracted/backend.md` §"Email + R2".

- **Email Send (`env.EMAIL`, restricted senders `no-reply@`/`accounts@`/`exports@snapceipt.app`):** magic-link sign-in; **send-to-accountant** export (CSV + PDF attachments, ≤ 25 MiB, `replyTo: user.email`). Transactional only — no marketing/digest. Onboard via `wrangler email sending enable snapceipt.app` (auto SPF + DKIM); add DMARC manually (ramp `p=none`→`quarantine`→`reject`, `adkim=s; aspf=s`).
- **Email Routing (email-in):** per-user opaque inbox token `r.<inboxId>@in.snapceipt.app` (catch-all → `email()`). Handler: resolve user by token (reject unknown / no-image to bound AI spend) → buffer raw once → parse MIME (`postal-mime`) → store original in R2 → Workers AI vision OCR → DeepSeek extractor → create transaction (`source:'email_in'`; failed extraction still creates a reviewable stub) → push notify → async thumbnail. Idempotent on `Message-ID`. SPF/DKIM/DMARC on the isolated inbound subdomain; per-inbox rate limit; rotatable token.
- **R2 (`snapceipt-receipts`):** keys `<userId>/receipts/<receiptId>/original.<ext>`, `…/thumb.jpg`, `<userId>/exports/<exportId>.pdf`. In-app viewing via **Worker-proxy** (`GET /v1/images/...`, session-authorized by user-prefix); accountant links via **presigned GET** (≤ 7-day max TTL — note expiry in the CSV + provide in-app **re-share**). Lifecycle: exports expire 7 days; tombstoned-receipt objects GC'd after the delete syncs to all devices (≥ 30-day grace). **ATO substantiation:** retain original receipt image/PDF as tax evidence (target ~5 years) — confirm in §21 before building eager deletion.

---

## 12. Screens & flows

Every screen below has exhaustive pixel detail in `extracted/screens.md`. This section states purpose, key behavior, **resolved decisions**, and required states. Mode-aware = re-skin to active profile accent. All lists get loading skeletons + empty states (§15) and read by **`profileId`** (§3.1).

### 12.1 Tab bar & shell
5 tabs — **Home, Activity, Snap (center FAB), Reports, Profile** — frosted raised bar (§6.5). Snap opens Capture (never switches tab). Switching tab/profile re-keys the screen (replays `sc-fade-up`).

### 12.2 Home (Dashboard)
Profile-switcher header (avatar + "ACTIVE PROFILE" + name + chevron → ProfilePickerSheet; bell → AlertsSheet), accent-gradient **Net this month** summary card (income/expense/net for the **active profile**), dark **Snap CTA** (`feature` variant), **mode-aware quick actions** (Personal: Loyalty · Add Manually · Mileage · WFH; Business: Create Quote · Add Manually · Reports · Receipts), a tracker card (Personal: **Monthly budgets** with working **Edit** → budget editor §12.6; Business: **Deductible · FY** tracker derived from real txn `deductible`/`gst`), and recent activity (4 rows → TxnDetail; "See all" → Activity). Identity & all figures are **data-bound** (not hardcoded). Empty state: zeroed summary + `EmptyArt` recent card.

### 12.3 Capture flow (centerpiece)
Stage machine **camera → scan → review → saved** over a full-screen cover. Camera = VisionKit (reuse `ReceiptScanner.swift`); flash/gallery/import wired (torch, photo picker, file import). **Scan** stage's field-reveal is driven by real OCR + `/extract` progress (falling back to the ~360ms staggered animation if the call returns fast); scan-line + per-field spinner→check chips (Merchant, Date, GST, Total, Category). **Review** = the **shared editable form** (§3.3, §12.4): editable merchant/date(picker)/category(picker)/amount/GST(with inferred-vs-printed flag)/deductible %/payment/note + **Assign to profile** (ModeToggle) + "Add to mileage"/"Match to bank" chips rendered as **"Coming soon"** (§3.9). AI banner + **"98% match"** (real `finalConfidence`, §10). **needsReview** variant highlights flagged fields. Save = local-first write + offline queue → **Saved** (confetti + drawn check). **Error/offline states (new):** OCR/extract failure → retry; offline → save locally + queue + inform. The hero green check/ring stays `income` green in both modes.

### 12.4 Activity + TxnDetail + Edit
Search (merchant/category), All/Expenses/Income chips, **month picker** (part of the shared period model §3.16), date-grouped list (Today/Yesterday/weekday), count + net header. Empty state via `EmptyArt` + "Snap a receipt". **TxnDetail:** hero (category icon, signed amount, mode + AI pills), metadata rows (category/date/payment/GST/tax note/deductible), receipt thumbnail (expenses; tap → full-image viewer via R2 proxy), **Edit** (→ shared editable form §3.3) and **Delete** (confirm → tombstone → undo toast). GST row shows `$0.00` when 0 (distinct from null).

### 12.5 Profile + AddProfile + ProfileDetail
**Profile hub:** data-bound identity (no hardcoded user; "Pro" hidden in v1 §3.15), dynamic profile-switcher grid (tap card → ProfileDetail; "Add another profile" → AddProfile), settings groups: **Capture & tax** (AI auto-categorise toggle, Categories & rules, Tax & GST, Connected banks [placeholder]) and **App** (Notifications & alerts → §12.8, Export & backup → §12.7, Privacy & security [Face ID/biometric lock], Help & support), **Sign out** (wired, §9). **AddProfile:** two-step (form → success) with live preview, Personal/Business type, conditional Business fields (Business name, **ABN**, **GST** toggle — *persist abn+gst*, fixing the prototype's drop), 8-swatch accent picker, optimistic local-first create. **ProfileDetail:** per-profile hero (uses the profile's own palette), "Switch to this profile", editable details, per-profile stats (real counts), Manage (Export this profile → §12.7; **Delete profile** → confirm dialog).

### 12.6 Budgets (real, new CRUD)
List/editor reachable from Home "Edit" and Profile. Per budget: scope (category or whole-profile), **cap**, period (monthly; FY optional), **alert threshold %** (drives push). Spent is computed from transactions for the period (never stored). Over-cap → `alert` styling + push (§12.8). Empty/first-budget state. Home tracker rows bind to these.

### 12.7 Reports + Export / Send-to-accountant
Reports: shared **period control** (Month/Quarter/FY — recomputes data, AU FY boundaries §3.16), income-vs-expense `BarPair`, category `Donut` + legend, **Business-only** tax StatPills (Deductible YTD, GST on purchases — computed from real txns) + Logbook rows (→ Mileage/WFH), **Personal-only** under-budget card, always an AI insight card. **Export sheet:** PDF / CSV / **To accountant**. Real generation: CSV (AU bookkeeping header incl. GST + deductible + signed receipt URL), PDF summary, both ≤ 25 MiB. **To accountant (new flow §3.13):** recipient entry + saved address book, date-range/profile scope, **in-progress/success/error** states, **send history**, **re-share** for expired (7-day) links. Generated via Worker + Email Send.

### 12.8 Notifications & Alerts (new)
**AlertsSheet** becomes data-bound: read/unread persistence, per-item tap deep-link, dismiss, empty state. **Notifications settings screen:** APNs permission priming; per-type push vs in-app (budget thresholds on by default; optional **BAS-due reminder**; auto-sort confirmations in-app); quiet hours. **Push pipeline:** Worker `scheduled` cron + on-write recompute of profile spend vs budget cap; threshold crossings fire **APNs** (p8 JWT signed in-Worker), idempotent per `(budgetId, threshold, period)` via `alert_sent_at`; tapping a push deep-links to the relevant screen. **No emailed reminders** (§3.5).

### 12.9 Loyalty (wallet + add + detail) — real barcodes
**Wallet:** branded cards (gradient, points pill, **real** mini barcode, member number), "Add a card", auto-match hint, **empty state (new)**. **Add a card:** dark **Scan** CTA (VisionKit/Vision barcode detection → captures number **and symbology**), brand search + "Popular in Australia" grid (catalog-backed), conditional number field, success. **Detail:** immersive brand-color full-screen, **large high-contrast scannable barcode** (generate the correct symbology from `barcode_format` + number via CoreImage/`CIBarcodeGenerator` or a barcode lib for EAN/QR; **number-only fallback** when unsupported), member number, **screen-brightness boost** on appear (restore on disappear), Share/Done. Store `barcode_format` (§3.14).

### 12.10 Manual entry (new date picker), Quote, Logbooks, Settings pages, Email-in
- **Add manually:** Expense/Income toggle (income tint = green), amount-first keypad (cents Int, cap $99,999.99), category chips (own brand colors; income = single category), merchant/source, **date row → real DatePicker** (defaults Today; prototype hardcoded), Save (enabled on amount>0) → success. Stores negative=expense / positive=income; GST = `gross − gross/1.1` (AU 10%, income exempt). **Add a profile/mode selector** so a Business expense can be added while a Personal profile is active (resolves the mode-inheritance gap).
- **Create Quote (Business):** bill-to **client picker** (saved clients store), **inline-editable** line items (desc/qty/price; the prototype's rows are static — make them editable), GST 10% toggle, live totals (server-recomputed on save), **server-authoritative quote number** (avoid offline duplicate `SN-####`), draft/sent **status + history**, **Send** (PDF emailed via Email Send) with sending/success/error states; accepted quotes can convert to invoice (model the path; invoice UI may be a later phase).
- **Mileage logbook:** real manual trips (from/to/purpose/km/date/business), hero stats computed (ATO cents-per-km or logbook method), trips list, **GPS auto-track toggle = "Coming soon" placeholder** (§3.9), "Add a trip" form, empty state.
- **WFH log:** real manual entries (date/hours/note), 67c/hr fixed-rate claim, this-week bar chart, logged-days list, fixed-rate explainer, "Log hours" form, empty state.
- **Categories & rules:** real smart-rules CRUD (matcher → category/deductible), category list with **derived** counts, new-category/new-rule flows (prototype's + and rows are inert).
- **Tax & GST settings:** bound to `tax_settings` per profile — summary (deductible YTD, GST on purchases), Business identity (ABN, entity type, GST-registered, accounting basis), Financial year (FY, BAS period, next BAS due), deduction defaults (meals 50%, vehicle method, WFH 67c/hr). Personal profiles hide ABN/GST identity (resolves the per-profile tax contradiction; confirm §21).
- **Connected banks:** **placeholder** — reconcile banner + linked accounts + auto-import toggles render as "Coming soon"; no network; `/banks` returns 501.
- **Email-in surface (new §3.12):** a settings row shows the personal inbound address with copy/share/**rotate**; a **review queue** for email-in receipts (esp. `extraction_status='failed'`).

---

## 13. Identity & scoping model (critical)

Restating §3.1 because it touches every data read: **partition all domain data by `profileId`.** `mode` is derived (`activeProfile.type`) and only selects accent + the mode-aware quick-action set. Home/Activity/Reports/budgets/deductible/quotes/logbooks all filter `WHERE profileId == activeProfileId`. The Worker additionally enforces `WHERE user_id = :authedUser`. This prevents commingling for users with multiple business profiles.

---

## 14. AU tax logic

- **GST 10%** stored per transaction (`gst_cents`). Prefer printed GST; infer `round(total/11,2)` only for AUD taxable with no printed GST and **flag** it (`gst_inferred`); `null`/0 for GST-free (fresh food) / mixed baskets / foreign — surfaced in the review UI (§10, §3.6). Manual entry extracts `gross − gross/1.1`.
- **Tax-deductible %** per transaction (0–100); defaults pre-filled by category/smart-rule (meals 50%, software/tools 100%, etc.) but always editable per receipt.
- **Financial year = 1 Jul – 30 Jun** (`financial_year_start_month = 7`). Drives Reports/Export/deductible YTD and BAS scheduling. Shared period model (§3.16).
- **Mileage** = ATO cents-per-km (default 88c, `tax_settings`) or logbook method; **WFH** = fixed rate 67c/hr. Rates stored in `tax_settings`; decide snapshot-vs-derive in §21.
- **Currency = AUD** (§3.7). Foreign receipts flagged + excluded from aggregates.

---

## 15. Cross-cutting UI (new)

Global **toast/banner system**; **sync-status** indicator (idle/syncing/offline/error); **offline banner**; **"pending upload"** badge on queued items; **"updated elsewhere"** LWW toast; **loading skeletons** (`sc-shimmer`) on every list reading from SwiftData/cloud; capture **extract-failure retry**; export/quote **send-failure retry**; consistent **error envelope** handling (`AUTH_*`, `VALIDATION_FAILED`, `RATE_LIMITED`, `NOT_IMPLEMENTED`, etc.) mapped to user-friendly messages. **First-run empty states** for every screen are designed, not incidental.

---

## 16. Real vs placeholder (v1)

| Feature | v1 status |
|---|---|
| Snap → OCR → DeepSeek extract → review → save | **Real** |
| Email-in receipts (Workers AI OCR → DeepSeek) | **Real** |
| Accounts + cloud sync (SIWA + magic-link, D1/R2) | **Real** |
| Budgets + push alerts (APNs) | **Real** |
| Loyalty cards + scannable barcodes | **Real** |
| Manual entry, Categories & rules, Tax & GST settings | **Real** |
| Quotes (compose + email; invoice convert may be later) | **Real (core)** |
| Mileage *trips* / WFH *logs* (manual) + claims | **Real** |
| Reports + Export (PDF/CSV) + send-to-accountant | **Real** |
| **GPS mileage auto-track** | **Placeholder** (toggle = "Coming soon", no GPS) |
| **Connected banks / reconcile** | **Placeholder** (UI only, `/banks`=501) |
| Capture "Add to mileage" / "Match to bank" chips | **Placeholder** ("Coming soon") |
| Multi-currency / FX | **Out of scope** |
| Monetization / Pro paywall | **Out of scope** |
| OS dark mode | **Out of scope (later)** |

---

## 17. Phasing (whole-app spec, phased build)

- **P0 — Foundations:** DesignSystem (tokens/fonts/icons/primitives/tab bar/animations); SwiftData model + sync envelope; `SyncEngine` + `APIClient` + Keychain + OutboxQueue; **Auth + onboarding** (SIWA + magic-link); Worker skeleton (Hono, D1 migrations, R2, KV, wrangler) + `/auth` + `/sync/push|pull`; profiles CRUD + switcher; cross-cutting toast/sync-status (§15).
- **P1 — Core loop:** Capture (reuse `ReceiptScanner.swift`) → `/extract` (DeepSeek) → shared editable Review → save; Activity + TxnDetail + Edit/Delete; Home; image upload + R2 proxy.
- **P2 — Reports & tax & export:** Reports (shared period model, charts, AU tax stats); Tax & GST settings; Export PDF/CSV + **send-to-accountant** (Email Send).
- **P3 — Productivity:** Manual entry (date picker); Categories & rules; **Budgets CRUD + push alerts** (APNs cron); **Loyalty** (real barcodes); Quotes (client picker, editable items, send).
- **P4 — Placeholders & inbound:** Mileage (manual) + WFH; honest placeholders (GPS auto, Connected banks); **email-in receipts** (Email Routing + Workers AI) + review queue; AlertsSheet data-binding + notification settings; account settings (devices, delete account); GC + R2 lifecycle jobs.

Each phase ends shippable; P0–P1 deliver the demoable core.

---

## 18. Testing strategy

- **Swift unit tests:** extraction→model mapping, AU GST/deductible/FY math, AUD/date formatters (`fmt`/`fmtK`/`fmtDate`, U+2212 minus), `SyncEngine` (LWW, tombstones, idempotent replay, offline queue drain, conflict overwrite + keep-local-newer), keypad cents model, budget spend computation.
- **Worker tests** (Vitest + Workers pool / Miniflare): `/auth` (Apple JWKS verify, magic-link single-use), `/sync/push|pull` (LWW, cursor paging, idempotency), `/extract` contract against a **mocked DeepSeek** (valid/invalid-JSON/empty-content → retry ladder → safe fallback), category-enum conformance, tenant scoping (`user_id`), rate limits, `/banks` 501.
- **Integration:** email-in `email()` handler (mock MIME + mocked Workers AI), export generate+email (note: binary attachments need a deployed env to fully validate), presigned URL expiry.
- **UI/snapshot:** key screens (Home, Capture stages, Activity, Reports, Profile, Loyalty detail barcode) against the design; empty/loading/error states; accent re-skin on profile switch.
- **Manual device QA:** real-camera capture + on-device OCR; barcode scannability at a POS; push delivery; Universal Link magic-link.

---

## 19. Risks & mitigations

(Full list: `extracted/critic.md` + `backend.md`.) Top risks:
1. **External dep verification** — DeepSeek model string/JSON-mode/retry, Workers AI image format + `max_tokens`, **Cloudflare Email Send beta** enablement + domain + SPF/DKIM/DMARC (auth is on the critical path — pick a fallback provider e.g. Resend/Postmark), APNs p8 JWT signing in-Worker. → **§20 pre-impl checklist.**
2. **LWW silent loss** on concurrent offline edits to one record (higher-stakes for tax data) → accepted for v1 + "updated elsewhere" toast; revisit field-level merge later.
3. **GST over-estimation** on inferred/mixed baskets → prefer printed, flag inferred, force review.
4. **Workers AI vision OCR quality** (general-purpose model; PDFs need rasterization) → isolated to email-in; clean-attachment guidance + fallback to reviewable stub; on-device Vision unaffected.
5. **ATO substantiation/retention** → retain originals ~5y; don't eager-delete before confirming (§21).
6. **Tombstone/R2 GC unbounded growth** → build the GC + min-device-cursor job (P4).
7. **Cold-pull at scale** → keyset `(updatedAt,id)` indexes + pagination; verify D1 limits.
8. **SIWA first-response data loss** → persist name/email on first auth; onboarding fallback to collect manually.
9. **Loyalty barcode feasibility** → capture symbology; number-only fallback.
10. **Presigned-link/inbound-token abuse** → 7-day cap + re-share; per-inbox rate limit + rotation.

## 20. Pre-implementation verification checklist (do before coding the dependent piece)

- [ ] DeepSeek: confirm live model id `deepseek-v4-flash`, base URL, auth header, `json_object` behavior + empty-content retry. (`deepseek-chat/reasoner` deprecate 2026-07-24 — pin model in config.)
- [ ] Workers AI: confirm `@cf/meta/llama-3.2-11b-vision-instruct` image input shape (byte-array vs base64), `max_tokens`, current Neuron pricing; decide PDF rasterization.
- [ ] Cloudflare Email Send: confirm account beta enablement + `snapceipt.app` verified (SPF/DKIM); add DMARC; **choose fallback provider** (auth-critical).
- [ ] Email Routing: enable on `in.snapceipt.app` (MX/SPF), catch-all → Worker; pick inbox scheme.
- [ ] APNs: p8 auth key as secret; verify JWT signing under Workers crypto; permission-denied → in-app-only fallback.
- [ ] R2: confirm presigned PUT/GET via `aws4fetch` (sign host only), 7-day max; Worker-proxy for in-app.
- [ ] Apple: Sign in with Apple capability, bundle id, JWKS caching, Universal Links AASA at `/.well-known/apple-app-site-association`.
- [ ] ATO substantiation retention period for receipt images/PDFs (legal) before setting R2 lifecycle.

## 21. Open questions (recommended defaults in **bold**)

1. Categories/smart-rules: per-profile or per-user? → **per-user, shared across profiles** (matches prototype's 9 user-level categories); rules can optionally scope to a profile.
2. Personal-profile `tax_settings`: needed? → **Business-only tax identity; personal profiles hide ABN/GST** but may keep GST=off settings row hidden.
3. Quote numbering: → **server-authoritative sequence per user** (avoids offline duplicates).
4. Loyalty number at-rest encryption: → **app-layer encryption deferred; rely on D1 + Keychain device cache** for v1 (revisit).
5. WFH/mileage rate: snapshot on each entry vs derive? → **snapshot the rate + cache claim on the entry** (preserves historical FY rates).
6. Magic-link strictness: same-device only vs any-device? → **same-device only** (tighter; OTP fallback covers edge cases).
7. Email-in failed extraction: create reviewable txn stub vs image-only? → **create a reviewable stub (`extraction_status='failed'`)** so nothing is lost.
8. Email-in: one receipt per email or per attachment? → **first image per email in v1** (log if others dropped).
9. Accountant export PDFs: retain in R2 or ephemeral? → **ephemeral per request + re-share regenerates** (avoid storing 3rd-party-shareable financial data at rest).
10. Default `deductible` when model returns null: per-category baseline vs force user input? → **per-category baseline from smart-rules/tax defaults**, editable.

## 22. References

- Pixel-level screen specs: [`extracted/screens.md`](./extracted/screens.md)
- Backend (D1 schema, Worker API + sync, extraction contract, email + R2): [`extracted/backend.md`](./extracted/backend.md)
- Completeness critic (gaps/contradictions/risks/recommendations): [`extracted/critic.md`](./extracted/critic.md)
- Raw structured analysis: [`extracted/_raw-result.json`](./extracted/_raw-result.json)
- Design handoff bundle (HTML/JSX prototype, chat transcript, screenshots): `design-ref/snapceipt/`
- Existing capture code to reuse: `ReceiptScanner.swift`
