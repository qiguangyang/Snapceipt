import XCTest

final class BasUITests: UITestCase {
    @MainActor func test_basCardOpensBasViewFixesIncomeAndLodges() {
        launchBasSeed()
        app.buttons[AccessibilityID.tabReports].tap()
        let card = app.descendants(matching: .any)[AccessibilityID.reportsBasCard]
        XCTAssertTrue(card.waitForExistence(timeout: 8), "BAS card missing for registered business")
        card.tap()
        // BasView spine.
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.basScreen].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.basCopy1A].waitForExistence(timeout: 4),
                      "1A copy control missing")

        // Headline starts "Estimated" (income unconfirmed).
        XCTAssertTrue(app.staticTexts["Estimated"].waitForExistence(timeout: 4),
                      "headline should start Estimated with unconfirmed income")
        // Fix the reconciliation item: confirm income → headline flips to firm.
        let confirm = app.descendants(matching: .any)[AccessibilityID.basConfirmIncome]
        XCTAssertTrue(confirm.waitForExistence(timeout: 4), "confirm-income quick-fix missing")
        confirm.tap()
        // "Estimated" label is gone once income is reviewed.
        let stillEstimated = app.staticTexts["Estimated"]
        XCTAssertFalse(stillEstimated.waitForExistence(timeout: 3),
                       "headline must flip from Estimated to firm after confirming income")

        // Copy 1A (no crash; pasteboard write is best-effort under test).
        app.descendants(matching: .any)[AccessibilityID.basCopy1A].tap()
        // Mark-as-lodged.
        app.descendants(matching: .any)[AccessibilityID.basMarkLodged].tap()
        // Export button exists.
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.basExport].waitForExistence(timeout: 4))
    }

    @MainActor func test_nonRegisteredProfileHidesBasCard() {
        launchBasSeed()
        // Switch to the non-registered business profile (p2 "Side Hustle") via the
        // home-header picker — the canonical switch path (ProfilePickerSheet calls
        // store.setActive). The picker rows are identified by profile name.
        app.buttons[AccessibilityID.tabHome].firstMatch.tap()
        let switcher = app.buttons[AccessibilityID.profileSwitcher].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 8), "profile switcher missing")
        switcher.tap()
        XCTAssertTrue(app.staticTexts["Switch profile"].waitForExistence(timeout: 5), "Picker did not open")
        app.staticTexts["Side Hustle"].firstMatch.tap()
        app.buttons[AccessibilityID.tabReports].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.reportsScreen].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)[AccessibilityID.reportsBasCard].exists,
                       "BAS card must be hidden for a non-registered profile")
    }
}
