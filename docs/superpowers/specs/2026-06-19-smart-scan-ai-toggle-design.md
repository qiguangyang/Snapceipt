# Smart Scan AI toggle — design

**Date:** 2026-06-19
**Branch:** `feature/smart-scan-ai-toggle`
**Status:** approved (design), pending implementation plan

## Goal

Let a tester (and any user) switch DeepSeek-based receipt recognition **on vs off**
from inside the app, in a normal Release/TestFlight build, and see which engine
produced a given result so the two can be compared back-to-back on the same receipt.

App-only change: **no backend change, no Cloudflare Worker deploy, one new app build.**

## Background (current behavior)

- Receipt recognition is a hybrid pipeline: on-device Vision OCR → `POST /extract`
  on the Worker, which calls DeepSeek (`deepseek-v4-flash`) under a monthly
  smart-scan cap (free 10 / pro 500).
- The app already has an on-device fallback: `CaptureViewModel.extract()`
  (`Snapceipt/Features/Capture/CaptureViewModel.swift:84`) calls `/extract` in a
  `do`, and on **any** failure runs `HeuristicParser.parse(recognizedLines)` in the
  `catch`, building the draft via `ExtractedReceipt(parsed:capturedAt:)`.
- That fallback builder hard-codes `extractionStatus: "pending"`
  (`Snapceipt/Features/Capture/ExtractedReceipt.swift:158`). `PendingExtractionReconciler`
  (`Snapceipt/Features/Capture/PendingExtractionReconciler.swift:24`) later finds
  `source=="scan" && extractionStatus=="pending"` txns on reconnect, re-calls
  `/extract` (DeepSeek), and upgrades them to `done`.
- All test seams (`AppLaunch`, `-uiTestOffline`) are `#if DEBUG` and compiled out of
  Release. So a TestFlight-testable switch must live in normal Release code, persisted
  like other settings (`UserDefaults` `sc.*` keys).
- The `/extract` response `meta` (model, stub, attempts, latencyMs, capped, smartScan)
  is decoded into `ExtractionMeta` but only `capped`/`smartScan` are used; the rest is
  never surfaced in the UI.

## Decisions (from brainstorming)

1. **"Off" = on-device heuristic** (app-only). ON keeps today's DeepSeek server flow.
2. **Visibility = everyone**: a normal labeled setting in Profile → Capture & tax.
3. **Compare signal = developer diagnostic line** on the Review screen, shown to all users.
4. **Label = "Smart Scan AI"**, default **ON** (current behavior unchanged).

## Behavior matrix

