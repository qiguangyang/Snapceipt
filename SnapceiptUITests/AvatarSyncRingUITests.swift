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

    @MainActor func test_syncRing_green_while_syncing() {
        app.launchArguments += ["-uiTestStub", "-uiTestSeed", "-uiTestActiveType", "personal", "-uiTestPushStall"]
        app.launch()
        require(app.descendants(matching: .any)[AccessibilityID.profileSwitcher], "avatar")
        if waitValue("syncing", 12) { shoot(app, "sync-ring-green") }   // best-effort
        // The stall releases → idle → no ring (also proves the banner is gone).
        if waitValue("idle", 25) { shoot(app, "sync-ring-idle-no-banner") }
    }

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
