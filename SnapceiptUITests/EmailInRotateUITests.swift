import XCTest

/// J50: rotating the inbox alias flips the displayed address initial→rotated.
final class EmailInRotateUITests: UITestCase {
    func testRotateUpdatesAlias() {
        launchSeeded()
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        let row = app.descendants(matching: .any)[AccessibilityID.profileRowEmailIn].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Email-in row missing")
        row.tap()
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
