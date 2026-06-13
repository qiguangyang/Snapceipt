import XCTest

/// J07: from a seeded shell, Sign out clears the session and returns to SignIn.
final class AuthFlowUITests: UITestCase {
    func testSignOutReturnsToSignIn() {
        launchSeeded()
        // Profile tab → hub → Sign out row.
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        let signOut = app.descendants(matching: .any)[AccessibilityID.signOutButton].firstMatch
        XCTAssertTrue(signOut.waitForExistence(timeout: 10), "Sign-out control not found in profile hub")
        signOut.tap()
        // A confirmation alert/sheet — tap the destructive "Sign out" affordance if present.
        let confirm = app.buttons["Sign out"]
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        // Back on the sign-in screen: the dev sign-in button returns.
        XCTAssertTrue(app.buttons[AccessibilityID.signInDev].waitForExistence(timeout: 10),
                      "Did not return to SignIn after sign-out")
    }
}