| Toggle | What runs | `extractionStatus` | Smart-scan slot | Diagnostic line |
|--------|-----------|--------------------|-----------------|-----------------|
| ON (default) | `POST /extract` → DeepSeek (today's flow) | `done` | consumed when under cap & LLM used | `deepseek-v4-flash · N try · <server>ms · conf X` (+ `stub`/`capped` if set) |
| ON, offline | on-device `HeuristicParser` (existing catch) | `pending` (re-extracts on reconnect) | none | `on-device (offline) · conf X · queued` |
| **OFF** | on-device `HeuristicParser` directly, no network | **`done`** | none | `on-device heuristic · conf X` |

### Critical correctness point

A deliberate **OFF** result MUST be saved with `extractionStatus: "done"`. If it were
`"pending"` (today's offline default), `PendingExtractionReconciler` would silently
re-run DeepSeek on the next reconnect and overwrite the heuristic result — defeating
the toggle. Avoiding this is the design's main job.

## Components

### 1. Settings accessor — `AppSettings.smartScanEnabled`

New small type (e.g. `Snapceipt/App/AppSettings.swift`).

- Backed by `UserDefaults.standard`, key `sc.smartScan.enabled`.
- **Returns `true` when the key is unset** (so default is ON — `UserDefaults.bool`
  returns `false` for missing keys, so this needs an explicit object-nil check or a
  registered default).
- Read by `CaptureViewModel` (not a View) at scan time.

### 2. Toggle row — `ProfileTabView.captureAndTaxGroup`

- New `smartScanRow` inserted in `captureAndTaxGroup`
  (`Snapceipt/Features/Profiles/ProfileTabView.swift:81`), styled like the existing
  `aiAutoCategoriseRow` (icon `sparkles`, title "Smart Scan AI", trailing `Toggle`).
- Bound with `@AppStorage("sc.smartScan.enabled")` (default true).
- New `AccessibilityID` for the row/toggle.
- Note: the existing `aiAutoCategorise` toggle is inert `@State`; this new toggle is
  the real, persisted control and is separate from it.

### 3. Capture flow — `CaptureViewModel.extract()`

Branch on `AppSettings.smartScanEnabled`:

- **ON** → current body unchanged: `do { api.extract … } catch { heuristic, pending }`.
- **OFF** → `HeuristicParser.parse(recognizedLines)`, build draft with
  `extractionStatus: "done"`, reset cap signals (`smartScanCapped/Cap/Used`), no network.

Both branches set `diagnostics` (below). Capture a client wall-time measurement around
the work for the diagnostic line.

`ExtractedReceipt(parsed:capturedAt:)`
(`Snapceipt/Features/Capture/ExtractedReceipt.swift:146`) gains an
`extractionStatus: String = "pending"` parameter (default preserves today's offline
behavior; the OFF branch passes `"done"`).

### 4. Diagnostics — `ScanDiagnostics`

New value type set on `CaptureViewModel` in every `extract()` branch and rendered on
the Review screen.

```
struct ScanDiagnostics: Equatable {
    enum Engine: String { case deepseek, onDeviceHeuristic, offlineHeuristic }
    var engine: Engine
    var model: String?      // meta.model (ON path)
    var clientMs: Int       // client-measured wall time (all paths)
    var serverMs: Int?      // meta.latencyMs (ON path)
    var attempts: Int?      // meta.attempts (ON path)
    var stub: Bool?         // meta.stub (ON path)
    var capped: Bool?       // meta.capped (ON path)
    var confidence: Double  // draft.confidence (all paths)
}
```

Rendered as a compact monospaced line near the existing `aiBanner`
(`Snapceipt/Features/Capture/Views/ReviewStep.swift:104`), reading `vm.diagnostics`
(ReviewStep already holds `vm`). Visible to all users by decision (3).

## Edge cases

- **isAi flag**: an OFF result is not AI. Verify `ReceiptMapper.map` sets `isAi`
  correctly (heuristic → not AI) so the history/list doesn't mislabel it. Adjust if
  it currently hard-codes AI on save.
- **Smart-scan cap**: OFF makes no server call, so it consumes no slot — good for
  repeated testing.
- **Offline + OFF**: already offline-safe (no network attempted).
- **Existing offline (ON) path**: unchanged — still `pending` + queued + reconciled.

## Testing (TDD)

`CaptureViewModel` is `@MainActor` with protocol-injected deps (mockable). Add tests:

1. **OFF** → `api.extract` is NOT called; `HeuristicParser` result used;
   `draft.extractionStatus == "done"`; `diagnostics.engine == .onDeviceHeuristic`.
2. **ON success** → `api.extract` called once; `draft.extractionStatus == "done"`;
   `diagnostics.engine == .deepseek` with model/attempts from meta.
3. **ON failure** → heuristic used; `draft.extractionStatus == "pending"` (unchanged);
   `diagnostics.engine == .offlineHeuristic`.
4. **Default** → with the key unset, `AppSettings.smartScanEnabled == true`.

## Files touched

- `Snapceipt/App/AppSettings.swift` (new) — settings accessor.
- `Snapceipt/Features/Capture/ScanDiagnostics.swift` (new) — diagnostics value (or
  co-locate in CaptureViewModel).
- `Snapceipt/Features/Profiles/ProfileTabView.swift` — toggle row.
- `Snapceipt/Features/Capture/CaptureViewModel.swift` — branch + diagnostics.
- `Snapceipt/Features/Capture/ExtractedReceipt.swift` — `extractionStatus` param.
- `Snapceipt/Features/Capture/Views/ReviewStep.swift` — diagnostic line.
- `Snapceipt/.../AccessibilityID` — new id(s).
- Tests under the app's test target for the cases above.

## Out of scope

- No backend / Worker change; no server-side "skip DeepSeek" request flag.
- No side-by-side dual-engine run on a single scan.
- No TestFlight-only gating (toggle is intentionally visible to everyone).
