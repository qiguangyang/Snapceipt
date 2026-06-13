# Photo / File Import in Capture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user add a receipt by importing an existing image (Photos) or an image/PDF (Files), feeding the picked image through the existing capture pipeline.

**Architecture:** A bottom-leading button overlaid on the camera stage opens a chooser (Photo Library / Files). Each source resolves to a single `UIImage` (PDF → first page rendered) and calls `CameraStep`'s existing `onScanned(UIImage)` closure — which already runs OCR → `vm.onScanned` → `/extract` → review → save. No view-model or pipeline change. A DEBUG-only launch arg (`-uiTestCaptureCamera`) lands the hermetic flow on `.camera` with a placeholder (the system scanner VC is unsupported in the simulator) so the affordance is UI-testable.

**Tech Stack:** SwiftUI, PhotosUI (`PhotosPicker`), UniformTypeIdentifiers (`.fileImporter`), PDFKit (`PDFDocument.thumbnail`), VisionKit (existing scanner), Swift Testing (unit) + XCUITest (UI).

**Spec:** `docs/superpowers/specs/2026-06-14-photo-import-design.md`

**Conventions (read once):**
- The Xcode project is generated from `project.yml` (the `.xcodeproj` is gitignored). **Run `xcodegen generate` before any `xcodebuild`.**
- Builds/tests are slow (minutes). Run them in the **foreground** with a long timeout; never background a build and end the turn.
- Destination: `platform=iOS Simulator,name=iPhone 16`.
- SourceKit file-level diagnostics are known false-positives in this repo (no module context). Trust `xcodebuild`, not the editor squiggles.
- Unit tests use Swift Testing (`import Testing`, `@Test`, `#expect`). UI tests subclass `UITestCase`.

---

## File Structure

- **Create** `Snapceipt/Features/Capture/Import/PDFImageRenderer.swift` — pure `Data → UIImage?` first-page PDF renderer.
- **Create** `SnapceiptTests/PDFImageRendererTests.swift` — unit tests for the renderer.
- **Create** `SnapceiptUITests/CaptureImportUITests.swift` — asserts the import button + chooser on the camera stage.
- **Modify** `Snapceipt/Shared/AccessibilityID.swift` — add 3 ids.
- **Modify** `Snapceipt/App/AppLaunch.swift` — add the `-uiTestCaptureCamera` seam.
- **Modify** `Snapceipt/App/RootView.swift` — suppress the canned feed under the new seam.
- **Modify** `Snapceipt/Features/Capture/Views/CameraStep.swift` — placeholder seam (Task 2) + import affordance (Task 3).
- **Modify** `docs/superpowers/specs/2026-06-11-beta-hardening-device-smoke-checklist.md` — on-device import item.

---

### Task 1: `PDFImageRenderer` (first-page PDF → UIImage)

**Files:**
- Create: `Snapceipt/Features/Capture/Import/PDFImageRenderer.swift`
- Test: `SnapceiptTests/PDFImageRendererTests.swift`

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/PDFImageRendererTests.swift`:

```swift
import Testing
import UIKit
@testable import Snapceipt

struct PDFImageRendererTests {

