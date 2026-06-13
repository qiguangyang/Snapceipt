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
