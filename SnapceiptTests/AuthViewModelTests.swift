import Testing
import Foundation
@testable import Snapceipt

@MainActor
@Suite("AuthViewModel")
struct AuthViewModelTests {
    /// A throwaway Keychain service keeps test runs isolated from the real app keychain.
    private func makeStore() -> AuthStore {
        let store = AuthStore(keychain: Keychain(service: "sc.test.\(UUID().uuidString)"))
        store.clear()
        return store
    }

    private var stub: SessionResponse {
        SessionResponse(accessToken: "header.payload.sig",
                        refreshToken: "refresh-token-value-0123456789abcdef",
                        expiresIn: 900,
                        user: SessionUser(id: "u1", email: "maya@example.com", displayName: "Maya Reyes"))
    }

    /// A mock wired so OTP request/verify + password login succeed by default; tests override.
    private func makeMock() -> MockAPIClient {
        let s = stub
        let mock = MockAPIClient()
        mock.otpRequestHandler = { _ in }
        mock.otpVerifyHandler = { _, _ in s }
        mock.passwordLoginHandler = { _, _ in .session(s) }
        mock.signOutHandler = { }
        return mock
    }

    // MARK: Password login (email + password; new device → MFA)

    @Test("password login on a trusted device → signedIn + saves the session")
    func passwordLoginTrusted() async {
        let mock = makeMock()
        let store = makeStore()
        let vm = AuthViewModel(api: mock, auth: store)
        await vm.signInWithPassword(email: "  Maya@Example.com ", password: "supersecret1")
        #expect(vm.state == .signedIn)
        #expect(store.session != nil)
        #expect(store.bearer() == "Bearer header.payload.sig")
    }

    @Test("password login on a new device → awaitingCode(.mfa), no session yet")
    func passwordLoginMfa() async {
        let mock = makeMock()
        mock.passwordLoginHandler = { _, _ in .mfaRequired }
        let store = makeStore()
        let vm = AuthViewModel(api: mock, auth: store)
        await vm.signInWithPassword(email: "maya@example.com", password: "supersecret1")
        #expect(vm.state == .awaitingCode(email: "maya@example.com", purpose: .mfa))
        #expect(store.session == nil)
        #expect(vm.codeSentCount == 1)   // the backend already emailed the MFA code
    }

    @Test("password login with a bad email errors without calling the API")
    func passwordLoginInvalidEmail() async {
        let mock = makeMock()
        let vm = AuthViewModel(api: mock, auth: makeStore())
        await vm.signInWithPassword(email: "nope", password: "supersecret1")
        #expect(vm.lastError != nil)
        #expect(vm.state == .signedOut)
    }

    @Test("password login wrong credentials → lastError, stays signedOut")
    func passwordLoginWrong() async {
        let mock = makeMock()
        mock.passwordLoginHandler = { _, _ in
            throw APIError(code: "AUTH_INVALID_CREDENTIALS", message: "Incorrect email or password", status: 401)
        }
        let store = makeStore()
        let vm = AuthViewModel(api: mock, auth: store)
        await vm.signInWithPassword(email: "maya@example.com", password: "wrong")
        #expect(vm.state == .signedOut)
        #expect(vm.lastError != nil)
        #expect(store.session == nil)
    }

    // MARK: 6-digit code flows (sign-up / reset / passwordless)

    @Test("startCode moves to awaitingCode with the purpose + bumps codeSentCount")
    func startCodeSignUp() async {
        let mock = makeMock()
        let vm = AuthViewModel(api: mock, auth: makeStore())
        await vm.startCode(email: "  Maya@Example.com ", purpose: .signUp)
        #expect(mock.otpRequestedEmails == ["maya@example.com"])  // normalized
        #expect(vm.state == .awaitingCode(email: "maya@example.com", purpose: .signUp))
        #expect(vm.pendingEmail == "maya@example.com")
        #expect(vm.codeSentCount == 1)
    }

    @Test("startCode with an invalid email errors without calling the API")
    func startCodeInvalidEmail() async {
        let mock = makeMock()
        let vm = AuthViewModel(api: mock, auth: makeStore())
        await vm.startCode(email: "nope", purpose: .signUp)
        #expect(mock.otpRequestedEmails.isEmpty)
        #expect(vm.lastError != nil)
    }

