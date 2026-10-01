# Task 10 — v2 client workflows, genuine upgrade, release verification

Base: b075754. Status: DONE_WITH_CONCERNS (unclassified minor frame warning and explicit manual/device gates). Final verification is complete; local commit recorded below.
No push, remote PR, production deploy, App Store upload or publication.

## Implementation and scope

- Added three real XCUITest journeys: client+notes → new quote from saved catalog item → save/history → Create again/review → reminder/completion; paid invoice repeat/reset date and two-business isolation (including catalog); select legacy candidate without confirmation then explicit association, preserving original contact.
- Extended only existing DEBUG -uiTestStub/-uiTestClientWorkspace fixture in AppLaunch. Fixed UUIDv7-shaped IDs for two business profiles' clients/documents/lines/payments/items/follow-ups; personal fixture remains available. No production auth bypass.
- Added genuine v1 disk upgrade with original receipt/client/quote/invoice/receipt line/quote line/invoice line/payment IDs and values, nil new properties, disk-only configuration and v2 edit/reopen.
- Added supported-iOS real SyncEngine success regression for loaded existing quote/invoice drafts, cached models and cached deduped outbox payloads, edited/deleted lines, applied acknowledgements, fresh-context durable fields/tombstones and unrelated/payment/income checks. No stale-line overwrite was reproduced; no speculative production fix.
- Added real local-Worker live notes creation/offline edit/relaunch/reconnect/sign-out-wipe/server-restore journey. Harness adds optional portable simulator/directory/port overrides, occupied-port preflight and actual listener ancestry verification.
- Repaired 17 baseline TypeScript errors: required-regex-capture/bounded-index narrowing, nullable array last result, imported Env, checked test spy indexing, migration path rooted consistently with existing config relative paths. No dependency upgrade or compiler strictness relaxation.
- Controller-authorized repair of stale baseline HTTP E2E expectations/entitlements, below; production contracts untouched.
- Acceptance checklist, proposed NEXT_RELEASE copy, local PR description and spec/plan rulings reconciled. Version/build and upload-ready metadata preserved.

## Genuine fixture provenance

Baseline e22d9952a1c7eccdca08e2e70976ddee0a59ccb0. Maintained generator:
`scripts/fixtures/generate-v1-workspace.py --simulator <booted-arm64-iOS-simulator-UUID>`.
It git-archives baseline production Entities, IDClock/Syncable/EntityType/OutboxMutation/
ModelContainer+Snapceipt and PendingReceipt into /private/tmp, compiles untouched
@Model classes under original module Snapceipt with arm64-apple-ios17.0-simulator,
and runs the synthetic recipe via simctl on iOS26.5. SQLite backup captures committed
WAL content in the single bundled store. 20 baseline models, not v2's22. No renamed,
nested or v2-generated fake v1 model/store.

`SnapceiptTests/Fixtures/v1-workspace.provenance.json` records baseline, source SHA256s,
recipe SHA256, Xcode27.0/27A266a, actual runtime and output SHA256. FixtureBundlingTests
verifies SQLite header, exact baseline/module and output hash. Upgrade uses throwing
ModelContainer with v2 schema and explicit URL, asserts every configuration is disk
at that URL, then all original rows. It never calls the memory-fallback launch helper.

Initial macOS-generation experiment migrated on iOS but emitted CoreData persistence
build-version warnings; discarded/replaced with iOS-runtime-generated fixture. Final
generation `/private/tmp/task10-fixture-final.log` exit0, no compiler warning. The
prior simulator generation emitted a linker sysroot warning; SDKROOT fixed it before
final fixture generation. Final store hash:
6c04d8618899860949024d542e6c31b069a4e6ea2c59b5e00c67592ccc9a2a23.

## TDD and focused verification ledger

All xcode tests use default signing, no CODE_SIGNING_ALLOWED=NO. Commands redirect
full output and preserve `$?`; logs are in /private/tmp. Failed footer cleanup touches
only identified owned Snapceipt/diagnostic processes, never other projects.

Common iOS prefix: `xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt
-destination 'platform=iOS Simulator,id=7962C2D3-C7A8-422D-A061-3C90F3D59206'
-derivedDataPath /private/tmp/snapceipt-v2-derived`.

