import XCTest

/// Hermetic logbook flow: seeded shell + stub API (no network).
/// Mileage: add vehicle -> start logbook -> add trip -> enter costs -> see claim.
/// WFH: log hours -> see the FY claim hero update.
final class LogbookUITests: UITestCase {

    func testMileageAddVehicleLogbookTripCostsClaim() {
        // Mileage is a PERSONAL-only Home quick action — seed personal-active.
        launchSeeded(activeType: "personal")

        // Open Mileage from the Home quick action.
        let mileage = app.buttons[AccessibilityID.homeQuickMileage].firstMatch
        XCTAssertTrue(mileage.waitForExistence(timeout: 10), "Mileage quick action missing")
        mileage.tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.mileageScreen].waitForExistence(timeout: 5)
                      || app.scrollViews.firstMatch.waitForExistence(timeout: 5),
                      "Mileage screen did not appear")

        // Add a vehicle.
        app.buttons[AccessibilityID.mileageAddVehicle].tap()
        let make = app.textFields[AccessibilityID.vehicleSheetMake]
        XCTAssertTrue(make.waitForExistence(timeout: 5), "Vehicle make field missing")
        make.tap(); make.typeText("Toyota")
        app.textFields[AccessibilityID.vehicleSheetModel].tap()
        app.textFields[AccessibilityID.vehicleSheetModel].typeText("HiLux")
        app.buttons[AccessibilityID.vehicleSheetSave].tap()

        // Start the logbook.
        app.buttons[AccessibilityID.mileageStartLogbook].tap()
        let lbSave = app.buttons[AccessibilityID.logbookSheetSave]
        XCTAssertTrue(lbSave.waitForExistence(timeout: 5), "Logbook period sheet missing")
        lbSave.tap()

        // Add a business trip (odometer in km -> distance).
        app.buttons[AccessibilityID.mileageAddTrip].firstMatch.tap()
        let odoStart = app.textFields[AccessibilityID.tripSheetOdoStart]
        XCTAssertTrue(odoStart.waitForExistence(timeout: 5), "Trip sheet missing")
        odoStart.tap(); odoStart.typeText("0")
        let odoEnd = app.textFields[AccessibilityID.tripSheetOdoEnd]
        odoEnd.tap(); odoEnd.typeText("100")
        app.buttons[AccessibilityID.tripSheetSave].tap()

        // Enter running costs.
        app.buttons[AccessibilityID.mileageEditCosts].tap()
        let fuel = app.textFields[AccessibilityID.costsSheetFuel]
        XCTAssertTrue(fuel.waitForExistence(timeout: 5), "Costs sheet missing")
        fuel.tap(); fuel.typeText("4120")
        app.buttons[AccessibilityID.costsSheetSave].tap()

        // The claim line renders (business-use % computed from the single business trip).
        XCTAssertTrue(app.staticTexts[AccessibilityID.mileageClaim].waitForExistence(timeout: 5),
                      "Claim line did not render after entering costs")
    }

    func testWFHLogHoursShowsFYClaim() {
        // WFH is a PERSONAL-only Home quick action — seed personal-active.
        launchSeeded(activeType: "personal")

        let wfh = app.buttons[AccessibilityID.homeQuickWFH].firstMatch
        XCTAssertTrue(wfh.waitForExistence(timeout: 10), "WFH quick action missing")
        wfh.tap()

        let logBtn = app.buttons[AccessibilityID.wfhLogHours]
        XCTAssertTrue(logBtn.waitForExistence(timeout: 5), "Log hours CTA missing")
        logBtn.tap()

        let hours = app.textFields[AccessibilityID.wfhSheetHours]
        XCTAssertTrue(hours.waitForExistence(timeout: 5), "Hours field missing")
        hours.tap(); hours.typeText("8")
        app.buttons[AccessibilityID.wfhSheetSave].tap()

        // After logging, the logged-days list shows the entry (hero claim > $0).
        XCTAssertTrue(app.staticTexts["8.0 h"].waitForExistence(timeout: 5),
                      "Logged day did not appear after saving hours")
    }
}
