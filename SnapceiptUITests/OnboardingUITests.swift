import XCTest

/// Dev sign-in → onboarding (create first profile) → advance permission priming → tabbed shell.
final class OnboardingUITests: UITestCase {
    func testDevSignInThroughOnboardingToShell() {
        launchStub()
        tapDevSignIn()

        let name = app.textFields[AccessibilityID.onboardingName]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "Onboarding first-profile form did not appear")
        name.tap()
        name.typeText("Studio North")
        app.buttons[AccessibilityID.onboardingTypeBusiness].tap()
        app.buttons[AccessibilityID.onboardingCreate].tap()

        // Advance the two permission-priming screens (camera, notifications). Under the
        // stub the requester is a no-op, so tapping "Not now" just advances — no system alert.
        for _ in 0..<2 {
            let notNow = app.buttons["Not now"]
            if notNow.waitForExistence(timeout: 6) { notNow.tap() }
        }

        XCTAssertTrue(
            app.otherElements[AccessibilityID.shellHome].waitForExistence(timeout: 10)
                || app.otherElements[AccessibilityID.shellTabBar].waitForExistence(timeout: 5)
                || app.staticTexts["Snap a receipt"].waitForExistence(timeout: 5),
            "Did not reach the tabbed shell after onboarding")
    }
}
