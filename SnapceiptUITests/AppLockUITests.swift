import XCTest

/// J08: enable app lock, relaunch, and confirm the lock state round-trips —
/// the gate engages on relaunch (then the deterministic stub evaluator clears it),
/// the shell is reachable (not stuck under the cover), and `sc.lock.enabled`
/// survived the terminate/relaunch (re-read in-test, not out-of-band).
/// Needs the -uiTestLockAvailable seam (biometrics report available + always-succeed).
final class AppLockUITests: UITestCase {
    func testLockGatesRelaunch() {
        // Teardown ALWAYS clears the persisted lock so a failure mid-test (or the
        // leaked sc.lock.enabled=true) can't lock out a later -uiTestReset launch —
        // including the live (E2E_LIVE) suite, which runs without -uiTestStub and so
        // gets the real LAContext evaluator that can't succeed on a passcode-less sim.
        addTeardownBlock {
            let cleanup = XCUIApplication()
            cleanup.launchArguments = ["-uiTestStub", "-uiTestReset"]
            cleanup.launch()
            cleanup.terminate()
        }

        // First launch: seeded shell with biometrics AVAILABLE.
        app.launchArguments += ["-uiTestStub", "-uiTestSeed", "-uiTestLockAvailable"]
        app.launch()

        // Privacy → enable the app-lock toggle.
        openPrivacy()
        let toggle = app.switches[AccessibilityID.privacyAppLockToggle]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "App-lock toggle missing")
        XCTAssertTrue(toggle.isEnabled, "Toggle should be enabled when biometrics are available")
        toggle.tap()
        // The binding flips via an async `Task { await appLock.setEnabled(on) }` with a
        // suspension point BEFORE the UserDefaults write (PrivacyView.swift:25 →
        // AppLockController.swift:54-63), so the ON state lands a runloop or two after the
        // tap. Wait for the switch to actually read "1" so we KNOW sc.lock.enabled was
        // persisted before we terminate — otherwise a fast relaunch could beat the write
        // and the test would silently pass un-gated.
        waitForValue("1", on: toggle, message: "App-lock toggle did not flip ON after tap")

        // Relaunch: the persisted lock (sc.lock.enabled) should gate the shell behind
        // LockScreen on cold launch (lockIfEnabled sets isLocked). Keep the SAME args.
        app.terminate()
        app.launchArguments = ["-uiTestStub", "-uiTestSeed", "-uiTestLockAvailable"]
        app.launch()

        // The LockScreen cover auto-prompts the evaluator the instant it appears
        // (RootView `.onAppear { onUnlock() }`); under the deterministic stub
        // (`evaluate: { true }`) the gate clears in a single runloop, faster than
        // XCUITest can reliably snapshot the transient unlock button — so we don't
        // assert the (flaky) cover, we assert it RESOLVES correctly:
        //   1. the shell tab bar is HITTABLE — `isHittable` (unlike `exists`) is false
        //      while LockScreen, a sibling ZStack with no .accessibilityHidden, covers it,
        //      so this fails in the gated-and-stuck world that the old `exists` check missed.
        let shellTabBar = app.otherElements[AccessibilityID.shellTabBar]
        XCTAssertTrue(shellTabBar.waitForExistence(timeout: 10), "Shell tab bar never appeared")
        waitUntilHittable(shellTabBar, message: "Shell tab bar not hittable — stuck under the lock cover on relaunch")
        //   2. no unlock gate remains after the settle.
        let unlock = app.descendants(matching: .any)[AccessibilityID.appLockUnlock].firstMatch
        XCTAssertFalse(unlock.waitForExistence(timeout: 2),
                       "Unlock gate still present after relaunch — stub evaluator failed to clear it")

        // Persistence proven IN-TEST (replaces the prior out-of-band plist inspection):
        // re-open Privacy after the relaunch and confirm the toggle still reads ON, i.e.
        // sc.lock.enabled survived the terminate → cold launch.
        openPrivacy()
        let toggleAfter = app.switches[AccessibilityID.privacyAppLockToggle]
        XCTAssertTrue(toggleAfter.waitForExistence(timeout: 5), "App-lock toggle missing after relaunch")
        waitForValue("1", on: toggleAfter,
                     message: "App-lock toggle did not persist ON across relaunch (sc.lock.enabled lost)")
    }

    /// Navigate the seeded shell to the Privacy & security screen.
    private func openPrivacy() {
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        let privacyRow = app.descendants(matching: .any)[AccessibilityID.profileRowPrivacy].firstMatch
        XCTAssertTrue(privacyRow.waitForExistence(timeout: 10), "Privacy row missing")
        privacyRow.tap()
    }

    /// Poll the element's LIVE `value` until it reads `expected` (re-snapshots each
    /// iteration, unlike an `XCTNSPredicateExpectation` bound to a cached XCUIElement
    /// proxy, which can miss an async write that lands shortly after the wait starts).
    private func waitForValue(_ expected: String, on element: XCUIElement,
                              timeout: TimeInterval = 5, message: String) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (element.value as? String) == expected { return }
            usleep(100_000)   // 0.1s
        }
        XCTFail("\(message) (last value: \(String(describing: element.value)))")
    }

    /// Poll the element's LIVE `isHittable` (occlusion-aware, unlike `exists`).
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 10, message: String) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable { return }
            usleep(100_000)   // 0.1s
        }
        XCTFail(message)
    }
}
