# Go-live Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `snapceipt-api` Worker code production-ready for the go-live milestone — rename the domain `snapceipt.app` → `snapceipt.cc`, add the `GET /auth/magic` custom-scheme bridge that completes magic-link sign-in, and pin the DeepSeek model — all behind green test suites.

**Architecture:** Pure code/config changes to the existing Hono Worker (`src/`). No new dependencies, no schema/migration changes, no behavioural change to auth/sync/extract beyond the additive bridge route. The actual resource provisioning, secrets, Email-Send onboarding, deploy, and end-to-end verification are an **operator runbook** (spec §2/§7/§8), NOT tasks in this plan.

**Tech Stack:** TypeScript, Hono, Cloudflare Workers (D1/KV/R2/Email Send), Vitest (`@cloudflare/vitest-pool-workers`), wrangler v4.

**Spec:** `docs/superpowers/specs/2026-06-02-go-live-backend-design.md` (§4 Track B/C/D, §5, §6 are the contract).

**Cross-plan contract (canonical new values — must match the iOS plan):**
- API origin: `https://api.snapceipt.cc`
- Magic-link bridge URL: `https://api.snapceipt.cc/auth/magic`
- Email sender: `noreply@snapceipt.cc`
- Email-in alias domain: `in.snapceipt.cc`
- Custom scheme (unchanged): `snapceipt://auth/verify?token=…`
- Bundle id (**NOT renamed**): `com.snapceipt.app`

**Baselines (confirmed):** `npm test` = 320, `npm run test:e2e` = 19, `npm run typecheck` clean.

---

## Task 1: Domain rename `snapceipt.app` → `snapceipt.cc` (backend)

Rename every hostname/email reference. The bundle id `com.snapceipt.app` is an identifier, not a hostname — leave it untouched. The pattern-targeted replacements below (`in.snapceipt.app`, `noreply@snapceipt.app`, `//snapceipt.app`, `api.snapceipt.app`) never match `com.snapceipt.app`, so the bundle id is safe.

**Files:**
- Modify (source): `src/lib/email.ts:11`, `src/routes/auth.ts:56`, `src/lib/inboxToken.ts:5`, `src/routes/quotes.ts:159`, `src/routes/export.ts:156`, `src/lib/csvExport.ts:30` (comment), `src/index.ts:14` (comment), `wrangler.jsonc:29` + `:23` (comment)
- Modify (tests — assertions that genuinely fail until source changes): `test/inboxToken.test.ts`, `test/inbound.test.ts`, `test/inbox-routes.test.ts`, `test/email.test.ts`, `test/email-quote.test.ts`, `e2e/inbox.e2e.test.ts`
- Modify (test — cosmetic, host is ignored): `test/sync-push.test.ts:75`
- **Do NOT touch** (excepted bundle id `com.snapceipt.app`): `test/apns.test.ts`, `e2e/{extract,snapceipt,snapceipt-export,devices,quotes,account}.e2e.test.ts`, `vitest.config.ts`

- [ ] **Step 1: Update the test assertions to expect `snapceipt.cc` (the failing tests)**

Apply these exact replacements:

`test/inboxToken.test.ts` — replace all `in.snapceipt.app` → `in.snapceipt.cc` and `noreply@snapceipt.app` → `noreply@snapceipt.cc` (lines 42, 43, 47, 49, 50). After:
```ts
  it("addressForToken formats r.<token>@in.snapceipt.cc", () => {
    expect(addressForToken("abc")).toBe("r.abc@in.snapceipt.cc");
```
```ts
    expect(tokenFromRecipient("r.deadbeef@in.snapceipt.cc")).toBe("deadbeef");
```
```ts
    expect(tokenFromRecipient("noreply@snapceipt.cc")).toBeNull();
    expect(tokenFromRecipient("r.@in.snapceipt.cc")).toBeNull();
```

