# V2 client workspace verification evidence

This durable ledger preserves the original Task 10 evidence and final-review fix verification.
The original combined full iOS run failed; its later covering runs are recorded separately.
Manual device gates and unclassified runtime observations remain open. Temporary raw logs
are supporting artifacts; commands, actual outcomes and limitations are preserved here.

## Archived Task 10 — v2 client workflows, genuine upgrade, release verification

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

## Task10 review fix round1 — stock macOS Bash3 optional-array compatibility

Base db973c7. Review Important finding reproduced: the optional XCODE_ARGS array
was empty when IOS_DERIVED_DATA was absent; Bash3.2 with set-u reported
`XCODE_ARGS[@]: unbound variable` before invoking xcodebuild. Replaced the empty
optional array with a nonempty complete xcode argv containing fixed test/scheme/
destination arguments, then appended the optional derived-data pair and nonempty
class selections. Defaults, quoting, environment and production behavior unchanged.
Only scripts/ios-e2e-journeys.sh and this report changed.

Verification uses `/private/tmp/task10-harness-args.py`, which invokes the actual
repository script with `/bin/bash`3.2.57 and PATH command stubs. Stub node/npx/curl/
lsof/xcodegen/xcodebuild avoid real networking, migrations, builds and simulator
launches. A harmless owned sleep stands in for the Worker lifetime and is cleaned
up by the real script's cleanup trap. NUL-delimited argv capture verifies argument
boundaries; no source fragment or alternate runner is substituted.

RED command: `python3 /private/tmp/task10-harness-args.py >
/private/tmp/task10-harness-bash3-red.log 2>&1`, actual verifier exit1.
- Default/no overrides: unbound-array stderr; xcodebuild never called. The actual
  runner returned0 via its existing EXIT cleanup, so checking exit alone would
  falsely pass; verifier correctly required recorded argv and failed.
- Explicit derived-data/destination/port and two class selectors: correct argv,
  actual runner0, passed even before correction.
- No derived override with synthetic xcode23: xcode never called, actual runner0,
  verifier rejected missing argv and lost expected23.

GREEN command: `python3 /private/tmp/task10-harness-args.py >
/private/tmp/task10-harness-bash3-green.log 2>&1`, actual verifier exit0.
All3 cases pass: default runner0 with original iPhone16 destination/default
LiveJourneyUITests/8787; overrides runner0 with space-containing derived and
persist paths preserved as single arguments, alternate destination/port and two
class selectors; synthetic xcode23 propagates runner23. Exact node/npx argv and
TEST_RUNNER_E2E_LIVE/API_BASE_URL are checked; default temporary persistence is
removed on exit. Log records the captured argv, actual exits and Bash version.
`/bin/bash -n scripts/ios-e2e-journeys.sh` and `git diff --check` exit0.

Self-review: whole argv is always nonempty under set-u, optional pair order remains
unchanged, and selected classes retain quoting. No app/backend/full-suite rerun:
this is the scoped shell correction requested by review. Previously accepted
full/covering/live evidence stands; minor frame warning and manual device gates
remain explicitly open. No push/deploy/publication.


---

# Final-review fix wave — v2 client workspace

Base `6549b62b0d52e74511d6c173d0b07b19786b6942`. One local implementation wave for all
five Important findings and the one Minor finding in final-review.md. No subagents
or independent reviewer dispatched. No remote PR/push/merge/deploy/upload/version
change; unrelated Leanology processes and its port 8787 listener were not touched.

## Per-finding changes and regression evidence

1. **Client CRUD atomicity (P1).** ClientStore now creates/edits/deletes in a fresh
   autosave-disabled ModelContext. The domain client and every committed live
   follow-up tombstone are staged by one checked real SyncEngine persistAndEnqueue
   call and saved together. Both working and durable client scope/liveness are
   checked. Only operation fields are mirrored after success; deletion preserves
   pending titles/notes and does not save unrelated dirty objects. Creation returns
   the committed client in the caller context. A failed write leaves form input and
   error visible, with no success callback or reminder-change notification.
   Regression injects a throwing save after inspecting actual staged outbox rows:
   create sees 1, deduplicated edit sees 1, delete with two follow-ups sees 4 (existing
   upsert plus three tombstones). Failure preserves durable domain/outbox and shared
   input; successful retries preserve mutation ID/base revision/time and commit all
   tombstones, including a completed follow-up, then emit one change signal.
   RED showed stage counts were wrong and unrelated pending notes had been saved.
   GREEN passes using real engine staging and fresh-context durable reads. This is
   an injected failure at the checked commit boundary after real staging; it does
   not claim an induced SQLite fetch corruption or disk-full failure.
