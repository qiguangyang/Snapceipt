import XCTest

/// Covers the design-100 refinements: the Home summary hero + Snap CTA, the Activity
/// search / filter / month controls, the Add-Manually flow, and the transaction-detail
/// Edit / Delete actions. Runs against the seeded shell (2 profiles + data).
final class RedesignUITests: UITestCase {

    // MARK: - Home

    func testHomeShowsSummaryHeroAndSnapCTA() {
        launchSeeded()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.homeSummary].waitForExistence(timeout: 10),
                      "Home net-this-month summary hero missing")
        XCTAssertTrue(app.buttons[AccessibilityID.homeSnapCTA].waitForExistence(timeout: 5),
                      "Home Snap-a-receipt CTA missing")
        XCTAssertTrue(app.buttons[AccessibilityID.homeQuickManual].waitForExistence(timeout: 5),
                      "Home 'Add Manually' quick action missing")
    }

    func testBellOpensAlerts() {
        launchSeeded()
        let bell = app.buttons[AccessibilityID.homeAlertsBell]
        XCTAssertTrue(bell.waitForExistence(timeout: 10), "Bell missing")
        bell.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.alertsScreen].waitForExistence(timeout: 6),
                      "Alerts did not open from the Home bell")
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

    // MARK: - Add manually: line items

    func testAddManualLineItemsAutoSumAndPersistToDetail() {
        launchSeeded()
        app.buttons[AccessibilityID.homeQuickManual].tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.manualScreen].waitForExistence(timeout: 8),
                      "Manual entry screen did not appear")

        // Add two items (dismiss the keyboard between fields — a sibling tap with the
        // keyboard up is otherwise swallowed as a dismiss / fails to take focus).
        let add = app.buttons[AccessibilityID.manualItemsAdd]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Add-item affordance missing")
        add.tap()
        let name0 = app.textFields["\(AccessibilityID.manualItemNamePrefix)0"]
        XCTAssertTrue(name0.waitForExistence(timeout: 5), "First item name field missing")
        name0.tap(); name0.typeText("Coffee"); dismissKeyboard()
        let price0 = app.textFields["\(AccessibilityID.manualItemPricePrefix)0"]
        price0.tap(); price0.typeText("4.50"); dismissKeyboard()

        add.tap()
        let name1 = app.textFields["\(AccessibilityID.manualItemNamePrefix)1"]
        XCTAssertTrue(name1.waitForExistence(timeout: 5), "Second item name field missing")
        name1.tap(); name1.typeText("Sandwich"); dismissKeyboard()
        let price1 = app.textFields["\(AccessibilityID.manualItemPricePrefix)1"]
        price1.tap(); price1.typeText("12.00"); dismissKeyboard()

        // Amount auto-summed to the items' total.
        let amount = app.textFields[AccessibilityID.manualAmount]
        XCTAssertEqual(amount.value as? String, "16.50", "Amount did not auto-sum the line items")

        let merchant = app.textFields[AccessibilityID.manualMerchant]
        merchant.tap(); merchant.typeText("ZZ Lineitem Co"); dismissKeyboard()
        app.buttons[AccessibilityID.manualSave].tap()

        // Find the saved transaction in Activity and open it.
        XCTAssertTrue(app.buttons[AccessibilityID.tabActivity].waitForExistence(timeout: 8),
                      "Did not return to the shell after saving")
        app.buttons[AccessibilityID.tabActivity].tap()
        let search = app.textFields[AccessibilityID.activitySearch]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "Activity search missing")
        search.tap(); search.typeText("ZZ Lineitem Co")
        // Activity has no keyboard accessory; tapping the (already-active) All filter
        // dismisses the search keyboard so the row tap below isn't swallowed.
        app.buttons[AccessibilityID.activityFilterAll].tap()

        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.activityRowPrefix)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "Saved manual transaction row not found")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(app.buttons[AccessibilityID.receiptDetailClose].waitForExistence(timeout: 8),
                      "Receipt detail did not appear")
        // The line items persisted and render in the detail.
        XCTAssertTrue(app.staticTexts["Coffee"].waitForExistence(timeout: 5), "Coffee line item missing in detail")
        XCTAssertTrue(app.staticTexts["Sandwich"].exists, "Sandwich line item missing in detail")
    }

    func testManualAmountEditedFirstIsNotOverwrittenByItems() {
        launchSeeded()
        app.buttons[AccessibilityID.homeQuickManual].tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.manualScreen].waitForExistence(timeout: 8),
                      "Manual entry screen did not appear")

        // Enter the amount by hand first — this is the user's authoritative total.
        let amount = app.textFields[AccessibilityID.manualAmount]
        XCTAssertTrue(amount.waitForExistence(timeout: 5), "Amount field missing")
        amount.tap(); amount.typeText("20.00"); dismissKeyboard()

        // Adding an item must NOT clobber the hand-entered amount.
        app.buttons[AccessibilityID.manualItemsAdd].tap()
        let name0 = app.textFields["\(AccessibilityID.manualItemNamePrefix)0"]
        XCTAssertTrue(name0.waitForExistence(timeout: 5), "Item name field missing")
        name0.tap(); name0.typeText("Coffee"); dismissKeyboard()
        let price0 = app.textFields["\(AccessibilityID.manualItemPricePrefix)0"]
        price0.tap(); price0.typeText("4.50"); dismissKeyboard()

        XCTAssertEqual(amount.value as? String, "20.00",
                       "Hand-entered amount was overwritten by the items total")
    }

    func testAddItemAutoFocusesNameField() {
        launchSeeded()
        app.buttons[AccessibilityID.homeQuickManual].tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.manualScreen].waitForExistence(timeout: 8),
                      "Manual entry screen did not appear")

        // Tapping "Add item" should move focus to the new row's name field: the
        // keyboard appears and the field accepts typing with no further tap.
        app.buttons[AccessibilityID.manualItemsAdd].tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 4),
                      "Adding an item did not raise the keyboard (focus didn't move)")
        let name0 = app.textFields["\(AccessibilityID.manualItemNamePrefix)0"]
        XCTAssertTrue(name0.waitForExistence(timeout: 4), "New item name field missing")
        name0.typeText("Latte")   // no tap first — only works if the field is focused
        XCTAssertEqual(name0.value as? String, "Latte",
                       "Item name field wasn't auto-focused after Add item")
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
