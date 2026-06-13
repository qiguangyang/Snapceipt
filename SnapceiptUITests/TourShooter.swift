import XCTest

/// Screenshot helper for `ScreenshotTourUITests`. `shoot(name:)` settles the UI,
/// captures the full app screen, and attaches it with `lifetime = .keepAlways`
/// and the screen name so `scripts/tour.sh` can export it via `xcresulttool`.
/// The attachment NAME is the `<screen>-<state>` token the script maps to a PNG.
extension XCTestCase {
    /// Settle, then attach a named full-app screenshot.
    /// - Parameter app: the launched application under test.
    /// - Parameter name: the `<screen>-<state>` token (e.g. `home-populated-business`).
    func shoot(_ app: XCUIApplication, _ name: String, settle: TimeInterval = 0.6) {
        // Let any in-flight enter/transition animation finish before capturing.
        // 0.6s comfortably exceeds the longest UI animation in the app
        // (ProgressBar .6s; most are <= .34s snap-curve).
        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline { _ = app.exists }   // spin without blocking the run loop

        let shot = app.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    /// Wait for an element to exist (default 8s) and fail with a clear message if not.
    @discardableResult
    func require(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 8) -> Bool {
        let ok = element.waitForExistence(timeout: timeout)
        XCTAssertTrue(ok, "tour: \(label) never appeared")
        return ok
    }
}
