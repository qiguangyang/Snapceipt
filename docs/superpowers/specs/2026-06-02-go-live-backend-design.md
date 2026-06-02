# Go-live: production backend + magic-link verify (Approach 1) — design

**Date:** 2026-06-02
**Status:** approved design (pre-plan)
**Milestone target:** *Backend to prod + verify* — deploy the `snapceipt-api` Worker to real Cloudflare infrastructure and prove the iOS app works end-to-end against it via a **real magic-link email** on the **`snapceipt.cc`** domain. App Store / TestFlight, push, and email-in are explicitly out of scope.

---

## 1. Goal & definition of done

Stand up a single production Worker deployment that the iOS app (iPhone 16 simulator) can:

1. Reach at `https://api.snapceipt.cc/health` (200).
2. Sign into via a **real** magic-link email delivered from `noreply@snapceipt.cc`.
3. Use to capture a receipt that is extracted by **real DeepSeek** (not the heuristic stub).
4. Sync to a **real D1** database and rehydrate on relaunch.

The milestone is **done** when all four are demonstrated and the existing test suites stay green (backend `npm test` 320 / `npm run test:e2e` 19 — both confirmed; iOS `xcodebuild test` ~359, last green baseline) after the domain rename + the new `GET /auth/magic` route.

### Non-goals (deferred to later milestones)

- Sign in with Apple verification (and the `APPLE_BUNDLE_ID` mismatch fix — see §9).
- APNs push (cron stays a no-op without `APNS_KEY`).
- Email-in (Workers AI OCR + Email Routing on `in.snapceipt.cc`).
- Universal Links / AASA / code-signing / associated-domains entitlement.
- TestFlight / App Store submission, privacy policy, App Store privacy labels.
- R2 lifecycle rules / ATO retention policy.

---

## 2. Prerequisites (operator actions — done before any deploy)

These are real-world actions that only the account owner can perform. The design does not depend on them, but execution does.

- [x] **Cloudflare account confirmed:** `techsiderau@gmail.com` — Account ID `bb4412973b5e4f6d7a10a4e68b713177` (verified via `wrangler whoami` after re-login).
- [ ] **Upgrade wrangler to v4:** `npm install --save-dev wrangler@4`. This is a **hard prerequisite for two reasons**: (a) the entire `wrangler email …` command family — needed to onboard the domain for Email Sending (Track E) — **does not exist** in 3.114.17 (`wrangler email sending enable …` errors `Unknown arguments: email, sending, enable`); and (b) 3.114.17 doesn't understand `send_email[0].allowed_sender_addresses` — it emits a non-fatal **warning and silently ignores the field**, deploying the `EMAIL` binding as *unrestricted* (the sender lockdown only takes effect on v4). *(Still pending — only `wrangler login` was run.)*
- [ ] **Confirm token scopes include R2.** The pre-login OAuth token had no R2 scope. After re-login, verify `wrangler r2 bucket list` succeeds (account-level access). If R2 is not enabled on the account, enable it in the dashboard (R2 has its own activation/billing).
- [ ] **Add `snapceipt.cc` as a zone** in the Cloudflare dashboard (DNS managed by Cloudflare) — required for the `api.` custom domain and so Email Sending can **auto-inject** its SPF + DKIM records on domain onboarding (Track E).
- [ ] **DeepSeek:** funded API key available to set as a secret; confirm the current live model id (see §6).

---

## 3. Target topology

```
            iPhone 16 simulator (Snapceipt app)
                       │  HTTPS
                       ▼
        https://api.snapceipt.cc   (Worker custom domain)
                       │
        ┌──────────────┴───────────────────────────┐
        │  snapceipt-api Worker (Hono)              │
        │   • /health, /auth/*, /sync/*, /extract…  │
        │   • NEW: GET /auth/magic  (bridge page)   │
        └───┬───────────┬───────────┬───────────┬───┘
            │           │           │           │
          D1 KV        R2          DeepSeek    Email Send
       (snapceipt)  (receipts)   (api.deepseek (noreply@
                                  .com)         snapceipt.cc)
```

