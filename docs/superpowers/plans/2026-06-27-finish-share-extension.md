# Finish the Share Extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the two `drainSharedReceipts` correctness bugs (double-import + silent data loss/false toast), add the cheap CI tests that cover the share handoff, then merge the branch as one PR and drive the TestFlight release.

**Architecture:** The Share Extension reads a shared receipt on-device and drops a JPEG + (usually) a parsed `ExtractedReceipt` draft into the App Group inbox (`ShareInbox`). The app's `ShellView.drainSharedReceipts` reads that inbox on launch + foreground and files each receipt under the active profile. The fixes are: a reentrancy guard so the two callers can't double-import, and gating file-deletion + the success toast on *confirmed persistence* (`CaptureViewModel.stage == .saved`) so a no-profile bail never drops a receipt behind a false "added" toast.

**Tech Stack:** Swift / SwiftUI / SwiftData, Swift Testing (`import Testing`, `@Test`, `#expect`). Backend is TypeScript on Cloudflare Workers (vitest). Xcode project is generated from `project.yml` via XcodeGen.

## Global Constraints

- iOS tests live in `SnapceiptTests/` and run with: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17'`. Scope a single file with `-only-testing:SnapceiptTests/<FileName>`.
- After adding ANY new file, regenerate the Xcode project first: `xcodegen generate` (project.yml globs sources; the generated `.xcodeproj` is gitignored).
- App Group id is exactly `group.app.snapceipt` — must match the `com.apple.security.application-groups` entry in both targets' entitlements. Never change it.
- **Gate commits on the real test exit code.** Never pipe `xcodebuild`/`vitest` through `grep`/`tail` before `&& git commit` — `grep` exits 0 and masks a red suite. Run the test command on its own, confirm it passed, then commit as a separate command.
- Backend tests: `npm test` (vitest). Backend deploy: `npm run deploy` (wrangler v4+).
- Branch is `feat/share-extension`; it merges to `main` as a **single** PR (the backend GST commit and the Cloud-AI settings commit stay in this PR per the spec).
- Swift Testing assertions are `#expect(...)`; force-unwrap (`x!`) in tests is the established style in this suite.

---

### Task 1: `ShareInbox` test seam + round-trip tests

`ShareInbox` keys off `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`, which returns `nil` in the unit-test host (no App Group entitlement), so a naive round-trip test silently no-ops. Add a minimal directory-override seam, then lock the write→pending→delete contract — including the corrupt-`.json` fallback that the drain depends on.

**Files:**
- Modify: `SnapceiptShareExtension/ShareExtensionStore.swift:15-17` (add `containerOverride`)
- Test: `SnapceiptTests/ShareInboxTests.swift` (create)

**Interfaces:**
- Consumes: `ShareInbox.write(jpeg:draft:)`, `ShareInbox.write(jpeg:text:)`, `ShareInbox.pending() -> [ShareInbox.Pending]`, `ShareInbox.delete(_:)`, `ExtractedReceipt` (memberwise init), `CategoryKey`.
- Produces: `ShareInbox.containerOverride: URL?` — a test-only static that, when set, replaces the live App Group container directory.

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/ShareInboxTests.swift`:

```swift
import Testing
import Foundation
@testable import Snapceipt

/// Serialized: these mutate the shared `ShareInbox.containerOverride` static.
@MainActor
@Suite(.serialized)
struct ShareInboxTests {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("share-inbox-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func draft() -> ExtractedReceipt {
        ExtractedReceipt(merchant: "Yakitori Bar", date: "2026-06-20", total: 30.00, gst: 2.70,
                         categoryKey: CategoryKey.meals.rawValue, deductible: 50,
                         lineItems: [.init(name: "Skewer", price: 3.00)],
                         confidence: 0.8, needsReview: false, extractionStatus: "pending")
    }

    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

