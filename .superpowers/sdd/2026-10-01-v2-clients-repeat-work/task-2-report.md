# Task 2 implementation report

## Implementation

- Added `validateV2Mutation(db, userId, mutation, stored)` and call it after idempotency, ownership, stale-write resolution, and the existing generic delete path, before constructing an upsert. Rejections use the existing per-mutation recorder and do not abort siblings.
- Validate effective stored-plus-supplied v2 fields with explicit Zod schemas, reusing Task 1's text/timezone/scalar definitions. Trim supplied client names, item descriptions, reminder titles, notes, and units; normalize blank optional notes/units to null. Preserve existing contact field behavior and no-type payloads.
- Enforce name/notes/description/unit/title limits, catalog cents range, safe nonnegative new-entity/reminder timestamps, IANA timezone, and UUIDv7 new entity/profile/client-link IDs. Confirmed both backend `src/lib/ids.ts` and existing Swift client construction use UUIDv7 before enforcing v2 links. Legacy unrelated IDs/schemas are unchanged.
- New catalog/follow-up writes require an owned live business profile. Existing client mutations on personal profiles retain prior behavior.
- New/changed links require same-user/profile live clients. Missing/deleted new links reject `VALIDATION_FAILED`; foreign/other-profile links reject `FORBIDDEN`. Existing quote/invoice links to tombstoned clients survive when their client and profile are unchanged. Explicit null unlinks optional documents. Generic tombstones remain unchanged.
- Client profile moves reject if live quote, invoice, or follow-up links in its original scope would be invalidated. Document/follow-up profile moves validate their effective client scope. Deleted links do not prevent a later client move.
- Same-batch parent-first applies dependents; reverse order records only the dependent rejection, allows the parent, and requires a fresh mutation ID to retry.
- Preserve omitted v2 domain fields and genuinely omitted existing profiles. For partial v2 writes, retained values are INSERT fallbacks only (SQLite checks required columns before conflict handling); ON CONFLICT updates only originally supplied columns. Explicit null profileId remains invalid under the existing wire schema (HTTP 400), never converted to retention.
- The controller approved a scoped client lookup followed by a bound, existence-only `SELECT 1` probe when necessary to distinguish forbidden IDs from missing IDs. No foreign contact fields are returned; domain data queries/writes remain user/profile scoped.

## TDD and verification commands

All vitest commands used `require_escalated` for the known localhost worker runtime requirement. No production network services, deployments, or pushes were used. Raw logs live under `/private/tmp/task-2-*.log`.

