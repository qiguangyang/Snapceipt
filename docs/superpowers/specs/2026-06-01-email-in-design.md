# F6 — Email-in Receipts (Design)

> Cloudflare Email Routing (inbound) → Workers AI OCR → existing DeepSeek extraction → a server-created `email_in` Transaction that syncs to the device for review.
>
> Sixth and penultimate feature of the Snapceipt remaining-features roadmap (`docs/superpowers/specs/2026-05-31-snapceipt-remaining-features-roadmap.md`, F6). F1 Logbooks, F2 Reports, F3 Budgets+push, F4 Loyalty, F5 Quotes are shipped & merged. F7 Settings follows in its own cycle.

---

## 1. Overview & scope

Each **profile** gets a stable, opaque inbox alias — `r.<token>@in.snapceipt.app`. A trader forwards (or BCCs) a supplier's receipt email there. Cloudflare Email Routing delivers it to the Worker's `email()` handler, which:

1. resolves the recipient alias → `(user_id, profile_id)`;
2. dedups on `Message-ID`;
3. parses the MIME, takes the first image attachment;
4. stores the image to R2;
5. OCRs it via Workers AI (gated by a stub seam);
6. runs the **existing** `runDeepseekExtraction(env, { source: "email_in" })` pipeline (itself gated);
7. writes a `transactions` row (`source='email_in'`) + `line_items` + a `receipt_images` row — all owned by the resolved user/profile — which the device pulls on the next `/sync/pull`.

If OCR or extraction fails, the Transaction is **still created** with `extraction_status='failed'` so the receipt is never lost; the user fixes it in a minimal **Email-in** screen on the Profile tab.

**Scope = backend + a minimal iOS surface.** Two implementation plans (backend, iOS). The address selects the profile, so there is no separate "which profile?" step.

**Out of scope (this feature):** PDF/non-image attachments (rejected as `no_image` for now), inline-image-only bodies without attachments, multi-attachment fan-out (only the first image is used), an in-app "forwarding instructions" wizard beyond the address card, and any change to the existing on-device capture/`/extract` flow.

**External deps gated behind stub seams** (same discipline as DeepSeek/APNs/Email Send in F1–F5):
- Cloudflare **Email Routing** (inbound) — the `email()` handler is not invocable in `vitest-pool-workers`, so all logic lives in a pure `inboundEmailLogic(...)` core that tests drive directly (the `budgetCronLogic` pattern from F3).
- **Workers AI** OCR — gated on `E2E_EMAIL_MODE === "1" || !env.AI`; the stub returns deterministic OCR text.
- **DeepSeek** extraction — already gated inside `runDeepseekExtraction` on `E2E_EXTRACT_MODE || !DEEPSEEK_API_KEY`.

---

## 2. Architecture & data model

### 2.1 New server-only tables (migration `0003_email_in.sql`)

Both are **server-only** (NOT in `SYNCABLE_TABLES`), exactly like `quote_counters` from F5. They never reach the device.

```sql
-- One active inbox alias per profile. Opaque random token; rotation overwrites it.
CREATE TABLE profile_inbox_tokens (
  token       TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id),
  profile_id  TEXT NOT NULL REFERENCES profiles(id),
  created_at  INTEGER NOT NULL
);
CREATE UNIQUE INDEX ux_inbox_profile ON profile_inbox_tokens(profile_id);
CREATE INDEX        ix_inbox_user    ON profile_inbox_tokens(user_id);

-- Idempotency + audit for inbound deliveries. message_id is the dedup key.
CREATE TABLE inbound_email_log (
  message_id     TEXT PRIMARY KEY,
  user_id        TEXT,
  profile_id     TEXT,
  transaction_id TEXT,
  status         TEXT NOT NULL CHECK (status IN ('created','failed','rejected','duplicate')),
  reason         TEXT,
  received_at    INTEGER NOT NULL
);
CREATE INDEX ix_inbound_received ON inbound_email_log(received_at);
```