- **One Worker**, one environment (no separate staging env in this milestone).
- **Real bindings** replace the `0000…` placeholders in `wrangler.jsonc`: D1 `snapceipt`, KV `KV`, R2 `snapceipt-receipts`.
- **`api.snapceipt.cc`** custom domain on the Worker; the magic-link bridge is served from the same origin (`https://api.snapceipt.cc/auth/magic`).
- APNs (`APNS_KEY`) and email-in (`AI` OCR + Email Routing) bindings remain declared but **stub-gated / unprovisioned**.

---

## 4. Work breakdown

### Track A — Cloudflare provisioning (runbook; operator CLI + small config edits)
Create the real resources, wire their ids into `wrangler.jsonc`, set secrets, apply remote migrations, deploy, and attach the custom domain. Full sequence in §7.

### Track B — Domain rename `snapceipt.app` → `snapceipt.cc` (code + config + tests)
A **global** rename (including the deferred email-in constants, for consistency — no lingering `snapceipt.app`). The **bundle id `com.snapceipt.app` is intentionally NOT renamed** (it is an identifier, not a hostname). Exact source sites (verified):

| File | Site | New value |
| --- | --- | --- |
| `src/lib/email.ts:11` | `MAGIC_LINK_SENDER` | `noreply@snapceipt.cc` |
| `src/routes/auth.ts:56` | `MAGIC_LINK_BASE_URL` | `https://api.snapceipt.cc/auth/magic` |
| `src/lib/inboxToken.ts:5` | `INBOX_DOMAIN` | `in.snapceipt.cc` |
| `src/routes/quotes.ts:159` | replyTo fallback | `noreply@snapceipt.cc` |
| `src/routes/export.ts:156` | replyTo fallback | `noreply@snapceipt.cc` |
| `src/lib/csvExport.ts:30` | comment | `api.snapceipt.cc` |
| `src/index.ts:14` | comment (`in.snapceipt.app`) | `in.snapceipt.cc` |
| `wrangler.jsonc:29` | `allowed_sender_addresses` | `["noreply@snapceipt.cc"]` |
| `wrangler.jsonc:23` | comment (`in.snapceipt.app`) | `in.snapceipt.cc` |
| `Snapceipt/App/AppLaunch.swift:120` | base URL default | `https://api.snapceipt.cc` |
| `Snapceipt/App/RootView.swift:608` | `LiveAPIClient` base | `https://api.snapceipt.cc` |
| `Snapceipt/App/SnapceiptApp.swift:51` | `LiveAPIClient` base | `https://api.snapceipt.cc` |
| `Snapceipt/Features/Quotes/QuoteEditorView.swift:239` | relative-link base | `https://api.snapceipt.cc` |
| `Snapceipt/Features/Reports/ExportSheet.swift:154` | relative-link base | `https://api.snapceipt.cc` |
| `Snapceipt/Features/Auth/AuthViewModel.swift:13-14` | doc comment | `snapceipt.cc` |
| `Snapceipt/App/DevAccount.swift:6` | dev email | `dev@snapceipt.cc` |
| `Snapceipt/Features/Profiles/ProfileTabView.swift:168` | help URL | `https://snapceipt.cc/help` (cosmetic) |
| `Snapceipt/Features/Auth/SignInView.swift`, `Snapceipt/Sync/StubAPIClient.swift` | preview/stub addresses | `…@in.snapceipt.cc` (cosmetic) |

**Test impact:** `grep snapceipt.app` matches 14 backend test files, but **only 7 carry hostname references that actually change** — `test/{inboxToken,inbound,inbox-routes,email,email-quote,sync-push}.test.ts` + `e2e/inbox.e2e.test.ts`. The **other 7 (`test/apns.test.ts` + `e2e/{extract,snapceipt,snapceipt-export,devices,quotes,account}.e2e.test.ts`) reference only the excepted bundle id `com.snapceipt.app` and must NOT be touched** (likewise `vitest.config.ts`). iOS: 7 files contain `snapceipt.app` strings — all are cosmetic test-data updates **except** `SnapceiptUITests/EmailInUITests.swift:25`, whose `@in.snapceipt.app` assertion is **coupled** to `StubAPIClient`'s preview address and must change together. **`MagicLinkParser` ignores the URL host** (it matches on path segments `auth/verify`|`auth/magic`), so no parser change is needed — the renamed `https://api.snapceipt.cc/auth/magic` link is already accepted.

