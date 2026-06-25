import XCTest

/// The floating tab bar must hug the bottom edge — never float high up the screen. This
/// guards the keyboard-inset pin: the bar is bottom-aligned in a ZStack that respects the
/// keyboard safe area, and a STALE keyboard inset used to leave the bar stuck floating up
/// until relaunch. The fix gives it a full-height frame + `.ignoresSafeArea(.keyboard)` so its
/// position depends only on the container safe area.
final class TabBarDiagUITests: UITestCase {
    func testTabBarHugsBottomOnHome() {
        launchSeeded(pro: true)
        let tabBar = app.descendants(matching: .any)[AccessibilityID.shellTabBar].firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "tab bar missing")
        // Gap between the tab bar's bottom and the screen bottom — the floating bar sits ~26pt
        // above the home indicator, so anything under ~40 means it's hugging the bottom.
        let gapBelow = app.windows.firstMatch.frame.maxY - tabBar.frame.maxY
        XCTAssertLessThan(gapBelow, 40,
                          "tab bar should hug the bottom; gapBelow=\(gapBelow) means it floated up")
    }
}