**No transaction-side migration is needed** — `0001_init.sql` already scaffolded everything the inbound path writes:
- `transactions.source` CHECK already includes `'email_in'`; `extraction_status` already allows `pending|done|failed`.
- `receipt_images.ocr_source` already allows `'workers_ai'`; `receipt_images.source` already allows `'email_in'`.

### 2.2 Inbox alias format & resolution

- Address: **`r.<token>@in.snapceipt.app`**. The `r.` prefix namespaces receipt-inbox addresses away from `noreply@`/magic-link senders.
- `token` = 16 random bytes → 32 lowercase hex chars, from `crypto.getRandomValues` (Workers global). Opaque, unguessable, **not** signed (unlike export/quote download tokens — those are HMAC-signed because they grant public read; this token is a stored secret looked up in D1).
- Resolver: `localPart = to.split("@")[0].toLowerCase()`; require `localPart.startsWith("r.")`; `token = localPart.slice(2)`; `SELECT user_id, profile_id FROM profile_inbox_tokens WHERE token = ?`. No row → reject.

### 2.3 Inbound flow (the `email()` handler → `inboundEmailLogic` core)

```
Email Routing catch-all (in.snapceipt.app)
        │
   email(message, env, ctx)           ← thin wrapper in src/index.ts
        │  build InboundMessage { to, from, messageId, raw }
        ▼
   inboundEmailLogic(env, msg, nowMs)  ← pure core, unit-tested
        │
        ├─ resolve token → (userId, profileId)        → unknown ⇒ {rejected, unknown_inbox}
        ├─ dedup Message-ID (INSERT inbound_email_log) → conflict ⇒ {duplicate}
        ├─ postal-mime parse → first image attachment  → none ⇒ {rejected, no_image}
        ├─ R2 put  u/<userId>/<uuid>.<ext>
        ├─ OCR  workersAiOcr(env, bytes, ct)           ← gated; throw ⇒ failed path
        ├─ runDeepseekExtraction(env,{source:"email_in"}) ← gated; throw ⇒ failed path
        └─ writeReceiptRows(...)  txn + line_items + receipt_images
                                          → {created, transactionId, extraction:'done'|'failed'}
```

The wrapper translates the result: `rejected` → `message.setReject(reason)` (sender gets a bounce); `duplicate`/`created` → accept silently. Any thrown error is caught + logged and **not** rethrown (a thrown handler bounces the mail and Email Routing retries indefinitely). `ctx.waitUntil` keeps the isolate alive for the async work.

---

## 3. Authoritative contract (backend ↔ iOS)

**This section is the cross-plan contract. The backend and iOS plans must both conform to it verbatim.**

### 3.1 Inbox token endpoints (new `src/routes/inbox.ts`, mounted at `/profiles`)

Both are auth-gated (global middleware), rate tier `"inbox"`, and scoped to the caller's `user_id`.

| Method & path | Behaviour | Response (200) |
|---|---|---|
| `GET /profiles/:profileId/inbox` | Verify the profile is owned by `c.var.userId` (else `404 NOT_FOUND`). Mint a token if none exists (`INSERT ... ON CONFLICT(profile_id) DO NOTHING`), then read it back. | `InboxAddressResponse` |
| `POST /profiles/:profileId/inbox/rotate` | Same ownership check. `UPDATE profile_inbox_tokens SET token=?, created_at=? WHERE profile_id=?` (mints first if absent). The old token stops resolving immediately. | `InboxAddressResponse` |

**`InboxAddressResponse` (JSON):**
```json
{ "profileId": "string", "token": "string", "address": "r.<token>@in.snapceipt.app" }
```

The server owns address formatting (`addressForToken(token) = "r." + token + "@in.snapceipt.app"`); the client treats `address` as opaque and never reconstructs it.

### 3.2 Inbound result type (internal, returned by `inboundEmailLogic`)

```ts
type InboundResult =
  | { status: "rejected";  reason: "unknown_inbox" | "no_image" }
  | { status: "duplicate" }
  | { status: "created";   transactionId: string; extraction: "done" | "failed" };
```

### 3.3 Server-side row mapping (`writeReceiptRows`)

Maps a finalized `ExtractedReceipt` (amounts in **dollars**) into D1 rows (amounts in **cents**). Called for both the success and the failed path (failed path passes a zeroed placeholder receipt).