- `task10-red.log`: only ClientWorkspaceUpgradeTests + ClientsJourneyUITests. Upgrade1 passed; UI3 failed as expected before fixed-ID/saved-item fixtures. Owned failed runner12306 and diagnostic12885 stalled; terminated, exit143 (not a complete xcode65/green claim).
- `task10-focused1.log`: upgrade + ClientWorkspaceAppliedAckTests + ClientsJourneyUITests. Exit65. Upgrade passed; quote/invoice durable lines passed, one invoice wire assertion wrong (invoice uses itemDescription, quote uses description). UI paid-invoice/profile passed; two selector failures (multiline item is not TextField; compact confirmation dialog has no Cancel element). Fixed test oracles, no product sync change.
- `task10-focused2.log`: above plus FixtureBundlingTests. Exit65. Four Swift tests/3 suites passed (ack test has quote/invoice arguments). Paid/profile UI passed; two remaining oracle errors: new reminder has explanatory In-app only text, standalone status appears for saved records; bill-to contact is static text in a button, not text fields.
- `task10-focused3.log`: only ClientsJourneyUITests/testAddNotesSavedItemQuoteRepeatAndReminder and /testLegacyAssociationRequiresConfirmationAndPreservesContact. Exit0. Both passed,98.265s.
- `npm run typecheck` baseline exit2:17 diagnosed errors. After repair final `/private/tmp/task10-typecheck-final.log` exit0.
- `npm test -- test/deepseek.test.ts test/notify.test.ts test/inbound.test.ts --testTimeout=15000`: `/private/tmp/task10-ts-focused.log`, exit0,52tests/3files.

## Baseline HTTP failures and evidence

Initial `npm run test:e2e`: `/private/tmp/task10-e2e-final.log`, exit1,
27passed/9failed in14files. Baseline `git show e22d995:<path>` evidence was inspected
and captured at `/private/tmp/task10-e2e-baseline-evidence.log`:

| Failure | Baseline production evidence | Repair |
| --- | --- | --- |
| Auth TTL expected900, actual600 | src/lib/jwt.ts:3 ACCESS_TTL_SECONDS=600 | Assert600 for login and refresh |
| Extraction expected THE GROUNDS | src/lib/ocr.ts:8 canonical stub ACME HARDWARE PTY LTD | Assert canonical deterministic fixture |
| Quote send/edge, inbox and BAS returned403 | baseline quotes.ts:177, inbox.ts:28, export.ts:151 requireProPlan | Explicit isolated local-D1 live Pro entitlement helper; production gate untouched |
| Quote response/download assumptions | baseline quotes.ts:283 returns url/emailed/number, auth.ts public /q/ | Read totals/status via pull, load public HTML /q/ link and reject forged link403 |
| Fourth auth email expected429 | baseline rateLimit.ts:42 email cap8, IPcap20 | Eight successes/ninth429, Retry-After retained |
| Inbox32hex discovered after gate fixed | baseline inboxToken.ts:17–19 uses13base32 | Assert13base32 |
| Inbox rotation200 discovered after format fixed | baseline inbox.ts exposes only GET, no rotation | Verify repeated GET stable alias and removed rotation404 |

Free-denial coverage remains in quote-invoice-pro-gate.test.ts, inbox-routes.test.ts,
export-pro-gate.test.ts and plan.test.ts; full Worker suite passed. The helper updates
only a validated fixture UUID in the suite's mkdtemp LOCAL D1, never remote.

Repaired full E2E first rerun `/private/tmp/task10-e2e-repaired.log`: exit1,
35passed/1failed (old inbox format). Focused inbox `/private/tmp/task10-inbox-focused.log`:
exit1,1passed/1failed (removed rotation). Focused inbox green exit0,2passed.
Final full `/private/tmp/task10-e2e-final-green.log`: exit0,36passed/14files,70.21s.

## Final backend result and export performance

`npm test -- --testTimeout=15000`: `/private/tmp/task10-backend-final.log`, exit0,
816tests/92files,125.43s total (56.90s tests). Existing61-request export rate-limit
case passed in8.325s (file8.615s); beyond default5s but below authorized CLI15s.
The case serially performs60 full authorized export requests then asserts61st429;
all61 route log timings sum to132ms (min0/max9ms), while case wall time is8.325s.
The majority is harness/dispatch/storage overhead outside measured route handlers;
no production export performance regression was established. Assertions remain intact. No checked-in timeout/performance configuration changed.
Runtime includes simultaneous independent local E2E/simulator work; this is local
harness timing, not a production latency benchmark. No unsupported performance claim.