### Track C — Magic-link bridge route (the verify crux)
The magic-link email points at a **Universal Link** host, but we are deliberately **not** standing up Universal Links/AASA this milestone. Instead add a thin **`GET /auth/magic`** handler to the Worker that serves a minimal HTML page which forwards the token to the **already-registered** custom scheme `snapceipt://auth/verify?token=<token>` (Info.plist `CFBundleURLSchemes: [snapceipt]`, name `app.snapceipt.auth`). `AuthViewModel` already parses `snapceipt://auth/verify?token=…` and calls `POST /auth/magic-link/verify`. Design detail in §5.

### Track D — Real DeepSeek extraction
Set `DEEPSEEK_API_KEY` secret + `DEEPSEEK_MODEL` var. Confirm the live model id (§6).

### Track E — Email Send (auth-critical)
**Onboard `snapceipt.cc` to Cloudflare Email Sending** — `npx wrangler email sending enable snapceipt.cc` (v4-only) or Dashboard → *Compute & AI → Email Service → Email Sending → Onboard Domain*. Because the zone's DNS is Cloudflare-managed, onboarding **auto-injects the SPF (TXT) + DKIM records** (propagation ~5–15 min); confirm with `npx wrangler email sending dns get snapceipt.cc`. A DMARC record is optional/recommended, not required. `allowed_sender_addresses: ["noreply@snapceipt.cc"]` restricts the *From* — no per-sender verification beyond domain onboarding is needed. (Recipient/destination verification is an Email **Routing** concept and does **not** apply to outbound Email Sending — magic-link emails go to arbitrary user inboxes.) Until onboarding completes, `env.EMAIL.send(...)` (`src/lib/email.ts`) throws and magic-link sign-in cannot complete; see the contingency in §10.

---

## 5. The `GET /auth/magic` bridge (detail)

**Why a bridge, not Universal Links:** Universal Links require an AASA file at `https://snapceipt.cc/.well-known/apple-app-site-association`, an `associatedDomains: applinks:snapceipt.cc` entitlement, a non-empty `DEVELOPMENT_TEAM`, and a code-signed build — all out of scope. The custom scheme is already registered and handled, so the bridge is the minimal path that works in the **plain simulator**.

**Behaviour:** `GET /auth/magic?token=<token>` returns `text/html` that:
- Immediately attempts to open `snapceipt://auth/verify?token=<token>` (via `window.location` / a meta-refresh), and
- Renders a visible **"Open in Snapceipt"** anchor to the same scheme as a tap fallback, plus one line of copy ("Return to the Snapceipt app to finish signing in.").

**Constraints:**
- The token is echoed only into the `snapceipt://` redirect and the anchor `href`; **it is never logged** and the page sets `Cache-Control: no-store` and `Referrer-Policy: no-referrer`.
- HTML-escape / URL-encode the token before interpolation (it is base64url, but encode defensively).
- The route is **already public** — it is matched by the existing `/auth/` prefix in `PUBLIC_PATHS` (`src/middleware/auth.ts:11`), so **no `PUBLIC_PATHS` edit is required**. It is subject only to the shared **per-IP `auth` tier (10/IP/hr)** (`src/app.ts:86` mounts `rateLimit("auth")` on `/auth/*`); the per-email cap (3/email/hr) does **not** apply because the GET carries no JSON email body. A single manual or scripted verify is far under 10/hr. It performs no verification itself — the single-use, TTL-bound, KV-backed check happens in `POST /auth/magic-link/verify`.
- No behavioural change to `/auth/magic-link/request` or `/auth/magic-link/verify`.

**Verify reality (important):** `POST /auth/magic-link/verify` (`src/routes/auth.ts`) accepts only `{ token }`, resolves it from KV, and registers whatever `X-Device-Id` the caller sends — it does **not** enforce that the verifying device equals the requesting device. So spec §21's "same-device only" is unenforced intent. Consequence for this milestone: the token can reach the simulator app by **any** path (real email tap, or a scripted `xcrun simctl openurl booted "snapceipt://auth/verify?token=…"`), and the app completes sign-in with its own device id. (Security follow-up, deferred: bind the magic link to the requesting device or shorten/again-gate it.)