`transactions` row:
| Column | Value |
|---|---|
| `id` | `uuidv7()` |
| `user_id` / `profile_id` | resolved from the token |
| `merchant` | `receipt.merchant` (`''` on the failed path) |
| `cat_key` | `coerceCatKey(receipt.category)` — lowercase; if ∈ `{meals,groceries,fuel,software,office,home,health,travel,income,custom}` use it, else `'office'` |
| `category_id` | `NULL` |
| `amount_cents` | `Math.round(receipt.total * 100)` (`0` on failed) |
| `currency` | `'AUD'` |
| `txn_date` | `receipt.date` (today `YYYY-MM-DD` on failed) |
| `mode` | profile `type === 'business' ? 'business' : 'personal'` |
| `deductible_pct` | `receipt.deductible` clamped 0..100, else `NULL` |
| `is_ai` | `1` |
| `gst_cents` | `receipt.gst == null ? NULL : Math.round(receipt.gst * 100)` |
| `note` | `NULL` |
| `source` | `'email_in'` |
| `extraction_status` | `'done'` (success) or `'failed'` |
| `created_at`/`updated_at` | `nowMs` |
| `rev` | `0` |
| `last_edited_device_id` | `'email_in'` |

`line_items` rows (success path only; one per `receipt.lineItems[i]`): `price_cents = Math.round(price*100)`, `quantity=1`, `sort_order=i`, `last_edited_device_id='email_in'`.

`receipt_images` row (always — preserves the image even on failure): `r2_key`, `content_type`, `byte_size`, `page_index=0`, `ocr_text` (the OCR output, or `NULL` if OCR itself failed), `ocr_source='workers_ai'`, `extraction_json=JSON.stringify(receipt)` (success) or `NULL` (failed), `extraction_model` (the model id or `NULL`), `transaction_id` (linked), `profile_id`, `source='email_in'`, `rev=0`, `last_edited_device_id='email_in'`.

All three tables ARE in `SYNCABLE_TABLES` already, so the rows pull to the device on the next `/sync/pull` with no registry change.

### 3.4 iOS API surface

`APIClient` gains two methods; **all four conformers** (`LiveAPIClient`, `StubAPIClient`, the SwiftUI Preview client, `MockAPIClient`) implement them:

```swift
func profileInbox(profileId: String) async throws -> InboxAddressResponse        // GET  /profiles/:id/inbox
func rotateProfileInbox(profileId: String) async throws -> InboxAddressResponse   // POST /profiles/:id/inbox/rotate
```

`InboxAddressResponse: Codable, Equatable { let profileId, token, address: String }`.
- **Stub/Preview** return a canned `InboxAddressResponse(profileId:, token: "stubtoken00000000000000000000000", address: "r.stubtoken00000000000000000000000@in.snapceipt.app")` (rotate returns a second canned token) — hermetic, no network.
- **Mock** records the call (entity + profileId) and returns a configurable canned response.

### 3.5 Profile scoping rule (unchanged invariant)

Every row the inbound path writes carries the token's `profile_id` and `user_id`. The iOS Email-in list filters `Transaction` by `source == "email_in"` **and** the currently-selected `profileId` — consistent with the app-wide scope-by-`profileId` rule.

---

## 4. Backend components

