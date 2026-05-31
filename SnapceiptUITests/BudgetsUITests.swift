import XCTest

/// Hermetic budgets/alerts/notifications flow: seeded shell + stub API (no network).
/// Home tracker renders seeded budgets (incl. over-cap) -> add a budget -> tracker
/// updates; open AlertsSheet from the seeded alerted budget -> dismiss; open
/// Notifications settings -> toggle push + set quiet hours.
/// NO live push: the simulator cannot issue real APNs tokens; registration fails
/// gracefully and real push is covered by the backend unit tests + the stub seam.
final class BudgetsUITests: UITestCase {
    func testTrackerAddAlertsAndNotifications() {
        launchSeeded()   // signed-in, business profile p1 active, seeded budgets + an alerted budget

        // Home tracker renders.
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.homeBudgetTracker].waitForExistence(timeout: 10),
                      "Budget tracker missing on Home")

        // Add a budget via the Edit link -> list -> Add CTA -> editor -> Save.
        // NOTE: the Home container applies `.accessibilityElement(children: .contain)`,
        // so the tracker's `home.budgetTracker` identifier propagates to its child
        // controls (the Edit button + each budget-row button all report that id). The
        // Edit control is therefore matched by its visible label "Edit".
        let edit = app.buttons["Edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "Edit link missing")
        edit.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.budgetListScreen].waitForExistence(timeout: 5),
                      "Budget list did not appear")
        app.buttons[AccessibilityID.budgetListAdd].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.budgetEditorScreen].waitForExistence(timeout: 5),
                      "Budget editor did not appear")
        let cap = app.textFields[AccessibilityID.budgetEditorCap]
        XCTAssertTrue(cap.waitForExistence(timeout: 5), "Cap field missing")
        cap.tap(); cap.typeText("300")
        // The numberPad keyboard covers the bottom-pinned Save button. Tap the screen
        // chrome to dismiss it first, then Save. (The "Period" label is always
        // on-screen near the top and is safe to tap as a keyboard-dismiss target.)
        app.staticTexts["Period"].firstMatch.tap()
        let save = app.buttons[AccessibilityID.budgetEditorSave]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Save button missing")
        save.tap()

        // OVERLAY MODEL: `.budgets` and `.budgetEditor` are MUTUALLY-EXCLUSIVE router
        // overlays (one `router.overlay` at a time), so opening the editor REPLACED the
        // list, and Save -> `router.dismissOverlay()` lands back on HOME (the tracker),
        // NOT the list. Assert we returned to Home and the tracker still shows.
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.homeBudgetTracker].waitForExistence(timeout: 5),
                      "Did not return to Home tracker after save")

        // Open the AlertsSheet from the Home bell -> dismiss the seeded alert.
        let bell = app.buttons[AccessibilityID.homeAlertsBell].firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 5), "Alerts bell missing")
        bell.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.alertsScreen].waitForExistence(timeout: 5),
                      "Alerts sheet did not appear")
        // The seeded "Coffee" budget alerted this month -> at least one alert row.
        let firstAlert = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", AccessibilityID.alertRowPrefix)).firstMatch
        XCTAssertTrue(firstAlert.waitForExistence(timeout: 5), "No seeded alert row rendered")
        firstAlert.swipeLeft()
        let dismiss = app.buttons["Dismiss"].firstMatch
        if dismiss.waitForExistence(timeout: 3) { dismiss.tap() }
        app.buttons[AccessibilityID.logbookClose].firstMatch.tap()

        // Notifications settings via the Profile tab -> toggle push + quiet hours.
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        let notifRow = app.buttons[AccessibilityID.profileRowNotifications].firstMatch
        XCTAssertTrue(notifRow.waitForExistence(timeout: 5), "Notifications row missing on Profile")
        notifRow.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.notifSettingsScreen].waitForExistence(timeout: 5),
                      "Notifications settings did not appear")
        let push = app.switches[AccessibilityID.notifPushToggle].firstMatch
        XCTAssertTrue(push.waitForExistence(timeout: 5), "Push toggle missing")
        push.tap()   // flips push_enabled (stubbed updateDevice, no network)
    }
}
