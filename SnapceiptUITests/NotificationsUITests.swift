import XCTest

/// J53: notifications settings — toggle push, then drive the quiet-hours pickers.
final class NotificationsUITests: UITestCase {
    func testQuietHoursPickers() {
        launchSeeded()
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        let row = app.descendants(matching: .any)[AccessibilityID.profileRowNotifications].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Notifications row missing")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.notifSettingsScreen].firstMatch
                        .waitForExistence(timeout: 5), "Notifications screen did not open")
        // Toggle push (Budget alerts).
        let pushToggle = app.switches[AccessibilityID.notifPushToggle]
        XCTAssertTrue(pushToggle.waitForExistence(timeout: 5), "Push toggle missing")
        pushToggle.tap()
        // Enable Quiet hours so the start/end time pickers are revealed.
        let quietToggle = app.switches[AccessibilityID.notifQuietToggle]
        XCTAssertTrue(quietToggle.waitForExistence(timeout: 5), "Quiet-hours toggle missing")
        quietToggle.tap()
        // Quiet-hours start/end controls exist and are interactable.
        let start = app.descendants(matching: .any)[AccessibilityID.notifQuietStart].firstMatch
        let end = app.descendants(matching: .any)[AccessibilityID.notifQuietEnd].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5), "Quiet-hours start control missing")
        XCTAssertTrue(end.exists, "Quiet-hours end control missing")
        start.tap()   // opens the time picker; confirm it does not crash
        // Dismiss any picker by tapping the screen background.
        app.descendants(matching: .any)[AccessibilityID.notifSettingsScreen].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.notifSettingsScreen].firstMatch.exists,
                      "Notifications screen disappeared after interacting with quiet hours")
    }
}