| File | Responsibility |
|---|---|
| `migrations/0003_email_in.sql` | the two server-only tables (§2.1) |
| `src/lib/inboxToken.ts` | `mintInboxToken`, `resolveInboxToken`, `rotateInboxToken`, `addressForToken`, `tokenFromRecipient` — pure helpers + thin D1 calls |
| `src/lib/ocr.ts` | `workersAiOcr(env, bytes, contentType): Promise<string>` + the gated stub (`E2E_EMAIL_MODE==='1' || !env.AI` ⇒ deterministic `STUB_OCR_TEXT`); real path calls `env.AI.run("@cf/meta/llama-3.2-11b-vision-instruct", {...})` |
| `src/lib/receiptRows.ts` | `writeReceiptRows(db, args)` (§3.3) + `coerceCatKey` — **net-new**; `/extract` does no DB writes, so server-side row creation does not exist yet |
| `src/email/inbound.ts` | `inboundEmailLogic(env, msg, nowMs)` pure core (§2.3) + the postal-mime parse + image-attachment pick |
| `src/routes/inbox.ts` | `GET /:profileId/inbox` + `POST /:profileId/inbox/rotate` (§3.1) |
| **Modify** `src/index.ts` | add `email` to the default export; thin wrapper → `inboundEmailLogic` + `setReject`/swallow |
| **Modify** `src/app.ts` | mount `inboxRoutes` at `/profiles`; add `app.use("/profiles/*", rateLimit("inbox"))` |
| **Modify** `src/middleware/rateLimit.ts` | add an `"inbox"` tier (per-user, generous — e.g. 60/hr) |
| **Modify** `src/env.ts` | add `E2E_EMAIL_MODE?: string` |
| **Modify** `wrangler.jsonc` | confirm `ai` binding (already present); document the Email Routing catch-all for `in.snapceipt.app` (provisioned in the dashboard, not in code) |
| **Modify** `package.json` | add `postal-mime` |

