import XCTest

/// J50: rotating the inbox alias flips the displayed address initial→rotated.
final class EmailInRotateUITests: UITestCase {
    func testRotateUpdatesAlias() {
        launchSeeded()
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        let row = app.descendants(matching: .any)[AccessibilityID.profileRowEmailIn].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Email-in row missing")
        row.tap()
        // Email-in is a Pro feature: the free seed user gets the paywall on open, and
        // Rotate itself is gated. Subscribe through the StoreKit-test paywall so the
        // gate falls away and the Rotate tap actually rotates the alias (instead of
        // re-presenting the paywall). No-op when already entitled.
        subscribeIfPaywallPresented()
        let address = app.descendants(matching: .any)[AccessibilityID.emailInAddress].firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 5), "Alias address label missing")
        XCTAssertTrue(address.label.contains("stubtokeninitial"),
                      "Initial alias not shown: \(address.label)")
        // Rotate → the displayed alias must change to the rotated token.
        app.buttons[AccessibilityID.emailInRotate].firstMatch.tap()
        // A residual gate-tap can re-present the paywall on slower CI; clear it again.
        subscribeIfPaywallPresented()
        let expectation = expectation(for: NSPredicate(format: "label CONTAINS %@", "stubtokenrotated"),
                                      evaluatedWith: address)
        wait(for: [expectation], timeout: 6)
    }

    /// Email-in is a Pro feature: the seeded (free) user is shown the Pro paywall the
    /// moment the screen opens (and on every gated tap). Subscribe through the
    /// StoreKit-test paywall so entitlement flips to Pro and the gate falls away. The
    /// `.storekit` config completes the purchase locally without a system dialog.
    /// No-op when the paywall isn't up (e.g. already entitled).
    private func subscribeIfPaywallPresented() {
        let title = app.staticTexts[AccessibilityID.paywallTitle].firstMatch
        guard title.waitForExistence(timeout: 3) else { return }
        let subscribe = app.buttons[AccessibilityID.paywallSubscribe].firstMatch
        XCTAssertTrue(subscribe.waitForExistence(timeout: 8), "Paywall subscribe CTA missing")
        subscribe.tap()
        // Purchase + entitlement propagation dismisses the sheet; wait it out.
        XCTAssertTrue(title.waitForNonExistence(timeout: 10), "Paywall did not dismiss after subscribing")
    }
}
