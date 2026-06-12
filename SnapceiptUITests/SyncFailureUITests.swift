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

    /// Relaunch-cleanliness net for the crash-recovery requeue path.
    ///
    /// NOTE: the FULL `requeueStrandedInflight()` crash-recovery scenario is NOT
    /// exercisable through the seams this program ships — under `-uiTestStub` the
    /// SwiftData store is in-memory (`makeSnapceiptContainer(inMemory: useStub)`),
    /// so `app.terminate()` wipes the outbox and no `inflight` row survives the
    /// relaunch; and on the live runner the `-uiTestPushReject` seam is read inside
    /// `StubAPIClient` only, so the real client never strands an `inflight` row to
    /// begin with. Stranding a surviving `inflight` row would need a new "die
    /// mid-push" / persistent-stub seam — flow/seam restructuring, out of guardrail
    /// (deferred-findings: "J23c inflight crash-recovery requeue").
    ///
    /// What this DOES verify: a session that hit a 4xx push rejection (.error) does
    /// not poison a subsequent clean relaunch — the next launch's sync reaches a
    /// non-error state. `requeueStrandedInflight()` (shipped, SyncEngine.swift:255)
    /// still runs unconditionally at the head of every `push()`.
    func testRelaunchAfterRejectReachesNonErrorSync() {
        // First run: reject pushes so the session ends in .error.
        app.launchArguments += ["-uiTestStub", "-uiTestSeed", "-uiTestPushReject"]
        app.launch()
        app.buttons[AccessibilityID.tabSnap].firstMatch.tap()
        let save = app.buttons[AccessibilityID.captureSave]
        XCTAssertTrue(save.waitForExistence(timeout: 12), "Review did not appear")
        save.tap()
        XCUIDevice.shared.press(.home)
        app.activate()   // drive the rejecting push so the session is in .error
        let pill = app.descendants(matching: .any)[AccessibilityID.syncStatusPill].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 12), "Sync status pill missing")
        let errored = NSPredicate(format: "value CONTAINS[c] 'error' OR value CONTAINS[c] 'fail'")
        wait(for: [expectation(for: errored, evaluatedWith: pill)], timeout: 12)
        app.terminate()
        // Relaunch WITHOUT the reject seam: the next sync (incl. the unconditional
        // requeueStrandedInflight() at the head of push()) must reach a non-error state.
        app.launchArguments = ["-uiTestStub", "-uiTestSeed"]
        app.launch()
        let pill2 = app.descendants(matching: .any)[AccessibilityID.syncStatusPill].firstMatch
        XCTAssertTrue(pill2.waitForExistence(timeout: 15), "Sync pill missing after relaunch")
        let drained = NSPredicate(format: "NOT (value CONTAINS[c] 'error' OR value CONTAINS[c] 'fail')")
        wait(for: [expectation(for: drained, evaluatedWith: pill2)], timeout: 20)
    }
}
