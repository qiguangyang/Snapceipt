import XCTest

/// Hermetic loyalty wallet flow: seeded shell + stub API (no network, no camera).
/// Home quick action -> wallet shows seeded cards -> tap -> detail barcode -> back ->
/// manual add (pick brand -> number -> save -> success -> new card) -> delete a card.
/// The Scan CTA presence is asserted; the live scan is manual device QA (no simulator
/// camera), so this drives the MANUAL add path only.
final class LoyaltyUITests: UITestCase {
    func testWalletDetailManualAddAndDelete() {
        launchSeeded(activeType: "personal")   // signed-in, personal profile p2 active, seeded loyalty cards

        // Home loyalty quick action -> wallet.
        let quick = app.buttons[AccessibilityID.homeQuickLoyalty].firstMatch
        XCTAssertTrue(quick.waitForExistence(timeout: 10), "Loyalty quick action missing on Home")
        quick.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.loyaltyWalletScreen].waitForExistence(timeout: 5),
                      "Loyalty wallet did not appear")

        // Seeded cards render (>=1 row).
        let firstCard = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", AccessibilityID.loyaltyCardRowPrefix)).firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 5), "No seeded loyalty card rendered")

        // Tap a card -> detail shows the barcode element.
        firstCard.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.loyaltyDetailScreen].waitForExistence(timeout: 5),
                      "Loyalty detail did not appear")
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.loyaltyDetailBarcode].waitForExistence(timeout: 5),
                      "Detail barcode element missing")
        // Back to the wallet.
        app.buttons[AccessibilityID.loyaltyDetailDone].firstMatch.tap()
        // Done dismisses to Home; re-open the wallet for the add flow.
        XCTAssertTrue(quick.waitForExistence(timeout: 5), "Did not return to Home")
        quick.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.loyaltyWalletScreen].waitForExistence(timeout: 5),
                      "Wallet did not reappear")

        // Add a card via the floating CTA -> add screen.
        app.buttons[AccessibilityID.loyaltyWalletAdd].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.loyaltyAddScreen].waitForExistence(timeout: 5),
                      "Add screen did not appear")
        // The Scan CTA must exist (manual QA drives the live scan).
        XCTAssertTrue(app.buttons[AccessibilityID.loyaltyAddScan].firstMatch.waitForExistence(timeout: 5),
                      "Scan CTA missing")
        // Pick a brand (flybuys).
        let brand = app.buttons[AccessibilityID.loyaltyAddBrandPrefix + "flybuys"].firstMatch
        XCTAssertTrue(brand.waitForExistence(timeout: 5), "flybuys brand tile missing")
        brand.tap()
        // Type a member number (revealed after brand pick). The field renders low in
        // the scroll view, with its lower half under the bottom-pinned Save bar, so a
        // center tap lands on the Save bar instead of focusing the field. Scroll the
        // content up first so the field clears the Save bar, then tap to focus.
        let number = app.textFields[AccessibilityID.loyaltyAddNumber]
        XCTAssertTrue(number.waitForExistence(timeout: 5), "Number field missing")
        app.descendants(matching: .any)[AccessibilityID.loyaltyAddScreen].swipeUp()
        XCTAssertTrue(number.waitForExistence(timeout: 5), "Number field disappeared after scroll")
        number.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5), "Keyboard did not appear for number field")
        number.typeText("6011000990139424")
        // The keyboard covers the bottom-pinned Save bar. Dismiss it by tapping the
        // always-on-screen header title "Add a card", then Save.
        app.staticTexts["Add a card"].firstMatch.tap()
        // Save -> success -> back to the wallet.
        let save = app.buttons[AccessibilityID.loyaltyAddSave]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Save button missing")
        save.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.loyaltyWalletScreen].waitForExistence(timeout: 8),
                      "Did not return to wallet after save")

        // Delete: swipe a card row left to reveal the Delete action, tap it, and confirm
        // the row count drops by one. The soft-delete + enqueue("delete") seam itself is
        // unit-covered by LoyaltyWalletViewModelTests.deleteSoft.
        let cardRows = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", AccessibilityID.loyaltyCardRowPrefix))
        XCTAssertTrue(cardRows.firstMatch.waitForExistence(timeout: 5), "No loyalty card row after add")
        let beforeCount = cardRows.count
        cardRows.firstMatch.swipeLeft()
        let deleteAction = app.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5), "Swipe Delete action did not appear")
        deleteAction.tap()
        expectation(for: NSPredicate(format: "count < %d", beforeCount), evaluatedWith: cardRows)
        waitForExpectations(timeout: 5)
    }
}
