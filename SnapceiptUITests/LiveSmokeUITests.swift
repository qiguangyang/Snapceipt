import XCTest

/// Opt-in live smoke: drives the real app against a local `wrangler dev` Worker
/// (NO stub). Skips by default so the hermetic suite stays green without a backend.
/// Run via `scripts/ios-e2e-live.sh`.
final class LiveSmokeUITests: UITestCase {
    func testLiveDevSignIn() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["E2E_LIVE"] == "1",
                          "Live smoke disabled (set E2E_LIVE=1 and run wrangler dev with E2E_TEST_MODE=1).")
        let base = env["API_BASE_URL"] ?? "http://127.0.0.1:8787"
        app.launchArguments += ["-uiTestReset"]          // NO -uiTestStub → real LiveAPIClient
        app.launchEnvironment["API_BASE_URL"] = base
        app.launch()
        tapDevSignIn()
        // Dev sign-in hit the live Worker (E2E_TEST_MODE) → real session → onboarding (fresh user, no profile).
        XCTAssertTrue(app.textFields[AccessibilityID.onboardingName].waitForExistence(timeout: 20),
                      "Live dev sign-in did not reach onboarding (is wrangler dev up with E2E_TEST_MODE=1?)")
    }
}