## Live harness investigation (completed result appended below)

Initial existing name-only destination selected latest OS27 with no iPhone16 and
failed resolution, exit70 `/private/tmp/task10-live.log`. Known UUID override fixes
runtime ambiguity while preserving default behavior for other users.

Found unrelated Leanology workerd81408 already listening8787. Original harness
accepted its health response despite own bind failure. Stopped only owned xcode22495,
exit143 `/private/tmp/task10-live2.log`; neither invalid run counts as app failure or
live pass. Left unrelated listener untouched. Port48987 is preflight-bound/released,
health requires owned Worker alive, and actual listening workerd ancestry is checked
against WPID before launching tests. Uses direct node Wrangler launcher so signal
forwarding/cleanup reaches its child. Example verified chain23147→23124→23120 for
live3 and24113→Worker24101 for live4. Each run uses distinct mkdtemp persistence.

live3 exit65: client list row selector expected nested static text; changed to stable
client-row ID and waited for navigation/row. live4 failed an assumed end-of-field
insertion: exported accessibility attachment458C93C8-165B-4D90-8A95-6BF1484E8E10.txt
shows actual saved `offline editLive original notes`. Caret started at beginning;
store trims optional notes. Revised test retains the actual normalized edited value,
checks it contains original plus edit, and requires that exact value after each
relaunch and final sign-out/pull. No persistence bug established. Owned diagnostic25052
stalled; terminating only it let xcode24149 return true65.

## Actual UI inspection, warning investigation and limitations

Exported and visually inspected real screenshots in `/private/tmp/task10-ui-attachments`:
C870876A-151A-4119-8822-5DE72E0B2111.png shows visible review banner, selected saved
item/unit/125.00, save action and totals. CC52BF4D-E79C-4B72-A9F6-7AE96E3A69E3.png
shows confirmed legacy original name/email/mobile/address and historical11.00 total.
Manifest records the completed reminder screenshot too. Task9 retains largest text,
long descriptions and DST visual evidence; final full suite includes those inspections.

Invalid-frame warning reproduced in task10-red/focused1/2/3 and live4 on first client
name-field focus, not only Task9 notes focus. Inspected ClientEditView, shared SheetHeader,
KeyboardDismiss toolbar/KeyboardObserver, Root keyboard layout and relevant geometry
primitives. Client editor/header use fixed finite or flexible dimensions; no concrete
negative-frame calculation in this path was established. Warning does not block name/
notes entry, keyboard dismissal, save, navigation or visible content in passing journeys.
Remain **unclassified minor runtime warning**, not attributed to baseline. No speculative
shared layout refactor. Actual root cause and physical-device impact remain unverified.

Known environment warnings: Xcode AppIntents metadata, existing actor-isolation
TaxSettings warnings, Simulator duplicate accessibility-loader class/debugger lookup;
Wrangler allowed_sender_addresses/compatibility-date fallback and local cron/AI binding
notices. No dependency upgrade; local test extraction seam avoids external AI requests.

Physical iOS17/current-device upgrade, spoken VoiceOver/focus order, real OS permission/
notification delivery/taps, >32 OS deliveries and two-device sync/notification behavior
NOT RUN. Deterministic fake-center scheduling/auth lifecycle/cold-route tests and
simulator AX screenshots are distinguished explicitly in acceptance checklist. The
live sign-out/server restore is one simulator, not a claimed second physical device.

Live5 exit65 retained the earlier pre-normalization oracle (leading whitespace).
Live6 exit65 passed offline save + offline disk relaunch + online relaunch, then
-uiTestReset cleared OnboardingGate and returned to first-profile onboarding after
successful server pull. Exact baseline RootView signedIn branch and AppLaunch reset
were inspected with git show e22d9952a1c7eccdca08e2e70976ddee0a59ccb0; behavior unchanged.
The final leg now uses real Sign out, whose AuthViewModel.signOut invokes
onWipeLocalData, retaining first-run priming; re-login must pull the client notes.
This tests the real supported restore flow without adding a reset/auth bypass seam.

