# F6 Email-in — Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Cloudflare `email()` handler that turns a forwarded receipt email into a server-created `email_in` Transaction (+ line items + receipt image) owned by the profile selected by the recipient alias, plus the two per-profile inbox-alias endpoints the app calls.

**Architecture:** Email Routing's catch-all on `in.snapceipt.app` delivers to a thin `email()` wrapper in `src/index.ts` that calls a pure, fully-unit-tested `inboundEmailLogic(env, msg, nowMs)` core (the `budgetCronLogic` pattern — Workers email handlers are not invocable in `vitest-pool-workers`). The core resolves the alias → `(userId, profileId)`, dedups on `Message-ID`, parses the MIME (`postal-mime`), stores the first image to R2, OCRs it via Workers AI (gated stub), runs the existing `runDeepseekExtraction` (gated stub), and writes rows via a new `writeReceiptRows`. Two auth-gated Hono routes (`GET /profiles/:id/inbox`, `POST /profiles/:id/inbox/rotate`) mint/rotate the opaque token.

**Tech Stack:** TypeScript, Hono, Cloudflare D1 + R2 + Workers AI + Email Routing, vitest (`@cloudflare/vitest-pool-workers`) + `unstable_dev` e2e, `postal-mime` (inbound MIME parse), `jose` (unrelated), `crypto.getRandomValues` (token).

**Authoritative contract:** §3 of `docs/superpowers/specs/2026-06-01-email-in-design.md`. Do not deviate from it.

**Baseline (capture before starting):** run `npm test` and `npm run test:e2e` once and record the passing counts. Every task below must keep the full suite green and only ADD tests. The roadmap target is e2e +2 (the two token endpoints) and a new `inbound`/`inboxToken`/`receiptRows`/`ocr`/`inbox-routes` set of unit tests.

**Server-only tables note:** `profile_inbox_tokens` and `inbound_email_log` are deliberately NOT added to `src/lib/syncTables.ts` (they never reach the device) — exactly like `quote_counters` from F5. Do not register them in `SYNCABLE_TABLES`.

---

### Task 1: Migration 0003 — server-only email-in tables

**Files:**
- Create: `migrations/0003_email_in.sql`
- Test: `test/email-in-schema.test.ts`

Migrations auto-apply in tests via `test/apply-migrations.ts` (`applyD1Migrations(env.DB, env.TEST_MIGRATIONS)`, idempotent) and `readD1Migrations("migrations")` in `vitest.config.ts`. No registry edit needed.

- [ ] **Step 1: Write the failing test**

Create `test/email-in-schema.test.ts`:

```typescript
import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";

describe("migration 0003 — email-in server-only tables", () => {
  it("creates profile_inbox_tokens with the expected columns", async () => {
    const info = await env.DB.prepare("PRAGMA table_info(profile_inbox_tokens)").all<{ name: string }>();
    const cols = info.results.map((r) => r.name).sort();
    expect(cols).toEqual(["created_at", "profile_id", "token", "user_id"]);
  });

  it("enforces one row per profile (unique profile_id)", async () => {
    const idx = await env.DB.prepare("PRAGMA index_list(profile_inbox_tokens)").all<{ name: string; unique: number }>();
    const hasUnique = idx.results.some((r) => r.unique === 1);
    expect(hasUnique).toBe(true);
  });

  it("creates inbound_email_log with message_id as the dedup key", async () => {
    const info = await env.DB.prepare("PRAGMA table_info(inbound_email_log)").all<{ name: string; pk: number }>();
    const pk = info.results.filter((r) => r.pk > 0).map((r) => r.name);
    expect(pk).toEqual(["message_id"]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/email-in-schema.test.ts`
Expected: FAIL — `no such table: profile_inbox_tokens`.

- [ ] **Step 3: Create the migration**

Create `migrations/0003_email_in.sql`:

```sql
-- F6 Email-in: server-only tables (NEVER added to SYNCABLE_TABLES — they do not sync).

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

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run test/email-in-schema.test.ts`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
git add migrations/0003_email_in.sql test/email-in-schema.test.ts
git commit -m "$(cat <<'EOF'
feat(F6): migration 0003 — email-in server-only tables

profile_inbox_tokens (one alias per profile) + inbound_email_log (Message-ID
dedup). Server-only; not registered in SYNCABLE_TABLES.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Inbox token helpers (`src/lib/inboxToken.ts`)

**Files:**
- Create: `src/lib/inboxToken.ts`
- Test: `test/inboxToken.test.ts`

Pure helpers (`generateInboxToken`, `addressForToken`, `tokenFromRecipient`) + D1 helpers (`resolveInboxToken`, `mintInboxToken`, `rotateInboxToken`). The token is a stored opaque secret (NOT a signed JWT like export/quote tokens).

- [ ] **Step 1: Write the failing test**

Create `test/inboxToken.test.ts`:

```typescript
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import {
  addressForToken,
  generateInboxToken,
  mintInboxToken,
  resolveInboxToken,
  rotateInboxToken,
  tokenFromRecipient,
} from "../src/lib/inboxToken";

async function seedProfile(): Promise<{ userId: string; profileId: string }> {
  const userId = uuidv7();
  const profileId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(userId, `${userId}@e.com`, t, t).run();
  await env.DB.prepare(
    `INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3, created_at, updated_at)
     VALUES (?, ?, 'Biz', 'business', '#0', '#1', '#2', ?, ?)`,
  ).bind(profileId, userId, t, t).run();
  return { userId, profileId };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM profile_inbox_tokens");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM users");
});

describe("inboxToken — pure helpers", () => {
  it("generateInboxToken returns 32 lowercase hex chars and is unique", () => {
    const a = generateInboxToken();
    const b = generateInboxToken();
    expect(a).toMatch(/^[0-9a-f]{32}$/);
    expect(a).not.toBe(b);
  });

  it("addressForToken formats r.<token>@in.snapceipt.app", () => {
    expect(addressForToken("abc")).toBe("r.abc@in.snapceipt.app");
  });

  it("tokenFromRecipient extracts the token and rejects non-r. localparts", () => {
    expect(tokenFromRecipient("r.deadbeef@in.snapceipt.app")).toBe("deadbeef");
    expect(tokenFromRecipient("R.DEADBEEF@IN.SNAPCEIPT.APP")).toBe("deadbeef");
    expect(tokenFromRecipient("noreply@snapceipt.app")).toBeNull();
    expect(tokenFromRecipient("r.@in.snapceipt.app")).toBeNull();
  });
});

describe("inboxToken — D1 helpers", () => {
  it("mint creates one token, is idempotent per profile, and resolves back to the owner", async () => {
    const { userId, profileId } = await seedProfile();
    const t1 = await mintInboxToken(env.DB, userId, profileId, nowMs());
    const t2 = await mintInboxToken(env.DB, userId, profileId, nowMs());
    expect(t1).toBe(t2); // idempotent — does not rotate
    const owner = await resolveInboxToken(env.DB, t1);
    expect(owner).toEqual({ userId, profileId });
  });

  it("rotate invalidates the old token and resolves the new one", async () => {
    const { userId, profileId } = await seedProfile();
    const old = await mintInboxToken(env.DB, userId, profileId, nowMs());
    const fresh = await rotateInboxToken(env.DB, userId, profileId, nowMs());
    expect(fresh).not.toBe(old);
    expect(await resolveInboxToken(env.DB, old)).toBeNull();
    expect(await resolveInboxToken(env.DB, fresh)).toEqual({ userId, profileId });
  });

  it("resolve returns null for an unknown token", async () => {
    expect(await resolveInboxToken(env.DB, "nope")).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/inboxToken.test.ts`
Expected: FAIL — cannot resolve module `../src/lib/inboxToken`.