**Reuses unchanged:** `runDeepseekExtraction` + `ExtractedReceipt` (`src/lib/deepseek.ts`), `heuristicExtract` (the stub's basis), `uuidv7`/`nowMs`, the R2 `RECEIPTS` bucket + `u/<userId>/...` key convention (from `images.ts`).

---

## 5. iOS components (minimal surface)

| File | Responsibility |
|---|---|
| `Snapceipt/Features/EmailIn/EmailInViewModel.swift` | `@Observable @MainActor`; `address` (+ loading/error), `inbox: [Transaction]` (filtered `source=='email_in'` & current `profileId`, **failed-first** then `txnDate` desc), `load()`, `rotate()`, `save(_:)` (edit a Transaction, flip `failed→done`, `enqueue` via `SyncEnqueuing`) |
| `Snapceipt/Features/EmailIn/EmailInView.swift` | address card (alias text + **Copy** / **Share** / **Rotate**) + inbox list (merchant/amount + status badge, failed rows flagged) + empty state; full-screen overlay chrome (`LbHeader`/`SheetHeader`) like Budgets/Loyalty |
| `Snapceipt/Features/EmailIn/EmailInReviewView.swift` | Transaction-bound editor (merchant, amount, date, category); **Save** → `viewModel.save` |
| **Modify** `APIClient.swift` (+3 conformers) & `MockAPIClient` | `profileInbox` / `rotateProfileInbox` (§3.4) |
| **Modify** `DTOs.swift` | `InboxAddressResponse` |
| **Modify** `Router.swift` | `.emailIn` (overlay) case |
| **Modify** `RootView.swift` | overlay wiring + sheet-binding/sheet-content exclusions (mirror `.budgets`/`.loyalty`) |
| **Modify** `ProfileTabView.swift` | new `onOpenEmailIn` row, icon `envelope`, `AccessibilityID.profileRowEmailIn` → `.emailIn` |
| **Modify** `AccessibilityID.swift` | `profileRowEmailIn`, `emailInAddress`, `emailInCopy`, `emailInRotate`, `emailInList`, `emailInReviewSave` |
| **Modify** `AppLaunch.swift` | seed two `source='email_in'` Transactions on the business profile (1 `extraction_status='failed'`, 1 `'done'`) for the UI test |

**No new `@Model` / no `EntityType` change** — email-in items are ordinary `Transaction`s, so the local-first list, sync, and editor reuse what exists. (Verify at build time that the `Transaction` `@Model` exposes `source` and `extractionStatus`; the schema was scaffolded with them.) The list is local-first (transactions already synced); only the address card needs the network.

---

## 6. Error handling

- **Unknown inbox** (token resolves to nothing) → `{rejected, unknown_inbox}` → `setReject` (sender bounce). No rows.
- **No image attachment** → `{rejected, no_image}` → `setReject`. No rows.
- **Duplicate** (`Message-ID` already in `inbound_email_log`) → `{duplicate}`, accepted silently, **no second Transaction**. Redelivery-safe. (Absent `Message-ID` ⇒ synthesize a random id ⇒ always processed, logged.)
- **OCR failure** (Workers AI throws) → skip extraction; create a Transaction `extraction_status='failed'` with the image stored and `ocr_text=NULL`. Receipt never lost.
- **Extraction failure** (`runDeepseekExtraction` throws) → create a Transaction `extraction_status='failed'`, image + `ocr_text` preserved, `extraction_json=NULL`.
- **Oversized attachment** (> 6 MiB, mirroring `images.ts`) → treated as `no_image` (skip, reject) to bound R2 spend.
- **Any uncaught error in the wrapper** → logged, swallowed (never rethrow → never bounce-loop).
- **iOS**: address fetch failure → inline retry; rotate failure → error toast (the old address keeps working); review-save offline → optimistic local write + `enqueue` (drains on reconnect).

---

## 7. Testing

### 7.1 Backend (vitest; baseline 283 unit / 15 e2e)

`inboundEmailLogic` core — driven with a mock `InboundMessage` (a fixture MIME with an image attachment, built once as a constant) and `E2E_EMAIL_MODE='1'` + `E2E_EXTRACT_MODE='1'` (both stubs):
- resolve token → `(user, profile)`; **unknown** alias → `{rejected, unknown_inbox}`, zero rows.
- **no image** → `{rejected, no_image}`, zero rows.
- **idempotent**: same `Message-ID` twice → first `{created}`, second `{duplicate}`, **exactly one** Transaction.
- **happy path**: OCR-stub → DeepSeek-stub → one `transactions` (`source='email_in'`, `extraction_status='done'`, the resolved `profile_id`, `is_ai=1`, correct `amount_cents`), N `line_items`, one `receipt_images` (`ocr_source='workers_ai'`, linked `transaction_id`).
- **extraction failure**: `vi.spyOn(deepseek, "runDeepseekExtraction").mockRejectedValue(...)` → Transaction `extraction_status='failed'`, `receipt_images` present with `ocr_text`, no `line_items`.
- **profile scoping**: the stamped `profile_id` equals the token's profile.

`inboxToken` unit: `mint` is unique; `resolve` round-trips; `rotate` — old token stops resolving, new resolves; `tokenFromRecipient` parses `r.<token>@…` and rejects non-`r.` localparts.

`inbox` routes: `GET` mints + returns a well-formed `InboxAddressResponse`; `rotate` returns a different token; another user's profile → `404`.

e2e (`+2`, → 17): `GET /profiles/:id/inbox` then `POST .../rotate` over real HTTP assert the address shape + that the token changed. (The `email()` handler is not invocable in `unstable_dev` → covered by the core unit tests.)

### 7.2 iOS (Swift Testing + XCUITest; baseline 311 unit / 11 UI)

`EmailInViewModelTests`: failed-first + profile-scoped query ordering; `save` edits the Transaction, flips `failed→done`, and records one `enqueue`; `load`/`rotate` call the right `MockAPIClient` methods. `InboxAddressResponse` decode + Mock-records.

`EmailInUITests` (hermetic, seeded): launch on the business profile → Profile tab → **Email-in receipts** → address card shows the stub alias → inbox list shows the **failed** row first → tap → review → edit merchant/amount → **Save** → status badge flips → back to the list. The **Rotate** button calls the stub and the displayed alias updates.

### 7.3 Stub seams (no provisioning required to test)

`E2E_EMAIL_MODE='1'` forces deterministic OCR; `E2E_EXTRACT_MODE='1'` forces the deterministic extraction stub; `env.AI` absent also takes the OCR stub. No `.p8`, no live Email Routing, no DeepSeek key needed for the suite to be green. The live Email Routing catch-all + the `in.snapceipt.app` zone are dashboard-provisioned at deploy time and exercised manually.

---

## 8. Targets after F6

- Backend: **`npm test` ≈ 283 + new unit tests**, **e2e 15 → 17**, `typecheck` clean.
- iOS: **unit 311 + new tests**, **UI 11 → 12** (+`EmailInUITests`), full suite green.
