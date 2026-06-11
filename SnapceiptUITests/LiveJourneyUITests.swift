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

    /// J02 (live): dev sign-in → (if a fresh account) onboarding (create first BUSINESS
    /// profile) → skip the 2 permission primes → land in the shell tab bar. Extends
    /// LiveSmoke (which stops at the onboarding form) all the way into the app.
    ///
    /// STATE-TOLERANT: dev sign-in always uses the single fixed account dev@snapceipt.cc
    /// (DevAccount.swift), and one `ios-e2e-journeys.sh LiveJourneyUITests` invocation
    /// boots ONE shared wrangler persist for the whole class. Whichever live test runs
    /// SECOND signs into an account that already has a profile and lands directly in the
    /// shell — so every live journey must branch on shellTabBar vs onboardingName rather
    /// than assuming a fresh account. (`-uiTestReset` only clears local Keychain, not
    /// server state.)
    func testFirstRunOnboardingToShell() throws {
        try launchLive()
        tapDevSignIn()

        // If the shell appears first, this account already onboarded (a prior live test in
        // the same shared-persist run) — the journey's contract (sign-in reaches the shell)
        // is still satisfied; skip the onboarding steps.
        if app.otherElements[AccessibilityID.shellTabBar].waitForExistence(timeout: 6) {
            return
        }
        // Otherwise it's a fresh account → drive onboarding to the shell.
        let name = app.textFields[AccessibilityID.onboardingName]
        XCTAssertTrue(name.waitForExistence(timeout: 20), "Onboarding name field did not appear")
        name.tap(); name.typeText("Studio North")

        // Pick the business profile type, then create.
        app.buttons[AccessibilityID.onboardingTypeBusiness].tap()
        app.buttons[AccessibilityID.onboardingCreate].tap()

        // Permission primes: two literal "Not now" taps (matches OnboardingUITests).
        let notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 5) { notNow.tap() }
        if app.buttons["Not now"].waitForExistence(timeout: 3) { app.buttons["Not now"].tap() }

        // Landed in the shell: the tab bar container exists.
        XCTAssertTrue(app.otherElements[AccessibilityID.shellTabBar].waitForExistence(timeout: 15),
                      "Did not reach the shell after live onboarding")
    }

    /// J18c (live): a receipt captured offline drains to the backend on reconnect.
    func testOfflineCaptureDrainsOnReconnect() throws {
        let base = try launchLive()
        tapDevSignIn()
        // (onboard if a fresh account lands on the form — state-tolerant, see J02/J12.)
        if app.textFields[AccessibilityID.onboardingName].waitForExistence(timeout: 8) {
            app.textFields[AccessibilityID.onboardingName].tap()
            app.textFields[AccessibilityID.onboardingName].typeText("Drain Co")
            app.buttons[AccessibilityID.onboardingTypeBusiness].tap()
            app.buttons[AccessibilityID.onboardingCreate].tap()
            if app.buttons["Not now"].waitForExistence(timeout: 5) { app.buttons["Not now"].tap() }
            if app.buttons["Not now"].waitForExistence(timeout: 3) { app.buttons["Not now"].tap() }
        }
        XCTAssertTrue(app.otherElements[AccessibilityID.shellTabBar].waitForExistence(timeout: 15),
                      "Did not reach the live shell")
        // Relaunch offline, capture (queues), then relaunch online → the queue drains.
        app.terminate()
        app.launchArguments = ["-uiTestOffline"]
        app.launchEnvironment["API_BASE_URL"] = base
        app.launch()
        app.buttons[AccessibilityID.tabSnap].firstMatch.tap()
        let save = app.buttons[AccessibilityID.captureSave]
        XCTAssertTrue(save.waitForExistence(timeout: 12), "Offline review did not appear (live)")
        save.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.captureQueuedBadge].firstMatch
                        .waitForExistence(timeout: 8), "Offline capture did not queue (live)")
        // Reconnect: relaunch WITHOUT -uiTestOffline → ReceiptUploadQueue drains on next sync.
        app.terminate()
        app.launchArguments = []
        app.launchEnvironment["API_BASE_URL"] = base
        app.launch()
        // The queued badge clears once the receipt drains (the reconciler re-extracts server-side).
        let queued = app.descendants(matching: .any)[AccessibilityID.captureQueuedBadge].firstMatch
        XCTAssertFalse(queued.waitForExistence(timeout: 20),
                       "Queued receipt did not drain after reconnect")
    }
}
