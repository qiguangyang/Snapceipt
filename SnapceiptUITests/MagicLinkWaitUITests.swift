import XCTest

/// End-to-end verification of the MagicLinkWaitView resend confirmation (Task 9
/// review fix #1/#2). The scripted screenshot tour reaches the wait screen but never
/// taps Resend, so the "Link sent" confirmation — which must survive RootView's
/// `.requestingLink → .awaitingLink` view recreation — is proven here with an actual tap.
final class MagicLinkWaitUITests: UITestCase {

    /// Drive SignIn → email submit → "Check your email", then tap Resend and assert the
    /// inline "Link sent" confirmation appears. Before the fix this confirmation was
    /// written into the @State of a view RootView had already destroyed, so it never
    /// showed in the live flow; the count now lives on AuthViewModel and the
    /// confirmation derives from it via `.task(id:)`, so it survives the round-trip.
    func testResendShowsLinkSentConfirmation() {
        launchStub()
        XCTAssertTrue(app.buttons[AccessibilityID.signInDev].waitForExistence(timeout: 10),
                      "should launch to SignIn")

        // Expand the email row and request a link (mirrors the tour's path).
        app.buttons["Continue with email"].firstMatch.tap()
        let emailField = app.textFields["you@example.com"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 4), "email field should appear")
        emailField.tap()
        emailField.typeText("dev@snapceipt.cc\n")   // submitLabel(.go) → send()

        XCTAssertTrue(app.staticTexts["Check your email"].waitForExistence(timeout: 5),
                      "should reach the magic-link wait screen")

        // Tap Resend (no a11y id — literal button label) and assert the confirmation.
        // The stub's magicLinkRequest succeeds, so the VM bumps linkSentCount and the
        // wait view flashes "Link sent" for ~1.6s.
        let resend = app.buttons["Resend email"]
        XCTAssertTrue(resend.waitForExistence(timeout: 3), "Resend button should be present")
        resend.tap()

        XCTAssertTrue(app.staticTexts["Link sent"].waitForExistence(timeout: 5),
                      "the 'Link sent' confirmation should appear after a real Resend tap")
    }
}
