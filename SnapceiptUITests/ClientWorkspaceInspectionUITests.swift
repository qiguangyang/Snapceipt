import XCTest

/// Task9's reachable visual/interaction gate; broad repeat-work journeys belong to Task10.
final class ClientWorkspaceInspectionUITests: UITestCase {
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func openClients() {
        let button = app.buttons[AccessibilityID.homeClients].firstMatch
        if !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.waitForExistence(timeout: 10)); button.tap()
        XCTAssertTrue(app.navigationBars["Clients"].waitForExistence(timeout: 5))
    }
    private func openAcme() {
        let client = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.clientWorkspaceRowPrefix)).firstMatch
        XCTAssertTrue(client.waitForExistence(timeout: 5)); client.tap()
        XCTAssertTrue(app.buttons[AccessibilityID.clientEdit].waitForExistence(timeout: 5))
    }
    func testEmptyAndCloseAndPersonalEntry() {
        launchTourEmpty(); openClients()
        XCTAssertTrue(app.staticTexts["No clients yet. Add your first client."].exists)
        shot("clients-empty")
        app.buttons[AccessibilityID.clientsClose].tap()
        XCTAssertTrue(app.buttons[AccessibilityID.homeClients].exists)
        app.terminate()
        app.launchArguments = ["-uiTestSkipPermissions"]
        launchSeeded(activeType: "personal")
        XCTAssertTrue(app.buttons[AccessibilityID.homeAlertsBell].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[AccessibilityID.homeClients].exists)
        shot("personal-home")
    }
    func testCompletingFollowUpDoesNotDeleteOrOpenEditor() {
        app.launchArguments += ["-uiTestClientWorkspace"]
        launchSeeded(pro: true); openClients(); openAcme()
        let complete = app.buttons["Mark complete"].firstMatch
        for _ in 0..<10 { if complete.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(complete.exists); complete.tap()
        XCTAssertFalse(app.textFields[AccessibilityID.followUpTitle].exists)
        app.buttons["Completed follow-ups"].firstMatch.tap()
        XCTAssertTrue(app.buttons["DST gap inspection"].exists)
        shot("follow-up-completed-still-present")
    }
    func testRepeatEditorReviewBannerAndInvoiceSaveReturn() {
        app.launchArguments += ["-uiTestClientWorkspace"]
        launchSeeded(pro: true); openClients(); openAcme()
        let repeatInvoice = app.buttons["Create invoice INV-REPEAT again"].firstMatch
        for _ in 0..<10 { if repeatInvoice.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(repeatInvoice.exists); repeatInvoice.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.invoiceEditorScreen].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[AccessibilityID.clientRepeatReview].isHittable)
        shot("repeat-invoice-long-description-review")
        app.buttons[AccessibilityID.invoiceEditorSaveDraft].tap()
        XCTAssertTrue(app.navigationBars["Acme Pty Ltd"].waitForExistence(timeout: 5))
        let repeatQuote = app.buttons["Create quote draft again"].firstMatch
        for _ in 0..<8 { if repeatQuote.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(repeatQuote.exists); repeatQuote.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.quoteEditorScreen].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[AccessibilityID.clientRepeatReview].isHittable)
        shot("repeat-quote-long-description-review")
        app.buttons[AccessibilityID.logbookClose].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Acme Pty Ltd"].waitForExistence(timeout: 5))
    }
    func testLargeTextClientDetailAndActions() {
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        launchSeeded(pro: true); openClients(); shot("clients-large-text-list"); openAcme()
        shot("client-large-text-detail")
        for _ in 0..<8 { if app.buttons[AccessibilityID.clientSetReminder].isHittable { break }; app.swipeUp() }
        shot("client-large-text-actions")
        XCTAssertTrue(app.buttons[AccessibilityID.clientNewQuote].exists)
        XCTAssertTrue(app.buttons[AccessibilityID.clientNewInvoice].exists)
        app.buttons[AccessibilityID.clientSetReminder].tap()
        XCTAssertTrue(app.textFields[AccessibilityID.followUpTitle].waitForExistence(timeout: 5))
        shot("follow-up-large-text")
        XCTAssertEqual(app.buttons[AccessibilityID.logbookClose].firstMatch.label, "Close")
        app.buttons[AccessibilityID.logbookClose].firstMatch.tap()
    }
    func testLongNotesReminderDSTAndBack() {
        app.launchArguments += ["-uiTestClientWorkspace"]
        launchSeeded(pro: true); openClients(); openAcme()
        shot("client-long-notes")
        app.buttons[AccessibilityID.clientEdit].tap()
        let notes = app.descendants(matching: .any)[AccessibilityID.clientFieldPrefix + "Notes (optional)"].firstMatch
        app.swipeUp()
        XCTAssertTrue(notes.waitForExistence(timeout: 5)); notes.tap()
        XCTAssertTrue(app.buttons[AccessibilityID.keyboardDismiss].waitForExistence(timeout: 3))
        dismissKeyboard(); shot("client-notes-keyboard-dismissed")
        XCTAssertEqual(app.buttons[AccessibilityID.logbookClose].firstMatch.label, "Close")
        app.buttons[AccessibilityID.logbookClose].firstMatch.tap()
        XCTAssertTrue(app.buttons[AccessibilityID.clientEdit].waitForExistence(timeout: 5))
        let gap = app.buttons["DST gap inspection"].firstMatch
        for _ in 0..<10 { if gap.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(gap.waitForExistence(timeout: 5)); gap.tap()
        let timezone = app.textFields[AccessibilityID.followUpTimezone]
        XCTAssertTrue(timezone.waitForExistence(timeout: 5)); XCTAssertEqual(timezone.value as? String, "UTC"); timezone.tap()
        timezone.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "Australia/Sydney")
        dismissKeyboard()
        XCTAssertTrue(app.staticTexts["This clock time does not exist in the chosen timezone. Choose another time."].exists)
        shot("follow-up-nonexistent-correction")
        app.buttons[AccessibilityID.followUpSave].tap()
        XCTAssertTrue(app.textFields[AccessibilityID.followUpTimezone].exists)
        app.buttons[AccessibilityID.logbookClose].firstMatch.tap()
        let overlap = app.buttons["DST overlap inspection"].firstMatch
        XCTAssertTrue(overlap.waitForExistence(timeout: 5)); overlap.tap()
        let zone = app.textFields[AccessibilityID.followUpTimezone]
        XCTAssertEqual(zone.value as? String, "UTC")
        zone.tap(); zone.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "Australia/Sydney")
        dismissKeyboard()
        shot("follow-up-overlap-before-assertion")
        XCTAssertTrue(app.staticTexts["This clock time occurs twice. The first occurrence will be used (UTC+11:00)."].exists)
        shot("follow-up-first-occurrence-offset")
        app.buttons[AccessibilityID.logbookClose].firstMatch.tap()
        app.navigationBars.buttons["Clients"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Clients"].waitForExistence(timeout: 5))
        app.buttons[AccessibilityID.clientsClose].tap()
        XCTAssertTrue(app.buttons[AccessibilityID.homeClients].exists)
    }
}
