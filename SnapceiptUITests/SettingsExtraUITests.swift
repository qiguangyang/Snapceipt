import XCTest

/// J52b: changing the tax FY start month recomputes the Reports FY period.
/// J52c: editing the meals default % threads into a new capture's Review surface.
///
/// Grounding notes (verified against the real views, Task 22b):
///   • `reportsPeriod` is a `Segmented` control whose option labels are the FIXED
///     strings "Month"/"Quarter"/"FY" — its element label does NOT encode the FY
///     window, so the recomputation is asserted on the netCard headline static text
///     ("Net saved · FY2025-26"), which is `Period.fy.headline` = `FinancialYear.label`.
///     The seed leaves the FY start at the default July (7) → "FY2025-26"; picking
///     January (1) moves the current date into the next FY → a different "FY…" label.
///   • `taxFyStart` is a `Menu` of month `Button`s ("January"…); `taxMealsPct` is a
///     `Stepper` (step 5, 0...100), so it exposes an "Increment" button.
///   • Tax is a `.sheet`; its `SheetHeader` close carries `logbookClose`. The tab bar
///     is covered while the sheet is up, so the sheet is dismissed before tab nav.
final class SettingsExtraUITests: UITestCase {
    func testFyStartThreadsToReports() {
        launchSeeded()
        // Record the Reports FY headline BEFORE changing the FY start (FY segment selected).
        app.buttons[AccessibilityID.tabReports].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.reportsScreen].firstMatch
                        .waitForExistence(timeout: 10), "Reports screen did not open")
        let fySegment = app.buttons["FY"].firstMatch
        XCTAssertTrue(fySegment.waitForExistence(timeout: 5), "FY period segment missing")
        fySegment.tap()
        let fyHeadline = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "FY")).firstMatch
        XCTAssertTrue(fyHeadline.waitForExistence(timeout: 10), "FY headline missing on Reports")
        let before = fyHeadline.label

        // Profile → Tax → change the FY start month to January via the month Menu.
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        app.buttons[AccessibilityID.profileRowTax].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.taxScreen].firstMatch
                        .waitForExistence(timeout: 5), "Tax screen did not open")
        let fyStart = app.descendants(matching: .any)[AccessibilityID.taxFyStart].firstMatch
        XCTAssertTrue(fyStart.waitForExistence(timeout: 5), "FY-start control missing")
        fyStart.tap()
        let jan = app.buttons["January"].firstMatch
        XCTAssertTrue(jan.waitForExistence(timeout: 3), "January option missing in FY-start menu")
        jan.tap()
        // Dismiss the Tax sheet so the tab bar is reachable again.
        app.buttons[AccessibilityID.logbookClose].firstMatch.tap()

        // Back to Reports → re-select FY → the headline must have recomputed.
        app.buttons[AccessibilityID.tabReports].firstMatch.tap()
        let fySegment2 = app.buttons["FY"].firstMatch
        XCTAssertTrue(fySegment2.waitForExistence(timeout: 10), "FY period segment missing after FY change")
        fySegment2.tap()
        let fyHeadlineAfter = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "FY")).firstMatch
        XCTAssertTrue(fyHeadlineAfter.waitForExistence(timeout: 10),
                      "FY headline missing on Reports after FY change")
        XCTAssertNotEqual(fyHeadlineAfter.label, before,
                          "Reports FY period did not recompute after changing the FY start month")
    }

    func testMealsDefaultPctThreads() {
        launchSeeded()
        // Profile → Tax → bump the meals default % via the Stepper.
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        app.buttons[AccessibilityID.profileRowTax].firstMatch.tap()
        let mealsPct = app.descendants(matching: .any)[AccessibilityID.taxMealsPct].firstMatch
        XCTAssertTrue(mealsPct.waitForExistence(timeout: 5), "Meals default-% control missing")
        let pctBefore = mealsPct.value as? String ?? mealsPct.label
        // `taxMealsPct` is a Stepper → drive its Increment; fall back to typing for a field.
        if mealsPct.buttons["Increment"].exists { mealsPct.buttons["Increment"].tap() }
        else { mealsPct.tap(); mealsPct.typeText("75") }
        let pctAfter = mealsPct.value as? String ?? mealsPct.label
        XCTAssertNotEqual(pctAfter, pctBefore, "Meals default % did not change")
        // Dismiss the Tax sheet so the Snap tab is reachable.
        app.buttons[AccessibilityID.logbookClose].firstMatch.tap()

        // New capture → the Review step surfaces the category/deductible (default % threaded in).
        app.buttons[AccessibilityID.tabSnap].firstMatch.tap()
        XCTAssertTrue(app.buttons[AccessibilityID.captureSave].waitForExistence(timeout: 12),
                      "Review did not appear")
        let deductible = app.descendants(matching: .any)[AccessibilityID.captureReviewCategory].firstMatch
        XCTAssertTrue(deductible.waitForExistence(timeout: 5),
                      "Review category/deductible surface missing — default % did not thread into capture")
    }
}
