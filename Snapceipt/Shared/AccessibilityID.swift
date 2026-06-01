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

    // Reports
    static let reportsScreen = "reports.screen"
    static let reportsExportPill = "reports.exportPill"
    static let reportsPeriod = "reports.period"
    static let reportsNet = "reports.net"
    static let reportsDonut = "reports.donut"
    static let reportsDeductiblePill = "reports.pill.deductible"
    static let reportsGstPill = "reports.pill.gst"
    static let reportsLogbookVehicle = "reports.logbook.vehicle"
    static let reportsLogbookWFH = "reports.logbook.wfh"
    static let reportsInsight = "reports.insight"
    static let reportsUnderBudget = "reports.underBudget"

    // Export sheet
    static let exportSheet = "export.sheet"
    static let exportFormatPDF = "export.format.pdf"
    static let exportFormatCSV = "export.format.csv"
    static let exportFormatAccountant = "export.format.accountant"
    static let exportEmailField = "export.emailField"
    static let exportGenerate = "export.generate"
    static let exportStatus = "export.status"

    // Budgets (F3)
    static let homeBudgetTracker = "home.budgetTracker"
    static let homeBudgetEditLink = "home.budget.edit"
    static let homeBudgetEmptyCTA = "home.budget.emptyCTA"
    static let homeAlertsBell = "home.alerts.bell"
    static let budgetRowPrefix = "budget.row."          // + budget.id
    static let budgetListScreen = "budget.list.screen"
    static let budgetListAdd = "budget.list.add"
    static let budgetEditorScreen = "budget.editor.screen"
    static let budgetEditorScopeProfile = "budget.editor.scope.profile"
    static let budgetEditorScopeCategory = "budget.editor.scope.category"
    static let budgetEditorCap = "budget.editor.cap"
    static let budgetEditorThreshold = "budget.editor.threshold"
    static let budgetEditorSave = "budget.editor.save"
    static let budgetEditorDelete = "budget.editor.delete"

    // Alerts (F3)
    static let alertsScreen = "alerts.screen"
    static let alertRowPrefix = "alert.row."            // + item.id

    // Notifications settings (F3)
    static let notifSettingsScreen = "notif.settings.screen"
    static let notifPushToggle = "notif.push.toggle"
    static let notifQuietStart = "notif.quiet.start"
    static let notifQuietEnd = "notif.quiet.end"
    static let notifBasToggle = "notif.bas.toggle"

    // Profile tab (F3 entry rows)
    static let profileRowNotifications = "profile.row.notifications"
    static let profileRowBudgets = "profile.row.budgets"

    // Home quick action (F4)
    static let homeQuickLoyalty = "home.quick.loyalty"

    // Loyalty (F4)
    static let loyaltyWalletScreen = "loyalty.wallet.screen"
    static let loyaltyCardRowPrefix = "loyalty.card.row."     // + card.id
    static let loyaltyWalletAdd = "loyalty.wallet.add"
    static let loyaltyAddScreen = "loyalty.add.screen"
    static let loyaltyAddScan = "loyalty.add.scan"
    static let loyaltyAddBrandPrefix = "loyalty.add.brand."   // + brand.key
    static let loyaltyAddNumber = "loyalty.add.number"
    static let loyaltyAddSave = "loyalty.add.save"
    static let loyaltyDetailScreen = "loyalty.detail.screen"
    static let loyaltyDetailBarcode = "loyalty.detail.barcode"
    static let loyaltyDetailDone = "loyalty.detail.done"

    // Home quick action (F5)
    static let homeQuickQuote = "home.quick.quote"

    // Quotes (F5)
    static let quotesScreen = "quotes.screen"
    static let quoteRowPrefix = "quote.row."             // + quote.id
    static let quotesAdd = "quotes.add"
    static let quoteEditorScreen = "quote.editor.screen"
    static let quoteEditorClient = "quote.editor.client"
    static let quoteEditorAddLine = "quote.editor.addLine"
    static let quoteLineRowPrefix = "quote.line.row."    // + line.id
    static let quoteEditorGst = "quote.editor.gst"
    static let quoteEditorSend = "quote.editor.send"
    static let clientPickerScreen = "client.picker.screen"
    static let clientPickerAdd = "client.picker.add"
    static let clientRowPrefix = "client.row."           // + client.id

    // Email-in
    static let profileRowEmailIn = "profile.row.emailin"
    static let emailInScreen = "emailin.screen"
    static let emailInAddress = "emailin.address"
    static let emailInCopy = "emailin.copy"
    static let emailInRotate = "emailin.rotate"
    static let emailInError = "emailin.error"
    static let emailInRetry = "emailin.retry"
    static let emailInListRowPrefix = "emailin.row."     // + transaction.id
    static let emailInReviewScreen = "emailin.review.screen"
    static let emailInReviewMerchant = "emailin.review.merchant"
    static let emailInReviewAmount = "emailin.review.amount"
    static let emailInReviewSave = "emailin.review.save"
}