---

## 6. DeepSeek model id

`src/lib/deepseek.ts` calls `https://api.deepseek.com/chat/completions` with `response_format: { type: "json_object" }`; `runDeepseekExtraction` reads `env.DEEPSEEK_MODEL ?? "deepseek-chat"`. The whole-app spec §20 notes `deepseek-chat`/`deepseek-reasoner` deprecate **2026-07-24** (today is 2026-06-02 → still valid for ~7 weeks). The brainstorm-era `deepseek-v4-flash` is **not** a confirmed API model.

**Decision:** set `DEEPSEEK_MODEL` explicitly (pin, don't rely on the default), and **confirm the exact current model id against DeepSeek's live model list at provisioning time**, choosing the non-deprecating successor if one is documented. Smoke-test `POST /extract` with a real receipt before declaring Track D done.

---

## 7. Provisioning runbook (sequenced)

> Commands assume `wrangler@4`, the `techsiderau@gmail.com` account, and `snapceipt.cc` added as a Cloudflare zone.

1. **D1:** `npx wrangler d1 create snapceipt` → paste `database_id` into `wrangler.jsonc` (`d1_databases[0]`).
2. **KV:** `npx wrangler kv namespace create KV` → paste `id` into `wrangler.jsonc` (`kv_namespaces[0]`).
3. **R2:** `npx wrangler r2 bucket create snapceipt-receipts` (requires R2 enabled + R2 token scope).
4. **Account id:** add `"account_id": "bb4412973b5e4f6d7a10a4e68b713177"` to `wrangler.jsonc` (explicit, so deploys never depend on membership enumeration).
5. **Secrets:**
   - `JWT_SIGNING_KEY` — `openssl rand -base64 48` → `npx wrangler secret put JWT_SIGNING_KEY`
   - `DEEPSEEK_API_KEY` — `npx wrangler secret put DEEPSEEK_API_KEY`
   - `DEEPSEEK_MODEL` — set as a `var` in `wrangler.jsonc` (confirmed id from §6).
   - `APPLE_BUNDLE_ID` — already a `var`; leave as-is for this milestone (SIWA not exercised).
6. **Email Send (Track E):** `npx wrangler email sending enable snapceipt.cc` (auto-injects SPF + DKIM since DNS is Cloudflare-managed) → `npx wrangler email sending dns get snapceipt.cc` to confirm. DMARC optional. No per-sender verification beyond domain onboarding.
7. **Migrations:** `npx wrangler d1 migrations apply snapceipt --remote` (forward-only; D1 tracks applied migrations).
8. **Deploy:** `npx wrangler deploy`.
9. **Custom domain:** attach `api.snapceipt.cc` to the Worker (Workers → custom domains, on the `snapceipt.cc` zone).
10. **Smoke:** `curl https://api.snapceipt.cc/health` → `200 {"ok":true,…}`; `curl -X POST …/auth/magic-link/request -d '{"email":"…"}'` → `202`.

---

## 8. Verification plan (definition of done)

> **Prerequisite — rebuild + reinstall the app.** The iOS API base URL is **compile-time**, not runtime: `SnapceiptApp.swift:51` and `RootView.swift:608` (Release) and `AppLaunch.swift:120` (DEBUG default) are hardcoded literals; the only runtime override is `apiBaseURLOverride`, fed solely by the `API_BASE_URL` env var inside a `#if DEBUG` block (a UI-test seam). So after the Track B rename you **must recompile and reinstall** the app on the iPhone 16 simulator before verifying. Run the verify as a **DEBUG build** (Xcode/`xcodebuild` → `AppLaunch.swift:120` is the active default) — either bake the renamed `https://api.snapceipt.cc` literal, or pass `API_BASE_URL=https://api.snapceipt.cc` as the DEBUG override.

1. **Health:** `curl https://api.snapceipt.cc/health` → 200.
2. **Auth end-to-end (primary = scriptable):** simulator app → request magic link → the email arrives in an **external inbox** (e.g. Gmail on the host — *not* visible inside the simulator, and the `https://…/auth/magic` tap can't reach the app without Universal Links, which are out of scope). Copy the token from that inbox and run `xcrun simctl openurl booted "snapceipt://auth/verify?token=…"` against the booted sim → bridge/scheme → `AuthViewModel` → **signed in**. *(No-email alternative for smoke-testing: the DEBUG dev sign-in button → `E2E_TEST_MODE` devToken. The `https://…/auth/magic` bridge page itself only becomes a tappable path once Universal Links exist — deferred.)*
3. **Real extraction:** capture/import a receipt → `POST /extract` returns DeepSeek-extracted fields (`meta.stub === false`) → review → save.
4. **Sync:** `npx wrangler d1 execute snapceipt --remote --command "select count(*) from transactions"` shows the row; relaunch the app (or a second install) → `/sync/pull` rehydrates it.
5. **Green suites:** backend `npm test` (320) + `npm run test:e2e` (19) — both reproduced and confirmed — and iOS `xcodebuild test` (~359, last green baseline) pass after the rename + new route + their test updates.

---

## 9. Known issues flagged (not fixed this milestone)

- **SIWA bundle-id mismatch:** the iOS app bundle id is `app.snapceipt.Snapceipt` (`project.yml`), but the backend's `APPLE_BUNDLE_ID` var is `com.snapceipt.app`. Sign in with Apple validates `identityToken.aud` against `APPLE_BUNDLE_ID`, so SIWA would fail until these match. Magic-link verify does not use it, so it is deferred — fix when SIWA is the milestone (set `APPLE_BUNDLE_ID = app.snapceipt.Snapceipt` or the registered App ID).
- **Magic link not device-bound** (see §5) — deferred security hardening.
- **`/banks`** returns `501 NOT_IMPLEMENTED` by design.

---

## 10. Error handling, rollback, contingency

- **Idempotent deploy:** `wrangler deploy` is safe to re-run; remote migrations are forward-only and tracked, so re-applying is a no-op.
- **Email on the critical path:** if `snapceipt.cc` Email Send verification or DNS propagation stalls, `env.EMAIL.send` throws and magic-link sign-in cannot complete. **Contingency:** temporarily deploy with the existing `E2E_TEST_MODE=1` seam (returns the code/link in the response) to verify the *non-email* mechanics (extraction + sync) while email finishes, then **remove the seam** before declaring the milestone done. The seam must never be left enabled in real prod.
- **R2 lag:** if R2 enablement is delayed, the core verify (auth + extraction + sync) still passes; only `POST /images` (receipt-image upload) waits on R2.
- **Secret rotation:** all secrets are settable/rotatable via `wrangler secret put`; `JWT_SIGNING_KEY` rotation invalidates existing sessions (acceptable pre-launch).

---

## 11. Resolved open decisions

1. **Custom domain host:** `api.snapceipt.cc`, and the magic-link bridge is served from the same origin (`api.snapceipt.cc/auth/magic`) — one custom domain, simplest. *(Not the apex `snapceipt.cc`.)*
2. **R2 in scope:** **yes** — provision R2 this milestone (you'll have the scope after re-login); image upload is verified too. If R2 lags, §10 covers graceful degradation.
3. **Rename breadth:** **global** — rename every `snapceipt.app` reference (incl. deferred email-in constants) so none linger; bundle id excepted.
4. **Staging env:** **no** — single prod env for this milestone (Approach 1, not 2).

---

## 12. References

- Whole-app design + pre-impl checklist: `docs/superpowers/specs/2026-05-30-snapceipt-ios-app-design.md` (§20).
- Receipt capture/extraction contract: `docs/superpowers/specs/2026-05-30-receipt-capture-extraction-design.md` (§9).
- Worker README (deploy steps, conventions): `README.md`.
- Key code: `src/routes/auth.ts` (magic-link), `src/lib/email.ts`, `src/lib/deepseek.ts`, `src/lib/inboxToken.ts`, `wrangler.jsonc`; iOS `AuthViewModel.swift`, `AppLaunch.swift`, Info.plist URL scheme.
