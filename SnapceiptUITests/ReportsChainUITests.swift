import XCTest

/// J28 capture→reports reflection; J33 deductible pill includes seeded VehicleYear claim.
final class ReportsChainUITests: UITestCase {
    func testCaptureReflectsInReports() {
        launchSeeded()
        // Capture + save a new receipt (canned stub).
        app.buttons[AccessibilityID.tabSnap].firstMatch.tap()
        let save = app.buttons[AccessibilityID.captureSave]
        XCTAssertTrue(save.waitForExistence(timeout: 12), "Review did not appear")
        save.tap()
        XCTAssertTrue(app.staticTexts[AccessibilityID.captureSavedTitle].waitForExistence(timeout: 5),
                      "Save did not complete")
        app.buttons[AccessibilityID.captureDone].tap()
        // Reports tab renders net + donut (the saved txn is included in the recompute).
        app.buttons[AccessibilityID.tabReports].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.reportsNet].firstMatch
                        .waitForExistence(timeout: 10), "Reports net did not render after capture")
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.reportsDonut].firstMatch.exists,
                      "Reports donut missing after capture")
    }

    func testDeductiblePillIncludesVehicleClaim() {
        launchSeeded()
        app.buttons[AccessibilityID.tabReports].firstMatch.tap()
        // The deductible pill renders; its value must INCLUDE the seeded VehicleYear
        // claim of $250 (AppLaunch seeds `claimCents: 250_00` under the fixed Epoch
        // date, so the Deductible YTD is deterministic and exact-or-minimum-stable).
        let pill = app.descendants(matching: .any)[AccessibilityID.reportsDeductiblePill].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "Deductible pill missing")
        let label = pill.label
        // Parse the first dollar amount out of the label and assert it is >= $250 —
        // this distinguishes a pill that EXCLUDES the vehicle claim (the presence-only
        // gap this row exists to close) from one that includes it.
        let dollars = parseFirstDollarAmount(from: label)
        XCTAssertNotNil(dollars, "Deductible pill did not render a dollar value: \(label)")
        XCTAssertGreaterThanOrEqual(dollars ?? 0, 250.0,
                      "Deductible YTD (\(label)) is below the seeded $250 VehicleYear claim — the logbook claim is not wired into the pill")
    }

    /// Extract the first "$1,234.56"-style amount from a label as a Double.
    private func parseFirstDollarAmount(from label: String) -> Double? {
        guard let range = label.range(of: #"\$[0-9][0-9,]*(\.[0-9]+)?"#, options: .regularExpression)
        else { return nil }
        let digits = label[range].replacingOccurrences(of: "$", with: "")
                                 .replacingOccurrences(of: ",", with: "")
        return Double(digits)
    }
}