    @Test("write(jpeg:draft:) round-trips through pending(); delete() clears it")
    func draftRoundTrip() throws {
        let dir = tempDir()
        ShareInbox.containerOverride = dir
        defer { ShareInbox.containerOverride = nil; try? FileManager.default.removeItem(at: dir) }

        try ShareInbox.write(jpeg: jpeg, draft: draft())
        let pending = ShareInbox.pending()
        #expect(pending.count == 1)
        let item = pending[0]
        #expect(item.jpeg == jpeg)
        #expect(item.draft?.merchant == "Yakitori Bar")
        #expect(item.draft?.extractionStatus == "pending")
        #expect(item.text == nil)

        ShareInbox.delete(item)
        #expect(ShareInbox.pending().isEmpty)
    }

    @Test("write(jpeg:text:) yields a pending with text and no draft")
    func textFallbackRoundTrip() throws {
        let dir = tempDir()
        ShareInbox.containerOverride = dir
        defer { ShareInbox.containerOverride = nil; try? FileManager.default.removeItem(at: dir) }

        try ShareInbox.write(jpeg: jpeg, text: "WOOLWORTHS\nTOTAL 12.00")
        let pending = ShareInbox.pending()
        #expect(pending.count == 1)
        #expect(pending[0].draft == nil)
        #expect(pending[0].text == "WOOLWORTHS\nTOTAL 12.00")

        ShareInbox.delete(pending[0])
        #expect(ShareInbox.pending().isEmpty)
    }

    @Test("a corrupt .json sidecar decodes to nil draft but the JPEG is still imported")
    func corruptDraftFallsBack() throws {
        let dir = tempDir()
        ShareInbox.containerOverride = dir
        defer { ShareInbox.containerOverride = nil; try? FileManager.default.removeItem(at: dir) }

        try ShareInbox.write(jpeg: jpeg, draft: draft())
        // Corrupt the .json on disk so decoding fails.
        let inbox = dir.appendingPathComponent("share-inbox", isDirectory: true)
        let jsonURL = try FileManager.default
            .contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" }!
        try Data("not valid json".utf8).write(to: jsonURL)

        let pending = ShareInbox.pending()
        #expect(pending.count == 1)
        #expect(pending[0].draft == nil)      // corrupt json -> nil, not a crash
        #expect(pending[0].jpeg == jpeg)       // JPEG still imported
    }
}
```

- [ ] **Step 2: Regenerate the project and run the test to verify it FAILS to compile**

Run:
```bash
cd /Users/yangqi/Documents/github/Snapceipt && xcodegen generate
xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/ShareInboxTests 2>&1 | tail -40
```
Expected: BUILD FAILURE — `type 'ShareInbox' has no member 'containerOverride'`.

- [ ] **Step 3: Add the override seam**

In `SnapceiptShareExtension/ShareExtensionStore.swift`, replace the `containerURL` computed property (lines 15-17):

```swift
    /// Test seam: when set, the inbox uses THIS directory instead of the live App Group
    /// container. The unit-test host lacks the App Group entitlement, so
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil and a round-trip test
    /// would silently no-op. Production never sets this (stays nil).
    static var containerOverride: URL?

    static var containerURL: URL? {
        containerOverride
            ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }
```

- [ ] **Step 4: Run the test to verify it PASSES**

Run:
```bash
xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/ShareInboxTests 2>&1 | tail -40
```
Expected: `TEST SUCCEEDED` — 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add SnapceiptShareExtension/ShareExtensionStore.swift SnapceiptTests/ShareInboxTests.swift
git commit -m "test(share): lock the ShareInbox handoff round-trip + add a container seam

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Lock the persistence signal the drain gates on

The Bug 2 fix makes `drainSharedReceipts` delete the inbox file + count a success ONLY when the receipt actually persisted, detected via `CaptureViewModel.stage == .saved`. Lock that contract: `ingestSharedDraft` reaches `.saved` and inserts a transaction when a profile resolves, and reaches a non-`.saved` stage (persisting nothing, setting `errorMessage`) when none does. These characterize existing `CaptureViewModel` behavior the drain fix depends on — they may pass immediately; they exist to prevent a future regression from silently breaking the drain's gate.

**Files:**
- Test: `SnapceiptTests/ShareDraftIngestTests.swift` (create)

**Interfaces:**
- Consumes: `CaptureViewModel(api:reducer:sync:profiles:context:userId:)`, `vm.ingestSharedDraft(image:draft:)`, `vm.stage` (`.saved`), `vm.errorMessage`, `ProfilesStore(context:sync:userId:)`, `store.setActive(_:)`, `ModelContainer.makeSnapceiptContainer(inMemory:)`, `Profile(...)`, `Transaction`, `PendingReceipt`.
- Produces: nothing consumed by later tasks (characterization only).

- [ ] **Step 1: Write the test**

Create `SnapceiptTests/ShareDraftIngestTests.swift`:

```swift
import Testing
import SwiftData
import UIKit
@testable import Snapceipt

