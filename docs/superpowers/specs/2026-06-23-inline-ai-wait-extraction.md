# Inline AI wait + survive-exit extraction — design

**Date:** 2026-06-23
**Goal (product owner, verbatim):** "wait for the AI to finish inline, but exit the app won't pause the processing, user can quit waiting and the receipt will update to app when it is ready."

## Behavior target
1. **Wait for the AI inline.** The scanning screen waits for the server `/extract` result and lands the AI result on Review (no premature "offline" fallback in the normal case).
2. **Quit waiting.** A **"Review now"** button (shown immediately) drops to Review with the on-device result, kept `pending` so the AI still upgrades it later.
3. **Exit won't pause; updates when ready.** Leaving during scanning auto-saves the scan as a `pending` receipt; the `PendingExtractionReconciler` re-extracts and upgrades it on next foreground (survives force-kill, since it's persisted).

## Root cause (verified)
- `CaptureViewModel.extract()` runs inline on the *view's* Task; its `catch` is a catch-all that turns **any** error — including the `CancellationError` from view/app teardown — into the "offline → pending" path. (`CaptureViewModel.swift:106,146`)
- Server `/extract` is genuinely slow (~31s: attempt 1 stalls to the 20s abort, attempt 2 ~11s) vs the client's 20s budget, so even a real wait times out. (`deepseek.ts`, `APIClient.swift:210`)

## Changes

### Server — `src/lib/deepseek.ts`
- `TIMEOUT_MS` 20_000 → **15_000** (a stalled attempt 1 fails fast; a good ~11s call still fits).
- `MAX_ATTEMPTS` 3 → **2** (worst case ~30s, aligned with the client budget so the server doesn't keep working after the client gives up).
- `max_tokens` **unchanged** (1500) — lowering it doesn't reduce latency for sub-cap responses and risks truncating long receipts.

### Client timeout — `Snapceipt/Sync/APIClient.swift`
- `/extract` request timeout 20 → **35** (covers a fast-failed attempt + one good attempt + network overhead; the "Review now" button is the escape hatch for impatience).

### `CaptureViewModel.swift`
- Add `@ObservationIgnored private var extractTask: Task<Void, Never>?`.
- `onScanned`: launch the network call as an **owned** unstructured task, then await its value:
  `let t = Task { await self.extract() }; extractTask = t; await t.value`.
  Ownership decouples it from *view* cancellation (fixes the false-offline); awaiting `.value` keeps `onScanned`'s completion contract (existing tests + auto-advance).
- `extract()` `catch`: **return early on cancellation** (`error is CancellationError || Task.isCancelled`) — leave UI state to whoever cancelled. Genuine transport/decode errors keep the existing on-device **pending** fallback.
- `reviewNow()` (quit waiting): guard `.scanning`; build the on-device heuristic draft (**pending**), set diagnostics engine `.onDeviceQueued`, `stage = .review`, then `extractTask?.cancel()`. The guard makes it a no-op if the AI already landed (race-safe).
- `autosaveOnExitIfScanning()`: guard `.scanning`; cancel the task; ensure an on-device pending draft exists; `save(..., autoSaved: true)`.
- `save(toProfileId:, autoSaved: Bool = false)`: thread `autoSaved` into the created `PendingReceipt`.
- `reset()`: `extractTask?.cancel()`.

### `ScanDiagnostics` (in `CaptureViewModel.swift`)
- Add engine case `.onDeviceQueued` → summary `"on-device · finishing with AI…"` (network is fine, AI still running — distinct from the misleading `"on-device (offline)"`).

### `PendingReceipt.swift`
- Add `var autoSaved: Bool = false` (+ init param). Local-only model; property default avoids the SwiftData migration wipe.

### `PendingExtractionReconciler.swift`
- `reconcileOne`: if `receipt.autoSaved` → **full scalar replace** from the AI result (merchant, signed amountCents, txnDate, catKey, gstCents/gstSource, gstFree, capital, deductiblePct, isAi) — the user never reviewed it, so the AI result should fully replace the placeholder. Else → current **classification-only** update (preserves a total/merchant the user saw/confirmed on Review). Line-item replacement deferred. Both → `done` + save + enqueue.

### `ScanStep.swift` + `CaptureFlow.swift`
- `ScanStep` gains `onUseOnDevice: () -> Void`; a "Review now" button shown immediately.
- `.scanning` case wires `onUseOnDevice: { vm.reviewNow() }` and wraps close as `{ vm.autosaveOnExitIfScanning(); onClose() }`.

### `RootView.swift`
- Run `PendingExtractionReconciler.reconcile()` on app foreground (not only when CaptureHost is visible) so saved-pending receipts upgrade even if the user leaves the Snap tab. Lists/detail refresh via SwiftData `@Query`.
- Also trigger auto-save on app background while a scan is mid-flight (`scenePhase` → `.background` && `.scanning`).

## Decisions
- Leaving during scanning (close **or** app-background) auto-saves as pending (product owner's choice).
- "Review now" shown immediately (product owner's choice).
- Full AI replace only for **never-reviewed** (auto-saved) placeholders; reviewed receipts get classification-only enrichment to avoid stomping what the user saw. Line-item replacement deferred.

## Out of scope (follow-ups)
- Line-item replacement on reconcile.
- In-place AI apply on an *open* Review screen with edit-aware merge.
