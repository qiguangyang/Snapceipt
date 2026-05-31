# Budgets + Push (APNs) — Design Spec

- **Status:** Approved (brainstorm) — proceeding to implementation plan(s)
- **Date:** 2026-06-01
- **Branch:** `foundation`
- **Feature:** F3 of the remaining-features roadmap (`docs/superpowers/specs/2026-05-31-snapceipt-remaining-features-roadmap.md`).
- **Builds on:** foundation + capture (F0) + F1 Logbooks + F2 Reports. iOS (`Snapceipt/`), Cloudflare backend (`src/`, `migrations/`, `test/`, `e2e/`). Design reference: `docs/superpowers/specs/extracted/screens.md` (Home budget tracker ~lines 36–44, AlertsSheet ~line 113/1475) and `2026-05-30-snapceipt-ios-app-design.md` §3.5, §12.2, §12.6, §12.8, §16; backend push at `extracted/backend.md` §2–4, §8.
- **Baselines to keep green:** backend `npm test` 237 / `npm run test:e2e` 12 + typecheck; iOS `xcodebuild -only-testing:SnapceiptTests` 225 + `SnapceiptUITests`.

---

## 1. Goal

Make budgets real and alert the user when spending nears a cap — real budget CRUD, a Home tracker bound to those budgets, an hourly Worker cron that fires **APNs** push when a budget crosses its alert threshold, a data-bound AlertsSheet, and a Notifications settings screen (push on/off, quiet hours, a BAS-reminder placeholder). AUD-only.

## 2. Decisions locked in brainstorming

1. **Alert feed = derived + local cache.** No `alert` entity, no server alert table. The AlertsSheet feed is computed on-device from budgets whose `alertSentAt` is in the current month (+ live spend); read/unread + dismissed IDs live in a UserDefaults-backed local cache (per-device, not synced).
2. **Quiet hours = enforced; BAS reminder = placeholder.** The cron suppresses pushes during a per-device quiet window (stored on `devices` + device IANA timezone). The BAS-due reminder is a persisted UI toggle with **no backend logic** in v1.
3. **Push trigger = the hourly cron only** (no on-write hook in the sync hot path).
4. **APNs is real but gated** behind an `APNS_KEY` stub seam (the `.p8` isn't provisioned) — buildable + unit-testable now; activates when the key is added.
5. **Budgets are monthly-only**; spend is always computed (never stored); whole-profile and per-category budgets coexist and are computed independently.
6. **Notifications settings screen only** — the full Profile/Settings hub is F7. F3 adds lightweight "Notifications & alerts" + "Budgets" entry rows on the Profile tab.
7. **Home tracker = the active profile's top-3 monthly budgets**, both modes (the design's Business "Deductible · FY26" framing is simplified to the monthly tracker; FY deductible tracking lives in Reports/F2).
8. **Enable the F2 Personal under-budget card** now that budgets exist.

**Reuse (already shipped):** the `Budget` @Model + `budgets` table (synced; cap, category-or-whole-profile, `alertThresholdPct`, `alertSentAt`); the `devices` table (`apns_token`, `push_enabled`) + `PUT /devices/me`; APNs permission priming (onboarding); `Period`, `TransactionQuery.byCategory`, `ProgressBar`/`Card`/`Segmented`/`IconCircle`, the Router + `.sheet(item:)` mechanism, `AuthStore.deviceId`.

## 3. Architecture

Budget CRUD is local-first through the **existing** `/sync/push`+`/sync/pull` (no new budget routes). The new networked pieces: the **backend `scheduled` cron** (recompute spend → APNs), the **APNs send path**, and **iOS APNs-token registration** (via `PUT /devices/me`). Alerts are **send-only** server-side; the in-app feed is client-derived. Likely two plans (iOS + backend) under §4 (authoritative).

## 4. Authoritative cross-plan contract

### 4.1 Schema touch — `devices` (the only migration)
Add to the `devices` `CREATE TABLE` (D1) + `PUT /devices/me` + iOS device-update:
| D1 column | wire / iOS | Type | Notes |
|---|---|---|---|
| `quiet_hours_start_min` | `quietHoursStartMin` | INTEGER? | minutes-from-midnight, device-local (0–1439); null = no quiet hours |
| `quiet_hours_end_min` | `quietHoursEndMin` | INTEGER? | minutes-from-midnight, device-local |
| `timezone` | `timezone` | TEXT? | IANA, e.g. `Australia/Sydney` |
`apns_token` + `push_enabled` already exist. **No new synced entities.** `budgets.alertSentAt` already exists (server-set by the cron; surfaced in the budget sync envelope so the client can derive the feed).

### 4.2 `PUT /devices/me` (extended; route exists)
Body adds (all optional): `apnsToken`, `quietHoursStartMin`, `quietHoursEndMin`, `timezone`. Bearer-auth, keyed by the `X-Device-Id` header, scoped to the authed user. Upserts the device row; returns device state.

