# F7 Settings — Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The F7 account-backend: change-email via a 6-digit code (`POST /users/me/email` + `/verify`), an irreversible delete-account purge (`DELETE /account`), and tests for the **already-existing** `DELETE /devices/:id` revoke.

**Architecture:** A new `src/routes/account.ts` Hono router (mounted with a tight `account` rate tier) holds the change-email + delete-account routes. Change-email mirrors the magic-link KV pattern (a hashed code in KV under `ec:<userId>`, 600s TTL). Delete-account hard-deletes every user-scoped D1 row in FK-safe order via one `db.batch`, then paginates the user's R2 objects away. No new D1 tables.

**Tech Stack:** TypeScript, Hono, Cloudflare D1 + KV + R2, vitest (`@cloudflare/vitest-pool-workers`) + `unstable_dev` e2e.

**Authoritative contract:** §8 of `docs/superpowers/specs/2026-06-02-settings-design.md`. Do not deviate.

**Baseline (capture first):** run `npm test` + `npm run test:e2e` and record counts (≈309 unit / 17 e2e). Keep the full suite green; only ADD tests.

**Already exists — do NOT rebuild:** `DELETE /devices/:id` is implemented in `src/routes/devices.ts` (verifies ownership → revokes each session family via `revokeSessionFamily` → tombstones the device → `{ ok: true }`; 404 if not owned). Task 5 only adds a test for it. `GET /auth/me` already returns `{ user, devices[] }`.

---

### Task 1: `account` rate tier + `GONE` error code

**Files:**
- Modify: `src/middleware/rateLimit.ts`
- Modify: `src/lib/errors.ts`
- Test: `test/rateLimit.test.ts` (existing — add one case)

- [ ] **Step 1: Add a failing assertion**

Append to `test/rateLimit.test.ts` (inside the existing top-level `describe`, or add one) — adjust the import to match the file's existing import of `RATE_LIMIT_TIERS`:

```typescript
import { RATE_LIMIT_TIERS } from "../src/middleware/rateLimit";
import { ERROR } from "../src/lib/errors";

describe("F7 tiers + error codes", () => {
  it("defines an 'account' tier (per-user, hourly)", () => {
    expect(RATE_LIMIT_TIERS.account).toEqual({ name: "account", limit: 60, windowMs: 60 * 60 * 1000, dimension: "user" });
  });
  it("maps GONE to 410", () => {
    expect(ERROR.GONE).toBe(410);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npx vitest run test/rateLimit.test.ts`
Expected: FAIL — `RATE_LIMIT_TIERS.account` undefined / `ERROR.GONE` undefined.

- [ ] **Step 3: Add the tier + code**

In `src/middleware/rateLimit.ts`, add to `RATE_LIMIT_TIERS` (after the `inbox` entry):

```typescript
  /** account ops (change email / delete account) — tight per-user tier. */
  account: { name: "account", limit: 60, windowMs: HOUR_MS, dimension: "user" },
```

Extend the union:

```typescript
export type RateLimitKind = "auth" | "sync" | "extract" | "export" | "quotes" | "inbox" | "account" | "default";
```

In the `rateLimit(kind)` factory ternary, add the arm before the final `: RATE_LIMIT_TIERS.default`:

```typescript
              : kind === "inbox"
                ? RATE_LIMIT_TIERS.inbox
                : kind === "account"
                  ? RATE_LIMIT_TIERS.account
                  : RATE_LIMIT_TIERS.default;
```

In `src/lib/errors.ts`, add to the `ERROR` map (after `CONFLICT: 409,`):

```typescript
  GONE: 410,
```

- [ ] **Step 4: Run it to verify it passes**

Run: `npx vitest run test/rateLimit.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/middleware/rateLimit.ts src/lib/errors.ts test/rateLimit.test.ts
git commit -m "$(cat <<'EOF'
feat(F7): add 'account' rate tier + GONE(410) error code

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `sendEmailChangeCode` email helper

**Files:**
- Modify: `src/lib/email.ts`
- Test: `test/email.test.ts` (existing — add a spy case mirroring the magic-link test)

- [ ] **Step 1: Write the failing test**

Add to `test/email.test.ts` (mirror how the existing test exercises `sendMagicLinkEmail` — use the same `env.EMAIL` spy/stub approach already in that file):

```typescript
import { sendEmailChangeCode } from "../src/lib/email";

