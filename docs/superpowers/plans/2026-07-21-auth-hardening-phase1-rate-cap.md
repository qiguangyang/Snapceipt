# Auth Hardening — Phase 1 (server-side rate-cap) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bound the "Your Snapceipt sign-in code" OTP-bombing to a fixed per-address daily ceiling and tighten the auth rate-limit tiers — server-only, no app change, no existing-user breakage.

**Architecture:** Add a per-email daily send counter at the *send seam* (`sendOtpCode`) so the cap applies across both `/auth/otp/request` and the `/auth/password/login` new-device MFA send, keyed by email (IP-rotation-proof). Lower the per-email hourly cap and add a per-IP daily cap in the existing KV fixed-window limiter. Optionally add Cloudflare edge rules (ops runbook).

**Tech Stack:** Cloudflare Workers, Hono, KV (fixed-window counters), TypeScript, Vitest (`@cloudflare/vitest-pool-workers`).

## Global Constraints

- Response bodies and status codes on the auth-bootstrap endpoints MUST NOT change (anti-enumeration): every `/auth/otp/request` still returns `202` with no body; hitting the send-cap skips the *email* only, never the KV code write or the response.
- All thresholds are named constants (tunable): `OTP_SEND_DAILY_CAP = 6`, `authEmail` hourly `= 4`, `authIpDay` daily `= 60`.
- No iOS app change in Phase 1.
- Timestamps are epoch ms via `nowMs()` (`src/lib/time.ts`). KV TTL minimum is 60s.
- Tests: `SELF.fetch` + `env` from `cloudflare:test`; the SendEmail seam is stubbed via `vi.spyOn(emailModule, "sendSignInCode")`. Never pipe test output through `grep` before `&& git commit` (a green suite must gate the commit on the real exit code).

---

### Task 1: Per-address daily OTP send-cap

**Files:**
- Modify: `src/routes/auth.ts` (the `sendOtpCode` helper + new constants/helper, around lines 65–115 and 286–315)
- Test: `test/auth.otp-sendcap.test.ts` (create)

**Interfaces:**
- Consumes: existing `sendOtpCode(c: Context<AppEnv>, normalized: string): Promise<string>`, `sha256Hex`, `nowMs`, `sendSignInCode`.
- Produces: `OTP_SEND_DAILY_CAP` (const), gated send behavior. No signature change to `sendOtpCode`.

- [ ] **Step 1: Write the failing test**

Create `test/auth.otp-sendcap.test.ts`:

```ts
import { env, SELF } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";

afterEach(() => vi.restoreAllMocks());

async function request(email: string) {
  return SELF.fetch("https://x/auth/otp/request", {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "198.51.100.7" },
    body: JSON.stringify({ email }),
  });
}

describe("OTP per-address daily send cap", () => {
  it("caps emails at OTP_SEND_DAILY_CAP/day but keeps returning 202 (no enumeration)", async () => {
    const send = vi.spyOn(emailModule, "sendSignInCode").mockResolvedValue(undefined);
    const email = "capme@example.com";

    // First 6 requests each send an email.
    for (let i = 0; i < 6; i++) {
      const res = await request(email);
      expect(res.status).toBe(202);
    }
    expect(send).toHaveBeenCalledTimes(6);

    // 7th request in the same day: still 202, but NO further email is sent.
    const res7 = await request(email);
    expect(res7.status).toBe(202);
    expect(send).toHaveBeenCalledTimes(6);

    // The KV code is still written for the capped request (response identical).
    const emailHash = [...new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(email)),
    )].map((b) => b.toString(16).padStart(2, "0")).join("");
    expect(await env.KV.get(`oc:${emailHash}`)).not.toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/auth.otp-sendcap.test.ts`
Expected: FAIL — 7th request still calls `sendSignInCode` (called 7 times, expected 6). (Note: per-IP hourly cap is 20/hr and per-email hourly is being lowered in Task 2; with 7 requests in one hour under the current 8/hr email cap this test isolates the daily send-cap.)

- [ ] **Step 3: Add the constant + helper in `src/routes/auth.ts`**