### 4.3 Budget spend (server + client, identical math)
`spent_cents = SUM(transactions.amount_cents)` magnitude over expenses (`amount_cents < 0`) for `(user_id, profile_id, deleted_at IS NULL, the YYYY-MM prefix of txn_date == target month, AND (budget.category_id IS NULL → all categories | else category_id == budget.category_id))`. (Match on `substr(txn_date,1,7)` — don't assume a `month_key` column on transactions; verify the actual column during planning.) Target month = the current calendar month (UTC) for a recurring budget (`budget.month_key` null), else `budget.month_key`. `spent_pct = spent_cents / cap_cents × 100`. Over cap when `spent_cents > cap_cents`.

### 4.4 Cron + alert semantics (`budgetCronLogic(db, env, nowMs)`)
Hourly. For each live budget: compute spend (§4.3). **Fire** when `spent_cents ≥ cap_cents × alert_threshold_pct / 100` **AND** (`alert_sent_at` is NULL OR its month ≠ the target month). On fire: for each of the user's devices with `push_enabled = 1` and `apns_token` not null, evaluate **quiet hours** (§4.6) — `sendPush` (§4.5) to each device NOT currently quiet. Set `alert_sent_at = nowMs` **only if ≥1 device was actually pushed** (if all were quiet-suppressed, leave it unset → the next hourly run outside quiet hours delivers it). Month rollover re-arms. Dedup is purely `alert_sent_at` (one push per budget per month).

### 4.5 APNs (`src/lib/apns.ts`)
- `signApnsJwt(env)` → `importPKCS8(env.APNS_KEY, "ES256")` + `new SignJWT({ iss: env.APNS_TEAM_ID, iat }).setProtectedHeader({ alg: "ES256", kid: env.APNS_KEY_ID }).sign(key)`; cache the token ~50 min.
- `sendPush(env, apnsToken, payload)`: **if `!env.APNS_KEY` → log + return `{ stub: true }` (no network)**; else `fetch("https://api.push.apple.com/3/device/" + apnsToken, { method:"POST", headers: { authorization: "bearer "+jwt, "apns-topic": env.APPLE_BUNDLE_ID, "apns-push-type": "alert", "apns-priority": "10" }, body })`.
- **Payload:** `{ "aps": { "alert": { "title": "Budget alert", "body": "<label>: <spent> of <cap> (<pct>%)" }, "sound": "default" }, "budgetId": "<id>", "deepLink": "snapceipt://budget/<id>" }`.
- Env: `APNS_KEY?` (.p8 PKCS8 PEM), `APNS_KEY_ID?`, `APNS_TEAM_ID?` (all optional → absence = stub mode); `APPLE_BUNDLE_ID` already exists (the apns-topic). Test seam: `vi.spyOn(apnsModule, "sendPush")` (mirrors the email seam).

### 4.6 Quiet hours
Per-device: `timezone` (IANA) + `[quietHoursStartMin, quietHoursEndMin)` in device-local minutes. The cron computes the device's local minutes-from-midnight from `nowMs` + `timezone` and suppresses if inside the window. **Wrap-around aware:** if `start > end` (e.g. 1320→420 = 22:00–07:00), quiet = `local ≥ start OR local < end`; else `start ≤ local < end`. Null start/end → never quiet.

### 4.7 Alert feed derivation (iOS, client-only)
Feed item per budget where `alertSentAt` ∈ current month AND `spent ≥ threshold`: `{ id: budgetId + "-" + monthKey, title: "Budget alert: <label>", body: "<spent> of <cap> (<pct>%)", firedAt: alertSentAt }`, newest first. Local cache (UserDefaults): `Set<readId>` + `Set<dismissedId>`. Unread = fired-this-month ∧ not read; dismissed → excluded. Deep-link (tap, or a tapped push's `budgetId`) → the budget's editor.

## 5. UI — Budgets (Home tracker + CRUD)
- **Home tracker card** (replaces the `homeStub` placeholder; keeps the profile switcher + QuickActions): title "Monthly budgets" + **Edit** link; the active profile's **top-3 monthly budgets** as **BudgetRows** (label, `spent / cap` via `fmt`, `ProgressBar` accent tint → **`--alert` red over cap**). `spent` via the pure `BudgetSpend` helper (§4.3). Tap row → edit that budget; Edit → `BudgetListView`. Empty state CTA when none.
- **`BudgetListView`** (from Home Edit + the Profile "Budgets" row): the profile's budgets (label, scope, `spent/cap` bar, threshold%), **Add budget** CTA, tap → edit, swipe → soft-delete, empty state.
- **`BudgetEditorView`** (add/edit): **scope** picker (Whole profile | a specific category) → defaults `label`; **cap** amount (→ cents); **alert threshold %** (default 90); period read-only **Monthly**. Save → create/update `Budget` + enqueue sync; Delete when editing.
- Everything scoped by `activeProfileId`; accent-reskinned by profile.

## 6. UI — Push, AlertsSheet, Notifications settings
- **APNs registration** (`NotificationDelegate` via `@UIApplicationDelegateAdaptor`): after permission granted → `registerForRemoteNotifications()`; `didRegister…deviceToken` → hex-encode → persist + `APIClient.updateDevice` (`PUT /devices/me`) with `apnsToken` + device IANA `timezone` + quiet-hours; `didReceive` (tap) → route to the budget via `deepLink`/`budgetId` (mark read); `willPresent` → foreground banner. **Simulator can't issue real tokens — registration fails gracefully; real push is verified via backend unit tests + the stub seam, not the UI test.**
- **`AlertsSheet`** (opened from a **bell** in the Home header with an unread dot): the §4.7 derived feed; row = `IconCircle` + title + relative time + body; tap → deep-link (mark read); swipe → dismiss; `EmptyArt` empty state. Budget-alerts-only in v1.
- **`NotificationsSettingsView`** (from the Profile "Notifications & alerts" row): APNs permission priming (request if undetermined; OS-Settings hint if denied); **Budget alerts** toggle → `devices.push_enabled`; **Quiet hours** two time pickers → minutes + device tz → `PUT /devices/me`; **BAS-due reminder** toggle → placeholder (persists locally, no backend). Any change → `PUT /devices/me`.
- **Profile tab:** F3 adds only the two entry rows ("Notifications & alerts", "Budgets") → the F3 screens; the full Settings hub is F7.
- **Reports (F2) Personal under-budget card** — now enabled: for a Personal profile with budgets, show "You're under budget" + `<Σspent> of <Σcap> used` when `Σspent < Σcap` for the month; hidden when no budgets. (Small addition to `ReportsView`/`ReportsViewModel`.)

## 7. Backend — cron + APNs
- `wrangler.jsonc`: `"triggers": { "crons": ["0 * * * *"] }`.
- `src/index.ts`: `export default { fetch: app.fetch, scheduled }`; `scheduled(event, env, ctx)` → `ctx.waitUntil(budgetCronLogic(env.DB, env, Date.now()))`.
- `src/cron/budgetAlert.ts`: `budgetCronLogic` (§4.3–4.6) — pure-ish, `now` injected.
- `src/lib/apns.ts` (§4.5) + `APNS_*` env (§4.5).
- `PUT /devices/me` extension (§4.2) + the devices migration (§4.1).

## 8. Testing
Keep baselines green; add:
- **Backend unit:** `budgetCronLogic` — spend per budget (per-category vs whole-profile), threshold fire (`sendPush` spied, payload asserted), dedup (same-month `alert_sent_at` → no re-send), month-rollover re-arm, quiet-hours suppression (device in window → suppressed, `alert_sent_at` left unset), `push_enabled`/`apns_token` filtering; `apns.ts` (`signApnsJwt` → ES256 JWT carrying `kid`/`iss`; `sendPush` stub-no-op without `APNS_KEY`); `PUT /devices/me` stores quiet hours + tz + token; migration test (devices new columns).
- **Backend e2e:** budget CRUD + `PUT /devices/me` round-trip (the `scheduled` handler isn't directly invocable in the test runtime — the cron is covered by the pure-function unit tests).
- **iOS unit:** `BudgetSpend` (category vs whole-profile, month scoping); AlertsSheet derivation + local read/unread/dismiss cache; budget editor/list CRUD + sync enqueue; quiet-hours encode + the `PUT /devices/me` payload; deep-link routing; the under-budget-card computation.
- **iOS UI** (hermetic): Home tracker renders seeded budgets (+ over-cap red) → add/edit a budget → tracker updates; open AlertsSheet (seed a budget with `alertSentAt` this month → alert appears) → dismiss; Notifications settings toggle + quiet-hours picker. (No live push — sim limitation.)

## 9. Non-goals (this feature)
- Real BAS-due reminder (UI placeholder only; no scheduling).
- On-write push (cron-only in v1).
- A synced alert/notification entity, server-side alert log, or cross-device read state.
- Non-monthly budgets; stored/forecasted spend; "days remaining" projections.
- The full Profile/Settings hub (F7); per-device-vs-per-user quiet-hours beyond the per-device model.
- The non-budget AlertsSheet rows (GST-due, "receipts auto-sorted", "subscription renewing") — no feature generates them yet.
- Emailed reminders (push only; alerts stay in-app).

## 10. Pre-implementation checklist
- Procure the **APNs `.p8` key** + Key ID + Team ID (Apple Developer) → `wrangler secret put APNS_KEY` etc. Until then the stub seam keeps build/tests green and push is a no-op.
- Confirm jose's `importPKCS8` + ES256 sign works under workerd (it should — pure-JS, already used for HS256).
- Confirm Cloudflare Workers `fetch` to `api.push.apple.com` (HTTP/2) is permitted on the plan.
- Editing `0001_init.sql` for the devices columns → reset local `.wrangler` dev D1 once (tests rebuild from migrations).
- Decide the cron cadence in prod (hourly is the v1 default; tighten later if alert latency matters).