2. **Dedupe order (P1).** Refresh only the pending payload, preserving original
   baseRev and createdAt. Strict increasing timestamps still order new rows.
   Real-engine push regression queues 199 independent entries, client at position
   200, then linked quote/invoice/follow-up and both kinds of lines. Re-edits client
   and document parents; a scripted API rejects any child seen before its parent.
   RED rejected dependents and left failed rows; GREEN sends batches [200, 5], client
   last in first batch, latest client payload/original baseRev, parents before lines,
   and drains the queue. The supported-iOS acknowledgement regression remains in
   the full unit run.
3. **Contact clears (P2).** Client pull mapping checks field presence for email,
   mobilePhone and address, applying explicit null as nil and retaining omissions.
   Real-engine pull regression first sends a legacy omission, then explicit nulls
   into a populated client. RepeatQuote/RepeatInvoice use cleared current contacts;
   original historical quote/invoice snapshots remain unchanged. RED retained old
   contacts and repeated them; GREEN passes.
4. **UTF-16 limits (P2).** Name/notes/title validation uses utf16.count to match
   existing backend wire limits; no server contract change. Exact limit and
   limit+1 tests use surrogate-pair 🛠 and combining e+acute, each two UTF-16 units.
   Names/titles accept 200 and reject 201; notes accept 10,000 and reject 10,001.
   Rejected input leaves durable outbox unchanged, creates no extra reminder and
   emits no scheduling/reconciliation success signal. RED accepted all overflows;
   GREEN passes both parameterized cases. Binding spec now states the convention.
5. **Catalog currency (P2).** Both editor insertion methods resolve the saved
   destination currency (or current profile default for an unsaved new document)
   and reject mismatch before appending a line. Localized explanation names both
   currencies and asks for a manual price in document currency. Existing picker
   throwing callback retains the sheet and shows this error; each price now shows
   its denomination. No FX, repricing or currency mutation. Tests change profile
   AUD→NZD, exercise both new editor kinds and repeats retaining AUD, reject wrong
   items without adding lines, accept matching ones, save, and verify source/item
   currencies. RED silently appended mismatches; GREEN passes. Existing first client
   UI journey now checks NZD denomination, mismatch explanation and retained picker,
   then successfully selects compatible AUD item. One DEBUG-only fixture item added.
6. **Durable evidence (P3).** Preserved the complete prior Task 10 command/outcome
   ledger in docs/testing/v2-client-workspace-evidence.md and added this verification.
   Checklist and PR description link there. Original failed full iOS run, subsequent
   covering repairs, live result, Bash3 harness fix and manual gates remain explicit.
   Added named invalid-frame classification follow-up to checklist. No claim of a
   green full UI suite; no evidence depends solely on a soon-deleted report link.

## Exact verification commands and actual outcomes

`xcodegen generate`: exit 0 after adding the focused test file. Generated project
is ignored and not committed. Default signing throughout.

### RED fixture compilation correction

```sh
xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,id=7962C2D3-C7A8-422D-A061-3C90F3D59206' -derivedDataPath /private/tmp/snapceipt-v2-derived -only-testing:SnapceiptTests/ClientWorkspaceFinalFixTests > /private/tmp/final-fix-red.log 2>&1
```
Actual exit **65**. Test build failed on six missing initializer arguments in new
line-item fixtures. Added required description/price arguments. This was not counted
as a behavioral RED result; no production fix had yet been applied.

### Behavioral RED

```sh
xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,id=7962C2D3-C7A8-422D-A061-3C90F3D59206' -derivedDataPath /private/tmp/snapceipt-v2-derived -only-testing:SnapceiptTests/ClientWorkspaceFinalFixTests > /private/tmp/final-fix-red2.log 2>&1
```
Actual exit **65**, **5 tests / 1 suite failed with 28 issues**, 1.300 seconds.
All five defects reproduced, as detailed above. Exact representative output:
- `stagedCounts == [1]` failed; `stagedCounts.suffix(2) == [1, 4]` failed.
- Fresh persisted unrelated client's notes `== "Saved"` failed.
- `Parent must already exist` failed; first batch last entity was not client.
- Client and repeated quote/invoice nil-contact expectations failed.
- Unicode overflow: `an error was expected but none was thrown` for name/notes/title.
- Both editor kinds: `Currency mismatch must be rejected` issues.

