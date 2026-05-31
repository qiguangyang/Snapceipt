import Foundation

/// Stable accessibility identifiers shared by the app views and the XCUITest target.
/// (UI tests are a separate process and cannot @testable-import the app, so this file
/// is added to both targets' sources in project.yml.)
enum AccessibilityID {
    static let signInApple = "signin.apple"
    static let signInEmail = "signin.email"
    static let signInDev = "signin.dev"
    static let onboardingName = "onboarding.name"
    static let onboardingTypePersonal = "onboarding.type.personal"
    static let onboardingTypeBusiness = "onboarding.type.business"
    static let onboardingCreate = "onboarding.create"
    static let shellTabBar = "shell.tabbar"
    static let shellHome = "shell.home"
    static let profileSwitcher = "profile.switcher"
    static let tabHome = "tab.home"
    static let tabActivity = "tab.activity"
    static let tabReports = "tab.reports"
    static let tabProfile = "tab.profile"
    static let tabSnap = "tabbar.snap"
    static let addProfileName = "addprofile.name"
    static let captureClose = "capture.close"

    // Capture flow
    static let captureScanTitle = "capture.scan.title"
    static let captureReviewMerchant = "capture.review.merchant"
    static let captureReviewCategory = "capture.review.category"
    static let captureReviewBadge = "capture.review.badge"
    static let captureReviewProfileToggle = "capture.review.profileToggle"
    static let captureSave = "capture.save"
    static let captureSavedTitle = "capture.saved.title"
    static let captureSnapAnother = "capture.snapAnother"
    static let captureDone = "capture.done"

    // Home quick actions
    static let homeQuickMileage = "home.quick.mileage"
    static let homeQuickWFH = "home.quick.wfh"

    // Logbooks — shared
    static let logbookClose = "logbook.close"
    static let logbookAdd = "logbook.add"

    // Mileage
    static let mileageScreen = "mileage.screen"
    static let mileageAddVehicle = "mileage.addVehicle"
    static let mileageStartLogbook = "mileage.startLogbook"
    static let mileageEditCosts = "mileage.editCosts"
    static let mileageAddTrip = "mileage.addTrip"
    static let mileageClaim = "mileage.claim"
    static let vehicleSheetMake = "vehicle.sheet.make"
    static let vehicleSheetModel = "vehicle.sheet.model"
    static let vehicleSheetSave = "vehicle.sheet.save"
    static let logbookSheetStart = "logbook.sheet.start"
    static let logbookSheetSave = "logbook.sheet.save"
    static let tripSheetOdoStart = "trip.sheet.odoStart"
    static let tripSheetOdoEnd = "trip.sheet.odoEnd"
    static let tripSheetBusiness = "trip.sheet.business"
    static let tripSheetSave = "trip.sheet.save"
    static let costsSheetFuel = "costs.sheet.fuel"
    static let costsSheetSave = "costs.sheet.save"

    // WFH
    static let wfhScreen = "wfh.screen"
    static let wfhLogHours = "wfh.logHours"
    static let wfhClaim = "wfh.claim"
    static let wfhSheetHours = "wfh.sheet.hours"
    static let wfhSheetSave = "wfh.sheet.save"
}
