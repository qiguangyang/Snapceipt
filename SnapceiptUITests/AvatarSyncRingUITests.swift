import XCTest

/// Verifies the avatar sync ring (which replaced the floating "Syncing…" pill): GREEN while
/// syncing, RED when the server is unreachable, NONE when idle. Captures a screenshot of each
/// state (synchronized via the syncStatusPill a11y probe). Asserts the offline → red path; the
/// green capture is best-effort (depends on the push-stall window).
final class AvatarSyncRingUITests: UITestCase {
    private func probe() -> XCUIElement {
        app.descendants(matching: .any)[AccessibilityID.syncStatusPill].firstMatch
    }
    @discardableResult
    private func waitValue(_ v: String, _ timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "value == %@", v)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: probe())],
                                timeout: timeout) == .completed
    }

    @MainActor func test_syncRing_white_while_syncing() {
        // Stall the push so the sync stays in-flight → WHITE ring.
        app.launchArguments += ["-uiTestStub", "-uiTestSeed", "-uiTestActiveType", "personal", "-uiTestPushStall"]
        app.launch()
        require(app.descendants(matching: .any)[AccessibilityID.profileSwitcher], "avatar")
        XCTAssertTrue(waitValue("syncing", 12), "did not reach syncing")
        shoot(app, "sync-ring-white-syncing")
    }

    // NOTE: the GREEN success flash (.syncing → .idle, ~2s) isn't UITest-captured: the stub sync
    // resolves too fast to register the transition reliably. It's exercised live with real network
    // latency and verified by the ring-colour logic (ProfileSwitcherHeader.ringColor).

    @MainActor func test_syncRing_red_when_unreachable() {
        // The seeded push is rejected (422) → SyncEngine status = .error → red avatar ring.
        app.launchArguments += ["-uiTestStub", "-uiTestSeed", "-uiTestActiveType", "personal", "-uiTestPushReject"]
        app.launch()
        require(app.descendants(matching: .any)[AccessibilityID.profileSwitcher], "avatar")
        let red = NSPredicate(format: "value == 'offline' OR value == 'error'")
        let ok = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: red, object: probe())],
                                  timeout: 25) == .completed
        XCTAssertTrue(ok, "sync did not reach offline/error")
        shoot(app, "sync-ring-red")
    }
}
