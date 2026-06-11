import XCTest

/// Hermetic capture flow: seeded shell + stub API + canned image (no camera).
/// Snap tab → Scan → Review (assert fields + confidence badge) → Save → Saved.
final class CaptureUITests: UITestCase {
    func testSnapToSaved() {
        launchSeeded()   // -uiTestStub + -uiTestSeed: signed-in, 2 profiles, StubAPIClient

        // Open the capture flow via the raised center Snap tab.
        let snap = app.buttons[AccessibilityID.tabSnap].firstMatch
        XCTAssertTrue(snap.waitForExistence(timeout: 10), "Snap tab not found")
        snap.tap()

        // The Scan stage shows its title (canned image starts at .scanning under the stub).
        XCTAssertTrue(app.staticTexts[AccessibilityID.captureScanTitle].waitForExistence(timeout: 5),
                      "Scan stage did not appear")

        // It auto-advances to Review once the stub extract resolves: the Save button +
        // the editable Merchant field + the confidence badge (shown because !needsReview).
        let save = app.buttons[AccessibilityID.captureSave]
        XCTAssertTrue(save.waitForExistence(timeout: 8), "Review stage (Save button) did not appear")
        XCTAssertTrue(app.textFields[AccessibilityID.captureReviewMerchant].exists,
                      "Merchant field missing on Review")
        XCTAssertTrue(app.staticTexts[AccessibilityID.captureReviewBadge].exists,
                      "Confidence badge should be shown for a confident (needsReview=false) draft")

        // Save → Saved.
        save.tap()
        XCTAssertTrue(app.staticTexts[AccessibilityID.captureSavedTitle].waitForExistence(timeout: 5),
                      "Saved stage did not appear")
        XCTAssertTrue(app.staticTexts["Receipt saved!"].exists, "Saved headline missing")

        // Dismiss back to the shell. The TabBar is an a11y CONTAINER (`.contain`), so
        // `shell.tabbar` surfaces as an `otherElement` (its inner tab buttons keep their
        // own ids) — matching how OnboardingUITests probes the shell.
        app.buttons[AccessibilityID.captureDone].tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.shellTabBar].waitForExistence(timeout: 5),
                      "Did not return to the shell after Done")
    }

    /// The Review close affordance (`captureClose`) cancels the whole capture overlay
    /// and returns to the shell without saving — the only cancel path beyond Camera.
    func testReviewCloseReturnsToShell() {
        launchSeeded()

        let snap = app.buttons[AccessibilityID.tabSnap].firstMatch
        XCTAssertTrue(snap.waitForExistence(timeout: 10), "Snap tab not found")
        snap.tap()

        // Wait for Review (the stub auto-advances Scan → Review).
        XCTAssertTrue(app.buttons[AccessibilityID.captureSave].waitForExistence(timeout: 8),
                      "Review stage did not appear")

        // Tap the close chip and assert the shell tab bar comes back.
        let close = app.buttons[AccessibilityID.captureClose]
        XCTAssertTrue(close.exists, "Close affordance missing on Review")
        close.tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.shellTabBar].waitForExistence(timeout: 5),
                      "Did not return to the shell after closing Review")
    }
}