    @Test("verifyCode for sign-up → settingPassword (+ session saved, skip allowed)")
    func verifyCodeSignUp() async {
        let mock = makeMock()
        let store = makeStore()
        let vm = AuthViewModel(api: mock, auth: store)
        await vm.startCode(email: "maya@example.com", purpose: .signUp)
        await vm.verifyCode("123456")
        #expect(mock.otpVerifiedCodes.map(\.code) == ["123456"])
        #expect(vm.state == .settingPassword)
        #expect(store.session != nil)
        #expect(vm.canSkipPasswordSetup == true)
    }

    @Test("verifyCode for reset → settingPassword, skip NOT allowed")
    func verifyCodeReset() async {
        let mock = makeMock()
        let vm = AuthViewModel(api: mock, auth: makeStore())
        await vm.startCode(email: "maya@example.com", purpose: .reset)
        await vm.verifyCode("123456")
        #expect(vm.state == .settingPassword)
        #expect(vm.canSkipPasswordSetup == false)
    }

    @Test("verifyCode for passwordless login → signedIn (no password step)")
    func verifyCodeLogin() async {
        let mock = makeMock()
        let store = makeStore()
        let vm = AuthViewModel(api: mock, auth: store)
        await vm.startCode(email: "maya@example.com", purpose: .codeLogin)
        await vm.verifyCode("123456")
        #expect(vm.state == .signedIn)
        #expect(store.session != nil)
    }

    @Test("verifyCode for new-device MFA → signedIn")
    func verifyCodeMfa() async {
        let mock = makeMock()
        mock.passwordLoginHandler = { _, _ in .mfaRequired }
        let store = makeStore()
        let vm = AuthViewModel(api: mock, auth: store)
        await vm.signInWithPassword(email: "maya@example.com", password: "supersecret1")
        await vm.verifyCode("123456")
        #expect(vm.state == .signedIn)
        #expect(store.session != nil)
    }

    @Test("verifyCode failure → back to awaitingCode + lastError, no session")
    func verifyCodeWrong() async {
        let mock = makeMock()
        mock.otpVerifyHandler = { _, _ in
            throw APIError(code: "VALIDATION_FAILED", message: "Incorrect code", status: 400)
        }
        let store = makeStore()
        let vm = AuthViewModel(api: mock, auth: store)
        await vm.startCode(email: "maya@example.com", purpose: .signUp)
        await vm.verifyCode("000000")
        #expect(vm.lastError != nil)
        if case .awaitingCode = vm.state {} else { Issue.record("expected awaitingCode, got \(vm.state)") }
        #expect(store.session == nil)
    }

    @Test("verifyCode with no pending email is a no-op")
    func verifyCodeNoPending() async {
        let mock = makeMock()
        let vm = AuthViewModel(api: mock, auth: makeStore())
        await vm.verifyCode("123456")
        #expect(mock.otpVerifiedCodes.isEmpty)
    }

    @Test("resendCode re-requests the same email + purpose and bumps the count")
    func resendCode() async {
        let mock = makeMock()
        let vm = AuthViewModel(api: mock, auth: makeStore())
        await vm.startCode(email: "maya@example.com", purpose: .signUp)
        await vm.resendCode()
        #expect(mock.otpRequestedEmails == ["maya@example.com", "maya@example.com"])
        #expect(vm.codeSentCount == 2)
    }

    @Test("resendCode FAILURE stays on the code screen (.awaitingCode) + sets lastError")
    func resendCodeFailureStaysOnCodeScreen() async {
        let mock = makeMock()
        let vm = AuthViewModel(api: mock, auth: makeStore())
        await vm.startCode(email: "maya@example.com", purpose: .signUp)   // → .awaitingCode
        mock.otpRequestHandler = { _ in
            throw APIError(code: "RATE_LIMITED", message: "Too many attempts", status: 429)
        }
        await vm.resendCode()
        #expect(vm.lastError != nil)
        if case .awaitingCode = vm.state {} else { Issue.record("expected awaitingCode, got \(vm.state)") }
        #expect(vm.codeSentCount == 1)   // not bumped on failure
    }