@MainActor
struct ShareDraftIngestTests {

    @MainActor final class SpySync: SyncEnqueuing {
        func enqueue(op: String, entityType: EntityType, entity: any Syncable) {}
    }
    struct PassReducer: ImageReducing {
        func reduce(_ image: UIImage) -> Data { Data([0xFF, 0xD8, 0xFF]) }
    }

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
    }
    private func draft() -> ExtractedReceipt {
        ExtractedReceipt(merchant: "Yakitori Bar", date: "2026-06-20", total: 30.00, gst: 2.70,
                         categoryKey: CategoryKey.meals.rawValue, deductible: 50,
                         lineItems: [.init(name: "Skewer", price: 3.00)],
                         confidence: 0.8, needsReview: false, extractionStatus: "pending")
    }

    @Test("ingestSharedDraft files under the active profile and reaches .saved")
    func ingestDraftPersists() throws {
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let profile = Profile(userId: "u1", name: "Me", type: "personal",
                              accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A", isDefault: true)
        ctx.insert(profile); try ctx.save()
        let store = ProfilesStore(context: ctx, sync: SpySync(), userId: "u1")
        store.setActive(profile.id)
        let vm = CaptureViewModel(api: MockAPIClient(), reducer: PassReducer(), sync: SpySync(),
                                  profiles: store, context: ctx, userId: "u1")

        vm.ingestSharedDraft(image: image(), draft: draft())

        #expect(vm.stage == .saved)
        #expect(try ctx.fetch(FetchDescriptor<Transaction>()).count == 1)
        #expect(try ctx.fetch(FetchDescriptor<PendingReceipt>()).count == 1)
    }

    @Test("ingestSharedDraft with NO resolvable profile persists nothing and does NOT reach .saved")
    func ingestDraftNoProfileDoesNotPersist() throws {
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        // No profiles inserted -> activeProfile == nil, no profile matches activeProfileId.
        let store = ProfilesStore(context: ctx, sync: SpySync(), userId: "u1")
        let vm = CaptureViewModel(api: MockAPIClient(), reducer: PassReducer(), sync: SpySync(),
                                  profiles: store, context: ctx, userId: "u1")

        vm.ingestSharedDraft(image: image(), draft: draft())

        #expect(vm.stage != .saved)        // the exact gate the drain uses to NOT delete/count
        #expect(try ctx.fetch(FetchDescriptor<Transaction>()).isEmpty)
        #expect(vm.errorMessage != nil)
    }
}
```

- [ ] **Step 2: Regenerate the project and run the test**

Run:
```bash
cd /Users/yangqi/Documents/github/Snapceipt && xcodegen generate
xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/ShareDraftIngestTests 2>&1 | tail -40
```
Expected: `TEST SUCCEEDED` — 2 tests pass (they characterize existing `save()` behavior). If `ingestDraftNoProfileDoesNotPersist` fails because a transaction WAS persisted, stop — that means `save()`'s no-profile guard regressed and the Bug 2 fix's signal is unsound; investigate before continuing.

- [ ] **Step 3: Commit**

```bash
git add SnapceiptTests/ShareDraftIngestTests.swift
git commit -m "test(share): lock the persisted-vs-not signal the drain gates on

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Fix `drainSharedReceipts` (reentrancy guard + persistence-gated delete/count)

Add an `isDraining` guard so the launch `.task` and `scenePhase==.active` callers can't run concurrently and double-import. Add an up-front active-profile guard that leaves the inbox untouched (self-heals on a later drain) when no profile resolves. Gate per-item `delete` + `saved += 1` on `vm.stage == .saved` so a non-persisted item is never dropped behind a false success toast.

