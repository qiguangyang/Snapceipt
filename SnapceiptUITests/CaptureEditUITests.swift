import XCTest

/// J13 edit-on-review, J14 needsReview banner, J18 snap-another loop.
final class CaptureEditUITests: UITestCase {
    /// Wait for the raised center Snap tab and open the capture flow. `launch()` blocks
    /// on quiescence, but the explicit wait is the established sibling pattern
    /// (CaptureUITests) and cheap insurance against slow CI sims.
    private func openCapture() {
        let snap = app.buttons[AccessibilityID.tabSnap].firstMatch
        XCTAssertTrue(snap.waitForExistence(timeout: 12), "Snap tab not found")
        snap.tap()
    }

    func testEditReviewFieldsBeforeSave() {
        launchSeeded()
        openCapture()
        let save = app.buttons[AccessibilityID.captureSave]
        XCTAssertTrue(save.waitForExistence(timeout: 12), "Review stage did not appear")
        // Edit the merchant field.
        let merchant = app.textFields[AccessibilityID.captureReviewMerchant]
        XCTAssertTrue(merchant.exists, "Merchant field missing")
        merchant.tap()
        // Clear then type a new value.
        if let value = merchant.value as? String, !value.isEmpty {
            merchant.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        merchant.typeText("Edited Cafe")
        // Verify the edit actually landed in the bound field BEFORE saving — otherwise the
        // test passes even if the TextField binding is broken, autocorrect mangles input,
        // or keystrokes hit the wrong element (capture Save is not gated on merchant).
        XCTAssertEqual(merchant.value as? String, "Edited Cafe",
                       "Typed merchant did not land in the bound field")
        save.tap()
        XCTAssertTrue(app.staticTexts[AccessibilityID.captureSavedTitle].waitForExistence(timeout: 5),
                      "Saved stage did not appear after editing")
    }

    func testNeedsReviewHidesBadge() {
        // Compose the canned-needsReview flag onto launchSeeded()'s arg list so it can't
        // drift from the helper (launchSeeded appends to launchArguments).
        app.launchArguments += ["-uiTestCannedNeedsReview"]
        launchSeeded()
        openCapture()
        XCTAssertTrue(app.buttons[AccessibilityID.captureSave].waitForExistence(timeout: 12),
                      "Review stage did not appear")
        // Neutral banner copy is shown; the confidence badge is hidden. The banner body
        // (ReviewStep `aiBanner`) carries AccessibilityID.captureReviewBanner — assert its
        // label directly (more targeted than scanning all staticTexts). Exact copy is
        // "Double-check the details below."; CONTAINS so a punctuation tweak doesn't flake.
        let banner = app.staticTexts[AccessibilityID.captureReviewBanner]
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "needsReview neutral banner missing")
        XCTAssertTrue((banner.label).contains("Double-check the details"),
                      "needsReview banner copy unexpected: \(banner.label)")
        XCTAssertFalse(app.staticTexts[AccessibilityID.captureReviewBadge].exists,
                       "Confidence badge should be hidden when needsReview=true")
    }

    func testSnapAnotherLoop() {
        launchSeeded()
        openCapture()
        let save = app.buttons[AccessibilityID.captureSave]
        XCTAssertTrue(save.waitForExistence(timeout: 12), "First review did not appear")
        save.tap()
        XCTAssertTrue(app.staticTexts[AccessibilityID.captureSavedTitle].waitForExistence(timeout: 5),
                      "First save did not reach Saved")
        app.buttons[AccessibilityID.captureSnapAnother].tap()
        // Second scan stage appears again.
        XCTAssertTrue(app.staticTexts[AccessibilityID.captureScanTitle].waitForExistence(timeout: 8),
                      "Snap another did not restart the scan stage")
        // And the re-fed canned image round-trips Scan → Review (the onChange seam re-feeds
        // the extract), proving the loop reaches Review end-to-end, not just that the
        // stage flipped back to .camera/.scanning.
        XCTAssertTrue(save.waitForExistence(timeout: 12),
                      "Re-fed snap-another loop did not reach Review")
    }
}
