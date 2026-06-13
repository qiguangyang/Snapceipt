import XCTest

/// J52d: smart-rule create → edit → delete through RuleEditorView.
///
/// Grounding notes (verified against `CategoriesView`/`RuleEditorView`/`Router`, Task 22b):
///   • The rules surface is hosted under Categories (`profileRowCategories` →
///     `categoriesScreen`), where `ruleAddButton` and the `ruleRowPrefix` rows live.
///   • Settings screens are single-slot `.overlay`s driven by `router.overlay`, NOT
///     stacked sheets: `onEditRule` REPLACES the Categories overlay with the editor,
///     and the editor's Save → `onClose()` → `dismissOverlay()` returns to the ROOT
///     tab (not back to Categories). So Categories is re-opened after each editor
///     dismissal to inspect the rule list.
///   • Delete is NOT swipe-to-delete: each `ruleRow` has an inline destructive
///     `Button` carrying `accessibilityLabel("Delete rule")`.
///   • The editor's first `TextField` is the matcher ("e.g. uber"); Save carries
///     `ruleEditorSave` (disabled until the matcher is non-empty).
final class SmartRulesUITests: UITestCase {
    private func openCategories() {
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        app.buttons[AccessibilityID.profileRowCategories].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.categoriesScreen].firstMatch
                        .waitForExistence(timeout: 5), "Categories/rules screen did not open")
    }

    private var ruleRows: XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.ruleRowPrefix))
    }

    func testRuleCreateEditDelete() {
        launchSeeded()
        openCategories()

        // Create a rule.
        let add = app.descendants(matching: .any)[AccessibilityID.ruleAddButton].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Add-rule control missing")
        add.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.ruleEditorScreen].firstMatch
                        .waitForExistence(timeout: 5), "Rule editor did not open")
        // Fill the editor's first text field (the matcher keyword) and save.
        let firstField = app.textFields.firstMatch
        XCTAssertTrue(firstField.waitForExistence(timeout: 5), "Rule editor field missing")
        firstField.tap(); firstField.typeText("Uber")
        app.buttons[AccessibilityID.ruleEditorSave].firstMatch.tap()

        // Save dismisses to root; re-open Categories → the new rule appears as a row.
        openCategories()
        let row = ruleRows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "New rule row not listed after create")

        // Edit it: reopen via the row body → save again (dismisses to root).
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.ruleEditorScreen].firstMatch
                        .waitForExistence(timeout: 5), "Rule editor did not reopen for edit")
        app.buttons[AccessibilityID.ruleEditorSave].firstMatch.tap()

        // Re-open Categories → delete it via the inline per-row destructive button.
        openCategories()
        XCTAssertTrue(ruleRows.firstMatch.waitForExistence(timeout: 5), "Rule row missing before delete")
        let del = app.buttons["Delete rule"].firstMatch
        XCTAssertTrue(del.waitForExistence(timeout: 5), "Inline delete-rule button missing")
        del.tap()
        // The row is gone.
        XCTAssertTrue(ruleRows.firstMatch.waitForNonExistence(timeout: 5),
                      "Rule row still present after delete")
    }
}