**Files:**
- Modify: `Snapceipt/App/RootView.swift` — add `@State private var isDraining = false` to `ShellView` (its `@State` block, near line 176); replace `drainSharedReceipts()` (lines 542-568).

**Interfaces:**
- Consumes: `ShareInbox.pending()`, `ShareInbox.delete(_:)`, `CaptureFactory.makeViewModel(...)`, `vm.ingestSharedDraft(image:draft:)`, `vm.ingestImport(image:text:)`, `vm.save()`, `vm.stage` (`.saved`), `profiles.activeProfile`, `profiles.profiles`, `profiles.activeProfileId`, `toasts.show(_:kind:)`.
- Produces: no new external interface (private method).

- [ ] **Step 1: Add the `isDraining` state flag**

In `Snapceipt/App/RootView.swift`, inside `struct ShellView` (begins line 150), add to the `@State` block near line 176 (next to `activityReloadToken`):

```swift
    @State private var isDraining = false
```

- [ ] **Step 2: Replace the `drainSharedReceipts()` body**

Replace the whole method (currently lines 542-568) with:

```swift
    private func drainSharedReceipts() async {
        // Reentrancy guard: this runs from BOTH the launch `.task` and `scenePhase==.active`.
        // Without it, a cold-launch-from-share plus a quick background/foreground re-reads the same
        // not-yet-deleted inbox file (the per-item delete lands AFTER an await) and imports the
        // receipt twice — and the duplicate survives reconcile as two cloud-upgraded txns. Mirrors
        // CaptureHost.drainQueues.
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        let pending = ShareInbox.pending()
        guard !pending.isEmpty else { return }
        // No profile to file under → leave the inbox files untouched and try again on the next drain
        // (it self-heals once a profile exists), rather than deleting them and dropping the receipts
        // behind a false "added" toast.
        guard profiles.activeProfile != nil
            || profiles.profiles.contains(where: { $0.id == profiles.activeProfileId }) else { return }

        // Visible feedback so a share that just opened the app shows it's "reading" right away.
        toasts.show(pending.count == 1 ? "Reading shared receipt…"
                                       : "Reading \(pending.count) shared receipts…", kind: .info)
        var saved = 0
        for item in pending {
            // A non-decodable JPEG can never be imported — drop it so it doesn't re-read forever.
            guard let image = UIImage(data: item.jpeg) else { ShareInbox.delete(item); continue }
            let vm = CaptureFactory.makeViewModel(
                api: captureAPI, sync: sync, profiles: profiles,
                context: profiles.context, userId: profiles.userId, reachability: reachability)
            if let draft = item.draft {
                // Already read on-device by the extension popup — file it as-is, no re-extract.
                vm.ingestSharedDraft(image: image, draft: draft)
            } else {
                // No draft (non-FM device / extraction failed) — re-extract via the normal pipeline.
                await vm.ingestImport(image: image, text: item.text)
                vm.save()   // toProfileId defaults to the active profile
            }
            // Only delete the handoff + count it once the receipt ACTUALLY persisted. `save()` bails
            // WITHOUT persisting if no profile resolves; deleting then would lose the receipt and the
            // success toast would lie. A not-persisted item is left for a later drain.
            if vm.stage == .saved {
                ShareInbox.delete(item)
                saved += 1
            }
        }
        if saved > 0 {
            toasts.show(saved == 1 ? "Receipt added" : "\(saved) receipts added", kind: .success)
        }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
cd /Users/yangqi/Documents/github/Snapceipt && xcodegen generate
xcodebuild build -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -25
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run the share tests to verify nothing regressed**

Run:
```bash
xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/ShareInboxTests -only-testing:SnapceiptTests/ShareDraftIngestTests -only-testing:SnapceiptTests/CaptureViewModelTests 2>&1 | tail -40
```
Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/App/RootView.swift
git commit -m "fix(share): guard drainSharedReceipts against double-import + silent drop

Add an isDraining reentrancy guard (the drain runs from both launch and foreground),
an up-front active-profile guard that leaves the inbox for a later drain when no
profile resolves, and gate delete + the success toast on stage==.saved so a no-profile
bail never drops a receipt behind a false 'Receipt added'.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Version bump + full verification

Bump the marketing version for this user-facing feature, then prove the whole iOS suite + the backend vitest suite are green before merging.

**Files:**
- Modify: `project.yml:27` (`MARKETING_VERSION`)

**Interfaces:** none.

- [ ] **Step 1: Bump `MARKETING_VERSION`**

In `project.yml`, line 27, change:
```yaml
    MARKETING_VERSION: "1.0.0"
