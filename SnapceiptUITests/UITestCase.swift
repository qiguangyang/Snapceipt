import XCTest

/// Base case for the hermetic XCUITest suite: owns the `XCUIApplication` and the
/// stub-launch + dev-sign-in helpers. `AccessibilityID` is compiled into this target.
class UITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    /// Hermetic launch: in-app stub + reset to signed-out/empty.
    func launchStub() {
        app.launchArguments += ["-uiTestStub", "-uiTestReset"]
        app.launch()
    }

    /// Launch directly into a SEEDED, already-signed-in shell (2 profiles) — for
    /// shell-level tests. NOTE: no `-uiTestReset` (seeding wants a live session;
    /// the seed overwrites the session deterministically).
    /// Launch into the seeded shell. `activeType` ("personal"/"business") chooses which
    /// seeded profile is active — Home quick actions are profile-type-gated (personal:
    /// Loyalty/Mileage/WFH; business: Quote/Reports/Receipts). `pro` reports a Pro plan so
    /// Pro-gated features (Quotes, Email-in, Mileage, WFH) open without the paywall.
    func launchSeeded(activeType: String? = nil, pro: Bool = false) {
        app.launchArguments += ["-uiTestStub", "-uiTestSeed"]
        if let activeType { app.launchArguments += ["-uiTestActiveType", activeType] }
        if pro { app.launchArguments += ["-uiTestPro"] }
        app.launch()
    }

    /// Launch directly into the BAS fixture: a GST-registered Business profile p1
    /// active + a non-registered Business p2 — for BasUITests.
    func launchBasSeed() {
        app.launchArguments += ["-uiTestStub", "-uiTestBasSeed"]
        app.launch()
    }

    /// Launch directly into the RICH tour fixture (both profiles populated,
    /// clock pinned) — for ScreenshotTourUITests only. `pro` reports a Pro plan so
    /// Pro-gated areas (Quotes, Email-in, Mileage, WFH) open without the paywall.
    func launchTour(activeType: String? = nil, pro: Bool = false) {
        app.launchArguments += ["-uiTestStub", "-uiTestTour"]
        if let activeType { app.launchArguments += ["-uiTestActiveType", activeType] }
        if pro { app.launchArguments += ["-uiTestPro"] }
        app.launch()
    }

    /// Launch into the EMPTY tour fixture (both profiles, NO domain data, clock
    /// pinned) so every screen renders its empty-state art — for the empty-state
    /// shots in ScreenshotTourUITests.
    func launchTourEmpty() {
        app.launchArguments += ["-uiTestStub", "-uiTestTourEmpty"]
        app.launch()
    }

    func tapDevSignIn() {
        let b = app.buttons[AccessibilityID.signInDev]
        XCTAssertTrue(b.waitForExistence(timeout: 10), "Dev sign-in button missing")
        b.tap()
    }
}