`test/inbound.test.ts` — line 83 `to: "r.deadbeefdeadbeefdeadbeefdeadbeef@in.snapceipt.cc",`; line 93 `to: "noreply@snapceipt.cc", ...`.

`test/inbox-routes.test.ts` — lines 42 & 68: `` `r.${body.token}@in.snapceipt.cc` `` and `` `r.${rotated.token}@in.snapceipt.cc` ``.

`test/email.test.ts:71` — `expect(captured.from).toBe("noreply@snapceipt.cc");`

`test/email-quote.test.ts:51` — `expect(captured.from).toBe("noreply@snapceipt.cc");`

`e2e/inbox.e2e.test.ts:104` — `` expect(got.json.address).toBe(`r.${got.json.token}@in.snapceipt.cc`); ``

`test/sync-push.test.ts:75` — `return SELF.fetch("https://api.snapceipt.cc/sync/push", {` (cosmetic; host is ignored by `SELF.fetch`).

- [ ] **Step 2: Run the affected unit tests to verify they fail**

Run: `npx vitest run test/inboxToken.test.ts test/inbound.test.ts test/inbox-routes.test.ts test/email.test.ts test/email-quote.test.ts`
Expected: FAIL — assertions expect `…@in.snapceipt.cc` / `noreply@snapceipt.cc` but the source still emits `…snapceipt.app`.

- [ ] **Step 3: Update the source constants**

```ts
// src/lib/email.ts:11
const MAGIC_LINK_SENDER = "noreply@snapceipt.cc";
```
```ts
// src/routes/auth.ts:56
const MAGIC_LINK_BASE_URL = "https://api.snapceipt.cc/auth/magic";
```
```ts
// src/lib/inboxToken.ts:5
const INBOX_DOMAIN = "in.snapceipt.cc";
```
```ts
// src/routes/quotes.ts:159
      replyTo: trader?.email ?? "noreply@snapceipt.cc",
```
```ts
// src/routes/export.ts:156
      replyTo: user?.email ?? "noreply@snapceipt.cc",
```
```ts
// src/lib/csvExport.ts:30  (comment)
  /** e.g. "https://api.snapceipt.cc" — the public origin for the dl link. */
```
```ts
// src/index.ts:14  (comment)
 * Inbound Email Routing handler (catch-all on in.snapceipt.cc). Thin wrapper:
```
```jsonc
// wrangler.jsonc:23 (comment) and :29
  // Inbound Email Routing (F6): provision a catch-all on the in.snapceipt.cc zone
  ...
    { "name": "EMAIL", "allowed_sender_addresses": ["noreply@snapceipt.cc"] }
```

- [ ] **Step 4: Run the full unit + e2e suites + typecheck**

Run: `npm test`
Expected: PASS — 320 tests.

Run: `npm run test:e2e`
Expected: PASS — 19 tests.

Run: `npm run typecheck`
Expected: no output (clean).

- [ ] **Step 5: Verify no hostname reference lingers (bundle id excepted)**

Run: `grep -rn 'snapceipt\.app' src test e2e wrangler.jsonc | grep -v 'com\.snapceipt\.app'`
Expected: no output (every hostname renamed; only the `com.snapceipt.app` bundle id remains, filtered out).

- [ ] **Step 6: Commit**

```bash
git add src test e2e wrangler.jsonc
git commit -m "refactor(go-live): rename snapceipt.app -> snapceipt.cc (backend + tests)"
```

---

## Task 2: `GET /auth/magic` bridge route

A new public route that turns the magic-link URL (`https://api.snapceipt.cc/auth/magic?token=…`) into the registered custom scheme `snapceipt://auth/verify?token=…`, which the iOS app already handles. It performs **no** verification — the single-use, TTL-bound check stays in `POST /auth/magic-link/verify`. Magic tokens are base64url (`[A-Za-z0-9_-]`), so the route validates that charset and 400s on anything else (which also makes interpolation injection-safe).