```
to:
```yaml
    MARKETING_VERSION: "1.1.0"
```
(Leave `CURRENT_PROJECT_VERSION` as-is — fastlane bumps the build number at archive time.)

- [ ] **Step 2: Run the FULL iOS unit suite**

Run (on its own — do NOT pipe through grep before committing):
```bash
cd /Users/yangqi/Documents/github/Snapceipt && xcodegen generate
xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests 2>&1 | tail -60
```
Expected: `TEST SUCCEEDED`. If anything fails, fix it before proceeding — do not commit a red suite.

- [ ] **Step 3: Run the backend vitest suite**

Run:
```bash
npm test 2>&1 | tail -30
```
Expected: all vitest files pass (includes `test/deepseek.test.ts`, the GST-trust change carried on this branch).

- [ ] **Step 4: Commit the version bump**

```bash
git add project.yml
git commit -m "chore(share): bump MARKETING_VERSION to 1.1.0 for the Share Extension

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Merge as a single PR

Integrate the branch into `main`. One PR per the spec — it carries the Share Extension, the backend GST fix, and the Cloud-AI settings change together.

**Files:** none.

**Interfaces:** none.

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feat/share-extension
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --base main --head feat/share-extension \
  --title "Share Extension: import receipts from other apps' share sheets" \
  --body "$(cat <<'EOF'
Adds a Share Extension so Snapceipt appears in other apps' share sheets for images + PDFs. The extension reads the receipt on-device in a popup and hands a JPEG + parsed draft to the app via the App Group inbox; the app drains it on launch/foreground and files it under the active profile.

This PR also carries two changes that rode along on the branch (kept together by decision):
- backend: trust the vision AI's GST on the image path (`src/lib/deepseek.ts`) — **needs its own `npm run deploy`**, it does not deploy on merge.
- settings: plan-based Cloud-AI default + auto-off at the usage cap.

Fixes in this PR over the prior branch state:
- `drainSharedReceipts` reentrancy guard (no more double-import; the dup also survived reconcile as two txns).
- persistence-gated delete/toast (no more silent data loss behind a false "Receipt added").
- new CI tests: ShareInbox handoff round-trip + the persisted-vs-not signal.

Release gate (post-merge, collaborative): register App Group `group.app.snapceipt` on both App IDs in the portal, then `fastlane certs`, then `fastlane beta`; device-verify the real share-sheet e2e.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2a: Confirm CI is green on the PR, then merge** (with the user)

This is the user's call to click merge (or `gh pr merge --squash`). Do not merge a red PR. After merge, `git checkout main && git pull`.

---

### Task 6: Drive the TestFlight release (collaborative — strict order)

Order matters: enabling the capability must precede `fastlane certs`, or `match` silently regenerates a profile missing the App Group entitlement and `gym` fails later with a confusing "provisioning profile doesn't include the application-groups entitlement".

**Files:** none.

**Interfaces:** none.

- [ ] **Step 1 (USER, GUI-only): register the App Group on both App IDs**