- [ ] **Step 3: Implement `src/lib/inboxToken.ts`**

```typescript
// src/lib/inboxToken.ts
// Per-profile inbox alias token: an opaque random secret stored in
// profile_inbox_tokens (NOT a signed JWT). The address selects the profile.

const INBOX_DOMAIN = "in.snapceipt.app";
const PREFIX = "r.";

export interface InboxOwner {
  userId: string;
  profileId: string;
}

/** 16 random bytes -> 32 lowercase hex chars. Unguessable; collision-free in practice. */
export function generateInboxToken(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Format the public alias for a token. The client treats the result as opaque. */
export function addressForToken(token: string): string {
  return `${PREFIX}${token}@${INBOX_DOMAIN}`;
}

/** Parse the token out of a recipient address; null when it is not an r.<token> alias. */
export function tokenFromRecipient(to: string): string | null {
  const local = (to.trim().toLowerCase().split("@")[0] ?? "");
  if (!local.startsWith(PREFIX)) return null;
  const token = local.slice(PREFIX.length);
  return token.length > 0 ? token : null;
}

export async function resolveInboxToken(db: D1Database, token: string): Promise<InboxOwner | null> {
  const row = await db
    .prepare("SELECT user_id, profile_id FROM profile_inbox_tokens WHERE token = ?")
    .bind(token)
    .first<{ user_id: string; profile_id: string }>();
  return row ? { userId: row.user_id, profileId: row.profile_id } : null;
}

/** Return the profile's existing token, minting one if absent. Never rotates. */
export async function mintInboxToken(
  db: D1Database,
  userId: string,
  profileId: string,
  now: number,
): Promise<string> {
  const existing = await db
    .prepare("SELECT token FROM profile_inbox_tokens WHERE profile_id = ?")
    .bind(profileId)
    .first<{ token: string }>();
  if (existing) return existing.token;

  const token = generateInboxToken();
  await db
    .prepare(
      `INSERT INTO profile_inbox_tokens (token, user_id, profile_id, created_at)
       VALUES (?, ?, ?, ?) ON CONFLICT(profile_id) DO NOTHING`,
    )
    .bind(token, userId, profileId, now)
    .run();
  // Re-read: a concurrent insert may have won the ON CONFLICT no-op.
  const row = await db
    .prepare("SELECT token FROM profile_inbox_tokens WHERE profile_id = ?")
    .bind(profileId)
    .first<{ token: string }>();
  return row!.token;
}

/** Overwrite the profile's token with a fresh one (old token stops resolving). */
export async function rotateInboxToken(
  db: D1Database,
  userId: string,
  profileId: string,
  now: number,
): Promise<string> {
  const token = generateInboxToken();
  await db
    .prepare(
      `INSERT INTO profile_inbox_tokens (token, user_id, profile_id, created_at)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(profile_id) DO UPDATE SET token = excluded.token, created_at = excluded.created_at`,
    )
    .bind(token, userId, profileId, now)
    .run();
  return token;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run test/inboxToken.test.ts`
Expected: PASS (7 passed).

- [ ] **Step 5: Commit**

```bash
git add src/lib/inboxToken.ts test/inboxToken.test.ts
git commit -m "$(cat <<'EOF'
feat(F6): inbox token helpers (mint/resolve/rotate + alias parse/format)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `inbox` rate tier + inbox routes + mount

**Files:**
- Modify: `src/middleware/rateLimit.ts` (the `RATE_LIMIT_TIERS` object, the `RateLimitKind` union, and the factory ternary)
- Create: `src/routes/inbox.ts`
- Modify: `src/app.ts` (import, `app.use("/profiles/*", ...)`, `app.route("/profiles", ...)`)
- Test: `test/inbox-routes.test.ts`

- [ ] **Step 1: Write the failing test**

Create `test/inbox-routes.test.ts`:

```typescript
import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

async function seedAuthedProfile(): Promise<{ profileId: string; bearer: string; userId: string }> {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const profileId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(userId, `${userId}@e.com`, t, t).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at) VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, t, t).run();
  await env.DB.prepare(
    `INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3, created_at, updated_at)
     VALUES (?, ?, 'Biz', 'business', '#0', '#1', '#2', ?, ?)`,
  ).bind(profileId, userId, t, t).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { profileId, bearer: `Bearer ${accessToken}`, userId };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM profile_inbox_tokens");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM users");
});

describe("GET /profiles/:id/inbox", () => {
  it("mints + returns a well-formed inbox address scoped to the profile", async () => {
    const { profileId, bearer } = await seedAuthedProfile();
    const res = await SELF.fetch(`https://x/profiles/${profileId}/inbox`, { headers: { authorization: bearer } });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { profileId: string; token: string; address: string };
    expect(body.profileId).toBe(profileId);
    expect(body.token).toMatch(/^[0-9a-f]{32}$/);
    expect(body.address).toBe(`r.${body.token}@in.snapceipt.app`);

    // Idempotent: a second GET returns the same token.
    const again = await SELF.fetch(`https://x/profiles/${profileId}/inbox`, { headers: { authorization: bearer } });
    expect(((await again.json()) as { token: string }).token).toBe(body.token);
  });

  it("404s for a profile the caller does not own", async () => {
    const { bearer } = await seedAuthedProfile();
    const res = await SELF.fetch(`https://x/profiles/${uuidv7()}/inbox`, { headers: { authorization: bearer } });
    expect(res.status).toBe(404);
  });

  it("401s without a bearer token", async () => {
    const { profileId } = await seedAuthedProfile();
    const res = await SELF.fetch(`https://x/profiles/${profileId}/inbox`);
    expect(res.status).toBe(401);
  });
});

