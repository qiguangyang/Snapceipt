import XCTest

/// Live-wrangler journey base: drives the REAL LiveAPIClient against a local
/// `wrangler dev` (E2E seams). Gated on E2E_LIVE so the hermetic suite stays green.
/// Run via `scripts/ios-e2e-journeys.sh LiveJourneyUITests`.
final class LiveJourneyUITests: UITestCase {
    /// Launch against the live Worker (NO -uiTestStub → real LiveAPIClient).
    /// Resets auth so each journey starts signed-out. Returns the API base.
    @discardableResult
    func launchLive(seeded: Bool = false) throws -> String {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["E2E_LIVE"] == "1",
                          "Live journeys disabled (set E2E_LIVE=1, run wrangler dev with E2E_TEST_MODE=1).")
        let base = env["API_BASE_URL"] ?? "http://127.0.0.1:8787"
        app.launchArguments += ["-uiTestReset"]
        app.launchEnvironment["API_BASE_URL"] = base
        app.launch()
        return base
    }

    /// Smoke: the live launch helper reaches the sign-in screen (proves the harness).
    func testLiveLaunchReachesSignIn() throws {
        try launchLive()
        XCTAssertTrue(app.buttons[AccessibilityID.signInDev].waitForExistence(timeout: 15),
                      "Live launch did not reach the sign-in screen")
    }
}
