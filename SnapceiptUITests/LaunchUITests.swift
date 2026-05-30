import XCTest

/// Smoke test proving the UI-test target wiring builds + runs and the app launches
/// in stub mode to the SignIn screen.
final class LaunchUITests: UITestCase {
    func testSignInScreenRenders() {
        launchStub()
        XCTAssertTrue(app.buttons[AccessibilityID.signInDev].waitForExistence(timeout: 10),
                      "Dev sign-in button should render at launch")
        XCTAssertTrue(app.buttons[AccessibilityID.signInApple].exists,
                      "Apple sign-in button should render at launch")
    }
}
