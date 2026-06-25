import XCTest

/// Regression: business-profile edits in Tax & GST reverted to the original info.
/// They must persist across closing + reopening the sheet. Seed: business p1 ("Studio
/// North") active, with EMPTY business email/phone/website — so typing sets them directly.
/// The fields sit low in a long scroll view, so each is scrolled into view before use.
final class SettingsSaveUITests: UITestCase {
    func testBusinessProfileEditsPersistAcrossReopen() {
        launchSeeded()
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.profileHubScreen].waitForExistence(timeout: 10),
                      "Profile hub did not appear")

        openTax()
        type(AccessibilityID.taxBusinessEmailField, "hi@studionorth.example")
        type(AccessibilityID.taxBusinessPhoneField, "0400111222")
        type(AccessibilityID.taxBusinessWebsiteField, "studionorth.example")

        app.buttons[AccessibilityID.logbookClose].firstMatch.tap()
        openTax()

        expect(AccessibilityID.taxBusinessEmailField, "hi@studionorth.example", "Business email")
        expect(AccessibilityID.taxBusinessPhoneField, "0400111222", "Phone")
        expect(AccessibilityID.taxBusinessWebsiteField, "studionorth.example", "Website")
    }

    private func openTax() {
        app.buttons[AccessibilityID.profileRowTax].tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.taxScreen].waitForExistence(timeout: 5),
                      "Tax screen did not open")
    }

    private func scrollToHittable(_ f: XCUIElement) {
        // Scroll until the field's top is in the upper-middle so its center (the tap target)
        // is on-screen and clear of where the keyboard appears.
        var tries = 0
        while f.frame.minY > 420 && tries < 12 { app.swipeUp(); tries += 1 }
    }

    private func dismissKeyboardIfUp() {
        let d = app.buttons[AccessibilityID.keyboardDismiss].firstMatch
        if d.exists { d.tap() }
    }

    private func type(_ id: String, _ text: String) {
        let f = app.textFields[id]
        XCTAssertTrue(f.waitForExistence(timeout: 5), "\(id) missing")
        scrollToHittable(f)
        f.tap(); f.typeText(text)
        dismissKeyboardIfUp()   // commits via on-focus-change; frees the screen for the next field
    }

    private func expect(_ id: String, _ value: String, _ name: String) {
        let f = app.textFields[id]
        XCTAssertTrue(f.waitForExistence(timeout: 5), "\(name) field missing on reopen")
        scrollToHittable(f)
        XCTAssertEqual(f.value as? String, value, "\(name) did not persist (reverted to original)")
    }
}
