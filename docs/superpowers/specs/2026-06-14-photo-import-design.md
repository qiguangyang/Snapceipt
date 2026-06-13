# Photo / file import in Capture — design

**Date:** 2026-06-14
**Status:** Approved (brainstorming → ready for implementation plan)
**Author:** brainstorming session

## 1. Goal

Let the user add a receipt by **importing an existing image or PDF** instead of only
capturing live with the camera. Today the only entry to the capture pipeline is the
system document scanner; this adds a second source — the Photos library and a
PDF/image from Files — that flows through the **exact same** extraction → review →
save pipeline.

## 2. Context (current architecture)

- Snap FAB → `CaptureHost` builds `CaptureViewModel` → `CaptureFlow` switches on
  `vm.stage`: `.camera → .scanning → .review → .saved`.
- `.camera` renders `CameraStep` → `DocumentScannerView`
  (`VNDocumentCameraViewController`, VisionKit). **All of its chrome — Cancel (✕),
  Flash, Filters, Shutter — is native and cannot be modified or have buttons added
  to it.**
- When a page is produced, `CameraStep`'s `onScanned: (UIImage) -> Void` closure
  (wired in `CaptureFlow`) runs `OCR.recognize(in: image)` and then
  `vm.onScanned(image:rawText:)`. From there: `/extract` (or the offline
  `HeuristicParser` fallback) → `.review` → `save()` (insert txn + line items,
  enqueue sync, persist a reduced JPEG via `ImageReducer`) → `.saved`.

**Key consequence:** everything downstream of "a `UIImage` exists" is generic. An
imported image only needs to produce a `UIImage` and call the **existing**
`onScanned(image)` closure. No view-model or pipeline change.

## 3. Locked decisions

| Decision | Choice |
|----------|--------|
| Entry point | A button in the **bottom-leading** corner of the camera stage, overlaid on the system scanner (iOS-Camera-style placement). |
| Button content | A **static photo-stack glyph** sized like a thumbnail — NOT a live "last photo" thumbnail (a live thumbnail forces an early Photos permission prompt; `PhotosPicker`/`fileImporter` need none). |
| Sources | **Photos** (single image) **and** **Files** (single image or PDF). |
| Source chooser | Tapping the button opens a `confirmationDialog`: **Photo Library** / **Files** / Cancel. |
| PDF | Render the **first page** only to a `UIImage` (single-receipt model). |
| Pipeline | Reuse `CameraStep`'s existing `onScanned(image)` closure verbatim. |
| Permissions | None added. `PhotosPicker` (PHPicker) and `.fileImporter` (UIDocumentPicker) run out-of-process; no `Info.plist` privacy strings, no library/camera-roll access. |
| Failure UX | Toast via the global `ToastCenter`; stay on the scanner. |

## 4. Components & data flow

```
                 ┌─ Photo Library → PhotosPicker (.images, single) → Data → UIImage ─┐
[import button]→ confirmationDialog                                                   ├→ onScanned(UIImage)
                 └─ Files → .fileImporter([.image,.pdf], single)                      │      (existing closure:
                        ├─ image → UIImage ───────────────────────────────────────── ┤       OCR.recognize →
                        └─ pdf   → PDFImageRenderer.firstPage(data) → UIImage ──────── ┘       vm.onScanned →
                                                                                              /extract → Review → Save)
```

- **`CameraStep`** (modified): wrap `DocumentScannerView` in
  `ZStack(alignment: .bottomLeading)`; add the import button + chooser state +
  `PhotosPicker` + `.fileImporter`. On obtaining a `UIImage`, call the existing
  `onScanned(image)` closure. The button uses safe-area-aware padding so it clears
  the home indicator and sits left of the scanner's centered control cluster.
  `@Environment(ToastCenter.self)` for failure toasts.