    // MARK: Set / skip password

    @Test("setPassword success → signedIn + calls passwordSet")
    func setPasswordSuccess() async {
        let mock = makeMock()
        let store = makeStore()
        let vm = AuthViewModel(api: mock, auth: store)
        await vm.startCode(email: "maya@example.com", purpose: .signUp)
        await vm.verifyCode("123456")   // → settingPassword
        let ok = await vm.setPassword("supersecret1")
        #expect(ok == true)
        #expect(vm.state == .signedIn)
        #expect(mock.passwordSetCalls == ["supersecret1"])
    }

    @Test("setPassword too short → false, stays on settingPassword, no API call")
    func setPasswordTooShort() async {
        let mock = makeMock()
        let vm = AuthViewModel(api: mock, auth: makeStore())
        await vm.startCode(email: "maya@example.com", purpose: .signUp)
        await vm.verifyCode("123456")
        let ok = await vm.setPassword("short")
        #expect(ok == false)
        #expect(vm.state == .settingPassword)
        #expect(mock.passwordSetCalls.isEmpty)
        #expect(vm.lastError != nil)
    }

    @Test("skipPasswordSetup → signedIn")
    func skipPassword() async {
        let mock = makeMock()
        let vm = AuthViewModel(api: mock, auth: makeStore())
        await vm.startCode(email: "maya@example.com", purpose: .signUp)
        await vm.verifyCode("123456")
        vm.skipPasswordSetup()
        #expect(vm.state == .signedIn)
    }

    // MARK: Misc

    @Test("cancelFlow returns to signedOut + clears pending")
    func cancelFlow() async {
        let mock = makeMock()
        let vm = AuthViewModel(api: mock, auth: makeStore())
        await vm.startCode(email: "maya@example.com", purpose: .signUp)
        vm.cancelFlow()
        #expect(vm.state == .signedOut)
        #expect(vm.pendingEmail == nil)
    }

    @Test("signOut clears the session and returns to signedOut")
    func signOut() async {
        let mock = makeMock()
        let store = makeStore()
        let vm = AuthViewModel(api: mock, auth: store)
        await vm.signInWithPassword(email: "maya@example.com", password: "supersecret1")
        #expect(store.session != nil)
        await vm.signOut()
        #expect(store.session == nil)
        #expect(vm.state == .signedOut)
    }

    @Test("a restored session starts the VM in signedIn")
    func restoredSessionStartsSignedIn() async {
        let store = makeStore()
        store.save(SessionResponse(accessToken: "a", refreshToken: "r", expiresIn: 900,
                                   user: SessionUser(id: "u1", email: nil, displayName: nil)))
        let vm = AuthViewModel(api: makeMock(), auth: store)
        #expect(vm.state == .signedIn)
    }

    @Test("handleDeepLink is a no-op (magic link removed)")
    func deepLinkNoOp() async throws {
        let mock = makeMock()
        let vm = AuthViewModel(api: mock, auth: makeStore())
        let url = try #require(URL(string: "https://snapceipt.cc/auth/verify?token=deep-tok"))
        await vm.handleDeepLink(url)
        #expect(vm.state == .signedOut)
    }

    @Test func devSignInWithTokenReachesSignedIn() async {
        let mock = makeMock()
        mock.magicLinkRequestDevHandler = { _ in "dev-tok" }
        mock.magicLinkVerifyHandler = { token in
            #expect(token == "dev-tok")
            return SessionResponse(accessToken: "a", refreshToken: "r", expiresIn: 900,
                                   user: SessionUser(id: "u-dev", email: "dev@snapceipt.cc", displayName: "Dev"))
        }
        let store = makeStore()
        let vm = AuthViewModel(api: mock, auth: store)
        await vm.devSignIn()
        #expect(vm.state == .signedIn)
        #expect(store.session?.userId == "u-dev")
    }

    @Test func devSignInWithNoTokenStaysSignedOut() async {
        let mock = makeMock()
        mock.magicLinkRequestDevHandler = { _ in nil }   // backend not in dev mode
        let vm = AuthViewModel(api: mock, auth: makeStore())
        await vm.devSignIn()
        #expect(vm.state == .signedOut)
        #expect(vm.lastError != nil)
    }
}
