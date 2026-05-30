import XCTest

/// Base case for the hermetic XCUITest suite: owns the `XCUIApplication` and the
/// stub-launch + dev-sign-in helpers. `AccessibilityID` is compiled into this target.
class UITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// Hermetic launch: in-app stub + reset to signed-out/empty.
    func launchStub() {
        app.launchArguments += ["-uiTestStub", "-uiTestReset"]
        app.launch()
    }

    func tapDevSignIn() {
        let b = app.buttons[AccessibilityID.signInDev]
        XCTAssertTrue(b.waitForExistence(timeout: 10), "Dev sign-in button missing")
        b.tap()
    }
}