    /// A real one-page PDF generated in-memory (no fixture file needed).
    private func onePagePDF() -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300))
        return renderer.pdfData { ctx in
            ctx.beginPage()
            UIColor.white.setFill()
            ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            ("TOTAL 12.34" as NSString).draw(
                at: CGPoint(x: 12, y: 12),
                withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
    }

    @Test("renders the first page of a valid PDF to a non-nil image, longest side ~= maxDimension")
    func rendersFirstPage() {
        let img = PDFImageRenderer.firstPage(onePagePDF(), maxDimension: 1000)
        #expect(img != nil)
        if let img {
            let longest = max(img.size.width, img.size.height)
            #expect(longest > 800 && longest <= 1000)            // 300 -> 1000 (scaled up)
            #expect(img.size.width < img.size.height)            // portrait aspect preserved
        }
    }

    @Test("returns nil for non-PDF and empty data")
    func nilForGarbage() {
        #expect(PDFImageRenderer.firstPage(Data([0x00, 0x01, 0x02])) == nil)
        #expect(PDFImageRenderer.firstPage(Data()) == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodegen generate
xcodebuild test -scheme Snapceipt -project Snapceipt.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/PDFImageRendererTests
```
Expected: FAIL — `cannot find 'PDFImageRenderer' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Snapceipt/Features/Capture/Import/PDFImageRenderer.swift`:

```swift
import UIKit
import PDFKit

/// Renders the FIRST page of a PDF document to a `UIImage` for OCR + the capture
/// pipeline. Single-receipt model: only page 0 is used. Returns nil when the data
/// is not a readable PDF, has no pages, or is password-protected.
enum PDFImageRenderer {
    static func firstPage(_ data: Data, maxDimension: CGFloat = 2000) -> UIImage? {
        guard let document = PDFDocument(data: data),
              !document.isLocked,
              let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = maxDimension / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        // PDFPage.thumbnail handles the PDF→UIKit coordinate flip and white backing.
        return page.thumbnail(of: size, for: .mediaBox)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodegen generate
xcodebuild test -scheme Snapceipt -project Snapceipt.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptTests/PDFImageRendererTests
```
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Capture/Import/PDFImageRenderer.swift SnapceiptTests/PDFImageRendererTests.swift
git commit -m "feat(capture): PDFImageRenderer for first-page PDF import"
```

---

### Task 2: Test-seam infra (ids, launch arg, placeholder)

Enables a hermetic camera stage. No behavior change in production: the placeholder branch is `#if DEBUG` + gated on the new arg, and `captureStub` only changes under that arg.

**Files:**
- Modify: `Snapceipt/Shared/AccessibilityID.swift`
- Modify: `Snapceipt/App/AppLaunch.swift`
- Modify: `Snapceipt/App/RootView.swift`
- Modify: `Snapceipt/Features/Capture/Views/CameraStep.swift`

- [ ] **Step 1: Add accessibility ids**

In `Snapceipt/Shared/AccessibilityID.swift`, immediately after the line `static let captureDone = "capture.done"`, add:

```swift
    static let captureImport = "capture.import"
    static let captureImportPhotos = "capture.import.photos"
    static let captureImportFiles = "capture.import.files"
```

- [ ] **Step 2: Add the `-uiTestCaptureCamera` launch arg to `AppLaunch`**

In `Snapceipt/App/AppLaunch.swift`, add a stored property after `let pushStall: Bool` (line ~32):

```swift
    /// Test seam (`-uiTestCaptureCamera`): keep the capture flow on `.camera` (suppress
    /// the canned-image feed) AND render a neutral placeholder instead of the live
    /// `VNDocumentCameraViewController` (unsupported in the simulator) — so the import
    /// affordance on the camera stage is hermetically inspectable. DEBUG-only.
    let captureCamera: Bool
```

In the `init(arguments:environment:)`, after the line `pushStall = arguments.contains("-uiTestPushStall")`, add:

```swift
        captureCamera = arguments.contains("-uiTestCaptureCamera")
```

- [ ] **Step 3: Suppress the canned feed under the seam (`RootView`)**

In `Snapceipt/App/RootView.swift`, replace the `captureStub` computed property:

```swift
    /// The canned (image, rawText) used by the camera-less UI test, or nil in production.
    private var captureStub: (image: UIImage, rawText: String)? {
        #if DEBUG
        return AppLaunch.current.cannedScan
        #else
        return nil
        #endif
    }
```

with:

```swift
    /// The canned (image, rawText) used by the camera-less UI test, or nil in production.
    private var captureStub: (image: UIImage, rawText: String)? {
        #if DEBUG
        // -uiTestCaptureCamera: suppress the canned feed so the flow stays on `.camera`,
        // letting the import-affordance UI test inspect the camera stage.
        if AppLaunch.current.captureCamera { return nil }
        return AppLaunch.current.cannedScan
        #else
        return nil
        #endif
    }
```

- [ ] **Step 4: Refactor `CameraStep` to render a placeholder under the seam (NO import button yet)**

Replace the entire body of `Snapceipt/Features/Capture/Views/CameraStep.swift` with:

```swift
import SwiftUI

/// Full-bleed VisionKit scanner. The shutter, auto-capture, edge detection,
/// dewarp, flash, AND the Cancel/Done chrome are all native to
/// VNDocumentCameraViewController — we do not rebuild (or overlay) any of them.
/// Native Cancel routes through the scanner delegate as an empty-pages success,
/// which maps to `onClose()` below.
struct CameraStep: View {
    let onScanned: (UIImage) -> Void
    let onClose: () -> Void

    var body: some View {
        scannerLayer
            .ignoresSafeArea()
    }

    /// The live scanner — or, under the hermetic camera seam, a neutral placeholder
    /// (`VNDocumentCameraViewController` is unsupported in the simulator).
    @ViewBuilder private var scannerLayer: some View {
        #if DEBUG
        if AppLaunch.current.captureCamera {
            Color.black
        } else {
            scanner
        }
        #else
        scanner
        #endif
    }

    private var scanner: some View {
        DocumentScannerView { result in
            switch result {
            case .failure:
                onClose()
            case .success(let images):
                guard let first = images.first else { onClose(); return }  // cancelled
                onScanned(first)
            }
        }
    }
}
```

- [ ] **Step 5: Build + confirm existing capture UI tests stay green**

```bash
xcodegen generate
xcodebuild test -scheme Snapceipt -project Snapceipt.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptUITests/CaptureUITests
```
Expected: PASS (2 tests) — production path is unchanged; these tests don't pass `-uiTestCaptureCamera`.

- [ ] **Step 6: Commit**

```bash
git add Snapceipt/Shared/AccessibilityID.swift Snapceipt/App/AppLaunch.swift \
        Snapceipt/App/RootView.swift Snapceipt/Features/Capture/Views/CameraStep.swift
git commit -m "test(capture): add -uiTestCaptureCamera seam + camera-stage placeholder"
```

---

### Task 3: Import affordance in `CameraStep` (button + chooser + pickers)

**Files:**
- Modify: `Snapceipt/Features/Capture/Views/CameraStep.swift`
- Test: `SnapceiptUITests/CaptureImportUITests.swift`

- [ ] **Step 1: Write the failing UI test**

Create `SnapceiptUITests/CaptureImportUITests.swift`:

```swift
import XCTest

/// J-import: the camera stage exposes an "import" affordance whose chooser offers
/// Photo Library + Files. Driven via the `-uiTestCaptureCamera` seam (the flow stays
/// on `.camera`; the live scanner VC is replaced by a placeholder in the simulator).
/// The system pickers themselves are not driven (not hermetic) — we assert the
/// affordance and the chooser only.
final class CaptureImportUITests: UITestCase {
    func testImportButtonOpensSourceChooser() {
        app.launchArguments += ["-uiTestStub", "-uiTestSeed", "-uiTestCaptureCamera"]
        app.launch()

        // Open capture via the raised center Snap tab — lands on `.camera` (no auto-feed).
        let snap = app.buttons[AccessibilityID.tabSnap].firstMatch
        XCTAssertTrue(snap.waitForExistence(timeout: 10), "Snap tab not found")
        snap.tap()

        // The import button is overlaid on the camera stage.
        let importButton = app.buttons[AccessibilityID.captureImport]
        XCTAssertTrue(importButton.waitForExistence(timeout: 8), "Import button missing on camera stage")
        importButton.tap()

        // The chooser surfaces both sources (action-sheet buttons, matched by label).
        let photoLibrary = app.buttons["Photo Library"]
        XCTAssertTrue(photoLibrary.waitForExistence(timeout: 5), "Chooser missing 'Photo Library'")
        XCTAssertTrue(app.buttons["Files"].exists, "Chooser missing 'Files'")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodegen generate
xcodebuild test -scheme Snapceipt -project Snapceipt.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptUITests/CaptureImportUITests
```
Expected: FAIL — "Import button missing on camera stage" (the camera stage renders the placeholder from Task 2, but no import button exists yet).

- [ ] **Step 3: Implement the import affordance**

Replace the entire contents of `Snapceipt/Features/Capture/Views/CameraStep.swift` with:

```swift
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Full-bleed VisionKit scanner with an import affordance overlaid bottom-leading.
/// The scanner's own chrome (shutter, flash, filters, Cancel/Done) is native to
/// VNDocumentCameraViewController and untouched. The import button opens a chooser
/// (Photo Library / Files); each source resolves to a single `UIImage` (PDF → first
/// page) and calls the SAME `onScanned(UIImage)` closure the scanner uses, so OCR →
/// extract → review → save is identical to a live scan.
struct CameraStep: View {
    let onScanned: (UIImage) -> Void
    let onClose: () -> Void

    @Environment(ToastCenter.self) private var toasts
    @State private var showingChooser = false
    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        scannerLayer
            .ignoresSafeArea()
            .overlay(alignment: .bottomLeading) {
                importButton
                    // Bottom padding clears the home indicator and sits left of the
                    // scanner's centered control cluster. Final value tuned on-device
                    // (the simulator can't render the real scanner chrome).
                    .padding(.leading, 20)
                    .padding(.bottom, 40)
            }
            .confirmationDialog("Add a receipt", isPresented: $showingChooser, titleVisibility: .visible) {
                // Defer the present-bool flip to the next runloop tick so the dialog's
                // own dismissal doesn't swallow the picker/importer presentation.
                Button("Photo Library") { DispatchQueue.main.async { showingPhotos = true } }
                    .accessibilityIdentifier(AccessibilityID.captureImportPhotos)
                Button("Files") { DispatchQueue.main.async { showingFiles = true } }
                    .accessibilityIdentifier(AccessibilityID.captureImportFiles)
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $showingPhotos, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        onScanned(image)
                    } else {
                        toasts.show("Couldn't read that file.", kind: .error)
                    }
                    photoItem = nil
                }
            }
            .fileImporter(isPresented: $showingFiles,
                          allowedContentTypes: [.image, .pdf],
                          allowsMultipleSelection: false) { result in
                handleFileImport(result)
            }
    }

    // MARK: Scanner / placeholder

    /// The live scanner — or, under the hermetic camera seam, a neutral placeholder
    /// (`VNDocumentCameraViewController` is unsupported in the simulator).
    @ViewBuilder private var scannerLayer: some View {
        #if DEBUG
        if AppLaunch.current.captureCamera {
            Color.black
        } else {
            scanner
        }
        #else
        scanner
        #endif
    }

    private var scanner: some View {
        DocumentScannerView { result in
            switch result {
            case .failure:
                onClose()
            case .success(let images):
                guard let first = images.first else { onClose(); return }  // cancelled
                onScanned(first)
            }
        }
    }

    // MARK: Import affordance

    private var importButton: some View {
        Button { showingChooser = true } label: {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.captureImport)
        .accessibilityLabel("Import a receipt from Photos or Files")
    }

    /// Resolve a Files selection to a single `UIImage` (PDF → first page) and feed the
    /// pipeline; toast on an unreadable/unsupported file. Stays on the scanner on cancel.
    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            toasts.show("Couldn't read that file.", kind: .error); return
        }
        let isPDF = UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) ?? false
        let image = isPDF ? PDFImageRenderer.firstPage(data) : UIImage(data: data)
        if let image {
            onScanned(image)
        } else {
            toasts.show("Couldn't read that file.", kind: .error)
        }
    }
}
```

- [ ] **Step 4: Run the UI test to verify it passes**

```bash
xcodegen generate
xcodebuild test -scheme Snapceipt -project Snapceipt.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapceiptUITests/CaptureImportUITests
```
Expected: PASS. (If "Photo Library"/"Files" aren't found at top level on some iOS versions, query `app.sheets.buttons["Photo Library"]` instead — confirmationDialog renders as an action sheet.)

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Capture/Views/CameraStep.swift SnapceiptUITests/CaptureImportUITests.swift
git commit -m "feat(capture): import a receipt from Photos or Files on the camera stage"
```

---

### Task 4: Device-smoke checklist item

The live scanner overlay and the system pickers can't be verified in the simulator, so add an explicit on-device item.

**Files:**
- Modify: `docs/superpowers/specs/2026-06-11-beta-hardening-device-smoke-checklist.md`

- [ ] **Step 1: Add the import item**

In `docs/superpowers/specs/2026-06-11-beta-hardening-device-smoke-checklist.md`, under the "Scoped to what beta hardening changed" section, add a new numbered item after item 12:

```markdown
13. [ ] **Photo/file import (NEW):** on the camera stage, the bottom-left import button renders above the live scanner, receives taps, and doesn't collide with the native Flash/Filters/Shutter chrome. Tapping it offers **Photo Library** and **Files**. Import a receipt photo from Photos → it lands in Review with extracted fields. Import a receipt **PDF** from Files → its first page lands in Review. Pick an obviously-bad file (e.g. a non-receipt PDF) → a "Couldn't read that file." toast appears OR it lands in Review with the low-confidence banner; either way, no crash and you stay in the flow.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-06-11-beta-hardening-device-smoke-checklist.md
git commit -m "docs(ship): device-smoke item for photo/file import"
```

---

### Task 5: Full-suite verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full iOS hermetic suite**

```bash
xcodegen generate
xcodebuild test -scheme Snapceipt -project Snapceipt.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -40
```
Expected: all tests pass (the prior baseline was 408 passed / 0 failed / 7 skipped; this adds `PDFImageRendererTests` (2) + `CaptureImportUITests` (1), so ~411 passed / 0 failed / 7 skipped). No regressions in `CaptureUITests`, `CaptureEditUITests`, `CaptureOfflineUITests`.

- [ ] **Step 2: Confirm no Release-only breakage in the import code**

The import code is not behind `#if DEBUG` (only the placeholder seam is). Confirm a Release build compiles:

```bash
xcodegen generate
xcodebuild build -scheme Snapceipt -project Snapceipt.xcodeproj \
  -configuration Release -destination 'generic/platform=iOS' 2>&1 | tail -20
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Report**

Summarize pass/fail counts. If green, the feature is ready for a `BETA_INTERNAL_ONLY` build (separate, user-authorized step) where the on-device smoke item (Task 4) is the final gate.

---

## Self-Review

**Spec coverage:**
- §3 entry point (bottom-leading button on scanner) → Task 3 (`importButton`, `.overlay(alignment: .bottomLeading)`). ✓
- §3 static glyph (not live thumbnail) → Task 3 uses `Image(systemName:)`, no library read. ✓
- §3 sources Photos + Files → Task 3 (`.photosPicker` + `.fileImporter([.image,.pdf])`). ✓
- §3 chooser → Task 3 (`.confirmationDialog`). ✓
- §3 PDF first page → Task 1 (`PDFImageRenderer`) + Task 3 (`handleFileImport`). ✓
- §3 pipeline reuse (no VM change) → Task 3 calls the existing `onScanned(UIImage)`; `CaptureViewModel`/`CaptureFlow` untouched. ✓
- §3 no permissions → no `Info.plist` change in any task (PhotosPicker/fileImporter need none). ✓
- §5 accessibility ids → Task 2. ✓
- §6 error handling (toast, stay on scanner; cancel = no-op) → Task 3 (`handleFileImport`, photo `onChange`). ✓
- §6 non-receipt image → existing low-confidence Review path (no code needed; covered by `CaptureViewModelTests.failurePathFallsBack`). ✓
- §7 unit `PDFImageRenderer` → Task 1. ✓
- §7 "imported UIImage drives `.scanning → .review`" → the shared entry is `vm.onScanned(image:rawText:)`, already covered by `CaptureViewModelTests.successPath` (no new VM test added — DRY, the import path is identical post-`UIImage`). ✓
- §7 UI/journey assertion behind a seam → Task 3 (`CaptureImportUITests` + `-uiTestCaptureCamera`). ✓
- §7 on-device smoke → Task 4. ✓
- §8 risk/fallback (overlay on system VC) → noted in Task 3 padding comment + Task 4 device item; fallback to pre-capture chooser is a design decision flagged to the user, not a coded branch. ✓
- §9 non-goals (multi-select, multi-page, crop) → not implemented anywhere. ✓

**Placeholder scan:** No "TBD"/"TODO"/"handle edge cases" — every code step has complete code and exact commands. The one tuned value (`.padding(.bottom, 40)`) is explicitly called out as an on-device tuning, with a concrete starting value.

**Type consistency:** `PDFImageRenderer.firstPage(_:maxDimension:)` signature identical in Task 1 (def + test) and Task 3 (call). `AccessibilityID.captureImport` / `.captureImportPhotos` / `.captureImportFiles` consistent across Task 2 (def), Task 3 (use), and the UI test. `AppLaunch.captureCamera` consistent across Task 2 (def in `AppLaunch`, read in `RootView` + `CameraStep`). `onScanned(UIImage) -> Void` matches the existing `CameraStep` interface and `CaptureFlow`'s wiring (unchanged).
