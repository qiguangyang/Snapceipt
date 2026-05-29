# snapceipt-api

Cloudflare Worker backend for Snapceipt — a Hono router on Workers with D1, KV,
R2, Workers AI, and Email bindings. Provides auth (Sign in with Apple +
email magic-link) and a local-first sync protocol for the iOS app.

This is the foundation scaffold: a deployable Worker serving `GET /health`
(public) and `ALL /banks` (501 placeholder), with a Vitest harness that runs
inside workerd via `@cloudflare/vitest-pool-workers` against real D1/KV bindings.
Auth, sync, devices, errors, and the full schema land in later tasks.

## Requirements

- Node 20+ (developed on Node 24)
- `npm`

## Setup

```bash
npm install
cp .dev.vars.example .dev.vars   # then fill in real local secrets
```

`.dev.vars` (git-ignored) holds local secrets/vars: `JWT_SIGNING_KEY`,
`DEEPSEEK_API_KEY`, `APPLE_BUNDLE_ID`. On deploy, secrets are set via
`wrangler secret put ...`; `APPLE_BUNDLE_ID` is also a non-secret `var` in
`wrangler.jsonc`.

## Scripts

| Script | Description |
| --- | --- |
| `npm run dev` | Run the Worker locally with `wrangler dev`. |
| `npm test` | Run the Vitest suite inside workerd (`vitest run`). |
| `npm run test:watch` | Vitest in watch mode. |
| `npm run typecheck` | `tsc --noEmit`. |
| `npm run cf-typegen` | Regenerate `worker-configuration.d.ts` from bindings. |
| `npm run deploy` | Deploy with `wrangler deploy`. |
| `npm run migrate:local` | Apply D1 migrations to the local DB. |
| `npm run migrate:remote` | Apply D1 migrations to the remote DB. |

## Layout

- `src/index.ts` — Worker entry (`export default { fetch: app.fetch }`).
- `src/app.ts` — module-scope `export const app`; middleware + route mounts.
- `src/env.ts` — `Env` (bindings) + `Variables` (request-scoped) types, reused
  by every later task.
- `src/routes/misc.ts` — `GET /health`, `ALL /banks` (501).
- `migrations/0001_init.sql` — placeholder migration (replaced by the schema
  task with the full domain schema).
- `test/` — Vitest tests + the D1 migration setup file.

## Testing notes

Tests run inside workerd via `@cloudflare/vitest-pool-workers` (pinned to the
`0.5.x` line, which peers `vitest@2.1.x` and exposes the `cloudflare:test`
module API — `env`, `SELF`, `applyD1Migrations`, `readD1Migrations` — that the
later tasks depend on).

The `ai` binding declared in `wrangler.jsonc` is compiled by Wrangler into a
wrapped binding backed by an external worker that the offline test runtime can't
resolve (workers-sdk #6796 / #7434). `vitest.config.ts` overrides the `AI`
wrapped binding with a local stub worker so the test runtime boots; `wrangler dev`
and `wrangler deploy` use the real binding unchanged.
