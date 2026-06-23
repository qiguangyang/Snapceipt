# On-device extraction via Apple Foundation Models — design

**Date:** 2026-06-24
**Status:** Approved (brainstorming) — pending spec review → implementation plan.

## Goal

Replace the brittle on-device regex parser (`HeuristicParser`) with **Apple Foundation Models** (the built-in on-device LLM, iOS 26+) as the on-device extraction engine. On devices that don't support Foundation Models (FM), use **cloud AI only**; offline scans on those devices **queue** and are filled in by the cloud reconciler when connectivity returns. Primary product goal: **offline robustness** (great offline extraction on capable devices; no garbage shown anywhere).

## Decisions (from brainstorming)

1. **FM is the on-device engine**; the old `HeuristicParser` is **removed**.
2. **Non-FM device + offline → queue as pending**, auto-filled by the existing `PendingExtractionReconciler` (cloud) when online. No on-device parsing.
3. **Smart Scan OFF (no-cloud / privacy)** → FM if available, else **manual entry** (never cloud).
4. **FM-capable device, online → FM first; if FM confidence is low, re-extract via cloud and upgrade the draft in place.**

## Behavior matrix

> **Supersedes the original FM-first design below.** The `smartScanEnabled` toggle is now
> surfaced as **"Cloud AI"**: **ON = Cloud mode** (cloud first, on-device only as the offline
> fallback), **OFF = on-device-only / private mode** (never cloud). Cloud is never used in OFF
> mode or while offline.

| Toggle (Cloud AI) | Network | Device | Behavior |
|---|---|---|---|
| ON | online | any | cloud `/extract` (`.deepseek`) |
| ON | offline | FM-capable | FM on-device; if `confidence < UPGRADE_THRESHOLD` → mark `pending` → reconciler cloud-upgrades when online; else `done` |
| ON | offline | non-FM | empty draft saved `pending` → reconciler cloud-fills when online |
| OFF | any | FM-capable | FM on-device only — result stays `done` even if low-confidence (`needsReview` surfaces it). Never cloud, never pending |
| OFF | any | non-FM | manual empty draft (`done`). No AI, no cloud |

