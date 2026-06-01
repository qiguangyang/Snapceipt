import XCTest

/// Hermetic Settings flow: seeded shell + stub API (no network). Business profile p1
/// ("Studio North") is active, so the Tax & GST editor shows the business-identity
/// group (GST toggle). Profile tab -> hub renders -> Tax & GST (toggle GST) -> back
/// -> Categories -> back -> a profile-switcher card -> ProfileDetail.
final class SettingsUITests: UITestCase {
    func testHubOpensTaxAndCategoriesAndProfileDetail() {
        launchSeeded()
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        // The hub root is a ScrollView with `.accessibilityElement(children: .contain)`;
        // XCUI exposes that container as a non-`otherElements` element, so query `.any`
        // (the proven pattern the other screen-level assertions use, e.g. EmailInUITests).
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.profileHubScreen].waitForExistence(timeout: 10))

        // Tax & GST
        app.buttons[AccessibilityID.profileRowTax].tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.taxScreen].waitForExistence(timeout: 5))
        // toggle GST (business profile is active in the seed)
        let gst = app.switches[AccessibilityID.taxGstToggle]
        if gst.waitForExistence(timeout: 3) { gst.tap() }
        app.buttons[AccessibilityID.logbookClose].firstMatch.tap()

        // Categories
        app.buttons[AccessibilityID.profileRowCategories].tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.categoriesScreen].waitForExistence(timeout: 5))
        app.buttons[AccessibilityID.logbookClose].firstMatch.tap()

        // Profile detail via switcher card (seed profile p1)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.profileSwitcherCardPrefix)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.profileDetailScreen].waitForExistence(timeout: 5))
    }
}
