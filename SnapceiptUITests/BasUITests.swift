import XCTest

final class BasUITests: UITestCase {
    /// Scroll a (possibly off-screen) element into view by swiping up on the
    /// scrollable content, then return it once it's hittable. The redesign turned
    /// Reports + BAS into restyled scroll views, so cards/controls that used to be
    /// above the fold may now sit further down — `waitForExistence` is true for an
    /// off-screen element, but `.tap()` needs it on-screen and hittable.
    @discardableResult
    @MainActor private func scrollToHittable(_ element: XCUIElement,
                                             timeout: TimeInterval = 8) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        var swipes = 0
        while !element.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        return element.isHittable
    }

    @MainActor func test_basCardOpensBasViewFixesIncomeAndLodges() {
        launchBasSeed()
        app.buttons[AccessibilityID.tabReports].tap()
        // The Reports restyle reordered/added cards, so scroll the BAS card on-screen
        // before tapping (it exists but may not be hittable off the fold).
        let card = app.descendants(matching: .any)[AccessibilityID.reportsBasCard]
        XCTAssertTrue(card.waitForExistence(timeout: 8), "BAS card missing for registered business")
        XCTAssertTrue(scrollToHittable(card), "BAS card never became hittable on Reports")
        card.tap()
        // BasView spine.
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.basScreen].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.basCopy1A].waitForExistence(timeout: 4),
                      "1A copy control missing")

        // Headline starts "Estimated" (income unconfirmed).
        XCTAssertTrue(app.staticTexts["Estimated"].waitForExistence(timeout: 4),
                      "headline should start Estimated with unconfirmed income")
        // Fix the reconciliation item: confirm income → headline flips to firm.
        let confirm = app.descendants(matching: .any)[AccessibilityID.basConfirmIncome]
        XCTAssertTrue(scrollToHittable(confirm, timeout: 4), "confirm-income quick-fix missing")
        confirm.tap()
        // "Estimated" label is gone once income is reviewed.
        let stillEstimated = app.staticTexts["Estimated"]
        XCTAssertFalse(stillEstimated.waitForExistence(timeout: 3),
                       "headline must flip from Estimated to firm after confirming income")

        // Copy 1A (no crash; pasteboard write is best-effort under test).
        let copy1A = app.descendants(matching: .any)[AccessibilityID.basCopy1A]
        XCTAssertTrue(scrollToHittable(copy1A, timeout: 4), "1A copy control not reachable")
        copy1A.tap()
        // Mark-as-lodged (the action buttons live at the bottom of the BAS scroll).
        let markLodged = app.descendants(matching: .any)[AccessibilityID.basMarkLodged]
        XCTAssertTrue(scrollToHittable(markLodged, timeout: 4), "Mark-as-lodged not reachable")
        markLodged.tap()
        // Export button exists.
        let export = app.descendants(matching: .any)[AccessibilityID.basExport]
        XCTAssertTrue(scrollToHittable(export, timeout: 4), "Export button missing")
    }

    @MainActor func test_nonRegisteredProfileHidesBasCard() {
        launchBasSeed()
        // Switch to the non-registered business profile (p2 "Side Hustle") via the
        // home-header picker — the canonical switch path (ProfilePickerSheet calls
        // store.setActive). The picker rows are identified by profile name.
        app.buttons[AccessibilityID.tabHome].firstMatch.tap()
        let switcher = app.buttons[AccessibilityID.profileSwitcher].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 8), "profile switcher missing")
        switcher.tap()
        XCTAssertTrue(app.staticTexts["Switch profile"].waitForExistence(timeout: 5), "Picker did not open")
        app.staticTexts["Side Hustle"].firstMatch.tap()
        app.buttons[AccessibilityID.tabReports].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.reportsScreen].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)[AccessibilityID.reportsBasCard].exists,
                       "BAS card must be hidden for a non-registered profile")
    }
}