Occupied-default-port negative check: `scripts/ios-e2e-journeys.sh
LiveJourneyUITests/testClientWorkspaceOfflineRelaunchAndServerRestore`,
/private/tmp/task10-port-preflight.log, exit1 EADDRINUSE before migration/server/test.
Cleanup trap is installed before preflight, so ephemeral persistence is removed on
this error too. `bash -n scripts/ios-e2e-journeys.sh` exit0.

Live7 exit65: real logout/login restored the shell on its retained Profile tab, so
Home's Clients button was absent. Actual AX attachment90500217-568C-4672-A2F1-911F73FAFCF4.txt
shows profile.signout and tab.home. Fixed helper to select Home before opening
Clients. Owned stalled simctl diagnose29079 (child of xcode28788) terminated;
xcode returned65. This was a test navigation assumption, not lost server data.

## Exact focused xcode commands

Generated project with `xcodegen generate` (exit0). Captured xcode invocation lines:

```sh
# /private/tmp/task10-red.log
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination "platform=iOS Simulator,id=7962C2D3-C7A8-422D-A061-3C90F3D59206" -derivedDataPath /private/tmp/snapceipt-v2-derived "-only-testing:SnapceiptTests/ClientWorkspaceUpgradeTests" "-only-testing:SnapceiptUITests/ClientsJourneyUITests"
# /private/tmp/task10-focused1.log
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination "platform=iOS Simulator,id=7962C2D3-C7A8-422D-A061-3C90F3D59206" -derivedDataPath /private/tmp/snapceipt-v2-derived "-only-testing:SnapceiptTests/ClientWorkspaceUpgradeTests" "-only-testing:SnapceiptTests/ClientWorkspaceAppliedAckTests" "-only-testing:SnapceiptUITests/ClientsJourneyUITests"
# /private/tmp/task10-focused2.log
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination "platform=iOS Simulator,id=7962C2D3-C7A8-422D-A061-3C90F3D59206" -derivedDataPath /private/tmp/snapceipt-v2-derived "-only-testing:SnapceiptTests/ClientWorkspaceUpgradeTests" "-only-testing:SnapceiptTests/ClientWorkspaceAppliedAckTests" "-only-testing:SnapceiptTests/FixtureBundlingTests" "-only-testing:SnapceiptUITests/ClientsJourneyUITests"
# /private/tmp/task10-focused3.log
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination "platform=iOS Simulator,id=7962C2D3-C7A8-422D-A061-3C90F3D59206" -derivedDataPath /private/tmp/snapceipt-v2-derived "-only-testing:SnapceiptUITests/ClientsJourneyUITests/testAddNotesSavedItemQuoteRepeatAndReminder" "-only-testing:SnapceiptUITests/ClientsJourneyUITests/testLegacyAssociationRequiresConfirmationAndPreservesContact"
```

Live7/8 and final live command (same portable overrides; each run isolated):
```sh
IOS_E2E_PORT=48987 IOS_TEST_DESTINATION='platform=iOS Simulator,id=7962C2D3-C7A8-422D-A061-3C90F3D59206' IOS_DERIVED_DATA=/private/tmp/snapceipt-v2-derived scripts/ios-e2e-journeys.sh LiveJourneyUITests/testClientWorkspaceOfflineRelaunchAndServerRestore
```

All full HTTP runs use `npm run test:e2e`. Focused inbox correction runs use
`npm run test:e2e -- e2e/inbox.e2e.test.ts`. Logs/results above preserve failing
attempts as well as green results; no failure was omitted from the final result.

## Final local live result

Live8: /private/tmp/task10-live8.log, true exit0, one test passed in90.448s.
Verified owned listener29486 beneath Worker29478 on48987. Exact normalized edited
notes survived offline save, offline disk relaunch, online reconnect, real sign-out
local wipe and same-user login/server restoration. Worker log preserved at
/private/tmp/task10-live8-worker.log. No -uiTestStub on this flow, no remote/prod
endpoint, no second-device claim. Final full iOS now running after final Swift edits.

## Self-review

