# Email-in receipt → push notification + auto-refresh — design

**Date:** 2026-06-24
**Status:** Approved (brainstorming) — pending spec review → implementation plan.

## Goal

When a Pro user's emailed receipt is ingested server-side, the app currently does not learn about it until the next manual/launch sync — so the new receipt doesn't appear while the app is open. Send an **APNs push** the moment the email-in transaction is created so the app (1) **notifies** the user and (2) **refreshes** to show the receipt: foreground → trigger a sync; tapping the notification → open that receipt's review editor.

This reuses the app's **existing, shipped APNs stack** (built for budget alerts) — `sendPush` (ES256 JWT, stub-gated on `APNS_KEY`), the `devices` table (`apns_token` / `push_enabled` / quiet-hours), and the iOS `NotificationDelegate` (token registration + tap/foreground handlers). It is wiring, not new infrastructure.

## Decisions (from brainstorming)

1. **Visible notification + refresh** (not silent-only, not both). A normal alert push; iOS handles foreground (sync + banner) and tap (sync + deep-link). No `content-available` silent push.
2. **Fires whenever an email-in receipt creates a transaction** — both `created` (extraction succeeded) and `failed` (extraction failed, image saved for review). Text adapts. **No push on rejections** (`no_image` / `pro_only` / `rate_limited` / duplicate — no transaction exists).
3. **Respect `push_enabled`** (the device master toggle). **Do NOT respect quiet-hours** — an emailed receipt is a direct response to the user's own action, unlike unsolicited budget alerts.
4. **Tap → that receipt's review editor** (`router.present(.emailInReview(id:))`), falling back to the Email-in screen (`.emailIn`) if the transaction isn't synced locally yet.
5. **Reuse the budget-alert push pattern** verbatim where possible (device query, `sendPush`, invalid-token cleanup).

## Behavior matrix (email-in push)

| Inbound outcome | Push? | Alert text |
|---|---|---|
| `created` (Gemini extraction ok) | yes (to each `push_enabled` device with a token) | title `"New receipt"`, body `"From {merchant} — tap to review."` (no merchant → `"New emailed receipt — tap to review."`) |
| `failed` (image saved, needs review) | yes | title `"Receipt received"`, body `"Couldn't read it automatically — tap to review."` |
| rejected (`pro_only` / `no_image` / `rate_limited` / duplicate) | no (no transaction) | — |

If the user has no devices with `push_enabled = 1` and a non-null `apns_token`, nothing is sent (no error). `APNS_KEY` absent (tests / unprovisioned) → `sendPush` stubs (logs, no network), so nothing breaks.

## Architecture

### Backend

**Changed — `src/lib/apns.ts`: generalize `ApnsPayload`.**
It is currently budget-specific (required `budgetId` + `deepLink`). Make it carry an optional, typed custom section so both push kinds share it:
```ts
export interface ApnsPayload {
  aps: { alert: { title: string; body: string }; sound: string };
  deepLink?: string;          // was required; now optional
  budgetId?: string;          // budget alerts only (now optional)
  type?: string;              // e.g. "email_in" — the iOS router branch key
  transactionId?: string;     // email-in: the created transaction id
}
```
`sendPush`'s signature/behavior is unchanged. The budget-alert payload still sets `budgetId` + `deepLink` and keeps working.

**New — `notifyEmailInReceipt(env, userId, transactionId, merchant, outcome)` (in `src/email/inbound.ts`, or a small `src/email/notify.ts` it imports).**
- `outcome: "created" | "failed"`.
- Query the owner's eligible devices (mirroring `budgetAlert`, minus quiet-hours):
  `SELECT apns_token FROM devices WHERE user_id = ? AND deleted_at IS NULL AND push_enabled = 1 AND apns_token IS NOT NULL`.
- Build the email-in `ApnsPayload`: `aps.alert` per the matrix above (`created` → `"New receipt"` / `"From {merchant} — tap to review."`; `failed` → `"Receipt received"` / `"Couldn't read it automatically — tap to review."`), `sound: "default"`, `type: "email_in"`, `transactionId`, `deepLink: \`snapceipt://receipt/${transactionId}\``.
- `for` each device: `await apns.sendPush(env, token, payload)`. On `{ stub: false, status: 410 | 400 }`, null that token (`UPDATE devices SET apns_token = NULL WHERE apns_token = ?`) — exactly the budget-alert invalid-token cleanup.
- **Best-effort:** the whole helper body is wrapped so any throw is caught and logged (`[email-in:push] …`); a push failure must never change the inbound result or fail email ingestion.

**Changed — `src/email/inbound.ts` (`inboundEmailLogic`).**
After the transaction is written and `logInbound` recorded, for the `created` and `failed` paths, call `await notifyEmailInReceipt(env, owner.userId, transactionId, merchant, outcome)`. `merchant` is the finalized receipt's merchant (empty string when absent → the helper uses the no-merchant body above). Placed after the existing terminal logging so the txn exists before we notify; no change to dedup / rate-limit / cap / sanity gates / rejection paths.

