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

### E2E journey suites (live wrangler dev)

Run a subset of UITest classes against a local `wrangler dev` with the E2E seams:

```bash
scripts/ios-e2e-journeys.sh LiveJourneyUITests
scripts/ios-e2e-journeys.sh ProfileScopingUITests CaptureEditUITests
# Crash-recovery journeys need a stable persist dir across restarts:
scripts/ios-e2e-journeys.sh --persist .e2e-journey-state LiveJourneyUITests
```

Backend e2e (real HTTP via `unstable_dev`): `npm run test:e2e`.

## Operations runbook

Production Worker: `snapceipt-api` on `api.snapceipt.cc` (account `techsiderau`,
id `bb4412973b5e4f6d7a10a4e68b713177`). Deploy is `npx wrangler deploy`
(`scripts/deploy.sh` for a full provision + deploy).

### Backend rollback (Worker code)

```bash
# 1. List recent deployments (most recent first) and copy a known-good Version ID.
npx wrangler deployments list

# 2. Roll back to that version (omit the id to roll back to the previous one).
npx wrangler rollback <version-id>
```

**WARNING — rollback does NOT revert the database.** D1 migrations in
`migrations/` are applied with `wrangler d1 migrations apply --remote` and are
**forward-only**: `wrangler rollback` only swaps the Worker bundle, it never
un-applies a migration. A migration that drops/renames a column will still be
gone after a code rollback. Therefore: make every migration **additive +
backward-compatible** (e.g. `0005_quote_gst_inclusive.sql` is a pure
`ADD COLUMN ... DEFAULT 0`), so an older Worker bundle keeps working against the
newer schema. If a migration corrupted data, recover via **D1 Time Travel**
(see "D1 backups" below), not via code rollback.

### D1 backups

Two layers cover the production `snapceipt` D1 database:

1. **Time Travel (built-in, 30-day):** Cloudflare keeps a continuous restore
   window. To inspect or restore a point in time:
   ```bash
   # Find the bookmark for a timestamp (or use --timestamp directly).
   npx wrangler d1 time-travel info snapceipt --timestamp=2026-06-15T00:00:00Z
   # Restore the DB to that point (DESTRUCTIVE — overwrites current state).
   npx wrangler d1 time-travel restore snapceipt --timestamp=2026-06-15T00:00:00Z
   ```
   Use this to recover from a bad migration or accidental mass-delete within the
   last 30 days.

2. **Off-platform export to R2 (hourly cron):** the Worker's scheduled handler
   (`src/index.ts`) also runs `d1BackupLogic` (`src/cron/d1Backup.ts`), which the
   `0 * * * *` cron triggers every hour. It writes a full SQL dump to the
   `BACKUPS` R2 bucket under `d1/snapceipt/<YYYY-MM-DD>/<epoch-ms>.sql`. To take a
   manual dump or restore from one:
   ```bash
   # Manual full export to a local file:
   npx wrangler d1 export snapceipt --remote --output=snapceipt-$(date +%F).sql
   # Restore that dump into a fresh/empty database:
   npx wrangler d1 execute snapceipt --remote --file=snapceipt-2026-06-15.sql
   ```
   R2 lifecycle: set a 30-day expiry on the `snapceipt-backups` bucket so dumps
   self-prune (Dashboard → R2 → snapceipt-backups → Settings → Object lifecycle
   rules → delete after 30 days; or CLI: `npx wrangler r2 bucket lifecycle ...`).

### iOS rollback (App Store)

There is no binary downgrade on the App Store. Levers, in order of preference:

1. **Fix-forward** — ship a new build (`bundle exec fastlane beta` →
   promote). Fastest safe path for most regressions.
2. **Pause a phased release** — App Store Connect → the version → *Phased
   Release for Automatic Updates* → **Pause**. Stops the rollout of a bad
   version to the rest of the install base while you cut a fix.
3. **Remove from Sale** — App Store Connect → App → *Pricing and Availability*
   → set availability to no territories. Last resort for a critical defect; new
   users can't download, existing installs are unaffected.

Because the backend is forward-compatible (additive migrations), an older
installed app keeps working against the current Worker — so the iOS lever you
almost always want is **fix-forward**, with phased-release **Pause** to buy time.