- **`PDFImageRenderer`** (new, tiny, pure):
  `static func firstPage(_ data: Data, maxDimension: CGFloat = 2000) -> UIImage?`
  using PDFKit/CoreGraphics. Returns nil on unreadable/empty/passworded PDFs.
  Unit-testable in isolation. Location:
  `Snapceipt/Features/Capture/Import/PDFImageRenderer.swift`.
- **`CaptureViewModel` / `CaptureFlow`**: unchanged (import reuses the camera
  stage's existing closure).

## 5. Accessibility ids (journey matrix)

Follow the `capture.*` dotted convention:
- `capture.import` — the bottom-leading import button.
- `capture.import.photos` — the "Photo Library" chooser action.
- `capture.import.files` — the "Files" chooser action.

## 6. Error handling / edge cases

- **Picker/importer cancel** → no-op; remain on the scanner.
- **Decode/render failure** (corrupt image, empty/passworded/garbage PDF) →
  `toasts.show("Couldn't read that file.", kind: .error)`; remain on the scanner. No
  crash, no dead-end.
- **Non-receipt or low-quality image** → OCR yields little/garbage text →
  extraction returns low confidence → Review shows the existing neutral
  "Double-check the details below." banner. User edits or cancels. Identical to a
  poor live scan; no special handling.
- **Multi-page PDF** → first page only (documented limitation).
- **Security-scoped Files URL** → wrap reads in
  `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`.

## 7. Testing

- **Unit — `PDFImageRenderer`**: a tiny embedded/generated single-page PDF renders a
  non-nil `UIImage` with sane dimensions; garbage `Data` and empty PDF return nil.
- **Unit — pipeline reuse**: feeding an imported `UIImage` through `onScanned`
  drives the same `.scanning → .review` transition and produces a draft (extends the
  existing `CaptureViewModel` coverage; OCR itself stays real Vision, untested, as
  the camera path already is).
- **UI / journey**: assert `capture.import` is present on the camera stage and the
  `confirmationDialog` surfaces the two actions, behind the existing UI-test seam
  (the simulator has no live scanner and the system pickers/importers are not
  hermetically drivable). New journey rows **J-import-photo** and **J-import-pdf**.
- **On-device (smoke checklist)**: verify the overlaid button renders above the live
  scanner, receives taps, doesn't collide with native chrome, and that
  Photos + Files imports complete a full receipt end-to-end. The simulator cannot
  render the real scanner chrome, so placement/collision is a device-only check.

## 8. Risks

- **Overlaying SwiftUI on a system VC** (`VNDocumentCameraViewController`): the button
  must render above it AND receive taps without the VC swallowing them. This is the
  one real risk. Verify early in implementation. **Fallback:** if unreliable, switch
  to the pre-capture chooser (tap Snap → "Scan with camera" / "Choose from Photos"),
  which touches no system UI — and flag the change rather than ship something flaky.
- Simulator can't show the real scanner, so the final overlay look is an on-device
  gate (§7).

## 9. Scope / non-goals

**In:** single image from Photos; single image OR first-page-of-PDF from Files;
through the existing extraction → review → save flow; failure toast; accessibility
ids + journey coverage.

**Out (not built):** multi-select batch import; multi-page PDF as multiple receipts;
in-app crop/rotate/dewarp of the imported image (the scanner's dewarp does not apply
to imports — we OCR the image as-is); importing from cloud providers beyond what the
system Files picker already exposes.

## 10. Files

- `Snapceipt/Features/Capture/Views/CameraStep.swift` — add overlay button, chooser,
  `PhotosPicker`, `.fileImporter`, glue to `onScanned`, failure toast.
- `Snapceipt/Features/Capture/Import/PDFImageRenderer.swift` — new first-page renderer.
- `Snapceipt/Shared/AccessibilityID.swift` — add `capture.import`,
  `capture.import.photos`, `capture.import.files`.
- Tests: `PDFImageRenderer` unit test; capture VM import-path test; UI/journey
  assertions for the import affordance.
- Device-smoke checklist: add the on-device import verification item.
