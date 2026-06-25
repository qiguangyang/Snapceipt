import XCTest

/// Drives the redesigned signed-out auth flow under the hermetic stub: landing → email login →
/// forgot password → back → create account → code entry. Asserts each screen renders and captures
/// a screenshot of it (exported from the .xcresult via `xcresulttool`). Doubles as the navigation
/// smoke test the new dedicated pages were otherwise missing.
final class AuthScreensUITests: UITestCase {
    @MainActor func test_authFlowScreens() {
        launchStub()   // signed-out landing (in-memory stub, isolated from real data)

        // Landing
        require(app.buttons[AccessibilityID.signInWithEmail], "landing: Sign in with Email")
        require(app.buttons[AccessibilityID.signInCreate], "landing: Create an account")
        shoot(app, "auth-1-landing")

        // Landing → Email login
        app.buttons[AccessibilityID.signInWithEmail].tap()
        require(app.textFields[AccessibilityID.signInEmail], "email-login: email field")
        require(app.buttons[AccessibilityID.signInSubmit], "email-login: Sign in")
        shoot(app, "auth-2-email-login")

        // Email login → Forgot password
        require(app.buttons[AccessibilityID.signInForgot], "email-login: Forgot password link")
        app.buttons[AccessibilityID.signInForgot].tap()
        require(app.buttons[AccessibilityID.forgotSubmit], "forgot: Send reset code")
        shoot(app, "auth-3-forgot-password")

        // Back to email login, then back to the landing (custom AuthBackButton, label "Back")
        app.buttons["Back"].firstMatch.tap()
        require(app.buttons[AccessibilityID.signInSubmit], "back on email login")
        app.buttons["Back"].firstMatch.tap()
        require(app.buttons[AccessibilityID.signInWithEmail], "back on landing")

        // Landing → Create account
        app.buttons[AccessibilityID.signInCreate].tap()
        require(app.textFields[AccessibilityID.createEmail], "create: email field")
        require(app.buttons[AccessibilityID.createSubmit], "create: Send verification code")
        shoot(app, "auth-4-create-account")

        // Create account → request a code → code-entry screen (stub otpRequest succeeds).
        // The email field's submitLabel(.go) → send(), so a trailing newline submits.
        app.textFields[AccessibilityID.createEmail].tap()
        app.textFields[AccessibilityID.createEmail].typeText("maya@example.com\n")
        require(app.staticTexts["Confirm your email"], "code-entry heading")
        require(app.textFields[AccessibilityID.codeField], "code-entry: code field")
        shoot(app, "auth-5-code-entry")
    }
}
