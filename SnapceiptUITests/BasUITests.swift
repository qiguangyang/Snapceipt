import XCTest

final class BasUITests: UITestCase {
    /// Scroll a (possibly off-screen) element into view by swiping up on the
    /// scrollable content, then return it once it's hittable. The redesign turned
    /// Reports + BAS into restyled scroll views, so cards/controls that used to be
    /// above the fold may now sit further down — `waitForExistence` is true for an
    /// off-screen element, but `.tap()` needs it on-screen and hittable.
    @discardableResult
    @MainActor private func scrollToHittable(_ element: XCUIElement,
                                             within container: XCUIElement? = nil,
                                             timeout: TimeInterval = 8) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        // Prefer swiping on the enclosing ScrollView (Reports / BAS are restyled
        // ScrollViews); the floating tab bar overlays the bottom ~90pt, so an
        // app-level swipe can land on the tab bar instead of scrolling content.
        let scroller: XCUIElement = container ?? app
        var swipes = 0
        while !element.isHittable && swipes < 8 {
            scroller.swipeUp()
            swipes += 1
        }
        return element.isHittable
    }

    @MainActor func test_basCardOpensBasViewFixesIncomeAndLodges() {
        launchBasSeed(pro: true)   // the BAS card is Pro-gated; open it without a paywall
        app.buttons[AccessibilityID.tabReports].tap()
        // The Reports restyle reordered/added cards, so the BAS card may now sit further
        // down the Reports ScrollView — it exists but isn't hittable off the fold. Bind it
        // as the real Button it is and scroll it on-screen by swiping the Reports scroll
        // view (not the whole app, which can land on the floating tab bar).
        let reportsScroll = app.descendants(matching: .any)[AccessibilityID.reportsScreen].firstMatch
        XCTAssertTrue(reportsScroll.waitForExistence(timeout: 8), "Reports screen never appeared")
        let card = app.buttons[AccessibilityID.reportsBasCard].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8), "BAS card missing for registered business")
        XCTAssertTrue(scrollToHittable(card, within: reportsScroll),
                      "BAS card never became hittable on Reports")
        card.tap()
        // BasView spine. Bind the BAS ScrollView so in-screen rows scroll against it
        // (not the whole app) — the floating tab bar overlays the bottom of the scroll.
        let basScroll = app.descendants(matching: .any)[AccessibilityID.basScreen].firstMatch
        XCTAssertTrue(basScroll.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.basCopy1A].waitForExistence(timeout: 4),
                      "1A copy control missing")

        // Headline starts "Estimated" (income unconfirmed).
        XCTAssertTrue(app.staticTexts["Estimated"].waitForExistence(timeout: 4),
                      "headline should start Estimated with unconfirmed income")
        // Fix the reconciliation item: confirm income → headline flips to firm.
        let confirm = app.descendants(matching: .any)[AccessibilityID.basConfirmIncome]
        XCTAssertTrue(scrollToHittable(confirm, within: basScroll, timeout: 4), "confirm-income quick-fix missing")
        confirm.tap()
        // "Estimated" label is gone once income is reviewed.
        let stillEstimated = app.staticTexts["Estimated"]
        XCTAssertFalse(stillEstimated.waitForExistence(timeout: 3),
                       "headline must flip from Estimated to firm after confirming income")

        // Copy 1A (no crash; pasteboard write is best-effort under test).
        let copy1A = app.descendants(matching: .any)[AccessibilityID.basCopy1A]
        XCTAssertTrue(scrollToHittable(copy1A, within: basScroll, timeout: 4), "1A copy control not reachable")
        copy1A.tap()
        // Mark-as-lodged (the action buttons live at the bottom of the BAS scroll).
        let markLodged = app.descendants(matching: .any)[AccessibilityID.basMarkLodged]
        XCTAssertTrue(scrollToHittable(markLodged, within: basScroll, timeout: 4), "Mark-as-lodged not reachable")
        markLodged.tap()
        // Export button exists.
        let export = app.descendants(matching: .any)[AccessibilityID.basExport]
        XCTAssertTrue(scrollToHittable(export, within: basScroll, timeout: 4), "Export button missing")
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

    @MainActor func test_basPeriodStepperAndHistoryDrillIn() {
        launchBasSeed(pro: true)
        app.buttons[AccessibilityID.tabReports].tap()
        let reportsScroll = app.descendants(matching: .any)[AccessibilityID.reportsScreen].firstMatch
        XCTAssertTrue(reportsScroll.waitForExistence(timeout: 8), "Reports never appeared")
        let card = app.buttons[AccessibilityID.reportsBasCard].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8), "BAS card missing")
        XCTAssertTrue(scrollToHittable(card, within: reportsScroll), "BAS card not hittable")
        card.tap()

        let basScroll = app.descendants(matching: .any)[AccessibilityID.basScreen].firstMatch
        XCTAssertTrue(basScroll.waitForExistence(timeout: 8), "BAS screen never appeared")

        // The period stepper controls exist (◀ may be disabled if the seed has no prior data).
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.basPeriodNext].waitForExistence(timeout: 4),
                      "period next control missing")
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.basPeriodPrev].exists,
                      "period prev control missing")

        // Open the Past-BAS history sheet.
        let historyLink = app.descendants(matching: .any)[AccessibilityID.basHistoryLink]
        XCTAssertTrue(scrollToHittable(historyLink, within: basScroll, timeout: 4), "Past BAS link not reachable")
        historyLink.tap()
        let historyScreen = app.descendants(matching: .any)[AccessibilityID.basHistoryScreen].firstMatch
        XCTAssertTrue(historyScreen.waitForExistence(timeout: 5), "history sheet did not open")

        // At least the current period row exists; tapping a row returns to the BAS screen.
        let firstRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.basHistoryRowPrefix))
            .firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "no history rows")
        firstRow.tap()
        XCTAssertTrue(basScroll.waitForExistence(timeout: 5), "did not return to the BAS screen after drill-in")
    }
}
