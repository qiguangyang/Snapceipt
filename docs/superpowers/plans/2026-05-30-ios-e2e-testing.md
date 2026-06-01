# iOS End-to-End Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read the Canonical Contracts in the spec first.

**Goal:** Add XCUITest end-to-end UI tests that launch the real Snapceipt iOS app and drive sign-in → onboarding → create profile → tabbed shell, in a hermetic stubbed mode (default/CI) and an opt-in live-backend smoke mode — enabled by a DEBUG-only one-tap "Dev sign in" button.

**Architecture:** A DEBUG launch-arg seam (`AppLaunch`) lets `SnapceiptApp` swap `LiveAPIClient` for an in-app `StubAPIClient` + in-memory SwiftData when launched with `-uiTestStub`, or point `LiveAPIClient` at a local backend via `API_BASE_URL`. A new `SnapceiptUITests` (XCUITest) target drives the real UI via shared `AccessibilityID` constants. The dev sign-in button reuses the backend's `E2E_TEST_MODE` magic-link dev-token seam. All test surfaces are `#if DEBUG`.

**Tech Stack:** Swift 5.10, SwiftUI, SwiftData, Swift Testing (unit), **XCUITest** (UI), XcodeGen, `xcodebuild` on the "iPhone 16" simulator.

**Spec:** `docs/superpowers/specs/2026-05-30-ios-e2e-testing-design.md` (§5 Canonical Contracts is authoritative). Repo `/Users/yangqi/Documents/github/Snapceipt`, branch `foundation`. Commit each task with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. After adding files, run `xcodegen generate`.

---

## Task 1: `APIClient.magicLinkRequestDev` (dev-token fetch)

**Files:**
- Modify: `Snapceipt/Sync/APIClient.swift` (add to the `APIClient` protocol + `LiveAPIClient`)
- Modify: `SnapceiptTests/Mocks/MockAPIClient.swift`
- Test: `SnapceiptTests/APIClientTests.swift`

- [ ] **Step 1: Write the failing test** in `SnapceiptTests/APIClientTests.swift` (add to the existing suite)

```swift
@Test func magicLinkRequestDevReturnsDevTokenFrom202Body() async throws {
    MockURLProtocol.requestHandler = { req in
        #expect(req.url?.path == "/auth/magic-link/request")
        let body = #"{"devToken":"dev-tok-123"}"#.data(using: .utf8)!
        return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, body)
    }
    let api = LiveAPIClient(baseURL: URL(string: "https://x")!, auth: AuthStore(keychain: Keychain(service: "t.\(UUID())")), session: Self.stubSession())
    let token = try await api.magicLinkRequestDev(email: "dev@snapceipt.app")
    #expect(token == "dev-tok-123")
}

@Test func magicLinkRequestDevReturnsNilWhenNoToken() async throws {
    MockURLProtocol.requestHandler = { req in
        (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
    }
    let api = LiveAPIClient(baseURL: URL(string: "https://x")!, auth: AuthStore(keychain: Keychain(service: "t.\(UUID())")), session: Self.stubSession())
    let token = try await api.magicLinkRequestDev(email: "dev@snapceipt.app")
    #expect(token == nil)
}
```

(If the existing test file already has a `stubSession()` helper / `MockURLProtocol` setup, reuse it; otherwise mirror the pattern already used by the other `APIClientTests`.)

