import XCTest

/// J50: rotating the inbox alias flips the displayed address initial→rotated.
final class EmailInRotateUITests: UITestCase {
    func testRotateUpdatesAlias() {
        // Email-in is a Pro feature. Launch with pro: true so the app reports a Pro
        // plan and the screen / rotate work WITHOUT the paywall ever appearing (the
        // StoreKit-test purchase hack can't complete in the stub).
        launchSeeded(pro: true)
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        let row = app.descendants(matching: .any)[AccessibilityID.profileRowEmailIn].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Email-in row missing")
        row.tap()
        // Pro plan is active, so the gate falls away and the Rotate tap actually
        // rotates the alias (no paywall is re-presented).
        let address = app.descendants(matching: .any)[AccessibilityID.emailInAddress].firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 5), "Alias address label missing")
        XCTAssertTrue(address.label.contains("stubtokeninitial"),
                      "Initial alias not shown: \(address.label)")
        // Rotate → the displayed alias must change to the rotated token.
        app.buttons[AccessibilityID.emailInRotate].firstMatch.tap()
        let expectation = expectation(for: NSPredicate(format: "label CONTAINS %@", "stubtokenrotated"),
                                      evaluatedWith: address)
        wait(for: [expectation], timeout: 6)
    }
}