Read all changed production/harness/test diffs and maintained fixture sources.
No sync/cache overwrite reproduced, so no speculative production sync modification.
The only app change is the existing DEBUG fixture extension; TypeScript production
edits narrow already-guaranteed regex/index values and preserve runtime behavior.
Entitlement fixtures use local D1 only; existing denied/auth/rate contracts remain.
Rechecked exact integer-cent snapshots and nil additive defaults, disk configuration,
source-module identity and fixture hashes; no v2-created substitute. Reversible
harness fixes preserve existing defaults and reject unrelated listeners.

`git diff --check`, `bash -n scripts/ios-e2e-journeys.sh`, and Python generator syntax
compile pass. Python's generated __pycache__ was removed, never committed.
`git diff -- project.yml fastlane/metadata/en-AU/release_notes.txt` is empty.
NEXT_RELEASE is append-only and preserves staged1.x content. No generated Xcode
project or /private/tmp logs enter the commit. Full iOS result and final file list
follow when validation completes.

Self-review independently recomputed every provenance sourcesSHA256 entry directly
from `git show <baseline>:<path>`, plus maintained recipe and bundled SQLite hashes;
all matched. Final iOS unit stage passed779 Swift Testing tests/165 suites plus4
XCTest tests; full combined process still running UI at this checkpoint.

## Full iOS and justified covering rerun

Exact final full command:
```sh
xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,id=7962C2D3-C7A8-422D-A061-3C90F3D59206' -derivedDataPath /private/tmp/snapceipt-v2-derived -only-testing:SnapceiptTests -only-testing:SnapceiptUITests
```
/private/tmp/task10-ios-final.log, true exit65. Unit stage:779 Swift Testing tests
in165 suites passed, plus4 XCTest tests passed. UI:85 executed,9 skipped,3 failed,
73 passed,1491.674s. Full run remained uninterrupted; no exit masking or cleanup
needed. All15 screenshot tours and all5 Task9 client inspections passed.

Three failures and evidence:
1. New paid-repeat test used compact DatePicker.value; iOS26 returns empty String.
   The newly added nonempty assertion caught the previously vacuous !contains2020
   oracle. Failure recording extracted to /private/tmp/task10-date-failure.png and
   inspected: visible date15 Oct2026, correct fresh14-day default, not original2020.
   Task9 repeat screenshot3660DA51-4247-4E1A-B33D-90494D89A9B9.png independently shows
   same date. Revised assertion queries the accessible visible date descendant in
   en_AU, matching14-day default ±one day for local/UTC midnight boundaries; it
   requires existence and hittability and retains AX evidence. No debug date seam.
2. Existing QuotesUITests:50 Send missing. AX file
   /private/tmp/task10-final-failures/A7167D77-E35D-4463-99A7-A45B1D72742D.txt shows
   focused description, Keyboard, and keyboard.dismiss button. Test only tapped
   static New quote title. Baseline/current source equality captured in
   /private/tmp/task10-quotes-ui-baseline-evidence.log: QuoteEditorView lines46/48
   hide Send while keyboard visible,251/263 focus added line,89/101 static title,
   127/139 existing dismiss toolbar. Test now calls existing dismissKeyboard().
3. Existing SettingsExtraUITests:55 expected July→January to change FY label on
   arbitrary current date. On Oct1 both correctly FY2026-27. Baseline/current diff
   empty for the test, FinancialYear.swift, ReportsViewModel.swift and
   TaxSettingsViewModel.swift. FinancialYear.of line41 uses month>=startMonth;
   fiscal interpretation is correct. Use existing launchTour clock pinned Jan15
   2026 and exact beforeFY2025-26/afterFY2026-27 assertions. No financial code change.

Controller authorized the confirmed stale UI action/fixture repairs under existing
Task10 ruling. Only tests changed after the full run. Covering rerun command:
```sh
xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,id=7962C2D3-C7A8-422D-A061-3C90F3D59206' -derivedDataPath /private/tmp/snapceipt-v2-derived -only-testing:SnapceiptUITests/ClientsJourneyUITests -only-testing:SnapceiptUITests/QuotesUITests -only-testing:SnapceiptUITests/SettingsExtraUITests
```
Result: /private/tmp/task10-ios-corrections.log, true exit0;5 passed,1 existing skip,0 failures,171.953s.

Full hermetic UI skips:8 require E2E_LIVE (AuthRateLimitLive1, LiveJourney5,
LiveSmoke1, SyncFailure inflight-requeue1), and1 existing explicit unsupported
meals-default-to-capture threading test. New live client journey was separately
run/passed locally; other live-only tests were not claimed run in this task.
The preexisting meals threading gap remains outside v2 client scope.