Post-assertion diagnostics stalled. Controller authorized SIGTERM only to child
55006. Fresh ps verified PPID 54925, owned simulator UUID and exact
Test-Snapceipt-2026.10.01_19-29-11-+1000.xcresult diagnostic path; test footer already
reported failure. Sent SIGTERM only to 55006; parent xcode remained alive and
returned its actual 65. Diagnostic collection partial; logs/xcresult retained.

### Focused GREEN

```sh
xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,id=7962C2D3-C7A8-422D-A061-3C90F3D59206' -derivedDataPath /private/tmp/snapceipt-v2-derived -only-testing:SnapceiptTests/ClientWorkspaceFinalFixTests > /private/tmp/final-fix-green.log 2>&1
```
Actual exit **0**, `Test run with 5 tests in 1 suite passed`, 1.093 seconds,
`TEST SUCCEEDED`. Unicode test has two parameterized cases. Signal assertions were
added to CRUD/Unicode tests and passed. Compile exposed a test-helper Sendable
warning: added explicit @MainActor to nested SignalCount before covering run below;
no product changes after full unit run.

### Full iOS unit target, once after focused GREEN

```sh
xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,id=7962C2D3-C7A8-422D-A061-3C90F3D59206' -derivedDataPath /private/tmp/snapceipt-v2-derived -only-testing:SnapceiptTests > /private/tmp/final-fix-units.log 2>&1
```
Actual exit **0**, **784 Swift Testing tests / 166 suites passed**, 10.208 seconds,
plus **4 XCTest unit tests passed**, `TEST SUCCEEDED`. This includes existing sync,
client/store/editor, repeat, follow-up, upgrade and cached-line acknowledgement
integration coverage. No full unit rerun solely for the helper actor annotation.

### Covering UI journeys and final focused test annotation

```sh
xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,id=7962C2D3-C7A8-422D-A061-3C90F3D59206' -derivedDataPath /private/tmp/snapceipt-v2-derived -only-testing:SnapceiptTests/ClientWorkspaceFinalFixTests -only-testing:SnapceiptUITests/ClientsJourneyUITests > /private/tmp/final-fix-journeys.log 2>&1
```
Actual exit **0**, **5 focused Swift Testing tests / 1 suite passed** (1.141 seconds),
**3 UI journeys passed / 0 skipped / 0 failed** (122.979 seconds), `TEST SUCCEEDED`.
Covering compile has no new SignalCount/Sendable warning. Existing AppIntents metadata
warning remains. First journey reproduced `Invalid frame dimension (negative or
non-finite)`; functional path and screenshot passed, classification remains open.

Owned post-test diagnostic child 56152 remained collecting after assertions ended.
Controller's scoped recovery authorization applied: freshly verified PPID 55930,
simulator UUID and Test-Snapceipt-2026.10.01_19-33-59-+1000.xcresult path; at 1m23s
sent SIGTERM only to that diagnostic child. Xcode was untouched and returned actual
0 / TEST SUCCEEDED. Diagnostic collection partial, logs and xcresult preserved.

Exported owned screenshot attachments (xcresulttool exit 0 after granting its normal
report-cache access) and visually inspected
/private/tmp/final-fix-attachments/E2D13B68-5AAD-4C82-B56B-9CB7357D3220.png. It shows
the full legible mismatch explanation, AUD 125.00 and NZD 125.00 price labels, Close
and Add actions, and retained Saved items sheet. No clipping observed in this view.
Exact export command:
```sh
xcrun xcresulttool export attachments --path /private/tmp/snapceipt-v2-derived/Logs/Test/Test-Snapceipt-2026.10.01_19-33-59-+1000.xcresult --output-path /private/tmp/final-fix-attachments --test-id 'ClientsJourneyUITests/testAddNotesSavedItemQuoteRepeatAndReminder()'
```
No package-wide UI or HTTP rerun: this fix changes iOS domain/sync/editor paths,
with backend contracts unchanged. `git diff --check` exits 0.

## Files changed

