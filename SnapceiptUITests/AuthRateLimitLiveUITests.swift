import XCTest

/// Live e2e (opt-in, runs the real LiveAPIClient against a local `wrangler dev` with the REAL rate
/// limiter): reproduces + guards the "Too many attempts" bug. Repeated FAILED password sign-ins
/// must NOT block a later code request — password/login is exempt from the per-email SEND cap
/// (only `.../request` endpoints count). Pre-fix, >8 failed logins burned the 8/email/hr cap and
/// the next otp/request 429'd ("Too many attempts"); post-fix the code request sends.
///
/// Run via `scripts/ios-e2e-ratelimit.sh`.
final class AuthRateLimitLiveUITests: UITestCase {
    func testFailedPasswordLoginsDoNotBlockCodeRequest() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["E2E_LIVE"] == "1",
                          "Live e2e disabled (set E2E_LIVE=1 + run wrangler dev with E2E_TEST_MODE=1).")
        let base = env["API_BASE_URL"] ?? "http://127.0.0.1:8787"
        app.launchArguments += ["-uiTestReset"]   // NO -uiTestStub → real LiveAPIClient, signed out
        app.launchEnvironment["API_BASE_URL"] = base
        app.launch()

        // Landing → dedicated email login page.
        let withEmail = app.buttons[AccessibilityID.signInWithEmail]
        XCTAssertTrue(withEmail.waitForExistence(timeout: 20), "sign-in landing not shown")
        withEmail.tap()

        let emailField = app.textFields[AccessibilityID.signInEmail]
        XCTAssertTrue(emailField.waitForExistence(timeout: 10), "email login page not shown")
        // Unique email so the per-email window is fresh for this run.
        let email = "ratelimit-e2e-\(Int(Date().timeIntervalSince1970))@example.com"
        emailField.tap(); emailField.typeText(email)

        let pw = app.secureTextFields[AccessibilityID.signInPassword]
        XCTAssertTrue(pw.waitForExistence(timeout: 5), "password field not shown")
        pw.tap(); pw.typeText("wrongpassword1")

        // Tap "Sign in" (→ password/login → 401, no such account) MORE than the 8/email/hr send
        // cap. Pre-fix these burned the cap; post-fix they're exempt, so the code request below
        // still sends.
        let signIn = app.buttons[AccessibilityID.signInSubmit]
        for i in 0..<9 {
            waitEnabled(signIn, "Sign in (iteration \(i))")
            signIn.tap()
        }

        // Now request a code — it must SEND (reach the code screen), NOT "Too many attempts".
        dismissKeyboard() // The keyboard can overlap the code button after the error appears.
        let useCode = app.buttons[AccessibilityID.signInUseCode]
        waitEnabled(useCode, "Email me a code")
        useCode.tap()

        XCTAssertTrue(app.staticTexts["Enter your sign-in code"].waitForExistence(timeout: 20),
                      "Code request was BLOCKED after failed password logins — password/login still consumes the per-email send cap (bug not fixed)")
        XCTAssertFalse(app.staticTexts["Too many attempts. Please wait a moment and try again."].exists,
                       "Got RATE_LIMITED requesting a code after failed password logins")
    }

    /// Wait until `el` is enabled+hittable (the primary CTA disables briefly while its request is
    /// in flight, then re-enables on the 401).
    private func waitEnabled(_ el: XCUIElement, _ label: String, timeout: TimeInterval = 12) {
        let p = NSPredicate(format: "isEnabled == true AND isHittable == true")
        let e = XCTNSPredicateExpectation(predicate: p, object: el)
        XCTAssertEqual(XCTWaiter().wait(for: [e], timeout: timeout), .completed,
                       "\(label) never became tappable")
    }
}