**Files:**
- Modify: `src/routes/auth.ts` (add the route after the `magic-link/verify` handler block, before the Apple route)
- Test: `test/auth.magiclink.test.ts`

- [ ] **Step 1: Write the failing tests**

Append to `test/auth.magiclink.test.ts` (after the existing `describe` blocks):
```ts
describe("GET /auth/magic (bridge)", () => {
  it("serves an HTML page that forwards a valid token to the snapceipt:// scheme", async () => {
    const res = await SELF.fetch("https://x/auth/magic?token=abc123_TOK-en");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("referrer-policy")).toBe("no-referrer");
    const html = await res.text();
    expect(html).toContain("snapceipt://auth/verify?token=abc123_TOK-en");
  });

  it("returns 400 and does NOT emit a scheme link when the token is missing", async () => {
    const res = await SELF.fetch("https://x/auth/magic");
    expect(res.status).toBe(400);
    const html = await res.text();
    expect(html).not.toContain("snapceipt://auth/verify");
  });

  it("returns 400 when the token contains non-base64url characters", async () => {
    const res = await SELF.fetch("https://x/auth/magic?token=bad%20token%3Cscript%3E");
    expect(res.status).toBe(400);
    const html = await res.text();
    expect(html).not.toContain("snapceipt://auth/verify");
  });
});
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `npx vitest run test/auth.magiclink.test.ts -t "bridge"`
Expected: FAIL — `GET /auth/magic` is not registered (404), so status/body assertions fail.

- [ ] **Step 3: Implement the route**

Add to `src/routes/auth.ts`, immediately after the `authRoutes.post("/magic-link/verify", …)` handler closes (before the Apple `/apple` route):
```ts
/**
 * GET /auth/magic — bridge page for the magic-link email.
 *
 * The email links to https://api.snapceipt.cc/auth/magic?token=… . This page
 * forwards the token to the registered custom scheme snapceipt://auth/verify?token=…
 * which the iOS app (AuthViewModel/MagicLinkParser) handles → POST /auth/magic-link/verify.
 * No verification happens here; the single-use, TTL-bound check is in /magic-link/verify.
 * Universal Links/AASA are out of scope for the go-live milestone, so this bridge is the
 * path from a tapped/opened https link to the app.
 *
 * Magic tokens are base64url ([A-Za-z0-9_-], see newMagicToken). We reject anything else
 * so the value is safe to interpolate and we never forward a malformed link.
 */
authRoutes.get("/magic", (c) => {
  const headers = {
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
  };
  const token = c.req.query("token") ?? "";
  if (token.length === 0 || !/^[A-Za-z0-9_-]+$/.test(token)) {
    return c.html(
      `<!doctype html><meta charset="utf-8"><title>Snapceipt</title>` +
        `<p>This sign-in link is invalid or has expired. Request a new one from the Snapceipt app.</p>`,
      400,
      headers,
    );
  }
  const deep = `snapceipt://auth/verify?token=${token}`;
  return c.html(
    `<!doctype html><html><head><meta charset="utf-8">` +
      `<meta name="viewport" content="width=device-width, initial-scale=1">` +
      `<title>Signing in to Snapceipt…</title>` +
      `<meta http-equiv="refresh" content="0;url=${deep}">` +
      `<script>location.replace(${JSON.stringify(deep)});</script></head>` +
      `<body style="font-family:-apple-system,system-ui,sans-serif;text-align:center;padding:3rem 1.5rem">` +
      `<p>Opening Snapceipt…</p>` +
      `<p><a href="${deep}">Open in Snapceipt</a></p>` +
      `<p style="color:#666">Return to the Snapceipt app to finish signing in.</p>` +
      `</body></html>`,
    200,
    headers,
  );
});
```

- [ ] **Step 4: Run the new tests to verify they pass**

Run: `npx vitest run test/auth.magiclink.test.ts`
Expected: PASS (the bridge + existing magic-link tests).

- [ ] **Step 5: Run the full suite + typecheck**

Run: `npm test`
Expected: PASS — 323 tests (320 + 3 new).

Run: `npm run typecheck`
Expected: no output (clean).

- [ ] **Step 6: Commit**

```bash
git add src/routes/auth.ts test/auth.magiclink.test.ts
git commit -m "feat(go-live): GET /auth/magic bridge to snapceipt:// scheme"
```

---

## Task 3: Pin the DeepSeek model in `wrangler.jsonc`

`src/lib/deepseek.ts` reads `env.DEEPSEEK_MODEL ?? "deepseek-chat"`. Spec §6 says to pin the model rather than rely on the default. `deepseek-chat` is valid until its 2026-07-24 deprecation; the operator confirms the current live id at provisioning time and updates this value if a successor is documented.

**Files:**
- Modify: `wrangler.jsonc` (the `vars` block)

- [ ] **Step 1: Add the `DEEPSEEK_MODEL` var**

In `wrangler.jsonc`, extend `vars`:
```jsonc
  "vars": {
    "APPLE_BUNDLE_ID": "com.snapceipt.app",
    "DEEPSEEK_MODEL": "deepseek-chat"
  }
