# F7 Settings — iOS Account & Security Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Account & security surface: the four account `APIClient` methods on all four conformers, an `AccountViewModel` + Account screen (change email via 6-digit code, device list + revoke, delete account), and a biometric `AppLockController` + Privacy screen that gates the app on launch + foreground.

**Architecture:** Four new `APIClient` methods wrap the §8 backend endpoints. `AccountViewModel` (`@Observable @MainActor`) drives the change-email code flow, the device list (from `me()`), revoke, and delete (which clears the session). `AppLockController` (`@Observable @MainActor`, injected biometric evaluator for testability) drives a lock-screen gate wrapped around the authed shell. New `Router` overlays (`.account`, `.privacy`, `.changeEmail`) reached from the F7 hub.

**Tech Stack:** SwiftUI + SwiftData, LocalAuthentication, Swift Testing + XCUITest, XcodeGen.

**Authoritative contract:** §8 (backend) + §6 (Face ID) of `docs/superpowers/specs/2026-06-02-settings-design.md`. The backend is built by `2026-06-02-settings-backend.md`. **Depends on** the iOS-config plan (`2026-06-02-settings-ios-config.md`) for the hub + the `.privacy`/`.account` row seam it left.

**Baseline:** iOS unit (319 + the config plan's additions) / UI (12 + config). Build/test as in the config plan (`xcodegen generate` first; iPhone 16; `-only-testing` by TYPE name; never `git add Snapceipt.xcodeproj`; trust `xcodebuild`; commit trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`; do NOT push).

**Reuse exemplars:** `Snapceipt/Sync/APIClient.swift` (`send`/`sendNoContent`/`makeRequest`/`NoBody`), `StubAPIClient.swift`, `Features/Auth/SignInView.swift` (PreviewAPIClient), `SnapceiptTests/Mocks/MockAPIClient.swift`, `Features/Notifications/NotificationsSettingsView.swift` (screen template), `Sync/AuthStore.swift` (`clear()`), `Sync/DTOs.swift` (`MeResponse`/`DeviceDTO`/`SessionUser`).

---

### Task 1: DTOs + 4 `APIClient` methods (all four conformers)

**Files:**
- Modify: `Snapceipt/Sync/DTOs.swift` (add request/response DTOs; extend `DeviceDTO`)
- Modify: `Snapceipt/Sync/APIClient.swift` (protocol + `LiveAPIClient`)
- Modify: `Snapceipt/Sync/StubAPIClient.swift`, `Snapceipt/Features/Auth/SignInView.swift` (Preview), `SnapceiptTests/Mocks/MockAPIClient.swift`
- Test: `SnapceiptTests/AccountDTOTests.swift`

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/AccountDTOTests.swift`:

```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("Account DTOs + APIClient")
struct AccountDTOTests {
    @Test("EmailChangeRequested + AccountUser decode")
    func decode() throws {
        let r = try JSONDecoder().decode(EmailChangeRequested.self, from: Data(#"{"sent":true,"devCode":"123456"}"#.utf8))
        #expect(r.sent == true); #expect(r.devCode == "123456")
        let wrap = try JSONDecoder().decode(AccountUserResponse.self, from: Data(#"{"user":{"id":"u","email":"new@e.com","displayName":"You","plan":"free"}}"#.utf8))
        #expect(wrap.user.email == "new@e.com"); #expect(wrap.user.plan == "free")
    }

    @Test("rich DeviceDTO decodes the /auth/me device fields")
    func device() throws {
        let json = #"{"id":"d1","platform":"ios","model":"iPhone","osVersion":"18.0","hasApnsToken":true,"pushEnabled":true,"lastSeenAt":123,"createdAt":1}"#
        let d = try JSONDecoder().decode(DeviceDTO.self, from: Data(json.utf8))
        #expect(d.id == "d1"); #expect(d.model == "iPhone"); #expect(d.pushEnabled == true)
    }

    @MainActor
    @Test("MockAPIClient records the 4 account calls")
    func mock() async throws {
        let m = MockAPIClient()
        m.requestEmailChangeHandler = { EmailChangeRequested(sent: true, devCode: "000000") }
        m.verifyEmailChangeHandler = { _ in AccountUser(id: "u", email: "n@e.com", displayName: "Y", plan: "free") }
        _ = try await m.requestEmailChange(newEmail: "n@e.com")
        _ = try await m.verifyEmailChange(code: "000000")
        try await m.revokeDevice(id: "d1")
        try await m.deleteAccount()
        #expect(m.requestEmailChangeCalls == ["n@e.com"])
        #expect(m.verifyEmailChangeCalls == ["000000"])
        #expect(m.revokeDeviceCalls == ["d1"])
        #expect(m.deleteAccountCallCount == 1)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild build-for-testing -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD FAILS — types/methods unknown.

- [ ] **Step 3: Add DTOs in `DTOs.swift`**

Replace the existing minimal `DeviceDTO` with a richer one (the server already sends these fields) and add the account types:

```swift
struct DeviceDTO: Decodable, Equatable {
    let id: String
    var platform: String? = nil
    var model: String? = nil
    var osVersion: String? = nil
    var hasApnsToken: Bool? = nil
    var pushEnabled: Bool? = nil
    var lastSeenAt: Int? = nil
    var createdAt: Int? = nil
}

struct EmailChangeBody: Encodable { let newEmail: String }
struct VerifyCodeBody: Encodable { let code: String }
struct EmailChangeRequested: Decodable, Equatable { let sent: Bool; let devCode: String? }
struct AccountUser: Decodable, Equatable { let id: String; let email: String?; let displayName: String?; let plan: String }
struct AccountUserResponse: Decodable, Equatable { let user: AccountUser }
```

(If `DeviceDTO` had a custom memberwise call elsewhere, the added defaults keep it source-compatible. Confirm `MeResponse` still compiles.)

- [ ] **Step 4: Add the protocol methods + LiveAPIClient impls**

In `APIClient.swift` protocol (after `rotateProfileInbox`):

```swift
    func requestEmailChange(newEmail: String) async throws -> EmailChangeRequested
    func verifyEmailChange(code: String) async throws -> AccountUser
    func revokeDevice(id: String) async throws
    func deleteAccount() async throws
```

In `LiveAPIClient`:

```swift
    func requestEmailChange(newEmail: String) async throws -> EmailChangeRequested {
        try await send("POST", "/users/me/email", body: EmailChangeBody(newEmail: newEmail), authenticated: true)
    }
    func verifyEmailChange(code: String) async throws -> AccountUser {
        let wrap: AccountUserResponse = try await send("POST", "/users/me/email/verify", body: VerifyCodeBody(code: code), authenticated: true)
        return wrap.user
    }
    func revokeDevice(id: String) async throws {
        try await sendNoContent("DELETE", "/devices/\(id)", body: NoBody(), authenticated: true)
    }
    func deleteAccount() async throws {
        try await sendNoContent("DELETE", "/account", body: NoBody(), authenticated: true)
    }
```

(Confirm `sendNoContent` exists — the explore showed it; if not, add it mirroring `send` but discarding the decoded body.)

- [ ] **Step 5: Add to StubAPIClient + PreviewAPIClient**

In both (Stub in `StubAPIClient.swift`, Preview in `SignInView.swift`):

```swift
    func requestEmailChange(newEmail: String) async throws -> EmailChangeRequested {
        EmailChangeRequested(sent: true, devCode: "000000")
    }
    func verifyEmailChange(code: String) async throws -> AccountUser {
        AccountUser(id: DevAccount.userId, email: "new@example.com", displayName: "Dev", plan: "free")
    }
    func revokeDevice(id: String) async throws {}
    func deleteAccount() async throws {}
```

(Preview can use `"u"` ids matching its other stubs.)

- [ ] **Step 6: Add to MockAPIClient**

```swift
    var requestEmailChangeHandler: (() async throws -> EmailChangeRequested)?
    var verifyEmailChangeHandler: ((String) async throws -> AccountUser)?
    private(set) var requestEmailChangeCalls: [String] = []
    private(set) var verifyEmailChangeCalls: [String] = []
    private(set) var revokeDeviceCalls: [String] = []
    private(set) var deleteAccountCallCount = 0

    func requestEmailChange(newEmail: String) async throws -> EmailChangeRequested {
        requestEmailChangeCalls.append(newEmail)
        guard let h = requestEmailChangeHandler else { throw MockAPIClientError.unscripted }
        return try await h()
    }
    func verifyEmailChange(code: String) async throws -> AccountUser {
        verifyEmailChangeCalls.append(code)
        guard let h = verifyEmailChangeHandler else { throw MockAPIClientError.unscripted }
        return try await h(code)
    }
    func revokeDevice(id: String) async throws { revokeDeviceCalls.append(id) }
    func deleteAccount() async throws { deleteAccountCallCount += 1 }
```

- [ ] **Step 7: Run to verify it passes**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/AccountDTOTests'`
Expected: PASS (3 tests). The full app + test target compile (all four conformers satisfy the protocol).

- [ ] **Step 8: Commit**

```bash
git add Snapceipt/Sync/DTOs.swift Snapceipt/Sync/APIClient.swift Snapceipt/Sync/StubAPIClient.swift Snapceipt/Features/Auth/SignInView.swift SnapceiptTests/Mocks/MockAPIClient.swift SnapceiptTests/AccountDTOTests.swift
git commit -m "$(cat <<'EOF'
feat(F7 iOS): account DTOs + requestEmailChange/verify/revokeDevice/deleteAccount on all 4 APIClients

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `AccountViewModel`

**Files:**
- Create: `Snapceipt/Features/Account/AccountViewModel.swift`
- Test: `SnapceiptTests/AccountViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/AccountViewModelTests.swift`:

```swift
import Testing
import Foundation
@testable import Snapceipt

@MainActor
@Suite("AccountViewModel")
struct AccountViewModelTests {
    private func vm(_ api: MockAPIClient) -> (AccountViewModel, AuthStore, Box) {
        let auth = AuthStore(keychain: Keychain(service: "test.\(UUID().uuidString)"))
        auth.save(SessionResponse(accessToken: "a", refreshToken: "r", expiresIn: 900,
                                  user: SessionUser(id: "u1", email: "old@e.com", displayName: "You")))
        let box = Box()
        let model = AccountViewModel(api: api, auth: auth, currentDeviceId: "thisDevice", onSignedOut: { box.signedOut = true })
        return (model, auth, box)
    }
    final class Box { var signedOut = false }

    @Test("change email: request then verify updates the session email")
    func changeEmail() async throws {
        let api = MockAPIClient()
        api.requestEmailChangeHandler = { EmailChangeRequested(sent: true, devCode: "000000") }
        api.verifyEmailChangeHandler = { _ in AccountUser(id: "u1", email: "new@e.com", displayName: "You", plan: "free") }
        let (m, auth, _) = vm(api)
        m.newEmail = "new@e.com"
        await m.requestCode()
        #expect(m.codeSent == true)
        m.code = "000000"
        await m.verifyCode()
        #expect(m.codeSent == false)
        #expect(auth.session?.email == "new@e.com")
        #expect(api.verifyEmailChangeCalls == ["000000"])
    }

    @Test("loadDevices populates from me()")
    func devices() async throws {
        let api = MockAPIClient()
        api.meHandler = { MeResponse(user: SessionUser(id: "u1", email: "old@e.com", displayName: "You"),
                                     devices: [DeviceDTO(id: "thisDevice"), DeviceDTO(id: "other")]) }
        let (m, _, _) = vm(api)
        await m.loadDevices()
        #expect(m.devices.count == 2)
    }

    @Test("revoking a non-current device reloads; revoking current signs out")
    func revoke() async throws {
        let api = MockAPIClient()
        api.meHandler = { MeResponse(user: SessionUser(id: "u1", email: "old@e.com", displayName: "You"), devices: [DeviceDTO(id: "other")]) }
        let (m, _, box) = vm(api)
        await m.revoke("other")
        #expect(api.revokeDeviceCalls == ["other"])
        #expect(box.signedOut == false)
        await m.revoke("thisDevice")
        #expect(box.signedOut == true)
    }

    @Test("deleteAccount clears the session and signs out")
    func delete() async throws {
        let api = MockAPIClient()
        let (m, auth, box) = vm(api)
        await m.deleteAccount()
        #expect(api.deleteAccountCallCount == 1)
        #expect(auth.session == nil)
        #expect(box.signedOut == true)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild build-for-testing -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD FAILS — `AccountViewModel` unknown.

- [ ] **Step 3: Implement `AccountViewModel.swift`**

```swift
import Foundation

@Observable
@MainActor
final class AccountViewModel {
    @ObservationIgnored private let api: any APIClient
    @ObservationIgnored private let auth: AuthStore
    @ObservationIgnored private let currentDeviceId: String
    @ObservationIgnored private let onSignedOut: () -> Void

    var email: String? { auth.session?.email }
    private(set) var devices: [DeviceDTO] = []

    // Change-email flow
    var newEmail = ""
    var code = ""
    private(set) var codeSent = false
    var errorMessage: String?
    private(set) var busy = false

    init(api: any APIClient, auth: AuthStore, currentDeviceId: String, onSignedOut: @escaping () -> Void) {
        self.api = api
        self.auth = auth
        self.currentDeviceId = currentDeviceId
        self.onSignedOut = onSignedOut
    }

    func requestCode() async {
        let target = newEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard target.contains("@"), target.contains(".") else { errorMessage = "Enter a valid email."; return }
        busy = true; errorMessage = nil; defer { busy = false }
        do { _ = try await api.requestEmailChange(newEmail: target); codeSent = true }
        catch { errorMessage = "Couldn't send the code. " + friendly(error) }
    }

    func verifyCode() async {
        busy = true; errorMessage = nil; defer { busy = false }
        do {
            let user = try await api.verifyEmailChange(code: code.trimmingCharacters(in: .whitespaces))
            auth.updateEmail(user.email)   // see Step 4
            codeSent = false; code = ""; newEmail = ""
        } catch { errorMessage = "That code didn't work. " + friendly(error) }
    }

    func loadDevices() async {
        do { devices = try await api.me().devices } catch { errorMessage = "Couldn't load devices." }
    }

    func revoke(_ id: String) async {
        do {
            try await api.revokeDevice(id: id)
            if id == currentDeviceId { signOut() } else { await loadDevices() }
        } catch { errorMessage = "Couldn't sign that device out." }
    }

    func deleteAccount() async {
        busy = true; errorMessage = nil; defer { busy = false }
        do { try await api.deleteAccount(); signOut() }
        catch { errorMessage = "Couldn't delete the account. " + friendly(error) }
    }

    var currentDevice: String { currentDeviceId }

    private func signOut() {
        auth.clear()
        onSignedOut()
    }
    private func friendly(_ e: Error) -> String {
        if let a = e as? APIError { return a.message }
        return "Please try again."
    }
}
```

- [ ] **Step 4: Add `AuthStore.updateEmail`**

In `Snapceipt/Sync/AuthStore.swift`, add a small mutator (the session struct is value-type, so rebuild it + re-persist the user blob):

```swift
/// Update the in-memory + persisted email after a confirmed change.
func updateEmail(_ email: String?) {
    guard var s = session else { return }
    s.email = email
    session = s
    persistUser(PersistedUser(id: s.userId, email: email, displayName: s.displayName))
}
```

(`persistUser`/`PersistedUser` are private in the file — add the method inside `AuthStore` so it can call them.)

- [ ] **Step 5: Run to verify it passes**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/AccountViewModelTests'`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Snapceipt/Features/Account/AccountViewModel.swift Snapceipt/Sync/AuthStore.swift SnapceiptTests/AccountViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(F7 iOS): AccountViewModel (change email, device list/revoke, delete)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `AppLockController` (Face ID)

**Files:**
- Create: `Snapceipt/Features/Account/AppLockController.swift`
- Test: `SnapceiptTests/AppLockControllerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/AppLockControllerTests.swift`:

```swift
import Testing
import Foundation
@testable import Snapceipt

@MainActor
@Suite("AppLockController")
struct AppLockControllerTests {
    private func make(enabled: Bool, canEval: Bool, evalResult: Bool) -> AppLockController {
        let defaults = UserDefaults(suiteName: "lock.\(UUID().uuidString)")!
        defaults.set(enabled, forKey: "sc.lock.enabled")
        return AppLockController(defaults: defaults, canEvaluate: { canEval }, evaluate: { evalResult })
    }

    @Test("enabled + available locks on launch and unlocks on success")
    func lockUnlock() async {
        let c = make(enabled: true, canEval: true, evalResult: true)
        c.lockIfEnabled()
        #expect(c.isLocked == true)
        await c.unlock()
        #expect(c.isLocked == false)
    }

    @Test("disabled never locks")
    func disabled() {
        let c = make(enabled: false, canEval: true, evalResult: true)
        c.lockIfEnabled()
        #expect(c.isLocked == false)
    }

    @Test("failed biometric stays locked")
    func failed() async {
        let c = make(enabled: true, canEval: true, evalResult: false)
        c.lockIfEnabled()
        await c.unlock()
        #expect(c.isLocked == true)
    }

    @Test("setEnabled(true) requires a successful check; canEvaluate=false refuses")
    func enabling() async {
        let ok = make(enabled: false, canEval: true, evalResult: true)
        await ok.setEnabled(true)
        #expect(ok.isEnabled == true)

        let noBio = make(enabled: false, canEval: false, evalResult: true)
        #expect(noBio.isAvailable == false)
        await noBio.setEnabled(true)
        #expect(noBio.isEnabled == false)   // refused; no biometry/passcode
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild build-for-testing -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD FAILS — `AppLockController` unknown.

- [ ] **Step 3: Implement `AppLockController.swift`**

```swift
import Foundation
import LocalAuthentication

@Observable
@MainActor
final class AppLockController {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let canEvaluate: () -> Bool
    @ObservationIgnored private let evaluate: () async -> Bool
    @ObservationIgnored private static let key = "sc.lock.enabled"

    private(set) var isEnabled: Bool
    private(set) var isLocked = false

    /// True when the device can do biometric/passcode auth.
    var isAvailable: Bool { canEvaluate() }

    init(defaults: UserDefaults = .standard,
         canEvaluate: (() -> Bool)? = nil,
         evaluate: (() async -> Bool)? = nil) {
        self.defaults = defaults
        self.canEvaluate = canEvaluate ?? {
            var err: NSError?
            return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
        }
        self.evaluate = evaluate ?? {
            await withCheckedContinuation { cont in
                LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Snapceipt") { ok, _ in
                    cont.resume(returning: ok)
                }
            }
        }
        self.isEnabled = defaults.bool(forKey: Self.key)
    }

    /// Lock now if the feature is enabled (call on cold launch + background→active).
    func lockIfEnabled() { isLocked = isEnabled }

    /// Attempt to unlock via biometrics; clears the lock on success.
    func unlock() async {
        if await evaluate() { isLocked = false }
    }

    /// Toggle the lock. Turning ON requires biometrics to be available AND a
    /// successful check (so the user can't lock themselves out).
    func setEnabled(_ on: Bool) async {
        if on {
            guard isAvailable, await evaluate() else { isEnabled = false; defaults.set(false, forKey: Self.key); return }
            isEnabled = true
        } else {
            isEnabled = false
            isLocked = false
        }
        defaults.set(isEnabled, forKey: Self.key)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/AppLockControllerTests'`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Account/AppLockController.swift SnapceiptTests/AppLockControllerTests.swift
git commit -m "$(cat <<'EOF'
feat(F7 iOS): AppLockController (biometric gate, injected evaluator)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Router `.account`/`.privacy`/`.changeEmail` + AccessibilityIDs + hub seam

**Files:**
- Modify: `Snapceipt/App/Router.swift`, `Snapceipt/Shared/AccessibilityID.swift`
- Modify: `Snapceipt/App/RootView.swift` (replace the config plan's Privacy/Account no-op seam with real `router.present(.privacy)` / `.account`)

- [ ] **Step 1: Add overlay cases** to `Router.swift` `Overlay` enum + `id` switch:

```swift
    case account
    case privacy
    case changeEmail
```
```swift
        case .account: return "account"
        case .privacy: return "privacy"
        case .changeEmail: return "changeEmail"
```

- [ ] **Step 2: Add AccessibilityIDs** to `AccessibilityID.swift`:

```swift
    // Account & privacy (F7)
    static let accountScreen = "account.screen"
    static let accountEmailRow = "account.email.row"
    static let accountChangeEmail = "account.change.email"
    static let accountDeviceRowPrefix = "account.device.row."   // + device.id
    static let accountRevokePrefix = "account.revoke."          // + device.id
    static let accountDeleteButton = "account.delete"
    static let accountDeleteConfirmField = "account.delete.confirm.field"
    static let accountDeleteConfirmButton = "account.delete.confirm.button"
    static let changeEmailScreen = "changeemail.screen"
    static let changeEmailField = "changeemail.field"
    static let changeEmailSend = "changeemail.send"
    static let changeEmailCodeField = "changeemail.code.field"
    static let changeEmailVerify = "changeemail.verify"
    static let privacyScreen = "privacy.screen"
    static let privacyAppLockToggle = "privacy.applock.toggle"
```

- [ ] **Step 3: Wire the hub rows** (in `RootView.swift`, the `ProfileTabView(...)` construction from the config plan): set `onOpenPrivacy: { router.present(.privacy) }` and `onOpenAccount: { router.present(.account) }` (replacing the config plan's `// TODO(account-plan)` no-ops).

- [ ] **Step 4: Build to confirm it compiles** (overlays added in Task 5; ensure the new `Overlay` cases are in `RootView`'s `sheetContent` EmptyView arm so an exhaustive switch compiles):

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild build-for-testing -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDS.

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/App/Router.swift Snapceipt/Shared/AccessibilityID.swift Snapceipt/App/RootView.swift
git commit -m "$(cat <<'EOF'
feat(F7 iOS): account/privacy/changeEmail routes + hub wiring

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Account / ChangeEmail / Privacy screens + overlay wiring

**Files:**
- Create: `Snapceipt/Features/Account/AccountView.swift`, `ChangeEmailView.swift`, `PrivacyView.swift`
- Modify: `Snapceipt/App/RootView.swift` (the three overlay blocks)

Screens mirror `NotificationsSettingsView` (SheetHeader + grouped `Card`s). No new unit tests (VMs covered); verified by build + Task 7's UI test.

- [ ] **Step 1: `AccountView`** — builds an `AccountViewModel` (inject `captureAPI`, `auth`, `auth.deviceId` as `currentDeviceId`, and `onSignedOut: { Task { await authVM.signOut() } }` — pass `authVM` in or a closure from RootView). Sections:
  - **Email**: a row showing `vm.email ?? "—"` (`accountEmailRow`) + a "Change email" button (`accountChangeEmail` → `onChangeEmail()` which routes to `.changeEmail`).
  - **Devices**: `.task { await vm.loadDevices() }`; a row per `vm.devices` (`accountDeviceRowPrefix + d.id`) showing model/platform + lastSeen, with a "Sign out" button (`accountRevokePrefix + d.id`) → a `confirmationDialog` → `vm.revoke(d.id)`. Mark the current device ("This device").
  - **Danger zone**: a "Delete account" button (`accountDeleteButton`, `Palette.alert`) → presents the delete confirm (a `.sheet` or inline section) with a `TextField` (`accountDeleteConfirmField`) and a destructive "Delete account" button (`accountDeleteConfirmButton`) `.disabled(confirmText != "DELETE")` → `Task { await vm.deleteAccount() }`. Show `vm.errorMessage` inline.
  Root id `accountScreen`. `SheetHeader(title: "Account", onClose:)`.

- [ ] **Step 2: `ChangeEmailView`** — shares the `AccountViewModel` (pass it in, or build one) and presents the two-step flow: a `newEmail` `TextField` (`changeEmailField`, keyboard `.emailAddress`) + "Send code" (`changeEmailSend` → `vm.requestCode()`); once `vm.codeSent`, a `code` `TextField` (`changeEmailCodeField`, number pad) + "Verify" (`changeEmailVerify` → `vm.verifyCode()` then `onClose()`); show `vm.errorMessage` inline. Root id `changeEmailScreen`.

- [ ] **Step 3: `PrivacyView`** — a toggle "Require Face ID / Touch ID to unlock" (`privacyAppLockToggle`) bound to `appLock.isEnabled` via `Task { await appLock.setEnabled($0) }`; when `!appLock.isAvailable`, disable the toggle with a caption ("Set up Face ID / a device passcode to use this"). Root id `privacyScreen`. Takes the shared `AppLockController` from the environment (Task 6 injects it).

- [ ] **Step 4: Overlay wiring in RootView** (mirror `.budgets`):

```swift
.overlay { if router.overlay == .account {
    AccountView(api: captureAPI, auth: auth, authVM: authVM, onChangeEmail: { router.present(.changeEmail) }, onClose: { router.dismissOverlay() })
        .environment(\.accent, accent).transition(.opacity) } }
.overlay { if router.overlay == .changeEmail {
    ChangeEmailView(api: captureAPI, auth: auth, onClose: { router.dismissOverlay() })
        .environment(\.accent, accent).transition(.opacity) } }
.overlay { if router.overlay == .privacy {
    PrivacyView(appLock: appLock, onClose: { router.dismissOverlay() })
        .environment(\.accent, accent).transition(.opacity) } }
```

Add `.account, .privacy, .changeEmail` to `sheetBinding`'s nil case + `fullScreen` set + `sheetContent` EmptyView arm. (`appLock` is the env `AppLockController` from Task 6. If `ChangeEmailView` needs the same VM instance as `AccountView`, route change-email as a sub-state inside `AccountView` instead of a separate overlay — simplest is a separate overlay each building its own VM against the same `auth`/`api`, since the VM is stateless except the in-flight code.)

- [ ] **Step 5: Build + run a VM suite**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/AccountViewModelTests'`
Expected: PASS (build succeeds; VM tests pass).

- [ ] **Step 6: Commit**

```bash
git add Snapceipt/Features/Account/AccountView.swift Snapceipt/Features/Account/ChangeEmailView.swift Snapceipt/Features/Account/PrivacyView.swift Snapceipt/App/RootView.swift
git commit -m "$(cat <<'EOF'
feat(F7 iOS): Account + ChangeEmail + Privacy screens

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: App-lock gate (launch + foreground) + stub bypass

**Files:**
- Modify: `Snapceipt/App/SnapceiptApp.swift` (own + inject the `AppLockController`)
- Modify: `Snapceipt/App/RootView.swift` (wrap the authed shell behind the lock gate)
- Modify: `Snapceipt/App/AppLaunch.swift` (UI-test bypass)

- [ ] **Step 1: Own + inject the controller** in `SnapceiptApp.swift`. Construct it in `init()`:

```swift
#if DEBUG
let appLock = AppLaunch.current.makeAppLock()   // stub-bypassed under -uiTestStub (Step 3)
#else
let appLock = AppLockController()
#endif
_appLock = State(initialValue: appLock)
```
Add `@State private var appLock: AppLockController` and `.environment(appLock)` on `RootView()`.

- [ ] **Step 2: Gate the shell** in `RootView.swift`. Read `@Environment(AppLockController.self) private var appLock`. Wrap the `.signedIn` shell:

```swift
case .signedIn:
    if profileRows.isEmpty {
        OnboardingView(onFinished: {})
    } else {
        ZStack {
            ShellView(...)
            if appLock.isLocked {
                LockScreen(onUnlock: { Task { await appLock.unlock() } })
                    .transition(.opacity)
            }
        }
        .task { appLock.lockIfEnabled() }                 // cold launch
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { appLock.lockIfEnabled() }   // require unlock on return
        }
    }
```

Add a small `LockScreen` view (full-screen `Palette.cream` cover with the app mark + an "Unlock" button carrying an accessibility id `"applock.unlock"`). `scenePhase` is already observed in `ShellView`; add it to `RootView` too (or host the gate inside `ShellView` — keep it where `scenePhase` is cleanest).

- [ ] **Step 3: UI-test bypass** in `AppLaunch.swift`: add `makeAppLock()` returning a controller with `canEvaluate: { false }` (so it never locks) when `-uiTestStub` is present, else the real one:

```swift
#if DEBUG
func makeAppLock() -> AppLockController {
    if useStub { return AppLockController(canEvaluate: { false }, evaluate: { true }) }
    return AppLockController()
}
#endif
```

(`useStub` already exists in `AppLaunch`.) With `canEvaluate=false`, `lockIfEnabled()` can still set `isLocked` only if `isEnabled` — and `isEnabled` defaults false in a fresh stub launch, so the gate never blocks UI tests.

- [ ] **Step 4: Build + run the lock suite + a UI smoke**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptTests/AppLockControllerTests' -only-testing 'SnapceiptUITests/ShellUITests'`
Expected: PASS (the lock tests + the existing shell UI test still launches, confirming the gate doesn't block seeded launches).

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/App/SnapceiptApp.swift Snapceipt/App/RootView.swift Snapceipt/App/AppLaunch.swift
git commit -m "$(cat <<'EOF'
feat(F7 iOS): app-lock gate on launch/foreground + UI-test bypass

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `AccountUITests` + full-suite gate

**Files:**
- Create: `SnapceiptUITests/AccountUITests.swift`

- [ ] **Step 1: Write the UI test** (hermetic, `launchSeeded`; the Stub APIClient returns `devCode "000000"` + canned account responses):

```swift
import XCTest

final class AccountUITests: UITestCase {
    func testAccountChangeEmailAndDeleteConfirm() {
        launchSeeded()
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        app.buttons[AccessibilityID.profileRowAccount].tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.accountScreen].waitForExistence(timeout: 10))

        // Change email flow (stub returns devCode 000000 + a new AccountUser)
        app.buttons[AccessibilityID.accountChangeEmail].tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.changeEmailScreen].waitForExistence(timeout: 5))
        let field = app.textFields[AccessibilityID.changeEmailField]
        field.tap(); field.typeText("new@example.com")
        app.buttons[AccessibilityID.changeEmailSend].tap()
        let codeField = app.textFields[AccessibilityID.changeEmailCodeField]
        XCTAssertTrue(codeField.waitForExistence(timeout: 5))
        codeField.tap(); codeField.typeText("000000")
        app.buttons[AccessibilityID.changeEmailVerify].tap()
        // back on account
        XCTAssertTrue(app.otherElements[AccessibilityID.accountScreen].waitForExistence(timeout: 5))

        // Delete confirm gate: button disabled until "DELETE" typed (we cancel, not destroy)
        app.buttons[AccessibilityID.accountDeleteButton].tap()
        let confirm = app.textFields[AccessibilityID.accountDeleteConfirmField]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let deleteBtn = app.buttons[AccessibilityID.accountDeleteConfirmButton]
        XCTAssertFalse(deleteBtn.isEnabled)   // gated until the confirm word is typed
    }

    func testPrivacyToggleVisible() {
        launchSeeded()
        app.buttons[AccessibilityID.tabProfile].firstMatch.tap()
        app.buttons[AccessibilityID.profileRowPrivacy].tap()
        XCTAssertTrue(app.otherElements[AccessibilityID.privacyScreen].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches[AccessibilityID.privacyAppLockToggle].exists)
    }
}
```

(Confirm the SheetHeader close id + that the delete confirm is a reachable element; if the destructive delete is a separate sheet, adjust the navigation. The destructive deletion itself is exercised by `AccountViewModelTests`, not against a live backend.)

- [ ] **Step 2: Run the UI tests**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing 'SnapceiptUITests/AccountUITests'`
Expected: PASS (2 tests).

- [ ] **Step 3: Full suite gate**

Run: `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: all pass (baseline + config-plan + account-plan unit tests; UI 12 + SettingsUITests + AccountUITests). `git status --short` shows no `Snapceipt.xcodeproj`.

- [ ] **Step 4: Commit**

```bash
git add SnapceiptUITests/AccountUITests.swift
git commit -m "$(cat <<'EOF'
test(F7 iOS): AccountUITests (change-email + delete gate + privacy toggle)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:** §8.4 four APIClient methods + DTOs → Task 1; change-email flow → Tasks 1,2,5; device list/revoke (§8.2) → Tasks 2,5; delete account (§8.3 client side) → Tasks 2,5; Face ID app-lock (§6) → Tasks 3,5,6; nav (§2 Account/Privacy rows) → Task 4; tests (§10.2) → Tasks 1,2,3,7. ✓
**Placeholder scan:** VMs + controller + DTOs + APIClient methods are full code; the three screens (Task 5) are spec'd by structure + exact AccessibilityIDs + the VM/controller calls + the `NotificationsSettingsView` exemplar. Conditional notes (`sendNoContent` existence, SheetHeader close id, delete-confirm presentation, shared-VM-vs-separate-overlay) each name the real-source check / the chosen fallback. ✓
**Type consistency:** `AccountUser`/`EmailChangeRequested`/`AccountUserResponse`/`DeviceDTO` defined in Task 1 + consumed by `AccountViewModel` (Task 2) + the Mock; `AppLockController(defaults:canEvaluate:evaluate:)` init used identically in Task 3 tests, Task 6 injection, and `AppLaunch.makeAppLock`; `AuthStore.updateEmail` added in Task 2 + called by the VM; the `.account`/`.privacy`/`.changeEmail` overlays (Task 4) are consumed by Task 5's RootView blocks; AccessibilityIDs declared in Task 4 are referenced in Tasks 5,7. ✓
