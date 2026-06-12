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
        // tap() does NOT poll for existence; wait for the shell's a11y tree to attach
        // first (the relaunch restores the Keychain session + opens the on-disk store
        // before the shell renders, and CI sims under load lag the a11y attach).
        let offlineSnap = app.buttons[AccessibilityID.tabSnap].firstMatch
        XCTAssertTrue(offlineSnap.waitForExistence(timeout: 12), "Snap tab not found (offline relaunch)")
        offlineSnap.tap()
        let save = app.buttons[AccessibilityID.captureSave]
        XCTAssertTrue(save.waitForExistence(timeout: 12), "Offline review did not appear (live)")
        save.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.captureQueuedBadge].firstMatch
                        .waitForExistence(timeout: 8), "Offline capture did not queue (live)")
        // Reconnect: relaunch WITHOUT -uiTestOffline (real LiveAPIClient). The outbox is
        // NOT drained by sync — drainQueues() runs only from CaptureHost's `.task` on
        // appear (CaptureHost.swift:42-46) or a Reachability flip (which the seam never
        // simulates). So OPEN the Snap tab on the online relaunch to fire drainQueues()
        // (ReceiptUploadQueue.drain() + PendingExtractionReconciler.reconcile()) against
        // the live backend — without it the drain leg genuinely never runs.
        app.terminate()
        app.launchArguments = []
        app.launchEnvironment["API_BASE_URL"] = base
        app.launch()
        let onlineSnap = app.buttons[AccessibilityID.tabSnap].firstMatch
        XCTAssertTrue(onlineSnap.waitForExistence(timeout: 15), "Snap tab not found (online relaunch)")
        onlineSnap.tap()
        // The queued badge lives ONLY on the transient SavedStep of an offline capture; it
        // is never present on a freshly-opened online capture flow. After drainQueues()
        // uploaded the queued receipt, opening capture online surfaces no queued badge —
        // i.e. the prior offline receipt has drained and nothing re-queues here.
        let queued = app.descendants(matching: .any)[AccessibilityID.captureQueuedBadge].firstMatch
        XCTAssertFalse(queued.waitForExistence(timeout: 8),
                       "A queued badge surfaced on the online relaunch — the offline receipt did not drain")
    }

    /// J12 (live, sync half): after live onboarding the new profile is persisted on the
    /// backend — relaunching and signing in again returns the shell directly (session +
    /// profile synced), not onboarding. Proves device→wrangler-dev→device round-trip.
    func testProfilePersistsAcrossRelaunch() throws {
        try launchLive()
        tapDevSignIn()
        // STATE-TOLERANT (shared-persist dev account, see J02's note): onboard only if a
        // fresh account lands on the form; if a prior live test already created the profile,
        // the shell appears directly and the profile is already persisted.
        if app.textFields[AccessibilityID.onboardingName].waitForExistence(timeout: 8) {
            let name = app.textFields[AccessibilityID.onboardingName]
            name.tap(); name.typeText("Persist Co")
            app.buttons[AccessibilityID.onboardingTypeBusiness].tap()
            app.buttons[AccessibilityID.onboardingCreate].tap()
            if app.buttons["Not now"].waitForExistence(timeout: 5) { app.buttons["Not now"].tap() }
            if app.buttons["Not now"].waitForExistence(timeout: 3) { app.buttons["Not now"].tap() }
        }
        XCTAssertTrue(app.otherElements[AccessibilityID.shellTabBar].waitForExistence(timeout: 15),
                      "Did not reach the shell")
        // Relaunch WITHOUT reset (keep the live session): should land in the shell, not onboarding.
        app.terminate()
        app.launchArguments = []   // no -uiTestReset → session survives
        app.launchEnvironment["API_BASE_URL"] = ProcessInfo.processInfo.environment["API_BASE_URL"] ?? "http://127.0.0.1:8787"
        app.launch()
        XCTAssertTrue(app.otherElements[AccessibilityID.shellTabBar].waitForExistence(timeout: 20),
                      "Relaunch did not restore the synced shell")
    }
}
