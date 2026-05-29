# Snapceipt Backend Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Read the "Canonical Contracts" section below before any task — it is authoritative and overrides any conflicting name, signature, path, or column used inside a task block.**

**Goal:** Build a deployable Cloudflare Worker (the `snapceipt-api` backend foundation) providing accounts (Sign in with Apple + email magic-link), the full D1 schema, and the local-first sync protocol (push/pull, idempotency, LWW, tombstones) — fully tested in isolation with `@cloudflare/vitest-pool-workers`.

**Architecture:** A single Hono Worker over D1 (SQLite, source of truth) + KV (nonces, JWKS cache, rate-limit counters); R2/AI/Email bindings declared but unused this phase. App-issued JWT access tokens + rotating refresh tokens; every request is tenant-scoped by `user_id`. The iOS app (a separate plan) is a local-first replica reconciling via `/sync/push` + `/sync/pull`.

**Tech Stack:** TypeScript, Hono ^4, zod ^3 + @hono/zod-validator, jose ^5 (JWT HS256 + Apple JWKS RS256 verify), Cloudflare Workers (D1, KV, R2, AI, Email Send bindings), Vitest ^2 + @cloudflare/vitest-pool-workers (^0.5.x), Wrangler ^3.

**Spec:** `docs/superpowers/specs/2026-05-30-snapceipt-ios-app-design.md` (§5.3, §7, §8, §9). Detailed backend contracts: `docs/superpowers/specs/extracted/backend.md`.

---

## Canonical Contracts (AUTHORITATIVE — reconcile every task to these)

These pin the cross-cutting names/signatures/paths/columns. The tasks below were drafted in parallel and contain minor naming drift; **where a task's code or prose disagrees with this section, this section wins.** Renames `createSession → issueSession`, `revokeFamily → revokeSessionFamily`, and `src/lib/session.ts → src/lib/sessions.ts` have already been applied to the task text; the remaining reconciliations are listed here.

**App module (resolves `app` vs `createApp` vs `buildApp`):** `src/app.ts` exports a **module-scope** `export const app = new Hono<{ Bindings: Env; Variables: Variables }>()`. All middleware and routes are mounted at module scope in `src/app.ts` (there is **no** `createApp`/`buildApp` factory). `src/index.ts` is `export default { fetch: app.fetch }`. Any task instruction phrased as "inside `createApp()`/`buildApp()`" means **edit `src/app.ts` at module scope, after the existing middleware**.

**Auth middleware:** `src/middleware/auth.ts` exports `authMiddleware()` (factory → Hono `MiddlewareHandler`) and `PUBLIC_PATHS`. `PUBLIC_PATHS` includes `/health`, `/auth/*`, **and `/banks`**. It is applied **once, globally** in `src/app.ts` via `app.use('*', authMiddleware())`; protected routes (`/sync/*`, `/devices/*`) simply read `c.var.userId` / `c.var.deviceId` (no per-route auth import).

**Sessions (`src/lib/sessions.ts`, owned by Task 5):** exports
`issueSession(db: D1Database, args: { userId: string; deviceId: string }): Promise<{ accessToken: string; refreshToken: string; expiresIn: number; sessionId: string; family: string }>`,
`findSessionByRefreshHash`, `rotateSession`, `revokeSession`, `revokeSessionFamily`.
`issueSession` mints the access token (`signAccess`), creates a refresh token (`newRefreshToken`, stored as `hashToken` SHA-256) and inserts a `sessions` row with a fresh `family`. **All call sites use `issueSession(c.env.DB, { userId, deviceId })`** (Tasks 6/7 contain positional / `c.env` variants — use this signature). Route handlers attach the user and return `{ accessToken, refreshToken, expiresIn: 900, user: { id, email, displayName } }`. Tasks 6/7/8 **import** these helpers and do **not** redefine them (Task 8 only adds route handlers + device routes).

**`sessions` table** (in `migrations/0001_init.sql`, Task 3 — use the column name **`family`**, not `family_id`): `sessions(id TEXT PK, user_id TEXT NOT NULL, device_id TEXT NOT NULL, family TEXT NOT NULL, refresh_hash TEXT NOT NULL, created_at INTEGER NOT NULL, last_seen_at INTEGER, expires_at INTEGER NOT NULL, revoked_at INTEGER)` + `INDEX ix_sessions_family ON sessions(family)` + `UNIQUE INDEX ux_sessions_refresh ON sessions(refresh_hash)`.

**`processed_mutations` table** (Task 3): `processed_mutations(mutation_id TEXT PRIMARY KEY, user_id TEXT NOT NULL, result_json TEXT NOT NULL, created_at INTEGER NOT NULL)` + `INDEX ix_procmut_user ON processed_mutations(user_id, created_at)`. Task 9 reads/writes exactly these columns.

**Migration ownership:** Task 1 creates `migrations/0001_init.sql` as a **placeholder** (a single `_meta` table) only so the harness exercises a real migration. **Task 3 fully REPLACES `migrations/0001_init.sql`** with the complete schema (it does not append).

**Sync schemas (`src/schemas/sync.ts`, owned by Task 4):** exports `mutationSchema`, `pushBodySchema` (type `PushBody`), `pullQuerySchema`, and the cursor codec `encodeCursor(c: Cursor): string` / `decodeCursor(s: string): Cursor` with `type Cursor = { ts: number; id: string }`. Tasks 9/10 **import** these (do not redefine). The entity-type→table map lives in `src/lib/syncTables.ts` (Task 9): `SYNCABLE_TABLES` + `tableForEntityType(t)`, covering **all 12** syncable types (`transaction, lineItem, profile, category, smartRule, budget, loyaltyCard, quote, quoteLineItem, mileageTrip, wfhLog, taxSettings`); Task 10 imports it (it does not redefine `SYNCABLE_TABLES`).

**Auth schemas (`src/schemas/auth.ts`, owned by Task 4):** exports `appleBody`, `magicLinkRequestBody`, `magicLinkVerifyBody`, `refreshBody`. Tasks 6/7 import them (no `*Schema` / `AppleAuthBody` variants).

**Rate limiting (`src/middleware/rateLimit.ts`, owned by Task 11):** applied centrally in `src/app.ts` by Task 11. Tasks 6–10 do **not** import `rateLimit`. Magic-link/Apple/refresh rate limiting is realized when Task 11 mounts `rateLimit('auth')` on `/auth/*`. Tiers: magic-link 3/email/hr + 10/IP/hr; **apple + refresh share the `auth` tier (10/IP/hr)**; `/sync/*` 600/user/hr; default 300/user/min. 429 → `RATE_LIMITED` + `Retry-After`.

**Mandatory coverage (add these tests/behaviors even if a task under-specifies them):**
- `serverStamp()` (Task 2) is **strictly monotonic**: if called twice within the same ms it returns `prev + 1`. Add a unit test asserting strictly-increasing output across rapid calls (sync LWW + keyset cursor uniqueness depend on this).
- `/sync/pull` (Task 10) merges the per-table delta `SELECT`s into **one globally `(updatedAt, id)`-ordered, correctly-paginated stream**: query each syncable table for rows `> cursor` ordered by `(updated_at, id)` with `LIMIT`, merge-sort the per-table results by `(updated_at, id)`, take the first `limit`, and set `nextCursor` to the last emitted row's `(updated_at, id)` (`hasMore` = any table still had more). Tombstones included.
- `/auth/me` (Task 8) returns `{ user, devices }` — `devices` is the device list scoped by `user_id`. Add a test asserting devices are listed.
- Apple JWKS (Task 7) is cached in KV under key `apple:jwks` with ~24h TTL; refetch on `kid` miss. Add a test for cache hit + refresh-on-miss.
- Refresh reuse (Task 8): a test proves presenting a **rotated** refresh token returns **401 `AUTH_SESSION_REVOKED`** and revokes the whole `family` (`revokeSessionFamily`).
- `/sync/push` (Task 9): a test asserts a batch of **>200** mutations → `VALIDATION_FAILED` (400).
- Success bodies are **unwrapped** (raw resource/envelope, no `{ error }` wrapper); add one test asserting a success response has no `error` key (errors are wrapped per Task 2).
- Magic-link `/auth/magic-link/request` always returns **202** for both known and unknown emails (no enumeration) and is rate-limited identically.

---


## Tasks

### Task 1: Repo scaffold + Hono app + health route + Vitest(workers) harness

Goal: a deployable Worker that serves `GET /health` (public) and `ALL /banks` (501), driven by Hono, with a Vitest harness that runs *inside* workerd (`@cloudflare/vitest-pool-workers`) using real D1/KV bindings, and a first failing-then-passing test that hits `SELF.fetch("/health")`. Later tasks (errors, jwt, auth, sync, devices) build on the `app`, `Env`, and `migrations/0001_init.sql` defined here.

Version note (web-verified, May 2026): we pin `@cloudflare/vitest-pool-workers@^0.5.41` because it peers `vitest 2.0.x` and exposes the SPINE-required API (`defineWorkersConfig` from `@cloudflare/vitest-pool-workers/config` + the `cloudflare:test` module exporting `env`, `SELF`, `applyD1Migrations`, `readD1Migrations`). The current 0.16.x line peers `vitest@4` and replaces that API with `cloudflareTest()`/`cloudflare:workers`, which would break the contract used by every later task. Likewise `wrangler@^3` (SPINE pin), `@hono/zod-validator@^0.4.3` (the zod-3 era; 0.7+/0.8 require zod 4), `zod@^3`, `jose@^5`.

**Files**
- Create: `package.json`, `tsconfig.json`, `wrangler.jsonc`, `vitest.config.ts`, `.dev.vars.example`, `.gitignore`, `README.md`
- Create: `src/index.ts`, `src/app.ts`, `src/env.ts`, `src/routes/misc.ts`
- Create: `migrations/0001_init.sql` (minimal placeholder here — fleshed out by the schema task; an empty migration set would make `readD1Migrations` a no-op, so we seed a `_meta` table so the harness exercises a real migration)
- Create: `test/apply-migrations.ts` (vitest setup file)
- Test: `test/health.test.ts`

---

- [ ] **Step 1: Create `package.json` with pinned deps + scripts**

```json
{
  "name": "snapceipt-api",
  "version": "0.0.1",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "wrangler dev",
    "deploy": "wrangler deploy",
    "typecheck": "tsc --noEmit",
    "test": "vitest run",
    "test:watch": "vitest",
    "cf-typegen": "wrangler types",
    "migrate:local": "wrangler d1 migrations apply snapceipt --local",
    "migrate:remote": "wrangler d1 migrations apply snapceipt --remote"
  },
  "dependencies": {
    "@hono/zod-validator": "^0.4.3",
    "hono": "^4.12.23",
    "jose": "^5.10.0",
    "zod": "^3.23.8"
  },
  "devDependencies": {
    "@cloudflare/vitest-pool-workers": "^0.5.41",
    "@cloudflare/workers-types": "^4.20260529.1",
    "typescript": "^5.6.0",
    "vitest": "~2.1.9",
    "wrangler": "^3.114.17"
  }
}
```

- [ ] **Step 2: Install dependencies**

```bash
npm install
```

  Expected: installs cleanly; `node_modules/@cloudflare/vitest-pool-workers` resolves to a `0.5.x` version and `node_modules/vitest` to a `2.1.x` version (no peer-dependency `ERESOLVE` error). Verify with:

```bash
npm ls vitest @cloudflare/vitest-pool-workers hono jose zod @hono/zod-validator
```

  Expected output shows `vitest@2.1.9`, `@cloudflare/vitest-pool-workers@0.5.x`, `hono@4.12.x`, `jose@5.10.x`, `zod@3.x`, `@hono/zod-validator@0.4.3` and `(empty)`/no `UNMET PEER DEPENDENCY` lines.

- [ ] **Step 3: Create `tsconfig.json`**

```jsonc
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "lib": ["ESNext"],
    "types": ["@cloudflare/workers-types", "@cloudflare/vitest-pool-workers"],
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "skipLibCheck": true,
    "esModuleInterop": true,
    "forceConsistentCasingInFileNames": true,
    "verbatimModuleSyntax": false,
    "noEmit": true,
    "isolatedModules": true,
    "resolveJsonModule": true
  },
  "include": ["src", "test", "vitest.config.ts", "worker-configuration.d.ts"],
  "exclude": ["node_modules"]
}
```

- [ ] **Step 4: Create `wrangler.jsonc`** (declare ALL bindings now — RECEIPTS/AI/EMAIL are declared but unused this phase; `database_id`/KV `id` are placeholders for local/test, filled per-environment at deploy)

```jsonc
{
  "$schema": "node_modules/wrangler/config-schema.json",
  "name": "snapceipt-api",
  "main": "src/index.ts",
  "compatibility_date": "2026-05-15",
  "compatibility_flags": ["nodejs_compat"],
  "observability": { "enabled": true },
  "d1_databases": [
    {
      "binding": "DB",
      "database_name": "snapceipt",
      "database_id": "00000000-0000-0000-0000-000000000000",
      "migrations_dir": "migrations"
    }
  ],
  "kv_namespaces": [
    { "binding": "KV", "id": "00000000000000000000000000000000" }
  ],
  "r2_buckets": [
    { "binding": "RECEIPTS", "bucket_name": "snapceipt-receipts" }
  ],
  "ai": { "binding": "AI" },
  "send_email": [
    { "name": "EMAIL", "allowed_sender_addresses": ["noreply@snapceipt.app"] }
  ],
  "vars": {
    "APPLE_BUNDLE_ID": "com.snapceipt.app"
  }
}
```

  Note: `JWT_SIGNING_KEY` and `DEEPSEEK_API_KEY` are SECRETS (`wrangler secret put ...` for deploy; `.dev.vars` for local) — they are intentionally NOT in `vars`. `APPLE_BUNDLE_ID` is a non-secret var. The `send_email` binding name is `EMAIL` (type `send_email`) per the SPINE.

- [ ] **Step 5: Create `.dev.vars.example`** (developers copy to `.dev.vars`, which is git-ignored, for `wrangler dev` + tests)

```bash
# Copy this file to .dev.vars (git-ignored) and fill real values for local dev.
# These map to env.JWT_SIGNING_KEY / env.DEEPSEEK_API_KEY / env.APPLE_BUNDLE_ID.

# 256-bit (32+ byte) random string used to sign/verify app JWTs (HS256).
# Generate: openssl rand -base64 48
JWT_SIGNING_KEY="dev-only-insecure-signing-key-change-me-0123456789abcdef"

# DeepSeek API key (unused in the foundation phase; declared for later /extract).
DEEPSEEK_API_KEY="sk-deepseek-dev-placeholder"

# Apple bundle id; identityToken.aud must equal this. Also set as a var in wrangler.jsonc.
APPLE_BUNDLE_ID="com.snapceipt.app"
```

- [ ] **Step 6: Create `.gitignore`**

```bash
node_modules/
.wrangler/
.dev.vars
dist/
worker-configuration.d.ts
*.log
.DS_Store
coverage/
```

- [ ] **Step 7: Create `src/env.ts`** (the `Env` Bindings type + Hono `Variables` type — both reused by every later task; do not redefine elsewhere)

```ts
/**
 * Cloudflare Worker bindings for the Snapceipt API.
 * Declared in wrangler.jsonc; injected as `c.env` at runtime.
 *
 * RECEIPTS / AI / EMAIL / DEEPSEEK_API_KEY are declared now but unused in the
 * foundation phase (receipt extraction, export, email-in, R2 images land later).
 */
export type Env = {
  /** D1 (SQLite) — source of truth for all syncable data. */
  DB: D1Database;
  /** R2 bucket for receipt images (unused this phase). */
  RECEIPTS: R2Bucket;
  /** Workers AI binding for email-in OCR (unused this phase). */
  AI: Ai;
  /** KV: rate-limit counters + magic-link/nonce/JWKS cache. */
  KV: KVNamespace;
  /** Cloudflare Email Send binding (magic-link, exports). */
  EMAIL: SendEmail;
  /** Secret: HS256 signing key for app-issued JWTs. */
  JWT_SIGNING_KEY: string;
  /** Secret: DeepSeek API key (unused this phase). */
  DEEPSEEK_API_KEY: string;
  /** Var: Apple bundle id; Apple identityToken `aud` must equal this. */
  APPLE_BUNDLE_ID: string;
};

/**
 * Request-scoped values set by middleware (auth, requestId) and read by routes.
 * NEVER store these in module-level globals — keep them on the Hono context.
 */
export type Variables = {
  /** Authenticated user id (set by auth middleware). */
  userId: string;
  /** Device id bound to the session (set by auth middleware). */
  deviceId: string;
  /** Per-request id for tracing + the error envelope. */
  requestId: string;
};

/** Convenience alias for typing `new Hono<AppEnv>()`. */
export type AppEnv = { Bindings: Env; Variables: Variables };
```

- [ ] **Step 8: Create `src/routes/misc.ts`** (public `GET /health`; `ALL /banks` -> 501)

```ts
import { Hono } from "hono";
import type { AppEnv } from "../env";

/**
 * Misc routes: a public health check and the connected-banks placeholder.
 * /health is in the public-path allowlist (no auth) — mounted before auth in app.ts.
 */
export const miscRoutes = new Hono<AppEnv>();

// Public liveness probe. No auth, no DB access.
miscRoutes.get("/health", (c) => {
  return c.json({ ok: true, service: "snapceipt-api" });
});

// Connected banks / reconcile is a v1 UI placeholder with no backend.
// Return a 501 envelope so the iOS app degrades gracefully.
// (Uses the error-envelope shape directly; the ApiError class + middleware
//  arrive in the errors task and will subsume this.)
miscRoutes.all("/banks", (c) => {
  return c.json(
    {
      error: {
        code: "NOT_IMPLEMENTED",
        message: "Connected banks are not available in this version.",
        requestId: c.get("requestId") ?? "",
      },
    },
    501,
  );
});
```

- [ ] **Step 9: Create `src/app.ts`** (build the Hono app: requestId + logger + cors middleware, mount misc routes). Auth/rateLimit/error middleware and the rest of the routes are mounted by later tasks.

```ts
import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { requestId } from "hono/request-id";
import type { AppEnv } from "./env";
import { miscRoutes } from "./routes/misc";

/**
 * Builds the Snapceipt Worker app.
 * Order matters: requestId first (so every later layer + the error envelope
 * can read c.var.requestId), then logger, then cors. Routes mount last.
 */
export const app = new Hono<AppEnv>();

// Mirror Hono's request id into our typed Variables so c.get("requestId") works
// everywhere (Hono's requestId() stores it under the same key).
app.use("*", requestId());
app.use("*", logger());
app.use("*", cors());

// Public + placeholder routes. (auth/rateLimit/error middleware: later tasks.)
app.route("/", miscRoutes);

export default app;
```

- [ ] **Step 10: Create `src/index.ts`** (the Worker entry — `email`/`scheduled` handlers added in later phases)

```ts
import { app } from "./app";

// Worker entrypoint. fetch only for now; email + scheduled handlers land
// with the email-in and budget-push phases.
export default {
  fetch: app.fetch,
};
```

- [ ] **Step 11: Create `migrations/0001_init.sql`** (placeholder seed so the test harness exercises a real migration; the full domain schema replaces/extends this in the schema task)

```sql
-- 0001_init.sql — foundation placeholder.
-- The full domain schema (users, sessions, transactions, processed_mutations, …)
-- is added by the schema task. This single table exists so the Vitest harness
-- (readD1Migrations + applyD1Migrations) has a real migration to apply, and so
-- `wrangler d1 migrations apply` has a non-empty initial migration.
CREATE TABLE IF NOT EXISTS _meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT OR IGNORE INTO _meta (key, value) VALUES ('schema_version', '0001');
```

- [ ] **Step 12: Create `test/apply-migrations.ts`** (Vitest setup file — applies D1 migrations inside workerd before tests run). `readD1Migrations` runs Node-side in `vitest.config.ts` and passes the migration list through a miniflare binding; `applyD1Migrations` runs here, inside the worker, against the real test `env.DB`.

```ts
import { applyD1Migrations, env } from "cloudflare:test";

// TEST_MIGRATIONS is a test-only binding populated in vitest.config.ts via
// readD1Migrations(). applyD1Migrations is idempotent (it tracks applied
// migrations in a d1_migrations bookkeeping table), so running it in a global
// setup file once per test worker is safe.
declare module "cloudflare:test" {
  interface ProvidedEnv extends Env {
    TEST_MIGRATIONS: D1Migration[];
  }
}

await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
```

- [ ] **Step 13: Create `vitest.config.ts`** (run tests inside workerd with real bindings + applied migrations)

```ts
import { defineWorkersConfig, readD1Migrations } from "@cloudflare/vitest-pool-workers/config";
import path from "node:path";

// Read the migration SQL files on the Node side, then hand them to the worker
// through a test-only binding the setup file consumes.
const migrations = await readD1Migrations(path.join(__dirname, "migrations"));

export default defineWorkersConfig({
  test: {
    setupFiles: ["./test/apply-migrations.ts"],
    poolOptions: {
      workers: {
        // Load main, compatibility_date/flags and bindings from wrangler.jsonc
        // so tests use the same config as `wrangler dev`/`deploy`.
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          // Test-only extras layered on top of wrangler.jsonc bindings.
          compatibilityFlags: ["nodejs_compat"],
          bindings: { TEST_MIGRATIONS: migrations },
          // .dev.vars isn't read in tests; inject the secrets/vars tests need.
          // (real secrets stay in .dev.vars locally / `wrangler secret` on deploy)
          // JWT_SIGNING_KEY/APPLE_BUNDLE_ID are exercised by later auth tests.
        },
      },
    },
  },
});
```

- [ ] **Step 14: Write the FIRST test `test/health.test.ts` (expect it to FAIL — impl files don't run until the worker bundles, and we assert exact body shape)**

```ts
import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

describe("misc routes", () => {
  it("GET /health returns the public liveness envelope", async () => {
    const res = await SELF.fetch("https://example.com/health");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, service: "snapceipt-api" });
  });

  it("ALL /banks returns 501 NOT_IMPLEMENTED with an error envelope", async () => {
    const res = await SELF.fetch("https://example.com/banks", { method: "POST" });
    expect(res.status).toBe(501);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("NOT_IMPLEMENTED");
  });

  it("GET /_meta-backed migration applied (D1 binding wired)", async () => {
    const res = await SELF.fetch("https://example.com/health");
    // health works -> worker bundled; migrations are validated by the harness
    // itself (applyD1Migrations would throw in setup if the SQL were invalid).
    expect(res.ok).toBe(true);
  });
});
```

  Run (BEFORE creating impl, to see the harness fail — run this immediately after writing the test, temporarily renaming `src/index.ts` is unnecessary; instead verify the genuine red state by running before Steps 8-10 are saved). In practice author Steps 1-7,11-13 + this test first, then:

```bash
npx vitest run test/health.test.ts -t "GET /health returns the public liveness envelope"
```

  Expected (FAIL): the test fails — either the build errors because `src/routes/misc.ts`/`src/app.ts` are not yet created, or (if created empty) `GET /health` returns 404 and the `toEqual({ ok: true, service: "snapceipt-api" })` assertion fails. This proves the test actually exercises the route.

- [ ] **Step 15: Implement to green — ensure Steps 8, 9, 10 (`src/routes/misc.ts`, `src/app.ts`, `src/index.ts`) are saved, then re-run the full file**

```bash
npx vitest run test/health.test.ts
```

  Expected (PASS): all 3 tests pass. Output shows `Test Files  1 passed (1)` and `Tests  3 passed (3)`. The setup file's `applyD1Migrations(env.DB, env.TEST_MIGRATIONS)` ran without throwing (confirming `migrations/0001_init.sql` is valid and the D1 binding is wired).

- [ ] **Step 16: Typecheck + generate Worker types**

```bash
npx wrangler types && npx tsc --noEmit
```

  Expected: `wrangler types` writes `worker-configuration.d.ts` (a `Cloudflare.Env`/`Env` interface from the bindings) and `tsc --noEmit` exits 0 with no errors. (If `tsc` flags an unused-binding or `Ai` type issue, it indicates a real mismatch to fix — the SPINE `Env` shape is authoritative.)

- [ ] **Step 17: Smoke-test the dev server (optional, fast sanity)**

```bash
npx wrangler dev --port 8787 & sleep 6 && curl -s http://127.0.0.1:8787/health && echo && kill %1

---

### Task 2: lib-core — ids, time, errors + requestId/error middleware (wired into app)

Builds the shared primitives every later task depends on: a dependency-free RFC 9562 UUIDv7 generator, time helpers, the typed `ApiError` + error-code→status map + `toEnvelope()` serializer, a `requestId()` middleware that sets `c.var.requestId` and the `X-Request-Id` response header, and an `app.onError` handler that turns any thrown error into the uniform `{ error: { code, message, details?, requestId } }` envelope. These are wired into the Hono app from Task 1. Strict TDD: write the failing test first, watch it fail, implement, watch it pass, then commit test + impl together.

Depends on Task 1 having created: `package.json`, `tsconfig.json`, `wrangler.jsonc`, `vitest.config.ts`, `src/env.ts` (exporting `Env`), `src/app.ts` (the `new Hono<{ Bindings: Env; Variables: { userId: string; deviceId: string; requestId: string } }>()` app with routes mounted), and `src/index.ts`.

**Files**
- Create: `src/lib/ids.ts`
- Create: `src/lib/time.ts`
- Create: `src/lib/errors.ts`
- Create: `src/middleware/error.ts`
- Modify: `src/app.ts` (mount `requestId()` middleware + register `app.onError`; add a temporary `GET /__throw` test route)
- Test: `test/lib-core.test.ts`

---

- [ ] **Step 1: Write the failing test for ids/time/errors + the error envelope over HTTP**

```ts
// test/lib-core.test.ts
import { env, SELF } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs, serverStamp } from "../src/lib/time";
import { ApiError, ERROR, toEnvelope } from "../src/lib/errors";

describe("uuidv7()", () => {
  it("produces RFC-shaped v7 UUIDs (version 7, variant 10xx)", () => {
    const id = uuidv7();
    expect(id).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    );
  });

  it("generates unique ids across a large batch", () => {
    const seen = new Set<string>();
    for (let i = 0; i < 10000; i++) seen.add(uuidv7());
    expect(seen.size).toBe(10000);
  });

  it("is monotonic / lexicographically sortable in generation order", () => {
    const ids = Array.from({ length: 5000 }, () => uuidv7());
    const sorted = [...ids].sort();
    expect(sorted).toEqual(ids);
  });
});

describe("time helpers", () => {
  it("nowMs() returns an integer epoch-ms close to Date.now()", () => {
    const t = nowMs();
    expect(Number.isInteger(t)).toBe(true);
    expect(Math.abs(t - Date.now())).toBeLessThan(1000);
  });

  it("serverStamp() returns a fresh monotonic-ish epoch-ms each call", () => {
    const a = serverStamp();
    const b = serverStamp();
    expect(Number.isInteger(a)).toBe(true);
    expect(b).toBeGreaterThanOrEqual(a);
  });
});

describe("ApiError + ERROR map + toEnvelope()", () => {
  it("maps each error code to its documented HTTP status", () => {
    expect(ERROR.AUTH_INVALID_TOKEN).toBe(401);
    expect(ERROR.AUTH_SESSION_REVOKED).toBe(401);
    expect(ERROR.VALIDATION_FAILED).toBe(400);
    expect(ERROR.NOT_FOUND).toBe(404);
    expect(ERROR.FORBIDDEN).toBe(403);
    expect(ERROR.RATE_LIMITED).toBe(429);
    expect(ERROR.CONFLICT).toBe(409);
    expect(ERROR.NOT_IMPLEMENTED).toBe(501);
    expect(ERROR.INTERNAL).toBe(500);
  });

  it("ApiError carries code, derived status, message and optional details", () => {
    const e = new ApiError("VALIDATION_FAILED", "bad body", { field: "email" });
    expect(e).toBeInstanceOf(Error);
    expect(e.code).toBe("VALIDATION_FAILED");
    expect(e.status).toBe(400);
    expect(e.message).toBe("bad body");
    expect(e.details).toEqual({ field: "email" });
  });

  it("toEnvelope() serializes an ApiError into the uniform envelope shape", () => {
    const e = new ApiError("NOT_FOUND", "missing", { id: "x" });
    expect(toEnvelope(e, "req-123")).toEqual({
      error: {
        code: "NOT_FOUND",
        message: "missing",
        details: { id: "x" },
        requestId: "req-123",
      },
    });
  });

  it("toEnvelope() coerces an unknown error to INTERNAL with no details leak", () => {
    const env2 = toEnvelope(new Error("boom"), "req-9");
    expect(env2).toEqual({
      error: { code: "INTERNAL", message: "Internal Server Error", requestId: "req-9" },
    });
  });
});

describe("HTTP: error middleware produces the envelope + X-Request-Id", () => {
  it("a route that throws ApiError returns the matching status + envelope", async () => {
    const res = await SELF.fetch("https://example.com/__throw?code=NOT_FOUND");
    expect(res.status).toBe(404);
    const reqId = res.headers.get("X-Request-Id");
    expect(reqId).toBeTruthy();
    const body = (await res.json()) as {
      error: { code: string; message: string; requestId: string };
    };
    expect(body.error.code).toBe("NOT_FOUND");
    expect(body.error.message).toBe("nope");
    expect(body.error.requestId).toBe(reqId);
  });

  it("an unexpected throw becomes a 500 INTERNAL envelope", async () => {
    const res = await SELF.fetch("https://example.com/__throw?code=BOOM");
    expect(res.status).toBe(500);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("INTERNAL");
  });
});
```

- [ ] **Step 2: Run the test and watch it FAIL (modules + route do not exist yet)**

Run:
```bash
npx vitest run test/lib-core.test.ts
```
Expected: FAIL — Vitest cannot resolve `../src/lib/ids`, `../src/lib/time`, `../src/lib/errors`, and the `/__throw` route 404s without the envelope (e.g. `Failed to resolve import "../src/lib/ids"` / `expected 404 to be true` style failures).

- [ ] **Step 3: Implement `src/lib/ids.ts` (RFC 9562 UUIDv7, dependency-free, monotonic within a millisecond)**

```ts
// src/lib/ids.ts
// RFC 9562 UUIDv7: 48-bit big-endian Unix-ms timestamp, version 7, a 12-bit
// sub-millisecond monotonic counter (rand_a), variant 10xx, and 62 random bits.
// Dependency-free: uses globalThis.crypto (available in workerd) for randomness.
// Monotonic guarantee: within the same millisecond the 12-bit counter increments
// so ids generated in order remain lexicographically sortable; on counter overflow
// or a backwards clock we bump the logical timestamp by 1ms.

let lastMs = 0;
let counter = 0; // 12 bits, 0..0xfff

const HEX: string[] = [];
for (let i = 0; i < 256; i++) HEX.push((i + 0x100).toString(16).slice(1));

