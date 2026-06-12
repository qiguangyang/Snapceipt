import XCTest

/// J23b: a 4xx push contract rejection surfaces the visible .error sync state.
/// J23c: an inflight push, interrupted by relaunch, requeues to pending and drains.
final class SyncFailureUITests: UITestCase {
    func testPushRejectionShowsErrorPill() {
        app.launchArguments += ["-uiTestStub", "-uiTestSeed", "-uiTestPushReject"]
        app.launch()
        // Capture + save → enqueues a mutation → SyncEngine.push() → stub rejects (422).
        app.buttons[AccessibilityID.tabSnap].firstMatch.tap()
        let save = app.buttons[AccessibilityID.captureSave]
        XCTAssertTrue(save.waitForExistence(timeout: 12), "Review did not appear")
        save.tap()
        if app.buttons[AccessibilityID.captureDone].waitForExistence(timeout: 5) {
            app.buttons[AccessibilityID.captureDone].tap()
        }
        // save() only ENQUEUES the mutation; a push fires on the scenePhase→.active
        // sync trigger (RootView). Background + reactivate to drive that push, which
        // the stub rejects (422) → SyncEngine sets .error.
        XCUIDevice.shared.press(.home)
        app.activate()
        // The sync status pill reflects the .error state (value contains "error" / "failed").
        let pill = app.descendants(matching: .any)[AccessibilityID.syncStatusPill].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 12), "Sync status pill missing")
        let errored = NSPredicate(format: "value CONTAINS[c] 'error' OR value CONTAINS[c] 'fail' OR value CONTAINS[c] 'retry'")
        wait(for: [expectation(for: errored, evaluatedWith: pill)], timeout: 12)
    }

    /// J23c (live crash-recovery): an inflight push, interrupted by a terminate,
    /// requeues to pending on the next launch and drains.
    ///
    /// Runs on the LIVE-wrangler path (no `-uiTestStub`) so the SwiftData store is
    /// ON DISK and survives `app.terminate()` — under `-uiTestStub` the store is
    /// in-memory (`makeSnapceiptContainer(inMemory: useStub)`) and the outbox is
    /// wiped on terminate, which is why the plan's fallback (line 1180) prescribes
    /// the live runner here. Invoke via:
    ///   scripts/ios-e2e-journeys.sh --persist .e2e-journey-state SyncFailureUITests
    /// (the runner sets E2E_LIVE=1 + API_BASE_URL and boots local wrangler dev).
    ///
    /// Mechanism: `-uiTestPushStall` parks the live `syncPush` indefinitely. SyncEngine
    /// marks the batch `inflight` and saves it to the on-disk store BEFORE that call
    /// (SyncEngine.swift:104-105), so terminating while it is parked strands a real
    /// persisted `inflight` row. The clean relaunch's first sync runs
    /// `requeueStrandedInflight()` (SyncEngine.swift:255, unconditional at push() head),
    /// which re-marks the row `pending`; the push then drains it → the pill is non-error.
    func testInflightRequeuesAfterRelaunch() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["E2E_LIVE"] == "1",
                          "J23c crash-recovery requeue needs the live runner: "
                          + "scripts/ios-e2e-journeys.sh --persist .e2e-journey-state SyncFailureUITests")
        let base = env["API_BASE_URL"] ?? "http://127.0.0.1:8787"

        // --- First run: reach the live shell, capture+save (enqueues a mutation),
        //     then drive a push that PARKS inflight, and terminate to strand it. ---
        // `-uiTestOffline` is required on the live path purely to admit the camera-less
        // canned scan (AppLaunch.cannedScan gates on `useStub || offline`) so capture can
        // reach Review without a real camera — same reason J18c uses it. It gates only
        // extract/uploadImage (HeuristicParser fallback), NOT enqueue/push: the
        // transaction mutation is still enqueued and the push still runs (and parks).
        app.launchArguments += ["-uiTestReset", "-uiTestOffline", "-uiTestPushStall"]
        app.launchEnvironment["API_BASE_URL"] = base
        app.launch()
        tapDevSignIn()
        // State-tolerant onboarding (shared-persist dev account; see LiveJourneyUITests).
        if app.textFields[AccessibilityID.onboardingName].waitForExistence(timeout: 8) {
            let name = app.textFields[AccessibilityID.onboardingName]
            name.tap(); name.typeText("Requeue Co")
            app.buttons[AccessibilityID.onboardingTypeBusiness].tap()
            app.buttons[AccessibilityID.onboardingCreate].tap()
            if app.buttons["Not now"].waitForExistence(timeout: 5) { app.buttons["Not now"].tap() }
            if app.buttons["Not now"].waitForExistence(timeout: 3) { app.buttons["Not now"].tap() }
        }
        XCTAssertTrue(app.otherElements[AccessibilityID.shellTabBar].waitForExistence(timeout: 15),
                      "Did not reach the live shell")
        let snap = app.buttons[AccessibilityID.tabSnap].firstMatch
        XCTAssertTrue(snap.waitForExistence(timeout: 12), "Snap tab not found")
        snap.tap()
        let save = app.buttons[AccessibilityID.captureSave]
        XCTAssertTrue(save.waitForExistence(timeout: 12), "Review did not appear")
        save.tap()   // enqueues the transaction mutation (synchronous outbox insert)
        if app.buttons[AccessibilityID.captureDone].waitForExistence(timeout: 5) {
            app.buttons[AccessibilityID.captureDone].tap()
        }
        // Drive the push (scenePhase→.active fires SyncEngine.sync()). The stub-less
        // live syncPush parks → the batch is saved `inflight` on disk and the pill
        // shows `syncing` (never resolves while stalled).
        XCUIDevice.shared.press(.home)
        app.activate()
        let pill = app.descendants(matching: .any)[AccessibilityID.syncStatusPill].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 12), "Sync status pill missing")
        let syncing = NSPredicate(format: "value CONTAINS[c] 'sync'")
        wait(for: [expectation(for: syncing, evaluatedWith: pill)], timeout: 15)
        app.terminate()   // strand the inflight row on the persisted store

        // --- Clean relaunch (no stall, no reset → on-disk outbox survives): the first
        //     sync requeues the stranded inflight row to pending and drains it. ---
        app.launchArguments = []
        app.launchEnvironment["API_BASE_URL"] = base
        app.launch()
        let pill2 = app.descendants(matching: .any)[AccessibilityID.syncStatusPill].firstMatch
        XCTAssertTrue(pill2.waitForExistence(timeout: 15), "Sync pill missing after relaunch")
        // The requeued row drains: assert the pill settles on the exact `idle` token.
        // `SyncStatusView.stateToken` emits only `idle | syncing | offline | error`; a
        // negative predicate would falsely pass on `offline` (transport flap re-marks the
        // row pending and the push throws → `.offline`) without the drain completing.
        // `status = .idle` is set only at SyncEngine.swift:146, AFTER every batch drains
        // successfully, so equality on `idle` is the precise drain-completed postcondition.
        let drained = NSPredicate(format: "value == 'idle'")
        wait(for: [expectation(for: drained, evaluatedWith: pill2)], timeout: 25)
    }
}
