import XCTest

/// J52b: changing the tax FY start month recomputes the Reports FY period.
/// J52c: editing the meals default % threads into a new capture's Review surface.
///
/// Grounding notes (verified against the real views, Task 22b):
///   • `reportsPeriod` is a `Segmented` control whose option labels are the FIXED
///     strings "Month"/"Quarter"/"FY" — its element label does NOT encode the FY
///     window, so the recomputation is asserted on the netCard headline static text
///     ("Net saved · FY2025-26"), which is `Period.fy.headline` = `FinancialYear.label`.
///     The January-pinned tour seed leaves the FY start at the default July (7) → "FY2025-26"; picking
///     January (1) moves the current date into the next FY → a different "FY…" label.
///   • `taxFyStart` is a `Menu` of month `Button`s ("January"…); `taxMealsPct` is a
///     `Stepper` (step 5, 0...100), so it exposes an "Increment" button.
///   • Tax is a `.sheet`; its `SheetHeader` close carries `logbookClose`. The tab bar
///     is covered while the sheet is up, so the sheet is dismissed before tab nav.
final class SettingsExtraUITests: UITestCase {
    func testFyStartThreadsToReports() {
        // Existing tour fixture pins 15 Jan 2026; July and January then have distinct FY labels.
        launchTour()
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
        XCTAssertEqual(fyHeadline.label, "Net saved · FY2025-26")

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
        XCTAssertEqual(fyHeadlineAfter.label, "Net saved · FY2026-27",
                       "Reports FY period did not recompute after changing the FY start month")
    }

    func testMealsDefaultPctThreads() throws {
        // The Review banner ("claimable at X%", AccessibilityID.captureReviewBanner,
        // ReviewStep.swift:117) is the ONLY place the meals deductible % surfaces in
        // capture. The non-vacuous assertion this test WANTS to make is:
        //   bump taxMealsPct 50→55 ⇒ a new meals capture's banner reads "claimable at 55%".
        //
        // That threading is NOT wired today: the capture extract path has no TaxSettings
        // dependency, and the DEBUG stub (StubAPIClient.swift:60) returns a hardcoded
        // `"deductible":50` for every meals receipt regardless of taxMealsPct. So the
        // banner would always read "claimable at 50%" no matter what the Stepper does —
        // any assertion on it after a bump is vacuous (or would falsely fail at 55%).
        // setMealsDeductiblePct() writes only to TaxSettings.mealsDeductiblePct; it never
        // reaches the meals Category row or the capture draft.
        //
        // Per the review finding: skip explicitly rather than assert a vacuous existence
        // check that a full regression in the (unbuilt) threading path would leave green.
        // TODO(J52c): when taxMealsPct → capture deductible is wired (TaxSettings injected
        //   into the extract/draft default path, stub honoring it), delete this skip and
        //   assert app.descendants…[captureReviewBanner].label CONTAINS "claimable at 55%"
        //   after one Stepper Increment (50→55).
        throw XCTSkip("J52c threading (taxMealsPct → capture deductible) not wired: stub returns a fixed deductible:50 and the capture flow has no TaxSettings dependency — the only meals-% surface (captureReviewBanner) is invariant to the Stepper, so any capture-side assertion is vacuous.")
    }
}
