import XCTest

/// From a seeded, signed-in shell (2 profiles), the profile switcher opens the picker sheet.
final class ShellUITests: UITestCase {
    func testProfileSwitcherOpensPicker() {
        launchSeeded()

        // The switcher is the `ProfileSwitcherHeader` button, found by its id (the
        // `shell.home` marker now sits on the home content body, not an ancestor of
        // this button, so it no longer shadows `profile.switcher`).
        let switcher = app.buttons[AccessibilityID.profileSwitcher].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 10), "Profile switcher not found in seeded shell")
        XCTAssertTrue(switcher.isEnabled, "Switcher should be enabled with >1 profile")
        switcher.tap()

        // The picker sheet has a unique "Switch profile" title and a row per profile.
        XCTAssertTrue(app.staticTexts["Switch profile"].waitForExistence(timeout: 5),
                      "Profile picker sheet did not open")
        XCTAssertTrue(app.staticTexts["Home Budget"].waitForExistence(timeout: 3),
                      "The second (non-active) profile should be listed in the picker")
    }
}
