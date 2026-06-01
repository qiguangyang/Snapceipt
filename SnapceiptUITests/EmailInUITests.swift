import XCTest

/// Hermetic Email-in flow: seeded shell + stub API (no network). Business profile
/// p1 is active and seeded with two `email_in` transactions (1 failed, 1 done), so
/// the list renders failed-first. Profile tab -> Email-in receipts -> address card
/// (stub alias) -> tap the failed row -> review -> Save -> back to the list -> Rotate.
final class EmailInUITests: UITestCase {
    func testEmailInAddressCardAndReviewFlow() {
        launchSeeded()

        // Navigate to the Profile tab. (The real id is `tab.profile` — the tab-bar
        // button — mirroring how BudgetsUITests reaches Notifications settings.)
        let profileTab = app.buttons[AccessibilityID.tabProfile].firstMatch
        XCTAssertTrue(profileTab.waitForExistence(timeout: 10), "Profile tab missing")
        profileTab.tap()

        // Open Email-in.
        let row = app.buttons[AccessibilityID.profileRowEmailIn].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Email-in row missing")
        row.tap()

        // Address card renders (stub alias).
        let address = app.staticTexts[AccessibilityID.emailInAddress]
        XCTAssertTrue(address.waitForExistence(timeout: 5), "Inbox address not shown")
        XCTAssertTrue(address.label.contains("@in.snapceipt.app"), "Address not formatted")

        // The failed row should be present and tappable (failed-first ordering).
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.emailInScreen].waitForExistence(timeout: 5),
                      "Email-in screen did not appear")
        let failedRow = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", AccessibilityID.emailInListRowPrefix)).firstMatch
        XCTAssertTrue(failedRow.waitForExistence(timeout: 5), "No email-in rows")
        failedRow.tap()

        // Review editor opens; the seeded row pre-fills the form on appear.
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.emailInReviewScreen].waitForExistence(timeout: 5),
                      "Review screen did not open")

        // Save is GATED on valid input: the FAILED seed has merchant: "" and
        // amount 0, so Save starts disabled and we must enter real data first.
        let save = app.buttons[AccessibilityID.emailInReviewSave]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Save button missing")
        XCTAssertFalse(save.isEnabled, "Save should be disabled until valid input is entered")

        // Confirm we opened the FAILED row (failed-first sort): its merchant is
        // empty. An empty SwiftUI TextField reports its PLACEHOLDER ("Merchant")
        // as `value`, so "empty" means value is "" or the placeholder string.
        let merchant = app.textFields[AccessibilityID.emailInReviewMerchant]
        XCTAssertTrue(merchant.waitForExistence(timeout: 5), "Merchant field missing")
        let merchantValue = (merchant.value as? String) ?? ""
        XCTAssertTrue(merchantValue.isEmpty || merchantValue == "Merchant",
                      "Failed seed row should open with an empty merchant")
        merchant.tap(); merchant.typeText("Bunnings")

        // The amount field pre-fills "0.00" — clear it, then type a real amount
        // (decimal keypad). Tapping focuses; select-all + delete clears the prefill.
        let amount = app.textFields[AccessibilityID.emailInReviewAmount]
        XCTAssertTrue(amount.waitForExistence(timeout: 5), "Amount field missing")
        amount.tap()
        if let current = amount.value as? String, !current.isEmpty {
            amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        amount.typeText("42.50")

        // Save is now enabled — tap it.
        XCTAssertTrue(save.isEnabled, "Save should be enabled after entering a merchant and a positive amount")
        save.tap()

        // OVERLAY MODEL: `.emailIn` and `.emailInReview` are MUTUALLY-EXCLUSIVE router
        // overlays (one `router.overlay` slot), so opening the review editor REPLACED the
        // Email-in list, and Save -> `router.dismissOverlay()` lands back on the underlying
        // PROFILE tab, NOT the list (same shape BudgetsUITests documents for the editor).
        // Assert the Email-in entry row is reachable again, then re-open the list.
        let rowAgain = app.buttons[AccessibilityID.profileRowEmailIn].firstMatch
        XCTAssertTrue(rowAgain.waitForExistence(timeout: 5),
                      "Did not return to the Profile tab after save")
        rowAgain.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.emailInScreen].waitForExistence(timeout: 5),
                      "Email-in list did not reopen after save")

        // Rotate the address (the stub returns a different alias).
        let rotate = app.buttons[AccessibilityID.emailInRotate]
        XCTAssertTrue(rotate.waitForExistence(timeout: 5), "Rotate button missing")
        rotate.tap()
    }
}