- [ ] **Step 2: Run it (expect fail)**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/APIClientTests`
Expected: FAIL — `magicLinkRequestDev` not a member of `APIClient`.

- [ ] **Step 3: Add to the `APIClient` protocol** (`Snapceipt/Sync/APIClient.swift`)

```swift
protocol APIClient {
    // ...existing methods...
    /// Dev-only: POST /auth/magic-link/request and return the `devToken` the backend
    /// includes only when E2E_TEST_MODE=1 (nil otherwise). Used by the dev sign-in button.
    func magicLinkRequestDev(email: String) async throws -> String?
}
```

- [ ] **Step 4: Implement in `LiveAPIClient`** (same file)

```swift
func magicLinkRequestDev(email: String) async throws -> String? {
    struct DevReq: Encodable { let email: String }
    struct DevResp: Decodable { let devToken: String? }
    // Reuse the same request builder the other calls use; this posts JSON and returns the raw body.
    let data = try await postExpectingData(path: "/auth/magic-link/request", body: DevReq(email: email), authenticated: false)
    guard !data.isEmpty else { return nil }
    return (try? JSONDecoder().decode(DevResp.self, from: data))?.devToken
}
```

If `LiveAPIClient` has no `postExpectingData(...)` helper, add a tiny private one that performs the request and returns `Data` (don't throw on an empty 202 body); reuse the existing `perform`/`makeRequest`/`validate` plumbing — match the file's established style.

- [ ] **Step 5: Implement in `MockAPIClient`** (`SnapceiptTests/Mocks/MockAPIClient.swift`)

```swift
var magicLinkRequestDevHandler: (String) async throws -> String? = { _ in "mock-dev-token" }
func magicLinkRequestDev(email: String) async throws -> String? { try await magicLinkRequestDevHandler(email) }
```

- [ ] **Step 6: Run tests (expect pass)**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/APIClientTests`
Expected: PASS. Then `xcodegen generate && xcodebuild build -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16"` → BUILD SUCCEEDED (confirms `StubAPIClient` not yet referenced; the protocol change compiles everywhere it's adopted — `MockAPIClient` updated; `StubAPIClient` arrives in Task 4).

- [ ] **Step 7: Commit**

```bash
git add Snapceipt/Sync/APIClient.swift SnapceiptTests/Mocks/MockAPIClient.swift SnapceiptTests/APIClientTests.swift
git commit -m "feat(ios): APIClient.magicLinkRequestDev for dev sign-in"
```

---

## Task 2: `AuthViewModel.devSignIn()`

**Files:**
- Create: `Snapceipt/App/DevAccount.swift` (DEBUG; the fixed dev account — used here and by Task 4)
- Modify: `Snapceipt/Features/Auth/AuthViewModel.swift`
- Test: `SnapceiptTests/AuthViewModelTests.swift`

- [ ] **Step 1: Write the failing tests** (`SnapceiptTests/AuthViewModelTests.swift`)

```swift
@Test func devSignInWithTokenReachesSignedInAndSavesSession() async {
    let mock = MockAPIClient()
    mock.magicLinkRequestDevHandler = { _ in "dev-tok" }
    mock.magicLinkVerifyHandler = { token in
        #expect(token == "dev-tok")
        return SessionResponse(accessToken: "a", refreshToken: "r", expiresIn: 900,
                               user: SessionUser(id: "u-dev", email: "dev@snapceipt.app", displayName: "Dev"))
    }
    let auth = AuthStore(keychain: Keychain(service: "t.\(UUID())"))
    let vm = AuthViewModel(api: mock, auth: auth)
    await vm.devSignIn()
    #expect(vm.state == .signedIn)
    #expect(auth.session?.userId == "u-dev")
}

@Test func devSignInWithNoTokenGoesToErrorAndStaysSignedOutScreen() async {
    let mock = MockAPIClient()
    mock.magicLinkRequestDevHandler = { _ in nil }   // backend not in dev mode
    let vm = AuthViewModel(api: mock, auth: AuthStore(keychain: Keychain(service: "t.\(UUID())")))
    await vm.devSignIn()
    if case .error = vm.state {} else { Issue.record("expected .error, got \(vm.state)") }
    #expect(vm.pendingEmail == nil)   // RootView keeps showing SignInView
}
```

(Match the real `AuthViewModel.init` signature + `MockAPIClient` handler names; if the verify handler is named differently in the existing mock, use that name.)

- [ ] **Step 2: Run (expect fail)**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/AuthViewModelTests`
Expected: FAIL — `devSignIn` undefined.

- [ ] **Step 3: Implement** (append to `AuthViewModel`, gated)

```swift
#if DEBUG
/// One-tap dev sign-in: fetch the backend's dev token (E2E_TEST_MODE) for the fixed
/// dev account and verify it → real session. Errors clearly if the backend isn't in dev mode.
func devSignIn() async {
    pendingEmail = nil
    state = .verifying
    do {
        guard let token = try await api.magicLinkRequestDev(email: DevAccount.email) else {
            state = .error("Dev sign-in needs the backend running in dev mode (E2E_TEST_MODE).")
            return
        }
        try await verifyMagicLink(token: token)   // existing path → saves session, sets .signedIn
    } catch {
        state = .error("Dev sign-in failed: \(error.localizedDescription)")
    }
}
#endif
```

Also create `Snapceipt/App/DevAccount.swift` (so `devSignIn` compiles in this task; Task 4 reuses it):

```swift
import Foundation

#if DEBUG
/// The fixed dev account used by dev sign-in and the UI-test stub.
enum DevAccount {
    static let email = "dev@snapceipt.app"
    static let userId = "00000000-0000-7000-8000-0000000000de"
}
#endif
```

If `verifyMagicLink(token:)` already manages `state`/`pendingEmail`, ensure `devSignIn`'s error path overrides any `pendingEmail` it set so RootView shows `SignInView` (not the wait screen).

- [ ] **Step 4: Run (expect pass)** — same command as Step 2. Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Auth/AuthViewModel.swift SnapceiptTests/AuthViewModelTests.swift
git commit -m "feat(ios): AuthViewModel.devSignIn (DEBUG)"
```

---

## Task 3: `AccessibilityID` + dev button on `SignInView`

**Files:**
- Create: `Snapceipt/Shared/AccessibilityID.swift`
- Modify: `Snapceipt/Features/Auth/SignInView.swift`

- [ ] **Step 1: Create `Snapceipt/Shared/AccessibilityID.swift`** (compiled into BOTH the app and the UITest target — see Task 6)

```swift
import Foundation

/// Stable accessibility identifiers shared by the app views and the XCUITest target.
/// (UI tests are a separate process and cannot @testable-import the app, so this file
/// is added to both targets' sources in project.yml.)
enum AccessibilityID {
    static let signInApple = "signin.apple"
    static let signInEmail = "signin.email"
    static let signInDev = "signin.dev"
    static let onboardingName = "onboarding.name"
    static let onboardingTypePersonal = "onboarding.type.personal"
    static let onboardingTypeBusiness = "onboarding.type.business"
    static let onboardingCreate = "onboarding.create"
    static let shellTabBar = "shell.tabbar"
    static let shellHome = "shell.home"
    static let profileSwitcher = "profile.switcher"
}
```

- [ ] **Step 2: Add the dev button + ids to `SignInView`** (modify)

Add `.accessibilityIdentifier(AccessibilityID.signInApple)` to the Apple button and `.signInEmail` to the email entry control. Add, below "Continue with email":

```swift
#if DEBUG
Button {
    Task { await authVM.devSignIn() }
} label: {
    Label("Dev sign in", systemImage: "wrench.and.screwdriver")
        .font(.ui(13, .semibold))
        .foregroundStyle(Palette.ink3)
}
.accessibilityIdentifier(AccessibilityID.signInDev)
.padding(.top, 6)

if case let .error(msg) = authVM.state {
    Text(msg).font(.ui(12, .regular)).foregroundStyle(Palette.alert)
        .multilineTextAlignment(.center).padding(.top, 4)
}
#endif
```

(Match `SignInView`'s real property name for the view model and its existing layout container.)

- [ ] **Step 3: Build to verify it compiles + renders**

Run: `xcodegen generate && xcodebuild build -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16"`
Expected: BUILD SUCCEEDED. Confirm the `SignInView` `#Preview` shows the dev button.

- [ ] **Step 4: Commit**

```bash
git add Snapceipt/Shared/AccessibilityID.swift Snapceipt/Features/Auth/SignInView.swift
git commit -m "feat(ios): shared AccessibilityID + DEBUG dev sign-in button on SignInView"
```

---

## Task 4: `StubAPIClient` + `AppLaunch` seam + `SnapceiptApp` wiring

**Files:**
- Create: `Snapceipt/App/AppLaunch.swift` (DEBUG: launch parsing + APIClient/container factory; uses `DevAccount` from Task 2)
- Create: `Snapceipt/Sync/StubAPIClient.swift` (DEBUG)
- Modify: `Snapceipt/App/SnapceiptApp.swift`
- Modify: `Snapceipt/Info.plist` (allow local networking for the live smoke)
- Modify: `Snapceipt/Features/Onboarding/PermissionPrimingView.swift` (skip real permission requests under stub)
- Test: `SnapceiptTests/AppLaunchTests.swift`

- [ ] **Step 1: Write failing tests** (`SnapceiptTests/AppLaunchTests.swift`)

```swift
import Testing
@testable import Snapceipt

struct AppLaunchTests {
    @Test func parsesStubAndResetFlags() {
        let l = AppLaunch(arguments: ["app", "-uiTestStub", "-uiTestReset"], environment: [:])
        #expect(l.useStub); #expect(l.reset); #expect(l.apiBaseURLOverride == nil)
    }
    @Test func parsesApiBaseURLOverride() {
        let l = AppLaunch(arguments: ["app"], environment: ["API_BASE_URL": "http://127.0.0.1:8787"])
        #expect(!l.useStub); #expect(l.apiBaseURLOverride?.absoluteString == "http://127.0.0.1:8787")
    }
    @Test func stubClientSignsInDevAccount() async throws {
        let s = StubAPIClient()
        let token = try await s.magicLinkRequestDev(email: DevAccount.email)
        #expect(token != nil)
        let session = try await s.magicLinkVerify(token: token!)
        #expect(session.user.id == DevAccount.userId)
    }
}
```

- [ ] **Step 2: Run (expect fail)**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/AppLaunchTests`
Expected: FAIL — `AppLaunch`/`StubAPIClient`/`DevAccount` undefined.

- [ ] **Step 3: Create `Snapceipt/App/AppLaunch.swift`**

`DevAccount` already exists from Task 2 (`Snapceipt/App/DevAccount.swift`) — reference it, don't redefine.

```swift
import Foundation
import SwiftData

#if DEBUG
/// Parses UI-test launch arguments/environment to decide how the app wires itself.
struct AppLaunch {
    let useStub: Bool
    let reset: Bool
    let apiBaseURLOverride: URL?

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        useStub = arguments.contains("-uiTestStub")
        reset = arguments.contains("-uiTestReset")
        apiBaseURLOverride = environment["API_BASE_URL"].flatMap(URL.init(string:))
    }

    static let current = AppLaunch()

    /// Clears dev-namespaced auth + active-profile state so a UI test starts signed-out + empty.
    func applyResetIfNeeded(authStore: AuthStore) {
        guard reset else { return }
        authStore.clear()
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
        UserDefaults.standard.removeObject(forKey: "sc.syncCursor")
    }

    func makeAPIClient(auth: AuthStore) -> APIClient {
        if useStub { return StubAPIClient() }
        let base = apiBaseURLOverride ?? URL(string: "https://api.snapceipt.app")!
        return LiveAPIClient(baseURL: base, auth: auth)
    }

    func makeContainer() -> ModelContainer {
        (try? ModelContainer.makeSnapceiptContainer(inMemory: useStub)) ?? makeSnapceiptContainer(inMemory: true)
    }
}
#endif
```

(Use the project's real container factory names — `ModelContainer.makeSnapceiptContainer(inMemory:)` and/or the free `makeSnapceiptContainer(inMemory:)`. Adjust to whichever exists.)

- [ ] **Step 4: Create `Snapceipt/Sync/StubAPIClient.swift`**

```swift
import Foundation

#if DEBUG
/// In-app deterministic APIClient for hermetic XCUITests (selected by -uiTestStub).
/// No network. Returns fixed fixtures for the dev account.
final class StubAPIClient: APIClient {
    private func devSession() -> SessionResponse {
        SessionResponse(accessToken: "stub-access", refreshToken: "stub-refresh", expiresIn: 900,
                        user: SessionUser(id: DevAccount.userId, email: DevAccount.email, displayName: "Dev"))
    }
    func authApple(_ body: AppleAuthBody) async throws -> SessionResponse { devSession() }
    func magicLinkRequest(email: String) async throws {}
    func magicLinkRequestDev(email: String) async throws -> String? { "stub-dev-token" }
    func magicLinkVerify(token: String) async throws -> SessionResponse { devSession() }
    func refresh(refreshToken: String) async throws -> SessionResponse { devSession() }
    func signOut() async throws {}
    func me() async throws -> MeResponse { MeResponse(user: devSession().user, devices: []) }
    func syncPush(deviceId: String, mutations: [PushMutation]) async throws -> PushResponse {
        PushResponse(results: mutations.map { PushResult(mutationId: $0.mutationId, status: "applied", reason: nil, entity: nil) },
                     serverTime: 0)
    }
    func syncPull(cursor: String?, limit: Int) async throws -> PullResponse {
        PullResponse(changes: [], nextCursor: nil, hasMore: false, serverTime: 0)
    }
}
#endif
```

(Adjust the DTO initializers to the real `SessionResponse`/`SessionUser`/`MeResponse`/`PushResult`/`PushResponse`/`PullResponse` shapes in `Sync/DTOs.swift`. `syncPull` returns empty so the dev account lands on Onboarding.)

- [ ] **Step 5: Wire `SnapceiptApp`** (modify the init that builds `api` + the model container)

```swift
// Replace the hardcoded LiveAPIClient + container construction with:
#if DEBUG
let launch = AppLaunch.current
let api: APIClient = launch.makeAPIClient(auth: auth)
let container = launch.makeContainer()
launch.applyResetIfNeeded(authStore: auth)
#else
let api: APIClient = LiveAPIClient(baseURL: URL(string: "https://api.snapceipt.app")!, auth: auth)
let container = (try? ModelContainer.makeSnapceiptContainer()) ?? makeSnapceiptContainer(inMemory: true)
#endif
```

(Preserve the surrounding env-injection from Task 14; only the `api`/`container` construction changes.)

- [ ] **Step 6: Allow local networking** — add to `Snapceipt/Info.plist` (benign in prod: only permits loopback/.local, never weakens HTTPS to the prod host):

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

- [ ] **Step 7: Skip real permission requests under stub** — in `PermissionPrimingView` (and/or `OnboardingView`), guard the actual Camera/Notification request calls:

```swift
#if DEBUG
if AppLaunch.current.useStub { onPrimed(); return }   // don't trigger a system alert in UI tests
#endif
```

(Keep the priming UI; only skip the real `AVCaptureDevice`/`UNUserNotificationCenter` request when stubbed, so no system alert blocks XCUITests. Match the view's real "advance" callback name.)

- [ ] **Step 8: Run unit tests + build (expect pass)**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/AppLaunchTests` → PASS
Then full unit suite stays green: `xcodebuild test ... -only-testing:SnapceiptTests` → all pass; `xcodebuild build ...` → BUILD SUCCEEDED.

- [ ] **Step 9: Commit**

```bash
git add Snapceipt/App/AppLaunch.swift Snapceipt/Sync/StubAPIClient.swift Snapceipt/App/SnapceiptApp.swift Snapceipt/Info.plist Snapceipt/Features/Onboarding/PermissionPrimingView.swift SnapceiptTests/AppLaunchTests.swift
git commit -m "feat(ios): DEBUG launch-arg seam (StubAPIClient + AppLaunch) for UI testing"
```

---

## Task 5: Accessibility identifiers on onboarding, shell, profile switcher

**Files:**
- Modify: `Snapceipt/Features/Onboarding/OnboardingView.swift`
- Modify: `Snapceipt/App/RootView.swift`
- Modify: `Snapceipt/Features/Profiles/ProfileSwitcherHeader.swift`

- [ ] **Step 1: Add ids** — apply `.accessibilityIdentifier(...)` using the `AccessibilityID` constants:
  - Onboarding first-profile form: name `TextField` → `AccessibilityID.onboardingName`; the Personal type control → `.onboardingTypePersonal`; Business → `.onboardingTypeBusiness`; the Create button → `.onboardingCreate`.
  - `RootView` shell: the `TabBar` container → `.shellTabBar`; the Home tab's root content → `.shellHome`.
  - `ProfileSwitcherHeader`: the tappable header → `.profileSwitcher`.

Example (onboarding name field):
```swift
TextField("Profile name", text: $name)
    .accessibilityIdentifier(AccessibilityID.onboardingName)
```

- [ ] **Step 2: Build to verify**

Run: `xcodegen generate && xcodebuild build -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16"`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Snapceipt/Features/Onboarding/OnboardingView.swift Snapceipt/App/RootView.swift Snapceipt/Features/Profiles/ProfileSwitcherHeader.swift
git commit -m "feat(ios): accessibility identifiers for UI tests (onboarding, shell, profile switcher)"
```

---

## Task 6: `SnapceiptUITests` XCUITest target + base case + smoke

**Files:**
- Modify: `project.yml` (new `SnapceiptUITests` target + scheme test action; add `AccessibilityID.swift` to both targets)
- Create: `SnapceiptUITests/UITestCase.swift`
- Create: `SnapceiptUITests/LaunchUITests.swift`

- [ ] **Step 1: Add the UI-test target to `project.yml`** (under `targets:`; add to the `Snapceipt` scheme's `test.targets`). The shared id file is listed in BOTH targets' sources.

```yaml
  SnapceiptUITests:
    type: bundle.ui-testing
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: SnapceiptUITests
      - path: Snapceipt/Shared/AccessibilityID.swift   # shared constants (UI tests can't @testable-import the app)
    dependencies:
      - target: Snapceipt
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.snapceipt.SnapceiptUITests
        GENERATE_INFOPLIST_FILE: YES
        TEST_TARGET_NAME: Snapceipt
```
And in `schemes.Snapceipt.test.targets`, add `SnapceiptUITests`.

- [ ] **Step 2: Create `SnapceiptUITests/UITestCase.swift`** (base + launch helpers)

```swift
import XCTest

class UITestCase: XCTestCase {
    var app: XCUIApplication!
    override func setUp() { super.setUp(); continueAfterFailure = false; app = XCUIApplication() }

    /// Hermetic launch: in-app stub + reset to signed-out/empty.
    func launchStub() { app.launchArguments += ["-uiTestStub", "-uiTestReset"]; app.launch() }

    func tapDevSignIn() {
        let b = app.buttons["signin.dev"]
        XCTAssertTrue(b.waitForExistence(timeout: 10), "Dev sign-in button missing")
        b.tap()
    }
}
```

- [ ] **Step 3: Create `SnapceiptUITests/LaunchUITests.swift`** (proves the target wiring builds + runs)

```swift
import XCTest

final class LaunchUITests: UITestCase {
    func testSignInScreenRenders() {
        launchStub()
        XCTAssertTrue(app.buttons["signin.dev"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["signin.apple"].exists)
    }
}
```

- [ ] **Step 4: Generate + run the UI suite (expect pass)**

Run: `xcodegen generate && xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptUITests/LaunchUITests`
Expected: TEST SUCCEEDED — the app launches in stub mode and the SignIn screen renders. (Confirm existing `SnapceiptTests` still pass: `-only-testing:SnapceiptTests`.)

- [ ] **Step 5: Commit**

```bash
git add project.yml SnapceiptUITests/UITestCase.swift SnapceiptUITests/LaunchUITests.swift
git commit -m "test(ios): add SnapceiptUITests XCUITest target + launch smoke"
```

---

## Task 7: Hermetic end-to-end UI flows

**Files:**
- Create: `SnapceiptUITests/OnboardingUITests.swift`
- Create: `SnapceiptUITests/ShellUITests.swift`

- [ ] **Step 1: `OnboardingUITests` — dev sign-in → onboarding → create profile → shell**

```swift
import XCTest

final class OnboardingUITests: UITestCase {
    func testDevSignInThroughOnboardingToShell() {
        launchStub()
        tapDevSignIn()
        // Onboarding first-profile form
        let name = app.textFields["onboarding.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "Onboarding did not appear")
        name.tap(); name.typeText("Studio North")
        app.buttons["onboarding.type.business"].tap()
        app.buttons["onboarding.create"].tap()
        // Lands on the tabbed shell
        XCTAssertTrue(app.otherElements["shell.tabbar"].waitForExistence(timeout: 10)
                      || app.otherElements["shell.home"].waitForExistence(timeout: 10),
                      "Did not reach the shell after creating a profile")
    }
}
```

(If onboarding has a permission-priming step between Create and the shell, the stubbed build auto-advances it — Task 4 Step 7. If it still shows a "Continue"/"Allow" in-app button, tap it by its id; add that id in Task 5 if needed.)

- [ ] **Step 2: `ShellUITests` — profile switcher opens**

```swift
import XCTest

final class ShellUITests: UITestCase {
    func testProfileSwitcherOpens() {
        launchStub()
        tapDevSignIn()
        // create a profile to reach the shell (reuse the onboarding path)
        let name = app.textFields["onboarding.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap(); name.typeText("Personal")
        app.buttons["onboarding.create"].tap()
        let switcher = app.buttons["profile.switcher"].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        switcher.tap()
        // the picker sheet shows an "Add a profile" affordance / the profile name
        XCTAssertTrue(app.staticTexts["Personal"].waitForExistence(timeout: 5))
    }
}
```

(Adjust the switcher element type — `buttons` vs `otherElements` — to how `ProfileSwitcherHeader` exposes it; if onboarding defaults the type to Personal, no type tap is needed.)

- [ ] **Step 3: Run the hermetic UI suite (expect pass)**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptUITests/OnboardingUITests -only-testing:SnapceiptUITests/ShellUITests -only-testing:SnapceiptUITests/LaunchUITests`
Expected: TEST SUCCEEDED. Iterate on element queries/timeouts until green (use `waitForExistence`, never `sleep`).

- [ ] **Step 4: Commit**

```bash
git add SnapceiptUITests/OnboardingUITests.swift SnapceiptUITests/ShellUITests.swift
git commit -m "test(ios): hermetic e2e UI flows (onboarding→shell, profile switcher)"
```

---

## Task 8: Live-backend smoke test + run docs

**Files:**
- Create: `SnapceiptUITests/LiveSmokeUITests.swift`
- Create: `scripts/ios-e2e-live.sh` (brings up the backend + runs the live smoke)
- Modify: `README.md` (root) — UI-test run instructions

- [ ] **Step 1: `LiveSmokeUITests` (opt-in; skips unless `E2E_LIVE=1`)**

```swift
import XCTest

final class LiveSmokeUITests: UITestCase {
    func testLiveDevSignIn() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["E2E_LIVE"] == "1", "Live smoke disabled (set E2E_LIVE=1 + run wrangler dev).")
        let base = env["API_BASE_URL"] ?? "http://127.0.0.1:8787"
        app.launchArguments += ["-uiTestReset"]            // NO -uiTestStub → real LiveAPIClient
        app.launchEnvironment["API_BASE_URL"] = base
        app.launch()
        tapDevSignIn()
        // Dev sign-in hit the live Worker (E2E_TEST_MODE) → reach onboarding
        XCTAssertTrue(app.textFields["onboarding.name"].waitForExistence(timeout: 20),
                      "Live dev sign-in did not reach onboarding (is wrangler dev up with E2E_TEST_MODE=1?)")
    }
}
```

- [ ] **Step 2: Create `scripts/ios-e2e-live.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
PERSIST=$(mktemp -d)
CI=1 npx wrangler d1 migrations apply snapceipt --local --persist-to "$PERSIST"
npx wrangler dev --local --persist-to "$PERSIST" --port 8787 --ip 127.0.0.1 \
  --var E2E_TEST_MODE:1 --var JWT_SIGNING_KEY:dev-e2e-signing-key-0123456789-abcdef --var APPLE_BUNDLE_ID:com.snapceipt.app \
  > /tmp/snapceipt-e2e-wrangler.log 2>&1 &
WPID=$!; trap 'kill $WPID 2>/dev/null; rm -rf "$PERSIST"' EXIT
until curl -sf http://127.0.0.1:8787/health >/dev/null; do sleep 0.5; done
xcodegen generate
E2E_LIVE=1 API_BASE_URL=http://127.0.0.1:8787 \
  xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" \
  -only-testing:SnapceiptUITests/LiveSmokeUITests
```
`chmod +x scripts/ios-e2e-live.sh`.

- [ ] **Step 3: Document in `README.md`** (append an "iOS UI tests" section):

```markdown
## iOS UI tests
- Hermetic suite (no backend): `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptUITests` (LiveSmokeUITests XCTSkips by default).
- Live smoke (real Worker): `./scripts/ios-e2e-live.sh` — starts `wrangler dev` (E2E_TEST_MODE) and runs LiveSmokeUITests against it.
```

- [ ] **Step 4: Verify the live smoke skips by default, then runs live**

Run (skips, no backend): `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptUITests/LiveSmokeUITests` → reports **skipped**.
Run (live): `./scripts/ios-e2e-live.sh` → TEST SUCCEEDED (the app authenticates against the live Worker).

- [ ] **Step 5: Commit**

```bash
git add SnapceiptUITests/LiveSmokeUITests.swift scripts/ios-e2e-live.sh README.md
git commit -m "test(ios): live-backend smoke UI test + run script/docs"
```

---

## Done when

The hermetic `SnapceiptUITests` suite (launch, onboarding→shell, profile switcher) is green via `xcodebuild test -only-testing:SnapceiptUITests`; `LiveSmokeUITests` skips by default and passes via `scripts/ios-e2e-live.sh`; the existing 121 unit tests + the new dev-sign-in/AppLaunch unit tests pass; and every added surface is `#if DEBUG` (Release build unaffected).