1. **Initial RED**: `npx vitest run test/sync-v2-clients.test.ts > /private/tmp/task-2-red.log 2>&1` — exit 1, **29 failed / 1 passed**. Expected failures: invalid links/scalars applied, whitespace persisted unnormalized, profile moves applied, dependent-first applied, personal business-profile violations applied, omitted existing quote profile rejected. Existing integer price guard already rejected fractional catalog cents (the one passing case).
2. **First GREEN**: same focused command to `/private/tmp/task-2-green-1.log` — exit 0, **30/30 passed** after initial validator integration.
3. **Merged edit RED**: focused command to `/private/tmp/task-2-red-merge.log` — exit 1, **2 failed / 33 passed**. A partial client/catalog/follow-up edit rejected because required INSERT fields were absent even though the effective merged row validated; the second failure was a test expecting per-mutation null-profile rejection even though the preexisting envelope correctly returns HTTP 400. Added insertion fallback and corrected that expectation.
4. **Intermediate GREEN**: `npx vitest run test/sync-v2-clients.test.ts test/sync-security.test.ts test/sync-push.test.ts test/sync-invoices.test.ts` to `/private/tmp/task-2-scoped.log` — exit 0, **79/79 passed**; later additional boundary/atomicity cases produced **81/81**.
5. **Concurrent omission RED**: focused command to `/private/tmp/task-2-red-concurrency.log` — exit 1, **1 failed / 37 passed**. A real route/D1 interleaving test updated the stored quote PDF/status during asynchronous client validation; the initial insertion workaround incorrectly restored `old.pdf`/`draft` instead of preserving `new.pdf`/`sent`. This directly demonstrated the controller's identified risk.
6. **Final scoped GREEN**: `npx vitest run test/sync-v2-clients.test.ts test/sync-security.test.ts test/sync-push.test.ts test/sync-invoices.test.ts > /private/tmp/task-2-scoped-final.log 2>&1` — exit 0, **82/82 passed (4 files)**, including **38 new v2 cases** and the existing no-type regression. The concurrent omission test now preserves server PDF/status on pull; partial required-field edits still apply.
7. `npm run typecheck > /private/tmp/task-2-typecheck-after.log 2>&1` — exit 2, **17 preexisting diagnostics; zero new diagnostics**. A before-implementation run captured the same old errors plus a temporary test `dueAt` inference error fixed by explicitly typing the helper payload as `Record<string, unknown>`. Remaining errors: 10 in `src/lib/deepseek.ts`, missing `Env` in `test/apply-migrations.ts`, 1 unchecked value in `test/inbound.test.ts`, 3 in `test/notify.test.ts`, missing `node:path` types and `__dirname` in `vitest.config.ts`. Those are controller-assigned Task 10 work; no unrelated repair attempted.
8. `npx vitest run > /private/tmp/task-2-full.log 2>&1` — exit 1 after **710 passing tests / 1 timeout** in 68 files. The existing `test/export-app.test.ts` rate-limit case exceeded its 5000ms timeout while issuing 61 requests; the worker then failed to unwind isolated storage (`expected 204, received 500`) and closed its runner websocket. The run aborted remaining suites. No domain assertion failed and the Task 2 suite passed. No test/config/source repair was made for this unrelated execution failure.
9. The controller approved a full retry with only a longer command-line execution tolerance: `npx vitest run --testTimeout=15000 > /private/tmp/task-2-full-retry.log 2>&1` — exit 0, **796/796 tests passed, 92/92 files**, duration 86.65s. The export rate-limit case passed without changes to assertions or configuration.
10. `git diff --check` — passed before final commit.

## Files changed

- `src/lib/v2SyncValidation.ts` (new)
- `src/routes/sync.ts`
- `test/sync-v2-clients.test.ts` (new)
- This report

## Self-review

- Read the complete task diff and verified targeted schemas do not invoke strict legacy entity schemas or require a type tag.
- Checked omitted-versus-null semantics, immutable stored createdAt handling, retained profile scope, safe money/time boundaries, ownership probes, tombstones, reverse batches, and replay behavior.
- Fixed omission safety after the controller flagged concurrent server fields; added an actual D1 interleaving regression before applying the fix.
- Retained field fallbacks are scoped to v2-related types. Existing unrelated profile/parent/numeric/deletion behavior remains unchanged.
- No historical contact snapshots are refreshed as a consequence of client edits or link assignments; explicit payload document changes remain under caller control.
- No new dependencies, notifications, scheduling, analytics, migrations, Swift/platform changes, or unrelated repairs.

## Concerns and limitations

- Typecheck cannot be globally green until the recorded Task 10 baseline issues are repaired. No Task 2 diagnostic remains.
- Test output contains existing Wrangler warnings (`allowed_sender_addresses`, compatibility date fallback), existing HTTP logs, and existing tested-error logs; new Task 2 paths add no warnings.
- The route continues its existing deterministic push echo behavior using the previously loaded row; under a concurrent server write an omitted field in the immediate push echo can reflect that earlier snapshot until pull. The committed SQL correctly preserves concurrent omitted server values, verified by pull. Changing general echo/concurrency semantics is outside this task.

## Commit

Task files and this report committed together with subject `feat: validate client workspace sync references`.
