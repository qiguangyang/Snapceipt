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