Just below the existing `OTP_TTL_SECONDS` / `OTP_MAX_ATTEMPTS` constants (around line 67), add:

```ts
// Max sign-in code EMAILS delivered to one address per UTC day, across BOTH /otp/request and the
// /password/login new-device MFA send. Bounds OTP-bombing to a fixed daily ceiling regardless of
// source IP (keyed by email). On exceed we skip the SEND only — the KV code is still written and
// the response is still 202, so the response is identical (no account enumeration) and a legit
// over-requester simply stops receiving mail that day. Tunable.
const OTP_SEND_DAILY_CAP = 6;
const OTP_SEND_DAY_MS = 24 * 60 * 60 * 1000;

/** Returns true (and increments the counter) when another sign-in code email to this address is
 *  allowed today; false once the daily cap is reached. Keyed by sha256(email) so it can't be
 *  bypassed by rotating source IPs. */
async function allowOtpSend(c: Context<AppEnv>, emailHash: string): Promise<boolean> {
  const bucket = Math.floor(nowMs() / OTP_SEND_DAY_MS);
  const key = `rl:otpsend:${emailHash}:${bucket}`;
  const current = Number((await c.env.KV.get(key)) ?? "0");
  if (current >= OTP_SEND_DAILY_CAP) return false;
  await c.env.KV.put(key, String(current + 1), {
    expirationTtl: Math.ceil(OTP_SEND_DAY_MS / 1000) + 60, // outlive the bucket
  });
  return true;
}
```

- [ ] **Step 4: Gate the real send inside `sendOtpCode`**

In `sendOtpCode` (around lines 290–315), the current body computes `emailHash` then sends. Replace the send block so the non-E2E branch is gated by `allowOtpSend`:

```ts
async function sendOtpCode(c: Context<AppEnv>, normalized: string): Promise<string> {
  const code = sixDigitCode();
  const codeHash = await sha256Hex(code);
  const emailHash = await sha256Hex(normalized);
  const expiresAtMs = nowMs() + OTP_TTL_SECONDS * 1000;
  await c.env.KV.put(
    `oc:${emailHash}`,
    JSON.stringify({ codeHash, email: normalized, attempts: 0, expiresAtMs }),
    { expirationTtl: OTP_TTL_SECONDS },
  );
  if (c.env.E2E_TEST_MODE === "1") {
    // E2E: always send (best-effort) so the harness can observe the seam; cap does not apply.
    try {
      await sendSignInCode(c.env, { to: normalized, code });
    } catch {
      // E2E-only: ignore the missing/failing local SendEmail binding.
    }
  } else if (await allowOtpSend(c, emailHash)) {
    // Background send (waitUntil) so a slow/failing provider can't block the request.
    c.executionCtx.waitUntil(
      sendSignInCode(c.env, { to: normalized, code }).catch((err) => {
        console.error("otp email send failed", err);
      }),
    );
  }
  // else: daily send cap reached — skip the email; KV code + 202 response are unchanged.
  return code;
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `npx vitest run test/auth.otp-sendcap.test.ts`
Expected: PASS (send called 6 times; 7th request 202 with no send; KV code present).

- [ ] **Step 6: Run the full auth suite for regressions**

Run: `npx vitest run test/auth.otp.test.ts test/auth.otp-email.test.ts test/auth.password.test.ts test/auth-security.test.ts`
Expected: PASS (existing tests use ≤ a couple requests per email, well under the cap).

- [ ] **Step 7: Commit**

```bash
git add src/routes/auth.ts test/auth.otp-sendcap.test.ts
git commit -m "feat(auth): cap sign-in code emails at 6/address/day (anti OTP-bombing)"
```

---

### Task 2: Tighten auth rate-limit tiers

**Files:**
- Modify: `src/middleware/rateLimit.ts` (tiers + the `kind === "auth"` block; export `consume`)
- Modify: `test/rateLimit.test.ts` (the existing per-email 8/hr assertion → 4/hr)
- Test: `test/rateLimit.test.ts` (add a daily-IP-cap unit test)

**Interfaces:**
- Consumes: existing `RATE_LIMIT_TIERS`, `consume(kv, tier, identity, now)`.
- Produces: `RATE_LIMIT_TIERS.authEmail.limit === 4`; new `RATE_LIMIT_TIERS.authIpDay`; `consume` is now exported for unit testing.

- [ ] **Step 1: Write the failing test (daily IP cap via `consume`)**

Add to `test/rateLimit.test.ts` (inside the top-level `describe` or a new one):

```ts
import { RATE_LIMIT_TIERS, consume } from "../src/middleware/rateLimit";

