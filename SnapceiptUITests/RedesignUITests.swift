import XCTest

/// Covers the design-100 refinements: the Home summary hero + Snap CTA, the Activity
/// search / filter / month controls, the Add-Manually flow, and the transaction-detail
/// Edit / Delete actions. Runs against the seeded shell (2 profiles + data).
final class RedesignUITests: UITestCase {

    // MARK: - Home

    func testHomeShowsSummaryHeroAndSnapCTA() {
        launchSeeded()
        XCTAssertTrue(app.otherElements[AccessibilityID.homeSummary].waitForExistence(timeout: 10),
                      "Home net-this-month summary hero missing")
        XCTAssertTrue(app.buttons[AccessibilityID.homeSnapCTA].waitForExistence(timeout: 5),
                      "Home Snap-a-receipt CTA missing")
        XCTAssertTrue(app.buttons[AccessibilityID.homeQuickManual].waitForExistence(timeout: 5),
                      "Home 'Add Manually' quick action missing")
    }

    // MARK: - Activity controls

    func testActivityHasSearchFiltersAndMonthPicker() {
        launchSeeded()
        app.buttons[AccessibilityID.tabActivity].tap()
        // The search field is the reliable "Activity is present" signal (a concrete
        // element, vs the ScrollView container which XCUITest exposes as a scrollView).
        XCTAssertTrue(app.textFields[AccessibilityID.activitySearch].waitForExistence(timeout: 10),
                      "Activity search field missing")
        XCTAssertTrue(app.buttons[AccessibilityID.activityFilterAll].exists, "All filter chip missing")
        XCTAssertTrue(app.buttons[AccessibilityID.activityFilterExpenses].exists, "Expenses filter chip missing")
        XCTAssertTrue(app.buttons[AccessibilityID.activityFilterIncome].exists, "Income filter chip missing")
        XCTAssertTrue(app.buttons[AccessibilityID.activityMonthPicker].exists, "Month picker missing")
        // Filtering to Income should not crash and keeps the screen up.
        app.buttons[AccessibilityID.activityFilterIncome].tap()
        XCTAssertTrue(app.textFields[AccessibilityID.activitySearch].exists)
    }

    // MARK: - Add manually

    func testAddManualTransactionSavesAndReturns() {
        launchSeeded()
        app.buttons[AccessibilityID.homeQuickManual].tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.manualScreen].waitForExistence(timeout: 8),
                      "Manual entry screen did not appear")

        let amount = app.textFields[AccessibilityID.manualAmount]
        XCTAssertTrue(amount.waitForExistence(timeout: 5), "Amount field missing")
        amount.tap(); amount.typeText("12.50")

        let merchant = app.textFields[AccessibilityID.manualMerchant]
        merchant.tap(); merchant.typeText("Test Cafe")

        app.buttons[AccessibilityID.manualSave].tap()
        // Back on the shell (manual overlay dismissed).
        XCTAssertTrue(app.buttons[AccessibilityID.tabActivity].waitForExistence(timeout: 8),
                      "Did not return to the shell after saving")
    }

    // MARK: - Detail Edit / Delete

    func testTransactionDetailHasEditAndDelete() {
        launchSeeded()
        app.buttons[AccessibilityID.tabActivity].tap()
        XCTAssertTrue(app.textFields[AccessibilityID.activitySearch].waitForExistence(timeout: 10),
                      "Activity screen missing")

        // Tap the first receipt row (newest month is selected by default, so rows show).
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.activityRowPrefix)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "No transaction rows to open")
        // Coordinate tap: a plain .tap() inside the scroll view can be swallowed as a
        // scroll gesture, leaving the row's button action unfired.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // The top-bar close button signals the detail is present; the Edit/Delete
        // actions live at the bottom of the scroll, so swipe up to bring them on-screen.
        XCTAssertTrue(app.buttons[AccessibilityID.receiptDetailClose].waitForExistence(timeout: 8),
                      "Receipt detail did not appear")
        app.swipeUp(); app.swipeUp()
        XCTAssertTrue(app.buttons[AccessibilityID.receiptDetailEdit].waitForExistence(timeout: 3), "Edit action missing")
        XCTAssertTrue(app.buttons[AccessibilityID.receiptDetailDelete].exists, "Delete action missing")
    }
}
