# Finish the Share Extension — Design

Date: 2026-06-27
Branch: `feat/share-extension`
Status: approved, ready for implementation plan

## Goal

Take the Share Extension from code-complete to merged-and-shipped. The feature
(import image/PDF receipts from other apps' share sheets, read on-device in a
popup, hand off to the app via an App Group inbox) is functionally built and
device-tested through TestFlight build 58→59. "Finishing" means closing two
correctness bugs, adding the cheap tests that cover them, merging to `main` as a
single PR, and driving the TestFlight release together.

## Scope decisions (confirmed with user)

- **One PR.** The whole branch merges as a single PR. The branch also carries a
  backend Worker change (`src/lib/deepseek.ts`, the "trust the vision AI's GST"
  fix) and an all-users Cloud-AI settings change (`da80ec2`); these stay in the
  same PR rather than being split out.
- **Gate the merge on the bug fixes + tests being green** — not merge-first,
  fix-later.
- **Collaborative release.** Some steps (Apple Developer portal, Xcode sign-in)
  are GUI-only and must be done by the user; the rest is automated via fastlane.

## Out of scope

- Splitting the branch into 3 PRs (considered, declined).
- Closing device-only verification gaps in CI (jetsam ceiling, real
  cross-process share sheet) — these remain documented manual-verify items.
- Nice-to-have edges: dead `jpeg(from:)` `scale=1` branch, poster-size-PDF 2×
  intermediate memory edge, cross-user filing on sign-out/sign-in, orphan-JPEG
  leak on a file-protection-locked read. All low-impact; deferred.

## Part 1 — Fix the two drain bugs (`Snapceipt/App/RootView.swift`, `drainSharedReceipts`)

Both defects live in `drainSharedReceipts`, which runs on every launch and every
foreground. One change set addresses both.

### Bug 1 — double-import (reentrancy)

`drainSharedReceipts` is invoked from both the launch `.task` and
`scenePhase == .active`, with no reentrancy guard. The inbox file is deleted only
*after* an `await vm.ingestImport(...)` suspension point, so a
cold-launch-from-share plus a quick background/foreground re-reads the same
not-yet-deleted file and imports it twice. The duplicate survives reconcile:
`reconcilePendingExtractions` independently cloud-upgrades both copies, yielding
two near-identical completed receipts that do not look like obvious dupes.

**Fix:** add an `isDraining` MainActor guard, mirroring the proven pattern in
`CaptureHost.swift:92-94`. The guard serializes the two callers so the second
early-returns. Keep **delete-after-success** (do not delete before processing):
the guard removes the concurrency hazard, and delete-after preserves the receipt
if ingest throws.

### Bug 2 — silent data loss + false "Receipt added" toast

When no active profile resolves at save time, `save()` bails without persisting
(sets `errorMessage`, returns `Void`). The drain ignores this: it deletes the
inbox file via `defer` and runs `saved += 1` unconditionally, so the receipt is
permanently lost while the user is shown "Receipt added". Worst-case failure mode
for an expense app.

**Fix — claim-on-confirmed-persistence:**
- Resolve the active profile once at the top of the drain; if there is none,
  abort the drain and **leave the inbox files in place** for a later drain (it
  self-heals once a profile exists). Do not delete, do not increment, do not toast.
- Only `delete` the inbox file and `saved += 1` when the receipt actually
  persisted. Never report success for a non-save.

## Part 2 — Close the cheap test gap

The drain/ingest path — exactly where both bugs live — currently has zero tests.
Add (all CI-runnable, no device):

- **`ShareInbox` round-trip** (`SnapceiptShareExtension/ShareExtensionStore.swift`):
  write → `pending()` → `delete`, plus the corrupt-`.json` branch that falls back
  to re-extract while still importing the JPEG. Requires a seam: make the App
  Group container directory injectable, because the test host lacks the App Group
  entitlement and `containerURL(forSecurityApplicationGroupIdentifier:)` returns
  `nil` (a naive test would silently no-op). The seam points the container at a
  temp dir.
- **`ingestSharedDraft` / `ingestImport`**
  (`Snapceipt/Features/Capture/CaptureViewModel.swift`) against an in-memory
  `ModelContainer`, including the new no-profile guard: assert the file is **not**
  dropped and no false success is reported.

Device-only risks stay as documented manual-verify items.

## Part 3 — Verify green + merge (one PR)

- Run the full iOS suite (`xcodebuild` test) and `vitest` (`test/deepseek.test.ts`);
  confirm green before merge. (Gate commits on the real exit code — do not pipe
  through `grep`.)
- Bump `MARKETING_VERSION` in `project.yml` (still `1.0.0`) for this user-facing
  feature.
- Merge `feat/share-extension` to `main` as a single PR.
- **Implication of one PR:** the backend Worker change (`src/lib/deepseek.ts`)
  rides in this PR but still needs its own `wrangler deploy` to prod — merging to
  `main` does not deploy the Worker. Call this out at merge time.

## Part 4 — Drive the release together (collaborative, strict order)

Order matters: if `fastlane certs` runs before the capability is enabled, match
silently regenerates a profile missing the entitlement and `gym` fails later with
a confusing error.

1. **User, in the Apple Developer portal:** enable App Groups on **both** App IDs
   (`app.snapceipt.Snapceipt` and `app.snapceipt.Snapceipt.ShareExtension`) and
   register `group.app.snapceipt`. (GUI-only; cannot be done headlessly.)
2. `bundle exec fastlane certs` — regenerates the match App Store profiles with
   the new entitlement. Must run after step 1.
3. `bundle exec fastlane beta` (`BETA_INTERNAL_ONLY=1`) — builds + uploads to
   TestFlight.
4. **Device verify the real e2e:** share an image *and* a PDF from another app →
   popup reads on-device → open app → receipt lands **exactly once**, under the
   correct profile; confirm the non-English deterministic fallback.
5. Post-merge housekeeping: update the `share-extension.md` memory entry (it still
   records the feature as unmerged / device-install BLOCKED).

## Acceptance criteria

- Both drain bugs fixed; the new `ShareInbox` and ingest tests cover them and pass.
- Full iOS suite + vitest green.
- `MARKETING_VERSION` bumped; branch merged to `main` as one PR.
- Worker change deployed to prod via `wrangler deploy`.
- App Group enabled on both App IDs; `fastlane certs` + `fastlane beta` produce a
  TestFlight build that installs on device.
- Real share-sheet e2e verified on device: image + PDF each import exactly once,
  correct profile, non-English fallback works.
- `share-extension.md` memory updated to reflect merged + shipped state.
