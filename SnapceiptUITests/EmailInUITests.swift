import XCTest

/// Hermetic Email-in flow: seeded shell + stub API (no network). Business profile
/// p1 is active and seeded with two `email_in` transactions (1 failed, 1 done), so
/// the list renders failed-first. Profile tab -> Email-in receipts -> address card
/// (stub alias) -> tap a row -> receipt detail -> close -> re-open list -> Rotate.
final class EmailInUITests: UITestCase {
    func testEmailInAddressCardAndDetailFlow() {
        // Email-in is a Pro feature. Launch with pro: true so the app reports a Pro
        // plan and the screen / review / rotate open WITHOUT the paywall ever
        // appearing (the StoreKit-test purchase hack can't complete in the stub).
        launchSeeded(pro: true)

        // Navigate to the Profile tab. (The real id is `tab.profile` — the tab-bar
        // button — mirroring how BudgetsUITests reaches Notifications settings.)
        let profileTab = app.buttons[AccessibilityID.tabProfile].firstMatch
        XCTAssertTrue(profileTab.waitForExistence(timeout: 10), "Profile tab missing")
        profileTab.tap()

        // Open Email-in.
        let row = app.buttons[AccessibilityID.profileRowEmailIn].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Email-in row missing")
        row.tap()

        // Pro plan is active (launched with pro: true), so the Pro gate falls away
        // and no paywall appears as we drive the list / review / rotate.

        // Address card renders (stub alias).
        let address = app.staticTexts[AccessibilityID.emailInAddress]
        XCTAssertTrue(address.waitForExistence(timeout: 5), "Inbox address not shown")
        XCTAssertTrue(address.label.contains("@in.snapceipt.cc"), "Address not formatted")

        // The failed row should be present and tappable (failed-first ordering).
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.emailInScreen].waitForExistence(timeout: 5),
                      "Email-in screen did not appear")
        let failedRow = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", AccessibilityID.emailInListRowPrefix)).firstMatch
        XCTAssertTrue(failedRow.waitForExistence(timeout: 5), "No email-in rows")
        failedRow.tap()

        // Tapping a row opens the rich receipt detail (ReceiptDetailView) — which REPLACED the
        // old bare review form. Detail + list are mutually-exclusive router overlays (one slot).
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.receiptDetailScreen].waitForExistence(timeout: 5),
                      "Receipt detail did not open from the email-in row")

        // Close the detail. The detail REPLACED the list (single router slot), so close lands on
        // the underlying PROFILE tab, NOT the list — re-open the list to continue.
        app.buttons[AccessibilityID.receiptDetailClose].firstMatch.tap()
        let rowAgain = app.buttons[AccessibilityID.profileRowEmailIn].firstMatch
        XCTAssertTrue(rowAgain.waitForExistence(timeout: 5),
                      "Did not return to the Profile tab after closing the detail")
        rowAgain.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.emailInScreen].waitForExistence(timeout: 5),
                      "Email-in list did not reopen")

        // Rotate the address (the stub returns a different alias).
        let rotate = app.buttons[AccessibilityID.emailInRotate]
        XCTAssertTrue(rotate.waitForExistence(timeout: 5), "Rotate button missing")
        rotate.tap()
    }
}
