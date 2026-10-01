import XCTest

final class ClientsJourneyUITests: UITestCase {
    private let acme = "01990000-0000-7000-8000-000000000103"
    private let paid = "01990000-0000-7000-8000-000000000106"
    private let legacy = "01990000-0000-7000-8000-000000000110"
    private func reach(_ element: XCUIElement) {
        for _ in 0..<12 { if element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    private func openClients() {
        let entry = app.buttons[AccessibilityID.homeClients]; XCTAssertTrue(entry.waitForExistence(timeout: 10)); reach(entry); entry.tap()
        XCTAssertTrue(app.navigationBars["Clients"].waitForExistence(timeout: 5))
    }
    private func launchWorkspace() { app.launchArguments += ["-uiTestClientWorkspace", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]; launchSeeded(pro: true); openClients() }
    private func openAcme() { app.buttons[AccessibilityID.clientWorkspaceRowPrefix + acme].tap() }
    private func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }

    func testAddNotesSavedItemQuoteRepeatAndReminder() {
        launchWorkspace()
        app.buttons[AccessibilityID.clientsAdd].tap()
        let name = app.textFields[AccessibilityID.clientFieldPrefix + "Client name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Journey Client"); dismissKeyboard()
        let notes = app.descendants(matching: .any)[AccessibilityID.clientFieldPrefix + "Notes (optional)"].firstMatch
        reach(notes); notes.tap(); notes.typeText("Private site access notes"); dismissKeyboard()
        let save = app.buttons["Save client"]; reach(save); save.tap()
        XCTAssertTrue(app.navigationBars["Journey Client"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Private site access notes"].exists)
        let quote = app.buttons[AccessibilityID.clientNewQuote]; reach(quote); quote.tap()
        let saved = app.buttons["Saved items"]; XCTAssertTrue(saved.waitForExistence(timeout: 5)); reach(saved); saved.tap()
        let mismatch = app.buttons.containing(.staticText, identifier: "NZD consulting").firstMatch
        XCTAssertTrue(mismatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "NZD 125.00")).firstMatch.exists)
        mismatch.tap()
        let explanation = app.staticTexts["This saved item is priced in NZD, but this document uses AUD. Add a manual item with a price in AUD."]
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Saved items"].exists)
        shot("saved-item-currency-mismatch-explanation")
        let item = app.buttons.containing(.staticText, identifier: "Journey consulting").firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", "Journey consulting")).firstMatch.waitForExistence(timeout: 5))
        app.buttons[AccessibilityID.quoteSaveDraft].tap()
        XCTAssertTrue(app.navigationBars["Journey Client"].waitForExistence(timeout: 5))
        let repeatQuote = app.buttons["Create quote draft again"].firstMatch; reach(repeatQuote); repeatQuote.tap()
        XCTAssertTrue(app.staticTexts[AccessibilityID.clientRepeatReview].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[AccessibilityID.clientRepeatReview].isHittable)
        shot("new-quote-saved-item-repeat-review")
        app.buttons[AccessibilityID.quoteSaveDraft].tap()
        XCTAssertTrue(app.navigationBars["Journey Client"].waitForExistence(timeout: 5))
        let reminder = app.buttons[AccessibilityID.clientSetReminder]; reach(reminder); reminder.tap()
        let title = app.textFields[AccessibilityID.followUpTitle]; XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("Journey follow-up"); dismissKeyboard()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "In-app only")).firstMatch.exists)
        app.buttons[AccessibilityID.followUpSave].tap()
        XCTAssertTrue(app.navigationBars["Journey Client"].waitForExistence(timeout: 5))
        let complete = app.buttons["Mark complete"].firstMatch; reach(complete); complete.tap()
        app.buttons["Completed follow-ups"].tap()
        XCTAssertTrue(app.buttons["Journey follow-up"].exists)
        XCTAssertTrue(app.buttons["Reopen"].exists)
        shot("new-client-quote-reminder-completed")
    }

    func testPaidInvoiceRepeatAndTwoBusinessProfiles() {
        launchWorkspace(); openAcme()
        let repeatInvoice = app.buttons[AccessibilityID.clientCreateAgainPrefix + paid]; reach(repeatInvoice)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Paid")).firstMatch.exists)
        let repeatStarted = Date()
        repeatInvoice.tap()
        XCTAssertTrue(app.staticTexts[AccessibilityID.clientRepeatReview].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[AccessibilityID.invoiceEditorRecordPayment].exists)
        XCTAssertTrue(app.buttons[AccessibilityID.invoiceEditorSaveDraft].exists)
        let due = app.datePickers[AccessibilityID.invoiceEditorDueDate]; reach(due)
        // Compact DatePicker's container value is empty on iOS26. Read its visible
        // date child instead, asserting the fresh 14-day default in known en_AU locale.
        // One-day tolerance covers local/UTC midnight boundaries, never the old 2020 date.
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_AU")
        formatter.timeZone = .current
        let expected = (13...15).flatMap { days -> [String] in
            let date = utc.date(byAdding: .day, value: days, to: utc.startOfDay(for: repeatStarted))!
            return ["d MMM yyyy", "d MMMM yyyy"].map { format in
                formatter.dateFormat = format; return formatter.string(from: date)
            }
        }
        let matches = NSCompoundPredicate(orPredicateWithSubpredicates: expected.map {
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", $0, $0)
        })
        let displayedDate = due.descendants(matching: .any).matching(matches).firstMatch
        XCTAssertTrue(displayedDate.waitForExistence(timeout: 5), due.debugDescription)
        XCTAssertTrue(displayedDate.isHittable, due.debugDescription)
        let dateEvidence = XCTAttachment(string: due.debugDescription)
        dateEvidence.name = "repeat-invoice-visible-date-accessibility"; dateEvidence.lifetime = .keepAlways; add(dateEvidence)
        shot("paid-invoice-repeat-reset-date")
        app.buttons[AccessibilityID.invoiceEditorSaveDraft].tap()
        XCTAssertTrue(app.navigationBars["Acme Pty Ltd"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Clients"].tap(); app.buttons[AccessibilityID.clientsClose].tap()
        app.buttons[AccessibilityID.profileSwitcher].tap()
        let other = app.buttons.containing(.staticText, identifier: "Journey South").firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 5)); other.tap(); openClients()
        XCTAssertFalse(app.buttons[AccessibilityID.clientWorkspaceRowPrefix + acme].exists)
        let southern = app.buttons[AccessibilityID.clientWorkspaceRowPrefix + "01990000-0000-7000-8000-000000000113"]
        XCTAssertTrue(southern.exists); southern.tap()
        XCTAssertTrue(app.staticTexts["South confidential notes"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Discuss access, materials")).firstMatch.exists)
        XCTAssertFalse(app.buttons[AccessibilityID.clientCreateAgainPrefix + paid].exists)
        let southReminder = app.buttons["South reminder"]; reach(southReminder)
        XCTAssertFalse(app.buttons["DST gap inspection"].exists)
        shot("second-business-isolated-workspace")
        app.navigationBars.buttons["Clients"].tap()
        app.buttons[AccessibilityID.clientsSavedItems].tap()
        XCTAssertTrue(app.staticTexts["South saved item"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Journey consulting"].exists)
    }

    func testLegacyAssociationRequiresConfirmationAndPreservesContact() {
        launchWorkspace(); openAcme()
        let link = app.buttons[AccessibilityID.clientLinkDocuments]; reach(link); link.tap()
        let candidate = app.buttons.containing(.staticText, identifier: "Quote Q-LEGACY").firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5)); candidate.tap()
        // Selecting a candidate alone must never associate it.
        app.buttons[AccessibilityID.logbookClose].tap()
        XCTAssertFalse(app.buttons[AccessibilityID.clientDocumentRowPrefix + legacy].exists)
        reach(link); link.tap(); candidate.tap(); app.buttons["Link selected documents (1)"].tap()
        XCTAssertTrue(app.buttons["Confirm association"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[AccessibilityID.clientDocumentRowPrefix + legacy].exists)
        app.buttons["Confirm association"].tap()
        XCTAssertTrue(app.navigationBars["Acme Pty Ltd"].waitForExistence(timeout: 5))
        let row = app.buttons[AccessibilityID.clientDocumentRowPrefix + legacy]; reach(row); row.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.quoteEditorScreen].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Legacy snapshot contact"].exists)
        XCTAssertTrue(app.staticTexts["legacy@example.test"].exists)
        shot("confirmed-legacy-original-contact")
    }
}
