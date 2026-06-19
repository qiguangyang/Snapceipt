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

    /// The right-aligned "hide keyboard" button in the keyboard accessory bar
    /// (shared via `.keyboardDismissButton()` on every input-bearing screen).
    static let keyboardDismiss = "keyboard.dismiss"
    static let profileSwitcher = "profile.switcher"
    static let tabHome = "tab.home"
    static let tabActivity = "tab.activity"
    static let tabReports = "tab.reports"
    static let tabProfile = "tab.profile"
    static let tabSnap = "tabbar.snap"
    static let addProfileName = "addprofile.name"
    static let addProfileCreate = "addprofile.create"

    // Capture flow
    static let captureClose = "capture.close"
    static let captureScanTitle = "capture.scan.title"
    static let captureReviewMerchant = "capture.review.merchant"
    static let captureReviewCategory = "capture.review.category"
    static let captureReviewBadge = "capture.review.badge"
    static let captureReviewBanner = "capture.review.banner"
    /// The smart-scan-cap upgrade nudge banner (shown only for free users when capped).
    static let captureReviewUpgradeNudge = "capture.review.upgradeNudge"
    /// The "Upgrade" button inside the smart-scan-cap nudge banner.
    static let captureReviewUpgrade = "capture.review.upgrade"
    static let captureReviewProfileToggle = "capture.review.profileToggle"
    static let captureReviewDiagnostics = "capture.review.diagnostics"
    static let captureReviewTotal = "capture.review.total"
    /// Editable Review line-item rows (suffixed with the row index).
    static let captureReviewItemNamePrefix = "capture.review.item.name."
    static let captureReviewItemPricePrefix = "capture.review.item.price."
    static let captureReviewItemRemovePrefix = "capture.review.item.remove."
    static let captureReviewItemsAdd = "capture.review.items.add"
    static let captureSave = "capture.save"
    static let captureSaveError = "capture.save.error"   // surfaced save failure (e.g. no profile)
    static let captureSavedTitle = "capture.saved.title"
    /// Shown on the Saved confirmation only when the receipt was captured offline
    /// (HeuristicParser fallback → outbox queue, extractionStatus=="pending"). Drives J18b/J18c.
    static let captureQueuedBadge = "capture.queued.badge"
    static let captureSnapAnother = "capture.snapAnother"
    static let captureDone = "capture.done"
    static let captureImport = "capture.import"
    static let captureImportPhotos = "capture.import.photos"
    static let captureImportFiles = "capture.import.files"

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

    // Sync status pill (J23b/J23c). Always present in the shell; its a11y VALUE
    // reflects the SyncEngine state (idle/syncing/offline/error) even when the
    // pill is visually hidden (idle), so XCUITest can poll the drain.
    static let syncStatusPill = "sync.status.pill"

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
    static let budgetEditorDuplicateWarning = "budget.editor.duplicateWarning"

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
    static let loyaltyAddFormat = "loyalty.add.format"
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
    static let quoteEditorGstInclusive = "quote.editor.gstInclusive"
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

    // Settings hub (F7)
    static let profileHubScreen = "profile.hub.screen"
    static let profileRowTax = "profile.row.tax"
    static let profileRowCategories = "profile.row.categories"
    static let profileRowPrivacy = "profile.row.privacy"
    static let profileRowAccount = "profile.row.account"
    static let profileSwitcherCardPrefix = "profile.switcher.card."  // + profile.id
    static let profileAddButton = "profile.add"
    static let signOutButton = "profile.signout"
    static let profileAiAutoCategorise = "profile.row.aiAutoCategorise"  // inert visual toggle
    static let profileSmartScanToggle = "profile.row.smartScan"
    static let profileRowConnectedBanks = "profile.row.connectedBanks"   // Coming-soon placeholder
    static let profileRowHelp = "profile.row.help"                       // opens external URL
    static let profileRowLegal = "profile.row.legal"                    // opens external Terms URL
    // Tax & GST
    static let taxScreen = "tax.screen"
    static let taxGstToggle = "tax.gst.toggle"
    static let taxAbnField = "tax.abn.field"
    static let taxFyStart = "tax.fy.start"
    static let taxMealsPct = "tax.meals.pct"
    // Categories & rules
    static let categoriesScreen = "categories.screen"
    static let categoryRowPrefix = "category.row."     // + category.id
    static let ruleRowPrefix = "rule.row."             // + rule.id
    static let ruleAddButton = "rule.add"
    static let ruleEditorScreen = "rule.editor.screen"
    static let ruleEditorSave = "rule.editor.save"
    // Profile detail
    static let profileDetailScreen = "profile.detail.screen"
    static let profileDetailSwitch = "profile.detail.switch"
    static let profileDetailDelete = "profile.detail.delete"
    static let profileDetailNameField = "profile.detail.name"

    // Account & privacy (F7)
    static let accountScreen = "account.screen"
    static let accountEmailRow = "account.email.row"
    static let accountChangeEmail = "account.change.email"
    static let accountDeviceRowPrefix = "account.device.row."   // + device.id
    static let accountRevokePrefix = "account.revoke."          // + device.id
    static let accountDeleteButton = "account.delete"
    static let accountDeleteConfirmField = "account.delete.confirm.field"
    static let accountDeleteConfirmButton = "account.delete.confirm.button"
    static let changeEmailScreen = "changeemail.screen"
    static let changeEmailField = "changeemail.field"
    static let changeEmailSend = "changeemail.send"
    static let changeEmailCodeField = "changeemail.code.field"
    static let changeEmailVerify = "changeemail.verify"
    static let privacyScreen = "privacy.screen"
    static let privacyAppLockToggle = "privacy.applock.toggle"
    static let appLockUnlock = "applock.unlock"

    // BAS (F8)
    static let reportsBasCard = "reports.bas.card"
    static let basScreen = "bas.screen"
    static let basPeriodStepper = "bas.period.stepper"
    static let basPeriodPrev = "bas.period.prev"
    static let basPeriodNext = "bas.period.next"
    static let basCopyG1 = "bas.copy.g1"
    static let basCopy1A = "bas.copy.1a"
    static let basCopy1B = "bas.copy.1b"
    static let basReconcileRowPrefix = "bas.reconcile.row."          // + transaction.id / "income"/"estimated"/"printed"
    static let basConfirmIncome = "bas.reconcile.confirmIncome"      // confirm-all-income quick-fix
    static let basPaygField = "bas.payg.field"
    static let basFullWorksheetToggle = "bas.fullWorksheet.toggle"
    static let basMarkLodged = "bas.markLodged"
    static let basExport = "bas.export"
    static let basHistoryLink = "bas.history.link"
    static let basHistoryScreen = "bas.history.screen"
    static let basHistoryRowPrefix = "bas.history.row."   // + periodKey
    // Paywall (Workstream 6)
    static let paywallTitle      = "paywall.title"
    static let paywallBuyMonthly = "paywall.buy.monthly"
    static let paywallBuyYearly  = "paywall.buy.yearly"
    static let paywallRestore    = "paywall.restore"
    static let paywallLoading    = "paywall.loading"     // spinner while products load
    static let paywallLoadError  = "paywall.loadError"   // empty/failed load message
    static let paywallRetry      = "paywall.retry"       // re-run loadProducts()
    static let paywallSubscribe  = "paywall.subscribe"   // CTA buying the selected plan
    // Activity tab (receipts list)
    static let activityScreen    = "activity.screen"
    static let activityRowPrefix = "activity.row."       // + transaction.id
    static let activityEmpty     = "activity.empty"
    static let homeRecentSection = "home.recent.section"
    static let homeRecentSeeAll  = "home.recent.seeAll"
    static let homeSnapCTA       = "home.snap.cta"
    static let homeSummary       = "home.summary"
    static let homeQuickManual   = "home.quick.manual"
    static let homeQuickReports  = "home.quick.reports"
    static let homeQuickReceipts = "home.quick.receipts"
    static let receiptDetailScreen = "receipt.detail.screen"
    static let receiptDetailClose  = "receipt.detail.close"
    static let receiptDetailEdit   = "receipt.detail.edit"
    static let receiptDetailDelete = "receipt.detail.delete"
    // Activity filters / search (design parity)
    static let activitySearch    = "activity.search"
    static let activityFilterAll = "activity.filter.all"
    static let activityFilterExpenses = "activity.filter.expenses"
    static let activityFilterIncome   = "activity.filter.income"
    static let activityMonthPicker = "activity.monthPicker"
    // Manual entry (design parity)
    static let manualScreen      = "manual.screen"
    static let manualMerchant    = "manual.merchant"
    static let manualAmount      = "manual.amount"
    static let manualGstField    = "manual.gst"
    static let manualSave        = "manual.save"
    // Manual entry — receipt-style line items
    static let manualItemsAdd      = "manual.items.add"
    static let manualItemsUseTotal = "manual.items.useTotal"
    static let manualItemNamePrefix   = "manual.item.name."   // + row index
    static let manualItemPricePrefix  = "manual.item.price."  // + row index
    static let manualItemRemovePrefix = "manual.item.remove." // + row index
    // Transaction editor GST fields (F8)
    static let txnGstFreeToggle = "txn.gstFree.toggle"
    static let txnCapitalToggle = "txn.capital.toggle"
    static let txnGstAmountField = "txn.gstAmount.field"
    // Tax & GST ABN hint (F8)
    static let taxAbnHint = "tax.abn.hint"

    // Invoices & A/R
    static let homeQuickInvoices = "home.quick.invoices"
    static let invoicesScreen = "invoices.screen"
    static let invoiceRowPrefix = "invoice.row."          // + invoice.id
    static let invoicesAdd = "invoices.add"
    static let invoiceNeedsAttentionSection = "invoices.needsAttention"
    static let invoiceEditorScreen = "invoice.editor.screen"
    static let invoiceEditorClient = "invoice.editor.client"
    static let invoiceEditorAddLine = "invoice.editor.addLine"
    static let invoiceLineRowPrefix = "invoice.line.row."  // + line.id
    static let invoiceEditorGst = "invoice.editor.gst"
    static let invoiceEditorGstInclusive = "invoice.editor.gstInclusive"
    static let invoiceEditorDueDate = "invoice.editor.dueDate"
    static let invoiceEditorIssue = "invoice.editor.issue"
    static let invoiceEditorSend = "invoice.editor.send"
    static let invoiceEditorPdf = "invoice.editor.pdf"
    static let invoiceEditorRecordPayment = "invoice.editor.recordPayment"
    static let invoiceEditorConvertFromQuote = "invoice.editor.fromQuote"
    static let recordPaymentSheet = "recordPayment.sheet"
    static let recordPaymentAmount = "recordPayment.amount"
    static let recordPaymentSave = "recordPayment.save"
    // Quote editor — new PDF + convert affordances
    static let quoteEditorGeneratePdf = "quote.editor.generatePdf"
    static let quoteEditorConvert = "quote.editor.convert"
}