- Snapceipt/Features/Clients/ClientStore.swift
- Snapceipt/Features/Clients/FollowUps/ClientFollowUpStore.swift
- Snapceipt/Sync/SyncEngine.swift
- Snapceipt/Sync/SyncEntityRegistry.swift
- Snapceipt/Features/Catalog/CatalogStore.swift
- Snapceipt/Features/Catalog/CatalogPickerSheet.swift
- Snapceipt/Features/Quotes/QuoteEditorViewModel.swift
- Snapceipt/Features/Invoices/InvoiceEditorViewModel.swift
- SnapceiptTests/ClientWorkspaceFinalFixTests.swift
- Snapceipt/App/AppLaunch.swift (DEBUG fixture only)
- SnapceiptUITests/ClientsJourneyUITests.swift
- docs/superpowers/specs/2026-10-01-v2-clients-repeat-work-design.md
- docs/testing/v2-client-workspace-checklist.md
- docs/testing/v2-client-workspace-pr-description.md
- docs/testing/v2-client-workspace-evidence.md
- .superpowers/sdd/2026-10-01-v2-clients-repeat-work/final-fix-report.md

## Self-review and retained concerns

Read final changed production/test diff. No unrelated restructuring; SyncEngine and
registry are large preexisting files but edits are narrowly limited to dedupe and
client contact mapping. Checked success-only mirroring, ownership checks, failure
propagation, one domain/outbox transaction, unchanged revision and queue position,
parent-before-line order, immutable historical snapshots, and direct editor guards.
The UI retains the existing picker error contract; no new modal flow or silent FX.

Known baseline actor/AppIntents and Wrangler compatibility/configuration warnings
remain disclosed in durable evidence. New test-helper warning is explicitly fixed
and its covering compile checked. The invalid-frame warning remains an unclassified
minor runtime concern; no baseline attribution or speculative layout repair.
Physical iOS17/current-device upgrade, spoken VoiceOver, actual OS permissions and
notification delivery/taps (>32/DST/travel included), and two-device behavior remain
manual release gates. This task neither runs nor labels them passed. Previous full
UI exit65 and covering success remain separate. No production latency claim.

## Additional authorized fix — B1: earlier document acquires a later client

The user explicitly authorized one additional fix and scoped review after the
remaining Important B1 finding. This is that targeted fix, not a new whole-branch
review. Base: `c5b0afb287bc2d53142995a4379ced97bad2a0b6`.
Implementation head: `e78052030a7797e92aefe960ea0d731d90e7e7bf` (`fix: order pending client dependencies before sync batching`).
The following evidence-only commit appends this ledger; it changes no production
or test behavior. All five other addressed review findings remain intact.

### Change and self-review

`SyncEngine.pendingOutbox` now orders the complete pending snapshot before `push`
splits it into batches of 200. It resolves typed references for quote/invoice/
follow-up → client and quote/invoice line → its document, only when an actual
pending upsert of that parent is present. It moves prerequisites ahead of dependents
and retains the original FIFO order for other rows and multiple operations on the
same entity. Deduplication still refreshes only payload, retaining mutation ID,
original baseRev and createdAt. Nothing rewrites queue metadata or document fields.

The traversal uses row indexes, typed entity keys and explicit visiting/emitted
states. Each pending row appears exactly once; it neither conflates entity types
nor drops duplicate entity mutations. An iterative stack bounds recursion risk.
The supported type graph is acyclic by construction; unrecognized reverse fields
cannot create edges, and visiting-state detection also prevents a malformed cycle
from hanging traversal. This is ordering, not a second validation implementation:
omitted/null/non-string references, absent or failed parents, and delete-only parents
leave normal server validation authoritative. Deletes do not gain dependencies from
stale payload fields. Earlier operations on a moved parent retain their sequence.

New real-store regression covers both quote and invoice with 0 and 199 unrelated
preceding mutations (four cases). An existing server document starts unlinked with
revision 7, then its edit and line are queued. ClientStore creates a later client
and explicitly links the earlier document via linkExistingDocuments. The scripted
API applies the same new-client existence rejection boundary as the server and
asserts the updated document precedes its line. After the fix it receives client,
updated document and line in that order; batches are [3] or [200, 2]. It sees the
latest link/contact payload and original revision; mutation IDs/count are unchanged,
the server-side link/line apply, and the durable outbox drains without failed rows.
The original create-client/create-dependents/re-edit-parent test still passes,
including its [200, 5] boundary and both line kinds.