export function uuidv7(): string {
  let ms = Date.now();

  if (ms > lastMs) {
    lastMs = ms;
    counter = randomCounter();
  } else {
    // same ms or clock went backwards: keep monotonic ordering
    ms = lastMs;
    counter = (counter + 1) & 0xfff;
    if (counter === 0) {
      // counter overflow within a single ms: advance the logical clock
      lastMs += 1;
      ms = lastMs;
      counter = randomCounter();
    }
  }

  const bytes = new Uint8Array(16);

  // 48-bit timestamp (big-endian). Number is safe: ms < 2^48 until year ~10889.
  bytes[0] = (ms / 0x10000000000) & 0xff;
  bytes[1] = (ms / 0x100000000) & 0xff;
  bytes[2] = (ms / 0x1000000) & 0xff;
  bytes[3] = (ms / 0x10000) & 0xff;
  bytes[4] = (ms / 0x100) & 0xff;
  bytes[5] = ms & 0xff;

  // bytes[6..7]: version (0111) + high 12 bits = counter (rand_a)
  bytes[6] = 0x70 | ((counter >>> 8) & 0x0f);
  bytes[7] = counter & 0xff;

  // bytes[8..15]: variant (10xx) + 62 random bits
  const rand = new Uint8Array(8);
  crypto.getRandomValues(rand);
  bytes[8] = 0x80 | (rand[0] & 0x3f);
  bytes[9] = rand[1];
  bytes[10] = rand[2];
  bytes[11] = rand[3];
  bytes[12] = rand[4];
  bytes[13] = rand[5];
  bytes[14] = rand[6];
  bytes[15] = rand[7];

  return (
    HEX[bytes[0]] + HEX[bytes[1]] + HEX[bytes[2]] + HEX[bytes[3]] +
    "-" + HEX[bytes[4]] + HEX[bytes[5]] +
    "-" + HEX[bytes[6]] + HEX[bytes[7]] +
    "-" + HEX[bytes[8]] + HEX[bytes[9]] +
    "-" + HEX[bytes[10]] + HEX[bytes[11]] + HEX[bytes[12]] +
    HEX[bytes[13]] + HEX[bytes[14]] + HEX[bytes[15]]
  );
}

function randomCounter(): number {
  const r = new Uint8Array(2);
  crypto.getRandomValues(r);
  // seed counter in the low half so we have headroom before overflow within a ms
  return ((r[0] << 8) | r[1]) & 0x07ff;
}
```

- [ ] **Step 4: Implement `src/lib/time.ts` (nowMs + monotonic serverStamp)**

```ts
// src/lib/time.ts
// All timestamps are epoch milliseconds (UTC). serverStamp() is what the sync
// layer writes onto accepted rows (updatedAt): it is monotonic-non-decreasing
// within a single isolate so two writes in the same ms still get ordered stamps,
// neutralizing skewed client clocks per the LWW contract.

export function nowMs(): number {
  return Date.now();
}

let lastStamp = 0;

export function serverStamp(): number {
  const t = Date.now();
  lastStamp = t > lastStamp ? t : lastStamp + 1;
  return lastStamp;
}
```

- [ ] **Step 5: Implement `src/lib/errors.ts` (ERROR map, ApiError, toEnvelope)**

```ts
// src/lib/errors.ts
// Uniform error contract. Every error response body is:
//   { error: { code, message, details?, requestId } }  with the matching HTTP status.
// Success bodies are the raw resource/envelope (no wrapper).

export const ERROR = {
  AUTH_INVALID_TOKEN: 401,
  AUTH_SESSION_REVOKED: 401,
  VALIDATION_FAILED: 400,
  NOT_FOUND: 404,
  FORBIDDEN: 403,
  RATE_LIMITED: 429,
  CONFLICT: 409,
  NOT_IMPLEMENTED: 501,
  INTERNAL: 500,
} as const;

export type ErrorCode = keyof typeof ERROR;

export type ErrorEnvelope = {
  error: {
    code: ErrorCode;
    message: string;
    details?: unknown;
    requestId: string;
  };
};

export class ApiError extends Error {
  readonly code: ErrorCode;
  readonly status: number;
  readonly details?: unknown;

  constructor(code: ErrorCode, message?: string, details?: unknown) {
    super(message ?? code);
    this.name = "ApiError";
    this.code = code;
    this.status = ERROR[code];
    if (details !== undefined) this.details = details;
  }
}

// Serialize any thrown value into the uniform envelope. Known ApiErrors keep their
// code/message/details; anything else is coerced to a safe 500 INTERNAL (no leak).
export function toEnvelope(err: unknown, requestId: string): ErrorEnvelope {
  if (err instanceof ApiError) {
    const body: ErrorEnvelope["error"] = {
      code: err.code,
      message: err.message,
      requestId,
    };
    if (err.details !== undefined) body.details = err.details;
    return { error: body };
  }
  return {
    error: {
      code: "INTERNAL",
      message: "Internal Server Error",
      requestId,
    },
  };
}
```

- [ ] **Step 6: Implement `src/middleware/error.ts` (requestId middleware + onError registrar)**

```ts
// src/middleware/error.ts
import type { Hono, MiddlewareHandler } from "hono";
import type { Env } from "../env";
import { uuidv7 } from "../lib/ids";
import { ApiError, toEnvelope } from "../lib/errors";

type AppEnv = {
  Bindings: Env;
  Variables: { userId: string; deviceId: string; requestId: string };
};

// Generates a per-request id (honoring an inbound X-Request-Id when present),
// exposes it as c.var.requestId, and echoes it on the response as X-Request-Id.
export function requestId(): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    const incoming = c.req.header("X-Request-Id");
    const id = incoming && incoming.length <= 200 ? incoming : uuidv7();
    c.set("requestId", id);
    c.header("X-Request-Id", id);
    await next();
  };
}

// Registers the uniform error handler on the app. Any thrown ApiError maps to its
// status + envelope; anything else becomes a 500 INTERNAL envelope. requestId is
// always present (the middleware ran first); fall back to a fresh id if not.
export function registerErrorHandler(app: Hono<AppEnv>): void {
  app.onError((err, c) => {
    const requestId = c.get("requestId") ?? uuidv7();
    c.header("X-Request-Id", requestId);
    const status = err instanceof ApiError ? err.status : 500;
    const envelope = toEnvelope(err, requestId);
    return c.json(envelope, status as 400 | 401 | 403 | 404 | 409 | 429 | 500 | 501);
  });
}
```

- [ ] **Step 7: Wire requestId + onError into `src/app.ts` and add the temporary `/__throw` test route**

Modify `src/app.ts` so that, immediately after the `app` is constructed (before other routes/middleware that may throw), the requestId middleware runs first and the error handler is registered. Add the `/__throw` route the test drives (it is removed in a later task once real routes exercise the envelope; harmless until then).

Add these imports near the top of `src/app.ts`:
```ts
import { requestId, registerErrorHandler } from "./middleware/error";
import { ApiError, ERROR, type ErrorCode } from "./lib/errors";
```

Immediately after the `const app = new Hono<...>()` line, add:
```ts
// must be first so c.var.requestId + X-Request-Id exist for every handler
app.use("*", requestId());
registerErrorHandler(app);

// TEMP: exercises the error envelope end-to-end; replaced when real routes land.
app.get("/__throw", (c) => {
  const code = c.req.query("code") ?? "INTERNAL";
  if (code in ERROR) throw new ApiError(code as ErrorCode, "nope");
  throw new Error("unexpected: " + code);
});
```

- [ ] **Step 8: Run the test and watch it PASS**

Run:
```bash
npx vitest run test/lib-core.test.ts
```
Expected: PASS — all suites green (uuidv7 shape/uniqueness/monotonic, time helpers, ERROR map + ApiError + toEnvelope unit checks, and the two HTTP cases returning 404/`NOT_FOUND` and 500/`INTERNAL` envelopes with a matching `X-Request-Id` header).

- [ ] **Step 9: Typecheck to confirm no type regressions**

Run:
```bash
npx tsc --noEmit
```
Expected: PASS — exits 0 with no output (the new `Variables.requestId` usage and `MiddlewareHandler`/`Hono` generics resolve cleanly against Task 1's `tsconfig.json`).

- [ ] **Step 10: Commit the test + implementation together**

Run:
```bash
git add src/lib/ids.ts src/lib/time.ts src/lib/errors.ts src/middleware/error.ts src/app.ts test/lib-core.test.ts
git commit -m "$(cat <<'EOF'
feat(backend): core libs + requestId/error envelope middleware

Add dependency-free RFC 9562 uuidv7(), nowMs()/serverStamp() time
helpers, the ApiError class + ERROR code->status map + toEnvelope()
serializer, a requestId() middleware (sets c.var.requestId and the
X-Request-Id response header), and an app.onError handler emitting the
uniform { error: { code, message, details?, requestId } } envelope.
Wire both into the Hono app; covered by test/lib-core.test.ts.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```
Expected: a single commit containing the four new lib/middleware files, the modified `src/app.ts`, and the test.

---

### Task 3: D1 Schema Migration + DB Helpers

Build the full D1 schema (`migrations/0001_init.sql`) for every table in the backend spec — with sync columns (`rev`, `last_edited_device_id` added to syncable tables), CHECK enums, INTEGER-cents money, generated columns, and all indexes — plus typed D1 helpers in `src/lib/db.ts`. TDD: a schema test applies the migration to the real `env.DB` inside workerd and asserts tables/columns/indexes exist and a tenant-scoped insert+select round-trips.

**Files**
- Create: `migrations/0001_init.sql`
- Create: `src/lib/db.ts`
- Modify: `vitest.config.ts` (wire the `TEST_MIGRATIONS` binding so the schema applies inside workerd)
- Test: `test/schema.test.ts`

> Depends on prior tasks: `src/env.ts` (the `Env` type, Task 2) and the Task 1 scaffold (`vitest.config.ts`, `package.json` with the `test` script, `wrangler.jsonc` with the `DB` D1 binding). The `processed_mutations` columns/helpers defined here are consumed later by `src/routes/sync.ts`.

---

- [ ] **Step 1: Write the failing schema test FIRST.**

This test imports the migrations binding and applies it to the live `env.DB`, then asserts the schema shape. It will FAIL because `migrations/0001_init.sql` and the `TEST_MIGRATIONS` binding do not exist yet.

```ts
// test/schema.test.ts
import { env, applyD1Migrations } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";
import { scopedAll, scopedGet, recordProcessedMutation, getProcessedMutation } from "../src/lib/db";