In the Apple Developer portal (developer.apple.com → Certificates, Identifiers & Profiles):
1. Identifiers → App Groups → ensure `group.app.snapceipt` exists (create if missing).
2. Enable the **App Groups** capability on App ID `app.snapceipt.Snapceipt` and assign `group.app.snapceipt`.
3. Enable the **App Groups** capability on App ID `app.snapceipt.Snapceipt.ShareExtension` (create the App ID if `match`/portal doesn't have it) and assign `group.app.snapceipt`.

(Claude cannot do this headlessly — it needs the signed-in Xcode/portal GUI.)

- [ ] **Step 2: Regenerate the match App Store profiles WITH the entitlement**

```bash
cd /Users/yangqi/Documents/github/Snapceipt && bundle exec fastlane certs
```
Expected: regenerates App Store profiles for `app.snapceipt.Snapceipt` and `app.snapceipt.Snapceipt.ShareExtension` carrying `group.app.snapceipt`.

- [ ] **Step 3: Build + upload to TestFlight (internal beta)**

```bash
BETA_INTERNAL_ONLY=1 bundle exec fastlane beta 2>&1 | tail -40
```
Expected: archive succeeds, uploads a new build to TestFlight internal.

- [ ] **Step 4 (USER, on device): verify the real share-sheet e2e**

On a device with the new TestFlight build:
1. Share an **image** receipt from Photos → Snapceipt → popup reads → tap Save → open Snapceipt → the receipt appears **exactly once** under the active profile.
2. Share a **PDF** receipt from Files → same flow → appears exactly once.
3. Confirm a **non-English** receipt's deterministic fallback imports (then gets cloud-upgraded on next foreground).
4. Confirm no duplicate after a quick background/foreground right after a share-launch.

---

### Task 7: Post-merge housekeeping

**Files:** none (deploy + memory).

**Interfaces:** none.

- [ ] **Step 1: Deploy the backend Worker change**

The GST-trust change (`src/lib/deepseek.ts`) ships on the Worker pipeline, not with the app binary:
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm run deploy 2>&1 | tail -20
```
Expected: `wrangler deploy` succeeds; the GST-trust change is live in prod.

- [ ] **Step 2: Update the `share-extension.md` memory**

Update `/Users/yangqi/.claude/projects/-Users-yangqi-Documents-github-Snapceipt/memory/share-extension.md` so it no longer says "unmerged / device-install BLOCKED": record that it merged to `main`, the two drain bugs were fixed with CI tests, and the App Group was registered + shipped to TestFlight (note the build number). Keep the hard-won device-only learnings (jetsam, non-English fallback, `extensionContext.open` blocked).

---

## Known limitations / deferred follow-ups

- **Non-FM device + shared plain image (no draft, no text):** the extension can't extract (no on-device AI) and hands off a JPEG with no text; the app's `ingestImport(text: nil)` only stages to `.confirm` and can't re-extract headlessly, so `stage` never reaches `.saved`. With this fix that item is **left in the inbox** (no data loss, no false toast) and re-read each drain, which re-shows the "Reading…" toast. This is a pre-existing functional gap (the headless no-draft-image path never actually imported); it's now non-destructive instead of a silent drop. Follow-up: have the no-draft drain path OCR + extract, or surface a "review in app" action and clear the file. Out of scope here.
- **No true cross-process e2e in CI** (real foreign-app share sheet, ~220 MB jetsam ceiling, signing) — covered by the manual device checks in Task 6.
- Nice-to-have edges from the audit (dead `jpeg(from:)` `scale=1` branch, poster-size-PDF 2× intermediate, orphan-JPEG on a file-protection-locked read, cross-user filing on sign-out) remain deferred.

---

## Self-Review

**Spec coverage:**
- Spec Part 1 Bug 1 (reentrancy) → Task 3 (`isDraining`). ✓
- Spec Part 1 Bug 2 (silent drop / false toast) → Task 3 (up-front profile guard + `.saved`-gated delete/count), signal locked by Task 2. ✓
- Spec Part 2 tests (ShareInbox round-trip + container seam; ingest + no-profile guard) → Task 1 + Task 2. ✓
- Spec Part 3 (verify green, version bump, one PR, Worker needs own deploy) → Task 4 + Task 5 + Task 7 Step 1. ✓
- Spec Part 4 (App Group portal → certs → beta → device e2e, strict order) → Task 6. ✓
- Spec Part 4 housekeeping (memory update) → Task 7 Step 2. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every test step shows full test bodies and exact run commands with expected output. ✓

**Type consistency:** `ShareInbox.containerOverride` defined in Task 1 and used in Task 1 tests; `vm.stage == .saved` is the single gate name used in Task 2 (lock) and Task 3 (fix); `ingestSharedDraft` / `ingestImport` / `save` signatures match the read sources; `ExtractedReceipt` memberwise init args and `CategoryKey.meals` verified against source. ✓