describe("sendEmailChangeCode", () => {
  it("calls env.EMAIL.send with the code in the body", async () => {
    const sent: any[] = [];
    const env = { EMAIL: { send: async (m: any) => { sent.push(m); } } } as any;
    await sendEmailChangeCode(env, { to: "new@example.com", code: "123456" });
    expect(sent).toHaveLength(1);
    expect(sent[0].to).toBe("new@example.com");
    expect(sent[0].text).toContain("123456");
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npx vitest run test/email.test.ts`
Expected: FAIL — `sendEmailChangeCode` is not exported.

- [ ] **Step 3: Implement it**

In `src/lib/email.ts`, after `sendMagicLinkEmail`, add (mirrors that function exactly):

```typescript
export interface EmailChangeCode {
  to: string;
  code: string;
}

/**
 * Send the 6-digit email-change confirmation code via the SendEmail builder
 * overload (same path as sendMagicLinkEmail). Failures surface as a thrown error.
 */
export async function sendEmailChangeCode(env: Env, msg: EmailChangeCode): Promise<void> {
  await env.EMAIL.send({
    from: { name: "Snapceipt", email: MAGIC_LINK_SENDER },
    to: msg.to,
    subject: "Confirm your new Snapceipt email",
    text:
      `Your Snapceipt email-change code is: ${msg.code}\n\n` +
      `Enter it in the app to confirm. It expires in 10 minutes and can be used once. ` +
      `If you didn't request this, ignore this email.`,
  });
}
```

(`MAGIC_LINK_SENDER` and the `Env` import already exist at the top of the file.)

- [ ] **Step 4: Run it to verify it passes**

Run: `npx vitest run test/email.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/email.ts test/email.test.ts
git commit -m "$(cat <<'EOF'
feat(F7): sendEmailChangeCode email helper

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Change-email routes (`POST /users/me/email` + `/verify`)

**Files:**
- Create: `src/routes/account.ts`
- Modify: `src/app.ts` (import + `/users/*` limiter + mount)
- Test: `test/account-email.test.ts`

- [ ] **Step 1: Write the failing test**

Create `test/account-email.test.ts`:

```typescript
import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

async function seedUser(email = "old@example.com"): Promise<{ userId: string; bearer: string }> {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(userId, email, t, t).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at) VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, t, t).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, bearer: `Bearer ${accessToken}` };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

describe("POST /users/me/email (+ /verify)", () => {
  it("issues a code (devCode in E2E) and verifying it swaps the email", async () => {
    const { userId, bearer } = await seedUser();
    const req = await SELF.fetch("https://x/users/me/email", {
      method: "POST", headers: { authorization: bearer, "content-type": "application/json" },
      body: JSON.stringify({ newEmail: "new@example.com" }),
    });
    expect(req.status).toBe(202);
    const { sent, devCode } = (await req.json()) as { sent: boolean; devCode?: string };
    expect(sent).toBe(true);
    expect(devCode).toMatch(/^\d{6}$/);

    const ver = await SELF.fetch("https://x/users/me/email/verify", {
      method: "POST", headers: { authorization: bearer, "content-type": "application/json" },
      body: JSON.stringify({ code: devCode }),
    });
    expect(ver.status).toBe(200);
    expect(((await ver.json()) as any).user.email).toBe("new@example.com");
    const row = await env.DB.prepare("SELECT email FROM users WHERE id = ?").bind(userId).first<{ email: string }>();
    expect(row!.email).toBe("new@example.com");
  });

  it("409s when the new email is already used by another user", async () => {
    const { bearer } = await seedUser("me@example.com");
    const t = nowMs();
    await env.DB.prepare(`INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, 'taken@example.com', 1, 'free', ?, ?)`).bind(uuidv7(), t, t).run();
    const req = await SELF.fetch("https://x/users/me/email", {
      method: "POST", headers: { authorization: bearer, "content-type": "application/json" },
      body: JSON.stringify({ newEmail: "taken@example.com" }),
    });
    expect(req.status).toBe(409);
  });

  it("400s on a wrong code", async () => {
    const { bearer } = await seedUser();
    await SELF.fetch("https://x/users/me/email", {
      method: "POST", headers: { authorization: bearer, "content-type": "application/json" },
      body: JSON.stringify({ newEmail: "new@example.com" }),
    });
    const ver = await SELF.fetch("https://x/users/me/email/verify", {
      method: "POST", headers: { authorization: bearer, "content-type": "application/json" },
      body: JSON.stringify({ code: "000000" }),
    });
    // 400 wrong code OR 410 if the random code happened to be 000000 (then it was consumed) — accept either failure
    expect([400, 410]).toContain(ver.status);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npx vitest run test/account-email.test.ts`
Expected: FAIL — `/users/me/email` 404 (no route mounted).

- [ ] **Step 3: Create `src/routes/account.ts`**

```typescript
// src/routes/account.ts
import { Hono } from "hono";
import { z } from "zod";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { nowMs } from "../lib/time";
import { validate } from "./auth";
import { sendEmailChangeCode } from "../lib/email";

/**
 * Account routes (auth-gated; rate tier "account"):
 *  POST /users/me/email         — request a 6-digit code to the NEW address
 *  POST /users/me/email/verify  — confirm the code, swap users.email
 *  DELETE /account              — irreversible hard purge of the user's data (Task 4)
 */
export const accountRoutes = new Hono<AppEnv>();

const EMAIL_CODE_TTL_SECONDS = 600;

function normalizeEmail(e: string): string {
  return e.trim().toLowerCase();
}
async function sha256Hex(input: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function sixDigitCode(): string {
  const n = crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000;
  return n.toString().padStart(6, "0");
}

const emailBody = z.object({ newEmail: z.string().email() });
const verifyBody = z.object({ code: z.string().regex(/^\d{6}$/) });

accountRoutes.post("/users/me/email", validate("json", emailBody), async (c) => {
  const userId = c.var.userId;
  const newEmail = normalizeEmail(c.req.valid("json").newEmail);

  const me = await c.env.DB.prepare("SELECT email FROM users WHERE id = ? AND deleted_at IS NULL")
    .bind(userId).first<{ email: string | null }>();
  if (!me) throw new ApiError("NOT_FOUND", "User not found");
  if (me.email && normalizeEmail(me.email) === newEmail) {
    throw new ApiError("CONFLICT", "That is already your email");
  }
  const taken = await c.env.DB.prepare(
    "SELECT 1 FROM users WHERE email = ? AND id <> ? AND deleted_at IS NULL",
  ).bind(newEmail, userId).first();
  if (taken) throw new ApiError("CONFLICT", "Email already in use");

  const code = sixDigitCode();
  const codeHash = await sha256Hex(code);
  await c.env.KV.put(`ec:${userId}`, JSON.stringify({ codeHash, newEmail }), {
    expirationTtl: EMAIL_CODE_TTL_SECONDS,
  });

  const e2e = c.env.E2E_TEST_MODE === "1";
  if (e2e) {
    try { await sendEmailChangeCode(c.env, { to: newEmail, code }); } catch { /* no local EMAIL binding in e2e */ }
    return c.json({ sent: true, devCode: code }, 202);
  }
  await sendEmailChangeCode(c.env, { to: newEmail, code });
  return c.json({ sent: true }, 202);
});

accountRoutes.post("/users/me/email/verify", validate("json", verifyBody), async (c) => {
  const userId = c.var.userId;
  const { code } = c.req.valid("json");

  const raw = await c.env.KV.get(`ec:${userId}`);
  if (!raw) throw new ApiError("GONE", "No pending email change");
  const { codeHash, newEmail } = JSON.parse(raw) as { codeHash: string; newEmail: string };
  if ((await sha256Hex(code)) !== codeHash) throw new ApiError("VALIDATION_FAILED", "Incorrect code");

  const taken = await c.env.DB.prepare(
    "SELECT 1 FROM users WHERE email = ? AND id <> ? AND deleted_at IS NULL",
  ).bind(newEmail, userId).first();
  if (taken) throw new ApiError("CONFLICT", "Email already in use");

  const now = nowMs();
  await c.env.DB.prepare("UPDATE users SET email = ?, email_verified = 1, updated_at = ? WHERE id = ?")
    .bind(newEmail, now, userId).run();
  await c.env.KV.delete(`ec:${userId}`);

  const u = await c.env.DB.prepare("SELECT id, email, display_name, plan FROM users WHERE id = ?")
    .bind(userId).first<{ id: string; email: string | null; display_name: string | null; plan: string }>();
  return c.json({ user: { id: u!.id, email: u!.email, displayName: u!.display_name, plan: u!.plan } });
});
```

- [ ] **Step 4: Mount in `src/app.ts`**

Add the import near the other route imports:

```typescript
import { accountRoutes } from "./routes/account";
```

Add the limiter mount (after the `/profiles/*` inbox limiter):

```typescript
// Account ops (change email / delete account) — tight per-user tier. Auth-gated.
app.use("/users/*", rateLimit("account"));
app.use("/account", rateLimit("account"));
```

Add the route mount (after the `/profiles` mount, before `app.route("/", miscRoutes)`):

```typescript
// Protected: account ops (change email via code, delete account).
app.route("/", accountRoutes);
```

(`accountRoutes` defines absolute paths `/users/me/email`, `/users/me/email/verify`, `/account`, so it mounts at root.)

- [ ] **Step 5: Run it to verify it passes**

Run: `npx vitest run test/account-email.test.ts`
Expected: PASS (3 passed).

- [ ] **Step 6: Typecheck + commit**

Run: `npm run typecheck`
Expected: no errors.

```bash
git add src/routes/account.ts src/app.ts test/account-email.test.ts
git commit -m "$(cat <<'EOF'
feat(F7): change-email via 6-digit code (POST /users/me/email + /verify)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Delete account (`DELETE /account` — D1 purge + R2 purge)

**Files:**
- Modify: `src/routes/account.ts` (add the route + `PURGE_ORDER`)
- Test: `test/account-delete.test.ts`

- [ ] **Step 1: Write the failing test**

Create `test/account-delete.test.ts`:

```typescript
import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

async function seedRichUser(): Promise<{ userId: string; bearer: string; r2Key: string }> {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const profileId = uuidv7();
  const txnId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(`INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`).bind(userId, `${userId}@e.com`, t, t).run();
  await env.DB.prepare(`INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at) VALUES (?, ?, 'ios', 1, ?, ?)`).bind(deviceId, userId, t, t).run();
  await env.DB.prepare(`INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3, created_at, updated_at) VALUES (?, ?, 'Biz', 'business', '#0','#1','#2', ?, ?)`).bind(profileId, userId, t, t).run();
  await env.DB.prepare(`INSERT INTO transactions (id, user_id, profile_id, merchant, cat_key, amount_cents, currency, txn_date, mode, is_ai, source, created_at, updated_at, rev) VALUES (?, ?, ?, 'X', 'office', -100, 'AUD', '2026-06-01', 'business', 0, 'manual', ?, ?, 0)`).bind(txnId, userId, profileId, t, t).run();
  const r2Key = `u/${userId}/x.jpg`;
  await env.RECEIPTS.put(r2Key, new TextEncoder().encode("img").buffer);
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, bearer: `Bearer ${accessToken}`, r2Key };
}

beforeEach(async () => {
  for (const t of ["transactions", "profiles", "sessions", "devices", "users"]) {
    await env.DB.exec(`DELETE FROM ${t}`);
  }
});

describe("DELETE /account", () => {
  it("purges all D1 rows + R2 objects for the user", async () => {
    const { userId, bearer, r2Key } = await seedRichUser();
    const res = await SELF.fetch("https://x/account", { method: "DELETE", headers: { authorization: bearer } });
    expect(res.status).toBe(200);

    for (const table of ["users", "profiles", "transactions", "devices"]) {
      const row = await env.DB.prepare(`SELECT COUNT(*) c FROM ${table} WHERE user_id = ?`).bind(userId).first<{ c: number }>();
      expect(row!.c).toBe(0);
    }
    const obj = await env.RECEIPTS.get(r2Key);
    expect(obj).toBeNull();
  });

  it("does not touch another user's data", async () => {
    const a = await seedRichUser();
    const b = await seedRichUser();
    await SELF.fetch("https://x/account", { method: "DELETE", headers: { authorization: a.bearer } });
    const bRows = await env.DB.prepare("SELECT COUNT(*) c FROM transactions WHERE user_id = ?").bind(b.userId).first<{ c: number }>();
    expect(bRows!.c).toBe(1);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npx vitest run test/account-delete.test.ts`
Expected: FAIL — `DELETE /account` 404.

- [ ] **Step 3: Add the route to `src/routes/account.ts`**

At the top of the file (after the imports), add the FK-safe ordered table list:

```typescript
/** Every user-scoped table, child→parent so the FK-enforced batch never violates a constraint. */
const PURGE_ORDER = [
  "line_items", "quote_line_items", "receipt_images",
  "transactions",
  "smart_rules", "budgets",
  "mileage_trips", "vehicle_years",
  "vehicles",
  "categories",
  "quotes",
  "clients", "tax_settings", "loyalty_cards", "wfh_logs",
  "inbound_email_log", "profile_inbox_tokens", "quote_counters",
  "email_outbox", "processed_mutations", "sessions", "devices", "auth_identities",
  "profiles",
  "users",
] as const;
```

Add the handler (after the verify route):

```typescript
accountRoutes.delete("/account", async (c) => {
  const userId = c.var.userId;

  // 1. Hard-delete every user-scoped row atomically (one transaction, FK-safe order).
  await c.env.DB.batch(
    PURGE_ORDER.map((t) => c.env.DB.prepare(`DELETE FROM ${t} WHERE user_id = ?`).bind(userId)),
  );

  // 2. Purge the user's R2 objects (paginated list -> delete).
  let cursor: string | undefined;
  for (;;) {
    const listed = await c.env.RECEIPTS.list({ prefix: `u/${userId}/`, cursor, limit: 1000 });
    const keys = listed.objects.map((o) => o.key);
    if (keys.length > 0) await c.env.RECEIPTS.delete(keys);
    if (!listed.truncated) break;
    cursor = listed.cursor;
  }

  return c.json({ ok: true });
});
```

Note: `users.user_id` equals `users.id` (set by the `trg_users_user_id` trigger on insert), so `DELETE FROM users WHERE user_id = ?` correctly removes the row. `email_tokens` has no `user_id` column and is unused in code (magic-link tokens live in KV), so it is intentionally not in `PURGE_ORDER`.

- [ ] **Step 4: Run it to verify it passes**

Run: `npx vitest run test/account-delete.test.ts`
Expected: PASS (2 passed).

- [ ] **Step 5: Typecheck + commit**

Run: `npm run typecheck`
Expected: no errors.

```bash
git add src/routes/account.ts test/account-delete.test.ts
git commit -m "$(cat <<'EOF'
feat(F7): DELETE /account — irreversible D1 + R2 purge

One FK-safe db.batch across all 25 user-scoped tables, then paginated R2 delete
of u/<userId>/*. Isolation-tested against a second user.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Test the existing `DELETE /devices/:id`

**Files:**
- Test: `test/devices.test.ts` (existing — add a describe) or create `test/devices-revoke.test.ts` if cleaner.

`DELETE /devices/:id` already exists in `src/routes/devices.ts` (no implementation change). This task only locks in its behaviour with a test.

- [ ] **Step 1: Write the test**

Create `test/devices-revoke.test.ts`:

```typescript
import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

async function seed(): Promise<{ userId: string; deviceId: string; bearer: string }> {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(`INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`).bind(userId, `${userId}@e.com`, t, t).run();
  await env.DB.prepare(`INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at) VALUES (?, ?, 'ios', 1, ?, ?)`).bind(deviceId, userId, t, t).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, deviceId, bearer: `Bearer ${accessToken}` };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

describe("DELETE /devices/:id", () => {
  it("tombstones the device + revokes its sessions, dropping it from /auth/me", async () => {
    const { deviceId, bearer } = await seed();
    const del = await SELF.fetch(`https://x/devices/${deviceId}`, { method: "DELETE", headers: { authorization: bearer } });
    expect(del.status).toBe(200);
    const revoked = await env.DB.prepare("SELECT revoked_at FROM sessions WHERE device_id = ?").bind(deviceId).first<{ revoked_at: number | null }>();
    expect(revoked!.revoked_at).not.toBeNull();
    const me = await SELF.fetch("https://x/auth/me", { headers: { authorization: bearer } });
    // The current session was revoked by deleting its own device → 401.
    expect(me.status).toBe(401);
  });

  it("404s for another user's device", async () => {
    const { bearer } = await seed();
    const res = await SELF.fetch(`https://x/devices/${uuidv7()}`, { method: "DELETE", headers: { authorization: bearer } });
    expect(res.status).toBe(404);
  });
});
```

- [ ] **Step 2: Run it (should already pass against the existing route)**

Run: `npx vitest run test/devices-revoke.test.ts`
Expected: PASS (2 passed). If the first test 401s on the DELETE itself (because deleting the current device revokes mid-request), adjust by seeding a SECOND device and revoking that one instead — but the existing route revokes by family and the access token JWT remains valid until its own session is checked, so the DELETE returns 200; confirm and keep whichever assertion matches the actual middleware behaviour.

- [ ] **Step 3: Commit**

```bash
git add test/devices-revoke.test.ts
git commit -m "$(cat <<'EOF'
test(F7): lock in DELETE /devices/:id revoke behaviour

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: e2e — change-email + delete-account over real HTTP

**Files:**
- Create: `e2e/account.e2e.test.ts`

Mirror `e2e/inbox.e2e.test.ts` (the `unstable_dev` boot + `applyMigrations` + `api()` helper + magic-link sign-in). Copy that file's `beforeAll`/`afterAll`/`api` verbatim and change only the test bodies + the temp-dir name.

- [ ] **Step 1: Write the e2e test**

Create `e2e/account.e2e.test.ts` with the same harness as `e2e/inbox.e2e.test.ts` (imports, `repoRoot`, `JWT_SIGNING_KEY`, `applyMigrations`, `beforeAll` booting `unstable_dev` with `vars: { E2E_TEST_MODE: "1", JWT_SIGNING_KEY, APPLE_BUNDLE_ID }`, `afterAll`, and the `api()` helper), then:

```typescript
describe("e2e (real HTTP): account ops", () => {
  async function signIn(ip: string): Promise<{ auth: Record<string, string>; deviceId: string }> {
    const email = `e2e-acct+${Date.now()}-${ip}@example.com`;
    const deviceId = crypto.randomUUID();
    const reqRes = await api("/auth/magic-link/request", { method: "POST", headers: { "cf-connecting-ip": ip }, body: { email } });
    const verifyRes = await api("/auth/magic-link/verify", {
      method: "POST", headers: { "cf-connecting-ip": ip, "x-device-id": deviceId }, body: { token: reqRes.json.devToken },
    });
    return { auth: { authorization: `Bearer ${verifyRes.json.accessToken}` }, deviceId };
  }

  it("changes the email via the 6-digit code", async () => {
    const { auth } = await signIn("203.0.113.40");
    const req = await api("/users/me/email", { method: "POST", headers: auth, body: { newEmail: `changed+${Date.now()}@example.com` } });
    expect(req.status).toBe(202);
    const code = req.json.devCode as string;
    const ver = await api("/users/me/email/verify", { method: "POST", headers: auth, body: { code } });
    expect(ver.status).toBe(200);
    expect(ver.json.user.email).toContain("changed+");
    const me = await api("/auth/me", { headers: auth });
    expect(me.json.user.email).toContain("changed+");
  });

  it("deletes the account so subsequent authed calls 401", async () => {
    const { auth } = await signIn("203.0.113.41");
    const del = await api("/account", { method: "DELETE", headers: auth });
    expect(del.status).toBe(200);
    const after = await api("/auth/me", { headers: auth });
    expect(after.status).toBe(401);
  });
});
```

- [ ] **Step 2: Run the e2e suite**

Run: `npm run test:e2e`
Expected: all pass (baseline + 2 new).

- [ ] **Step 3: Commit**

```bash
git add e2e/account.e2e.test.ts
git commit -m "$(cat <<'EOF'
test(F7): e2e for change-email + delete-account (real HTTP)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Final verification

- [ ] **Step 1: Full suite**

Run: `npm run typecheck` → no errors. `npm test` → all pass (baseline + `rateLimit` additions + `email`, `account-email`, `account-delete`, `devices-revoke`). `npm run test:e2e` → all pass (baseline + 2).

- [ ] **Step 2: Commit if anything pending** (else no-op)

```bash
git commit -am "$(cat <<'EOF'
chore(F7 backend): account ops verified green

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)" || echo "nothing to commit"
```

---

## Self-Review

**Spec coverage (§8):** change-email request+verify (§8.1) → Tasks 2,3; device revoke (§8.2 — already exists) → Task 5; delete-account cascade + R2 purge (§8.3) → Task 4; `account` tier + GONE → Task 1; e2e → Task 6. ✓
**Placeholder scan:** every step has full code/commands; the one conditional (Task 5 Step 2 current-device-revoke assertion) names its exact fallback. ✓
**Type consistency:** `ec:<userId>` KV shape `{codeHash,newEmail}` is written in Task 3 and read identically; `PURGE_ORDER` (Task 4) lists all 25 user-scoped tables in FK-safe order; the change-email response `{user:{id,email,displayName,plan}}` matches the iOS `AccountUser` DTO in the account plan's §8 contract. ✓
