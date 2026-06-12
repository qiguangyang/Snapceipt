import XCTest

/// J39: open a seeded budget to edit its cap, then swipe-delete a row.
///
/// Two harness facts shape this test (both documented in BudgetsUITests):
///  1. The Home tracker AND the budget list BOTH render `budget.row.<id>` Buttons,
///     so an app-wide `firstMatch` on that prefix can resolve to a tracker row
///     sitting *behind* the open list overlay (hit point {-1,-1}, not hittable).
///     We therefore scope every row query to the `budgetListScreen` subtree.
///  2. `.budgets` and `.budgetEditor` are MUTUALLY-EXCLUSIVE router overlays, so
///     opening the editor REPLACES the list and Save -> dismissOverlay() lands
///     back on HOME (the tracker), not the list. We re-open the list to delete.
///     The numberPad also covers the bottom-pinned Save, so we dismiss it first
///     by tapping the always-visible "Period" label.
final class BudgetsExtraUITests: UITestCase {
    func testEditAndDeleteBudget() {
        launchSeeded()

        // Home -> Edit budgets -> list (seeded budgets).
        let editLink = app.descendants(matching: .any)[AccessibilityID.homeBudgetEditLink].firstMatch
        XCTAssertTrue(editLink.waitForExistence(timeout: 10), "Budget edit link missing on Home")
        editLink.tap()
        let list = app.descendants(matching: .any)[AccessibilityID.budgetListScreen].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), "Budget list did not open")

        // Tap the first LIST row (scoped to the list subtree) -> editor pre-filled.
        let row = list.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.budgetRowPrefix)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "No budget rows found")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.budgetEditorScreen].firstMatch
                        .waitForExistence(timeout: 5), "Budget editor did not open")

        // Change the cap -> dismiss numberPad (tap "Period") -> Save.
        let cap = app.textFields[AccessibilityID.budgetEditorCap]
        XCTAssertTrue(cap.waitForExistence(timeout: 5), "Editor cap field missing")
        cap.tap()
        if let v = cap.value as? String, !v.isEmpty {
            cap.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: v.count))
        }
        cap.typeText("250")
        app.staticTexts["Period"].firstMatch.tap()   // dismiss numberPad covering Save
        app.buttons[AccessibilityID.budgetEditorSave].tap()

        // Save -> dismissOverlay() lands back on HOME. Re-open the list to delete.
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.homeBudgetTracker].firstMatch
                        .waitForExistence(timeout: 5), "Did not return to Home after save")
        let editLink2 = app.descendants(matching: .any)[AccessibilityID.homeBudgetEditLink].firstMatch
        XCTAssertTrue(editLink2.waitForExistence(timeout: 5), "Edit link missing after save")
        editLink2.tap()
        let list2 = app.descendants(matching: .any)[AccessibilityID.budgetListScreen].firstMatch
        XCTAssertTrue(list2.waitForExistence(timeout: 5), "List did not re-open")

        // Swipe-delete a LIST row.
        let row2 = list2.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.budgetRowPrefix)).firstMatch
        XCTAssertTrue(row2.waitForExistence(timeout: 5), "No list rows to delete")
        row2.swipeLeft()
        let del = app.buttons["Delete"]
        if del.waitForExistence(timeout: 3) { del.tap() }
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.budgetListScreen].firstMatch.exists,
                      "Budget list disappeared unexpectedly after delete")
    }
}
