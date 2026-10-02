# Add business client workspaces and safe repeat work

Business profiles now offer a Clients hub with contact details/private notes,
explicitly linked quote/invoice history, balances grouped by saved currency, reusable
items and in-app follow-ups. Create again prepares a fresh draft with reset dates and
no copied payments or income. Existing documents retain historical contact, tax,
price and PDF snapshots; linking older work requires explicit confirmation.

The additive server/client sync contract preserves fields omitted by old apps and
server-owned PDF metadata. Checked atomic domain/outbox writes preserve typed input
on save failure. Reminder scheduling is local and opt-in per device, with scoped
ownership checks before cross-profile navigation. No automatic customer messages
or recurring documents.

Design: [v2 specification](../superpowers/specs/2026-10-01-v2-clients-repeat-work-design.md).
Implementation: [plan and reconciled rulings](../superpowers/plans/2026-10-01-v2-clients-repeat-work.md).
Acceptance: [checklist](v2-client-workspace-checklist.md).
Detailed evidence: [Verification evidence](v2-client-workspace-evidence.md).

## Validation

- TypeScript typecheck passes without dependency upgrades or strictness changes.
- Worker tests:816 passed across92 files. Existing61-request export test8.325s with
  explicitly authorized CLI15s timeout; checked-in configuration unchanged.
- Real HTTP end-to-end:36 passed across14 files. Repaired confirmed pre-v2 stale
  fixtures/contracts, keeping production authentication, rate limits and Pro gates.
- Genuine v1 fixture comes from archived e22d995 baseline production @Model/schema
  sources compiled as original Snapceipt module and run on iOS26.5 Simulator. Bundled
  SQLite/source/recipe provenance hashes; throwing disk upgrade verifies original
  receipt/client/document/line/payment data and nil optional additions.
- Local live Worker journey:1 passed, including offline disk relaunch and exact
  edited-note restoration after real sign-out wipes local data. Owned loopback
  listener verified; no production endpoint or auth bypass.
- Full iOS:779 Swift Testing tests +4 XCTest unit tests passed. UI executed85,
  with9 explicit skips and3 test-oracle/action failures; after evidence-based
  test-only repairs, the covering rerun passed5 tests with1 existing skip.
  The full run's exit65 and covering exit0 are retained in the report. Post-test
  simulator diagnostic collection required owned-child cleanup and is partial.
  Eight full-run skips require live mode; one existing meals-default threading
  test documents functionality outside this feature's scope.

Final review fixes also make client CRUD atomic with its outbox, retain parent
queue positions on deduplication, apply explicit contact clears, match UTF-16 text
limits, and reject saved-item currency mismatches in both editors. The final unit
run passes 784 Swift Testing tests plus 4 XCTest tests. All three scoped client
journeys pass, including the visible currency explanation; exact outcomes are in
the durable evidence. Earlier failed full UI and later covering results above
remain distinct.

## Release boundaries and remaining gates

Deploy additive D1 migrations and Worker support first through the existing staging/
release workflow; distribute v2 iOS only after server compatibility verification.
Proposed What's New is in NEXT_RELEASE. Current staged1.x metadata, project version/
build and upload-ready release_notes.txt are preserved.

Physical-device/iOS17 upgrade, spoken VoiceOver, actual notification permission/
delivery/taps and second-device behavior remain explicit manual release gates.
Simulator client-field focus reproduces an unclassified minor invalid-frame warning;
passing entry/save/navigation and screenshot checks have not established its cause.

This is a local review draft. No remote PR, push, production deploy, App Store upload
or publication was performed.