describe("authIpDay tier", () => {
  it("blocks the 61st auth op from one IP within a UTC day (across hour buckets)", async () => {
    const tier = RATE_LIMIT_TIERS.authIpDay;
    expect(tier.limit).toBe(60);
    const identity = "ip:203.0.113.99";
    // Advance `now` by >1h each call so the HOURLY bucket differs but the DAY bucket is constant.
    const base = 1_700_000_000_000; // fixed ms inside one UTC day
    let last: number | null = 0;
    for (let i = 0; i < 60; i++) {
      last = await consume(env.KV, tier, identity, base + i * 61 * 60 * 1000);
      expect(last).toBeNull(); // first 60 permitted
    }
    const blocked = await consume(env.KV, tier, identity, base + 60 * 61 * 60 * 1000);
    expect(blocked).not.toBeNull(); // 61st blocked
    expect(blocked!).toBeGreaterThan(0);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/rateLimit.test.ts -t "authIpDay"`
Expected: FAIL — `consume` is not exported and `RATE_LIMIT_TIERS.authIpDay` is undefined.

- [ ] **Step 3: Add `DAY_MS`, the `authIpDay` tier, lower `authEmail`, export `consume`**

In `src/middleware/rateLimit.ts`:

Add near `HOUR_MS`/`MINUTE_MS`:
```ts
const DAY_MS = 24 * 60 * 60 * 1000;
```

In `RATE_LIMIT_TIERS`, change `authEmail` limit `8 → 4` and add `authIpDay` right after `authIp`:
```ts
  authIp: { name: "auth-ip", limit: 20, windowMs: HOUR_MS, dimension: "ip" },
  /** auth per-IP DAILY ceiling — bounds a single source across the day (the hourly cap trips
   *  first within any hour; this caps the multi-hour total). */
  authIpDay: { name: "auth-ip-day", limit: 60, windowMs: DAY_MS, dimension: "ip" },
  /** per-email cap on SEND ops (keyed by body email). Lowered 8→4 to blunt targeted OTP-bombing;
   *  a legit sign-up + a couple resends stays under it. Verify endpoints remain EXEMPT. */
  authEmail: { name: "auth-email", limit: 4, windowMs: HOUR_MS, dimension: "ip" },
```

Change the `consume` declaration from `async function consume(` to `export async function consume(`.

- [ ] **Step 4: Wire the daily IP cap into the `auth` branch**

In `rateLimit()`, inside `if (kind === "auth") {`, right after the existing hourly IP check, add the daily IP check:

```ts
      const ip = clientKeyForRoute(c, RATE_LIMIT_TIERS.authIp);
      const ipReset = await consume(kv, RATE_LIMIT_TIERS.authIp, ip, now);
      if (ipReset !== null) reject(ipReset);
      const ipDayReset = await consume(kv, RATE_LIMIT_TIERS.authIpDay, ip, now);
      if (ipDayReset !== null) reject(ipDayReset);
```

- [ ] **Step 5: Update the existing per-email cap assertion (8 → 4)**

In `test/rateLimit.test.ts`, find the test around line 111 that exercises the "8/email/hr" send cap and update its loop bound and comment from 8 to 4 (the 5th same-email `/otp/request` within the hour should now 429). Update any literal `8` in that test to `4` and adjust the expected number of allowed requests accordingly.

- [ ] **Step 6: Run the rate-limit suite**

Run: `npx vitest run test/rateLimit.test.ts`
Expected: PASS (updated per-email cap + new daily-IP-cap test).

- [ ] **Step 7: Commit**

```bash
git add src/middleware/rateLimit.ts test/rateLimit.test.ts
git commit -m "feat(auth): lower per-email hourly cap to 4 and add 60/IP/day auth cap"
```

---

### Task 3: Full suite + deploy Phase 1 + prod smoke

**Files:**
- No code; deploy + verification only.

- [ ] **Step 1: Run the full backend test suite**

Run: `npx vitest run`
Expected: PASS (all suites green). Do NOT proceed on any failure.

- [ ] **Step 2: Deploy to production**

Run: `npx wrangler deploy`
Expected: a new Worker version id is printed and `api.snapceipt.cc` routes bind.

- [ ] **Step 3: Prod smoke — confirm the daily send-cap holds end-to-end (throwaway address)**

Create a disposable inbox and request 7 codes; confirm only 6 emails arrive while all 7 return `202`:

```bash
API=https://api.mail.tm
DOMAIN=$(curl -s $API/domains | python3 -c "import sys,json;print(json.load(sys.stdin)['hydra:member'][0]['domain'])")
ADDR="capsmoke$RANDOM@$DOMAIN"; PW="Pw-$RANDOM!"
curl -s -X POST $API/accounts -H 'content-type: application/json' -d "{\"address\":\"$ADDR\",\"password\":\"$PW\"}" >/dev/null
TOKEN=$(curl -s -X POST $API/token -H 'content-type: application/json' -d "{\"address\":\"$ADDR\",\"password\":\"$PW\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
for i in $(seq 1 7); do
  echo -n "req $i -> "; curl -s -o /dev/null -w "%{http_code}\n" -X POST https://api.snapceipt.cc/auth/otp/request -H 'content-type: application/json' -d "{\"email\":\"$ADDR\"}"
done
sleep 5
echo "delivered:"; curl -s $API/messages -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json;print(len(json.load(sys.stdin)['hydra:member']))"
```
Expected: seven `202`s printed, and `delivered: 6` (the 7th send suppressed by the cap).

- [ ] **Step 4: Commit any notes / mark task complete**

No code commit required (deploy step). Record the deployed version id in the PR description.

---

### Task 4 (optional, ops): Cloudflare edge rules runbook

**Files:** none (Cloudflare dashboard config). Deliverable = documented, curl-verified rules.

- [ ] **Step 1: Rate-Limiting Rule (edge, runs before the Worker)**

Dashboard → `snapceipt.cc` zone → Security → WAF → Rate limiting rules → Create:
- If incoming requests match: `(http.request.uri.path in {"/auth/otp/request" "/auth/magic-link/request" "/auth/password/login" "/auth/apple"})`
- Rate: `30` requests per `1 minute` per client IP → Action: `Block`, duration `60s`.

- [ ] **Step 2: WAF custom rule — challenge non-app shape on auth paths**

Dashboard → Security → WAF → Custom rules → Create:
- Expression: `(starts_with(http.request.uri.path, "/auth/") and not any(http.request.headers.names[*] eq "x-device-id"))`
- Action: `Managed Challenge`.
- Note in the rule description: deterrent-only (headers are spoofable); the app always sends `X-Device-Id`, so genuine traffic passes.

- [ ] **Step 3: Verify the app path still passes and a bare curl is challenged/limited**

```bash
# App-shaped request (has X-Device-Id) — expect 202
curl -s -o /dev/null -w "app-shape: %{http_code}\n" -X POST https://api.snapceipt.cc/auth/otp/request \
  -H 'content-type: application/json' -H 'x-device-id: 00000000-0000-0000-0000-000000000000' \
  -d '{"email":"noone-'$RANDOM'@web-library.net"}'
# Bare request (no X-Device-Id) — expect a challenge/blocked status (403/429/503), not 202
curl -s -o /dev/null -w "bare: %{http_code}\n" -X POST https://api.snapceipt.cc/auth/otp/request \
  -H 'content-type: application/json' -d '{"email":"noone-'$RANDOM'@web-library.net"}'
```
Expected: `app-shape: 202`; `bare:` a non-202 challenge/blocked code once the rule is active.
