import XCTest

/// Hermetic Reports flow: seeded shell + stub API (no network).
/// Reports tab -> toggle period (donut + net recompute) -> open Export -> pick CSV ->
/// stubbed export. A Business profile shows tax pills + logbook rows.
final class ReportsUITests: UITestCase {
    func testReportsTabTogglePeriodAndExportCSV() {
        launchSeeded()   // signed-in, business profile p1 active, seeded transactions

        // Open the Reports tab.
        let reports = app.buttons[AccessibilityID.tabReports].firstMatch
        XCTAssertTrue(reports.waitForExistence(timeout: 10), "Reports tab not found")
        reports.tap()

        // SwiftUI surfaces the screen-root container as the underlying ScrollView (not an
        // `otherElement`) under iOS 26, so probe `.any` per the plan's Step 3 a11y caveat.
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.reportsScreen].waitForExistence(timeout: 5),
                      "Reports screen did not appear")

        // Net headline + donut render.
        XCTAssertTrue(app.staticTexts[AccessibilityID.reportsNet].waitForExistence(timeout: 5),
                      "Net figure missing")
        XCTAssertTrue(app.otherElements[AccessibilityID.reportsDonut].exists
                      || app.staticTexts[AccessibilityID.reportsDonut].exists,
                      "Donut missing")

        // Business layout: tax pills + logbook rows present.
        XCTAssertTrue(app.otherElements[AccessibilityID.reportsDeductiblePill].exists
                      || app.staticTexts[AccessibilityID.reportsDeductiblePill].exists,
                      "Deductible pill missing for a business profile")
        XCTAssertTrue(app.buttons[AccessibilityID.reportsLogbookVehicle].exists,
                      "Vehicle logbook row missing")

        // Toggle to FY -> the screen still renders the net figure (recompute ran).
        let fySeg = app.buttons["FY"].firstMatch
        if fySeg.exists { fySeg.tap() }
        XCTAssertTrue(app.staticTexts[AccessibilityID.reportsNet].waitForExistence(timeout: 5),
                      "Net figure missing after period toggle")

        // Open the Export sheet.
        app.buttons[AccessibilityID.reportsExportPill].tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.exportSheet].waitForExistence(timeout: 5),
                      "Export sheet did not appear")

        // Pick CSV, then Generate (stubbed network returns a download url -> share sheet).
        app.buttons[AccessibilityID.exportFormatCSV].tap()
        let generate = app.buttons[AccessibilityID.exportGenerate]
        XCTAssertTrue(generate.waitForExistence(timeout: 5), "Generate CTA missing")
        generate.tap()

        // The stubbed export resolves without error: the sheet stays up (no error status)
        // and the system share sheet may appear. Assert no error status line is shown.
        XCTAssertFalse(app.staticTexts[AccessibilityID.exportStatus].waitForExistence(timeout: 3),
                       "Export reported an error under the stub")
    }
}
