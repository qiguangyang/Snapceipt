# Snapceipt iOS End-to-End Testing — Design Spec

- **Status:** Approved (brainstorm) — proceeding to implementation plan
- **Date:** 2026-05-30
- **Branch:** `foundation`
- **Builds on:** the iOS app foundation (`Snapceipt/` + `SnapceiptTests/`, XcodeGen `project.yml`) and the Cloudflare backend (root `src/`, with the `E2E_TEST_MODE` magic-link dev-token seam).

---

## 1. Goal

Add **XCUITest end-to-end UI tests** that launch the real Snapceipt app in the simulator and drive the real screens through the core flow — **sign-in → onboarding → create first profile → tabbed shell** — in two modes:

1. **Hermetic suite (default / CI):** the app runs against an in-app `StubAPIClient` + an in-memory store, toggled by a launch argument. Fast, deterministic, no backend process.
2. **Live smoke (opt-in):** one test runs against a live local `wrangler dev`, exercising the real app↔Worker HTTP path. Skipped unless explicitly enabled.

A **DEBUG-only "Dev sign in" button** on the login screen is the enabler: it signs into a fixed dev account in one tap (reusing the backend's `E2E_TEST_MODE` magic-link dev-token seam), so a UI test gets past the login gate deterministically.

**Non-goals:** snapshot/pixel testing; testing later-phase screens (capture, reports, budgets, loyalty — those are stubs); CI pipeline config (documented, not wired).

## 2. Safety (all test-only surfaces are double-gated)

Every affordance added here is compiled out of Release/App Store builds:
- The dev button, `AuthViewModel.devSignIn()`, `StubAPIClient`, the launch-arg seam, and the `API_BASE_URL`/local-HTTP overrides are all wrapped in **`#if DEBUG`**.
- The backend `devToken` is emitted only when `E2E_TEST_MODE === "1"` (never in production).
- The `SnapceiptUITests` target is a test bundle — never shipped.

## 3. Architecture & components

### 3.1 Dev sign-in (the enabler)
- `APIClient.magicLinkRequestDev(email:) async throws -> String?` — POSTs `/auth/magic-link/request` and returns the `devToken` from the 202 body (present only when the backend has `E2E_TEST_MODE=1`; else `nil`). Implemented in `LiveAPIClient`, `StubAPIClient`, and `MockAPIClient` (tests).
- `AuthViewModel.devSignIn()` (`#if DEBUG`): calls `magicLinkRequestDev(DevAccount.email)`; on a token → `verifyMagicLink(token)` → real session + working sync (existing path → onboarding if no profile). On `nil`/error → `.error` state with a clear message ("Dev sign-in needs the backend in dev mode (E2E_TEST_MODE)" / a network message).
- `SignInView` (`#if DEBUG`): a subdued button under "Continue with email" — **"🔧 Dev sign in"** → `authVM.devSignIn()`; surfaces the error inline on the SignIn screen.

### 3.2 Launch-arg test seam (`#if DEBUG`, in `SnapceiptApp`)
A small `AppLaunch` helper reads `ProcessInfo.processInfo.arguments` / `.environment` once at launch and decides what `SnapceiptApp` builds:
- `-uiTestStub` → use `StubAPIClient` (canned responses) instead of `LiveAPIClient`, and an **in-memory** `makeSnapceiptContainer(inMemory: true)` so each run is clean.
- `-uiTestReset` → start signed-out with empty Keychain/UserDefaults state (clears the dev-namespaced auth/profile keys) so onboarding shows.
- env `API_BASE_URL` → build `LiveAPIClient(baseURL:)` pointing there (for the live smoke). DEBUG-only; pairs with a DEBUG-only ATS local-networking allowance so the simulator can reach `http://127.0.0.1:8787`.
- Production / no flags → unchanged (`LiveAPIClient` at the production base URL, on-disk container).

### 3.3 `StubAPIClient` (`#if DEBUG`, in the app target)
Because XCUITests run in a *separate* process and can't inject code into the app, the stub lives **in the app** (under `#if DEBUG`) and is selected by `-uiTestStub`. It conforms to `APIClient` and returns deterministic fixtures: a fixed dev `SessionResponse`; `magicLinkRequestDev` → a fixed token; `magicLinkVerify` → the dev session; `me` → the dev user + one device; `syncPush` → all `applied` (echoing input, rev 1); `syncPull` → a small canned change set (or empty, to drive onboarding). Fixtures are simple `static` values; no network.

### 3.4 Accessibility identifiers
A shared `AccessibilityID` enum of string constants, compiled into **both** the app target and the `SnapceiptUITests` target (XcodeGen `sources` lists the one file in both), so tests reference symbols, not magic strings. Identifiers (pinned in §5): the dev button, the onboarding name field + type toggles + Create button, a shell/Home marker, and the profile-switcher header. Applied via `.accessibilityIdentifier(...)` on the relevant views.

### 3.5 `SnapceiptUITests` target (XCUITest)
New `bundle.ui-testing` target in `project.yml`, depending on `Snapceipt`, added to the scheme's test action.
- **Hermetic tests** (launch with `-uiTestStub -uiTestReset`):
  - `SignInUITests.testSignInScreenRenders` — assert the Apple button, email field, and Dev sign-in button exist.
  - `OnboardingUITests.testDevSignInThroughOnboardingToShell` — tap Dev sign-in → Onboarding appears → enter a profile name, pick a type, tap Create (+ advance any permission-priming step) → assert the tab bar / Home marker appears.
  - `ShellUITests.testProfileSwitcherOpens` — from the signed-in shell (seeded), tap the profile switcher → assert the picker sheet.
- **Live smoke** (`LiveSmokeUITests.testLiveDevSignIn`): reads test env `E2E_LIVE` + `API_BASE_URL`; if unset → `throw XCTSkip(...)`. Else launches the app with `launchEnvironment["API_BASE_URL"]` set and `-uiTestReset` (NO `-uiTestStub` → real `LiveAPIClient`), taps Dev sign-in, asserts it reaches Onboarding/shell (the app really hit the local Worker).

## 4. File structure

```
Snapceipt/App/AppLaunch.swift                 # DEBUG: parse launch args/env → choose APIClient + container
Snapceipt/App/SnapceiptApp.swift              # MODIFY: use AppLaunch to build api + container
Snapceipt/Sync/StubAPIClient.swift            # DEBUG: canned APIClient for -uiTestStub
Snapceipt/Sync/APIClient.swift                # MODIFY: add magicLinkRequestDev(email:) to protocol + LiveAPIClient
Snapceipt/Features/Auth/AuthViewModel.swift   # MODIFY: add devSignIn() (#if DEBUG)
Snapceipt/Features/Auth/SignInView.swift      # MODIFY: add #if DEBUG dev button + inline error
Snapceipt/Shared/AccessibilityID.swift        # NEW: shared id constants (app + UITest targets)
Snapceipt/Features/Onboarding/OnboardingView.swift  # MODIFY: a11y ids on name field/type/Create
Snapceipt/App/RootView.swift                  # MODIFY: a11y id on the shell/Home marker
Snapceipt/Features/Profiles/ProfileSwitcherHeader.swift  # MODIFY: a11y id
SnapceiptTests/Mocks/MockAPIClient.swift      # MODIFY: implement magicLinkRequestDev
SnapceiptTests/AuthViewModelTests.swift       # MODIFY: devSignIn() unit tests
SnapceiptUITests/{SignInUITests,OnboardingUITests,ShellUITests,LiveSmokeUITests}.swift  # NEW
SnapceiptUITests/UITestCase.swift             # NEW: base XCTestCase (launch helpers)
project.yml                                   # MODIFY: SnapceiptUITests target + scheme test action; AccessibilityID.swift in both targets
README/run docs                               # MODIFY: how to run hermetic vs live UI tests
```

## 5. Canonical Contracts (authoritative — keep the plan/implementers consistent)

- **Launch args (Bool):** `"-uiTestStub"`, `"-uiTestReset"`. **Launch env (String):** `"API_BASE_URL"` (app reads), `"E2E_LIVE"` (the UI test reads to decide skip). The dev account is `DevAccount.email = "dev@snapceipt.app"`.
- **`AppLaunch`** (`#if DEBUG`) exposes `static var useStub: Bool`, `static var reset: Bool`, `static var apiBaseURLOverride: URL?`, and a `static func makeAPIClient(auth:) -> APIClient` + `static func makeContainer() -> ModelContainer` used by `SnapceiptApp`. In non-DEBUG, `SnapceiptApp` uses the production `LiveAPIClient` + on-disk container directly (no `AppLaunch`).
- **`APIClient.magicLinkRequestDev(email: String) async throws -> String?`** — return the dev token or `nil`. (Prod backend → `nil`; `StubAPIClient` → a fixed non-nil token; `LiveAPIClient` → decodes `{ devToken }`.)
- **`StubAPIClient`** is `#if DEBUG`, conforms to `APIClient`, returns the fixtures in §3.3. Its dev session user id = `DevAccount.userId` (a fixed UUID).
- **`AccessibilityID`** string constants (used by `.accessibilityIdentifier` and the tests):
  `signInApple="signin.apple"`, `signInEmail="signin.email"`, `signInDev="signin.dev"`,
  `onboardingName="onboarding.name"`, `onboardingTypePersonal="onboarding.type.personal"`, `onboardingTypeBusiness="onboarding.type.business"`, `onboardingCreate="onboarding.create"`,
  `shellTabBar="shell.tabbar"`, `shellHome="shell.home"`, `profileSwitcher="profile.switcher"`.
- **XCUITest launch:** the base case does `app.launchArguments += ["-uiTestStub","-uiTestReset"]; app.launch()`. The live case sets `app.launchEnvironment["API_BASE_URL"]` + `app.launchArguments += ["-uiTestReset"]` (no `-uiTestStub`).
- **`devSignIn()` failure UX:** sets `AuthViewModel.state = .error(message)` with `pendingEmail = nil` so RootView keeps showing `SignInView`; `SignInView` renders the error text near the dev button.

## 6. Testing & running

- **Unit tests** (existing 121, unchanged) + the new `devSignIn()` unit tests run via `xcodebuild test -only-testing:SnapceiptTests`.
- **Hermetic UI suite:** `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptUITests` (excludes the live smoke via its `XCTSkip`). No backend.
- **Live smoke:** start `wrangler dev` (with `E2E_TEST_MODE=1`, migrated local D1), then `E2E_LIVE=1 API_BASE_URL=http://127.0.0.1:8787 xcodebuild test ... -only-testing:SnapceiptUITests/LiveSmokeUITests` (passes the env through to the test, which forwards to the app launch). Document the one-time backend bring-up.

## 7. Risks / notes

- **XCUITest flakiness:** use `waitForExistence(timeout:)` on elements (no fixed sleeps); the hermetic stub removes network timing from the equation.
- **Permission priming in onboarding:** the onboarding flow primes Camera/Notifications — the test must handle/skip any system permission alert (use `addUIInterruptionMonitor` or ensure the priming step is dismissible without a system dialog in test mode; if a system alert blocks, gate the actual permission request out under `-uiTestStub`).
- **Keychain reset between tests:** `-uiTestReset` clears the dev-namespaced auth/profile keys at launch so each test starts signed-out; the in-memory container guarantees empty SwiftData.
- **Live smoke is opt-in** and `XCTSkip`s by default, so the default `xcodebuild test` stays green without a backend.