## Changed files

- `Snapceipt/App/AppLaunch.swift`
- `SnapceiptTests/FixtureBundlingTests.swift`
- `SnapceiptUITests/LiveJourneyUITests.swift`
- `SnapceiptUITests/QuotesUITests.swift`
- `SnapceiptUITests/SettingsExtraUITests.swift`
- `docs/superpowers/plans/2026-10-01-v2-clients-repeat-work.md`
- `docs/superpowers/specs/2026-10-01-v2-clients-repeat-work-design.md`
- `e2e/extract.e2e.test.ts`
- `e2e/inbox.e2e.test.ts`
- `e2e/quotes-edges.e2e.test.ts`
- `e2e/quotes.e2e.test.ts`
- `e2e/rate-limit.e2e.test.ts`
- `e2e/snapceipt-export.e2e.test.ts`
- `e2e/snapceipt.e2e.test.ts`
- `fastlane/NEXT_RELEASE.md`
- `scripts/ios-e2e-journeys.sh`
- `src/lib/deepseek.ts`
- `test/apply-migrations.ts`
- `test/inbound.test.ts`
- `test/notify.test.ts`
- `vitest.config.ts`
- `SnapceiptTests/ClientWorkspaceAppliedAckTests.swift`
- `SnapceiptTests/ClientWorkspaceUpgradeTests.swift`
- `SnapceiptTests/Fixtures/v1-workspace.provenance.json`
- `SnapceiptTests/Fixtures/v1-workspace.store`
- `SnapceiptUITests/ClientsJourneyUITests.swift`
- `docs/testing/v2-client-workspace-checklist.md`
- `docs/testing/v2-client-workspace-pr-description.md`
- `e2e/helpers/entitlement.ts`
- `scripts/fixtures/README.md`
- `scripts/fixtures/generate-v1-workspace.py`
- `scripts/fixtures/v1-workspace-main.swift`
- `.superpowers/sdd/2026-10-01-v2-clients-repeat-work/task-10-report.md` (this maintained report)

## Final verification outcome

- Typecheck: exit0.
- Full Worker:816 tests/92 files, exit0; authorized CLI15s timeout only.
- Full HTTP E2E:36 tests/14 files, exit0 after documented baseline fixture repairs.
- Full iOS unit target:779 Swift Testing tests/165 suites +4 XCTest tests pass.
- Full iOS UI:85 executed,73passed/9skipped/3failed; combined command true65.
  Test-only fixes followed by one grouped covering run:5passed/1existing skip,
  zero failures, true0. No remaining failed automated assertion; no claim that the
  original full run was green. No broad rerun after these test-only fixes.
- New client live local journey:1 passed, true0,90.448s; owned listener proven.

Covering-run finalization: tests ended18:54:23; owned simctl diagnose43248 under
xcode42631 stalled for about3minutes. Controller explicitly authorized scoped
post-test diagnostic recovery. Reverified exact PPID and result path, then sent
SIGTERM only to43248. Parent xcode42631 returned actual0 and TEST SUCCEEDED at
18:57:23. Logs/xcresult remain; simulator diagnostics collection is partial. No
runner/xcode termination, no altered result, no unrelated process touched.

Exported covering-run attachment in /private/tmp/task10-corrections-date proves
actual AX subtree: DatePicker invoice.editor.dueDate → Button label Date Picker,
value15 Oct2026. The assertion matched this expected fresh14-day default and required
hittability. Both profile catalogs, original paid invoice separation, all3 new
journeys, quote sending and exact FY transition passed in that covering run.

Final source/diff review: no further functional changes needed. Unclassified
invalid-frame warning is the only new unresolved minor runtime observation; physical
VoiceOver, real OS delivery and multiple-device checks remain explicitly unrun.
The full hermetic suite's existing meals-default threading skip remains known
outside this feature. Baseline fiscal evidence file:
/private/tmp/task10-fy-ui-baseline-evidence.log. Final `git diff --cached --check`
passes; project.yml/version/build and upload-ready release_notes.txt untouched.

Commit subject: `test: verify v2 client workflows and upgrades` (local only).
