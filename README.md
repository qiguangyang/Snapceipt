# Snapceipt API (Cloudflare Worker)

Local-first sync backend for the Snapceipt iOS app: Sign in with Apple + email
magic-link, JWT sessions, and a push/pull sync protocol over D1 (SQLite) + KV.
Built with Hono, validated with zod, JWTs via jose. Receipt extraction, export,
email-in, R2 images and push are declared but implemented in later phases
(`/banks` returns `501 NOT_IMPLEMENTED`).

## Requirements

- Node.js 20+ (developed on Node 24)
- A Cloudflare account (Workers Paid recommended for D1 beyond free limits)
- `wrangler` (installed as a dev dependency — invoke via `npx wrangler …`)

## 1. Install

```bash
npm install
```

## 2. Create the D1 database and KV namespace

```bash
# D1 — copy the printed database_id into wrangler.jsonc under d1_databases[0].database_id
npx wrangler d1 create snapceipt

# KV — copy the printed id into wrangler.jsonc under kv_namespaces[0].id
npx wrangler kv namespace create KV
```

The repo ships with placeholder ids in `wrangler.jsonc`; replace them with the
ids printed above before deploying.

## 3. Apply migrations

```bash
# Local (the dev/test sqlite) — also available as `npm run migrate:local`
npx wrangler d1 migrations apply snapceipt --local

# Remote (production D1) — also available as `npm run migrate:remote`
npx wrangler d1 migrations apply snapceipt --remote
```

## 4. Configure secrets

```bash
# 256-bit signing key for app-issued HS256 JWTs
npx wrangler secret put JWT_SIGNING_KEY

# Your iOS app bundle id, used as the Apple identity-token audience
# (also declared as a non-secret var in wrangler.jsonc)
npx wrangler secret put APPLE_BUNDLE_ID

# Declared for later phases (receipt extraction); safe to set now
npx wrangler secret put DEEPSEEK_API_KEY
```

For local dev, copy `.dev.vars.example` to `.dev.vars` (git-ignored) and fill in
values:

```bash
cp .dev.vars.example .dev.vars
```

`.dev.vars` holds the local-only `JWT_SIGNING_KEY`, `APPLE_BUNDLE_ID`, and
`DEEPSEEK_API_KEY`. It is read by `wrangler dev`; tests inject their own values
via `vitest.config.ts`.

## 5. Run locally

```bash
npx wrangler dev          # or: npm run dev
# Worker on http://localhost:8787
# Smoke test:
curl http://localhost:8787/health        # -> 200 {"ok":true,...}
curl -X POST http://localhost:8787/auth/magic-link/request \
  -H 'content-type: application/json' -d '{"email":"you@example.com"}'   # -> 202
```

## 6. Test

Tests run inside workerd via `@cloudflare/vitest-pool-workers` with real D1 + KV
bindings. Migrations are applied per test-worker from `migrations/` via
`applyD1Migrations(env.DB, env.TEST_MIGRATIONS)` (see `test/apply-migrations.ts`).
`isolatedStorage` is on by default, so each test gets a fresh KV/D1 view — this
is why the rate limiter (KV-backed) never bleeds counts across tests.

```bash
npm test                                   # all suites (vitest run)
npx vitest run test/integration.test.ts    # end-to-end foundation check
npm run typecheck                          # tsc --noEmit
```

## 7. Deploy

```bash
npx wrangler deploy        # or: npm run deploy
```

## API surface (this phase)

| Method | Path                     | Auth   | Notes                                          |
| ------ | ------------------------ | ------ | ---------------------------------------------- |
| GET    | /health                  | public | liveness; never rate-limited                   |
| POST   | /auth/apple              | public | Sign in with Apple; rate-limited 10/IP/hr      |
| POST   | /auth/magic-link/request | public | always 202; rate-limited 3/email/hr, 10/IP/hr  |
| POST   | /auth/magic-link/verify  | public | single-use token; rate-limited 10/IP/hr        |
| POST   | /auth/refresh            | public | rotates refresh token; rate-limited 10/IP/hr   |
| POST   | /auth/signout            | Bearer | revoke current session                         |
| GET    | /auth/me                 | Bearer | user + devices                                 |
| PUT    | /devices/me              | Bearer | upsert device (X-Device-Id); 300/user/min      |
| DELETE | /devices/:id             | Bearer | sign out a device; 300/user/min                |
| POST   | /sync/push               | Bearer | batch <=200; idempotent; LWW; 600/user/hr      |
| GET    | /sync/pull               | Bearer | keyset cursor; tombstones included; 600/user/hr |
| ALL    | /banks                   | public | 501 NOT_IMPLEMENTED (placeholder)              |

All money is integer cents, all ids are UUIDv7 strings, all timestamps are
epoch ms, dates are `YYYY-MM-DD`. Error bodies are
`{ "error": { "code", "message", "details?", "requestId" } }`; success bodies
are the raw resource (no wrapper).

## Conventions

- Tenancy: every D1 query is scoped `WHERE user_id = <authed user>`. Never trust
  a client-sent `userId`/`profileId` alone.
- Rate limiting: KV fixed-window per `{userId|IP, route-class}`. Tiers — auth
  3/email/hr + 10/IP/hr (apple + refresh share the per-IP `auth` tier),
  `/sync/*` 600/user/hr, default 300/user/min. 429 responses carry a
  `Retry-After` header (seconds). Mounted centrally in `src/app.ts`:
  `/auth/*` is limited BEFORE auth; `/sync/*` and `/devices/*` AFTER auth (so the
  authed `userId` keys the counter).

## Layout

- `src/index.ts` — Worker entry (`export default { fetch: app.fetch }`).
- `src/app.ts` — module-scope `export const app`; middleware + route mounts.
- `src/env.ts` — `Env` (bindings) + `Variables` (request-scoped) types.
- `src/middleware/` — `error.ts` (requestId + uniform error envelope),
  `auth.ts` (Bearer verification + `PUBLIC_PATHS`), `rateLimit.ts` (KV limiter).
- `src/routes/` — `misc.ts` (`/health`, `/banks`), `auth.ts` (`/auth/*`),
  `devices.ts` (`/devices/*`), `sync.ts` (`/sync/*`).
- `src/lib/` — ids, time, jwt, sessions, apple, email, db helpers, sync tables.
- `src/schemas/` — zod schemas for auth, sync, and syncable entities.
- `migrations/0001_init.sql` — the full D1 schema.
- `test/` — Vitest suites + the shared D1 migration setup file.

## Testing notes

The `ai` binding declared in `wrangler.jsonc` is compiled by Wrangler into a
wrapped binding backed by an external worker that the offline test runtime can't
resolve (workers-sdk #6796 / #7434). `vitest.config.ts` overrides the `AI`
wrapped binding with a local stub worker so the test runtime boots; `wrangler
dev`/`wrangler deploy` use the real binding unchanged.

## iOS UI tests

- **Hermetic suite (no backend, default/CI):** `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptUITests` — launches the app against an in-app stub (`-uiTestStub`) and drives sign-in → onboarding → shell + the profile switcher. `LiveSmokeUITests` `XCTSkip`s here.
- **Live smoke (real Worker):** `./scripts/ios-e2e-live.sh` — applies D1 migrations to a fresh local store, starts `wrangler dev` with `E2E_TEST_MODE=1`, and runs `LiveSmokeUITests` (real `LiveAPIClient` → dev sign-in hits the live `/auth/magic-link/*` seam → onboarding). The script tears the Worker down on exit.