describe("POST /profiles/:id/inbox/rotate", () => {
  it("returns a different token than the one GET minted", async () => {
    const { profileId, bearer } = await seedAuthedProfile();
    const first = (await (await SELF.fetch(`https://x/profiles/${profileId}/inbox`, { headers: { authorization: bearer } })).json()) as { token: string };
    const rotated = (await (await SELF.fetch(`https://x/profiles/${profileId}/inbox/rotate`, { method: "POST", headers: { authorization: bearer } })).json()) as { token: string; address: string };
    expect(rotated.token).not.toBe(first.token);
    expect(rotated.address).toBe(`r.${rotated.token}@in.snapceipt.app`);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/inbox-routes.test.ts`
Expected: FAIL — `GET /profiles/...` returns 404 (no route mounted) / module `../src/routes/inbox` missing once imported.

- [ ] **Step 3: Add the `inbox` rate tier**

In `src/middleware/rateLimit.ts`, add to the `RATE_LIMIT_TIERS` object (right after the `quotes` entry):

```typescript
  /** inbox alias mint/rotate — light per-user tier. */
  inbox: { name: "inbox", limit: 60, windowMs: HOUR_MS, dimension: "user" },
```

Extend the `RateLimitKind` union:

```typescript
export type RateLimitKind = "auth" | "sync" | "extract" | "export" | "quotes" | "inbox" | "default";
```

In the `rateLimit(kind)` factory, extend the tier ternary (insert the `inbox` arm before the final `: RATE_LIMIT_TIERS.default`):

```typescript
    const tier =
      kind === "sync"
        ? RATE_LIMIT_TIERS.sync
        : kind === "extract"
          ? RATE_LIMIT_TIERS.extract
          : kind === "export"
            ? RATE_LIMIT_TIERS.export
            : kind === "quotes"
              ? RATE_LIMIT_TIERS.quotes
              : kind === "inbox"
                ? RATE_LIMIT_TIERS.inbox
                : RATE_LIMIT_TIERS.default;
```

- [ ] **Step 4: Create `src/routes/inbox.ts`**

```typescript
// src/routes/inbox.ts
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { nowMs } from "../lib/time";
import { addressForToken, mintInboxToken, rotateInboxToken } from "../lib/inboxToken";

/**
 * Per-profile inbox-alias endpoints (auth-gated; rate tier "inbox").
 *  GET  /profiles/:profileId/inbox        — mint-if-absent + return the alias.
 *  POST /profiles/:profileId/inbox/rotate — overwrite with a fresh alias.
 * Both verify the profile belongs to c.var.userId (else 404).
 */
export const inboxRoutes = new Hono<AppEnv>();

async function assertOwnedProfile(db: D1Database, userId: string, profileId: string): Promise<void> {
  const owned = await db
    .prepare("SELECT 1 FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL")
    .bind(profileId, userId)
    .first();
  if (!owned) throw new ApiError("NOT_FOUND", "Profile not found");
}

inboxRoutes.get("/:profileId/inbox", async (c) => {
  const userId = c.var.userId;
  const profileId = c.req.param("profileId");
  await assertOwnedProfile(c.env.DB, userId, profileId);
  const token = await mintInboxToken(c.env.DB, userId, profileId, nowMs());
  return c.json({ profileId, token, address: addressForToken(token) });
});

inboxRoutes.post("/:profileId/inbox/rotate", async (c) => {
  const userId = c.var.userId;
  const profileId = c.req.param("profileId");
  await assertOwnedProfile(c.env.DB, userId, profileId);
  const token = await rotateInboxToken(c.env.DB, userId, profileId, nowMs());
  return c.json({ profileId, token, address: addressForToken(token) });
});
```

Note: confirm `profiles` has a `deleted_at` column (it is a syncable entity, so it does). If not, drop the `AND deleted_at IS NULL` clause.

- [ ] **Step 5: Mount in `src/app.ts`**

Add the import alongside the other route imports:

```typescript
import { inboxRoutes } from "./routes/inbox";
```

Add the limiter mount (after the `quotes` limiter block, before "Public + placeholder routes"):

```typescript
// Inbox alias mint/rotate — light per-user tier. Auth-gated (not public).
app.use("/profiles/*", rateLimit("inbox"));
```

Add the route mount (after the `quotes` route mount):

```typescript
// Protected: per-profile inbox alias (GET mint + POST rotate).
app.route("/profiles", inboxRoutes);
```

- [ ] **Step 6: Run test to verify it passes**

Run: `npx vitest run test/inbox-routes.test.ts`
Expected: PASS (5 passed).

- [ ] **Step 7: Typecheck + commit**

Run: `npm run typecheck`
Expected: no errors.

```bash
git add src/middleware/rateLimit.ts src/routes/inbox.ts src/app.ts test/inbox-routes.test.ts
git commit -m "$(cat <<'EOF'
feat(F6): inbox alias endpoints + 'inbox' rate tier

GET /profiles/:id/inbox mints-if-absent; POST .../rotate overwrites. Auth-gated,
profile-ownership checked (404 cross-user).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Workers AI OCR with stub seam (`src/lib/ocr.ts`)

**Files:**
- Create: `src/lib/ocr.ts`
- Modify: `src/env.ts` (add `E2E_EMAIL_MODE?: string`)
- Test: `test/ocr.test.ts`

- [ ] **Step 1: Add the env flag**

In `src/env.ts`, add after the `E2E_EXTRACT_MODE?: string;` field (keep the existing doc-comment style):

```typescript
  /**
   * E2E-ONLY email seam. When "1", the email-in OCR step returns a deterministic
   * stub instead of calling Workers AI, so the suite is hermetic. Also implicitly
   * engaged when the AI binding is absent. MUST be undefined in production.
   */
  E2E_EMAIL_MODE?: string;
```

- [ ] **Step 2: Write the failing test**

Create `test/ocr.test.ts`:

```typescript
import { describe, expect, it } from "vitest";
import { STUB_OCR_TEXT, workersAiOcr } from "../src/lib/ocr";
import type { Env } from "../src/env";

const buf = new TextEncoder().encode("not-a-real-image").buffer;

describe("workersAiOcr — gating", () => {
  it("returns the deterministic stub when E2E_EMAIL_MODE === '1'", async () => {
    const env = { E2E_EMAIL_MODE: "1", AI: { run: async () => ({ description: "REAL" }) } } as unknown as Env;
    expect(await workersAiOcr(env, buf, "image/jpeg")).toBe(STUB_OCR_TEXT);
  });

  it("returns the stub when the AI binding is absent", async () => {
    const env = { AI: undefined } as unknown as Env;
    expect(await workersAiOcr(env, buf, "image/jpeg")).toBe(STUB_OCR_TEXT);
  });

  it("calls Workers AI and returns its text when not gated", async () => {
    const env = { AI: { run: async () => ({ description: " ACME 33.00 " }) } } as unknown as Env;
    expect(await workersAiOcr(env, buf, "image/jpeg")).toBe("ACME 33.00");
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `npx vitest run test/ocr.test.ts`
Expected: FAIL — cannot resolve `../src/lib/ocr`.

- [ ] **Step 4: Implement `src/lib/ocr.ts`**

```typescript
// src/lib/ocr.ts
import type { Env } from "../env";

/**
 * Deterministic OCR text for the stub seam. Crafted so heuristicExtract picks a
 * merchant + a 33.00 total (the email-in extraction stub mirrors /extract).
 */
export const STUB_OCR_TEXT = [
  "ACME HARDWARE PTY LTD",
  "123 Trade St, Sydney NSW",
  "Drill bits        18.00",
  "Safety gloves     12.00",
  "GST                3.00",
  "TOTAL             33.00",
].join("\n");

const OCR_MODEL = "@cf/meta/llama-3.2-11b-vision-instruct";
const OCR_PROMPT = "Transcribe ALL text from this receipt image exactly. Output only the raw text.";

/**
 * OCR a receipt image via Workers AI. Gated: when E2E_EMAIL_MODE === "1" or the
 * AI binding is absent, returns STUB_OCR_TEXT so the suite stays hermetic.
 */
export async function workersAiOcr(env: Env, bytes: ArrayBuffer, _contentType: string): Promise<string> {
  if (env.E2E_EMAIL_MODE === "1" || !env.AI) return STUB_OCR_TEXT;
  const image = Array.from(new Uint8Array(bytes));
  const result = (await env.AI.run(OCR_MODEL, { image, prompt: OCR_PROMPT })) as {
    description?: string;
    response?: string;
  };
  return (result.description ?? result.response ?? "").trim();
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `npx vitest run test/ocr.test.ts`
Expected: PASS (3 passed).

- [ ] **Step 6: Commit**

```bash
git add src/lib/ocr.ts src/env.ts test/ocr.test.ts
git commit -m "$(cat <<'EOF'
feat(F6): Workers AI OCR with E2E_EMAIL_MODE stub seam

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Server-side row writer (`src/lib/receiptRows.ts`)

**Files:**
- Create: `src/lib/receiptRows.ts`
- Test: `test/receiptRows.test.ts`

`/extract` writes no DB rows (the device does), so this server-side `ExtractedReceipt → D1 rows` writer is net-new. Amounts in `ExtractedReceipt` are **dollars** → convert to cents.

- [ ] **Step 1: Write the failing test**

Create `test/receiptRows.test.ts`:

```typescript
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { coerceCatKey, writeReceiptRows } from "../src/lib/receiptRows";
import type { ExtractedReceipt } from "../src/lib/deepseek";

function receipt(over: Partial<ExtractedReceipt> = {}): ExtractedReceipt {
  return {
    merchant: "ACME Hardware",
    date: "2026-05-30",
    currencyCode: "AUD",
    total: 33,
    gst: 3,
    category: "office",
    deductible: 100,
    lineItems: [{ name: "Drill bits", price: 18 }, { name: "Gloves", price: 12 }],
    confidence: 0.9,
    needsReview: false,
    ...over,
  };
}

async function seed(): Promise<{ userId: string; profileId: string }> {
  const userId = uuidv7();
  const profileId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(userId, `${userId}@e.com`, t, t).run();
  await env.DB.prepare(
    `INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3, created_at, updated_at)
     VALUES (?, ?, 'Biz', 'business', '#0', '#1', '#2', ?, ?)`,
  ).bind(profileId, userId, t, t).run();
  return { userId, profileId };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM line_items");
  await env.DB.exec("DELETE FROM receipt_images");
  await env.DB.exec("DELETE FROM transactions");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM users");
});

describe("coerceCatKey", () => {
  it("passes through allowed keys (case-insensitive) and falls back to office", () => {
    expect(coerceCatKey("meals")).toBe("meals");
    expect(coerceCatKey("MEALS")).toBe("meals");
    expect(coerceCatKey("widgets")).toBe("office");
  });
});

describe("writeReceiptRows", () => {
  it("writes a done transaction (dollars->cents), line items, and a receipt_images row", async () => {
    const { userId, profileId } = await seed();
    const txnId = await writeReceiptRows(env.DB, {
      userId, profileId, profileType: "business", receipt: receipt(),
      ocrText: "ACME 33.00", r2Key: `u/${userId}/x.jpg`, contentType: "image/jpeg",
      byteSize: 1234, extractionStatus: "done", extractionModel: "deepseek-chat", nowMs: nowMs(),
    });

    const txn = await env.DB.prepare("SELECT * FROM transactions WHERE id = ?").bind(txnId).first<any>();
    expect(txn.source).toBe("email_in");
    expect(txn.extraction_status).toBe("done");
    expect(txn.profile_id).toBe(profileId);
    expect(txn.amount_cents).toBe(-3300); // expense category -> signed negative
    expect(txn.gst_cents).toBe(300); // positive magnitude
    expect(txn.cat_key).toBe("office");
    expect(txn.mode).toBe("business");
    expect(txn.is_ai).toBe(1);
    expect(txn.last_edited_device_id).toBe("email_in");

    const lines = await env.DB.prepare("SELECT * FROM line_items WHERE transaction_id = ? ORDER BY sort_order").bind(txnId).all<any>();
    expect(lines.results.map((l) => l.price_cents)).toEqual([1800, 1200]);

    const img = await env.DB.prepare("SELECT * FROM receipt_images WHERE transaction_id = ?").bind(txnId).first<any>();
    expect(img.ocr_source).toBe("workers_ai");
    expect(img.source).toBe("email_in");
    expect(img.r2_key).toBe(`u/${userId}/x.jpg`);
    expect(JSON.parse(img.extraction_json).merchant).toBe("ACME Hardware");
  });

  it("stores a positive amount when the category is income", async () => {
    const { userId, profileId } = await seed();
    const txnId = await writeReceiptRows(env.DB, {
      userId, profileId, profileType: "business", receipt: receipt({ category: "income", lineItems: [] }),
      ocrText: null, r2Key: `u/${userId}/z.jpg`, contentType: "image/jpeg",
      byteSize: 10, extractionStatus: "done", extractionModel: "deepseek-chat", nowMs: nowMs(),
    });
    const txn = await env.DB.prepare("SELECT amount_cents, cat_key FROM transactions WHERE id = ?").bind(txnId).first<any>();
    expect(txn.cat_key).toBe("income");
    expect(txn.amount_cents).toBe(3300); // income -> positive
  });

  it("on the failed path writes a failed transaction with no line items, image preserved", async () => {
    const { userId, profileId } = await seed();
    const txnId = await writeReceiptRows(env.DB, {
      userId, profileId, profileType: "personal",
      receipt: { merchant: "", date: "2026-06-01", currencyCode: "AUD", total: 0, gst: null, category: "office", deductible: null, lineItems: [], confidence: 0, needsReview: true },
      ocrText: "garbled", r2Key: `u/${userId}/y.jpg`, contentType: "image/jpeg",
      byteSize: 99, extractionStatus: "failed", extractionModel: null, nowMs: nowMs(),
    });
    const txn = await env.DB.prepare("SELECT * FROM transactions WHERE id = ?").bind(txnId).first<any>();
    expect(txn.extraction_status).toBe("failed");
    expect(txn.amount_cents).toBe(0);
    expect(txn.mode).toBe("personal");
    const lines = await env.DB.prepare("SELECT COUNT(*) c FROM line_items WHERE transaction_id = ?").bind(txnId).first<{ c: number }>();
    expect(lines!.c).toBe(0);
    const img = await env.DB.prepare("SELECT ocr_text, extraction_json FROM receipt_images WHERE transaction_id = ?").bind(txnId).first<any>();
    expect(img.ocr_text).toBe("garbled");
    expect(img.extraction_json).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/receiptRows.test.ts`
Expected: FAIL — cannot resolve `../src/lib/receiptRows`.

- [ ] **Step 3: Implement `src/lib/receiptRows.ts`**

```typescript
// src/lib/receiptRows.ts
import type { ExtractedReceipt } from "./deepseek";
import { uuidv7 } from "./ids";

const CAT_KEYS = [
  "meals", "groceries", "fuel", "software", "office",
  "home", "health", "travel", "income", "custom",
] as const;
export type CatKey = (typeof CAT_KEYS)[number];

const DEVICE = "email_in";

/** Map a free-text category onto the transactions.cat_key CHECK set; fallback office. */
export function coerceCatKey(category: string): CatKey {
  const c = category.trim().toLowerCase();
  return (CAT_KEYS as readonly string[]).includes(c) ? (c as CatKey) : "office";
}

function toCents(dollars: number): number {
  return Math.round(dollars * 100);
}
function clampPct(n: number | null): number | null {
  if (n == null) return null;
  return Math.max(0, Math.min(100, Math.round(n)));
}

export interface WriteReceiptArgs {
  userId: string;
  profileId: string;
  profileType: string; // 'business' | 'personal'
  receipt: ExtractedReceipt;
  ocrText: string | null;
  r2Key: string;
  contentType: string;
  byteSize: number;
  extractionStatus: "done" | "failed";
  extractionModel: string | null;
  nowMs: number;
}

/**
 * Insert a transactions row (+ line_items on the done path) + a receipt_images
 * row, all owned by (userId, profileId). Amounts in ExtractedReceipt are dollars
 * — converted to integer cents here. Returns the new transaction id.
 */
export async function writeReceiptRows(db: D1Database, a: WriteReceiptArgs): Promise<string> {
  const txnId = uuidv7();
  const r = a.receipt;
  const mode = a.profileType === "business" ? "business" : "personal";
  const catKey = coerceCatKey(r.category);
  // amount_cents is SIGNED on the device (expense < 0, income > 0). Receipt totals
  // are positive dollars, so negate unless the category is income. gst_cents stays a
  // positive magnitude (matches the on-device convention).
  const sign = catKey === "income" ? 1 : -1;
  const amountCents = sign * toCents(r.total);
  const gstCents = r.gst == null ? null : toCents(r.gst);

  await db
    .prepare(
      `INSERT INTO transactions
         (id, user_id, profile_id, merchant, category_id, cat_key, amount_cents, currency, txn_date,
          mode, tax_label, deductible_pct, payment_method, is_ai, note, gst_cents, logbook_link,
          mileage_trip_id, source, extraction_status, created_at, updated_at, deleted_at, rev, last_edited_device_id)
       VALUES (?, ?, ?, ?, NULL, ?, ?, 'AUD', ?, ?, NULL, ?, NULL, 1, NULL, ?, NULL, NULL, 'email_in', ?, ?, ?, NULL, 0, ?)`,
    )
    .bind(
      txnId, a.userId, a.profileId, r.merchant, catKey, amountCents, r.date,
      mode, clampPct(r.deductible), gstCents, a.extractionStatus, a.nowMs, a.nowMs, DEVICE,
    )
    .run();

  if (a.extractionStatus === "done") {
    for (let i = 0; i < r.lineItems.length; i++) {
      const li = r.lineItems[i];
      await db
        .prepare(
          `INSERT INTO line_items
             (id, user_id, transaction_id, name, price_cents, quantity, sort_order, created_at, updated_at, deleted_at, rev, last_edited_device_id)
           VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, NULL, 0, ?)`,
        )
        .bind(uuidv7(), a.userId, txnId, li.name, toCents(li.price), i, a.nowMs, a.nowMs, DEVICE)
        .run();
    }
  }

  await db
    .prepare(
      `INSERT INTO receipt_images
         (id, user_id, profile_id, transaction_id, r2_key, thumb_r2_key, content_type, byte_size,
          width, height, page_index, ocr_text, ocr_source, extraction_json, extraction_model, source,
          created_at, updated_at, deleted_at, rev, last_edited_device_id)
       VALUES (?, ?, ?, ?, ?, NULL, ?, ?, NULL, NULL, 0, ?, 'workers_ai', ?, ?, 'email_in', ?, ?, NULL, 0, ?)`,
    )
    .bind(
      uuidv7(), a.userId, a.profileId, txnId, a.r2Key, a.contentType, a.byteSize,
      a.ocrText, a.extractionStatus === "done" ? JSON.stringify(r) : null, a.extractionModel,
      a.nowMs, a.nowMs, DEVICE,
    )
    .run();

  return txnId;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run test/receiptRows.test.ts`
Expected: PASS (4 passed).

- [ ] **Step 5: Commit**

```bash
git add src/lib/receiptRows.ts test/receiptRows.test.ts
git commit -m "$(cat <<'EOF'
feat(F6): server-side receipt row writer (txn + line items + image)

ExtractedReceipt (dollars) -> D1 rows (cents); done writes line items + JSON,
failed preserves the image. cat_key coerced to the CHECK set.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Inbound core (`src/email/inbound.ts`) + `postal-mime`

**Files:**
- Modify: `package.json` (add `postal-mime`)
- Create: `src/email/inbound.ts`
- Test: `test/inbound.test.ts`

This is the heart of F6. `inboundEmailLogic` is pure (takes `env`, an `InboundMessage`, `nowMs`) so it is fully unit-testable without the un-invocable `email()` handler.

- [ ] **Step 1: Add the postal-mime dependency**

Run: `npm install postal-mime@^2.4.3`
Expected: adds `"postal-mime": "^2.4.3"` to `package.json` dependencies and updates the lockfile. (postal-mime is pure ESM and Workers-compatible.)

- [ ] **Step 2: Write the failing test**

Create `test/inbound.test.ts`:

```typescript
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { mintInboxToken, addressForToken } from "../src/lib/inboxToken";
import { inboundEmailLogic } from "../src/email/inbound";
import * as deepseek from "../src/lib/deepseek";

// A multipart/mixed MIME with one base64 image/jpeg attachment.
function mimeWithImage(messageId: string): ArrayBuffer {
  const raw = [
    "From: supplier@example.com",
    "To: receipts@example.com",
    `Message-ID: <${messageId}>`,
    "Subject: Your tax invoice",
    "MIME-Version: 1.0",
    'Content-Type: multipart/mixed; boundary="BOUND"',
    "",
    "--BOUND",
    "Content-Type: text/plain; charset=utf-8",
    "",
    "Receipt attached.",
    "--BOUND",
    'Content-Type: image/jpeg; name="receipt.jpg"',
    "Content-Transfer-Encoding: base64",
    'Content-Disposition: attachment; filename="receipt.jpg"',
    "",
    "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBD",
    "--BOUND--",
    "",
  ].join("\r\n");
  return new TextEncoder().encode(raw).buffer;
}

// A MIME with NO attachments (text only).
function mimeTextOnly(messageId: string): ArrayBuffer {
  const raw = [
    "From: supplier@example.com",
    "To: receipts@example.com",
    `Message-ID: <${messageId}>`,
    "Subject: hi",
    "Content-Type: text/plain; charset=utf-8",
    "",
    "no attachment here",
    "",
  ].join("\r\n");
  return new TextEncoder().encode(raw).buffer;
}

async function seedProfileWithInbox(type = "business"): Promise<{ userId: string; profileId: string; address: string }> {
  const userId = uuidv7();
  const profileId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(userId, `${userId}@e.com`, t, t).run();
  await env.DB.prepare(
    `INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3, created_at, updated_at)
     VALUES (?, ?, 'Biz', ?, '#0', '#1', '#2', ?, ?)`,
  ).bind(profileId, userId, type, t, t).run();
  const token = await mintInboxToken(env.DB, userId, profileId, t);
  return { userId, profileId, address: addressForToken(token) };
}

// Hermetic env: stub OCR + stub extraction.
function emailEnv(over: Record<string, unknown> = {}) {
  return { ...env, E2E_EMAIL_MODE: "1", E2E_EXTRACT_MODE: "1", ...over } as typeof env;
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM line_items");
  await env.DB.exec("DELETE FROM receipt_images");
  await env.DB.exec("DELETE FROM transactions");
  await env.DB.exec("DELETE FROM inbound_email_log");
  await env.DB.exec("DELETE FROM profile_inbox_tokens");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM users");
});

describe("inboundEmailLogic", () => {
  it("rejects an unknown inbox alias and writes no rows", async () => {
    const res = await inboundEmailLogic(emailEnv(), {
      to: "r.deadbeefdeadbeefdeadbeefdeadbeef@in.snapceipt.app",
      from: "x@e.com", messageId: "<m1>", raw: mimeWithImage("m1"),
    }, nowMs());
    expect(res).toEqual({ status: "rejected", reason: "unknown_inbox" });
    const c = await env.DB.prepare("SELECT COUNT(*) c FROM transactions").first<{ c: number }>();
    expect(c!.c).toBe(0);
  });

  it("rejects a non-r. recipient (unknown_inbox)", async () => {
    const res = await inboundEmailLogic(emailEnv(), {
      to: "noreply@snapceipt.app", from: "x@e.com", messageId: "<m1b>", raw: mimeWithImage("m1b"),
    }, nowMs());
    expect(res).toEqual({ status: "rejected", reason: "unknown_inbox" });
  });

  it("rejects an email with no image attachment", async () => {
    const { address } = await seedProfileWithInbox();
    const res = await inboundEmailLogic(emailEnv(), {
      to: address, from: "x@e.com", messageId: "<m2>", raw: mimeTextOnly("m2"),
    }, nowMs());
    expect(res).toEqual({ status: "rejected", reason: "no_image" });
  });

  it("creates a done transaction with the resolved profile on the happy path", async () => {
    const { profileId, address } = await seedProfileWithInbox();
    const res = await inboundEmailLogic(emailEnv(), {
      to: address, from: "x@e.com", messageId: "<m3>", raw: mimeWithImage("m3"),
    }, nowMs());
    expect(res.status).toBe("created");
    if (res.status !== "created") return;
    expect(res.extraction).toBe("done");
    const txn = await env.DB.prepare("SELECT * FROM transactions WHERE id = ?").bind(res.transactionId).first<any>();
    expect(txn.source).toBe("email_in");
    expect(txn.extraction_status).toBe("done");
    expect(txn.profile_id).toBe(profileId);
    expect(txn.amount_cents).toBe(-3300); // STUB_OCR_TEXT -> total 33.00, office (expense) -> signed negative
    const img = await env.DB.prepare("SELECT COUNT(*) c FROM receipt_images WHERE transaction_id = ?").bind(res.transactionId).first<{ c: number }>();
    expect(img!.c).toBe(1);
  });

  it("is idempotent on Message-ID — a redelivery creates no second transaction", async () => {
    const { address } = await seedProfileWithInbox();
    const msg = { to: address, from: "x@e.com", messageId: "<dup>", raw: mimeWithImage("dup") };
    const first = await inboundEmailLogic(emailEnv(), { ...msg, raw: mimeWithImage("dup") }, nowMs());
    const second = await inboundEmailLogic(emailEnv(), { ...msg, raw: mimeWithImage("dup") }, nowMs());
    expect(first.status).toBe("created");
    expect(second).toEqual({ status: "duplicate" });
    const c = await env.DB.prepare("SELECT COUNT(*) c FROM transactions").first<{ c: number }>();
    expect(c!.c).toBe(1);
  });

  it("creates a failed transaction (image preserved) when extraction throws", async () => {
    const { address } = await seedProfileWithInbox();
    const spy = vi.spyOn(deepseek, "runDeepseekExtraction").mockRejectedValue(new Error("boom"));
    try {
      // DEEPSEEK_API_KEY present + E2E_EXTRACT_MODE unset => real extraction path => the spy throws.
      const res = await inboundEmailLogic(
        emailEnv({ E2E_EXTRACT_MODE: undefined, DEEPSEEK_API_KEY: "real-key" }),
        { to: address, from: "x@e.com", messageId: "<m4>", raw: mimeWithImage("m4") },
        nowMs(),
      );
      expect(res.status).toBe("created");
      if (res.status !== "created") return;
      expect(res.extraction).toBe("failed");
      const txn = await env.DB.prepare("SELECT extraction_status FROM transactions WHERE id = ?").bind(res.transactionId).first<any>();
      expect(txn.extraction_status).toBe("failed");
      const img = await env.DB.prepare("SELECT ocr_text FROM receipt_images WHERE transaction_id = ?").bind(res.transactionId).first<any>();
      expect(img.ocr_text).not.toBeNull(); // OCR stub still ran
    } finally {
      spy.mockRestore();
    }
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `npx vitest run test/inbound.test.ts`
Expected: FAIL — cannot resolve `../src/email/inbound`.

- [ ] **Step 4: Implement `src/email/inbound.ts`**

```typescript
// src/email/inbound.ts
import PostalMime from "postal-mime";
import type { Env } from "../env";
import { uuidv7 } from "../lib/ids";
import { resolveInboxToken, tokenFromRecipient, type InboxOwner } from "../lib/inboxToken";
import { workersAiOcr } from "../lib/ocr";
import { heuristicExtract } from "../lib/extractionHeuristic";
import { runDeepseekExtraction, type ExtractedReceipt } from "../lib/deepseek";
import { writeReceiptRows } from "../lib/receiptRows";

const MAX_IMAGE_BYTES = 6_291_456; // 6 MiB — mirrors images.ts

/** The shape the email() wrapper hands to the pure core. */
export interface InboundMessage {
  to: string;
  from: string;
  messageId: string | null;
  raw: ReadableStream<Uint8Array> | ArrayBuffer | Uint8Array | string;
}

export type InboundResult =
  | { status: "rejected"; reason: "unknown_inbox" | "no_image" }
  | { status: "duplicate" }
  | { status: "created"; transactionId: string; extraction: "done" | "failed" };

function todayIso(now: number): string {
  return new Date(now).toISOString().slice(0, 10);
}
function isImage(mimeType: string | undefined | null): boolean {
  return typeof mimeType === "string" && mimeType.toLowerCase().startsWith("image/");
}
function toArrayBuffer(content: ArrayBuffer | Uint8Array | string): ArrayBuffer {
  if (content instanceof ArrayBuffer) return content;
  if (content instanceof Uint8Array) {
    return content.buffer.slice(content.byteOffset, content.byteOffset + content.byteLength);
  }
  return new TextEncoder().encode(content).buffer; // base64/text fallback
}
function failedReceipt(date: string): ExtractedReceipt {
  return {
    merchant: "", date, currencyCode: "AUD", total: 0, gst: null,
    category: "office", deductible: null, lineItems: [], confidence: 0, needsReview: true,
  };
}

/** Extraction with the same stub gate as POST /extract. */
async function runExtraction(
  env: Env,
  ocrText: string,
  defaultDate: string,
): Promise<{ receipt: ExtractedReceipt; model: string }> {
  const stubGate = env.E2E_EXTRACT_MODE === "1" || !env.DEEPSEEK_API_KEY;
  if (stubGate) {
    const h = heuristicExtract(ocrText, defaultDate);
    return {
      receipt: {
        merchant: h.merchant, date: h.date, currencyCode: "AUD", total: h.total,
        gst: h.total === 0 ? null : h.gst, category: h.category, deductible: h.deductible,
        lineItems: h.lineItems, confidence: 0.9, needsReview: false,
      },
      model: env.DEEPSEEK_MODEL ?? "deepseek-chat",
    };
  }
  const result = await runDeepseekExtraction(env, { ocrText, source: "email_in", defaultDate });
  return { receipt: result.receipt, model: result.meta.model };
}

async function logInbound(
  db: D1Database,
  messageId: string,
  owner: InboxOwner | null,
  txnId: string | null,
  status: "created" | "failed" | "rejected",
  reason: string | null,
  now: number,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO inbound_email_log (message_id, user_id, profile_id, transaction_id, status, reason, received_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(messageId, owner?.userId ?? null, owner?.profileId ?? null, txnId, status, reason, now)
    .run();
}

/**
 * Pure inbound core (the email() handler is not invocable in vitest-pool-workers).
 * Resolve alias -> dedup -> parse -> store image -> OCR (gated) -> extract (gated)
 * -> write rows. OCR/extraction failure still creates a 'failed' transaction so the
 * receipt is never lost. The inbound_email_log row is written only on a terminal
 * outcome, so a mid-flight crash safely reprocesses on redelivery.
 */
export async function inboundEmailLogic(env: Env, msg: InboundMessage, now: number): Promise<InboundResult> {
  // 1. Resolve the alias -> owner.
  const token = tokenFromRecipient(msg.to);
  if (!token) return { status: "rejected", reason: "unknown_inbox" };
  const owner = await resolveInboxToken(env.DB, token);
  if (!owner) return { status: "rejected", reason: "unknown_inbox" };

  // 2. Dedup on Message-ID (synthesize one when absent so the row is still logged).
  const messageId = msg.messageId && msg.messageId.length > 0 ? msg.messageId : `no-id:${uuidv7()}`;
  const dup = await env.DB.prepare("SELECT 1 FROM inbound_email_log WHERE message_id = ?").bind(messageId).first();
  if (dup) return { status: "duplicate" };

  // 3. Parse MIME; pick the first image attachment under the size cap.
  const parsed = await new PostalMime().parse(msg.raw);
  const image = (parsed.attachments ?? []).find((att) => isImage(att.mimeType));
  if (!image) {
    await logInbound(env.DB, messageId, owner, null, "rejected", "no_image", now);
    return { status: "rejected", reason: "no_image" };
  }
  const buf = toArrayBuffer(image.content as ArrayBuffer | Uint8Array | string);
  if (buf.byteLength === 0 || buf.byteLength > MAX_IMAGE_BYTES) {
    await logInbound(env.DB, messageId, owner, null, "rejected", "no_image", now);
    return { status: "rejected", reason: "no_image" };
  }
  const contentType = (image.mimeType ?? "image/jpeg").toLowerCase();
  const ext = contentType.includes("png") ? "png" : "jpg";

  // 4. Store the image to R2 under the owner's prefix.
  const r2Key = `u/${owner.userId}/${uuidv7()}.${ext}`;
  await env.RECEIPTS.put(r2Key, buf, { httpMetadata: { contentType } });

  // 5. Profile type drives txn.mode.
  const prof = await env.DB.prepare("SELECT type FROM profiles WHERE id = ?").bind(owner.profileId).first<{ type: string }>();
  const profileType = prof?.type ?? "personal";
  const defaultDate = todayIso(now);

  // 6. OCR (gated) -> extraction (gated). Any failure => failed transaction, image kept.
  let ocrText: string | null = null;
  let receipt: ExtractedReceipt;
  let extraction: "done" | "failed" = "done";
  let model: string | null = null;
  try {
    ocrText = await workersAiOcr(env, buf, contentType);
    const out = await runExtraction(env, ocrText, defaultDate);
    receipt = out.receipt;
    model = out.model;
  } catch {
    extraction = "failed";
    receipt = failedReceipt(defaultDate);
  }

  // 7. Write rows.
  const transactionId = await writeReceiptRows(env.DB, {
    userId: owner.userId, profileId: owner.profileId, profileType,
    receipt, ocrText, r2Key, contentType, byteSize: buf.byteLength,
    extractionStatus: extraction, extractionModel: model, nowMs: now,
  });

  await logInbound(env.DB, messageId, owner, transactionId, extraction === "done" ? "created" : "failed", null, now);
  return { status: "created", transactionId, extraction };
}
```

If `import PostalMime from "postal-mime"` fails to resolve in the workers pool at runtime, switch to a dynamic import inside the function (`const { default: PostalMime } = await import("postal-mime");`), mirroring the dynamic imports in `src/lib/email.ts`. Try the static import first.

- [ ] **Step 5: Run test to verify it passes**

Run: `npx vitest run test/inbound.test.ts`
Expected: PASS (6 passed).

- [ ] **Step 6: Typecheck + commit**

Run: `npm run typecheck`
Expected: no errors.

```bash
git add package.json package-lock.json src/email/inbound.ts test/inbound.test.ts
git commit -m "$(cat <<'EOF'
feat(F6): inbound email core (inboundEmailLogic) + postal-mime

Resolve alias -> dedup Message-ID -> parse MIME -> R2 store -> gated OCR ->
gated DeepSeek extraction -> writeReceiptRows. Failure still creates a 'failed'
transaction; terminal-only logging makes redelivery safe.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Wire the `email()` handler in `src/index.ts`

**Files:**
- Modify: `src/index.ts`

The `email()` handler is not invocable in vitest-pool-workers, so this task has no unit test — it is a thin, typed wrapper over the unit-tested core, verified by `npm run typecheck` and the e2e suite (Task 8) plus the existing tests staying green.

- [ ] **Step 1: Replace `src/index.ts`**

```typescript
import { app } from "./app";
import type { Env } from "./env";
import { budgetCronLogic } from "./cron/budgetAlert";
import { inboundEmailLogic } from "./email/inbound";

/**
 * Hourly scheduled handler (wrangler.jsonc triggers.crons = "0 * * * *").
 */
const scheduled: ExportedHandlerScheduledHandler<Env> = (_event, env, ctx) => {
  ctx.waitUntil(budgetCronLogic(env.DB, env, Date.now()));
};

/**
 * Inbound Email Routing handler (catch-all on in.snapceipt.app). Thin wrapper:
 * builds the InboundMessage and delegates to the pure core. Rejected results call
 * setReject (the sender gets a bounce); created/duplicate are accepted silently.
 * Any thrown error is logged and swallowed — never rethrow, or Email Routing would
 * bounce + retry indefinitely.
 */
const email = async (
  message: ForwardableEmailMessage,
  env: Env,
  _ctx: ExecutionContext,
): Promise<void> => {
  try {
    const result = await inboundEmailLogic(
      env,
      {
        to: message.to,
        from: message.from,
        messageId: message.headers.get("message-id"),
        raw: message.raw,
      },
      Date.now(),
    );
    if (result.status === "rejected") {
      message.setReject(result.reason === "no_image" ? "No receipt image attached" : "Unknown inbox address");
    }
  } catch (err) {
    console.error("inbound email failed", err);
  }
};

// Worker entrypoint: HTTP fetch + hourly cron + inbound email.
export default {
  fetch: app.fetch,
  scheduled,
  email,
};
```

- [ ] **Step 2: Typecheck**

Run: `npm run typecheck`
Expected: no errors. (`ForwardableEmailMessage` and `ExecutionContext` are global types from `@cloudflare/workers-types`.)

- [ ] **Step 3: Full unit suite stays green**

Run: `npm test`
Expected: all tests pass (baseline + the tasks above; 0 failures).

- [ ] **Step 4: Commit**

```bash
git add src/index.ts
git commit -m "$(cat <<'EOF'
feat(F6): wire inbound email() handler into the Worker entrypoint

Thin wrapper -> inboundEmailLogic; rejects bounce, errors are swallowed.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: e2e — inbox token endpoints over real HTTP

**Files:**
- Create: `e2e/inbox.e2e.test.ts`

Mirrors `e2e/quotes.e2e.test.ts`: boot the worker via `unstable_dev`, sign in via magic-link (`E2E_TEST_MODE`), push a profile via `/sync/push`, then exercise the token endpoints. The `email()` handler itself is covered by Task 6's unit tests.

- [ ] **Step 1: Write the e2e test**

Create `e2e/inbox.e2e.test.ts`:

```typescript
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { unstable_dev, type Unstable_DevWorker } from "wrangler";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const JWT_SIGNING_KEY = "e2e-signing-key-0123456789-abcdefghijklmnop";
const APPLE_BUNDLE_ID = "com.snapceipt.app";

let worker: Unstable_DevWorker;
let baseUrl: string;
let persistDir: string;

function applyMigrations(dir: string): void {
  execFileSync(
    "node",
    [
      path.join(repoRoot, "node_modules", "wrangler", "bin", "wrangler.js"),
      "d1", "migrations", "apply", "snapceipt", "--local", "--persist-to", dir,
    ],
    { cwd: repoRoot, stdio: "pipe", env: { ...process.env, CI: "1", WRANGLER_SEND_METRICS: "false" } },
  );
}

beforeAll(async () => {
  persistDir = mkdtempSync(path.join(tmpdir(), "snapceipt-e2e-inbox-"));
  applyMigrations(persistDir);
  worker = await unstable_dev(path.join(repoRoot, "src", "index.ts"), {
    config: path.join(repoRoot, "wrangler.jsonc"),
    local: true,
    persistTo: persistDir,
    experimental: { disableExperimentalWarning: true },
    vars: { E2E_TEST_MODE: "1", JWT_SIGNING_KEY, APPLE_BUNDLE_ID },
    logLevel: "warn",
  });
  const host = worker.address === "::" || worker.address === "0.0.0.0" ? "127.0.0.1" : worker.address;
  baseUrl = `http://${host}:${worker.port}`;
}, 120_000);

afterAll(async () => {
  if (worker) await worker.stop();
  if (persistDir) {
    try { rmSync(persistDir, { recursive: true, force: true }); } catch { /* best-effort */ }
  }
});

async function api(
  pathname: string,
  init: { method?: string; headers?: Record<string, string>; body?: unknown } = {},
): Promise<{ status: number; json: any; text: string }> {
  const headers: Record<string, string> = { ...(init.headers ?? {}) };
  let body: string | undefined;
  if (init.body !== undefined) {
    headers["content-type"] = "application/json";
    body = JSON.stringify(init.body);
  }
  const res = await fetch(`${baseUrl}${pathname}`, { method: init.method ?? (body ? "POST" : "GET"), headers, body });
  const text = await res.text();
  let json: any = null;
  try { json = text.length ? JSON.parse(text) : null; } catch { json = null; }
  return { status: res.status, json, text };
}

describe("e2e (real HTTP): inbox alias endpoints", () => {
  it("mints an alias for a pushed profile and rotates it", async () => {
    const email = `e2e-inbox+${Date.now()}@example.com`;
    const deviceId = crypto.randomUUID();
    const ip = "203.0.113.77";

    const reqRes = await api("/auth/magic-link/request", { method: "POST", headers: { "cf-connecting-ip": ip }, body: { email } });
    expect(reqRes.status).toBe(202);
    const verifyRes = await api("/auth/magic-link/verify", {
      method: "POST", headers: { "cf-connecting-ip": ip, "x-device-id": deviceId }, body: { token: reqRes.json.devToken },
    });
    expect(verifyRes.status).toBe(200);
    const userId: string = verifyRes.json.user.id;
    const authHeaders = { authorization: `Bearer ${verifyRes.json.accessToken}` };

    const profileId = crypto.randomUUID();
    const t = Date.now();
    const pushRes = await api("/sync/push", {
      method: "POST", headers: authHeaders,
      body: {
        deviceId,
        mutations: [{
          mutationId: crypto.randomUUID(), entityType: "profile", entityId: profileId, op: "upsert", updatedAt: t,
          payload: {
            id: profileId, userId, type: "profile", name: "Acme Pty Ltd", profileType: "business",
            accent1: "#000", accent2: "#111", accent3: "#222",
            createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
          },
        }],
      },
    });
    expect(pushRes.status).toBe(200);

    const got = await api(`/profiles/${profileId}/inbox`, { headers: authHeaders });
    expect(got.status).toBe(200);
    expect(got.json.profileId).toBe(profileId);
    expect(got.json.token).toMatch(/^[0-9a-f]{32}$/);
    expect(got.json.address).toBe(`r.${got.json.token}@in.snapceipt.app`);

    const rotated = await api(`/profiles/${profileId}/inbox/rotate`, { method: "POST", headers: authHeaders });
    expect(rotated.status).toBe(200);
    expect(rotated.json.token).not.toBe(got.json.token);
  });

  it("404s for a profile the caller does not own", async () => {
    const email = `e2e-inbox2+${Date.now()}@example.com`;
    const deviceId = crypto.randomUUID();
    const ip = "203.0.113.78";
    const reqRes = await api("/auth/magic-link/request", { method: "POST", headers: { "cf-connecting-ip": ip }, body: { email } });
    const verifyRes = await api("/auth/magic-link/verify", {
      method: "POST", headers: { "cf-connecting-ip": ip, "x-device-id": deviceId }, body: { token: reqRes.json.devToken },
    });
    const authHeaders = { authorization: `Bearer ${verifyRes.json.accessToken}` };
    const res = await api(`/profiles/${crypto.randomUUID()}/inbox`, { headers: authHeaders });
    expect(res.status).toBe(404);
  });
});
```

Note: confirm the `/sync/push` profile payload shape against `e2e/quotes.e2e.test.ts` (it pushes a `profile` with `profileType: "business"`); copy that exact shape. If the push reports the profile as not-applied, align field names with the quotes e2e before asserting.

- [ ] **Step 2: Run the e2e suite**

Run: `npm run test:e2e`
Expected: all e2e tests pass (baseline + 2 new; 0 failures).

- [ ] **Step 3: Commit**

```bash
git add e2e/inbox.e2e.test.ts
git commit -m "$(cat <<'EOF'
test(F6): e2e for inbox alias mint + rotate (real HTTP)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Final verification + Email Routing config note

**Files:**
- Modify: `wrangler.jsonc` (add a documentation comment for the Email Routing catch-all — no binding change)

Email Routing inbound is provisioned in the Cloudflare dashboard (a catch-all route on the `in.snapceipt.app` zone → this Worker), not in `wrangler.jsonc`. Leave a comment so the deploy step is discoverable.

- [ ] **Step 1: Add the config note**

In `wrangler.jsonc`, add a comment line above the `"ai"` binding:

```jsonc
  // Inbound Email Routing (F6): provision a catch-all on the in.snapceipt.app zone
  // in the Cloudflare dashboard, routing to this Worker's email() handler. No binding
  // is declared here (inbound email is a handler, not a binding). The "ai" binding
  // below powers email-in OCR (gated by E2E_EMAIL_MODE in tests).
  "ai": { "binding": "AI" },
```

- [ ] **Step 2: Full verification**

Run: `npm run typecheck`
Expected: no errors.

Run: `npm test`
Expected: all unit tests pass; the new suites (`email-in-schema`, `inboxToken`, `inbox-routes`, `ocr`, `receiptRows`, `inbound`) are included; 0 failures.

Run: `npm run test:e2e`
Expected: all e2e tests pass (baseline + 2; 0 failures).

- [ ] **Step 3: Commit**

```bash
git add wrangler.jsonc
git commit -m "$(cat <<'EOF'
docs(F6): note the inbound Email Routing catch-all (dashboard-provisioned)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- §2.1 migration 0003 (both server-only tables) → Task 1. ✓
- §2.2 alias format + resolution → Task 2 (`generateInboxToken`/`addressForToken`/`tokenFromRecipient`). ✓
- §2.3 inbound flow → Task 6 (`inboundEmailLogic`) + Task 7 (`email()` wrapper). ✓
- §3.1 inbox endpoints (mint + rotate, 404 cross-user) → Task 3 + e2e Task 8. ✓
- §3.2 `InboundResult` type → Task 6. ✓
- §3.3 `writeReceiptRows` mapping (dollars→cents, `coerceCatKey`, mode, is_ai, line items, receipt_images, failed path) → Task 5. ✓
- §3.5 profile scoping (stamped profile_id) → asserted in Tasks 5 & 6. ✓
- §4 backend files → Tasks 1–7, 9 (inboxToken, ocr, receiptRows, inbound, inbox routes, index wiring, rate tier, env flag, wrangler note, postal-mime). ✓
- §6 error handling (unknown/no-image reject, dedup, OCR/extraction failure → failed txn, oversized → no_image, swallow) → Tasks 6 & 7 (`MAX_IMAGE_BYTES`, terminal-only log, try/catch wrapper). ✓
- §7.1 backend tests (resolve/reject/dedup/happy/extraction-failure/scoping, token unit, routes, e2e) → Tasks 2, 3, 5, 6, 8. ✓
- §7.3 stub seams (`E2E_EMAIL_MODE`, `E2E_EXTRACT_MODE`, absent AI) → Tasks 4 & 6. ✓

**Placeholder scan:** No TBD/TODO. Every code step shows full code; commands have explicit expected output. The only deferred verifications are explicitly conditional (the `deleted_at` column check in Task 3, the `postal-mime` static-vs-dynamic import in Task 6, and the `/sync/push` profile shape in Task 8) — each names the exact fallback. ✓

**Type consistency:** `InboxOwner {userId, profileId}` used identically in Tasks 2 & 6; `WriteReceiptArgs` fields in Task 5 match the call site in Task 6; `InboundMessage`/`InboundResult` defined in Task 6 and consumed in Task 7; `STUB_OCR_TEXT` exported in Task 4 and relied on (33.00 total) in Task 6's happy-path assertion; `coerceCatKey` returns the `CatKey` union used in the transactions INSERT. ✓