```
> Operator note: confirm `deepseek-chat` (or its documented successor) against DeepSeek's live model list before deploy; this is a non-secret var, the API key stays a secret.

- [ ] **Step 2: Verify config + suites still pass**

Run: `npm run typecheck`
Expected: no output (clean).

Run: `npm test`
Expected: PASS — 323 tests (tests inject env via `vitest.config.ts`; the added var is inert in the test runtime).

- [ ] **Step 3: Commit**

```bash
git add wrangler.jsonc
git commit -m "chore(go-live): pin DEEPSEEK_MODEL var"
```

---

## Operator runbook (NOT plan tasks — performed by the account owner)

These are real-world provisioning steps from spec §2/§7/§8, done after the code tasks above (and require wrangler v4 + the re-logged-in `techsiderau@gmail.com` account):

1. `npm install --save-dev wrangler@4` (hard prerequisite — the `wrangler email …` family + `allowed_sender_addresses` need v4).
2. `wrangler d1 create snapceipt` / `kv namespace create KV` / `r2 bucket create snapceipt-receipts` → paste real ids + `"account_id": "bb4412973b5e4f6d7a10a4e68b713177"` into `wrangler.jsonc`.
3. `wrangler secret put JWT_SIGNING_KEY` (`openssl rand -base64 48`) + `wrangler secret put DEEPSEEK_API_KEY`.
4. `wrangler email sending enable snapceipt.cc` (auto-injects SPF+DKIM) → `wrangler email sending dns get snapceipt.cc` to confirm.
5. `wrangler d1 migrations apply snapceipt --remote` → `wrangler deploy` → attach the `api.snapceipt.cc` custom domain.
6. Verify per spec §8 (health, magic-link sign-in via `simctl openurl`, real DeepSeek extraction, sync round-trip).

---

## Self-review (completed during authoring)

- **Spec coverage:** Track B rename → Task 1; Track C bridge → Task 2; Track D DeepSeek model → Task 3; Track A/E + deploy + verify → operator runbook (intentionally not code tasks). ✓
- **Placeholder scan:** no TBD/TODO; every code/test step shows full content. ✓
- **Type/name consistency:** `MAGIC_LINK_SENDER`, `MAGIC_LINK_BASE_URL`, `INBOX_DOMAIN`, `authRoutes`, `c.html(body, status, headers)`, `c.req.query("token")` all match the existing code (`src/routes/auth.ts:130` uses `c.body(null, 202)`; `c.html` is the standard Hono helper). ✓
- **Bundle-id exception** explicit in Task 1 (the 7 excepted backend files + `vitest.config.ts`). ✓