`UPGRADE_THRESHOLD = 0.8` to start (matches the server's `needsReview` line); tune on device.

Key change from the original design: when Cloud AI is ON **and online**, the cloud runs first
(it is the more accurate engine) — FM is the **offline** fallback, not the first choice. In OFF
mode an FM result is never escalated to the cloud and never marked `pending`, regardless of
confidence.

## Architecture

A capability-and-network **router** in `CaptureViewModel.extract()` selects the engine per the matrix. FM is wrapped in a focused, `#available(iOS 26)`-gated unit. Everything reuses the machinery already built this session: the `draftRevision` in-place refresh and the `PendingExtractionReconciler`.

### New components

**`OnDeviceAI`** (e.g. `Snapceipt/Features/Capture/Scanner/OnDeviceAI.swift`)
- `static var isAvailable: Bool` — `if #available(iOS 26, *)` AND `SystemLanguageModel.default.availability == .available`. Treat `.deviceNotEligible` / `.appleIntelligenceNotEnabled` / `.modelNotReady` as unavailable (router falls to the non-FM path).
- One place so the routing and any UI gating share a single source of truth.

**`FoundationModelExtractor`** (`Snapceipt/Features/Capture/Scanner/FoundationModelExtractor.swift`, `@available(iOS 26, *)`)
- A `@Generable` result type:
  ```
  @Generable struct FMReceipt {
    var merchant: String
    var date: String?            // nullable — backfilled like the cloud path
    var total: Double            // Decimal isn't @Generable-native; convert in app code
    var gst: Double?
    @Guide(.anyOf(CategoryKey.allCases.map(\.rawValue))) var category: String
    var deductible: Int?
    @Guide(.count(0...50)) var lineItems: [FMLineItem]   // bound the array for context safety
    var confidence: Double
  }
  @Generable struct FMLineItem { var name: String; var price: Double }
  ```
- `func extract(ocrText:layoutText:capturedAt:) async throws -> ExtractedReceipt` — builds a one-shot `LanguageModelSession`, prompts with the SAME content the cloud gets (the `ReceiptRows` layout text, tail-trimmed), takes the typed `FMReceipt`, maps Double→Decimal, applies the **FM output guards** (below), and returns an `ExtractedReceipt` + confidence.
- **Context window (4096 tokens, iOS 26):** pre-trim noise/tail before prompting; if `tokenCount` (iOS 26.4+) or a thrown `.exceededContextWindowSize` indicates overflow, surface a typed failure so the router falls back (cloud if online, else pending). One-shot session per receipt (no transcript accumulation).
- System prompt: reuse the intent of the server `SYSTEM_PROMPT` (AU receipts, the 9 categories, GST rule, line-item exclusion rules), trimmed for the smaller model.

**FM output guards** (small, in `FoundationModelExtractor` or a helper)
- GST: honor a printed `GST $X` if present, else cap at ~`total/11` with the surcharge allowance (mirror the server's `reconcileGst` intent). Total must be ≥ 0. This is the safety net for a 3B model — NOT a re-introduction of the old heuristic parser.

### Changed components

**`CaptureViewModel.extract()`** — rewritten as the router:
1. `smartScanEnabled == false` (OFF): `OnDeviceAI.isAvailable` ? run FM (no cloud) : produce an **empty manual draft** (status `done`, `needsReview` true) — no cloud.
2. `smartScanEnabled == true` (ON):
   - `OnDeviceAI.isAvailable`: run FM. If `confidence < UPGRADE_THRESHOLD`: online → kick a cloud re-extract and upgrade in place (reuse the in-place refresh: set draft, bump `draftRevision`); offline → set `extractionStatus = "pending"` so the reconciler cloud-upgrades later. Else → `done`.
     - **Reconciler note:** a low-confidence FM result saved `pending` should be **fully replaced** by the cloud result (the FM result was uncertain), like the `autoSaved` case — not classification-only. The reconciler's full-replace gate must cover this (e.g. an `autoSaved`-equivalent flag, or treat FM-pending the same), while still never stomping a user edit.
   - not available: online → cloud `/extract` (today's path); offline → **empty/typed draft saved `pending`** → reconciler.
- The owned `extractTask`, `draftUserEdited`, `draftRevision`, `reviewNow`, `autosaveOnExitIfScanning` behaviors from the inline-wait work are preserved; FM just replaces the heuristic as the on-device producer.

**`ExtractedReceipt`** — add `init(foundationModel:)` mapping `FMReceipt`→draft; add `static func empty(capturedAt:)` for the manual/queued-offline case. Remove `init(parsed:)` (heuristic) once `HeuristicParser` is gone.

**`ScanDiagnostics.Engine`** — add `.foundationModel` (summary e.g. "On-device AI"). Keep `.deepseek` (cloud) and `.onDeviceQueued`. Remove `.onDeviceHeuristic`/`.offlineHeuristic` once unused.

**Smart Scan setting copy** — update the toggle's helptext to reflect "uses on-device AI when available, otherwise manual" (no longer "on-device heuristic").

**Manual/queued review state** — ReviewStep must render cleanly with an empty draft (no items, blank merchant/total) for the non-FM-offline and Smart-Scan-OFF-non-FM cases, with messaging like "We'll finish this automatically when you're back online" (queued) or normal manual entry.

### Removed
- `HeuristicParser.swift` + `ParsedReceipt` + `ExtractedReceipt(parsed:)` + the heuristic call sites.
- **Keep** `ReceiptRows` (builds `layoutText` for cloud + FM), the cloud `/extract` path, the server-side heuristic (server's own LLM-failure fallback), and the pending/reconciler machinery.

## Data flow

`OCR (lines + boxes)` → `ReceiptRows` (layout text) → **router**:
- FM path: `FoundationModelExtractor.extract` → guards → draft → (low-confidence → cloud upgrade in place / pending).
- Cloud path: `api.extract` → draft.
- Queued path: `ExtractedReceipt.empty` (pending) → save → `PendingExtractionReconciler` (cloud) when online.

## Error handling / fallbacks
- FM unavailable / throws / context overflow → router treats device as non-FM for that scan (cloud if online, else pending).
- FM low-confidence → cloud upgrade (online) or pending (offline).
- Non-FM offline → pending (never an error/dead-end; the receipt + image are saved and reconciled later).
- All money stays `Decimal` in app code (convert from FM `Double`/`String` at the boundary) to preserve the existing money contract.

## Testing
- **Router unit tests** (FM mocked via a protocol seam): assert the correct engine/outcome for each matrix cell (capability × network × Smart Scan), including FM-low-confidence → cloud upgrade and non-FM-offline → pending.
- **FM output guard tests:** GST cap/printed-honor, total sanity, Double→Decimal.
- **Mapping tests:** `FMReceipt` → `ExtractedReceipt`; `date: nil` backfills like the cloud path.
- **Device test** (real FM): the user's iPhone 15 Pro Max (A17 Pro) on iOS 26 — scan the Japan City + Yakitori receipts, confirm FM output quality and the low-confidence cloud upgrade.
- Remove/retire `HeuristicParser` tests.

## Build / deployment
- Project already builds against the iOS 26.5 SDK; deployment target stays **iOS 17.0**. All FM code is `@available(iOS 26, *)` + runtime availability-gated, so iOS 17–25 and non-eligible devices compile and run unaffected (they take the cloud/queue path).
- No new third-party dependencies, no app-size increase (the model ships with the OS).

## Out of scope (future)
- iOS 27 multimodal FM (feeding the receipt image directly) — revisit when iOS 27 ships.
- A bundled fine-tuned small model for full offline parity on non-FM devices (heavy; only if that becomes a hard requirement).
- `RecognizeDocumentsRequest` (iOS 26 table structure) to feed FM cleaner rows — a possible later refinement to `ReceiptRows`.

## Open risks
- FM accuracy on messy/angled receipts is below cloud DeepSeek — mitigated by the low-confidence → cloud upgrade and by keeping cloud as the non-FM path.
- FM behavior can shift across OS releases (Apple owns the model) — guards + tests bound the blast radius.
- Simulator FM support is uncertain; device testing on the 15 Pro Max is the source of truth.