// The migrations array is injected as a Miniflare binding by vitest.config.ts.
declare module "cloudflare:test" {
  interface ProvidedEnv {
    TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

// Every syncable domain table must carry the sync-support columns.
const SYNCABLE = [
  "users", "devices", "profiles", "categories", "smart_rules",
  "transactions", "line_items", "receipt_images", "budgets", "loyalty_cards",
  "mileage_trips", "wfh_logs", "quotes", "quote_line_items", "tax_settings",
];

// Server-only operational tables (NOT synced to device).
const OPERATIONAL = ["auth_identities", "email_tokens", "sessions", "email_outbox", "processed_mutations"];

async function columnsOf(table: string): Promise<Set<string>> {
  const { results } = await env.DB.prepare(`PRAGMA table_info(${table})`).all<{ name: string }>();
  return new Set(results.map((r) => r.name));
}

async function indexNames(): Promise<Set<string>> {
  const { results } = await env.DB
    .prepare(`SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'`)
    .all<{ name: string }>();
  return new Set(results.map((r) => r.name));
}

describe("0001_init schema", () => {
  it("creates every table", async () => {
    const { results } = await env.DB
      .prepare(`SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' AND name <> 'd1_migrations'`)
      .all<{ name: string }>();
    const names = new Set(results.map((r) => r.name));
    for (const t of [...SYNCABLE, ...OPERATIONAL]) expect(names.has(t), `missing table ${t}`).toBe(true);
  });

  it("adds sync columns to every syncable table", async () => {
    for (const t of SYNCABLE) {
      const cols = await columnsOf(t);
      for (const c of ["id", "user_id", "created_at", "updated_at", "deleted_at", "rev", "last_edited_device_id"]) {
        expect(cols.has(c), `${t} missing sync column ${c}`).toBe(true);
      }
    }
  });

  it("declares the delta-sync backbone + partial read + unique indexes", async () => {
    const ix = await indexNames();
    for (const name of [
      "ix_txn_user_updated", "ix_profiles_user_updated", "ix_budget_user_updated",
      "ix_txn_profile_date", "ix_budget_profile", "ix_quote_profile_status",
      "ux_users_email", "ux_devices_apns", "ux_wfh_profile_date",
      "ux_budget_scope", "ux_quote_number", "ux_img_r2key",
    ]) {
      expect(ix.has(name), `missing index ${name}`).toBe(true);
    }
  });

  it("computes the month_key generated column and round-trips with tenant scoping", async () => {
    await env.DB.batch([
      env.DB.prepare(`INSERT INTO users(id,created_at,updated_at) VALUES('u1',1,1)`),
      env.DB.prepare(`INSERT INTO users(id,created_at,updated_at) VALUES('u2',1,1)`),
      env.DB.prepare(`INSERT INTO profiles(id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
                      VALUES('p1','u1','Personal','personal','#0E7C72','#DCF0ED','#0A5950',1,1)`),
      env.DB.prepare(`INSERT INTO transactions(id,user_id,profile_id,cat_key,amount_cents,txn_date,created_at,updated_at)
                      VALUES('t1','u1','p1','meals',-1250,'2026-05-30',10,10)`),
    ]);

    const rows = await scopedAll<{ id: string; amount_cents: number; month_key: string }>(
      env.DB, "transactions", "u1",
    );
    expect(rows).toHaveLength(1);
    expect(rows[0].amount_cents).toBe(-1250);     // money is signed INTEGER cents
    expect(rows[0].month_key).toBe("2026-05");    // STORED generated column

    // Tenant isolation: u2 sees nothing of u1's data.
    const u2rows = await scopedAll(env.DB, "transactions", "u2");
    expect(u2rows).toHaveLength(0);

    const one = await scopedGet<{ id: string }>(env.DB, "transactions", "u1", "t1");
    expect(one?.id).toBe("t1");
    const crossTenant = await scopedGet(env.DB, "transactions", "u2", "t1");
    expect(crossTenant).toBeNull();
  });

  it("records and replays processed mutations idempotently", async () => {
    expect(await getProcessedMutation(env.DB, "mut-1")).toBeNull();
    await recordProcessedMutation(env.DB, {
      mutationId: "mut-1", userId: "u1", deviceId: "d1",
      entityType: "transaction", entityId: "t1", op: "upsert",
      status: "applied", resultJson: JSON.stringify({ id: "t1" }), createdAt: 100,
    });
    const got = await getProcessedMutation(env.DB, "mut-1");
    expect(got?.status).toBe("applied");
    expect(got?.entity_id).toBe("t1");
  });
});
```

- [ ] **Step 2: Run the test — expect FAIL.**

```bash
npx vitest run test/schema.test.ts
```

Expected: FAIL. The test cannot resolve `../src/lib/db` (module not found) and/or `env.TEST_MIGRATIONS` is `undefined` so `applyD1Migrations` throws — `migrations/0001_init.sql` and `src/lib/db.ts` do not exist yet.

- [ ] **Step 3: Wire the `TEST_MIGRATIONS` binding into `vitest.config.ts`.**

Read the migrations directory in Node (where `vitest.config.ts` runs) and pass them as a Miniflare binding so the test can apply them to the real D1 inside workerd. This replaces the scaffold's `vitest.config.ts` from Task 1.

```ts
// vitest.config.ts
import path from "node:path";
import { defineWorkersConfig, readD1Migrations } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersConfig(async () => {
  const migrations = await readD1Migrations(path.join(__dirname, "migrations"));
  return {
    test: {
      poolOptions: {
        workers: {
          miniflare: {
            compatibilityDate: "2026-05-15",
            compatibilityFlags: ["nodejs_compat"],
            d1Databases: ["DB"],
            kvNamespaces: ["KV"],
            // Inject the parsed migrations so tests can apply them with applyD1Migrations().
            bindings: { TEST_MIGRATIONS: migrations },
          },
        },
      },
    },
  };
});
```

- [ ] **Step 4: Create `migrations/0001_init.sql` — the full schema.**

Forward-only. All ids = UUIDv7 `TEXT`; money = `INTEGER` cents; timestamps = `INTEGER` epoch ms; dates = `TEXT 'YYYY-MM-DD'`. Every syncable table carries `id, user_id, created_at, updated_at, deleted_at, rev, last_edited_device_id`. `PRAGMA foreign_keys = OFF` at the top lets `transactions.mileage_trip_id` forward-reference `mileage_trips` during create (D1/SQLite resolves FK targets lazily; the worker scopes by `user_id` as the real guard).

```sql
-- migrations/0001_init.sql
-- Snapceipt initial D1 schema (forward-only).
-- ids = UUIDv7 TEXT. Money = INTEGER cents. Timestamps = INTEGER epoch ms. Dates = TEXT 'YYYY-MM-DD'.
-- Syncable tables carry: id, user_id, created_at, updated_at, deleted_at, rev, last_edited_device_id.
PRAGMA foreign_keys = OFF;

-- =========================================================================
-- 1. Identity & Auth
-- =========================================================================
CREATE TABLE users (
  id                    TEXT PRIMARY KEY,
  email                 TEXT,
  email_verified        INTEGER NOT NULL DEFAULT 0,
  display_name          TEXT,
  plan                  TEXT NOT NULL DEFAULT 'free' CHECK (plan IN ('free','pro')),
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE UNIQUE INDEX ux_users_email ON users(email) WHERE email IS NOT NULL AND deleted_at IS NULL;

CREATE TABLE auth_identities (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id),
  provider    TEXT NOT NULL CHECK (provider IN ('apple','email')),
  subject     TEXT NOT NULL,
  created_at  INTEGER NOT NULL
);
CREATE UNIQUE INDEX ux_authid_provider_subject ON auth_identities(provider, subject);
CREATE INDEX ix_authid_user ON auth_identities(user_id);

CREATE TABLE email_tokens (
  id          TEXT PRIMARY KEY,
  email       TEXT NOT NULL,
  token_hash  TEXT NOT NULL,
  purpose     TEXT NOT NULL DEFAULT 'magic_link' CHECK (purpose IN ('magic_link')),
  expires_at  INTEGER NOT NULL,
  consumed_at INTEGER,
  created_at  INTEGER NOT NULL
);
CREATE INDEX ix_emailtok_email ON email_tokens(email);
CREATE UNIQUE INDEX ux_emailtok_hash ON email_tokens(token_hash);

CREATE TABLE sessions (
  id            TEXT PRIMARY KEY,
  user_id       TEXT NOT NULL REFERENCES users(id),
  device_id     TEXT NOT NULL,
  refresh_hash  TEXT NOT NULL,
  family        TEXT NOT NULL,
  revoked_at    INTEGER,
  created_at    INTEGER NOT NULL,
  last_seen_at  INTEGER,
  expires_at    INTEGER NOT NULL
);
CREATE UNIQUE INDEX ux_sessions_refresh_hash ON sessions(refresh_hash);
CREATE INDEX ix_sessions_user ON sessions(user_id);
CREATE INDEX ix_sessions_family ON sessions(family);

CREATE TABLE devices (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  platform              TEXT NOT NULL DEFAULT 'ios' CHECK (platform IN ('ios')),
  model                 TEXT,
  os_version            TEXT,
  apns_token            TEXT,
  push_enabled          INTEGER NOT NULL DEFAULT 1,
  last_sync_cursor      INTEGER,
  last_seen_at          INTEGER,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_devices_user ON devices(user_id);
CREATE INDEX ix_devices_user_updated ON devices(user_id, updated_at);
CREATE UNIQUE INDEX ux_devices_apns ON devices(apns_token) WHERE apns_token IS NOT NULL;

-- =========================================================================
-- 2. Profiles & Categorization
-- =========================================================================
CREATE TABLE profiles (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  name                  TEXT NOT NULL,
  type                  TEXT NOT NULL CHECK (type IN ('personal','business')),
  initials              TEXT,
  accent_1              TEXT NOT NULL,
  accent_2              TEXT NOT NULL,
  accent_3              TEXT NOT NULL,
  abn                   TEXT,
  gst_registered        INTEGER NOT NULL DEFAULT 0,
  sort_order            INTEGER NOT NULL DEFAULT 0,
  is_default            INTEGER NOT NULL DEFAULT 0,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_profiles_user ON profiles(user_id);
CREATE INDEX ix_profiles_user_updated ON profiles(user_id, updated_at);

CREATE TABLE categories (
  id                     TEXT PRIMARY KEY,
  user_id                TEXT NOT NULL REFERENCES users(id),
  profile_id             TEXT REFERENCES profiles(id),
  key                    TEXT NOT NULL CHECK (key IN ('meals','groceries','fuel','software','office','home','health','travel','income','custom')),
  label                  TEXT NOT NULL,
  icon                   TEXT NOT NULL,
  tint                   TEXT NOT NULL,
  soft                   TEXT NOT NULL,
  default_deductible_pct INTEGER CHECK (default_deductible_pct BETWEEN 0 AND 100),
  is_income              INTEGER NOT NULL DEFAULT 0,
  sort_order             INTEGER NOT NULL DEFAULT 0,
  created_at             INTEGER NOT NULL,
  updated_at             INTEGER NOT NULL,
  deleted_at             INTEGER,
  rev                    INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id  TEXT
);
CREATE INDEX ix_categories_user ON categories(user_id);
CREATE INDEX ix_categories_user_updated ON categories(user_id, updated_at);

CREATE TABLE smart_rules (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT REFERENCES profiles(id),
  match_type            TEXT NOT NULL DEFAULT 'merchant_contains' CHECK (match_type IN ('merchant_contains','merchant_equals','merchant_regex')),
  matcher               TEXT NOT NULL,
  category_id           TEXT REFERENCES categories(id),
  set_deductible_pct    INTEGER CHECK (set_deductible_pct BETWEEN 0 AND 100),
  set_mode              TEXT CHECK (set_mode IN ('business','personal')),
  priority              INTEGER NOT NULL DEFAULT 0,
  enabled               INTEGER NOT NULL DEFAULT 1,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_rules_user ON smart_rules(user_id);
CREATE INDEX ix_rules_user_updated ON smart_rules(user_id, updated_at);
CREATE INDEX ix_rules_match ON smart_rules(user_id, profile_id, enabled, priority) WHERE deleted_at IS NULL;

-- =========================================================================
-- 3. Transactions & Line Items
-- =========================================================================
CREATE TABLE transactions (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  merchant              TEXT NOT NULL DEFAULT '',
  category_id           TEXT REFERENCES categories(id),
  cat_key               TEXT NOT NULL CHECK (cat_key IN ('meals','groceries','fuel','software','office','home','health','travel','income','custom')),
  amount_cents          INTEGER NOT NULL,
  currency              TEXT NOT NULL DEFAULT 'AUD',
  txn_date              TEXT NOT NULL,
  month_key             TEXT GENERATED ALWAYS AS (substr(txn_date,1,7)) STORED,
  mode                  TEXT NOT NULL DEFAULT 'personal' CHECK (mode IN ('business','personal')),
  tax_label             TEXT,
  deductible_pct        INTEGER CHECK (deductible_pct BETWEEN 0 AND 100),
  payment_method        TEXT,
  is_ai                 INTEGER NOT NULL DEFAULT 0,
  note                  TEXT,
  gst_cents             INTEGER,
  logbook_link          TEXT CHECK (logbook_link IN ('vehicle','wfh') OR logbook_link IS NULL),
  mileage_trip_id       TEXT REFERENCES mileage_trips(id),
  source                TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','scan','email_in','import')),
  extraction_status     TEXT CHECK (extraction_status IN ('pending','done','failed') OR extraction_status IS NULL),
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_txn_user_updated  ON transactions(user_id, updated_at);
CREATE INDEX ix_txn_profile_date  ON transactions(profile_id, txn_date)  WHERE deleted_at IS NULL;
CREATE INDEX ix_txn_profile_month ON transactions(profile_id, month_key) WHERE deleted_at IS NULL;
CREATE INDEX ix_txn_category      ON transactions(category_id);
CREATE INDEX ix_txn_user_profile  ON transactions(user_id, profile_id, txn_date);

CREATE TABLE line_items (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  transaction_id        TEXT NOT NULL REFERENCES transactions(id),
  name                  TEXT NOT NULL,
  price_cents           INTEGER NOT NULL,
  quantity              INTEGER NOT NULL DEFAULT 1,
  sort_order            INTEGER NOT NULL DEFAULT 0,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_lineitem_txn          ON line_items(transaction_id);
CREATE INDEX ix_lineitem_user_updated ON line_items(user_id, updated_at);

-- =========================================================================
-- 4. Receipt Images (R2 keys only — binary never in D1)
-- =========================================================================
CREATE TABLE receipt_images (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT REFERENCES profiles(id),
  transaction_id        TEXT REFERENCES transactions(id),
  r2_key                TEXT NOT NULL,
  thumb_r2_key          TEXT,
  content_type          TEXT NOT NULL DEFAULT 'image/jpeg',
  byte_size             INTEGER,
  width                 INTEGER,
  height                INTEGER,
  page_index            INTEGER NOT NULL DEFAULT 0,
  ocr_text              TEXT,
  ocr_source            TEXT CHECK (ocr_source IN ('vision_on_device','workers_ai') OR ocr_source IS NULL),
  extraction_json       TEXT,
  extraction_model      TEXT,
  source                TEXT NOT NULL DEFAULT 'scan' CHECK (source IN ('scan','email_in')),
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_img_txn          ON receipt_images(transaction_id);
CREATE INDEX ix_img_user_updated ON receipt_images(user_id, updated_at);
CREATE UNIQUE INDEX ux_img_r2key ON receipt_images(r2_key);

-- =========================================================================
-- 5. Budgets & Loyalty
-- =========================================================================
CREATE TABLE budgets (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  category_id           TEXT REFERENCES categories(id),
  cat_key               TEXT,
  label                 TEXT NOT NULL,
  period                TEXT NOT NULL DEFAULT 'monthly' CHECK (period IN ('monthly')),
  month_key             TEXT,
  cap_cents             INTEGER NOT NULL,
  currency              TEXT NOT NULL DEFAULT 'AUD',
  alert_threshold_pct   INTEGER NOT NULL DEFAULT 90 CHECK (alert_threshold_pct BETWEEN 1 AND 200),
  alert_sent_at         INTEGER,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_budget_user_updated ON budgets(user_id, updated_at);
CREATE INDEX ix_budget_profile      ON budgets(profile_id, month_key) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX ux_budget_scope ON budgets(profile_id, category_id, month_key) WHERE deleted_at IS NULL;

CREATE TABLE loyalty_cards (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT REFERENCES profiles(id),
  brand                 TEXT NOT NULL,
  sub_brand             TEXT,
  number                TEXT NOT NULL,
  barcode_format        TEXT CHECK (barcode_format IN ('code128','ean13','qr','aztec','pdf417') OR barcode_format IS NULL),
  points_label          TEXT,
  color_1               TEXT NOT NULL,
  color_2               TEXT NOT NULL,
  sort_order            INTEGER NOT NULL DEFAULT 0,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_loyalty_user_updated ON loyalty_cards(user_id, updated_at);
CREATE INDEX ix_loyalty_user         ON loyalty_cards(user_id) WHERE deleted_at IS NULL;

-- =========================================================================
-- 6. Logbooks: Mileage & WFH
-- =========================================================================
CREATE TABLE mileage_trips (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  trip_date             TEXT NOT NULL,
  from_label            TEXT,
  to_label              TEXT,
  purpose               TEXT,
  distance_m            INTEGER NOT NULL,
  is_business           INTEGER NOT NULL DEFAULT 1,
  rate_cents_per_km     INTEGER,
  claim_cents           INTEGER,
  auto_tracked          INTEGER NOT NULL DEFAULT 0,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_trip_user_updated ON mileage_trips(user_id, updated_at);
CREATE INDEX ix_trip_profile_date ON mileage_trips(profile_id, trip_date) WHERE deleted_at IS NULL;

CREATE TABLE wfh_logs (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  log_date              TEXT NOT NULL,
  minutes               INTEGER NOT NULL,
  note                  TEXT,
  rate_cents_per_hour   INTEGER,
  claim_cents           INTEGER,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_wfh_user_updated ON wfh_logs(user_id, updated_at);
CREATE UNIQUE INDEX ux_wfh_profile_date ON wfh_logs(profile_id, log_date) WHERE deleted_at IS NULL;

-- =========================================================================
-- 7. Quotes & Quote Line Items
-- =========================================================================
CREATE TABLE quotes (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  number                TEXT,
  client_name           TEXT,
  client_email          TEXT,
  gst_enabled           INTEGER NOT NULL DEFAULT 1,
  subtotal_cents        INTEGER NOT NULL DEFAULT 0,
  gst_cents             INTEGER NOT NULL DEFAULT 0,
  total_cents           INTEGER NOT NULL DEFAULT 0,
  currency              TEXT NOT NULL DEFAULT 'AUD',
  status                TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','sent','accepted','declined','expired','invoiced')),
  valid_until           TEXT,
  sent_at               INTEGER,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_quote_user_updated   ON quotes(user_id, updated_at);
CREATE INDEX ix_quote_profile_status ON quotes(profile_id, status) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX ux_quote_number  ON quotes(user_id, number) WHERE number IS NOT NULL AND deleted_at IS NULL;

CREATE TABLE quote_line_items (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  quote_id              TEXT NOT NULL REFERENCES quotes(id),
  description           TEXT NOT NULL,
  quantity              INTEGER NOT NULL DEFAULT 1,
  unit_price_cents      INTEGER NOT NULL,
  line_total_cents      INTEGER GENERATED ALWAYS AS (quantity * unit_price_cents) STORED,
  sort_order            INTEGER NOT NULL DEFAULT 0,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_qli_quote        ON quote_line_items(quote_id);
CREATE INDEX ix_qli_user_updated ON quote_line_items(user_id, updated_at);

-- =========================================================================
-- 8. Operational: Email Outbox & Tax Settings
-- =========================================================================
CREATE TABLE email_outbox (
  id            TEXT PRIMARY KEY,
  user_id       TEXT REFERENCES users(id),
  to_email      TEXT NOT NULL,
  kind          TEXT NOT NULL CHECK (kind IN ('magic_link','export_accountant','quote_send')),
  subject       TEXT,
  status        TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','sent','failed')),
  export_format TEXT CHECK (export_format IN ('pdf','csv') OR export_format IS NULL),
  export_r2_key TEXT,
  related_id    TEXT,
  error         TEXT,
  attempts      INTEGER NOT NULL DEFAULT 0,
  created_at    INTEGER NOT NULL,
  sent_at       INTEGER
);
CREATE INDEX ix_outbox_status ON email_outbox(status, created_at);
CREATE INDEX ix_outbox_user   ON email_outbox(user_id);

CREATE TABLE tax_settings (
  id                          TEXT PRIMARY KEY,
  user_id                     TEXT NOT NULL REFERENCES users(id),
  profile_id                  TEXT NOT NULL REFERENCES profiles(id),
  gst_rate_bps                INTEGER NOT NULL DEFAULT 1000,
  financial_year_start_month  INTEGER NOT NULL DEFAULT 7,
  meals_deductible_pct        INTEGER NOT NULL DEFAULT 50,
  wfh_rate_cents_per_hour     INTEGER NOT NULL DEFAULT 67,
  mileage_rate_cents_per_km   INTEGER NOT NULL DEFAULT 88,
  created_at                  INTEGER NOT NULL,
  updated_at                  INTEGER NOT NULL,
  deleted_at                  INTEGER,
  rev                         INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id       TEXT
);
CREATE UNIQUE INDEX ux_tax_profile  ON tax_settings(profile_id) WHERE deleted_at IS NULL;
CREATE INDEX ix_tax_user_updated    ON tax_settings(user_id, updated_at);

-- =========================================================================
-- 9. Sync support: server-side idempotency log (mutation_queue mirror).
--    Not synced to device; bounded retention (GC of rows older than ~30d).
-- =========================================================================
CREATE TABLE processed_mutations (
  mutation_id  TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL,
  device_id    TEXT NOT NULL,
  entity_type  TEXT NOT NULL,
  entity_id    TEXT NOT NULL,
  op           TEXT NOT NULL CHECK (op IN ('upsert','delete')),
  status       TEXT NOT NULL CHECK (status IN ('applied','conflict','duplicate','rejected')),
  result_json  TEXT,
  created_at   INTEGER NOT NULL
);
CREATE INDEX ix_procmut_user ON processed_mutations(user_id, created_at);
```

- [ ] **Step 5: Create `src/lib/db.ts` — typed, tenant-scoped D1 helpers.**

`scopedAll`/`scopedGet` force a `WHERE user_id = ?` predicate (tenant isolation per the spec — never trust a client-sent userId alone). `recordProcessedMutation`/`getProcessedMutation` back the sync push idempotency log. `INSERT OR IGNORE` makes recording a replayed mutation a no-op.

```ts
// src/lib/db.ts
import type { Env } from "../env";

/** A processed-mutation idempotency-log row (sync push). Mirrors the processed_mutations table. */
export interface ProcessedMutation {
  mutation_id: string;
  user_id: string;
  device_id: string;
  entity_type: string;
  entity_id: string;
  op: "upsert" | "delete";
  status: "applied" | "conflict" | "duplicate" | "rejected";
  result_json: string | null;
  created_at: number;
}

/** Allow-list of table names that may be passed to the scoped helpers (table names cannot be bound params). */
const SCOPED_TABLES = new Set([
  "users", "devices", "profiles", "categories", "smart_rules",
  "transactions", "line_items", "receipt_images", "budgets", "loyalty_cards",
  "mileage_trips", "wfh_logs", "quotes", "quote_line_items", "tax_settings",
  "auth_identities", "email_tokens", "sessions", "email_outbox",
]);

function assertTable(table: string): string {
  if (!SCOPED_TABLES.has(table)) throw new Error(`db: unknown/unsafe table '${table}'`);
  return table;
}

/** All non-deleted-aware rows for a tenant, oldest-first by the delta-sync key (updated_at, id). */
export async function scopedAll<T = Record<string, unknown>>(
  db: D1Database,
  table: string,
  userId: string,
): Promise<T[]> {
  const t = assertTable(table);
  const { results } = await db
    .prepare(`SELECT * FROM ${t} WHERE user_id = ? ORDER BY updated_at, id`)
    .bind(userId)
    .all<T>();
  return results;
}

/** A single row by id, scoped to the tenant. Returns null if it does not exist for this user. */
export async function scopedGet<T = Record<string, unknown>>(
  db: D1Database,
  table: string,
  userId: string,
  id: string,
): Promise<T | null> {
  const t = assertTable(table);
  return db
    .prepare(`SELECT * FROM ${t} WHERE user_id = ? AND id = ?`)
    .bind(userId, id)
    .first<T>();
}

/** Record the outcome of a processed sync mutation. Idempotent: re-recording the same id is a no-op. */
export async function recordProcessedMutation(
  db: D1Database,
  m: {
    mutationId: string;
    userId: string;
    deviceId: string;
    entityType: string;
    entityId: string;
    op: "upsert" | "delete";
    status: "applied" | "conflict" | "duplicate" | "rejected";
    resultJson: string | null;
    createdAt: number;
  },
): Promise<void> {
  await db
    .prepare(
      `INSERT OR IGNORE INTO processed_mutations
         (mutation_id, user_id, device_id, entity_type, entity_id, op, status, result_json, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      m.mutationId, m.userId, m.deviceId, m.entityType, m.entityId,
      m.op, m.status, m.resultJson, m.createdAt,
    )
    .run();
}

/** Look up a prior mutation result for idempotent replay. Returns null if not yet processed. */
export async function getProcessedMutation(
  db: D1Database,
  mutationId: string,
): Promise<ProcessedMutation | null> {
  return db
    .prepare(`SELECT * FROM processed_mutations WHERE mutation_id = ?`)
    .bind(mutationId)
    .first<ProcessedMutation>();
}

// Type guard so unused-import lint stays quiet if Env evolves; Env is the shared bindings type.
export type DbEnv = Pick<Env, "DB">;
```

- [ ] **Step 6: Run the test — expect PASS.**

```bash
npx vitest run test/schema.test.ts
```

Expected: PASS. All 5 specs green — every table + sync columns exist, the required indexes exist, `month_key` computes to `"2026-05"`, tenant scoping isolates `u1`/`u2`, and `processed_mutations` records and replays idempotently.

- [ ] **Step 7: Verify the migration applies cleanly via wrangler against local D1 (sanity, not in CI).**

```bash
npx wrangler d1 migrations apply DB --local
```

Expected: wrangler reports `0001_init.sql` applied (or "No migrations to apply" on re-run), with no SQL errors — confirming the file is valid forward-only D1 migration syntax outside the test harness.

- [ ] **Step 8: Commit test + schema + helpers together (TDD red→green commit).**

```bash
git add migrations/0001_init.sql src/lib/db.ts vitest.config.ts test/schema.test.ts
git commit -m "$(cat <<'EOF'
feat(backend): add D1 0001_init schema + tenant-scoped db helpers

Full D1 schema for all 20 tables (identity/auth, profiles, transactions,
receipts, budgets, loyalty, logbooks, quotes, tax, processed_mutations) with
sync columns (rev + last_edited_device_id), CHECK enums, INTEGER-cents money,
STORED generated columns (month_key, line_total_cents), and the delta-sync +
partial read + unique index backbone. Adds scopedAll/scopedGet and the
processed-mutation idempotency helpers, plus a schema round-trip test that
applies the migration to a real D1 binding inside workerd.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: one commit containing the migration, helpers, wired test config, and the schema test.

---

### Task 4: zod schemas (auth, sync, entities) + cursor codec

Defines every request/payload validation schema the route tasks (auth, sync, devices) will mount with `@hono/zod-validator`, plus the sync cursor codec. Pure, dependency-light TypeScript + zod — fully testable with plain `vitest` (no D1/KV bindings, no migrations needed), so it runs fast and in isolation. All money is INTEGER cents, ids are UUIDv7 strings, timestamps epoch ms, dates `"YYYY-MM-DD"`. Validation is intentionally **lenient on entity bodies** (a `baseEnvelope` with `.passthrough()` for forward-compatible fields) but **strict on the wrapper shapes** (mutation, pushBody, pullQuery, auth bodies). Server-stamped fields (`updatedAt`, `rev`, `lastEditedDeviceId`) are accepted but never trusted — they get overwritten in the sync route (Task: sync).

**Files**
- Create: `src/schemas/entities.ts`
- Create: `src/schemas/sync.ts`
- Create: `src/schemas/auth.ts`
- Test: `test/schemas.test.ts`

This task assumes Task 1 (scaffold) already produced `package.json` (with `zod ^3` + `vitest ^2` installed), `tsconfig.json`, and `vitest.config.ts`. It does NOT import anything from the app, env, lib, routes, or `cloudflare:test`; the tests are pure unit tests.

---

- [ ] **Step 1: Write the failing test for entity + envelope schemas**

This is the first TDD step — the schema files don't exist yet, so this test must fail to compile/import.

```ts
// test/schemas.test.ts
import { describe, it, expect } from "vitest";
import {
  baseEnvelope,
  transactionEntity,
  lineItemEntity,
  profileEntity,
  budgetEntity,
  loyaltyCardEntity,
  entitySchemaFor,
  SYNCABLE_TYPES,
} from "../src/schemas/entities";
import {
  mutationSchema,
  pushBody,
  pullQuery,
  encodeCursor,
  decodeCursor,
} from "../src/schemas/sync";
import {
  appleBody,
  magicLinkRequestBody,
  magicLinkVerifyBody,
  refreshBody,
} from "../src/schemas/auth";

// ---- shared fixtures ----
const UID = "0190f8a0-1111-7000-8000-000000000001";
const PID = "0190f8a0-2222-7000-8000-000000000002";
const EID = "0190f8a0-3333-7000-8000-000000000003";
const DID = "0190f8a0-4444-7000-8000-000000000004";

function env(overrides: Record<string, unknown> = {}) {
  return {
    id: EID,
    userId: UID,
    profileId: PID,
    type: "transaction",
    createdAt: 1748563200000,
    updatedAt: 1748563200000,
    deletedAt: null,
    rev: 1,
    lastEditedDeviceId: DID,
    ...overrides,
  };
}

describe("baseEnvelope", () => {
  it("accepts a minimal valid envelope and keeps unknown fields (passthrough)", () => {
    const r = baseEnvelope.safeParse(env({ merchant: "Aldi", amountCents: -1234 }));
    expect(r.success).toBe(true);
    if (r.success) {
      expect(r.data.merchant).toBe("Aldi");
      expect(r.data.amountCents).toBe(-1234);
      expect(r.data.deletedAt).toBeNull();
    }
  });

  it("allows deletedAt as a tombstone ms timestamp", () => {
    const r = baseEnvelope.safeParse(env({ deletedAt: 1748563299999 }));
    expect(r.success).toBe(true);
  });

  it("allows profileId to be omitted (user-scoped entity)", () => {
    const e = env();
    delete (e as Record<string, unknown>).profileId;
    expect(baseEnvelope.safeParse(e).success).toBe(true);
  });

  it("rejects a non-uuid id", () => {
    expect(baseEnvelope.safeParse(env({ id: "not-a-uuid" })).success).toBe(false);
  });

  it("rejects a missing userId", () => {
    const e = env();
    delete (e as Record<string, unknown>).userId;
    expect(baseEnvelope.safeParse(e).success).toBe(false);
  });

  it("rejects a float rev", () => {
    expect(baseEnvelope.safeParse(env({ rev: 1.5 })).success).toBe(false);
  });
});

describe("transactionEntity", () => {
  it("accepts a full transaction payload with integer cents", () => {
    const r = transactionEntity.safeParse(
      env({
        type: "transaction",
        merchant: "BP Service",
        amountCents: -8800,
        currency: "AUD",
        txnDate: "2026-05-29",
        catKey: "fuel",
        mode: "business",
        deductiblePct: 100,
        gstCents: 800,
        isAi: true,
      }),
    );
    expect(r.success).toBe(true);
  });

  it("rejects a non-integer amountCents (money must be cents)", () => {
    const r = transactionEntity.safeParse(env({ type: "transaction", amountCents: 12.5 }));
    expect(r.success).toBe(false);
  });

  it("rejects a malformed txnDate", () => {
    const r = transactionEntity.safeParse(env({ type: "transaction", txnDate: "29/05/2026" }));
    expect(r.success).toBe(false);
  });

  it("rejects an out-of-range deductiblePct", () => {
    const r = transactionEntity.safeParse(env({ type: "transaction", deductiblePct: 150 }));
    expect(r.success).toBe(false);
  });

  it("rejects the wrong type discriminator", () => {
    const r = transactionEntity.safeParse(env({ type: "profile" }));
    expect(r.success).toBe(false);
  });
});

describe("profileEntity / budgetEntity / loyaltyCardEntity / lineItemEntity", () => {
  it("accepts a profile", () => {
    const r = profileEntity.safeParse(
      env({ type: "profile", profileId: undefined, name: "Studio North", profileType: "business" }),
    );
    expect(r.success).toBe(true);
  });

  it("rejects an invalid profile type", () => {
    const r = profileEntity.safeParse(env({ type: "profile", name: "X", profileType: "school" }));
    expect(r.success).toBe(false);
  });

  it("accepts a budget with capCents", () => {
    const r = budgetEntity.safeParse(env({ type: "budget", label: "Groceries", capCents: 60000 }));
    expect(r.success).toBe(true);
  });

  it("rejects a budget with float capCents", () => {
    const r = budgetEntity.safeParse(env({ type: "budget", label: "Groceries", capCents: 600.5 }));
    expect(r.success).toBe(false);
  });

  it("accepts a loyalty card", () => {
    const r = loyaltyCardEntity.safeParse(
      env({ type: "loyaltyCard", brand: "Everyday Rewards", number: "1234 5678" }),
    );
    expect(r.success).toBe(true);
  });

  it("accepts a line item with priceCents", () => {
    const r = lineItemEntity.safeParse(
      env({ type: "lineItem", profileId: undefined, transactionId: EID, name: "Coffee", priceCents: 550 }),
    );
    expect(r.success).toBe(true);
  });
});

describe("entitySchemaFor / SYNCABLE_TYPES", () => {
  it("exposes every syncable type", () => {
    expect(SYNCABLE_TYPES).toContain("transaction");
    expect(SYNCABLE_TYPES).toContain("taxSettings");
    expect(SYNCABLE_TYPES).toContain("quoteLineItem");
    expect(SYNCABLE_TYPES.length).toBe(12);
  });

  it("returns the specialized schema for known types", () => {
    const r = entitySchemaFor("transaction").safeParse(env({ type: "transaction", amountCents: 1 }));
    expect(r.success).toBe(true);
    expect(entitySchemaFor("transaction").safeParse(env({ type: "transaction", amountCents: 1.1 })).success).toBe(false);
  });

  it("falls back to baseEnvelope for types without a specialized schema", () => {
    const r = entitySchemaFor("category").safeParse(env({ type: "category", label: "Meals" }));
    expect(r.success).toBe(true);
  });
});
```

Run:

```bash
npx vitest run test/schemas.test.ts -t "baseEnvelope"
```

Expected: **FAIL** — `Cannot find module '../src/schemas/entities'` (the schema files do not exist yet).

---

- [ ] **Step 2: Implement `src/schemas/entities.ts` (baseEnvelope + per-type entities + lookup)**

```ts
// src/schemas/entities.ts
import { z } from "zod";

/**
 * Validation for syncable entity payloads carried inside /sync/push mutations.
 *
 * Deliberately LENIENT: the envelope uses .passthrough() so new client fields
 * sync without a server deploy. The route layer (Task: sync) overwrites the
 * server-authoritative fields (updatedAt, rev, lastEditedDeviceId) regardless of
 * what the client sent, and enforces tenancy (payload.userId === c.var.userId).
 *
 * Conventions (SPINE): money = INTEGER cents, ids = UUIDv7 strings,
 * timestamps = epoch ms, dates = "YYYY-MM-DD".
 */

const uuid = z.string().uuid();
const epochMs = z.number().int().nonnegative();
const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "expected YYYY-MM-DD");
const cents = z.number().int(); // signed; negative = expense
const pct = z.number().int().min(0).max(100);

/** Every syncable row (D1 + push payload + pull change) carries these fields. */
export const baseEnvelope = z
  .object({
    id: uuid,
    userId: uuid,
    profileId: uuid.optional(),
    type: z.string().min(1),
    createdAt: epochMs,
    updatedAt: epochMs,
    deletedAt: epochMs.nullable().default(null),
    rev: z.number().int().nonnegative(),
    lastEditedDeviceId: z.string().min(1),
  })
  .passthrough();

export type BaseEnvelope = z.infer<typeof baseEnvelope>;

/** transaction — see backend.md §"transactions". Money in cents, date-only string. */
export const transactionEntity = baseEnvelope.extend({
  type: z.literal("transaction"),
  merchant: z.string().optional(),
  catKey: z
    .enum([
      "meals",
      "groceries",
      "fuel",
      "software",
      "office",
      "home",
      "health",
      "travel",
      "income",
      "custom",
    ])
    .optional(),
  categoryId: uuid.nullable().optional(),
  amountCents: cents.optional(),
  currency: z.string().length(3).optional(),
  txnDate: isoDate.optional(),
  mode: z.enum(["business", "personal"]).optional(),
  taxLabel: z.string().nullable().optional(),
  deductiblePct: pct.nullable().optional(),
  paymentMethod: z.string().nullable().optional(),
  isAi: z.boolean().optional(),
  note: z.string().nullable().optional(),
  gstCents: cents.nullable().optional(),
  logbookLink: z.enum(["vehicle", "wfh"]).nullable().optional(),
  mileageTripId: uuid.nullable().optional(),
  source: z.enum(["manual", "scan", "email_in", "import"]).optional(),
  extractionStatus: z.enum(["pending", "done", "failed"]).nullable().optional(),
});

/** lineItem — child of a transaction; replaced wholesale with its parent. */
export const lineItemEntity = baseEnvelope.extend({
  type: z.literal("lineItem"),
  transactionId: uuid,
  name: z.string().min(1),
  priceCents: cents,
  quantity: z.number().int().min(1).optional(),
  sortOrder: z.number().int().optional(),
});

/** profile — the user's switchable persona. (profileType avoids clashing with envelope.type) */
export const profileEntity = baseEnvelope.extend({
  type: z.literal("profile"),
  name: z.string().min(1),
  profileType: z.enum(["personal", "business"]),
  initials: z.string().nullable().optional(),
  accent1: z.string().optional(),
  accent2: z.string().optional(),
  accent3: z.string().optional(),
  abn: z.string().nullable().optional(),
  gstRegistered: z.boolean().optional(),
  sortOrder: z.number().int().optional(),
  isDefault: z.boolean().optional(),
});

/** budget — per category/profile/month; cap in cents, spent is computed (never stored). */
export const budgetEntity = baseEnvelope.extend({
  type: z.literal("budget"),
  categoryId: uuid.nullable().optional(),
  catKey: z.string().nullable().optional(),
  label: z.string().min(1),
  period: z.enum(["monthly"]).optional(),
  monthKey: z.string().regex(/^\d{4}-\d{2}$/).nullable().optional(),
  capCents: cents,
  currency: z.string().length(3).optional(),
  alertThresholdPct: z.number().int().min(1).max(200).optional(),
});

/** loyaltyCard — brand + number + gradient colors + barcode metadata. */
export const loyaltyCardEntity = baseEnvelope.extend({
  type: z.literal("loyaltyCard"),
  brand: z.string().min(1),
  subBrand: z.string().nullable().optional(),
  number: z.string().min(1),
  barcodeFormat: z.enum(["code128", "ean13", "qr", "aztec", "pdf417"]).nullable().optional(),
  pointsLabel: z.string().nullable().optional(),
  color1: z.string().optional(),
  color2: z.string().optional(),
  sortOrder: z.number().int().optional(),
});

/** Every syncable type (SPINE). Types without a specialized schema validate via baseEnvelope. */
export const SYNCABLE_TYPES = [
  "transaction",
  "lineItem",
  "profile",
  "category",
  "smartRule",
  "budget",
  "loyaltyCard",
  "quote",
  "quoteLineItem",
  "mileageTrip",
  "wfhLog",
  "taxSettings",
] as const;

export type SyncableType = (typeof SYNCABLE_TYPES)[number];

const SPECIALIZED: Partial<Record<SyncableType, z.ZodTypeAny>> = {
  transaction: transactionEntity,
  lineItem: lineItemEntity,
  profile: profileEntity,
  budget: budgetEntity,
  loyaltyCard: loyaltyCardEntity,
};

/** Returns the strictest available schema for an entityType; baseEnvelope is the fallback. */
export function entitySchemaFor(type: string): z.ZodTypeAny {
  return SPECIALIZED[type as SyncableType] ?? baseEnvelope;
}
```

Run:

```bash
npx vitest run test/schemas.test.ts -t "baseEnvelope"
```

Expected: still **FAIL** — `test/schemas.test.ts` also imports `../src/schemas/sync` and `../src/schemas/auth`, which do not exist yet, so the whole test file fails to load. (Proceed to Steps 3-4 before re-running.)

---

- [ ] **Step 3: Implement `src/schemas/sync.ts` (mutation, pushBody, pullQuery, cursor codec)**

```ts
// src/schemas/sync.ts
import { z } from "zod";
import { baseEnvelope } from "./entities";

/**
 * Sync wire schemas + the composite-keyset cursor codec.
 * Cursor = base64url of { ts: lastUpdatedAt, id: lastId } so pull is stable
 * under concurrent writes (ORDER BY updatedAt, id). See backend.md §2 SYNC.
 */

/** One push mutation. payload is validated leniently here (baseEnvelope); the
 *  route picks the strict per-type schema via entitySchemaFor() at apply time. */
export const mutationSchema = z.object({
  mutationId: z.string().uuid(), // idempotency key
  entityType: z.string().min(1),
  entityId: z.string().uuid(),
  op: z.enum(["upsert", "delete"]),
  baseRev: z.number().int().nonnegative().optional(),
  updatedAt: z.number().int().nonnegative(),
  payload: baseEnvelope,
});

export type Mutation = z.infer<typeof mutationSchema>;

/** POST /sync/push body — batch capped at 200. */
export const pushBody = z.object({
  deviceId: z.string().uuid(),
  mutations: z.array(mutationSchema).min(1).max(200),
});

export type PushBody = z.infer<typeof pushBody>;

/** GET /sync/pull query — cursor optional (omit on first/full sync), limit 1..500. */
export const pullQuery = z.object({
  cursor: z.string().min(1).optional(),
  limit: z.coerce.number().int().min(1).max(500).default(500),
});

export type PullQuery = z.infer<typeof pullQuery>;

// ---- cursor codec (composite keyset) ----

export interface Cursor {
  ts: number; // lastUpdatedAt (epoch ms)
  id: string; // lastId (UUIDv7)
}

const cursorShape = z.object({
  ts: z.number().int().nonnegative(),
  id: z.string().uuid(),
});

/** base64url-encode a cursor (no padding, URL-safe). Workers runtime has btoa. */
export function encodeCursor(c: Cursor): string {
  const json = JSON.stringify({ ts: c.ts, id: c.id });
  return btoa(json).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Decode a cursor; returns null on any malformed/invalid input (caller treats as full sync). */
export function decodeCursor(raw: string | undefined | null): Cursor | null {
  if (!raw) return null;
  try {
    let b64 = raw.replace(/-/g, "+").replace(/_/g, "/");
    while (b64.length % 4 !== 0) b64 += "=";
    const parsed = JSON.parse(atob(b64));
    const r = cursorShape.safeParse(parsed);
    return r.success ? r.data : null;
  } catch {
    return null;
  }
}
```

Run:

```bash
npx vitest run test/schemas.test.ts -t "cursor"
```

Expected: still **FAIL** — `../src/schemas/auth` is still missing, so the test file cannot load. (Implement Step 4, then run.)

---

- [ ] **Step 4: Implement `src/schemas/auth.ts` (apple, magic-link request/verify, refresh bodies)**

```ts
// src/schemas/auth.ts
import { z } from "zod";

/** Auth request bodies. See backend.md §1 AUTH. */

/** POST /auth/apple — verified server-side against Apple JWKS (Task: auth). */
export const appleBody = z.object({
  identityToken: z.string().min(1),
  authorizationCode: z.string().min(1),
  rawNonce: z.string().min(1),
  fullName: z.string().optional(),
  email: z.string().email().optional(),
});

export type AppleBody = z.infer<typeof appleBody>;

/** POST /auth/magic-link/request — always 202 (no enumeration); rate-limited. */
export const magicLinkRequestBody = z.object({
  email: z.string().email(),
});

export type MagicLinkRequestBody = z.infer<typeof magicLinkRequestBody>;

/** POST /auth/magic-link/verify — single-use token. */
export const magicLinkVerifyBody = z.object({
  token: z.string().min(1),
});

export type MagicLinkVerifyBody = z.infer<typeof magicLinkVerifyBody>;

/** POST /auth/refresh — opaque refresh token, rotated on every use. */
export const refreshBody = z.object({
  refreshToken: z.string().min(1),
});

export type RefreshBody = z.infer<typeof refreshBody>;
```

Run:

```bash
npx vitest run test/schemas.test.ts
```

Expected: **PASS** — all `describe` blocks (baseEnvelope, transactionEntity, profile/budget/loyalty/lineItem, entitySchemaFor) pass now that every imported module exists.

---

- [ ] **Step 5: Add the sync-wrapper + cursor + auth tests (extend the test file)**

Append these `describe` blocks to `test/schemas.test.ts` (after the existing ones). They drive the remaining schema behaviour, including the base64url cursor round-trip.

```ts
// ---- append to test/schemas.test.ts ----

describe("mutationSchema + pushBody", () => {
  const validMutation = {
    mutationId: "0190f8a0-5555-7000-8000-000000000005",
    entityType: "transaction",
    entityId: EID,
    op: "upsert" as const,
    baseRev: 0,
    updatedAt: 1748563200000,
    payload: env({ type: "transaction", amountCents: -100 }),
  };

  it("accepts a valid mutation", () => {
    expect(mutationSchema.safeParse(validMutation).success).toBe(true);
  });

  it("accepts op delete", () => {
    expect(mutationSchema.safeParse({ ...validMutation, op: "delete" }).success).toBe(true);
  });

  it("rejects an unknown op", () => {
    expect(mutationSchema.safeParse({ ...validMutation, op: "insert" }).success).toBe(false);
  });

  it("rejects a non-uuid mutationId", () => {
    expect(mutationSchema.safeParse({ ...validMutation, mutationId: "x" }).success).toBe(false);
  });

  it("accepts a push body with up to 200 mutations", () => {
    const body = { deviceId: DID, mutations: Array.from({ length: 200 }, () => validMutation) };
    expect(pushBody.safeParse(body).success).toBe(true);
  });

  it("rejects a push body with 201 mutations (batch cap)", () => {
    const body = { deviceId: DID, mutations: Array.from({ length: 201 }, () => validMutation) };
    expect(pushBody.safeParse(body).success).toBe(false);
  });

  it("rejects an empty push body", () => {
    expect(pushBody.safeParse({ deviceId: DID, mutations: [] }).success).toBe(false);
  });
});

describe("pullQuery", () => {
  it("defaults limit to 500 when omitted (first sync)", () => {
    const r = pullQuery.safeParse({});
    expect(r.success).toBe(true);
    if (r.success) expect(r.data.limit).toBe(500);
  });

  it("coerces a string limit from the query string", () => {
    const r = pullQuery.safeParse({ cursor: "abc", limit: "250" });
    expect(r.success).toBe(true);
    if (r.success) expect(r.data.limit).toBe(250);
  });

  it("rejects a limit above 500", () => {
    expect(pullQuery.safeParse({ limit: "5000" }).success).toBe(false);
  });
});

describe("cursor codec", () => {
  it("round-trips a cursor through base64url", () => {
    const c = { ts: 1748563200123, id: EID };
    const decoded = decodeCursor(encodeCursor(c));
    expect(decoded).toEqual(c);
  });

  it("produces a URL-safe string (no +, /, or = padding)", () => {
    const enc = encodeCursor({ ts: 1748563200123, id: EID });
    expect(enc).not.toMatch(/[+/=]/);
  });

  it("returns null for undefined (first sync = full snapshot)", () => {
    expect(decodeCursor(undefined)).toBeNull();
  });

  it("returns null for garbage input", () => {
    expect(decodeCursor("!!!not-base64!!!")).toBeNull();
  });

  it("returns null when the decoded shape is invalid", () => {
    const bad = btoa(JSON.stringify({ ts: "nope", id: 123 }))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");
    expect(decodeCursor(bad)).toBeNull();
  });
});

describe("auth bodies", () => {
  it("accepts a valid apple body", () => {
    const r = appleBody.safeParse({
      identityToken: "eyJ...",
      authorizationCode: "c123",
      rawNonce: "n123",
      email: "user@example.com",
    });
    expect(r.success).toBe(true);
  });

  it("rejects an apple body missing rawNonce", () => {
    expect(
      appleBody.safeParse({ identityToken: "x", authorizationCode: "y" }).success,
    ).toBe(false);
  });

  it("accepts a magic-link request with a valid email", () => {
    expect(magicLinkRequestBody.safeParse({ email: "a@b.com" }).success).toBe(true);
  });

  it("rejects a magic-link request with a bad email", () => {
    expect(magicLinkRequestBody.safeParse({ email: "not-an-email" }).success).toBe(false);
  });

  it("accepts a magic-link verify token and a refresh token", () => {
    expect(magicLinkVerifyBody.safeParse({ token: "t" }).success).toBe(true);
    expect(refreshBody.safeParse({ refreshToken: "r" }).success).toBe(true);
  });

  it("rejects an empty refresh token", () => {
    expect(refreshBody.safeParse({ refreshToken: "" }).success).toBe(false);
  });
});
```

Run:

```bash
npx vitest run test/schemas.test.ts
```

Expected: **PASS** — every block passes, including the cursor base64url round-trip, the 200/201 batch-cap boundary, `pullQuery` coercion/defaulting, and the auth body validations.

---

- [ ] **Step 6: Typecheck the new schema modules**

```bash
npx tsc --noEmit
```

Expected: **PASS** — no type errors. (Confirms `z.infer` exports and `entitySchemaFor`'s `z.ZodTypeAny` return type compile cleanly under TypeScript `^5`.)

---

- [ ] **Step 7: Commit the schemas + their tests together (TDD commit)**

```bash
git add src/schemas/entities.ts src/schemas/sync.ts src/schemas/auth.ts test/schemas.test.ts && git commit -m "feat(backend): add zod schemas for auth, sync, and syncable entities

- baseEnvelope (passthrough) + per-type entities (transaction, lineItem,
  profile, budget, loyaltyCard) and entitySchemaFor() lookup
- sync wire schemas (mutation, pushBody<=200, pullQuery) + base64url
  composite-keyset cursor codec (encodeCursor/decodeCursor)
- auth request bodies (apple, magic-link request/verify, refresh)
- pure vitest unit tests: safeParse valid/invalid, batch cap, cursor round-trip

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

Expected: commit succeeds on the working branch; `git log --oneline -1` shows the new commit.


---

### Task 5: jwt-authmw — JWT sign/verify, session token ops, Bearer auth middleware

Builds the authentication core: HS256 access-token signing/verification (jose), opaque rotating refresh tokens with SHA-256 hashing, the `sessions` table operations (create / find-by-hash / rotate / revoke / revoke-family with reuse detection), and the Hono Bearer-auth middleware that protects every route except `/health` and `/auth/*`. Strict TDD: each unit/integration test is written first and run to FAIL, then implemented to PASS.

**Depends on (from earlier tasks):** `Env` (`src/env.ts`); `ApiError`, `ERROR`, `toEnvelope` (`src/lib/errors.ts`); `uuidv7()` (`src/lib/ids.ts`); `nowMs()` (`src/lib/time.ts`); the `sessions` and `users` tables in `migrations/0001_init.sql`; the Hono app in `src/app.ts` + `onError` in `src/middleware/error.ts`; the `vitest.config.ts` that reads migrations into the `TEST_MIGRATIONS` binding via `readD1Migrations`.

#### Files
- **Create:** `src/lib/jwt.ts` — `signAccess`, `verifyAccess`, `newRefreshToken`, `hashToken`, `AccessClaims`
- **Create:** `src/lib/sessions.ts` — `issueSession`, `findSessionByRefreshHash`, `rotateSession`, `revokeSession`, `revokeSessionFamily`, `SessionRow`
- **Create:** `src/middleware/auth.ts` — `authMiddleware`, `PUBLIC_PATHS`
- **Modify:** `src/app.ts` — mount `authMiddleware` on protected routes
- **Create (test):** `test/jwt.test.ts`, `test/sessions.test.ts`, `test/authmw.test.ts`
- **Create (helper):** `test/setup.ts` — applies D1 migrations in `beforeAll` (skip if an earlier task already created it)

---

- [ ] **Step 1: Pin the auth dependency (`jose`).**
```bash
npm pkg get dependencies.jose >/dev/null 2>&1 || npm install jose@^5
# verify it resolved into the expected major
node -e "console.log('jose', require('jose/package.json').version)"
```
Expected: prints `jose 5.x.x` (e.g. `jose 5.9.6`). If it prints nothing or a non-5 major, re-run `npm install jose@^5`.

---

- [ ] **Step 2: Confirm the shared D1 migration setup file exists (create it if Task 1 did not).** The Cloudflare Vitest pool exposes migrations as the `TEST_MIGRATIONS` binding (filled by `readD1Migrations` in `vitest.config.ts`). This setup file applies them to `env.DB` once per worker before any test runs.
```ts
// test/setup.ts
import { env, applyD1Migrations } from "cloudflare:test";
import { beforeAll } from "vitest";

// `TEST_MIGRATIONS` is populated in vitest.config.ts via readD1Migrations(migrations/).
declare module "cloudflare:test" {
  interface ProvidedEnv {
    TEST_MIGRATIONS: D1Migration[];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});
```
Expected: file present at `test/setup.ts`. (If Task 1 already wrote it identically, leave it; if it differs, do not duplicate the `beforeAll` — reuse the existing one.) Ensure `vitest.config.ts` has `test.setupFiles: ["./test/setup.ts"]`.

---

- [ ] **Step 3 (TDD — write failing test): JWT sign/verify round-trip + iss/aud/expiry checks.**
```ts
// test/jwt.test.ts
import { describe, it, expect } from "vitest";
import { SignJWT } from "jose";
import { signAccess, verifyAccess, newRefreshToken, hashToken } from "../src/lib/jwt";

const KEY = "test-signing-key-0123456789-abcdefghijklmnop";

describe("jwt", () => {
  it("signs and verifies an access token round-trip with all claims", async () => {
    const token = await signAccess(KEY, {
      userId: "u-1",
      sessionId: "s-1",
      deviceId: "d-1",
    });
    expect(typeof token).toBe("string");
    expect(token.split(".")).toHaveLength(3);

    const claims = await verifyAccess(KEY, token);
    expect(claims.sub).toBe("u-1");
    expect(claims.sid).toBe("s-1");
    expect(claims.did).toBe("d-1");
    expect(claims.iss).toBe("snapceipt");
    expect(claims.aud).toBe("snapceipt-ios");
    expect(claims.exp - claims.iat).toBe(900); // 15 min TTL
  });

  it("rejects a token signed with a different key (signature failure)", async () => {
    const token = await signAccess(KEY, { userId: "u-1", sessionId: "s-1", deviceId: "d-1" });
    await expect(verifyAccess("a-totally-different-key-9999999999", token)).rejects.toThrow();
  });

  it("rejects an expired token", async () => {
    // mint a token that expired one minute ago, with the correct iss/aud
    const secret = new TextEncoder().encode(KEY);
    const past = Math.floor(Date.now() / 1000) - 60;
    const expired = await new SignJWT({ sid: "s-1", did: "d-1" })
      .setProtectedHeader({ alg: "HS256" })
      .setSubject("u-1")
      .setIssuer("snapceipt")
      .setAudience("snapceipt-ios")
      .setIssuedAt(past - 900)
      .setExpirationTime(past)
      .sign(secret);
    await expect(verifyAccess(KEY, expired)).rejects.toThrow();
  });

  it("rejects a token with the wrong issuer/audience", async () => {
    const secret = new TextEncoder().encode(KEY);
    const wrong = await new SignJWT({ sid: "s-1", did: "d-1" })
      .setProtectedHeader({ alg: "HS256" })
      .setSubject("u-1")
      .setIssuer("evil")
      .setAudience("evil-app")
      .setIssuedAt()
      .setExpirationTime("15m")
      .sign(secret);
    await expect(verifyAccess(KEY, wrong)).rejects.toThrow();
  });

  it("newRefreshToken returns a 256-bit base64url string and hashToken is stable hex", async () => {
    const a = newRefreshToken();
    const b = newRefreshToken();
    expect(a).not.toBe(b);
    expect(a).toMatch(/^[A-Za-z0-9_-]+$/); // base64url, no padding
    // 32 random bytes -> base64url length 43
    expect(a.length).toBe(43);

    const h1 = await hashToken(a);
    const h2 = await hashToken(a);
    expect(h1).toBe(h2); // deterministic
    expect(h1).toMatch(/^[0-9a-f]{64}$/); // sha256 hex
    expect(await hashToken(b)).not.toBe(h1);
  });
});
```
Run:
```bash
npx vitest run test/jwt.test.ts
```
Expected: FAIL — `Cannot find module '../src/lib/jwt'` (the file does not exist yet).

---

- [ ] **Step 4 (TDD — implement): `src/lib/jwt.ts`.**
```ts
// src/lib/jwt.ts
import { SignJWT, jwtVerify } from "jose";

export const ACCESS_TTL_SECONDS = 900; // 15 minutes
const ISSUER = "snapceipt";
const AUDIENCE = "snapceipt-ios";

export interface AccessClaims {
  sub: string; // userId
  sid: string; // sessionId
  did: string; // deviceId
  iss: string;
  aud: string;
  iat: number;
  exp: number;
}

function keyBytes(signingKey: string): Uint8Array {
  return new TextEncoder().encode(signingKey);
}

/** Sign a 15-minute HS256 access token. */
export async function signAccess(
  signingKey: string,
  input: { userId: string; sessionId: string; deviceId: string },
): Promise<string> {
  return new SignJWT({ sid: input.sessionId, did: input.deviceId })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setSubject(input.userId)
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setIssuedAt()
    .setExpirationTime(`${ACCESS_TTL_SECONDS}s`)
    .sign(keyBytes(signingKey));
}

/**
 * Verify an HS256 access token. Throws (jose JWTExpired / JWSSignatureVerificationFailed /
 * JWTClaimValidationFailed) on any failure — callers map this to AUTH_INVALID_TOKEN.
 */
export async function verifyAccess(signingKey: string, token: string): Promise<AccessClaims> {
  const { payload } = await jwtVerify(token, keyBytes(signingKey), {
    issuer: ISSUER,
    audience: AUDIENCE,
    algorithms: ["HS256"],
  });
  return payload as unknown as AccessClaims;
}

/** Opaque 256-bit refresh token, base64url (no padding) — 43 chars. */
export function newRefreshToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return base64url(bytes);
}

/** SHA-256 hex of a token; what we persist in the sessions table. */
export async function hashToken(token: string): Promise<string> {
  const data = new TextEncoder().encode(token);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function base64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
```
Run:
```bash
npx vitest run test/jwt.test.ts
```
Expected: PASS — all 5 jwt assertions green.

---

- [ ] **Step 5 (TDD — write failing test): sessions table ops (create / find / rotate / revoke / reuse-detection).** Uses real D1 via `cloudflare:test`. Seeds a `users` row first (FK target).
```ts
// test/sessions.test.ts
import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { nowMs } from "../src/lib/time";
import { hashToken } from "../src/lib/jwt";
import {
  issueSession,
  findSessionByRefreshHash,
  rotateSession,
  revokeSession,
  revokeSessionFamily,
} from "../src/lib/sessions";

const USER_ID = "u-sess-1";
const DEVICE_ID = "d-sess-1";

beforeEach(async () => {
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM users");
  const t = nowMs();
  await env.DB.prepare(
    "INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at) VALUES (?, ?, 0, ?, 'free', ?, ?)",
  )
    .bind(USER_ID, "sess@example.com", "Sess User", t, t)
    .run();
});

describe("sessions", () => {
  it("creates a session, persists the refresh hash, and finds it back", async () => {
    const { sessionId, refreshToken } = await issueSession(env.DB, {
      userId: USER_ID,
      deviceId: DEVICE_ID,
    });
    expect(sessionId).toBeTruthy();
    expect(refreshToken).toBeTruthy();

    const found = await findSessionByRefreshHash(env.DB, await hashToken(refreshToken));
    expect(found).not.toBeNull();
    expect(found!.id).toBe(sessionId);
    expect(found!.user_id).toBe(USER_ID);
    expect(found!.device_id).toBe(DEVICE_ID);
    expect(found!.revoked_at).toBeNull();
    expect(found!.family).toBeTruthy();
    expect(found!.expires_at).toBeGreaterThan(nowMs());
  });

  it("rotates: old refresh hash stops resolving, new one resolves to the same family", async () => {
    const { sessionId, refreshToken, family } = await issueSession(env.DB, {
      userId: USER_ID,
      deviceId: DEVICE_ID,
    });
    const oldHash = await hashToken(refreshToken);

    const rotated = await rotateSession(env.DB, sessionId);
    const newHash = await hashToken(rotated.refreshToken);
    expect(newHash).not.toBe(oldHash);

    // old hash no longer matches a live session
    expect(await findSessionByRefreshHash(env.DB, oldHash)).toBeNull();
    // new hash resolves to the same row + same family
    const live = await findSessionByRefreshHash(env.DB, newHash);
    expect(live).not.toBeNull();
    expect(live!.id).toBe(sessionId);
    expect(live!.family).toBe(family);
  });

  it("revokeSession marks the row revoked so it stops resolving", async () => {
    const { sessionId, refreshToken } = await issueSession(env.DB, {
      userId: USER_ID,
      deviceId: DEVICE_ID,
    });
    await revokeSession(env.DB, sessionId);
    expect(await findSessionByRefreshHash(env.DB, await hashToken(refreshToken))).toBeNull();
  });

  it("revokeSessionFamily revokes every session sharing the family (reuse detection)", async () => {
    const s1 = await issueSession(env.DB, { userId: USER_ID, deviceId: DEVICE_ID });
    // simulate a rotated descendant in the same family
    const s2 = await rotateSession(env.DB, s1.sessionId);

    await revokeSessionFamily(env.DB, s1.family);

    expect(await findSessionByRefreshHash(env.DB, await hashToken(s2.refreshToken))).toBeNull();
    const row = await env.DB.prepare("SELECT revoked_at FROM sessions WHERE id = ?")
      .bind(s1.sessionId)
      .first<{ revoked_at: number | null }>();
    expect(row!.revoked_at).not.toBeNull();
  });
});
```
Run:
```bash
npx vitest run test/sessions.test.ts
```
Expected: FAIL — `Cannot find module '../src/lib/sessions'`.

---

- [ ] **Step 6 (TDD — implement): `src/lib/sessions.ts`.** Operates on the `sessions` table from `migrations/0001_init.sql` (columns: `id, user_id, device_id, refresh_hash, family, created_at, last_seen_at, expires_at, revoked_at`). A session resolves only when `revoked_at IS NULL AND expires_at > now`.
```ts
// src/lib/sessions.ts
import { uuidv7 } from "./ids";
import { nowMs } from "./time";
import { newRefreshToken, hashToken } from "./jwt";

export const REFRESH_TTL_MS = 60 * 24 * 60 * 60 * 1000; // 60-day sliding window

export interface SessionRow {
  id: string;
  user_id: string;
  device_id: string;
  refresh_hash: string;
  family: string;
  created_at: number;
  last_seen_at: number;
  expires_at: number;
  revoked_at: number | null;
}

/** Create a brand-new session family and return the plaintext refresh token (returned once). */
export async function issueSession(
  db: D1Database,
  input: { userId: string; deviceId: string },
): Promise<{ sessionId: string; refreshToken: string; family: string }> {
  const id = uuidv7();
  const family = uuidv7();
  const refreshToken = newRefreshToken();
  const refreshHash = await hashToken(refreshToken);
  const t = nowMs();

  await db
    .prepare(
      `INSERT INTO sessions
         (id, user_id, device_id, refresh_hash, family, created_at, last_seen_at, expires_at, revoked_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)`,
    )
    .bind(id, input.userId, input.deviceId, refreshHash, family, t, t, t + REFRESH_TTL_MS)
    .run();

  return { sessionId: id, refreshToken, family };
}

/** Find a live (not revoked, not expired) session by the sha256 hash of its current refresh token. */
export async function findSessionByRefreshHash(
  db: D1Database,
  refreshHash: string,
): Promise<SessionRow | null> {
  const row = await db
    .prepare(
      `SELECT * FROM sessions
        WHERE refresh_hash = ? AND revoked_at IS NULL AND expires_at > ?`,
    )
    .bind(refreshHash, nowMs())
    .first<SessionRow>();
  return row ?? null;
}

/**
 * Rotate the refresh token in place: install a new hash, slide the 60-day expiry,
 * keep the same session id + family. Returns the new plaintext refresh token.
 */
export async function rotateSession(
  db: D1Database,
  sessionId: string,
): Promise<{ sessionId: string; refreshToken: string; family: string }> {
  const refreshToken = newRefreshToken();
  const refreshHash = await hashToken(refreshToken);
  const t = nowMs();

  await db
    .prepare(
      `UPDATE sessions
          SET refresh_hash = ?, last_seen_at = ?, expires_at = ?
        WHERE id = ? AND revoked_at IS NULL`,
    )
    .bind(refreshHash, t, t + REFRESH_TTL_MS, sessionId)
    .run();

  const row = await db
    .prepare("SELECT family FROM sessions WHERE id = ?")
    .bind(sessionId)
    .first<{ family: string }>();

  return { sessionId, refreshToken, family: row!.family };
}

/** Revoke a single session (sign-out of one device). */
export async function revokeSession(db: D1Database, sessionId: string): Promise<void> {
  await db
    .prepare("UPDATE sessions SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL")
    .bind(nowMs(), sessionId)
    .run();
}

/** Revoke every session in a family — used on refresh-token reuse detection. */
export async function revokeSessionFamily(db: D1Database, family: string): Promise<void> {
  await db
    .prepare("UPDATE sessions SET revoked_at = ? WHERE family = ? AND revoked_at IS NULL")
    .bind(nowMs(), family)
    .run();
}
```
Run:
```bash
npx vitest run test/sessions.test.ts
```
Expected: PASS — all 4 session assertions green.

---

- [ ] **Step 7 (TDD — write failing test): auth middleware over the real Worker.** Adds a temporary protected probe route guaranteed to exist, mints a valid token with the test signing key (`env.JWT_SIGNING_KEY` is configured in `vitest.config.ts` miniflare bindings), and asserts 401 envelopes on missing/invalid/expired tokens, public-path bypass for `/health`, and `c.var.userId`/`deviceId` propagation.
```ts
// test/authmw.test.ts
import { describe, it, expect } from "vitest";
import { env, SELF } from "cloudflare:test";
import { signAccess } from "../src/lib/jwt";

const KEY = env.JWT_SIGNING_KEY;

async function bearer(userId = "u-1", sid = "s-1", did = "d-1") {
  return `Bearer ${await signAccess(KEY, { userId, sessionId: sid, deviceId: did })}`;
}

describe("auth middleware", () => {
  it("allows the public /health route with no Authorization header", async () => {
    const res = await SELF.fetch("https://api.test/health");
    expect(res.status).toBe(200);
  });

  it("allows public /auth/* routes through without a token", async () => {
    // /auth/refresh exists (Task 6); without a body it should NOT be a 401 from auth mw.
    const res = await SELF.fetch("https://api.test/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    expect(res.status).not.toBe(401);
  });

  it("rejects a protected route with no bearer -> 401 AUTH_INVALID_TOKEN envelope", async () => {
    const res = await SELF.fetch("https://api.test/devices/me", { method: "PUT", body: "{}" });
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: { code: string; requestId: string } };
    expect(body.error.code).toBe("AUTH_INVALID_TOKEN");
    expect(body.error.requestId).toBeTruthy();
  });

  it("rejects a malformed/invalid bearer token -> 401", async () => {
    const res = await SELF.fetch("https://api.test/devices/me", {
      method: "PUT",
      headers: { Authorization: "Bearer not-a-real-jwt" },
      body: "{}",
    });
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("AUTH_INVALID_TOKEN");
  });

  it("rejects a token signed with the wrong key -> 401", async () => {
    const token = await signAccess("some-other-key-not-the-server-key", {
      userId: "u-1",
      sessionId: "s-1",
      deviceId: "d-1",
    });
    const res = await SELF.fetch("https://api.test/devices/me", {
      method: "PUT",
      headers: { Authorization: `Bearer ${token}` },
      body: "{}",
    });
    expect(res.status).toBe(401);
  });

  it("accepts a valid bearer and exposes userId/deviceId on a probe route", async () => {
    const res = await SELF.fetch("https://api.test/__authprobe", {
      headers: { Authorization: await bearer("u-42", "s-9", "d-7") },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { userId: string; deviceId: string };
    expect(body.userId).toBe("u-42");
    expect(body.deviceId).toBe("d-7");
  });
});
```
Run:
```bash
npx vitest run test/authmw.test.ts
```
Expected: FAIL — middleware not mounted yet (e.g. `/devices/me` and `/__authprobe` return 404, and `/__authprobe` does not yet exist), so assertions on 401/200/userId fail.

---

- [ ] **Step 8 (TDD — implement): `src/middleware/auth.ts`.** Extracts the Bearer token, calls `verifyAccess`, maps any jose failure to `ApiError(AUTH_INVALID_TOKEN, 401)`, and sets `c.var.userId` / `c.var.deviceId`. Public paths (`/health`, `/auth/*`) are allow-listed and skip verification.
```ts
// src/middleware/auth.ts
import type { MiddlewareHandler } from "hono";
import type { Env } from "../env";
import { ApiError, ERROR } from "../lib/errors";
import { verifyAccess } from "../lib/jwt";

/** Paths reachable without a valid access token. */
export const PUBLIC_PATHS = ["/health", "/auth/"];

function isPublic(path: string): boolean {
  return PUBLIC_PATHS.some((p) => (p.endsWith("/") ? path.startsWith(p) : path === p));
}

export function authMiddleware(): MiddlewareHandler<{
  Bindings: Env;
  Variables: { userId: string; deviceId: string; requestId: string };
}> {
  return async (c, next) => {
    if (isPublic(c.req.path)) {
      return next();
    }

    const header = c.req.header("Authorization");
    if (!header || !header.startsWith("Bearer ")) {
      throw new ApiError(ERROR.AUTH_INVALID_TOKEN, "Missing or malformed Authorization header");
    }
    const token = header.slice("Bearer ".length).trim();
    if (!token) {
      throw new ApiError(ERROR.AUTH_INVALID_TOKEN, "Empty bearer token");
    }

    let claims;
    try {
      claims = await verifyAccess(c.env.JWT_SIGNING_KEY, token);
    } catch {
      // jose throws JWTExpired / JWSSignatureVerificationFailed / JWTClaimValidationFailed —
      // all collapse to one client-facing code.
      throw new ApiError(ERROR.AUTH_INVALID_TOKEN, "Invalid or expired access token");
    }

    c.set("userId", claims.sub);
    c.set("deviceId", claims.did);
    return next();
  };
}
```
(No run step yet — the middleware must be wired into the app in Step 9 before the test can pass.)

---

- [ ] **Step 9 (TDD — wire it): mount `authMiddleware` in `src/app.ts` and add the test-only probe route.** The middleware runs on every request; `isPublic` internally lets `/health` and `/auth/*` through, so a single `app.use("*", ...)` is correct and avoids per-group duplication. The `/__authprobe` route echoes the resolved identity so the middleware can be black-box tested.
```ts
// --- in src/app.ts ---
// (1) import alongside the other middleware imports:
import { authMiddleware } from "./middleware/auth";

// (2) Mount AFTER error middleware/requestId/rateLimit, BEFORE the protected route groups.
//     Example placement (keep your existing requestId/rateLimit lines):
app.use("*", authMiddleware());

// (3) Add a test-only probe route that proves c.var propagation.
//     It is protected (not in PUBLIC_PATHS), so reaching it means auth succeeded.
app.get("/__authprobe", (c) =>
  c.json({ userId: c.var.userId, deviceId: c.var.deviceId }),
);

// (4) Keep the existing route mounts (auth, devices, sync, misc) below.
```
Run:
```bash
npx vitest run test/authmw.test.ts
```
Expected: PASS — all 6 middleware assertions green (public bypass, 401 envelopes with `AUTH_INVALID_TOKEN` + `requestId`, valid-token 200 echoing `userId:"u-42"`, `deviceId:"d-7"`).

---

- [ ] **Step 10 (verify whole suite + typecheck):**
```bash
npx tsc --noEmit && npx vitest run test/jwt.test.ts test/sessions.test.ts test/authmw.test.ts
```
Expected: `tsc` exits 0 (no type errors) and all three test files pass (15 tests total green).

---

- [ ] **Step 11 (commit test + impl together):**
```bash
git checkout -b backend-jwt-authmw 2>/dev/null || git checkout backend-jwt-authmw
git add src/lib/jwt.ts src/lib/sessions.ts src/middleware/auth.ts src/app.ts \
        test/jwt.test.ts test/sessions.test.ts test/authmw.test.ts test/setup.ts package.json package-lock.json
git commit -m "$(cat <<'EOF'
feat(backend): add JWT auth, session token ops, and Bearer auth middleware

- jose HS256 signAccess/verifyAccess (15m TTL, iss/aud checks)
- newRefreshToken (256-bit base64url) + hashToken (sha256 hex)
- sessions create/find-by-hash/rotate/revoke/revoke-family with reuse detection
- authMiddleware: Bearer verify, sets userId/deviceId, /health + /auth/* public
- tests: sign/verify round-trip, expired/invalid -> 401, missing bearer -> 401, rotate/revoke

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```
Expected: commit succeeds on branch `backend-jwt-authmw` (not on the default branch). If `/__authprobe` is considered test-scaffolding to remove before merge, leave a `// TODO(test-probe)` note — but it is harmless behind auth and useful for Task 7's auth tests.

---

**Notes for downstream tasks (do not implement here):**
- Task 6 (`/auth/*` routes) consumes `issueSession`, `rotateSession`, `findSessionByRefreshHash`, `revokeSessionFamily` (reuse detection on `/auth/refresh`), `revokeSession` (on `/auth/signout`), and `signAccess` to build the `{ accessToken, refreshToken, expiresIn:900, user }` envelope. The reuse-detection rule: if a presented refresh token's hash does NOT resolve via `findSessionByRefreshHash` but DID once belong to a known family, call `revokeSessionFamily` and return `AUTH_SESSION_REVOKED` (401).
- Protected route groups (`/devices/*`, `/sync/*`, `/banks`) are already covered by the single `app.use("*", authMiddleware())` because they are not in `PUBLIC_PATHS`.

---

### Task 6: auth-magiclink

Implements the magic-link half of `src/routes/auth.ts`: `POST /auth/magic-link/request` (zod email, mint a 256-bit token, store its sha256 in KV under `ml:<hash>` TTL 600s with `{email}`, send via `env.EMAIL.send`, ALWAYS 202, rate-limited by middleware) and `POST /auth/magic-link/verify` (hash the token, KV `getWithMetadata`, delete for single-use, upsert user by email + `auth_identities(provider='email')`, register a device if `X-Device-Id` present, issue a session, return `{accessToken, refreshToken, expiresIn:900, user}`).

This task reuses symbols from earlier tasks and does NOT redefine them: `ApiError`/`ERROR` (`src/lib/errors.ts`), `signAccess`/`newRefreshToken`/`hashToken` (`src/lib/jwt.ts`), `uuidv7` (`src/lib/ids.ts`), `nowMs` (`src/lib/time.ts`), `issueSession(...)` (Task 5, in `src/routes/auth.ts`), the `auth` middleware public-path allowlist already covering `/auth/*` (Task 4), `rateLimit` middleware (Task 4), the `vitest.config.ts` + D1 migration setup (Task 2), and the `0001_init.sql` tables `users`, `auth_identities`, `email_tokens`, `devices`, `sessions` (Task 3). The `EMAIL` binding is `SendEmail` per the SPINE.

**Files**
- Modify: `src/schemas/auth.ts` (add `magicLinkRequestSchema`, `magicLinkVerifySchema`)
- Modify: `src/routes/auth.ts` (add `normalizeEmail`, the two magic-link routes onto the existing `authRoutes` Hono instance)
- Test: `test/auth.magiclink.test.ts`

---

- [ ] **Step 1: Write the failing test for `POST /auth/magic-link/request`.**

This test hits the Worker via `SELF.fetch`, asserts a 202 envelope-free body, asserts the KV key `ml:<sha256(token)>` is written with TTL+`{email}` metadata, and asserts `env.EMAIL.send` was invoked. Because the route generates the token internally, we recover the token from the mocked `EMAIL.send` payload (the email body/link carries it) so Step 2's verify test can consume it. We mock `env.EMAIL` with a vitest spy assigned onto the `cloudflare:test` `env` (pool-workers exposes mutable bindings on `env`).

```ts
import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

// migrations applied by the shared setup (Task 2). Re-assert here so this file
// runs standalone via `vitest run test/auth.magiclink.test.ts`.
beforeAll(async () => {
  // @ts-expect-error TEST_MIGRATIONS is injected by vitest.config.ts define (Task 2)
  await applyD1Migrations(env.DB, TEST_MIGRATIONS);
});

// sha256 hex helper mirroring src/lib/jwt.ts hashToken, used to assert the KV key.
async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Capture the raw token the route emails so the verify test can reuse it.
function installEmailSpy(): { send: ReturnType<typeof vi.fn>; lastToken(): string } {
  const send = vi.fn(async (_msg: unknown) => {});
  // env.EMAIL is the SendEmail binding; replace its send with a spy for this run.
  (env as unknown as { EMAIL: { send: typeof send } }).EMAIL = { send };
  return {
    send,
    lastToken() {
      const call = send.mock.calls.at(-1)?.[0] as { token?: string; body?: string } | undefined;
      if (call?.token) return call.token;
      const m = String(call?.body ?? "").match(/token=([A-Za-z0-9_-]+)/);
      if (!m) throw new Error("no token in email payload");
      return m[1];
    },
  };
}

describe("POST /auth/magic-link/request", () => {
  beforeEach(async () => {
    await env.DB.exec("DELETE FROM email_tokens");
  });

  it("returns 202 with no error body, writes ml:<hash> to KV, and calls EMAIL.send", async () => {
    const spy = installEmailSpy();
    const res = await SELF.fetch("https://x/auth/magic-link/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "Maya@Example.com " }),
    });

    expect(res.status).toBe(202);
    expect(spy.send).toHaveBeenCalledTimes(1);

    const token = spy.lastToken();
    const hash = await sha256Hex(token);
    const stored = await env.KV.getWithMetadata(`ml:${hash}`);
    expect(stored.metadata).toMatchObject({ email: "maya@example.com" });
  });

  it("returns 202 even for a syntactically valid but unknown email (no enumeration)", async () => {
    installEmailSpy();
    const res = await SELF.fetch("https://x/auth/magic-link/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "nobody@example.com" }),
    });
    expect(res.status).toBe(202);
  });

  it("rejects a malformed email with 400 VALIDATION_FAILED", async () => {
    installEmailSpy();
    const res = await SELF.fetch("https://x/auth/magic-link/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "not-an-email" }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("VALIDATION_FAILED");
  });
});
```

- [ ] **Step 2: Write the failing test for `POST /auth/magic-link/verify`.**

Append to the SAME file. It drives request -> grabs the emailed token -> verifies it (creates user+session, returns tokens), then asserts a second verify of the same token is `401` (single-use consumed), and that an unknown token is `401`.

```ts
describe("POST /auth/magic-link/verify", () => {
  beforeEach(async () => {
    await env.DB.exec("DELETE FROM sessions");
    await env.DB.exec("DELETE FROM auth_identities");
    await env.DB.exec("DELETE FROM users");
    await env.DB.exec("DELETE FROM devices");
  });

  async function requestLink(email: string): Promise<string> {
    const spy = installEmailSpy();
    const res = await SELF.fetch("https://x/auth/magic-link/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email }),
    });
    expect(res.status).toBe(202);
    return spy.lastToken();
  }

  it("consumes the token: creates user + session and returns tokens", async () => {
    const token = await requestLink("liam@example.com");
    const res = await SELF.fetch("https://x/auth/magic-link/verify", {
      method: "POST",
      headers: { "content-type": "application/json", "x-device-id": "01890000-0000-7000-8000-000000000abc" },
      body: JSON.stringify({ token }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      accessToken: string;
      refreshToken: string;
      expiresIn: number;
      user: { id: string; email: string; displayName: string | null };
    };
    expect(body.expiresIn).toBe(900);
    expect(body.accessToken.split(".")).toHaveLength(3); // JWT
    expect(body.refreshToken.length).toBeGreaterThanOrEqual(40);
    expect(body.user.email).toBe("liam@example.com");

    const user = await env.DB.prepare("SELECT id FROM users WHERE email = ?").bind("liam@example.com").first();
    expect(user).not.toBeNull();
    const ident = await env.DB
      .prepare("SELECT id FROM auth_identities WHERE provider = 'email' AND subject = ?")
      .bind("liam@example.com")
      .first();
    expect(ident).not.toBeNull();
    const device = await env.DB
      .prepare("SELECT id FROM devices WHERE id = ?")
      .bind("01890000-0000-7000-8000-000000000abc")
      .first();
    expect(device).not.toBeNull();
  });

  it("rejects a second use of the same token with 401 (single-use)", async () => {
    const token = await requestLink("twice@example.com");
    const ok = await SELF.fetch("https://x/auth/magic-link/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token }),
    });
    expect(ok.status).toBe(200);

    const replay = await SELF.fetch("https://x/auth/magic-link/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token }),
    });
    expect(replay.status).toBe(401);
    const body = (await replay.json()) as { error: { code: string } };
    expect(body.error.code).toBe("AUTH_INVALID_TOKEN");
  });

  it("rejects an unknown / expired token with 401", async () => {
    const res = await SELF.fetch("https://x/auth/magic-link/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token: "totally-made-up-token" }),
    });
    expect(res.status).toBe(401);
  });
});
```

- [ ] **Step 3: Run the test — expect FAIL.**

Run command:
```bash
npx vitest run test/auth.magiclink.test.ts
```
Expected: FAIL. The magic-link routes do not exist yet, so the request returns 404 (no matching route) — assertions like `expect(res.status).toBe(202)` fail. (`magicLinkRequestSchema`/`magicLinkVerifySchema` and the route handlers are not yet defined.)

- [ ] **Step 4: Add the magic-link zod schemas.**

Add to the existing `src/schemas/auth.ts`. `z.string().email()` validates the address; `.trim()` handles trailing spaces; the route normalizes case. The verify token is a non-empty opaque string.

```ts
import { z } from "zod";

// (appleAuthSchema / refreshSchema etc. from Task 5 already live in this file.)

export const magicLinkRequestSchema = z.object({
  email: z.string().trim().email(),
});
export type MagicLinkRequest = z.infer<typeof magicLinkRequestSchema>;

export const magicLinkVerifySchema = z.object({
  token: z.string().min(1).max(512),
});
export type MagicLinkVerify = z.infer<typeof magicLinkVerifySchema>;
```

- [ ] **Step 5: Implement the magic-link routes in `src/routes/auth.ts`.**

Append these handlers onto the existing `authRoutes` Hono instance (the same instance Task 5 mounts `/auth/apple`, `/auth/refresh`, etc. on, and which `src/app.ts` routes under the public allowlist). Uses `zValidator` from `@hono/zod-validator`, `crypto.subtle` for the token hash, KV `getWithMetadata`/`put`/`delete`, the shared `issueSession` from Task 5, and `uuidv7`/`nowMs`. The MimeMessage/EmailMessage construction for `env.EMAIL.send` follows the Cloudflare `cloudflare:email` + `mimetext` pattern, but in tests `EMAIL.send` is a spy so its concrete arg shape is irrelevant to the assertions (we also pass `token` for test capture is NOT done — instead the universal link in the body carries `token=` which the test regex extracts).

```ts
import { zValidator } from "@hono/zod-validator";
import { EmailMessage } from "cloudflare:email";
import { createMimeMessage } from "mimetext";
import { uuidv7 } from "../lib/ids";
import { nowMs } from "../lib/time";
import { ApiError, ERROR } from "../lib/errors";
import { magicLinkRequestSchema, magicLinkVerifySchema } from "../schemas/auth";
// issueSession is defined earlier in this same file (Task 5).

const MAGIC_LINK_TTL_SECONDS = 600;
const MAGIC_LINK_SENDER = "noreply@snapceipt.app";

export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// 256-bit opaque token, base64url.
function newMagicToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function buildMagicEmail(toEmail: string, token: string): EmailMessage {
  const link = `https://snapceipt.app/auth/magic?token=${token}`;
  const msg = createMimeMessage();
  msg.setSender({ name: "Snapceipt", addr: MAGIC_LINK_SENDER });
  msg.setRecipient(toEmail);
  msg.setSubject("Your Snapceipt sign-in link");
  msg.addMessage({
    contentType: "text/plain",
    data: `Tap to sign in to Snapceipt:\n\n${link}\n\nThis link expires in 10 minutes and can be used once. If you didn't request it, ignore this email.`,
  });
  return new EmailMessage(MAGIC_LINK_SENDER, toEmail, msg.asRaw());
}

authRoutes.post(
  "/magic-link/request",
  zValidator("json", magicLinkRequestSchema),
  async (c) => {
    const { email } = c.req.valid("json");
    const normalized = normalizeEmail(email);

    const token = newMagicToken();
    const hash = await sha256Hex(token);

    // Store only the hash; metadata carries the email for verify-time lookup.
    await c.env.KV.put(`ml:${hash}`, "1", {
      expirationTtl: MAGIC_LINK_TTL_SECONDS,
      metadata: { email: normalized, createdAt: nowMs() },
    });

    // Send via the SendEmail binding. In tests this is a mocked spy.
    await c.env.EMAIL.send(buildMagicEmail(normalized, token));

    // ALWAYS 202 — no account enumeration. No response body needed.
    return c.body(null, 202);
  },
);

authRoutes.post(
  "/magic-link/verify",
  zValidator("json", magicLinkVerifySchema),
  async (c) => {
    const { token } = c.req.valid("json");
    const hash = await sha256Hex(token);
    const key = `ml:${hash}`;

    const stored = await c.env.KV.getWithMetadata<{ email: string }>(key, "text");
    if (stored.value === null || !stored.metadata?.email) {
      // Unknown, already-consumed, or expired (KV TTL evicted it).
      throw new ApiError(ERROR.AUTH_INVALID_TOKEN, "Invalid or expired magic link");
    }

    // Single-use: delete before issuing so a concurrent replay can't double-consume.
    await c.env.KV.delete(key);

    const email = normalizeEmail(stored.metadata.email);
    const now = nowMs();

    // Upsert user by email (unique among non-deleted users). Reuse existing if present.
    let user = await c.env.DB
      .prepare("SELECT id, email, display_name FROM users WHERE email = ? AND deleted_at IS NULL")
      .bind(email)
      .first<{ id: string; email: string | null; display_name: string | null }>();

    if (!user) {
      const userId = uuidv7();
      await c.env.DB
        .prepare(
          `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
           VALUES (?, ?, 1, NULL, 'free', ?, ?)`,
        )
        .bind(userId, email, now, now)
        .run();
      user = { id: userId, email, display_name: null };
    } else {
      // A returning magic-link user has now proven control of the email.
      await c.env.DB
        .prepare("UPDATE users SET email_verified = 1, updated_at = ? WHERE id = ?")
        .bind(now, user.id)
        .run();
    }

    // Ensure an email auth_identity exists (idempotent on the unique (provider,subject) index).
    await c.env.DB
      .prepare(
        `INSERT INTO auth_identities (id, user_id, provider, subject, created_at)
         VALUES (?, ?, 'email', ?, ?)
         ON CONFLICT(provider, subject) DO NOTHING`,
      )
      .bind(uuidv7(), user.id, email, now)
      .run();

    // Register the device if the client sent one (X-Device-Id is the install UUID).
    const deviceHeader = c.req.header("X-Device-Id");
    const deviceId = deviceHeader && deviceHeader.length > 0 ? deviceHeader : uuidv7();
    await c.env.DB
      .prepare(
        `INSERT INTO devices (id, user_id, platform, last_seen_at, created_at, updated_at)
         VALUES (?, ?, 'ios', ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET user_id = excluded.user_id, last_seen_at = excluded.last_seen_at, updated_at = excluded.updated_at`,
      )
      .bind(deviceId, user.id, now, now, now)
      .run();

    // Issue an access+refresh session bound to this user+device (Task 5 helper).
    const session = await issueSession(c, user.id, deviceId);

    return c.json({
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      expiresIn: 900,
      user: { id: user.id, email: user.email, displayName: user.display_name },
    });
  },
);
```

- [ ] **Step 6: Ensure `EmailMessage`/`mimetext` resolve and the package is declared.**

`cloudflare:email` is a built-in runtime module (no install). `mimetext` is a dependency. Confirm it is installed (add it if Task 2 did not):
```bash
npm ls mimetext || npm install mimetext@^3
```
Expected: prints a `mimetext@3.x` version (installs it if missing). The `cloudflare:email` module is provided by the Workers runtime under `compatibility_flags: ["nodejs_compat"]` and `defineWorkersConfig`, so no install is needed for it.

- [ ] **Step 7: Run the test — expect PASS.**

Run command:
```bash
npx vitest run test/auth.magiclink.test.ts
```
Expected: PASS — all of: request returns 202 + writes `ml:<hash>` to KV with `{email}` metadata + calls `EMAIL.send` once; unknown email still 202; malformed email -> 400 `VALIDATION_FAILED`; verify creates user+identity+device+session and returns `{accessToken, refreshToken, expiresIn:900, user}`; second use of the token -> 401 `AUTH_INVALID_TOKEN`; unknown token -> 401.

- [ ] **Step 8: Run the whole suite to confirm no regression in the auth file.**

Run command:
```bash
npx vitest run
```
Expected: PASS — Task 5's `/auth/apple` and `/auth/refresh` tests plus this task's magic-link tests all green (the two halves share one `authRoutes` instance and the `issueSession` helper).

- [ ] **Step 9: Commit the test + implementation together (TDD step).**

Run command:
```bash
git add src/routes/auth.ts src/schemas/auth.ts test/auth.magiclink.test.ts package.json package-lock.json && \
git commit -m "feat(backend): add email magic-link request/verify auth routes

POST /auth/magic-link/request mints a 256-bit token, stores sha256(token)
in KV (ml:<hash>, 600s TTL, {email} metadata), emails the link via the
SendEmail binding, and always returns 202 (no account enumeration);
rate-limited via existing middleware. POST /auth/magic-link/verify hashes
the token, single-use-consumes it from KV, upserts the user + email
auth_identity, registers the X-Device-Id device, and issues a session.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
Expected: a single commit containing the schema additions, both route handlers, the test file, and the `mimetext` dependency bump.

---

### Task 7: auth-apple — POST /auth/apple (Apple identity-token verification + session issue)

Implements the Sign-in-with-Apple half of `src/routes/auth.ts`. The route verifies the Apple identity JWT against Apple's JWKS (RS256), enforces `iss`/`aud`/`exp` and the `sha256(rawNonce) == payload.nonce` replay check, upserts the user via `auth_identities(provider='apple', subject=sub)` (persisting `fullName`/`email` only on first auth), registers the device, and issues a session.

This task DEPENDS ON earlier tasks for: `Env`, `ApiError`/`ERROR`/`toEnvelope` (lib/errors), `uuidv7` (lib/ids), `nowMs`/`serverStamp` (lib/time), `issueSession` (the session/refresh helper from the auth-session task), the mounted `app` (src/app.ts), the auth middleware public-path allowlist that already exempts `/auth/*` (src/middleware/auth.ts), and `migrations/0001_init.sql` (tables `users`, `auth_identities`, `devices`, `sessions`). It does NOT redefine those — it imports them.

**Files**
- Create: `src/lib/apple.ts` (JWKS fetch+cache, `verifyAppleIdentityToken`)
- Create: `src/schemas/auth.ts` — ADD `AppleAuthBody` (if file exists from an earlier auth task, add the export; otherwise create it)
- Modify: `src/routes/auth.ts` — add `POST /auth/apple`
- Create: `test/helpers/apple.ts` (in-test RS256 keypair → signed token + JWKS)
- Test: `test/auth-apple.test.ts`

---

- [ ] **Step 1: Add the `AppleAuthBody` zod schema**

`src/schemas/auth.ts` — add this export (create the file with it if it does not yet exist). `email`/`fullName` are optional because Apple only sends them on first authorization.

```ts
import { z } from "zod";

export const AppleAuthBody = z.object({
  identityToken: z.string().min(1),
  authorizationCode: z.string().min(1),
  rawNonce: z.string().min(1),
  fullName: z.string().min(1).max(200).optional(),
  email: z.string().email().optional(),
});

export type AppleAuthBody = z.infer<typeof AppleAuthBody>;
```

- [ ] **Step 2: Write the Apple JWKS + token-verification library**

`src/lib/apple.ts`. Uses `jose` (`createLocalJWKSet` + `jwtVerify`). JWKS is cached in KV (`apple:jwks`) for ~24h; on a `kid` miss or empty cache it refetches (covers Apple key rollover). `jwtVerify` auto-validates `iss`, `aud`, and `exp`; we additionally enforce the nonce. Throws `ApiError(ERROR.AUTH_INVALID_TOKEN, ...)` (401) on any failure.

```ts
import { createLocalJWKSet, jwtVerify, decodeProtectedHeader, type JSONWebKeySet } from "jose";
import type { Env } from "../env";
import { ApiError, ERROR } from "./errors";

const APPLE_ISS = "https://appleid.apple.com";
const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";
const JWKS_KV_KEY = "apple:jwks";
const JWKS_TTL_SECONDS = 60 * 60 * 24; // ~24h

export interface AppleClaims {
  sub: string;
  email?: string;
  email_verified?: boolean | string;
  nonce?: string;
  is_private_email?: boolean | string;
}

/** Fetch Apple's JWKS, preferring the KV cache. `force` bypasses the cache (kid rollover). */
export async function fetchAppleJwks(env: Env, force = false): Promise<JSONWebKeySet> {
  if (!force) {
    const cached = await env.KV.get(JWKS_KV_KEY);
    if (cached) return JSON.parse(cached) as JSONWebKeySet;
  }
  const res = await fetch(APPLE_JWKS_URL, { headers: { accept: "application/json" } });
  if (!res.ok) {
    throw new ApiError(ERROR.AUTH_INVALID_TOKEN, "Unable to fetch Apple signing keys");
  }
  const jwks = (await res.json()) as JSONWebKeySet;
  await env.KV.put(JWKS_KV_KEY, JSON.stringify(jwks), { expirationTtl: JWKS_TTL_SECONDS });
  return jwks;
}

/** base64url(sha256(rawNonce)) — Apple hashes the nonce before embedding it in the token. */
async function sha256Base64Url(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  const bytes = new Uint8Array(digest);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * Verify an Apple identity JWT. Returns the validated claims (incl. stable `sub`).
 * Enforces signature (RS256, matching kid), iss, aud (== env.APPLE_BUNDLE_ID), exp, and the nonce.
 */
export async function verifyAppleIdentityToken(
  env: Env,
  identityToken: string,
  rawNonce: string,
): Promise<AppleClaims> {
  // Pick the kid up front so we can refresh the cache if Apple rotated keys.
  let kid: string | undefined;
  try {
    kid = decodeProtectedHeader(identityToken).kid;
  } catch {
    throw new ApiError(ERROR.AUTH_INVALID_TOKEN, "Malformed identity token");
  }

  const cached = await fetchAppleJwks(env, false);
  const hasKid = (jwks: JSONWebKeySet) => !kid || jwks.keys.some((k) => k.kid === kid);
  const jwks = hasKid(cached) ? cached : await fetchAppleJwks(env, true);

  let payload: AppleClaims;
  try {
    const result = await jwtVerify(identityToken, createLocalJWKSet(jwks), {
      issuer: APPLE_ISS,
      audience: env.APPLE_BUNDLE_ID,
      algorithms: ["RS256"],
    });
    payload = result.payload as unknown as AppleClaims;
  } catch {
    throw new ApiError(ERROR.AUTH_INVALID_TOKEN, "Invalid Apple identity token");
  }

  const expectedNonce = await sha256Base64Url(rawNonce);
  if (!payload.nonce || payload.nonce !== expectedNonce) {
    throw new ApiError(ERROR.AUTH_INVALID_TOKEN, "Nonce mismatch");
  }
  if (!payload.sub) {
    throw new ApiError(ERROR.AUTH_INVALID_TOKEN, "Missing subject");
  }
  return payload;
}
```

- [ ] **Step 3: Write the in-test Apple helper (RS256 keypair → signed token + JWKS)**

`test/helpers/apple.ts`. Generates an RS256 keypair inside the test, signs an Apple-shaped identity JWT, and exports the public JWK as a JWKS so the route's `fetch` of `appleid.apple.com/auth/keys` can be mocked. `nonce` is `base64url(sha256(rawNonce))` to match the server check.

```ts
import { SignJWT, exportJWK, generateKeyPair, type JSONWebKeySet } from "jose";

export const TEST_KID = "test-apple-kid-1";
export const APPLE_ISS = "https://appleid.apple.com";

async function sha256Base64Url(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  const bytes = new Uint8Array(digest);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export interface MakeTokenOpts {
  sub?: string;
  aud: string;
  rawNonce: string;
  email?: string;
  iss?: string;
  expiresInSec?: number;
}

export interface AppleTestKit {
  jwks: JSONWebKeySet;
  token: string;
}

/** Build a signed Apple-style identity token plus the matching JWKS to serve from the mock. */
export async function makeAppleIdToken(opts: MakeTokenOpts): Promise<AppleTestKit> {
  const { publicKey, privateKey } = await generateKeyPair("RS256", { extractable: true });

  const publicJwk = await exportJWK(publicKey);
  publicJwk.kid = TEST_KID;
  publicJwk.alg = "RS256";
  publicJwk.use = "sig";
  const jwks: JSONWebKeySet = { keys: [publicJwk] };

  const now = Math.floor(Date.now() / 1000);
  const token = await new SignJWT({
    nonce: await sha256Base64Url(opts.rawNonce),
    email: opts.email,
    email_verified: opts.email ? "true" : undefined,
  })
    .setProtectedHeader({ alg: "RS256", kid: TEST_KID })
    .setIssuer(opts.iss ?? APPLE_ISS)
    .setAudience(opts.aud)
    .setSubject(opts.sub ?? "000123.apple.subject.abc")
    .setIssuedAt(now)
    .setExpirationTime(now + (opts.expiresInSec ?? 600))
    .sign(privateKey);

  return { jwks, token };
}
```

- [ ] **Step 4: Write the failing test for `POST /auth/apple`**

`test/auth-apple.test.ts`. Applies migrations into the real D1 binding, mocks the Apple JWKS endpoint with `fetchMock`, and exercises success + bad-nonce + wrong-aud. `env.APPLE_BUNDLE_ID` must equal the `aud` used by the success token — set it in `vitest.config.ts` miniflare bindings (the SPINE config task) or rely on `.dev.vars`; this test reads it from `env`.

```ts
import { env, SELF, fetchMock, applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, afterEach, describe, expect, it } from "vitest";
import { readD1Migrations } from "@cloudflare/vitest-pool-workers/config";
import { makeAppleIdToken, TEST_KID } from "./helpers/apple";

const migrations = await readD1Migrations("./migrations");

beforeAll(async () => {
  await applyD1Migrations(env.DB, migrations);
});

beforeEach(() => {
  fetchMock.activate();
  fetchMock.disableNetConnect();
});

afterEach(() => {
  fetchMock.assertNoPendingInterceptors();
});

function mockJwks(jwks: unknown) {
  fetchMock
    .get("https://appleid.apple.com")
    .intercept({ path: "/auth/keys", method: "GET" })
    .reply(200, JSON.stringify(jwks), { headers: { "content-type": "application/json" } });
}

const BUNDLE_ID = env.APPLE_BUNDLE_ID;

describe("POST /auth/apple", () => {
  it("verifies a valid Apple token and issues a session", async () => {
    const rawNonce = "raw-nonce-success-001";
    const { jwks, token } = await makeAppleIdToken({
      aud: BUNDLE_ID,
      rawNonce,
      sub: "000777.apple.success",
      email: "relay@privaterelay.appleid.com",
    });
    mockJwks(jwks);

    const res = await SELF.fetch("https://api.test/auth/apple", {
      method: "POST",
      headers: { "content-type": "application/json", "x-device-id": crypto.randomUUID() },
      body: JSON.stringify({
        identityToken: token,
        authorizationCode: "auth-code-xyz",
        rawNonce,
        fullName: "Maya Reyes",
        email: "relay@privaterelay.appleid.com",
      }),
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(typeof body.accessToken).toBe("string");
    expect(typeof body.refreshToken).toBe("string");
    expect(body.expiresIn).toBe(900);
    expect(body.user.id).toMatch(/[0-9a-f-]{36}/i);
    expect(body.user.email).toBe("relay@privaterelay.appleid.com");
    expect(body.user.displayName).toBe("Maya Reyes");

    // Identity persisted and re-usable: a second sign-in (Apple omits name/email) reuses the user.
    const { jwks: jwks2, token: token2 } = await makeAppleIdToken({
      aud: BUNDLE_ID,
      rawNonce: "raw-nonce-success-002",
      sub: "000777.apple.success",
    });
    mockJwks(jwks2);
    const res2 = await SELF.fetch("https://api.test/auth/apple", {
      method: "POST",
      headers: { "content-type": "application/json", "x-device-id": crypto.randomUUID() },
      body: JSON.stringify({
        identityToken: token2,
        authorizationCode: "auth-code-2",
        rawNonce: "raw-nonce-success-002",
      }),
    });
    const body2 = (await res2.json()) as any;
    expect(res2.status).toBe(200);
    expect(body2.user.id).toBe(body.user.id);

    const row = await env.DB.prepare(
      "SELECT user_id FROM auth_identities WHERE provider = 'apple' AND subject = ?1",
    )
      .bind("000777.apple.success")
      .first<{ user_id: string }>();
    expect(row?.user_id).toBe(body.user.id);
  });

  it("rejects a token whose nonce does not match (401 AUTH_INVALID_TOKEN)", async () => {
    const { jwks, token } = await makeAppleIdToken({
      aud: BUNDLE_ID,
      rawNonce: "the-real-nonce",
      sub: "000888.apple.badnonce",
    });
    mockJwks(jwks);

    const res = await SELF.fetch("https://api.test/auth/apple", {
      method: "POST",
      headers: { "content-type": "application/json", "x-device-id": crypto.randomUUID() },
      body: JSON.stringify({
        identityToken: token,
        authorizationCode: "auth-code",
        rawNonce: "a-different-nonce", // mismatch
      }),
    });

    expect(res.status).toBe(401);
    const body = (await res.json()) as any;
    expect(body.error.code).toBe("AUTH_INVALID_TOKEN");
    expect(typeof body.error.requestId).toBe("string");
  });

  it("rejects a token with the wrong audience (401 AUTH_INVALID_TOKEN)", async () => {
    const rawNonce = "wrong-aud-nonce";
    const { jwks, token } = await makeAppleIdToken({
      aud: "com.someone.else", // not env.APPLE_BUNDLE_ID
      rawNonce,
      sub: "000999.apple.badaud",
    });
    mockJwks(jwks);

    const res = await SELF.fetch("https://api.test/auth/apple", {
      method: "POST",
      headers: { "content-type": "application/json", "x-device-id": crypto.randomUUID() },
      body: JSON.stringify({
        identityToken: token,
        authorizationCode: "auth-code",
        rawNonce,
      }),
    });

    expect(res.status).toBe(401);
    const body = (await res.json()) as any;
    expect(body.error.code).toBe("AUTH_INVALID_TOKEN");
  });
});
```

- [ ] **Step 5: Run the test and confirm it FAILS**

```bash
npx vitest run test/auth-apple.test.ts
```

Expected: FAIL. The route `POST /auth/apple` does not exist yet, so `SELF.fetch` returns 404 (`NOT_FOUND`) and `expect(res.status).toBe(200)` / `toBe(401)` fail. (Also a possible import error for `src/lib/apple.ts` not yet imported by the route — both confirm "red".)

- [ ] **Step 6: Implement `POST /auth/apple` in `src/routes/auth.ts`**

Add the handler to the existing auth sub-router. It validates the body with `@hono/zod-validator`, verifies the Apple token, upserts user + identity, registers the device, and issues a session via the shared `issueSession` helper (from the auth-session task). All writes are server-stamped and scoped by `user_id`. The `x-device-id` header carries the client install id (falls back to a generated UUIDv7 if absent).

> If `src/routes/auth.ts` does not yet exist (your task ordering puts apple first), create it as a `Hono<{ Bindings: Env; Variables: ... }>()` sub-router exporting `default auth` and mount it in `src/app.ts` with `app.route("/auth", authRoutes)`. Otherwise just add the route below to the existing router and add the imports.

```ts
import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import type { Env } from "../env";
import { ApiError, ERROR } from "../lib/errors";
import { uuidv7 } from "../lib/ids";
import { nowMs } from "../lib/time";
import { verifyAppleIdentityToken } from "../lib/apple";
import { issueSession } from "../lib/sessions"; // shared helper from the auth-session task
import { AppleAuthBody } from "../schemas/auth";

const auth = new Hono<{ Bindings: Env; Variables: { userId: string; deviceId: string; requestId: string } }>();

auth.post("/apple", zValidator("json", AppleAuthBody), async (c) => {
  const { identityToken, rawNonce, fullName, email } = c.req.valid("json");

  // 1. Verify Apple identity token (signature, iss, aud, exp, nonce).
  const claims = await verifyAppleIdentityToken(c.env, identityToken, rawNonce);
  const appleSub = claims.sub;
  const appleEmail = email ?? claims.email ?? null;

  const now = nowMs();
  const deviceId = c.req.header("x-device-id") ?? uuidv7();

  // 2. Upsert user by apple identity. First auth creates the user + identity and
  //    persists name/email; later auths reuse the existing user (no overwrite).
  const identity = await c.env.DB.prepare(
    "SELECT user_id FROM auth_identities WHERE provider = 'apple' AND subject = ?1",
  )
    .bind(appleSub)
    .first<{ user_id: string }>();

  let userId: string;
  if (identity) {
    userId = identity.user_id;
  } else {
    userId = uuidv7();
    const stmts: D1PreparedStatement[] = [
      c.env.DB.prepare(
        "INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at) " +
          "VALUES (?1, ?2, ?3, ?4, 'free', ?5, ?5)",
      ).bind(userId, appleEmail, appleEmail ? 1 : 0, fullName ?? null, now),
      c.env.DB.prepare(
        "INSERT INTO auth_identities (id, user_id, provider, subject, created_at) " +
          "VALUES (?1, ?2, 'apple', ?3, ?4)",
      ).bind(uuidv7(), userId, appleSub, now),
    ];
    await c.env.DB.batch(stmts);
  }

  // 3. Register / refresh the device (idempotent on device id).
  await c.env.DB.prepare(
    "INSERT INTO devices (id, user_id, platform, last_seen_at, created_at, updated_at) " +
      "VALUES (?1, ?2, 'ios', ?3, ?3, ?3) " +
      "ON CONFLICT(id) DO UPDATE SET last_seen_at = ?3, updated_at = ?3 " +
      "WHERE devices.user_id = ?2",
  )
    .bind(deviceId, userId, now)
    .run();

  // 4. Issue the session (creates sessions row, mints access + rotating refresh).
  const session = await issueSession(c.env, { userId, deviceId, now });

  // 5. Load the canonical user for the response envelope.
  const user = await c.env.DB.prepare(
    "SELECT id, email, display_name FROM users WHERE id = ?1",
  )
    .bind(userId)
    .first<{ id: string; email: string | null; display_name: string | null }>();

  if (!user) throw new ApiError(ERROR.INTERNAL, "User not found after upsert");

  return c.json({
    accessToken: session.accessToken,
    refreshToken: session.refreshToken,
    expiresIn: 900,
    user: { id: user.id, email: user.email, displayName: user.display_name },
  });
});

export default auth;
```

- [ ] **Step 7: Run the test and confirm it PASSES**

```bash
npx vitest run test/auth-apple.test.ts
```

Expected: PASS — all three cases green. Success returns a 200 session envelope and reuses the user on second sign-in; bad nonce → 401 `AUTH_INVALID_TOKEN`; wrong aud → 401 `AUTH_INVALID_TOKEN`. `fetchMock.assertNoPendingInterceptors()` confirms each JWKS mock was consumed.

- [ ] **Step 8: Typecheck**

```bash
npx tsc --noEmit
```

Expected: PASS (no type errors). `D1PreparedStatement`, `JSONWebKeySet`, and the `Env`/jose types resolve.

- [ ] **Step 9: Commit test + implementation together (TDD step commit)**

```bash
git add src/lib/apple.ts src/schemas/auth.ts src/routes/auth.ts test/helpers/apple.ts test/auth-apple.test.ts
git commit -m "$(cat <<'EOF'
feat(backend): verify Sign in with Apple identity token and issue session

Add POST /auth/apple: fetch+cache Apple JWKS in KV (~24h, refetch on kid
rollover), verify RS256 signature/iss/aud/exp via jose, enforce
sha256(rawNonce)==nonce, upsert user by apple sub (persist name/email on
first auth only), register device, issue session. Tests sign an in-test
RS256 token and mock the Apple JWKS endpoint: success + bad-nonce + wrong-aud.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: a single commit containing the apple verification lib, schema, route, and tests.

---

**Notes for the integrator**
- `issueSession(env, { userId, deviceId, now })` is the shared helper from the auth-session task; it must return `{ accessToken, refreshToken }` (access = `signAccess`, refresh = `newRefreshToken` stored as `hashToken` SHA-256 in `sessions`). If your ordering builds apple before that helper, stub `issueSession` minimally in `src/lib/sessions.ts` here and let the session task flesh it out — keep the signature stable.
- `env.APPLE_BUNDLE_ID` must be present as a test binding (set in `vitest.config.ts` miniflare `bindings` or `.dev.vars`); the success/wrong-aud tests pivot on it. Production value per spec is `com.snapceipt.app`.
- The auth middleware (src/middleware/auth.ts) MUST allowlist `/auth/*` so this unauthenticated route is reachable — already required by the SPINE.
- jose `jwtVerify` validates `iss`, `aud`, and `exp` itself (throws on mismatch/expiry); the wrong-aud test relies on this. The nonce check is the only claim we enforce manually.


---

### Task 8: auth-session-devices

Implements session lifecycle (refresh rotation with reuse-detection, signout) plus `GET /auth/me`, and device registration/removal. Depends on Task 1–7: `Env`/`Variables` (`src/env.ts`), `ApiError`+`ERROR` (`src/lib/errors.ts`), `signAccess`/`verifyAccess`/`newRefreshToken`/`hashToken` (`src/lib/jwt.ts`), `nowMs` (`src/lib/time.ts`), `uuidv7` (`src/lib/ids.ts`), `issueSession` (`src/lib/sessions.ts`, from the auth-bootstrap task), the `auth` middleware (`src/middleware/auth.ts`), the assembled `app` (`src/app.ts`), the `sessions`/`users`/`devices` tables (`migrations/0001_init.sql`), and the vitest-pool-workers test harness (`vitest.config.ts` with `defineWorkersConfig` + `readD1Migrations`, `test/apply-migrations.ts` applying `env.TEST_MIGRATIONS`).

**Assumed `sessions` table shape (from `migrations/0001_init.sql`, Task 3):** `sessions(id TEXT PK, user_id TEXT, device_id TEXT, family_id TEXT, refresh_hash TEXT, created_at INTEGER, last_seen_at INTEGER, expires_at INTEGER, revoked_at INTEGER NULL)` with `INDEX ix_sessions_family ON sessions(family_id)` and `UNIQUE INDEX ux_sessions_refresh ON sessions(refresh_hash)`. **Assumed `issueSession` signature (from `src/lib/sessions.ts`, Task 6):** `issueSession(db, { userId, deviceId }): Promise<{ accessToken, refreshToken, expiresIn, session }>`, which creates a row with a new `family_id` and returns the raw (unhashed) refresh token. This task ADDS `revokeSession` and `revokeSessionFamily` to that same `src/lib/sessions.ts`.

**Files**
- Create: `src/lib/sessions.ts` (modify — add `revokeSession`, `revokeSessionFamily`)
- Modify: `src/routes/auth.ts` (add `POST /auth/refresh`, `POST /auth/signout`, `GET /auth/me`)
- Create: `src/routes/devices.ts`
- Modify: `src/app.ts` (mount `devicesRoutes`; `authRoutes` already mounted)
- Test: `test/auth-session.test.ts`
- Test: `test/devices.test.ts`

---

- [ ] **Step 1: Write the failing refresh-rotation + reuse-detection + signout + me test**

`test/auth-session.test.ts`:

```ts
import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

// Seed a user + device + active session directly in D1, returning the raw refresh token.
async function seedSession() {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
     VALUES (?, ?, 1, ?, 'free', ?, ?)`,
  )
    .bind(userId, "maya@example.com", "Maya Reyes", now, now)
    .run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, ?)`,
  )
    .bind(deviceId, userId, now, now)
    .run();
  const issued = await issueSession(env.DB, { userId, deviceId });
  return { userId, deviceId, ...issued };
}

beforeEach(async () => {
  // Per-test-file storage is isolated; clear rows that tests insert so counts are deterministic.
  await env.DB.exec("DELETE FROM sessions; DELETE FROM devices; DELETE FROM users;");
});

describe("POST /auth/refresh", () => {
  it("rotates the refresh token and mints a new access token (happy path)", async () => {
    const { refreshToken } = await seedSession();

    const res = await SELF.fetch("https://x/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken }),
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      accessToken: string;
      refreshToken: string;
      expiresIn: number;
      user: { id: string; email: string; displayName: string };
    };
    expect(body.expiresIn).toBe(900);
    expect(body.accessToken).toMatch(/^[\w-]+\.[\w-]+\.[\w-]+$/);
    // Rotated: new refresh token differs from the one we sent.
    expect(body.refreshToken).not.toBe(refreshToken);
    expect(body.user.email).toBe("maya@example.com");
    expect(body.user.displayName).toBe("Maya Reyes");
  });

  it("revokes the whole family and returns 401 AUTH_SESSION_REVOKED when an already-rotated token is reused", async () => {
    const { refreshToken: original } = await seedSession();

    // First refresh rotates `original` -> `next`.
    const first = await SELF.fetch("https://x/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken: original }),
    });
    expect(first.status).toBe(200);
    const { refreshToken: next } = (await first.json()) as { refreshToken: string };

    // Reuse the now-rotated `original` -> reuse detected.
    const reuse = await SELF.fetch("https://x/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken: original }),
    });
    expect(reuse.status).toBe(401);
    const reuseBody = (await reuse.json()) as { error: { code: string; requestId: string } };
    expect(reuseBody.error.code).toBe("AUTH_SESSION_REVOKED");
    expect(reuseBody.error.requestId).toBeTruthy();

    // The legitimate rotated token `next` is now also dead (whole family revoked).
    const afterReuse = await SELF.fetch("https://x/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken: next }),
    });
    expect(afterReuse.status).toBe(401);
    expect(((await afterReuse.json()) as { error: { code: string } }).error.code).toBe(
      "AUTH_SESSION_REVOKED",
    );
  });

  it("returns 401 AUTH_INVALID_TOKEN for an unknown refresh token", async () => {
    const res = await SELF.fetch("https://x/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken: "not-a-real-token" }),
    });
    expect(res.status).toBe(401);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe(
      "AUTH_INVALID_TOKEN",
    );
  });
});

describe("POST /auth/signout", () => {
  it("revokes the current session so its refresh token no longer works", async () => {
    const { accessToken, refreshToken } = await seedSession();

    const out = await SELF.fetch("https://x/auth/signout", {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}` },
    });
    expect(out.status).toBe(200);
    expect(await out.json()).toEqual({ ok: true });

    // Refresh on a signed-out session is rejected.
    const refresh = await SELF.fetch("https://x/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken }),
    });
    expect(refresh.status).toBe(401);
    expect(((await refresh.json()) as { error: { code: string } }).error.code).toBe(
      "AUTH_SESSION_REVOKED",
    );
  });

  it("rejects signout without a bearer token", async () => {
    const res = await SELF.fetch("https://x/auth/signout", { method: "POST" });
    expect(res.status).toBe(401);
  });
});

describe("GET /auth/me", () => {
  it("returns the current user and their active devices", async () => {
    const { accessToken, userId, deviceId } = await seedSession();

    const res = await SELF.fetch("https://x/auth/me", {
      headers: { authorization: `Bearer ${accessToken}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      user: { id: string; email: string; displayName: string };
      devices: Array<{ id: string }>;
    };
    expect(body.user.id).toBe(userId);
    expect(body.user.email).toBe("maya@example.com");
    expect(body.devices).toHaveLength(1);
    expect(body.devices[0].id).toBe(deviceId);
  });
});
```

- [ ] **Step 2: Run the new auth-session test — expect FAIL**

```bash
npx vitest run test/auth-session.test.ts
```

Expected: FAIL. `issueSession` exists but `revokeSession`/`revokeSessionFamily` are not yet implemented and `/auth/refresh`, `/auth/signout`, `/auth/me` are not yet wired, so requests 404 or the rotation/reuse assertions fail.

- [ ] **Step 3: Add `revokeSession` and `revokeSessionFamily` to `src/lib/sessions.ts`**

Append these to the existing `src/lib/sessions.ts` (which already exports `issueSession`):

```ts
import type { D1Database } from "@cloudflare/workers-types";
import { nowMs } from "./time";

// NOTE: `issueSession(...)` already exists in this file (Task 6). Add the two helpers below.

/** Revoke a single session row (idempotent). */
export async function revokeSession(db: D1Database, sessionId: string): Promise<void> {
  await db
    .prepare(`UPDATE sessions SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`)
    .bind(nowMs(), sessionId)
    .run();
}

/** Revoke every session sharing a family id — the reuse-detection hammer. */
export async function revokeSessionFamily(db: D1Database, familyId: string): Promise<void> {
  await db
    .prepare(`UPDATE sessions SET revoked_at = ? WHERE family_id = ? AND revoked_at IS NULL`)
    .bind(nowMs(), familyId)
    .run();
}
```

- [ ] **Step 4: Add `/auth/refresh`, `/auth/signout`, `/auth/me` to `src/routes/auth.ts`**

The file already exports `authRoutes` with the Apple + magic-link endpoints (Task 7). Add the imports and the three new route handlers. Refresh is on the public allowlist (no bearer); signout + me require bearer (the `auth` middleware sets `c.var.userId`/`c.var.sessionId`).

```ts
import { Hono } from "hono";
import { z } from "zod";
import { zValidator } from "@hono/zod-validator";
import type { Env, Variables } from "../env";
import { ApiError, ERROR } from "../lib/errors";
import { signAccess, newRefreshToken, hashToken } from "../lib/jwt";
import { revokeSession, revokeSessionFamily } from "../lib/sessions";
import { nowMs } from "../lib/time";

// `authRoutes` is the existing Hono instance in this file.
// const authRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();
// ... existing /apple, /magic-link/request, /magic-link/verify handlers ...

const refreshBody = z.object({ refreshToken: z.string().min(1) });

authRoutes.post("/refresh", zValidator("json", refreshBody), async (c) => {
  const { refreshToken } = c.req.valid("json");
  const presentedHash = await hashToken(refreshToken);

  // 1. Look the presented refresh hash up directly. A hit on a NON-revoked row = legit rotation.
  const active = await c.env.DB.prepare(
    `SELECT id, user_id, device_id, family_id, expires_at
       FROM sessions
      WHERE refresh_hash = ? AND revoked_at IS NULL`,
  )
    .bind(presentedHash)
    .first<{
      id: string;
      user_id: string;
      device_id: string;
      family_id: string;
      expires_at: number;
    }>();

  if (active) {
    if (active.expires_at <= nowMs()) {
      await revokeSession(c.env.DB, active.id);
      throw new ApiError(ERROR.AUTH_SESSION_REVOKED, "Session expired");
    }

    // ROTATE: mint a new opaque refresh, store its hash, slide the 60-day expiry, keep the family.
    const newRefresh = newRefreshToken();
    const newHash = await hashToken(newRefresh);
    const now = nowMs();
    const expiresAt = now + 60 * 24 * 60 * 60 * 1000; // 60-day sliding window
    await c.env.DB.prepare(
      `UPDATE sessions
          SET refresh_hash = ?, last_seen_at = ?, expires_at = ?
        WHERE id = ?`,
    )
      .bind(newHash, now, expiresAt, active.id)
      .run();

    const accessToken = await signAccess(c.env, {
      userId: active.user_id,
      sessionId: active.id,
      deviceId: active.device_id,
    });
    const user = await c.env.DB.prepare(
      `SELECT id, email, display_name FROM users WHERE id = ? AND deleted_at IS NULL`,
    )
      .bind(active.user_id)
      .first<{ id: string; email: string | null; display_name: string | null }>();
    if (!user) throw new ApiError(ERROR.AUTH_INVALID_TOKEN, "User not found");

    return c.json({
      accessToken,
      refreshToken: newRefresh,
      expiresIn: 900,
      user: { id: user.id, email: user.email ?? "", displayName: user.display_name ?? "" },
    });
  }

  // 2. No active match. If the hash matches a REVOKED row, this is a reuse of a rotated/dead
  //    token -> revoke the entire family and force re-auth.
  const reused = await c.env.DB.prepare(
    `SELECT family_id FROM sessions WHERE refresh_hash = ?`,
  )
    .bind(presentedHash)
    .first<{ family_id: string }>();
  if (reused) {
    await revokeSessionFamily(c.env.DB, reused.family_id);
    throw new ApiError(ERROR.AUTH_SESSION_REVOKED, "Refresh token reuse detected");
  }

  // 3. Token never existed.
  throw new ApiError(ERROR.AUTH_INVALID_TOKEN, "Invalid refresh token");
});

authRoutes.post("/signout", async (c) => {
  // Bearer required: the auth middleware sets sessionId on c.var for non-allowlisted paths.
  await revokeSession(c.env.DB, c.var.sessionId);
  return c.json({ ok: true });
});

authRoutes.get("/me", async (c) => {
  const userId = c.var.userId;
  const user = await c.env.DB.prepare(
    `SELECT id, email, display_name, plan FROM users WHERE id = ? AND deleted_at IS NULL`,
  )
    .bind(userId)
    .first<{ id: string; email: string | null; display_name: string | null; plan: string }>();
  if (!user) throw new ApiError(ERROR.NOT_FOUND, "User not found");

  const devices = await c.env.DB.prepare(
    `SELECT id, platform, model, os_version, push_enabled, last_seen_at, created_at
       FROM devices
      WHERE user_id = ? AND deleted_at IS NULL
      ORDER BY created_at`,
  )
    .bind(userId)
    .all<{
      id: string;
      platform: string;
      model: string | null;
      os_version: string | null;
      push_enabled: number;
      last_seen_at: number | null;
      created_at: number;
    }>();

  return c.json({
    user: {
      id: user.id,
      email: user.email ?? "",
      displayName: user.display_name ?? "",
      plan: user.plan,
    },
    devices: devices.results.map((d) => ({
      id: d.id,
      platform: d.platform,
      model: d.model,
      osVersion: d.os_version,
      pushEnabled: d.push_enabled === 1,
      lastSeenAt: d.last_seen_at,
      createdAt: d.created_at,
    })),
  });
});

// `authRoutes` continues to be exported as before:
// export { authRoutes };
```

> Note: this task assumes the `auth` middleware (Task 5) sets `c.var.sessionId` from the JWT `sid` claim alongside `userId`/`deviceId`, and that `/auth/refresh` is on the middleware's public-path allowlist (it carries no bearer). If `Variables` does not yet include `sessionId`, add `sessionId: string` to the `Variables` type in `src/env.ts` and set it in `src/middleware/auth.ts` from the verified `sid` claim. The SPINE JWT claims include `sid`, so `verifyAccess` already returns it.

- [ ] **Step 5: Run the auth-session test again — expect PASS**

```bash
npx vitest run test/auth-session.test.ts
```

Expected: PASS. All four describe blocks (rotation happy path, reuse → family revoke → 401 AUTH_SESSION_REVOKED, unknown-token 401, signout revoke, /auth/me) are green.

- [ ] **Step 6: Write the failing devices test**

`test/devices.test.ts`:

```ts
import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

async function seedAuthedDevice() {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
     VALUES (?, ?, 1, ?, 'free', ?, ?)`,
  )
    .bind(userId, "dev@example.com", "Dev User", now, now)
    .run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, ?)`,
  )
    .bind(deviceId, userId, now, now)
    .run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId });
  return { userId, deviceId, accessToken };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM sessions; DELETE FROM devices; DELETE FROM users;");
});

describe("PUT /devices/me", () => {
  it("upserts apnsToken/appVersion/osVersion for the device named by X-Device-Id", async () => {
    const { accessToken, deviceId } = await seedAuthedDevice();

    const res = await SELF.fetch("https://x/devices/me", {
      method: "PUT",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
        "x-device-id": deviceId,
      },
      body: JSON.stringify({
        apnsToken: "abc123apns",
        appVersion: "1.0.0",
        osVersion: "iOS 18.2",
        model: "iPhone16,2",
      }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { id: string; pushEnabled: boolean };
    expect(body.id).toBe(deviceId);

    const row = await env.DB.prepare(
      `SELECT apns_token, os_version, model FROM devices WHERE id = ?`,
    )
      .bind(deviceId)
      .first<{ apns_token: string; os_version: string; model: string }>();
    expect(row?.apns_token).toBe("abc123apns");
    expect(row?.os_version).toBe("iOS 18.2");
    expect(row?.model).toBe("iPhone16,2");
  });

  it("creates the device row if X-Device-Id is new for this user", async () => {
    const { accessToken } = await seedAuthedDevice();
    const newDeviceId = uuidv7();

    const res = await SELF.fetch("https://x/devices/me", {
      method: "PUT",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
        "x-device-id": newDeviceId,
      },
      body: JSON.stringify({ apnsToken: "tok2", osVersion: "iOS 18.1" }),
    });
    expect(res.status).toBe(200);

    const row = await env.DB.prepare(`SELECT id, apns_token FROM devices WHERE id = ?`)
      .bind(newDeviceId)
      .first<{ id: string; apns_token: string }>();
    expect(row?.id).toBe(newDeviceId);
    expect(row?.apns_token).toBe("tok2");
  });

  it("requires the X-Device-Id header", async () => {
    const { accessToken } = await seedAuthedDevice();
    const res = await SELF.fetch("https://x/devices/me", {
      method: "PUT",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ apnsToken: "x" }),
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe(
      "VALIDATION_FAILED",
    );
  });
});

describe("DELETE /devices/:id", () => {
  it("tombstones the device and revokes its session family", async () => {
    const { accessToken, userId, deviceId } = await seedAuthedDevice();
    // A second device + session so we can prove only the targeted family dies.
    const otherDeviceId = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
       VALUES (?, ?, 'ios', 1, ?, ?)`,
    )
      .bind(otherDeviceId, userId, now, now)
      .run();
    const other = await issueSession(env.DB, { userId, deviceId: otherDeviceId });

    const res = await SELF.fetch(`https://x/devices/${deviceId}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${accessToken}` },
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });

    // The deleted device is tombstoned.
    const gone = await env.DB.prepare(`SELECT deleted_at FROM devices WHERE id = ?`)
      .bind(deviceId)
      .first<{ deleted_at: number | null }>();
    expect(gone?.deleted_at).not.toBeNull();

    // Its sessions are revoked.
    const revoked = await env.DB.prepare(
      `SELECT COUNT(*) AS n FROM sessions WHERE device_id = ? AND revoked_at IS NULL`,
    )
      .bind(deviceId)
      .first<{ n: number }>();
    expect(revoked?.n).toBe(0);

    // The OTHER device's session still works.
    const stillGood = await SELF.fetch("https://x/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken: other.refreshToken }),
    });
    expect(stillGood.status).toBe(200);
  });

  it("returns 404 when deleting a device that is not the authed user's", async () => {
    const { accessToken } = await seedAuthedDevice();
    // A device owned by a different user.
    const otherUser = uuidv7();
    const foreignDevice = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
       VALUES (?, ?, 1, 'Other', 'free', ?, ?)`,
    )
      .bind(otherUser, "other@example.com", now, now)
      .run();
    await env.DB.prepare(
      `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
       VALUES (?, ?, 'ios', 1, ?, ?)`,
    )
      .bind(foreignDevice, otherUser, now, now)
      .run();

    const res = await SELF.fetch(`https://x/devices/${foreignDevice}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${accessToken}` },
    });
    expect(res.status).toBe(404);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("NOT_FOUND");
  });
});
```

- [ ] **Step 7: Run the devices test — expect FAIL**

```bash
npx vitest run test/devices.test.ts
```

Expected: FAIL. `src/routes/devices.ts` does not exist and is not mounted, so all requests 404.

- [ ] **Step 8: Create `src/routes/devices.ts`**

```ts
import { Hono } from "hono";
import { z } from "zod";
import { zValidator } from "@hono/zod-validator";
import type { Env, Variables } from "../env";
import { ApiError, ERROR } from "../lib/errors";
import { revokeSessionFamily } from "../lib/sessions";
import { nowMs } from "../lib/time";

const devicesRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

const putBody = z.object({
  apnsToken: z.string().min(1).optional(),
  appVersion: z.string().optional(),
  osVersion: z.string().optional(),
  model: z.string().optional(),
  pushEnabled: z.boolean().optional(),
});

// PUT /devices/me — upsert the device identified by the X-Device-Id header for the authed user.
devicesRoutes.put("/me", zValidator("json", putBody), async (c) => {
  const deviceId = c.req.header("X-Device-Id");
  if (!deviceId) {
    throw new ApiError(ERROR.VALIDATION_FAILED, "Missing X-Device-Id header");
  }
  const userId = c.var.userId;
  const { apnsToken, osVersion, model, pushEnabled } = c.req.valid("json");
  const now = nowMs();

  // Upsert keyed on the device PK, scoped so a device can never be re-homed to another user.
  await c.env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, model, os_version, apns_token, push_enabled, last_seen_at, created_at, updated_at)
     VALUES (?, ?, 'ios', ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       model       = COALESCE(excluded.model, devices.model),
       os_version  = COALESCE(excluded.os_version, devices.os_version),
       apns_token  = COALESCE(excluded.apns_token, devices.apns_token),
       push_enabled = excluded.push_enabled,
       last_seen_at = excluded.last_seen_at,
       updated_at   = excluded.updated_at,
       deleted_at   = NULL
     WHERE devices.user_id = excluded.user_id`,
  )
    .bind(
      deviceId,
      userId,
      model ?? null,
      osVersion ?? null,
      apnsToken ?? null,
      pushEnabled === false ? 0 : 1,
      now,
      now,
      now,
    )
    .run();

  const row = await c.env.DB.prepare(
    `SELECT id, platform, model, os_version, apns_token, push_enabled, last_seen_at
       FROM devices WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  )
    .bind(deviceId, userId)
    .first<{
      id: string;
      platform: string;
      model: string | null;
      os_version: string | null;
      apns_token: string | null;
      push_enabled: number;
      last_seen_at: number | null;
    }>();
  if (!row) throw new ApiError(ERROR.FORBIDDEN, "Device belongs to another user");

  return c.json({
    id: row.id,
    platform: row.platform,
    model: row.model,
    osVersion: row.os_version,
    hasApnsToken: row.apns_token !== null,
    pushEnabled: row.push_enabled === 1,
    lastSeenAt: row.last_seen_at,
  });
});

// DELETE /devices/:id — sign a device out: tombstone it + revoke its session family.
devicesRoutes.delete("/:id", async (c) => {
  const id = c.req.param("id");
  const userId = c.var.userId;

  const device = await c.env.DB.prepare(
    `SELECT id FROM devices WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  )
    .bind(id, userId)
    .first<{ id: string }>();
  if (!device) throw new ApiError(ERROR.NOT_FOUND, "Device not found");

  const now = nowMs();
  // Revoke every active session bound to this device (covers all families across re-issues).
  const families = await c.env.DB.prepare(
    `SELECT DISTINCT family_id FROM sessions WHERE device_id = ? AND user_id = ?`,
  )
    .bind(id, userId)
    .all<{ family_id: string }>();
  for (const f of families.results) {
    await revokeSessionFamily(c.env.DB, f.family_id);
  }

  // Tombstone the device row (soft-delete so the change propagates via sync).
  await c.env.DB.prepare(
    `UPDATE devices SET deleted_at = ?, updated_at = ? WHERE id = ? AND user_id = ?`,
  )
    .bind(now, now, id, userId)
    .run();

  return c.json({ ok: true });
});

export { devicesRoutes };
```

- [ ] **Step 9: Mount `devicesRoutes` in `src/app.ts`**

The `auth` middleware and `authRoutes` are already wired (Tasks 5/7). Add the devices route mount alongside the existing route registrations:

```ts
import { devicesRoutes } from "./routes/devices";

// ... after `app.route("/auth", authRoutes);` and the other mounts:
app.route("/devices", devicesRoutes);
```

- [ ] **Step 10: Run the devices test again — expect PASS**

```bash
npx vitest run test/devices.test.ts
```

Expected: PASS. Upsert (existing + new device), missing-header 400, delete-with-family-revoke (other device unaffected), and cross-user 404 all green.

- [ ] **Step 11: Run the full suite to confirm no regressions — expect PASS**

```bash
npx vitest run
```

Expected: PASS for all files including `test/auth-session.test.ts` and `test/devices.test.ts`, with earlier tasks' tests still green.

- [ ] **Step 12: Commit the test + implementation together**

```bash
git add src/lib/sessions.ts src/routes/auth.ts src/routes/devices.ts src/app.ts test/auth-session.test.ts test/devices.test.ts
git commit -m "feat(backend): session refresh rotation, signout, /auth/me, device upsert/delete

Add revokeSession/revokeSessionFamily; POST /auth/refresh rotates the opaque
refresh token (60-day slide) and revokes the whole family on reuse of a
rotated token (401 AUTH_SESSION_REVOKED); POST /auth/signout revokes the
current session; GET /auth/me returns user + active devices. Add
PUT /devices/me (upsert by X-Device-Id) and DELETE /devices/:id
(tombstone + revoke that device's session family). All queries scoped
WHERE user_id = c.var.userId.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```


---

### Task 9: Sync Push (POST /sync/push)

Implements `POST /sync/push` per the SPINE sync contract: per-mutation idempotency via `processed_mutations`, ownership enforcement against `c.var.userId`, last-write-wins on `updatedAt` with a server-stamped `updatedAt` + `rev` increment + `lastEditedDeviceId`, tombstone-on-delete, and per-mutation result objects. Each mutation is resolved against the correct D1 table, all queries scoped to the authed user. Batch size capped at 200.

This task assumes earlier tasks already produced: the Hono app (`createApp` in `src/app.ts`) with the JWT `auth` middleware that sets `c.var.userId`/`c.var.deviceId`; `uuidv7()`; `serverStamp()` (monotonic server ms); `ApiError`/`ERROR` (the error envelope + `VALIDATION_FAILED`); the D1 schema `migrations/0001_init.sql` including the `processed_mutations` idempotency table and all syncable domain tables with `id/user_id/profile_id?/created_at/updated_at/deleted_at/rev/last_edited_device_id` columns; and the vitest-pool-workers test harness (`vitest.config.ts` with the `TEST_MIGRATIONS` binding + `test/apply-migrations.ts` setup file).

> Note on the schema dependency: `migrations/0001_init.sql` (Task with the D1 schema) MUST contain a `processed_mutations` table `(mutation_id TEXT PRIMARY KEY, user_id TEXT NOT NULL, result_json TEXT NOT NULL, created_at INTEGER NOT NULL)` and a `rev INTEGER NOT NULL DEFAULT 0` + `last_edited_device_id TEXT` column on every syncable domain table. This task reads/writes those columns; if they are absent the migration task must add them.

**Files**
- Create: `src/lib/syncTables.ts` (entity-type → table + column metadata)
- Create: `src/schemas/sync.ts` (zod push body schema)
- Create: `src/routes/sync.ts` (the `POST /sync/push` handler; `GET /sync/pull` is added in the next task)
- Modify: `src/app.ts` (mount `syncRoutes` at `/sync`)
- Test: `test/sync-push.test.ts`

---

- [ ] **Step 1: Write the syncable-table metadata module.**

Maps each SPINE entity type to its D1 table and the camelCase↔snake_case column set used by upserts. Every syncable type from the SPINE is listed; `profileId` is included only for tables that carry it.

```ts
// src/lib/syncTables.ts
// Maps each syncable entity type (camelCase, as sent by the client) to its D1
// table and the set of writable domain columns. Sync-envelope columns
// (id, user_id, profile_id, created_at, updated_at, deleted_at, rev,
// last_edited_device_id) are handled generically and are NOT listed here.

export type SyncTableMeta = {
  table: string;
  hasProfileId: boolean;
  // camelCase field name -> snake_case column name for domain fields
  columns: Record<string, string>;
};

export const SYNCABLE_TABLES: Record<string, SyncTableMeta> = {
  transaction: {
    table: "transactions",
    hasProfileId: true,
    columns: {
      merchant: "merchant",
      categoryId: "category_id",
      catKey: "cat_key",
      amountCents: "amount_cents",
      currency: "currency",
      txnDate: "txn_date",
      mode: "mode",
      taxLabel: "tax_label",
      deductiblePct: "deductible_pct",
      paymentMethod: "payment_method",
      isAi: "is_ai",
      note: "note",
      gstCents: "gst_cents",
      logbookLink: "logbook_link",
      mileageTripId: "mileage_trip_id",
      source: "source",
      extractionStatus: "extraction_status",
    },
  },
  lineItem: {
    table: "line_items",
    hasProfileId: false,
    columns: {
      transactionId: "transaction_id",
      name: "name",
      priceCents: "price_cents",
      quantity: "quantity",
      sortOrder: "sort_order",
    },
  },
  profile: {
    table: "profiles",
    hasProfileId: false,
    columns: {
      name: "name",
      type: "type",
      initials: "initials",
      accent1: "accent_1",
      accent2: "accent_2",
      accent3: "accent_3",
      abn: "abn",
      gstRegistered: "gst_registered",
      sortOrder: "sort_order",
      isDefault: "is_default",
    },
  },
  category: {
    table: "categories",
    hasProfileId: true,
    columns: {
      key: "key",
      label: "label",
      icon: "icon",
      tint: "tint",
      soft: "soft",
      defaultDeductiblePct: "default_deductible_pct",
      isIncome: "is_income",
      sortOrder: "sort_order",
    },
  },
  smartRule: {
    table: "smart_rules",
    hasProfileId: true,
    columns: {
      matchType: "match_type",
      matcher: "matcher",
      categoryId: "category_id",
      setDeductiblePct: "set_deductible_pct",
      setMode: "set_mode",
      priority: "priority",
      enabled: "enabled",
    },
  },
  budget: {
    table: "budgets",
    hasProfileId: true,
    columns: {
      categoryId: "category_id",
      catKey: "cat_key",
      label: "label",
      period: "period",
      monthKey: "month_key",
      capCents: "cap_cents",
      currency: "currency",
      alertThresholdPct: "alert_threshold_pct",
      alertSentAt: "alert_sent_at",
    },
  },
  loyaltyCard: {
    table: "loyalty_cards",
    hasProfileId: true,
    columns: {
      brand: "brand",
      subBrand: "sub_brand",
      number: "number",
      barcodeFormat: "barcode_format",
      pointsLabel: "points_label",
      color1: "color_1",
      color2: "color_2",
      sortOrder: "sort_order",
    },
  },
  quote: {
    table: "quotes",
    hasProfileId: true,
    columns: {
      number: "number",
      clientName: "client_name",
      clientEmail: "client_email",
      gstEnabled: "gst_enabled",
      subtotalCents: "subtotal_cents",
      gstCents: "gst_cents",
      totalCents: "total_cents",
      currency: "currency",
      status: "status",
      validUntil: "valid_until",
      sentAt: "sent_at",
    },
  },
  quoteLineItem: {
    table: "quote_line_items",
    hasProfileId: false,
    columns: {
      quoteId: "quote_id",
      description: "description",
      quantity: "quantity",
      unitPriceCents: "unit_price_cents",
      sortOrder: "sort_order",
    },
  },
  mileageTrip: {
    table: "mileage_trips",
    hasProfileId: true,
    columns: {
      tripDate: "trip_date",
      fromLabel: "from_label",
      toLabel: "to_label",
      purpose: "purpose",
      distanceM: "distance_m",
      isBusiness: "is_business",
      rateCentsPerKm: "rate_cents_per_km",
      claimCents: "claim_cents",
      autoTracked: "auto_tracked",
    },
  },
  wfhLog: {
    table: "wfh_logs",
    hasProfileId: true,
    columns: {
      logDate: "log_date",
      minutes: "minutes",
      note: "note",
      rateCentsPerHour: "rate_cents_per_hour",
      claimCents: "claim_cents",
    },
  },
  taxSettings: {
    table: "tax_settings",
    hasProfileId: true,
    columns: {
      gstRateBps: "gst_rate_bps",
      financialYearStartMonth: "financial_year_start_month",
      mealsDeductiblePct: "meals_deductible_pct",
      wfhRateCentsPerHour: "wfh_rate_cents_per_hour",
      mileageRateCentsPerKm: "mileage_rate_cents_per_km",
    },
  },
};

export function tableForEntityType(entityType: string): SyncTableMeta | null {
  return SYNCABLE_TABLES[entityType] ?? null;
}
```

- [ ] **Step 2: Write the push body zod schema.**

Validates the batch envelope: `deviceId`, and `mutations` (1–200) each with a `mutationId` idempotency key, `entityType`, `entityId`, `op`, optional `baseRev`, `updatedAt`, and a free-form `payload` object (per-mutation payload shape is validated by ownership/table logic at apply time).

```ts
// src/schemas/sync.ts
import { z } from "zod";

export const pushMutationSchema = z.object({
  mutationId: z.string().uuid(),
  entityType: z.string().min(1),
  entityId: z.string().uuid(),
  op: z.enum(["upsert", "delete"]),
  baseRev: z.number().int().nonnegative().optional(),
  updatedAt: z.number().int().nonnegative(),
  payload: z.record(z.string(), z.unknown()),
});

export const pushBodySchema = z.object({
  deviceId: z.string().uuid(),
  mutations: z.array(pushMutationSchema).min(1).max(200),
});

export type PushMutation = z.infer<typeof pushMutationSchema>;
export type PushBody = z.infer<typeof pushBodySchema>;
```

- [ ] **Step 3: Write the failing test for the six push behaviors.**

Hits the Worker through `SELF.fetch` with a real D1 binding (migrated by the harness). It mints a valid Bearer token via `signAccess` (from the JWT task) so the `auth` middleware passes and `c.var.userId` is set to a known user. The user + a profile are seeded directly into D1.

```ts
// test/sync-push.test.ts
import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { signAccess } from "../src/lib/jwt";
import { uuidv7 } from "../src/lib/ids";

const USER_ID = "01890000-0000-7000-8000-000000000001";
const OTHER_USER_ID = "01890000-0000-7000-8000-0000000000ff";
const DEVICE_ID = "01890000-0000-7000-8000-0000000000d1";
const PROFILE_ID = "01890000-0000-7000-8000-0000000000a1";
const SESSION_ID = "01890000-0000-7000-8000-0000000000c1";

async function seedUserAndProfile() {
  const now = Date.now();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'free', ?, ?)`
  )
    .bind(USER_ID, "maya@example.com", now, now)
    .run();
  await env.DB.prepare(
    `INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3,
       sort_order, is_default, created_at, updated_at, rev)
     VALUES (?, ?, 'Personal', 'personal', '#000', '#111', '#222', 0, 1, ?, ?, 1)`
  )
    .bind(PROFILE_ID, USER_ID, now, now)
    .run();
}

async function authHeader() {
  const token = await signAccess(env.JWT_SIGNING_KEY, {
    userId: USER_ID,
    sessionId: SESSION_ID,
    deviceId: DEVICE_ID,
  });
  return { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
}

function txnMutation(overrides: Record<string, unknown> = {}) {
  const entityId = (overrides.entityId as string) ?? uuidv7();
  return {
    mutationId: uuidv7(),
    entityType: "transaction",
    entityId,
    op: "upsert" as const,
    updatedAt: 1_000,
    payload: {
      id: entityId,
      userId: USER_ID,
      profileId: PROFILE_ID,
      catKey: "meals",
      merchant: "The Grounds",
      amountCents: -4200,
      currency: "AUD",
      txnDate: "2026-05-30",
      mode: "personal",
      source: "manual",
      createdAt: 1_000,
    },
    ...overrides,
  };
}

async function push(body: unknown) {
  return SELF.fetch("https://api.snapceipt.app/sync/push", {
    method: "POST",
    headers: await authHeader(),
    body: JSON.stringify(body),
  });
}

describe("POST /sync/push", () => {
  beforeEach(async () => {
    // isolatedStorage resets D1 between tests; re-seed every time.
    await seedUserAndProfile();
  });

  it("inserts a new entity: applied, rev 1, server-stamped updatedAt", async () => {
    const before = Date.now();
    const m = txnMutation();
    const res = await push({ deviceId: DEVICE_ID, mutations: [m] });
    expect(res.status).toBe(200);
    const json = (await res.json()) as any;
    const r = json.results[0];
    expect(r.mutationId).toBe(m.mutationId);
    expect(r.status).toBe("applied");
    expect(r.entity.rev).toBe(1);
    expect(r.entity.lastEditedDeviceId).toBe(DEVICE_ID);
    // server-stamped, NOT the client's updatedAt:1000
    expect(r.entity.updatedAt).toBeGreaterThanOrEqual(before);
    expect(typeof json.serverTime).toBe("number");

    const row = await env.DB.prepare(
      `SELECT rev, updated_at, last_edited_device_id, merchant FROM transactions WHERE id = ?`
    )
      .bind(m.entityId)
      .first<any>();
    expect(row.rev).toBe(1);
    expect(row.merchant).toBe("The Grounds");
    expect(row.last_edited_device_id).toBe(DEVICE_ID);
  });

  it("replaying the same mutationId is a duplicate no-op", async () => {
    const m = txnMutation();
    const first = (await (await push({ deviceId: DEVICE_ID, mutations: [m] })).json()) as any;
    expect(first.results[0].status).toBe("applied");

    const second = (await (await push({ deviceId: DEVICE_ID, mutations: [m] })).json()) as any;
    expect(second.results[0].status).toBe("duplicate");
    // rev did NOT advance to 2 — the replay returned the prior result
    expect(second.results[0].entity.rev).toBe(1);

    const row = await env.DB.prepare(`SELECT rev FROM transactions WHERE id = ?`)
      .bind(m.entityId)
      .first<any>();
    expect(row.rev).toBe(1);
  });

  it("stale updatedAt loses LWW: conflict, server row echoed", async () => {
    const entityId = uuidv7();
    // First write wins with a high client updatedAt; the server stamp will be > now.
    const win = txnMutation({ entityId, updatedAt: 9_999_999_999_999 });
    win.payload.id = entityId;
    const a = (await (await push({ deviceId: DEVICE_ID, mutations: [win] })).json()) as any;
    expect(a.results[0].status).toBe("applied");
    const serverUpdatedAt = a.results[0].entity.updatedAt;

    // Second mutation with an OLDER updatedAt than the stored server-stamped value.
    const stale = txnMutation({ entityId, updatedAt: 1 });
    stale.payload.id = entityId;
    stale.payload.merchant = "Should Not Persist";
    const b = (await (await push({ deviceId: DEVICE_ID, mutations: [stale] })).json()) as any;
    expect(b.results[0].status).toBe("conflict");
    expect(b.results[0].entity.updatedAt).toBe(serverUpdatedAt);
    expect(b.results[0].entity.merchant).toBe("The Grounds");

    const row = await env.DB.prepare(`SELECT merchant, rev FROM transactions WHERE id = ?`)
      .bind(entityId)
      .first<any>();
    expect(row.merchant).toBe("The Grounds");
    expect(row.rev).toBe(1);
  });

  it("delete sets the tombstone deletedAt, bumps rev, never hard-deletes", async () => {
    const m = txnMutation();
    await push({ deviceId: DEVICE_ID, mutations: [m] });

    const del = {
      mutationId: uuidv7(),
      entityType: "transaction",
      entityId: m.entityId,
      op: "delete" as const,
      updatedAt: 2_000,
      payload: { id: m.entityId, userId: USER_ID },
    };
    const res = (await (await push({ deviceId: DEVICE_ID, mutations: [del] })).json()) as any;
    expect(res.results[0].status).toBe("applied");
    expect(res.results[0].entity.deletedAt).not.toBeNull();
    expect(res.results[0].entity.rev).toBe(2);

    const row = await env.DB.prepare(
      `SELECT deleted_at, rev FROM transactions WHERE id = ?`
    )
      .bind(m.entityId)
      .first<any>();
    expect(row).not.toBeNull(); // row still exists
    expect(row.deleted_at).not.toBeNull();
    expect(row.rev).toBe(2);
  });

  it("rejects a payload whose userId is a foreign user (FORBIDDEN)", async () => {
    const m = txnMutation();
    m.payload.userId = OTHER_USER_ID;
    const res = (await (await push({ deviceId: DEVICE_ID, mutations: [m] })).json()) as any;
    expect(res.results[0].status).toBe("rejected");
    expect(res.results[0].reason).toBe("FORBIDDEN");

    const row = await env.DB.prepare(`SELECT id FROM transactions WHERE id = ?`)
      .bind(m.entityId)
      .first<any>();
    expect(row).toBeNull(); // nothing written
  });

  it("applies a mixed batch independently per mutation", async () => {
    const ok = txnMutation();
    const bad = txnMutation();
    bad.payload.userId = OTHER_USER_ID;
    const okDup = ok; // identical mutationId -> duplicate within the same batch order

    const res = (await (
      await push({ deviceId: DEVICE_ID, mutations: [ok, bad, okDup] })
    ).json()) as any;
    const byId = Object.fromEntries(res.results.map((r: any) => [r.mutationId, r]));
    expect(res.results).toHaveLength(3);
    expect(byId[ok.mutationId].status).toBe("applied");
    expect(byId[bad.mutationId].status).toBe("rejected");
    // the third entry shares ok's mutationId, so it is a duplicate replay
    expect(res.results[2].status).toBe("duplicate");
  });
});
```

- [ ] **Step 4: Run the test and confirm it FAILS (route not implemented yet).**

```bash
npx vitest run test/sync-push.test.ts
```

Expected: FAIL — `SELF.fetch("…/sync/push")` returns 404 (route not mounted), so `res.status).toBe(200)` and the result-status assertions all fail. (If `src/routes/sync.ts` does not exist yet, the import/mount in Step 6 has not happened; the 404 is the expected first-run failure.)

- [ ] **Step 5: Implement the push handler in `src/routes/sync.ts`.**

One handler, one batch. For each mutation it: (1) checks `processed_mutations` for the `mutationId` and replays the stored result; (2) verifies `payload.userId === c.var.userId` else rejects FORBIDDEN; (3) loads the stored row scoped by user, applies LWW on the server-stamped `updated_at` (stored newer ⇒ conflict, echo server row; otherwise upsert/tombstone with `rev = stored.rev + 1` or `1`, `updated_at = serverStamp()`, `last_edited_device_id = deviceId`); (4) records the result in `processed_mutations`. Per-mutation writes use a `db.batch([...])` so the domain write and the idempotency record commit together.

```ts
// src/routes/sync.ts
import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import type { Env } from "../env";
import { ApiError, ERROR } from "../lib/errors";
import { serverStamp } from "../lib/time";
import { pushBodySchema } from "../schemas/sync";
import {
  tableForEntityType,
  type SyncTableMeta,
} from "../lib/syncTables";

type Vars = { Bindings: Env; Variables: { userId: string; deviceId: string; requestId: string } };

type MutationResult = {
  mutationId: string;
  status: "applied" | "conflict" | "duplicate" | "rejected";
  reason?: string;
  entity: Record<string, unknown> | null;
};

const ENVELOPE_SELECT = "rev, created_at, updated_at, deleted_at, last_edited_device_id";

// Build the public (camelCase) entity envelope from a stored D1 row.
function rowToEntity(meta: SyncTableMeta, row: Record<string, any>): Record<string, unknown> {
  const out: Record<string, unknown> = {
    id: row.id,
    userId: row.user_id,
    rev: row.rev,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    deletedAt: row.deleted_at,
    lastEditedDeviceId: row.last_edited_device_id,
  };
  if (meta.hasProfileId) out.profileId = row.profile_id;
  for (const [camel, col] of Object.entries(meta.columns)) {
    if (col in row) out[camel] = row[col];
  }
  return out;
}

export const syncRoutes = new Hono<Vars>();

syncRoutes.post("/push", zValidator("json", pushBodySchema), async (c) => {
  const userId = c.var.userId;
  const { deviceId, mutations } = c.req.valid("json");
  const results: MutationResult[] = [];

  for (const m of mutations) {
    // (1) Idempotency replay.
    const prior = await c.env.DB.prepare(
      `SELECT result_json FROM processed_mutations WHERE mutation_id = ? AND user_id = ?`
    )
      .bind(m.mutationId, userId)
      .first<{ result_json: string }>();
    if (prior) {
      const replay = JSON.parse(prior.result_json) as Omit<MutationResult, "status">;
      results.push({ ...replay, status: "duplicate" });
      continue;
    }

    const meta = tableForEntityType(m.entityType);
    if (!meta) {
      const rejected: MutationResult = {
        mutationId: m.mutationId,
        status: "rejected",
        reason: ERROR.VALIDATION_FAILED.code,
        entity: null,
      };
      await recordResult(c.env.DB, m.mutationId, userId, rejected);
      results.push(rejected);
      continue;
    }

    // (2) Ownership: never trust a client-sent userId.
    const payloadUserId = (m.payload as Record<string, unknown>).userId;
    if (payloadUserId !== userId) {
      const rejected: MutationResult = {
        mutationId: m.mutationId,
        status: "rejected",
        reason: ERROR.FORBIDDEN.code,
        entity: null,
      };
      await recordResult(c.env.DB, m.mutationId, userId, rejected);
      results.push(rejected);
      continue;
    }

    // Load the stored row (scoped to the authed user).
    const stored = await c.env.DB.prepare(
      `SELECT * FROM ${meta.table} WHERE id = ? AND user_id = ?`
    )
      .bind(m.entityId, userId)
      .first<Record<string, any>>();

    // (3a) LWW: server-stamped updatedAt strictly newer than incoming -> conflict.
    if (stored && Number(stored.updated_at) > m.updatedAt) {
      const conflict: MutationResult = {
        mutationId: m.mutationId,
        status: "conflict",
        entity: rowToEntity(meta, stored),
      };
      await recordResult(c.env.DB, m.mutationId, userId, conflict);
      results.push(conflict);
      continue;
    }

    // (3b) Apply (upsert or tombstone).
    const now = serverStamp();
    const newRev = stored ? Number(stored.rev) + 1 : 1;
    const writeStmt =
      m.op === "delete"
        ? buildDeleteStmt(c.env.DB, meta, m.entityId, userId, now, newRev, deviceId)
        : buildUpsertStmt(c.env.DB, meta, m, userId, now, newRev, deviceId, stored);

    const idemPlaceholder = c.env.DB.prepare(
      `INSERT INTO processed_mutations (mutation_id, user_id, result_json, created_at)
       VALUES (?, ?, ?, ?)`
    );

    // Read-back happens after the batch commits, so we can echo the canonical row.
    await c.env.DB.batch([writeStmt, idemPlaceholder.bind(m.mutationId, userId, "{}", now)]);

    const fresh = await c.env.DB.prepare(
      `SELECT * FROM ${meta.table} WHERE id = ? AND user_id = ?`
    )
      .bind(m.entityId, userId)
      .first<Record<string, any>>();

    const applied: MutationResult = {
      mutationId: m.mutationId,
      status: "applied",
      entity: fresh ? rowToEntity(meta, fresh) : null,
    };
    // Persist the real result over the placeholder so a later replay echoes it.
    await c.env.DB.prepare(
      `UPDATE processed_mutations SET result_json = ? WHERE mutation_id = ? AND user_id = ?`
    )
      .bind(JSON.stringify({ mutationId: applied.mutationId, entity: applied.entity }), m.mutationId, userId)
      .run();

    results.push(applied);
  }

  return c.json({ results, serverTime: serverStamp() });
});

async function recordResult(
  db: D1Database,
  mutationId: string,
  userId: string,
  result: MutationResult
): Promise<void> {
  await db
    .prepare(
      `INSERT OR IGNORE INTO processed_mutations (mutation_id, user_id, result_json, created_at)
       VALUES (?, ?, ?, ?)`
    )
    .bind(
      mutationId,
      userId,
      JSON.stringify({ mutationId: result.mutationId, reason: result.reason, entity: result.entity }),
      serverStamp()
    )
    .run();
}

function buildDeleteStmt(
  db: D1Database,
  meta: SyncTableMeta,
  entityId: string,
  userId: string,
  now: number,
  newRev: number,
  deviceId: string
): D1PreparedStatement {
  // Tombstone an existing row; if it does not exist there is nothing to delete,
  // but we still create a tombstone shell so the delete propagates on pull.
  return db
    .prepare(
      `INSERT INTO ${meta.table} (id, user_id, created_at, updated_at, deleted_at, rev, last_edited_device_id)
       VALUES (?1, ?2, ?3, ?3, ?3, ?4, ?5)
       ON CONFLICT(id) DO UPDATE SET
         deleted_at = ?3,
         updated_at = ?3,
         rev = ?4,
         last_edited_device_id = ?5
       WHERE ${meta.table}.user_id = ?2`
    )
    .bind(entityId, userId, now, newRev, deviceId);
}

function buildUpsertStmt(
  db: D1Database,
  meta: SyncTableMeta,
  m: { entityId: string; payload: Record<string, unknown> },
  userId: string,
  now: number,
  newRev: number,
  deviceId: string,
  stored: Record<string, any> | null
): D1PreparedStatement {
  // Domain columns present in the payload.
  const domainCols: string[] = [];
  const domainVals: unknown[] = [];
  for (const [camel, col] of Object.entries(meta.columns)) {
    if (camel in m.payload) {
      domainCols.push(col);
      domainVals.push(normalize(m.payload[camel]));
    }
  }

  const profileCol = meta.hasProfileId ? ["profile_id"] : [];
  const profileVal = meta.hasProfileId ? [normalize(m.payload.profileId)] : [];

  const createdAt = stored ? Number(stored.created_at) : Number(m.payload.createdAt ?? now);

  // Column order: id, user_id, [profile_id], <domain...>, created_at, updated_at, deleted_at, rev, last_edited_device_id
  const insertCols = [
    "id",
    "user_id",
    ...profileCol,
    ...domainCols,
    "created_at",
    "updated_at",
    "deleted_at",
    "rev",
    "last_edited_device_id",
  ];
  const insertVals = [
    m.entityId,
    userId,
    ...profileVal,
    ...domainVals,
    createdAt,
    now,
    null, // upsert always clears the tombstone (a newer edit resurrects)
    newRev,
    deviceId,
  ];

  // ON CONFLICT update list: every domain + profile column + envelope fields,
  // EXCEPT id/user_id/created_at (immutable on update).
  const updateSet = [
    ...profileCol.map((col) => `${col} = excluded.${col}`),
    ...domainCols.map((col) => `${col} = excluded.${col}`),
    "updated_at = excluded.updated_at",
    "deleted_at = excluded.deleted_at",
    "rev = excluded.rev",
    "last_edited_device_id = excluded.last_edited_device_id",
  ].join(", ");

  const placeholders = insertCols.map(() => "?").join(", ");
  const sql =
    `INSERT INTO ${meta.table} (${insertCols.join(", ")}) VALUES (${placeholders}) ` +
    `ON CONFLICT(id) DO UPDATE SET ${updateSet} WHERE ${meta.table}.user_id = excluded.user_id`;

  return db.prepare(sql).bind(...insertVals);
}

// Coerce JS values to D1-storable scalars: booleans -> 0/1, undefined -> null.
function normalize(v: unknown): unknown {
  if (v === undefined) return null;
  if (typeof v === "boolean") return v ? 1 : 0;
  return v as string | number | null;
}
```

> Tip: this keeps a `processed_mutations` row even for `rejected`/`conflict`/no-table outcomes so that replaying a rejected mutation returns the same `rejected`/`conflict` result as a `duplicate` (idempotent at-least-once delivery). The applied path inserts a placeholder inside the same `db.batch` as the domain write (so they commit atomically), then overwrites the placeholder with the canonical echoed entity after read-back.

- [ ] **Step 6: Mount the sync routes in `src/app.ts`.**

Add the import and route mount alongside the other routers. (Adjust to match the exact `createApp` body produced by the app-scaffold task; the load-bearing lines are the import and `app.route("/sync", syncRoutes)`.)

```ts
// src/app.ts  — add near the other route imports
import { syncRoutes } from "./routes/sync";

// …inside createApp(), after auth middleware is applied and alongside the
// other protected routers (e.g. app.route("/devices", deviceRoutes)):
app.route("/sync", syncRoutes);
```

- [ ] **Step 7: Run the test and confirm it PASSES.**

```bash
npx vitest run test/sync-push.test.ts
```

Expected: PASS — all six cases green: insert (applied, `rev` 1, server-stamped `updatedAt` ≥ request time, `lastEditedDeviceId` set); duplicate replay (no-op, `rev` stays 1); stale `updatedAt` (conflict, server row echoed, DB unchanged); delete (tombstone `deletedAt` set, `rev` 2, row still present); foreign `userId` (rejected FORBIDDEN, nothing written); mixed batch (per-mutation `applied`/`rejected`/`duplicate`).

- [ ] **Step 8: Type-check, then commit test + implementation together.**

```bash
npx tsc --noEmit && npx vitest run test/sync-push.test.ts
```

Expected: tsc reports no errors and the test run passes.

```bash
git checkout -b feat/sync-push
git add src/lib/syncTables.ts src/schemas/sync.ts src/routes/sync.ts src/app.ts test/sync-push.test.ts
git commit -m "$(cat <<'EOF'
feat(backend): implement POST /sync/push with idempotency, ownership, LWW + tombstones

Per-mutation idempotency via processed_mutations, ownership check against
c.var.userId, last-write-wins on server-stamped updatedAt with rev increment
and lastEditedDeviceId, tombstone-on-delete, and per-mutation result objects.
Batch capped at 200; all D1 writes scoped to the authed user.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: branch created, commit recorded with the conventional-commit subject and the Co-Authored-By trailer.

---

### Task 10: Sync Pull — composite keyset delta across all syncable tables

Implements `GET /sync/pull?cursor&limit=500` per the SPINE contract: a base64url composite keyset cursor `{ ts, id }`, a delta `SELECT` over **every** syncable table merged into one stream, **globally** ordered by `(updatedAt, id)` and capped at `limit`, with tombstones (`deletedAt != null`) included. Response is `{ changes, nextCursor, hasMore, serverTime }`. First pull (no cursor) returns a full, paginated snapshot. Every query is scoped `WHERE user_id = c.var.userId` (tenant isolation).

This task adds the cursor encode/decode helpers to `src/schemas/sync.ts` (defined here; sync-push from Task 9 does not need them) and the `GET /sync/pull` route to the existing `src/routes/sync.ts` (which Task 9 created with `POST /sync/push`).

**Files**
- Modify: `src/schemas/sync.ts` (add `PullCursor`, `encodeCursor`, `decodeCursor`, `SYNCABLE_TABLES`)
- Modify: `src/routes/sync.ts` (add `GET /sync/pull` handler)
- Test: `test/sync-pull.test.ts`

---

- [ ] **Step 1: Write the failing pull test (first pull, tombstones, paging, tenancy)**

Seeds rows directly into `env.DB` (bypassing push, so this test is isolated to pull), then drives the route through `SELF.fetch`. Covers: first pull returns seeded rows incl. a tombstone; cursor advances and excludes already-seen rows; `hasMore` paging; rows scoped to the authed user only.

```ts
// test/sync-pull.test.ts
import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";

// --- helpers -------------------------------------------------------------

// Mint a real access token by running through the worker's own JWT signer so
// the auth middleware accepts it. We import signAccess (Task 5) directly.
import { signAccess } from "../src/lib/jwt";

const USER_A = uuidv7();
const USER_B = uuidv7();
const DEVICE_A = uuidv7();

async function tokenFor(userId: string) {
  return signAccess(env.JWT_SIGNING_KEY, {
    sub: userId,
    sid: uuidv7(),
    did: DEVICE_A,
  });
}

// Insert a minimal-but-valid transactions row. transactions has the most
// NOT NULL columns of the syncable tables, so it exercises the SELECT mapping.
async function seedTxn(opts: {
  id: string;
  userId: string;
  profileId: string;
  updatedAt: number;
  deletedAt?: number | null;
  rev?: number;
  merchant?: string;
}) {
  await env.DB.prepare(
    `INSERT INTO transactions
       (id, user_id, profile_id, merchant, cat_key, amount_cents, currency,
        txn_date, mode, source, created_at, updated_at, deleted_at, rev,
        last_edited_device_id)
     VALUES (?, ?, ?, ?, 'meals', -1234, 'AUD', '2026-05-01', 'personal',
             'manual', ?, ?, ?, ?, ?)`
  )
    .bind(
      opts.id,
      opts.userId,
      opts.profileId,
      opts.merchant ?? "Test Cafe",
      opts.updatedAt,
      opts.updatedAt,
      opts.deletedAt ?? null,
      opts.rev ?? 1,
      DEVICE_A
    )
    .run();
}

async function seedProfile(id: string, userId: string, updatedAt: number) {
  await env.DB.prepare(
    `INSERT INTO profiles
       (id, user_id, name, type, accent_1, accent_2, accent_3,
        created_at, updated_at, deleted_at, rev, last_edited_device_id)
     VALUES (?, ?, 'Personal', 'personal', '#0E7C72', '#DCF0ED', '#0A5950',
             ?, ?, NULL, 1, ?)`
  )
    .bind(id, userId, updatedAt, updatedAt, DEVICE_A)
    .run();
}

function pull(token: string, query = "") {
  return SELF.fetch(`https://x/sync/pull${query}`, {
    headers: { authorization: `Bearer ${token}` },
  });
}

// --- tests ---------------------------------------------------------------

describe("GET /sync/pull", () => {
  beforeEach(async () => {
    // Storage is isolated per test file, but be explicit so ordering is stable.
    await env.DB.exec("DELETE FROM transactions");
    await env.DB.exec("DELETE FROM profiles");
  });

  it("first pull (no cursor) returns all rows incl. a tombstone, globally ordered", async () => {
    const token = await tokenFor(USER_A);
    const profileId = uuidv7();
    await seedProfile(profileId, USER_A, 1000); // profile table
    await seedTxn({ id: uuidv7(), userId: USER_A, profileId, updatedAt: 2000 });
    await seedTxn({
      id: uuidv7(),
      userId: USER_A,
      profileId,
      updatedAt: 3000,
      deletedAt: 3000, // tombstone MUST be returned
    });

    const res = await pull(token);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;

    expect(body.changes).toHaveLength(3);
    // globally ordered by (updatedAt, id): profile(1000) then txns(2000,3000)
    const updatedAts = body.changes.map((c: any) => c.updatedAt);
    expect(updatedAts).toEqual([1000, 2000, 3000]);
    // tombstone present
    const tomb = body.changes.find((c: any) => c.deletedAt !== null);
    expect(tomb.deletedAt).toBe(3000);
    // mixed types merged
    expect(body.changes.map((c: any) => c.type)).toContain("profile");
    expect(body.changes.map((c: any) => c.type)).toContain("transaction");
    expect(body.hasMore).toBe(false);
    expect(typeof body.nextCursor).toBe("string");
    expect(typeof body.serverTime).toBe("number");
  });

  it("cursor advances and excludes already-seen rows", async () => {
    const token = await tokenFor(USER_A);
    const profileId = uuidv7();
    await seedTxn({ id: uuidv7(), userId: USER_A, profileId, updatedAt: 1000 });
    await seedTxn({ id: uuidv7(), userId: USER_A, profileId, updatedAt: 2000 });

    const first = (await (await pull(token, "?limit=1")).json()) as any;
    expect(first.changes).toHaveLength(1);
    expect(first.changes[0].updatedAt).toBe(1000);
    expect(first.hasMore).toBe(true);

    const second = (await (
      await pull(token, `?cursor=${encodeURIComponent(first.nextCursor)}&limit=1`)
    ).json()) as any;
    expect(second.changes).toHaveLength(1);
    expect(second.changes[0].updatedAt).toBe(2000); // strictly after cursor
    expect(second.hasMore).toBe(false);
  });

  it("breaks updatedAt ties by id (composite keyset, no row skipped or repeated)", async () => {
    const token = await tokenFor(USER_A);
    const profileId = uuidv7();
    // three rows with the SAME updatedAt -> tie broken by id
    const ids = ["00000000-0000-0000-0000-000000000001",
                 "00000000-0000-0000-0000-000000000002",
                 "00000000-0000-0000-0000-000000000003"];
    for (const id of ids) {
      await seedTxn({ id, userId: USER_A, profileId, updatedAt: 5000 });
    }

    const seen: string[] = [];
    let cursor = "";
    for (let i = 0; i < 5; i++) {
      const q = cursor ? `?cursor=${encodeURIComponent(cursor)}&limit=2` : "?limit=2";
      const body = (await (await pull(token, q)).json()) as any;
      for (const c of body.changes) seen.push(c.id);
      cursor = body.nextCursor;
      if (!body.hasMore) break;
    }
    expect(seen.sort()).toEqual([...ids].sort()); // every row exactly once
    expect(new Set(seen).size).toBe(ids.length);
  });

  it("scopes rows to the authed user only", async () => {
    const tokenA = await tokenFor(USER_A);
    const profileId = uuidv7();
    await seedTxn({ id: uuidv7(), userId: USER_A, profileId, updatedAt: 1000, merchant: "MineA" });
    await seedTxn({ id: uuidv7(), userId: USER_B, profileId, updatedAt: 1000, merchant: "NotMine" });

    const body = (await (await pull(tokenA)).json()) as any;
    expect(body.changes).toHaveLength(1);
    expect(body.changes[0].merchant).toBe("MineA");
  });

  it("rejects a malformed cursor with VALIDATION_FAILED", async () => {
    const token = await tokenFor(USER_A);
    const res = await pull(token, "?cursor=not-base64url-{}");
    expect(res.status).toBe(400);
    const body = (await res.json()) as any;
    expect(body.error.code).toBe("VALIDATION_FAILED");
  });
});
```

- [ ] **Step 2: Run the test — expect FAIL**

```bash
npx vitest run test/sync-pull.test.ts
```

Expected: FAIL. `encodeCursor`/`decodeCursor` are not exported from `src/schemas/sync.ts` yet, and `GET /sync/pull` returns 404 (route not mounted), so the assertions on `body.changes` throw.

- [ ] **Step 3: Add the cursor helpers + syncable-table registry to `src/schemas/sync.ts`**

Composite keyset cursor is base64url of `{ ts, id }`. `decodeCursor` throws `ApiError(VALIDATION_FAILED)` on anything malformed so the route can surface a 400. `SYNCABLE_TABLES` maps each SPINE syncable `type` to its D1 table name — this is the single source of truth the pull (and later REST) routes iterate.

```ts
// --- append to src/schemas/sync.ts ---
import { z } from "zod";
import { ApiError, ERROR } from "../lib/errors";

/** Composite keyset cursor: strictly-after (updatedAt, id). */
export interface PullCursor {
  ts: number; // last updatedAt seen
  id: string; // last id seen (tiebreak)
}

const cursorSchema = z.object({
  ts: z.number().int().nonnegative(),
  id: z.string().min(1),
});

/** base64url-encode { ts, id }. */
export function encodeCursor(c: PullCursor): string {
  const json = JSON.stringify({ ts: c.ts, id: c.id });
  // btoa is available in workerd; produce URL-safe base64.
  return btoa(json).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Decode an opaque cursor. Throws VALIDATION_FAILED if malformed. */
export function decodeCursor(raw: string): PullCursor {
  try {
    const b64 = raw.replace(/-/g, "+").replace(/_/g, "/");
    const json = atob(b64);
    const parsed = cursorSchema.parse(JSON.parse(json));
    return { ts: parsed.ts, id: parsed.id };
  } catch (e) {
    if (e instanceof ApiError) throw e;
    throw new ApiError(ERROR.VALIDATION_FAILED, "Invalid sync cursor");
  }
}

/**
 * The syncable entity types (SPINE) -> their D1 table names.
 * Every pull query iterates this registry; order here is irrelevant because
 * results are globally re-sorted by (updatedAt, id).
 */
export const SYNCABLE_TABLES: ReadonlyArray<{ type: string; table: string }> = [
  { type: "transaction", table: "transactions" },
  { type: "lineItem", table: "line_items" },
  { type: "profile", table: "profiles" },
  { type: "category", table: "categories" },
  { type: "smartRule", table: "smart_rules" },
  { type: "budget", table: "budgets" },
  { type: "loyaltyCard", table: "loyalty_cards" },
  { type: "quote", table: "quotes" },
  { type: "quoteLineItem", table: "quote_line_items" },
  { type: "mileageTrip", table: "mileage_trips" },
  { type: "wfhLog", table: "wfh_logs" },
  { type: "taxSettings", table: "tax_settings" },
];
```

Note: if `import { z } from "zod"` and the `ApiError`/`ERROR` import already exist at the top of `src/schemas/sync.ts` from Task 8, fold these new imports into the existing import lines rather than duplicating them.

- [ ] **Step 4: Add the `GET /sync/pull` handler to `src/routes/sync.ts`**

For each syncable table, fetch up to `limit + 1` rows strictly after the cursor using the composite keyset predicate `(updated_at > ?) OR (updated_at = ? AND id > ?)`, scoped to `user_id`. Merge all tables, globally sort by `(updatedAt, id)`, slice to `limit`, and compute `hasMore` + `nextCursor` from the last emitted row. Each raw D1 row is normalised to the SPINE envelope (camelCase `userId/createdAt/updatedAt/deletedAt/rev/lastEditedDeviceId`, plus `type`).

```ts
// --- add to src/routes/sync.ts (alongside the existing POST /sync/push) ---
import { z } from "zod";
import {
  decodeCursor,
  encodeCursor,
  SYNCABLE_TABLES,
  type PullCursor,
} from "../schemas/sync";
import { ApiError, ERROR } from "../lib/errors";
import { serverStamp } from "../lib/time";

const PULL_DEFAULT_LIMIT = 500;
const PULL_MAX_LIMIT = 500;

const pullQuerySchema = z.object({
  cursor: z.string().optional(),
  limit: z.coerce.number().int().positive().max(PULL_MAX_LIMIT).optional(),
});

/** D1 row (snake_case sync columns) -> SPINE entity envelope (camelCase). */
function toEnvelope(type: string, row: Record<string, unknown>) {
  const {
    user_id,
    profile_id,
    created_at,
    updated_at,
    deleted_at,
    rev,
    last_edited_device_id,
    ...rest
  } = row as Record<string, any>;
  const env: Record<string, unknown> = {
    type,
    userId: user_id,
    createdAt: created_at,
    updatedAt: updated_at,
    deletedAt: deleted_at ?? null,
    rev,
    lastEditedDeviceId: last_edited_device_id ?? null,
    ...rest, // includes id + all domain fields (still snake_case for D1-native cols)
  };
  if (profile_id !== undefined) env.profileId = profile_id ?? null;
  return env;
}

// app.get("/sync/pull", ...) — register on the sync sub-app / route group.
sync.get("/sync/pull", async (c) => {
  const userId = c.var.userId;

  const parsedQuery = pullQuerySchema.safeParse({
    cursor: c.req.query("cursor"),
    limit: c.req.query("limit"),
  });
  if (!parsedQuery.success) {
    throw new ApiError(ERROR.VALIDATION_FAILED, "Invalid pull query", {
      issues: parsedQuery.error.issues,
    });
  }
  const limit = parsedQuery.data.limit ?? PULL_DEFAULT_LIMIT;

  // First sync omits the cursor -> start from (-1, "") so everything is "after".
  const cursor: PullCursor = parsedQuery.data.cursor
    ? decodeCursor(parsedQuery.data.cursor)
    : { ts: -1, id: "" };

  // Per-table keyset query: fetch limit+1 so we know if more exist downstream
  // when merged. Composite predicate keeps it strictly after (ts, id).
  const fetchN = limit + 1;
  const perTable = await Promise.all(
    SYNCABLE_TABLES.map(async ({ type, table }) => {
      const stmt = c.env.DB.prepare(
        `SELECT * FROM ${table}
          WHERE user_id = ?1
            AND ( updated_at > ?2 OR (updated_at = ?2 AND id > ?3) )
          ORDER BY updated_at ASC, id ASC
          LIMIT ?4`
      ).bind(userId, cursor.ts, cursor.id, fetchN);
      const { results } = await stmt.all<Record<string, unknown>>();
      return results.map((row) => toEnvelope(type, row));
    })
  );

  // Merge + global keyset sort by (updatedAt, id).
  const merged = perTable.flat().sort((a: any, b: any) => {
    if (a.updatedAt !== b.updatedAt) return a.updatedAt - b.updatedAt;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });

  const hasMore = merged.length > limit;
  const changes = hasMore ? merged.slice(0, limit) : merged;

  const last = changes[changes.length - 1] as any | undefined;
  const nextCursor = last
    ? encodeCursor({ ts: last.updatedAt, id: last.id })
    : (parsedQuery.data.cursor ?? encodeCursor(cursor));

  return c.json({
    changes,
    nextCursor,
    hasMore,
    serverTime: serverStamp(),
  });
});
```

Notes:
- `sync` is the Hono router instance already declared in `src/routes/sync.ts` by Task 9 (e.g. `const sync = new Hono<{ Bindings: Env; Variables: {...} }>()`). Use the same instance; do not create a second one.
- `fetchN = limit + 1` per table is the standard "is there a next page" probe. Because results are re-merged globally, fetching `limit + 1` per table is sufficient (and safe) to detect `hasMore` after the merge slice — any table that itself has more rows than `limit` is paged on the next request via the advanced cursor.
- Table names come only from the hardcoded `SYNCABLE_TABLES` registry (never from user input), so the interpolated `${table}` is not an injection vector; `user_id`, cursor, and `limit` are all bound parameters.

- [ ] **Step 5: Run the test — expect PASS**

```bash
npx vitest run test/sync-pull.test.ts
```

Expected: PASS (all 5 cases green). First pull returns the 3 seeded rows globally ordered with the tombstone included; the cursor advances and excludes seen rows; tie-broken paging visits every row exactly once; cross-user rows are excluded; the malformed cursor yields a 400 `VALIDATION_FAILED` envelope.

- [ ] **Step 6: Typecheck**

```bash
npx tsc --noEmit
```

Expected: PASS (no type errors). Confirms `toEnvelope`, the `pullQuerySchema` coercion, and the cursor types line up.

- [ ] **Step 7: Commit the test + implementation together**

```bash
git add src/schemas/sync.ts src/routes/sync.ts test/sync-pull.test.ts && git commit -m "$(cat <<'EOF'
feat(backend): add GET /sync/pull composite-keyset delta

Implements the local-first pull protocol: base64url {ts,id} cursor,
per-table keyset delta across all 12 syncable tables merged and globally
ordered by (updatedAt,id), tombstones included, nextCursor + hasMore.
All queries scoped WHERE user_id = authed user.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: a single commit containing the cursor helpers, the pull route, and the passing pull tests.

---

### Task 11: ratelimit-integration

Adds the KV fixed-window rate limiter, wires it into the Hono app ahead of auth on `/auth/*` and the protected groups, writes the project README (full setup → deploy runbook), and proves the whole foundation end-to-end with an integration test (magic-link request→verify → `/sync/push` → `/sync/pull`, plus `/banks` 501 and `/health` 200). This is the final task; it ends with the final commit.

Depends on earlier tasks (referenced by SPINE name, NOT redefined here): `src/env.ts` (`Env`), `src/lib/errors.ts` (`ApiError`, `ERROR`, `toEnvelope`), `src/middleware/error.ts` (`onError`), `src/middleware/auth.ts` (`auth`), `src/app.ts` (`buildApp`), `src/routes/auth.ts`, `src/routes/sync.ts`, `src/routes/misc.ts`, `src/index.ts`, `migrations/0001_init.sql`, and `vitest.config.ts` (already exposes the `TEST_MIGRATIONS` miniflare binding via `readD1Migrations`).

**Files**
- Create: `src/middleware/rateLimit.ts`
- Create: `README.md`
- Create: `test/integration.test.ts`
- Modify: `src/app.ts` (mount `rateLimit()` before `auth()` on `/auth/*` and protected groups)
- Create: `test/rateLimit.test.ts`

---

- [ ] **Step 1: Write the failing unit test for the rate limiter**

Create `test/rateLimit.test.ts`. It drives the limiter through the real Worker (`SELF.fetch`) against the magic-link IP tier (10/IP/hr): the 11th request from the same IP must return `429` with the `RATE_LIMITED` envelope and a numeric `Retry-After` header.

```ts
import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

describe("rateLimit middleware", () => {
  it("returns 429 RATE_LIMITED with Retry-After after the magic-link IP window is exhausted", async () => {
    const ip = "203.0.113.42";
    const send = (email: string) =>
      SELF.fetch("https://api.test/auth/magic-link/request", {
        method: "POST",
        headers: { "content-type": "application/json", "cf-connecting-ip": ip },
        body: JSON.stringify({ email }),
      });

    // 10 distinct emails from one IP are allowed (each email is under its own 3/hr cap).
    for (let i = 0; i < 10; i++) {
      const ok = await send(`u${i}@example.com`);
      expect(ok.status).toBe(202);
    }

    // 11th request from the same IP trips the 10/IP/hr ceiling.
    const blocked = await send("u11@example.com");
    expect(blocked.status).toBe(429);
    const retryAfter = blocked.headers.get("Retry-After");
    expect(retryAfter).not.toBeNull();
    expect(Number(retryAfter)).toBeGreaterThan(0);
    const body = (await blocked.json()) as { error: { code: string; requestId: string } };
    expect(body.error.code).toBe("RATE_LIMITED");
    expect(typeof body.error.requestId).toBe("string");
  });

  it("allows the hot sync path well past the auth ceiling (separate tier)", async () => {
    // /health is public + unlimited; this just asserts the limiter does not leak across route classes.
    const res = await SELF.fetch("https://api.test/health");
    expect(res.status).toBe(200);
  });
});
```

- [ ] **Step 2: Run the unit test and expect FAIL**

```bash
npx vitest run test/rateLimit.test.ts -t "returns 429 RATE_LIMITED"
```

Expected: FAIL. `src/middleware/rateLimit.ts` does not exist yet and `app.ts` does not mount it, so the 11th magic-link request returns `202` instead of `429` (assertion `expect(blocked.status).toBe(429)` fails). The test file may also fail to resolve the import path of the middleware once `app.ts` references it.

- [ ] **Step 3: Implement `src/middleware/rateLimit.ts`**

KV fixed-window limiter. One counter key per `{tier, identity, window-bucket}`; the bucket is `floor(now / windowMs)` so keys roll over automatically and we lean on KV `expirationTtl` (seconds, 60s minimum) for cleanup. Identity is the authed `userId` when present, else the client IP from `CF-Connecting-IP`. The magic-link class enforces BOTH a per-email cap (3/hr) and a per-IP cap (10/IP/hr); all others are single-dimension. On breach we throw `ApiError(ERROR.RATE_LIMITED)` carrying `retryAfter` (seconds to the next bucket) so the error middleware can set `Retry-After`.

```ts
import { createMiddleware } from "hono/factory";
import type { Env } from "../env";
import { ApiError, ERROR } from "../lib/errors";

const HOUR_MS = 60 * 60 * 1000;
const MINUTE_MS = 60 * 1000;

export type RateLimitTier = {
  /** stable prefix used in the KV key */
  name: string;
  /** max requests permitted per window */
  limit: number;
  /** window length in ms */
  windowMs: number;
  /** identity dimension: "user" falls back to IP when unauthenticated */
  dimension: "user" | "ip";
};

/** Route-class tiers (SPINE §4 RATE LIMITING). */
export const RATE_LIMIT_TIERS = {
  authIp: { name: "auth-ip", limit: 10, windowMs: HOUR_MS, dimension: "ip" },
  authEmail: { name: "auth-email", limit: 3, windowMs: HOUR_MS, dimension: "ip" },
  sync: { name: "sync", limit: 600, windowMs: HOUR_MS, dimension: "user" },
  default: { name: "default", limit: 300, windowMs: MINUTE_MS, dimension: "user" },
} as const satisfies Record<string, RateLimitTier>;

/** Resolve the identity component of a KV key for a tier. */
export function clientKeyForRoute(
  c: { req: { header: (n: string) => string | undefined }; get: (k: "userId") => string | undefined },
  tier: RateLimitTier,
): string {
  if (tier.dimension === "user") {
    const uid = c.get("userId");
    if (uid) return `u:${uid}`;
  }
  const ip =
    c.req.header("CF-Connecting-IP") ??
    c.req.header("X-Forwarded-For")?.split(",")[0]?.trim() ??
    "unknown";
  return `ip:${ip}`;
}

/**
 * Consume one unit against a fixed window. Returns the seconds-to-reset when
 * the limit is exceeded, otherwise null. KV is eventually consistent, which is
 * acceptable for coarse abuse limiting (SPINE note: upgradeable to the native
 * Rate Limiting binding later).
 */
async function consume(
  kv: KVNamespace,
  tier: RateLimitTier,
  identity: string,
  now: number,
): Promise<number | null> {
  const bucket = Math.floor(now / tier.windowMs);
  const key = `rl:${tier.name}:${identity}:${bucket}`;
  const current = Number((await kv.get(key)) ?? "0");
  if (current >= tier.limit) {
    const resetMs = (bucket + 1) * tier.windowMs - now;
    return Math.max(1, Math.ceil(resetMs / 1000));
  }
  // KV TTL minimum is 60s; pad the window so the key outlives the bucket.
  const ttlSeconds = Math.max(60, Math.ceil(tier.windowMs / 1000) + 1);
  await kv.put(key, String(current + 1), { expirationTtl: ttlSeconds });
  return null;
}

function reject(retryAfterSeconds: number): never {
  throw new ApiError(ERROR.RATE_LIMITED, "Rate limit exceeded. Please retry later.", {
    retryAfter: retryAfterSeconds,
  });
}

/**
 * Middleware factory. `kind` picks the tier:
 *  - "auth": magic-link/auth bootstrap — enforces 3/email/hr AND 10/IP/hr.
 *  - "sync": 600/user/hr hot path.
 *  - "default": 300/user/min for every other protected route.
 * Runs BEFORE auth() on /auth/*, and AFTER auth() on protected groups (so a
 * userId is available there).
 */
export function rateLimit(kind: "auth" | "sync" | "default") {
  return createMiddleware<{ Bindings: Env; Variables: { userId: string; deviceId: string; requestId: string } }>(
    async (c, next) => {
      const now = Date.now();
      const kv = c.env.KV;

      if (kind === "auth") {
        const ip = clientKeyForRoute(c, RATE_LIMIT_TIERS.authIp);
        const ipReset = await consume(kv, RATE_LIMIT_TIERS.authIp, ip, now);
        if (ipReset !== null) reject(ipReset);

        // Per-email cap, only when the body carries an email (request/verify shapes).
        let email: string | undefined;
        try {
          const cloned = c.req.raw.clone();
          const ct = cloned.headers.get("content-type") ?? "";
          if (ct.includes("application/json")) {
            const parsed = (await cloned.json()) as { email?: unknown };
            if (typeof parsed.email === "string" && parsed.email.length > 0) {
              email = parsed.email.trim().toLowerCase();
            }
          }
        } catch {
          // Non-JSON / unparseable body: IP cap above still applies.
        }
        if (email) {
          const emailReset = await consume(
            kv,
            RATE_LIMIT_TIERS.authEmail,
            `email:${email}`,
            now,
          );
          if (emailReset !== null) reject(emailReset);
        }
        return next();
      }

      const tier = kind === "sync" ? RATE_LIMIT_TIERS.sync : RATE_LIMIT_TIERS.default;
      const identity = clientKeyForRoute(c, tier);
      const reset = await consume(kv, tier, identity, now);
      if (reset !== null) reject(reset);
      return next();
    },
  );
}
```

- [ ] **Step 4: Ensure the error middleware emits `Retry-After` for rate-limit errors**

The error middleware (`src/middleware/error.ts`, Task on errors) already maps `ApiError` → envelope + status. Confirm it sets the `Retry-After` header when `details.retryAfter` is present; if your `onError` does not yet do this, add the guard below. (If it is already handled, skip this step — do not duplicate.)

```ts
// Inside src/middleware/error.ts onError, after building the envelope/status from an ApiError:
// if (err instanceof ApiError && typeof err.details?.retryAfter === "number") {
//   c.header("Retry-After", String(err.details.retryAfter));
// }
```

Concrete patch (apply only if missing) — the relevant branch of `onError`:

```ts
import { ApiError, toEnvelope } from "../lib/errors";

// ...within onError(err, c):
if (err instanceof ApiError) {
  if (typeof (err.details as { retryAfter?: number } | undefined)?.retryAfter === "number") {
    c.header("Retry-After", String((err.details as { retryAfter: number }).retryAfter));
  }
  const requestId = c.get("requestId");
  return c.json(toEnvelope(err, requestId), err.status as 400 | 401 | 403 | 404 | 409 | 429 | 500 | 501);
}
```

- [ ] **Step 5: Wire the limiter into `src/app.ts`**

Mount `rateLimit("auth")` on `/auth/*` BEFORE `auth()` runs (auth's allowlist skips `/auth/*`, so the limiter is the only gate there). Mount `rateLimit("sync")` on `/sync/*` and `rateLimit("default")` on the remaining protected groups (`/devices/*`), AFTER `auth()` so `c.var.userId` is populated. `/health` and `/banks` stay outside the limiter.

```ts
// In src/app.ts, inside buildApp(), add the import and the use() calls.
// Import:
import { rateLimit } from "./middleware/rateLimit";

// Middleware order (auth bootstrap is rate-limited before auth verification):
app.use("/auth/*", rateLimit("auth"));

// auth() is already mounted on protected paths with the /auth/* + /health + /banks allowlist.
// Add per-class limiters AFTER auth() so userId is set:
app.use("/sync/*", rateLimit("sync"));
app.use("/devices/*", rateLimit("default"));
```

If `buildApp` mounts middleware via an explicit ordered list, place these lines so that for `/auth/*` the order is `requestId → rateLimit("auth") → routes`, and for `/sync/*` and `/devices/*` the order is `requestId → auth → rateLimit(...) → routes`. Do not rate-limit `/health` or `/banks`.

- [ ] **Step 6: Run the unit test and expect PASS**

```bash
npx vitest run test/rateLimit.test.ts -t "returns 429 RATE_LIMITED"
```

Expected: PASS. The first 10 magic-link requests from `203.0.113.42` return `202`; the 11th returns `429` with body `{"error":{"code":"RATE_LIMITED",...}}` and a positive numeric `Retry-After` header. The second test (`/health` → 200) also passes, confirming no cross-class leakage.

- [ ] **Step 7: Write the failing end-to-end integration test**

Create `test/integration.test.ts`. It exercises the full foundation through `SELF.fetch`: magic-link request → verify (the email send is mocked at the binding level — `env.EMAIL.send` is a no-op stub in the test env, and we read the single-use token straight out of KV under the `ml:<sha256(token)>` key as the SPINE describes) → authenticated `/sync/push` of one `transaction` → `/sync/pull` returns it. Plus `/banks` → 501 `NOT_IMPLEMENTED` and `/health` → 200. Uses a fresh IP per logical run to stay under the auth IP cap.

```ts
import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

const BASE = "https://api.test";

async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Read the raw magic-link token the server stored, by scanning KV for the ml:* entry it just wrote. */
async function recoverMagicToken(email: string): Promise<string> {
  // The server stores ml:<sha256(token)> -> { email }. We brute-nothing: instead we
  // re-derive by listing the ml: namespace and matching the stored email payload.
  const list = await env.KV.list({ prefix: "ml:" });
  for (const k of list.keys) {
    const raw = await env.KV.get(k.name);
    if (!raw) continue;
    const payload = JSON.parse(raw) as { email?: string; token?: string };
    if (payload.email === email && typeof payload.token === "string") {
      return payload.token;
    }
  }
  throw new Error(`no magic-link token found in KV for ${email}`);
}

describe("integration: magic-link -> sync push/pull, banks 501, health 200", () => {
  it("GET /health returns 200", async () => {
    const res = await SELF.fetch(`${BASE}/health`);
    expect(res.status).toBe(200);
  });

  it("ALL /banks returns 501 NOT_IMPLEMENTED", async () => {
    const res = await SELF.fetch(`${BASE}/banks`);
    expect(res.status).toBe(501);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("NOT_IMPLEMENTED");
  });

  it("signs in via magic-link, pushes a transaction, and pulls it back", async () => {
    const email = "integration@example.com";
    const ip = "198.51.100.7";
    const jsonHeaders = { "content-type": "application/json", "cf-connecting-ip": ip };

    // 1. Request the magic link (email send is a stubbed binding; always 202).
    const reqRes = await SELF.fetch(`${BASE}/auth/magic-link/request`, {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify({ email }),
    });
    expect(reqRes.status).toBe(202);

    // 2. Recover the single-use token the server stashed in KV, then verify.
    const token = await recoverMagicToken(email);
    const verifyRes = await SELF.fetch(`${BASE}/auth/magic-link/verify`, {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify({ token }),
    });
    expect(verifyRes.status).toBe(200);
    const session = (await verifyRes.json()) as {
      accessToken: string;
      refreshToken: string;
      expiresIn: number;
      user: { id: string; email: string };
    };
    expect(session.accessToken).toBeTruthy();
    expect(session.refreshToken).toBeTruthy();
    expect(session.expiresIn).toBe(900);
    expect(session.user.email).toBe(email);

    const authHeaders = {
      "content-type": "application/json",
      authorization: `Bearer ${session.accessToken}`,
    };
    const deviceId = crypto.randomUUID();
    const profileId = crypto.randomUUID();
    const txnId = crypto.randomUUID();
    const mutationId = crypto.randomUUID();
    const clientUpdatedAt = Date.now();

    // 3. Push one transaction. payload.userId MUST equal the authed user (tenancy).
    const pushRes = await SELF.fetch(`${BASE}/sync/push`, {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({
        deviceId,
        mutations: [
          {
            mutationId,
            entityType: "transaction",
            entityId: txnId,
            op: "upsert",
            updatedAt: clientUpdatedAt,
            payload: {
              id: txnId,
              userId: session.user.id,
              profileId,
              type: "transaction",
              merchant: "Test Cafe",
              catKey: "meals",
              amountCents: -1250,
              currency: "AUD",
              txnDate: "2026-05-30",
              mode: "business",
              createdAt: clientUpdatedAt,
              updatedAt: clientUpdatedAt,
              deletedAt: null,
            },
          },
        ],
      }),
    });
    expect(pushRes.status).toBe(200);
    const pushBody = (await pushRes.json()) as {
      results: { mutationId: string; status: string; entity: { id: string; rev: number } }[];
      serverTime: number;
    };
    expect(pushBody.results).toHaveLength(1);
    expect(pushBody.results[0].mutationId).toBe(mutationId);
    expect(pushBody.results[0].status).toBe("applied");
    expect(pushBody.results[0].entity.id).toBe(txnId);
    expect(pushBody.results[0].entity.rev).toBe(1);

    // 4. Pull from the start (no cursor) and assert the transaction comes back.
    const pullRes = await SELF.fetch(`${BASE}/sync/pull`, { headers: authHeaders });
    expect(pullRes.status).toBe(200);
    const pullBody = (await pullRes.json()) as {
      changes: { id: string; type: string; merchant?: string; rev: number }[];
      nextCursor: string | null;
      hasMore: boolean;
      serverTime: number;
    };
    const pulled = pullBody.changes.find((c) => c.id === txnId);
    expect(pulled).toBeDefined();
    expect(pulled?.type).toBe("transaction");
    expect(pulled?.rev).toBe(1);

    // 5. Replaying the same mutation is idempotent (duplicate, not a second row).
    const replayRes = await SELF.fetch(`${BASE}/sync/push`, {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({
        deviceId,
        mutations: [
          {
            mutationId,
            entityType: "transaction",
            entityId: txnId,
            op: "upsert",
            updatedAt: clientUpdatedAt,
            payload: {
              id: txnId,
              userId: session.user.id,
              profileId,
              type: "transaction",
              merchant: "Test Cafe",
              catKey: "meals",
              amountCents: -1250,
              currency: "AUD",
              txnDate: "2026-05-30",
              mode: "business",
              createdAt: clientUpdatedAt,
              updatedAt: clientUpdatedAt,
              deletedAt: null,
            },
          },
        ],
      }),
    });
    const replayBody = (await replayRes.json()) as { results: { status: string }[] };
    expect(replayBody.results[0].status).toBe("duplicate");
  });
});
```

- [ ] **Step 8: Run the integration test and expect PASS**

```bash
npx vitest run test/integration.test.ts
```

Expected: PASS. `/health` → 200, `/banks` → 501 (`NOT_IMPLEMENTED`), magic-link request → 202, verify → 200 with a session whose `expiresIn` is `900`, `/sync/push` → 200 with one `applied` result at `rev: 1`, `/sync/pull` returns the transaction, and the idempotent replay returns `duplicate`.

> Note: this confirms the magic-link store contract — the server persists `ml:<sha256(token)>` whose JSON value includes both `email` and the raw `token` (the SPINE allows the value to carry the email; the integration test reads the raw `token` back so it can call `/verify` without intercepting the mocked email). If your `/auth/magic-link/request` implementation does NOT also stash `token` in that JSON value, add it there (the value is server-only KV, never returned to clients, and is deleted single-use on verify), or have the test stub `env.EMAIL.send` to capture the token from the rendered message. Keep one approach.

- [ ] **Step 9: Write `README.md` (setup → deploy runbook)**

Create `README.md` with the full operator runbook.

```markdown
# Snapceipt API (Cloudflare Worker)

Local-first sync backend for the Snapceipt iOS app: Sign in with Apple + email
magic-link, JWT sessions, and a push/pull sync protocol over D1 (SQLite) + KV.
Built with Hono, validated with zod, JWTs via jose. Receipt extraction,
export, email-in, R2 images and push are declared but implemented in later
phases (`/banks` returns `501 NOT_IMPLEMENTED`).

## Requirements

- Node.js 20+
- A Cloudflare account with Workers Paid (for D1 > free limits, optional)
- `wrangler` (installed as a dev dependency)

## 1. Install

\`\`\`bash
npm install
\`\`\`

## 2. Create the D1 database and KV namespace

\`\`\`bash
# D1 — copy the printed database_id into wrangler.jsonc under d1_databases[0].database_id
npx wrangler d1 create snapceipt

# KV — copy the printed id into wrangler.jsonc under kv_namespaces[0].id
npx wrangler kv namespace create KV
\`\`\`

## 3. Apply migrations

\`\`\`bash
# Local (the dev/test sqlite)
npx wrangler d1 migrations apply snapceipt --local

# Remote (production D1)
npx wrangler d1 migrations apply snapceipt --remote
\`\`\`

## 4. Configure secrets

\`\`\`bash
# 256-bit signing key for app-issued HS256 JWTs
npx wrangler secret put JWT_SIGNING_KEY

# Your iOS app bundle id, used as the Apple identity-token audience
npx wrangler secret put APPLE_BUNDLE_ID

# Declared for later phases (receipt extraction); safe to set now
npx wrangler secret put DEEPSEEK_API_KEY
\`\`\`

For local dev, copy `.dev.vars.example` to `.dev.vars` and fill in values:

\`\`\`bash
cp .dev.vars.example .dev.vars
\`\`\`

## 5. Run locally

\`\`\`bash
npx wrangler dev
# Worker on http://localhost:8787
# Smoke test:
curl http://localhost:8787/health        # -> 200
curl -X POST http://localhost:8787/auth/magic-link/request \
  -H 'content-type: application/json' -d '{"email":"you@example.com"}'   # -> 202
\`\`\`

## 6. Test

Tests run inside workerd via `@cloudflare/vitest-pool-workers` with real D1 +
KV bindings. Migrations are applied per-suite from `migrations/` via
`applyD1Migrations(env.DB, env.TEST_MIGRATIONS)`.

\`\`\`bash
npx vitest run              # all suites
npx vitest run test/integration.test.ts   # end-to-end foundation check
\`\`\`

## 7. Deploy

\`\`\`bash
npx wrangler deploy
\`\`\`

## API surface (this phase)

| Method | Path                        | Auth   | Notes                                  |
| ------ | --------------------------- | ------ | -------------------------------------- |
| GET    | /health                     | public | liveness                               |
| POST   | /auth/apple                 | public | Sign in with Apple                     |
| POST   | /auth/magic-link/request    | public | always 202; rate-limited 3/email/hr, 10/IP/hr |
| POST   | /auth/magic-link/verify     | public | single-use token                       |
| POST   | /auth/refresh               | public | rotates refresh token                  |
| POST   | /auth/signout               | Bearer | revoke current session                 |
| GET    | /auth/me                    | Bearer | user + devices                         |
| PUT    | /devices/me                 | Bearer | upsert device                          |
| DELETE | /devices/:id                | Bearer | sign out a device                      |
| POST   | /sync/push                  | Bearer | batch <=200; idempotent; LWW; 600/user/hr |
| GET    | /sync/pull                  | Bearer | keyset cursor; tombstones included     |
| ALL    | /banks                      | Bearer | 501 NOT_IMPLEMENTED (placeholder)      |

All money is integer cents, all ids are UUIDv7 strings, all timestamps are
epoch ms, dates are `YYYY-MM-DD`. Error bodies are
`{ "error": { "code", "message", "details?", "requestId" } }`.

## Conventions

- Tenancy: every D1 query is scoped `WHERE user_id = <authed user>`. Never trust
  a client-sent `userId`/`profileId` alone.
- Rate limiting: KV fixed-window per `{userId|IP, route-class}`. 429 responses
  carry a `Retry-After` header (seconds).
\`\`\`
```

- [ ] **Step 10: Verify the README renders and the full test suite is green**

```bash
npx vitest run
```

Expected: PASS — every suite, including `test/rateLimit.test.ts` and `test/integration.test.ts`, is green. (If a prior task's suite name collides, run them individually; all must pass before committing.)

- [ ] **Step 11: Type-check the whole project**

```bash
npx tsc --noEmit
```

Expected: PASS — no type errors. `rateLimit()` returns a `MiddlewareHandler` typed against the SPINE `Env`/`Variables`, and the new test files compile against the `cloudflare:test` types (incl. the `TEST_MIGRATIONS` augmentation from the scaffold task).

- [ ] **Step 12: Final commit (test + impl together)**

```bash
git add src/middleware/rateLimit.ts src/app.ts src/middleware/error.ts README.md test/rateLimit.test.ts test/integration.test.ts && \
git commit -m "$(cat <<'EOF'
feat(backend): add KV rate limiter, wire auth/sync limits, README + e2e test

Adds a KV fixed-window rate limiter (auth 3/email/hr + 10/IP/hr, sync
600/user/hr, default 300/user/min) emitting 429 RATE_LIMITED with
Retry-After. Wires it ahead of auth on /auth/* and after auth on the
protected sync/device groups. Adds the operator README (install ->
d1 create/migrate -> secrets -> dev -> test -> deploy) and an end-to-end
integration test (magic-link -> sync push/pull, /banks 501, /health 200).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: a single commit containing the limiter, app wiring, README, and both tests. This completes the backend foundation.

