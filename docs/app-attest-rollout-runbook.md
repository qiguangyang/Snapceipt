# App Attest rollout runbook

Phased rollout of App-Attest enforcement on the six auth-bootstrap endpoints, so no existing App Store install breaks. See the design at `docs/superpowers/specs/2026-07-21-app-attest-auth-hardening-design.md`.

## Controls
- `ATTEST_MODE` (wrangler var / env): `off` (default) → `soft` → `enforce-new` → `enforce-all`.
- `ATTEST_MIN_BUILD` (env, numeric string): the first `CFBundleVersion` that ships App Attest. **Required before selecting `enforce-new`** — if unset it coerces to 0, and `enforce-new` then behaves like `enforce-all` (rejects every un-attested request, including old installs). This is enforced by `attestDecision` (`src/middleware/attest.ts`).

Modes are read per-request from `c.env.ATTEST_MODE`; flip via a wrangler var change + deploy (or a secret). Dev/E2E leave it unset (`off`).

## What each mode does (from `attestDecision`)
| Mode | Un-attested request | Attested request |
|---|---|---|
| `off` | pass (middleware early-returns; no verification) | pass |
| `soft` | pass (verify-if-present + telemetry, never reject) | pass |
| `enforce-new` | reject **iff** `X-App-Build ≥ ATTEST_MIN_BUILD`; older/unknown builds exempt | pass |
| `enforce-all` | reject | pass |

## Sequence
1. **Deploy the Worker** (all backend tasks) with `ATTEST_MODE=off`. Migration `0019_attest_keys` ships and is inert. `npx wrangler deploy`.
2. **Ship the iOS build** with `AppAttestor` (Phase 2 Task 9) to TestFlight → App Store. Record its `CFBundleVersion`.
3. **Capture a real-device vector** and complete the deferred acceptance test (see `test/fixtures/appattest/README.md`). Confirm one genuine `/attest/verify` + one assertion-gated auth call succeed end-to-end on a physical device.
4. Set `ATTEST_MIN_BUILD=<that build>`, then `ATTEST_MODE=soft` → deploy. Watch Worker logs (`attest soft: unattested`) for the valid-assertion rate from the new build; confirm false-positives ≈ 0 and adoption is climbing.
5. When the new build's valid-assertion rate is high: `ATTEST_MODE=enforce-new` → deploy. App-path abuse (OTP-bombing via `curl`) dies for the enforced build range; older installs stay exempt and keep working.
6. **(Optional, later)** After old builds have effectively aged out (aided by a min-version prompt in-app), `ATTEST_MODE=enforce-all`.

## Rollback
Set `ATTEST_MODE=off` (or `soft`) and deploy — instantly restores the pre-enforcement behavior. Phase-1 rate caps remain in force regardless, so OTP-bombing stays bounded even at `off`.

## Notes / cleanup candidates (from the SDD review pass)
- `derToRawEcdsa` (`src/lib/appAttest.ts`): add deterministic fixed-vector tests for the leading-zero-strip and left-pad branches (currently exercised only probabilistically). Non-blocking.
- Stale rate-limit comments in `test/rateLimit.test.ts` still say "8/email/hr" (the cap is now 4). Cosmetic.
- Stale top-of-function JSDoc on `sendOtpCode` (`src/routes/auth.ts`) predates the daily send-cap. Cosmetic.
- `/attest/*` currently uses the `auth` rate-limit tier (20/IP/hr). Revisit if a single install legitimately needs more challenge round-trips per hour.
