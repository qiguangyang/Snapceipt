import XCTest

/// End-to-end A/R flow: open the Invoices list from Home, create a new invoice,
/// pick the seeded client, add a priced line item, issue it (StubAPIClient), then
/// record a PARTIAL payment and assert the editor surfaces the `Partial` A/R badge.
///
/// Hermetic — `launchSeeded(pro: true)` (`-uiTestStub -uiTestSeed -uiTestPro`) is the
/// same harness `QuotesUITests` uses: a signed-in, Pro, business profile (p1) with a
/// saved client, so Quotes/Invoices open without the paywall and no network is hit.
/// The convert path is exercised by the convert unit tests; this asserts the
/// issue + partial-payment surfacing end-to-end.
final class InvoiceFlowUITests: UITestCase {
    func testIssueRecordPartialPaymentShowsPartial() {
        launchSeeded(pro: true)   // signed-in, business profile p1 active, seeded client

        // 1. Open the Invoices list from Home (business quick-action tile) and add new.
        let invoicesTile = app.buttons[AccessibilityID.homeQuickInvoices].firstMatch
        XCTAssertTrue(invoicesTile.waitForExistence(timeout: 10),
                      "Invoices quick action missing on Home (business profile)")
        invoicesTile.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.invoicesScreen].waitForExistence(timeout: 5),
                      "Invoices list did not appear")

        app.buttons[AccessibilityID.invoicesAdd].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.invoiceEditorScreen].waitForExistence(timeout: 5),
                      "Invoice editor did not appear")

        // 2. Pick the seeded client (the picker mirrors the quote editor's).
        app.buttons[AccessibilityID.invoiceEditorClient].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.clientPickerScreen].waitForExistence(timeout: 5),
                      "Client picker did not appear")
        let clientRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", AccessibilityID.clientRowPrefix)).firstMatch
        XCTAssertTrue(clientRow.waitForExistence(timeout: 5), "No seeded client row in the picker")
        clientRow.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.invoiceEditorScreen].waitForExistence(timeout: 5),
                      "Did not return to the editor after picking a client")

        // 3. Add a line item and give it a non-zero unit price so the invoice total is
        //    positive (the A/R badge derives Partial only when 0 < paid < total).
        app.buttons[AccessibilityID.invoiceEditorAddLine].firstMatch.tap()
        let lineRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", AccessibilityID.invoiceLineRowPrefix)).firstMatch
        XCTAssertTrue(lineRow.waitForExistence(timeout: 5), "Line item row did not appear after Add")

        // The line's unit-price field carries the "Unit $" placeholder (qty is "Qty",
        // description is "Description"); target it by placeholder + give it a real price.
        let unitField = app.textFields.matching(
            NSPredicate(format: "placeholderValue == %@", "Unit $")).firstMatch
        XCTAssertTrue(unitField.waitForExistence(timeout: 5), "Unit-price field not found on the line row")
        unitField.tap()
        unitField.typeText("500")          // $500 ex-GST → $550 total with the default GST toggle
        dismissKeyboard()

        // 4. Issue the invoice (StubAPIClient returns INV-0001 / issued / total 55000).
        let issue = app.buttons[AccessibilityID.invoiceEditorIssue].firstMatch
        XCTAssertTrue(issue.waitForExistence(timeout: 5), "Issue button missing")
        XCTAssertTrue(issue.isEnabled, "Issue should be enabled with a client + a priced line item")
        issue.tap()

        // 5. Record a PARTIAL payment: the amount defaults to the full outstanding
        //    balance, so clear it and type a smaller amount, then save.
        let recordPayment = app.buttons[AccessibilityID.invoiceEditorRecordPayment].firstMatch
        XCTAssertTrue(recordPayment.waitForExistence(timeout: 10),
                      "Record-payment button never appeared (invoice not issued?)")
        recordPayment.tap()

        let amountField = app.textFields[AccessibilityID.recordPaymentAmount].firstMatch
        XCTAssertTrue(amountField.waitForExistence(timeout: 5), "Record-payment amount field missing")
        amountField.tap()
        // Clear the pre-filled outstanding amount, then type a partial amount (< total).
        amountField.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 1) { app.menuItems["Select All"].tap() }
        amountField.typeText("100")        // $100 < $550 → Partial

        app.buttons[AccessibilityID.recordPaymentSave].firstMatch.tap()

        // 6. Back in the invoice editor, the A/R badge now reads "Partial".
        let partial = app.staticTexts["Partial"].firstMatch
        XCTAssertTrue(partial.waitForExistence(timeout: 8),
                      "Invoice editor should show the Partial A/R badge after a partial payment")
    }
}
