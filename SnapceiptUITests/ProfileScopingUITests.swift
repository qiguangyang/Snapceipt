import XCTest

/// CRITICAL profile-scoping probes (beta-hardening §6): switching profiles must
/// rescope ALL surfaces; business-only gating; add+switch re-skin.
final class ProfileScopingUITests: UITestCase {
    private func switchTo(_ profileName: String) {
        let switcher = app.buttons[AccessibilityID.profileSwitcher].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 10), "Switcher missing")
        switcher.tap()
        XCTAssertTrue(app.staticTexts["Switch profile"].waitForExistence(timeout: 5), "Picker did not open")
        app.staticTexts[profileName].firstMatch.tap()
    }

    func testSwitchRescopesAllSurfaces() {
        launchSeeded()
        // ---- On business p1: NO personal-profile rows are visible on ANY surface. ----
        // Reports: the personal merchant ("Coles Personal") must be absent.
        app.buttons[AccessibilityID.tabReports].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.reportsScreen].firstMatch
                        .waitForExistence(timeout: 10), "Reports did not render on p1")
        XCTAssertFalse(app.staticTexts["Coles Personal"].exists,
                       "Personal-profile txn leaked into business Reports")
        // Home tracker/budgets: the p2 budget ("Personal cap") must be absent.
        app.buttons[AccessibilityID.tabHome].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.homeBudgetEditLink].firstMatch
                        .waitForExistence(timeout: 10), "Home did not render on p1")
        XCTAssertFalse(app.staticTexts["Personal cap"].exists,
                       "Personal-profile budget leaked into the business Home tracker")
        // ---- Switch to personal p2: NO business-profile rows are visible. ----
        switchTo("Home Budget")
        // Reports: the business merchant ("The Grounds") must be absent.
        app.buttons[AccessibilityID.tabReports].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.reportsScreen].firstMatch
                        .waitForExistence(timeout: 10), "Reports did not render on p2")
        XCTAssertFalse(app.staticTexts["The Grounds"].exists,
                       "Business-profile txn leaked into personal Reports")
        // Home: the seeded business budgets ("Coffee"/"Dining"/"Whole profile") must
        // be absent on personal.
        app.buttons[AccessibilityID.tabHome].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.homeBudgetEditLink].firstMatch
                        .waitForExistence(timeout: 10), "Home did not render on p2")
        XCTAssertFalse(app.staticTexts["Coffee"].exists,
                       "Business-profile budget leaked into the personal Home tracker")
        // Switch back → business data returns (presence re-proven by ReportsUITests).
        switchTo("Studio North")
    }

    /// Snapshot the set of loyalty-card-row identifiers (`loyalty.card.row.<id>`)
    /// currently rendered in the open wallet. Each seeded card carries a unique uuidv7
    /// id, so two profiles' wallets expose DISJOINT identifier sets — the basis for the
    /// rescoping assertion below.
    private func openWalletCardIDs() -> Set<String> {
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.loyaltyWalletScreen].firstMatch
                        .waitForExistence(timeout: 10), "Wallet did not open")
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.loyaltyCardRowPrefix))
        // ForEach renders rows asynchronously after the container appears — synchronise
        // on the first row before snapshot-querying (else slow CI sees 0).
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "Wallet rendered no loyalty cards")
        return Set(rows.allElementsBoundByIndex.map { $0.identifier })
    }

    /// J24 (cont.): the single-slot loyalty-wallet overlay is rescoped on a profile
    /// switch — it re-derives its rows from the ACTIVE profile, never showing another
    /// profile's cards or stale rows from before the switch. Loyalty is a personal-only
    /// quick action now, so launch with the personal profile active to reach it, then
    /// round-trip through the business profile (where the action is correctly absent).
    func testSwitchRescopesOverlays() {
        launchSeeded(activeType: "personal")   // personal p2 active → loyalty tile present
        // p2 (personal) holds its own seeded loyalty cards; open the wallet and capture
        // exactly which card rows it exposes.
        let loyalty = app.buttons[AccessibilityID.homeQuickLoyalty].firstMatch
        XCTAssertTrue(loyalty.waitForExistence(timeout: 10), "Loyalty quick action missing on personal Home")
        loyalty.tap()
        let p2Cards = openWalletCardIDs()
        XCTAssertEqual(p2Cards.count, 4, "Personal p2 should expose exactly its 4 seeded loyalty cards")
        // Dismiss the wallet overlay via its close affordance (the LbHeader back button
        // carries logbookClose) — the wallet is a full-screen overlay, not a
        // swipe-dismiss sheet — and switch to the business profile p1.
        app.buttons[AccessibilityID.logbookClose].firstMatch.tap()
        XCTAssertTrue(app.buttons[AccessibilityID.profileSwitcher].firstMatch.waitForExistence(timeout: 5),
                      "Did not return to Home after dismissing the wallet")
        switchTo("Studio North")
        // Loyalty is personal-only → its quick action must be ABSENT on the business
        // profile (the overlay can't even be reached here — strict gating).
        XCTAssertFalse(app.buttons[AccessibilityID.homeQuickLoyalty].firstMatch.waitForExistence(timeout: 3),
                       "Loyalty quick action should be hidden on a business profile")
        // Switch back to personal p2 and reopen the wallet: the single-slot overlay must
        // re-derive the SAME profile-scoped set — no business-profile cards leaked in and
        // no stale rows persisted across the switch.
        switchTo("Home Budget")
        let loyaltyAgain = app.buttons[AccessibilityID.homeQuickLoyalty].firstMatch
        XCTAssertTrue(loyaltyAgain.waitForExistence(timeout: 10),
                      "Loyalty quick action missing after switching back to personal")
        loyaltyAgain.tap()
        let p2CardsAgain = openWalletCardIDs()
        XCTAssertEqual(p2CardsAgain, p2Cards,
                       "Reopened personal wallet did not rescope to p2's exact card set after the switch")
    }

    func testQuotesGatedToBusiness() {
        launchSeeded()
        // Business p1 active: the Quotes quick action is present.
        XCTAssertTrue(app.buttons[AccessibilityID.homeQuickQuote].firstMatch.waitForExistence(timeout: 10),
                      "Quote quick action missing on business profile")
        // Switch to personal: Quotes quick action must be ABSENT; mileage stays.
        switchTo("Home Budget")
        XCTAssertFalse(app.buttons[AccessibilityID.homeQuickQuote].firstMatch.waitForExistence(timeout: 3),
                       "Quote quick action should be hidden on a personal profile")
        XCTAssertTrue(app.buttons[AccessibilityID.homeQuickMileage].firstMatch.exists,
                      "Mileage quick action should remain on personal")
    }

    func testAddProfileAndSwitch() {
        launchSeeded()
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        let add = app.descendants(matching: .any)[AccessibilityID.profileAddButton].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Add-profile control missing")
        add.tap()
        // Real AddProfile form: name field + segmented type Picker + Create button.
        let nameField = app.textFields[AccessibilityID.addProfileName]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Add-profile name field missing")
        nameField.tap(); nameField.typeText("Second Biz")
        // Select the Business segment FIRST (while the keyboard is up is fine — the
        // segmented Picker exposes its segments as buttons by label; Business may already
        // be the default, so the tap is idempotent if present).
        let businessSegment = app.buttons["Business"]
        if businessSegment.exists { businessSegment.tap() }
        // Dismiss the keyboard so it can't cover the create button, then scroll the
        // create button into view (the form is a ScrollView and the Business ABN/GST
        // fields push it below the fold).
        if app.keyboards.count > 0 { app.swipeUp() }
        // Create via the dedicated id (NOT the onboarding ids — those aren't attached here).
        let create = app.buttons[AccessibilityID.addProfileCreate]
        XCTAssertTrue(create.waitForExistence(timeout: 5), "Create button missing")
        var scrolls = 0
        while !create.isHittable && scrolls < 4 { app.swipeUp(); scrolls += 1 }
        create.tap()
        // Success step renders "Profile created"; its Done dismisses the sheet, returning
        // to the Profile tab with the new profile already active.
        XCTAssertTrue(app.staticTexts["Profile created"].waitForExistence(timeout: 5),
                      "Add-profile success step did not appear after Create")
        app.buttons["Done"].firstMatch.tap()
        // The sheet must actually dismiss (its Create button is gone).
        XCTAssertTrue(app.buttons[AccessibilityID.addProfileCreate].waitForNonExistence(timeout: 5),
                      "Add-profile sheet did not dismiss after Done")
        // The profile-switcher header lives ONLY on the Home tab — hop there to reach it.
        app.buttons[AccessibilityID.tabHome].firstMatch.tap()
        // Switch to the new profile and assert the switcher now lists it + it becomes active.
        let switcher = app.buttons[AccessibilityID.profileSwitcher].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 10), "Switcher missing after add")
        switcher.tap()
        XCTAssertTrue(app.staticTexts["Switch profile"].waitForExistence(timeout: 5), "Picker did not open")
        // "Second Biz" also appears in the Home header behind the open sheet, so tap the visible
        // (hittable) picker row, not the obscured header label.
        let candidates = app.staticTexts.matching(identifier: "Second Biz")
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 5), "New profile not listed in the switcher")
        let pickerRow = (0..<candidates.count).map { candidates.element(boundBy: $0) }.first { $0.isHittable }
        XCTAssertNotNil(pickerRow, "New profile row not tappable in the switcher")
        pickerRow?.tap()
        // Re-skin proof: the per-profile switcher card (id = profileSwitcherCardPrefix +
        // profileId) renders on the Profile tab; confirming the new profile's card is
        // present + marked Active proves the active profile changed and the shell
        // re-skinned to it.
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        let activeCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.profileSwitcherCardPrefix))
        XCTAssertTrue(activeCard.firstMatch.waitForExistence(timeout: 5),
                      "Active profile switcher card did not re-skin after switching to the new profile")
        // The new profile must be the one marked Active.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Second Biz, Active"))
                        .firstMatch.waitForExistence(timeout: 5),
                      "New profile is not the active profile after switching")
    }
}