A separate real-engine push test verifies absent/null/unknown/non-string references,
failed or delete-only parents, irrelevant back-reference fields and delete payloads
retain FIFO and unchanged wire payloads. Scripted validation rejections remain
failed in the outbox (alongside the previously failed parent); accepted mutations
are acknowledged normally. Count and unique mutation-ID checks catch dropped or
repeated wire mutations. This test passed before and after the fix.

Self-reviewed the narrow diff for identity/revision preservation, complete-snapshot
ordering before batching, stable unrelated order, parent-before-line order,
termination and unchanged rejection handling. Corrected one test comment after the
full run to describe its cross-type back references precisely; no executable code
changed after full-unit verification. No new UI/backend/entitlement or release work.

### Exact RED/GREEN and integration evidence

Default signing, the explicitly owned simulator, and the existing derived-data
location are unchanged. No new files require xcodegen in this wave.

Behavioral RED, before the production ordering change:
```sh
xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,id=7962C2D3-C7A8-422D-A061-3C90F3D59206' -derivedDataPath /private/tmp/snapceipt-v2-derived -only-testing:SnapceiptTests/ClientWorkspaceFinalFixTests > /private/tmp/final-b1-red.log 2>&1
```
Actual exit **65**. **7 tests / 1 suite, 20 issues**, 2.976 seconds, `TEST FAILED`.
The new association test failed in all four quote/invoice × 0/199 cases. The six
other functions passed, including all prior five fixes and the new unchanged-
reference/rejection test. Representative failures:
- `New client must exist before the association upsert`.
- `The updated parent must precede its line`.
- Sent suffix was document/line/client instead of client/document/line.
- Server document link stayed unset; failed outbox mutation remained stranded.
No fixture compilation correction or test-oracle weakening was required.

Focused GREEN:
```sh
xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,id=7962C2D3-C7A8-422D-A061-3C90F3D59206' -derivedDataPath /private/tmp/snapceipt-v2-derived -only-testing:SnapceiptTests/ClientWorkspaceFinalFixTests > /private/tmp/final-b1-green.log 2>&1
```
Actual exit **0**. **7 tests / 1 suite passed**, 3.248 seconds, `TEST SUCCEEDED`.
New association test passes all four parameterized cases; existing Unicode test
still passes both cases. No previously addressed finding regressed.

Full iOS unit target, once after focused GREEN:
```sh
xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,id=7962C2D3-C7A8-422D-A061-3C90F3D59206' -derivedDataPath /private/tmp/snapceipt-v2-derived -only-testing:SnapceiptTests > /private/tmp/final-b1-units.log 2>&1
```
Actual exit **0**. **786 Swift Testing tests / 166 suites passed**, 11.137 seconds,
plus **4 XCTest tests passed**, `TEST SUCCEEDED`. Existing sync, association,
CRUD atomicity, repeat/contact, Unicode, catalog currency and acknowledgement tests
are included. No UI/HTTP/full Worker repeat for unchanged paths.

All three xcode commands returned their actual exits naturally in this wave; no
diagnostic child or runner was terminated. Logs and xcresults remain available.
Focused compile retains the baseline AppIntents metadata extraction warning; no
new compiler warning was reported. `git diff --check` and staged diff check exit 0.

### Changed files and retained boundaries

- `Snapceipt/Sync/SyncEngine.swift`
- `SnapceiptTests/ClientWorkspaceFinalFixTests.swift`
- `.superpowers/sdd/2026-10-01-v2-clients-repeat-work/final-fix-report.md` (append)
- `docs/testing/v2-client-workspace-evidence.md` (same durable append)

No new correctness concern found in self-review. This does not reclassify or close
the prior unclassified invalid-frame warning, physical iOS17/current-device upgrade,
spoken VoiceOver, actual OS notification permissions/delivery/taps/DST/travel/>32,
or two-device release gates. The original full UI failure and subsequent covering
success remain separate historical outcomes. Prior baseline actor/AppIntents and
Wrangler warnings remain disclosed. No unrelated Leanology process/listener touched,
no remote PR/push/merge/deploy/upload/version change, and no subagent or reviewer
was spawned. A fresh scoped rereview is the controller's next step.
