# App-only auth hardening (rate-cap + Apple App Attest)

- **Date:** 2026-07-21
- **Status:** Approved design — ready for implementation plan
- **Owner:** qiguangyang
- **Area:** Backend auth (`src/routes/auth.ts`, `src/middleware/`), iOS auth (`Snapceipt/Sync/`, `Snapceipt/Features/Auth/`)

## 1. Context & motivation

An investigation on 2026-07-21 traced repeated unsolicited **"Your Snapceipt sign-in code"** emails to `qiguangyang@gmail.com`. Findings:

- The email is sent only by `sendSignInCode` (`src/lib/email.ts`), reachable from exactly two endpoints: the **unauthenticated** `POST /auth/otp/request`, and `POST /auth/password/login`'s new-device MFA branch (after a *correct* password).
- The recipient is a pure pass-through of the request body's `email` — **verified end-to-end** (code trace + 16 passing tests + a live prod send to a throwaway external inbox whose delivered code's `sha256` matched the KV `codeHash`). **There is no misrouting bug.**
- The affected account is real (created 2026-06-25 via the email flow, has a password, `email`-only identity, last successful activity 2026-07-01). **No takeover occurred** — no new device was trusted.
- Root cause of the emails: an **external actor POSTing the public API** (`api.snapceipt.cc`) with the victim's email. The auth-bootstrap endpoints are internet-reachable and only coarsely rate-limited, so anyone can trigger OTP emails to any address ("OTP bombing").

**Objective (user-selected):** make the auth-bootstrap endpoints answer only to the genuine Snapceipt app, delivered in **two phases** so no current App Store user breaks.

## 2. Goals & non-goals

### Goals
- Eliminate the trivial `curl`/bot abuse of the auth-bootstrap endpoints.
- Provide a cryptographic "genuine, unmodified Snapceipt install on a real Apple device" guarantee for those endpoints (Apple App Attest).
- Bound abuse **today** with a server-only change that cannot break existing installs.
- Transitively protect all authenticated endpoints (no session token can be minted without passing the attested bootstrap).

### Non-goals / honest limits
- **A public HTTPS API cannot be made mathematically app-only.** App Attest raises the bar from "one line of `curl`" to "defeat Apple hardware attestation," but a fully reverse-engineered, instrumented genuine binary remains a (far higher-cost) theoretical bypass. The spec states this explicitly rather than overclaiming.
- **Deliberately public endpoints stay public:** hosted quote/invoice pages (`/q/<token>`, `/i/<token>`), receipt images (`/images/<key>`), the `/auth/magic` bridge, and inbound email. These are how traders' clients view documents in a browser and must NOT be locked.
- Android / Play Integrity — out of scope (iOS-only app).

