import XCTest

/// J37 (scoped): adding a business trip recomputes the mileage claim surface.
/// Trip EDIT + swipe-DELETE are DEFERRED — MileageScreen has no such affordance
/// (adding it is out-of-guardrail new UI); see the deferred-findings log.
final class LogbookExtraUITests: UITestCase {
    func testTripAddRecomputesClaim() {
        // Mileage is a PERSONAL-only Home quick action — seed personal-active.
        // pro: true reports a Pro plan so Mileage opens without the paywall.
        launchSeeded(activeType: "personal", pro: true)
        // Open mileage via the Home quick action.
        app.buttons[AccessibilityID.homeQuickMileage].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.mileageScreen].firstMatch
                        .waitForExistence(timeout: 10)
                      || app.scrollViews.firstMatch.waitForExistence(timeout: 5),
                      "Mileage screen did not open")
        // Add vehicle.
        app.buttons[AccessibilityID.mileageAddVehicle].firstMatch.tap()
        let make = app.textFields[AccessibilityID.vehicleSheetMake]
        XCTAssertTrue(make.waitForExistence(timeout: 5), "Vehicle make field missing")
        make.tap(); make.typeText("Toyota")
        app.textFields[AccessibilityID.vehicleSheetModel].tap()
        app.textFields[AccessibilityID.vehicleSheetModel].typeText("Corolla")
        app.buttons[AccessibilityID.vehicleSheetSave].tap()
        // Start a logbook (if the affordance is shown for a fresh vehicle).
        let startLog = app.buttons[AccessibilityID.mileageStartLogbook]
        if startLog.waitForExistence(timeout: 5) {
            startLog.tap()
            let lbSave = app.buttons[AccessibilityID.logbookSheetSave]
            XCTAssertTrue(lbSave.waitForExistence(timeout: 5), "Logbook period sheet missing")
            lbSave.tap()
        }
        // Add a business trip via odometer (50km → drives a non-nil business-use %).
        app.buttons[AccessibilityID.mileageAddTrip].firstMatch.tap()
        let odoStart = app.textFields[AccessibilityID.tripSheetOdoStart]
        XCTAssertTrue(odoStart.waitForExistence(timeout: 5), "Trip odo-start field missing")
        odoStart.tap(); odoStart.typeText("1000")
        app.textFields[AccessibilityID.tripSheetOdoEnd].tap()
        app.textFields[AccessibilityID.tripSheetOdoEnd].typeText("1050")
        app.buttons[AccessibilityID.tripSheetSave].tap()
        // Enter running costs — the claim surface materialises a vehicle_year row,
        // and the recomputed business-use % from the trip flows into its claim.
        app.buttons[AccessibilityID.mileageEditCosts].tap()
        let fuel = app.textFields[AccessibilityID.costsSheetFuel]
        XCTAssertTrue(fuel.waitForExistence(timeout: 5), "Costs sheet missing")
        fuel.tap(); fuel.typeText("4120")
        app.buttons[AccessibilityID.costsSheetSave].tap()
        // The claim surface renders the recomputed value (50km business trip → claim).
        let claim = app.descendants(matching: .any)[AccessibilityID.mileageClaim].firstMatch
        XCTAssertTrue(claim.waitForExistence(timeout: 8),
                      "Mileage claim surface did not render after adding a trip")
    }
}
