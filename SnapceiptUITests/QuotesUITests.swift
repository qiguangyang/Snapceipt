import XCTest

/// Hermetic quotes flow: seeded shell + stub API (no network). Home Create Quote
/// (Business-only) -> list -> new editor -> pick the seeded client -> add a line
/// item -> toggle GST -> Send (stub) -> success overlay -> Done -> Home.
/// Real PDF/email is covered by the backend tests + manual QA.
final class QuotesUITests: UITestCase {
    func testCreateQuotePickClientAddLineSend() {
        launchSeeded()   // signed-in, business profile p1 active, seeded client + quote

        let quick = app.buttons[AccessibilityID.homeQuickQuote].firstMatch
        XCTAssertTrue(quick.waitForExistence(timeout: 10), "Create Quote quick action missing on Home (business profile)")
        quick.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.quotesScreen].waitForExistence(timeout: 5),
                      "Quotes list did not appear")

        let seededRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", AccessibilityID.quoteRowPrefix)).firstMatch
        XCTAssertTrue(seededRow.waitForExistence(timeout: 5), "No seeded quote row rendered")

        app.buttons[AccessibilityID.quotesAdd].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.quoteEditorScreen].waitForExistence(timeout: 5),
                      "Quote editor did not appear")

        app.buttons[AccessibilityID.quoteEditorClient].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.clientPickerScreen].waitForExistence(timeout: 5),
                      "Client picker did not appear")
        let clientRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", AccessibilityID.clientRowPrefix)).firstMatch
        XCTAssertTrue(clientRow.waitForExistence(timeout: 5), "No seeded client row in the picker")
        clientRow.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.quoteEditorScreen].waitForExistence(timeout: 5),
                      "Did not return to the editor after picking a client")

        app.buttons[AccessibilityID.quoteEditorAddLine].firstMatch.tap()
        let lineRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", AccessibilityID.quoteLineRowPrefix)).firstMatch
        XCTAssertTrue(lineRow.waitForExistence(timeout: 5), "Line item row did not appear after Add")

        let gst = app.switches[AccessibilityID.quoteEditorGst].firstMatch
        if gst.waitForExistence(timeout: 3) { gst.tap() }
        app.staticTexts["New quote"].firstMatch.tap()

        let send = app.buttons[AccessibilityID.quoteEditorSend]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Send button missing")
        XCTAssertTrue(send.isEnabled, "Send should be enabled with a client + a line item")
        send.tap()
        XCTAssertTrue(app.staticTexts["Quote ready!"].firstMatch.waitForExistence(timeout: 8)
                      || app.staticTexts["Quote sent!"].firstMatch.waitForExistence(timeout: 2),
                      "Success overlay did not appear after Send")

        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.shellHome].waitForExistence(timeout: 5),
                      "Did not return to Home after Done")
        XCTAssertTrue(app.buttons[AccessibilityID.homeQuickQuote].firstMatch.waitForExistence(timeout: 5),
                      "Create Quote action missing on Home after returning")
    }
}
