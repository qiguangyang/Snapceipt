# Backend environments & staging runbook

Snapceipt's backend has two deployed Wrangler environments plus a local/test layer.
All three let you test changes **without touching prod user data**.

| Layer | Where | Use it for |
|---|---|---|
| **Hermetic tests** | `npm test` (652 tests, in-memory D1/KV/R2) | every change, pre-deploy gate |
| **Local dev** | `npx wrangler@4 dev` (miniflare) | quick manual smoke; drive a Debug iOS build against it |
| **Staging** | `snapceipt-api-staging.techsiderau.workers.dev` | end-to-end test of the *deployed* worker on isolated resources |
| **Prod** | `api.snapceipt.cc` | live users — only deploy here after staging is green |

## Staging at a glance

- **URL:** `https://snapceipt-api-staging.techsiderau.workers.dev`
- **Worker:** `snapceipt-api-staging`
- **Isolated resources** (separate from prod): D1 `snapceipt-staging`, KV `snapceipt-staging-kv`, R2 `snapceipt-receipts-staging` + `snapceipt-backups-staging`.
- **Secrets:** its own `JWT_SIGNING_KEY` (distinct from prod, so tokens never cross-validate). `DEEPSEEK_API_KEY` is intentionally **unset** → `/extract` uses the free heuristic stub. Set it (`wrangler secret put DEEPSEEK_API_KEY --env staging`) to test real LLM extraction. `APNS_KEY` unset → push runs in stub (log-only) mode.
- Config lives under `env.staging` in `wrangler.jsonc`.

## The pre-release workflow (recommended)

```bash
# 1. Always pass the hermetic suite first.
npm test

# 2. Apply any new migrations to STAGING and deploy there.
npx wrangler@4 d1 migrations apply snapceipt-staging --remote --env staging
npx wrangler@4 deploy --env staging

# 3. Smoke-test staging (HTTP + a Debug iOS build pointed at it — see below).

# 4. Only when staging is green, promote to prod.
npx wrangler@4 d1 migrations apply snapceipt --remote     # validate migrations on prod
npx wrangler@4 deploy
```

Applying migrations to staging first is the safety net: a migration that would abort
`apply --remote` (e.g. a UNIQUE index over dirty data) fails on staging, not prod.

## Point the iOS app at staging

The app reads an `API_BASE_URL` env override (`AppLaunch.swift`), **DEBUG builds only**:

- **Xcode:** Scheme → Run → Arguments → Environment Variables → add
  `API_BASE_URL = https://snapceipt-api-staging.techsiderau.workers.dev`, then run on device/sim.
- **`wrangler dev` instead:** set `API_BASE_URL = http://<your-mac-LAN-ip>:8787`.

> A TestFlight (Release) build **cannot** be pointed at staging today — Release hardcodes
> `api.snapceipt.cc`. If you want a TestFlight-on-staging build, add a dedicated Staging
> build configuration that injects the base URL (not yet set up).

## Inspect / reset staging data

```bash
npx wrangler@4 d1 execute snapceipt-staging --remote --env staging --command "SELECT COUNT(*) FROM users;"
# wipe a table for a clean run:
npx wrangler@4 d1 execute snapceipt-staging --remote --env staging --command "DELETE FROM transactions;"
```

## Not yet wired on staging (add if needed)

- **Email-in:** needs an inbound Email Routing catch-all (e.g. `in-staging.snapceipt.cc`)
  pointed at the staging worker's `email()` handler, configured in the Cloudflare dashboard.
- **Apple subscriptions:** test with StoreKit **sandbox** testers; point the *sandbox*
  App Store Server Notification URL at the staging worker (prod keeps the production URL).