### iOS

**Changed — `Snapceipt/App/Router.swift`.**
- Add `func openEmailInReceipt(_ id: String) { present(.emailInReview(id: id)) }` (the `.emailInReview(id:)` overlay already renders `EmailInReviewView`).
- Add `snapceipt://receipt/<id>` parsing (mirroring `handleBudgetDeepLink`): `func handleReceiptDeepLink(_ url: URL) -> Bool` → `openEmailInReceipt(id)`.

**Changed — `Snapceipt/Features/Notifications/NotificationDelegate.swift`.**
- Add a shared `static var sync: SyncEngine?` injected in `SnapceiptApp.init` alongside `router`/`api`.
- `willPresent` (foreground): if `userInfo["type"] as? String == "email_in"` → `Task { await Self.sync?.sync() }` (refresh the open list), then return `[.banner, .sound]`. Other pushes keep the current `[.banner, .sound]`.
- `didReceive` (tap): if `type == "email_in"` → `await Self.sync?.sync()`, then on the main actor `Self.router?.openEmailInReceipt(txnId)` using `userInfo["transactionId"]`; if `transactionId` is missing, fall back to `Self.router?.present(.emailIn)`. The existing budget branch (`deepLink` / `budgetId`) is unchanged and checked when `type != "email_in"`.
- (The Email-in review view already loads the receipt image by transaction id, so once the sync has pulled the txn, opening it shows the receipt; if not yet pulled, `.emailInReview` still opens by id and its view model fetches.)

**Changed — `Snapceipt/App/SnapceiptApp.swift`.**
- In `init`, after the existing `NotificationDelegate.router = router` / `.api = api`, add `NotificationDelegate.sync = syncEngine` (the same `SyncEngine` instance the shell uses).

### Config

No new env/secret. APNs is already provisioned (`APNS_KEY` / `APNS_KEY_ID` / `APNS_TEAM_ID` for budget alerts). When `APNS_KEY` is absent, `sendPush` stubs — same as today.

## Data flow

Pro inbound email → `inboundEmailLogic` creates the txn (`created`/`failed`) → `logInbound` → **`notifyEmailInReceipt`** → owner's `push_enabled` devices → `apns.sendPush` → APNs → device:
- **foreground:** `willPresent` → `SyncEngine.sync()` (Email-in list refreshes) + banner.
- **tap:** `didReceive` → `SyncEngine.sync()` → `Router.openEmailInReceipt(txnId)` (review editor; fallback `.emailIn`).

## Error handling / fallbacks

- No eligible devices → nothing sent, no error.
- `APNS_KEY` absent → `sendPush` stub (no network), helper no-ops gracefully.
- Any push error (network, signing, JSON) → caught + logged; inbound result and email ingestion are unaffected (best-effort).
- APNs `410 Unregistered` / `400 BadDeviceToken` → null that `apns_token` so future sends skip it.
- iOS sync failure on push → silent; the next launch/foreground sync catches up.

## Testing

**Backend (`vitest`):**
- `notifyEmailInReceipt` — with a seeded owner + one `push_enabled` device and a stubbed/spied `sendPush`: asserts one send with the right token and payload (`type: "email_in"`, `transactionId`, `deepLink`, and the `created` vs `failed` title/body). A second device with `push_enabled = 0` (or null token) is skipped. A `410` response nulls the token.
- `inboundEmailLogic` — a Pro `created` path triggers exactly one notify call (spy), a `failed` path triggers one, and a rejected path (`pro_only`) triggers none. A thrown `sendPush` does NOT change the `created` result (best-effort).
- The test env has no `APNS_KEY`, so the real `sendPush` stubs — existing inbound tests stay hermetic and green.

**iOS (Swift Testing):**
- `NotificationDelegate` routing for an `email_in` payload: a `didReceive` with `transactionId` calls sync then `Router.openEmailInReceipt(id)` (assert `router.overlay == .emailInReview(id:)`); a payload missing `transactionId` falls back to `.emailIn`. A non-`email_in` (budget) payload still routes to the budget branch (unchanged). Use a test `Router` + a spy/stub `SyncEngine` seam.

Full backend `vitest` + iOS suites stay green.

## Out of scope

- Silent/`content-available` background push (chose visible-only).
- Quiet-hours for email-in (intentionally not applied).
- The in-app camera-scan path and any other push type.
- A user-facing per-type notification preference (the existing `push_enabled` master toggle governs).

## Related memory

[[email-in-receipts]] (the Pro/Gemini email-in pipeline this notifies for), [[capture-and-receipt-images]] (the by-transaction receipt-image read-back the review editor uses).
