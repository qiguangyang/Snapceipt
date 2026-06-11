import XCTest

/// J13 edit-on-review, J14 needsReview banner, J18 snap-another loop.
final class CaptureEditUITests: UITestCase {
    func testEditReviewFieldsBeforeSave() {
        launchSeeded()
        app.buttons[AccessibilityID.tabSnap].firstMatch.tap()
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
        save.tap()
        XCTAssertTrue(app.staticTexts[AccessibilityID.captureSavedTitle].waitForExistence(timeout: 5),
                      "Saved stage did not appear after editing")
    }

    func testNeedsReviewHidesBadge() {
        app.launchArguments += ["-uiTestStub", "-uiTestSeed", "-uiTestCannedNeedsReview"]
        app.launch()
        app.buttons[AccessibilityID.tabSnap].firstMatch.tap()
        XCTAssertTrue(app.buttons[AccessibilityID.captureSave].waitForExistence(timeout: 12),
                      "Review stage did not appear")
        // Neutral banner copy is shown; the confidence badge is hidden.
        // Exact copy is "Double-check the details below." (ReviewStep.swift:62) — use a
        // CONTAINS predicate so a trailing-punctuation tweak doesn't flake the test.
        let banner = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Double-check the details")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5),
                      "needsReview neutral banner missing")
        XCTAssertFalse(app.staticTexts[AccessibilityID.captureReviewBadge].exists,
                       "Confidence badge should be hidden when needsReview=true")
    }

    func testSnapAnotherLoop() {
        launchSeeded()
        app.buttons[AccessibilityID.tabSnap].firstMatch.tap()
        let save = app.buttons[AccessibilityID.captureSave]
        XCTAssertTrue(save.waitForExistence(timeout: 12), "First review did not appear")
        save.tap()
        XCTAssertTrue(app.staticTexts[AccessibilityID.captureSavedTitle].waitForExistence(timeout: 5),
                      "First save did not reach Saved")
        app.buttons[AccessibilityID.captureSnapAnother].tap()
        // Second scan stage appears again.
        XCTAssertTrue(app.staticTexts[AccessibilityID.captureScanTitle].waitForExistence(timeout: 8),
                      "Snap another did not restart the scan stage")
    }
}
