import XCTest

/// J44: open a card of each seeded barcode format; the barcode element renders.
final class LoyaltyFormatsUITests: UITestCase {
    private func openWallet() {
        app.buttons[AccessibilityID.homeQuickLoyalty].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.loyaltyWalletScreen].firstMatch
                        .waitForExistence(timeout: 10), "Wallet did not open")
    }
    /// Open the nth card from a freshly-opened wallet and assert its barcode renders.
    /// The detail's Done dismisses the overlay back to Home (the wallet and detail are
    /// sibling overlays, not a nav stack — `onOpenCard` replaces the `.loyalty` overlay
    /// with `.loyaltyCard`), so each iteration re-opens the wallet first. Rows live in a
    /// LazyVStack; later rows may be offscreen, so scroll the nth row into view first.
    private func openNthCardAndAssertBarcode(_ index: Int) {
        openWallet()
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.loyaltyCardRowPrefix))
        let row = rows.element(boundBy: index)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Card row \(index) missing")
        if !row.isHittable {
            app.descendants(matching: .any)[AccessibilityID.loyaltyWalletScreen].firstMatch.swipeUp()
        }
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.loyaltyDetailScreen].firstMatch
                        .waitForExistence(timeout: 5), "Detail did not open for card \(index)")
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.loyaltyDetailBarcode].firstMatch.exists,
                      "Barcode element missing on card \(index)")
        app.buttons[AccessibilityID.loyaltyDetailDone].firstMatch.tap()
        XCTAssertTrue(app.buttons[AccessibilityID.homeQuickLoyalty].firstMatch.waitForExistence(timeout: 5),
                      "Did not return to Home after card \(index)")
    }
    func testBarcodeRendersPerFormat() {
        launchSeeded()
        // Open each seeded card (ean13, qr, code128, pdf417) and assert its barcode renders.
        for i in 0..<4 { openNthCardAndAssertBarcode(i) }
    }
}