## 3. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Strategy | **Both, phased** | Stop the bleeding now (server-only) + real lock later (App Attest) without breaking existing users |
| Scope | **Auth-bootstrap *entry* endpoints** | Attested: `/auth/otp/request`, `/auth/otp/verify`, `/auth/password/login`, `/auth/apple`, `/auth/magic-link/request`, `/auth/magic-link/verify`. **`/auth/refresh` is intentionally excluded** — it is high-frequency (~every 15 min) and already protected by rotating-token single-use + reuse-detection, and it can only present a refresh token minted through an attested entry. Authenticated routes are covered transitively (bearer token only obtainable via these). |
| Email sign-up | **Keep** | New users may still register by email code (`CreateAccountView` → `/otp/request` → `/otp/verify`). App Attest protects sign-up too (attestation works before an account exists), so "existing-accounts-only" is unnecessary. |
| App Attest crypto | **Hand-rolled, WebCrypto-based verifier** | Dependency-light (matches the codebase's no-Node-deps ethos); App Attest verification is well-specified; heavily unit-tested. |

Reference identifiers: **Team ID `2SU47GHJQX`**, bundle `app.snapceipt.Snapceipt` ⇒ App Attest App ID `2SU47GHJQX.app.snapceipt.Snapceipt`; iOS deployment target **17.0** (App Attest requires iOS 14+).

## 4. Phase 1 — server-side (ships now, no app change, no existing-user breakage)

### 4.1 Per-address daily send cap (core lever)
In `sendOtpCode` (`src/routes/auth.ts`), **at the send seam**, before calling `sendSignInCode`:

- Read/increment a per-email daily counter `rl:otpsend:<sha256(email)>:<dayBucket>` where `dayBucket = floor(now / 86_400_000)`, TTL just over one day.
- If the counter is already at the cap (**`OTP_SEND_DAILY_CAP = 6`**, tunable), **skip the actual email send** but otherwise behave identically: still write the `oc:<hash>` KV code, still return `202`. Response is unchanged ⇒ **anti-enumeration preserved**, and a legitimate user who somehow requested 6 codes in a day simply gets no further emails that day (rare, acceptable).

Because it sits at the send seam, this cap:
- Applies across **both** `/otp/request` and the `/password/login` MFA send.
- **Cannot be bypassed by rotating source IPs** (keyed by email, not IP).
- Bounds any single inbox to ≤ `OTP_SEND_DAILY_CAP` code emails/day — the direct fix for the observed symptom.

### 4.2 Tier tightening (`src/middleware/rateLimit.ts`)
- `authEmail` (per-email hourly on `/request`): `8 → 4`.
- Add `authIpDay`: `60` per IP per day, applied on the `auth` class alongside the existing `authIp` (`20`/IP/hr).
- Existing `authIp` (20/IP/hr) unchanged.

### 4.3 Optional edge rules (Cloudflare dashboard; plan-aware; guided, not code)
- **Rate-Limiting Rule** on `/auth/*request`, `/auth/password/login`, `/auth/apple` keyed by IP (e.g. > 30/min → block 60s). Runs before the Worker (saves invocations). Free tier includes one such rule.
- **WAF custom rule:** on the auth-bootstrap paths, issue a **managed challenge** when the `X-Device-Id` header is absent (the app always sends it; naive bots do not). Free tier allows up to 5 custom rules.
- Flagged **deterrent-only** — headers are spoofable; the reliable core is §4.1.

### 4.4 Phase 1 properties
No app change; no existing-user breakage; no response/enumeration change; all thresholds are named constants (tunable).

## 5. Phase 2 — Apple App Attest (true app-origin proof)

### 5.1 iOS app
- **Entitlement** `com.apple.developer.devicecheck.appattest-environment`: `development` in `Snapceipt.entitlements`, `production` in `Snapceipt.Release.entitlements`.
- **New `AppAttestor`** (`Snapceipt/Sync/AppAttestor.swift`):
  - Guard on `DCAppAttestService.shared.isSupported` — false on Simulator / unsupported hardware ⇒ skip attestation; the server's enforcement mode decides acceptance.
  - **Key lifecycle:** `generateKey()` once, persist `keyId` in Keychain, reuse thereafter (reinstall ⇒ new key). Attest the key on first use.
  - **Attest (one-time per key):** `GET /attest/challenge` → `clientDataHash = SHA256(challenge)` → `attestKey(keyId, clientDataHash)` → `POST /attest/verify { keyId, attestation(base64), challenge }`.
  - **Assert (per auth-bootstrap call):** `GET /attest/challenge` → `generateAssertion(keyId, SHA256(challenge ‖ SHA256(requestBody)))` → attach headers.
- **Request headers** attached only for the six attested entry routes (§3; not `/auth/refresh`):
  - `X-Attest-Key-Id`, `X-Attest-Assertion` (base64 CBOR), `X-Attest-Challenge` (the nonce), `X-App-Build` (`CFBundleVersion`, for version-gating).
- **`APIClient` hook:** obtains + attaches attest headers for those routes; on `isSupported == false` or any attestation error, sends the request **without** attest headers (server decides).
- **Test seam:** the existing `-uiTestStub` / E2E flags force-disable attestation (the Simulator cannot attest and would throw), reusing the established stub pattern.

### 5.2 Backend — `src/routes/attest.ts` (public, in the auth allowlist)
- **`GET /attest/challenge`** → mint a 32-byte random nonce, store `att_chal:<nonce>` in KV (~120s TTL, single-use), return `{ challenge }` (base64url).
- **`POST /attest/verify`** → full attestation verification:
  1. Consume the challenge from KV (must exist, unused).
  2. CBOR-parse the attestation (`fmt == "apple-appattest"`; `attStmt.x5c` cert chain + `receipt`; `authData`).
  3. **Verify the x5c chain up to the pinned Apple App Attest Root CA** (root cert embedded as a constant; validate each signature with WebCrypto).
  4. Verify `nonce = SHA256(authData ‖ clientDataHash)` (with `clientDataHash = SHA256(challenge)`) equals the value in the leaf cert's Apple extension **OID `1.2.840.113635.100.8.2`**.
  5. Verify `rpIdHash` (first 32 bytes of `authData`) `== SHA256("2SU47GHJQX.app.snapceipt.Snapceipt")`.
  6. Extract the credential P-256 public key; verify `keyId == base64(SHA256(pubKey))`; verify counter `== 0`; `aaguid ∈ {appattest, appattestdevelop}`.
  7. Persist `{ key_id → public_key(DER), sign_count, aaguid, device_id }` in D1.

### 5.3 Backend — `attestMiddleware` on the six attested entry routes (§3; not `/auth/refresh`)
1. Read `X-Attest-Key-Id`, `X-Attest-Assertion`, `X-Attest-Challenge`.
2. Consume the challenge (fresh/unused).
3. Load the stored public key + `sign_count` for `key_id`.
4. Parse the assertion CBOR (`signature` + `authenticatorData`); compute `clientDataHash = SHA256(challenge ‖ SHA256(rawBody))`, `nonce = SHA256(authenticatorData ‖ clientDataHash)`; verify the ECDSA-P256 signature over `nonce` with the stored key.
5. Verify `rpIdHash`; enforce **strictly-increasing `sign_count`** (anti-replay); persist the new count + `last_used_at`.
6. Set `c.var.attested = true` on success; on failure, behave per §5.5.

### 5.4 Data model — `migrations/0019_attest_keys.sql`
```sql
CREATE TABLE attest_keys (
  key_id      TEXT PRIMARY KEY,      -- base64(sha256(pubkey))
  device_id   TEXT,                  -- X-Device-Id at attestation time
  public_key  BLOB NOT NULL,         -- DER-encoded P-256 public key
  sign_count  INTEGER NOT NULL DEFAULT 0,
  aaguid      TEXT,                  -- appattest | appattestdevelop
  created_at  INTEGER NOT NULL,
  last_used_at INTEGER
);
CREATE INDEX ix_attest_keys_device ON attest_keys (device_id);
```
`attest_keys` is device-scoped. **Add it to the account-delete purge (keyed by `device_id` for the account's devices) and to the test seed**, per the recurring FK-violation trap when a new table is missing from the purge order.

### 5.5 Phased enforcement — `ATTEST_MODE` (backward-compatibility mechanism)
| Mode | Behavior |
|---|---|
| `off` | Attestation ignored (today; and until the attest-enabled app ships) |
| `soft` | Verify assertion if present; **log** presence + validity; never reject. Ship the day the attest build goes live. |
| `enforce-new` | Reject un-attested/invalid **only when `X-App-Build ≥ ATTEST_MIN_BUILD`**; older installs (no header / lower build) exempt ⇒ keep working. |
| `enforce-all` | Reject all un-attested auth-bootstrap requests. Flip only once old builds are effectively gone (ideally paired with a min-version gate). |

- `ATTEST_MODE` and `ATTEST_MIN_BUILD` are env vars (flip via `wrangler` + quick deploy); dev/E2E stay `off`.
- **Honest caveat:** during `enforce-new`, an attacker can spoof a low `X-App-Build` to land in the exempt bucket, so protection is graduated and becomes airtight only at `enforce-all`. Accepted: it still kills the *common* abuse immediately, and `enforce-all` can be reached quickly if abuse persists.

## 6. Rollout sequence
1. **Phase 1** (Worker): §4 send-cap + tier tightening → deploy → verify. Optional §4.3 edge rules.
2. **Phase 2a** (Worker): attest routes + verifier + middleware shipped in `ATTEST_MODE=off` + migration `0019` (inert) → deploy.
3. **Phase 2b** (iOS): entitlement + `AppAttestor` + `APIClient` wiring → TestFlight → App Store build.
4. `ATTEST_MODE=soft` for ≥ 1 week; watch attest adoption + valid-assertion rate from the new build.
5. `ATTEST_MODE=enforce-new` (older builds exempt) → app-path abuse dies.
6. (Optional, later) min-version gate + `ATTEST_MODE=enforce-all`.

## 7. Testing strategy
- **App Attest verifier** unit tests (`test/`): known-good vectors (Apple sample + a captured real-device attestation/assertion) and negatives — wrong `rpIdHash`, stale/expired challenge, replayed (non-increasing) counter, tampered signature, broken cert chain.
- **Route/middleware tests:** `/attest/challenge` (single-use, TTL), `/attest/verify` (accept/reject), and `attestMiddleware` in each of `off` / `soft` / `enforce-new` / `enforce-all`, including `X-App-Build` version-gating.
- **Phase 1:** send-cap tests (cap reached ⇒ no email but still 202 + KV code written; cross-endpoint counting for `/otp/request` + `/password/login`); updated tier tests.
- **iOS:** `AppAttestor` unit tests with `DCAppAttestService` stubbed; guard that `-uiTestStub`/sim disables attestation; existing auth UITests remain green (test backend enforcement `off`).
- **Regression:** all existing auth / rate-limit / security suites stay green.

## 8. Security analysis
- **Stops (at `enforce-all`, and the common case from `soft`+`enforce-new`):** `curl`/bot/replay traffic to auth-bootstrap; the observed OTP-bombing; unauthenticated abuse of every downstream authenticated endpoint (no token without the attested bootstrap).
- **Does not stop:** a fully reverse-engineered genuine binary under instrumentation (far higher cost); public share links remain public by design; a spoofed low `X-App-Build` during the `enforce-new` window (graduated exposure, §5.5).
- **Defense in depth retained:** Phase 1 caps remain in force under Phase 2, so even an attested client cannot flood an inbox.

## 9. File-level change inventory
**Phase 1 (Worker):** `src/routes/auth.ts` (send-cap in `sendOtpCode` + constant), `src/middleware/rateLimit.ts` (tiers), tests.
**Phase 2 (Worker):** `src/routes/attest.ts` (new), `src/middleware/attest.ts` (new), `src/lib/appattest.ts` (verifier, new), `migrations/0019_attest_keys.sql` (new), `src/lib/db.ts` (purge order), `src/env.ts` (`ATTEST_MODE`, `ATTEST_MIN_BUILD`), route mounting in `src/index.ts`, tests.
**Phase 2 (iOS):** `Snapceipt/Sync/AppAttestor.swift` (new), `Snapceipt/Sync/APIClient.swift` (header hook), `Snapceipt/Snapceipt.entitlements` + `Snapceipt/Snapceipt.Release.entitlements`, tests.

## 10. Open tunables (not blockers)
- `OTP_SEND_DAILY_CAP` (default 6), `authEmail` hourly (4), `authIpDay` (60).
- Timing of `enforce-all` and whether to add a hard min-version gate.
- Whether to also attach a lightweight app-signature to authenticated JSON endpoints later (currently out of scope — covered transitively).
