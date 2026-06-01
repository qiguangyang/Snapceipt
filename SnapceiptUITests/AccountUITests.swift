import XCTest

/// Hermetic Account & security flow: seeded shell + stub API (no network). The Stub
/// APIClient returns `devCode "000000"` from `requestEmailChange` and a canned
/// `AccountUser` from `verifyEmailChange`, so the change-email flow runs end-to-end
/// without a backend. The destructive deletion itself is exercised by
/// `AccountViewModelTests`, not against a live backend — here we only assert the
/// typed-`DELETE` confirm gate keeps the destructive button disabled.
///
/// NOTE: the screen roots use `.accessibilityElement(children: .contain)`, which XCUI
/// exposes as a non-`otherElements` container — so screen-level existence is queried
/// via `descendants(matching: .any)` (the proven `SettingsUITests`/`EmailInUITests`
/// pattern), not `app.otherElements`.
///
/// OVERLAY MODEL (real `RootView` behaviour, deviating from the plan's draft): the
/// `.account`/`.changeEmail`/`.privacy` screens are MUTUALLY-EXCLUSIVE `router.overlay`
/// states (one at a time). Opening "Change email" REPLACES the account overlay, and a
/// successful Verify calls `onClose -> router.dismissOverlay()`, landing back on the
/// profile HUB (not the account screen). So we re-open Account from the hub to exercise
/// the delete-confirm gate.
final class AccountUITests: UITestCase {
    func testAccountChangeEmailAndDeleteConfirm() {
        launchSeeded()
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        app.buttons[AccessibilityID.profileRowAccount].tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.accountScreen].waitForExistence(timeout: 10))

        // Change email flow (stub returns devCode 000000 + a new AccountUser)
        app.buttons[AccessibilityID.accountChangeEmail].tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.changeEmailScreen].waitForExistence(timeout: 5))
        let field = app.textFields[AccessibilityID.changeEmailField]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("new@example.com")
        app.buttons[AccessibilityID.changeEmailSend].tap()
        let codeField = app.textFields[AccessibilityID.changeEmailCodeField]
        XCTAssertTrue(codeField.waitForExistence(timeout: 5))
        codeField.tap(); codeField.typeText("000000")
        app.buttons[AccessibilityID.changeEmailVerify].tap()
        // Verify -> onClose -> dismissOverlay: lands back on the profile hub.
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.profileHubScreen].waitForExistence(timeout: 5))

        // Re-open Account from the hub to reach the delete-confirm gate.
        app.buttons[AccessibilityID.profileRowAccount].tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.accountScreen].waitForExistence(timeout: 5))

        // Delete confirm gate: button disabled until "DELETE" typed (we cancel, not destroy)
        app.buttons[AccessibilityID.accountDeleteButton].tap()
        let confirm = app.textFields[AccessibilityID.accountDeleteConfirmField]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let deleteBtn = app.buttons[AccessibilityID.accountDeleteConfirmButton]
        XCTAssertTrue(deleteBtn.waitForExistence(timeout: 5))
        XCTAssertFalse(deleteBtn.isEnabled)   // gated until the confirm word is typed
    }

    func testPrivacyToggleVisible() {
        launchSeeded()
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        app.buttons[AccessibilityID.profileRowPrivacy].tap()
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.privacyScreen].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches[AccessibilityID.privacyAppLockToggle].waitForExistence(timeout: 5))
    }
}
