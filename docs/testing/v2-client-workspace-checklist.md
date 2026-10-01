# V2 client workspace acceptance and rollout

Scope: business-profile Clients hub, private notes, explicit document links,
saved items, manual repeat drafts and in-app follow-ups. Five bottom tabs and
iOS 17 deployment support remain. No automatic customer messaging or recurrence.

## Automated evidence

The detailed command/exit/count ledger is
[Task 10 report](../../.superpowers/sdd/2026-10-01-v2-clients-repeat-work/task-10-report.md).
Final results are recorded there; do not interpret the existence of a test as a pass.

| Acceptance | Owning automated verification |
| --- | --- |
| Add notes, choose a saved item in a new quote, save to history, Create again, review, reminder, completion | ClientsJourneyUITests |
| Paid invoice repeats as draft, reset dates, no copied payments/income; immutable original snapshots | ClientsJourneyUITests + RepeatWorkServiceTests |
| Two business profiles isolate clients, notes, documents, reminders and saved items; foreign account rejected | ClientsJourneyUITests + scoped store/history/server suites |
| Legacy selection alone does not link; explicit confirmation retains original contact/amount/date/PDF | ClientsJourneyUITests + LegacyClientLinkerTests |
| Genuine v1 disk upgrades with IDs/values intact, optional new fields nil, no memory fallback | ClientWorkspaceUpgradeTests + FixtureBundlingTests |
| Existing cached draft/outbox edited and deleted lines survive applied acknowledgements on iOS | ClientWorkspaceAppliedAckTests, real SyncEngine + scripted API response |
| Offline edit survives disk relaunch and restores from local server after sign-out wipes local data | LiveJourneyUITests.testClientWorkspaceOfflineRelaunchAndServerRestore |
| Save failure preserves input and unrelated pending changes, emits no success | Client/Catalog/FollowUp stores + editor atomic-save suites |
| Completion/reopen/reschedule/deletion, account switch/sign-out/deletion cancel pending and delivered requests | FollowUp store/scheduler/lifecycle suites; fake notification center |
| Permission denial/disabled device leaves in-app reminders; >32 chooses earliest eligible reminders | FollowUpNotificationSchedulerTests; fake notification center |
| Stale/completed/deleted/foreign and cold-launch taps validate current auth/profile before navigation | ClientReminderRouteTests + notification delegate/integration tests |
| Sydney DST gap and overlap, safe timestamps, displayed first offset | FollowUpTime/store suites + ClientWorkspaceInspectionUITests |
| Long notes/descriptions, largest Dynamic Type, keyboard dismissal, Back/Close | ClientWorkspaceInspectionUITests + journey screenshots |
| Old payload omissions retain v2 fields and server-owned PDF state | Backend v2 sync tests + iOS authoritative pull tests |

## Physical-device release gates — NOT RUN in this task

- [ ] On a physical iOS 17 device and current supported iOS device: install the
  shipping v1 app, retain real data, install v2, verify offline CRUD and relaunch.
  The automated fixture was created from v1 source on an iOS simulator; this is
  additional device/OS coverage, not a substitute for the fixture test.
- [ ] Spoken VoiceOver: labels, focus order, headings, notes, document history,
  reminder controls and full Back/Close journeys. XCUITest accessibility queries
  prove discoverability only; they do not prove spoken output or focus order.
- [ ] Real OS notification prompt: deny permission, create/reschedule/complete/
  delete reminder, verify In-app only. Re-enable through Settings and verify
  actual foreground/background/terminated delivery and taps.
- [ ] Real delivered/pending notification cleanup on client deletion, sign-out
  and account deletion; test stale notification taps after account switch.
- [ ] Two physical devices for one account: verify notes/catalog/link/follow-up
  sync, offline conflict/reconnect, completion cancellation after each device
  syncs, timezone changes, and independent per-device opt-in.
- [ ] Real OS delivery with >32 reminders and across DST/travel/timezone changes.
  Deterministic planner/fake-center tests are not OS delivery evidence.

## Notification semantics

Follow-ups are in-app records first. Local notifications need explicit opt-in on
each device and OS permission. Multiple opted-in devices may each notify; local
scheduling is not a centralized single-delivery service. Remote changes cancel or
replace device reminders after that device syncs/reconciles. No backend cron or
customer contact is introduced. Completed/past-due records remain in-app as designed.

## Snapshot and isolation checks

Client/catalog edits and associations never rewrite historical document snapshots.
Repeat work makes a fresh unissued/unsent draft, resets dates/identifiers/PDF state,
retains saved currency/tax/line prices (legacy nil GST freezes the effective 10%
default), and copies no payments or income. Show balances separately by currency.
Workspace queries use authenticated user plus active profile; planner/navigation
first validate ownership/liveness of an explicit target business profile.

## Server-first additive rollout — execution not performed

1. Review migrations `0019` onward and deploy them to staging through the existing
   staging workflow; deploy compatible Worker support and run old/new payload checks.
2. Complete automated verification and the physical-device gates above.
3. Deploy the additive D1 changes and Worker support before distributing v2 iOS.
   Monitor rejected mutations and preserve compatibility with installed v1 clients.
4. During separately authorized release preparation, reconcile staged 1.x work,
   set 2.0.0 and build, then replace upload-ready release notes using reviewed copy.
5. App Store upload and publication require their separate execution instruction.

No production deployment, push, App Store upload or publication is part of Task 10.
