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

    /// The canonical scriptable `MockAPIClient` wired with a stub session + recorders.
    /// Returns the mock plus mutable recorder boxes so each test can assert on calls.
    private final class Recorder {
        var requestedEmails: [String] = []
        var verifiedTokens: [String] = []
        var appleBodies: [AppleAuthBody] = []
        var signedOut = false
    }

    private func makeMock(rec: Recorder, verifyShouldFail: Bool = false) -> MockAPIClient {
        let stub = SessionResponse(
            accessToken: "header.payload.sig",
            refreshToken: "refresh-token-value-0123456789abcdef",
            expiresIn: 900,
            user: SessionUser(id: "u1", email: "maya@example.com", displayName: "Maya Reyes")
        )
        let mock = MockAPIClient()
        mock.magicLinkRequestHandler = { email in rec.requestedEmails.append(email) }
        mock.magicLinkVerifyHandler = { token in
            rec.verifiedTokens.append(token)
            if verifyShouldFail {
                throw APIError(code: "AUTH_INVALID_TOKEN",
                               message: "Invalid or expired magic link", status: 401)
            }
            return stub
        }
        mock.authAppleHandler = { body in rec.appleBodies.append(body); return stub }
        mock.signOutHandler = { rec.signedOut = true }
        return mock
    }

    @Test("requestMagicLink moves to awaitingLink and calls the API once")
    func requestMovesToAwaiting() async {
        let rec = Recorder()
        let api = makeMock(rec: rec)
        let vm = AuthViewModel(api: api, auth: makeStore())

        await vm.requestMagicLink(email: "  Maya@Example.com ")

        #expect(rec.requestedEmails == ["maya@example.com"])  // normalized
        #expect(vm.state == .awaitingLink(email: "maya@example.com"))
        #expect(vm.pendingEmail == "maya@example.com")
    }

    @Test("requestMagicLink with an invalid email errors without calling the API")
    func requestInvalidEmail() async {
        let rec = Recorder()
        let api = makeMock(rec: rec)
        let vm = AuthViewModel(api: api, auth: makeStore())

        await vm.requestMagicLink(email: "not-an-email")

        #expect(rec.requestedEmails.isEmpty)
        if case .error = vm.state { } else { Issue.record("expected .error, got \(vm.state)") }
    }

    @Test("verifyMagicLink success → signedIn and persists the session")
    func verifySuccess() async {
        let rec = Recorder()
        let api = makeMock(rec: rec)
        let store = makeStore()
        let vm = AuthViewModel(api: api, auth: store)

        await vm.verifyMagicLink(token: "good-token")

        #expect(rec.verifiedTokens == ["good-token"])
        #expect(vm.state == .signedIn)
        #expect(store.session != nil)
        #expect(store.bearer() == "Bearer header.payload.sig")
    }

    @Test("verifyMagicLink 401 → error state, no session saved")
    func verifyExpired() async {
        let rec = Recorder()
        let api = makeMock(rec: rec, verifyShouldFail: true)
        let store = makeStore()
        let vm = AuthViewModel(api: api, auth: store)

        await vm.verifyMagicLink(token: "expired")

        #expect(store.session == nil)
        if case .error(let msg) = vm.state {
            #expect(msg.isEmpty == false)
        } else {
            Issue.record("expected .error, got \(vm.state)")
        }
    }

    @Test("handleDeepLink extracts the token, drives verify, and signs in")
    func deepLinkVerifies() async throws {
        let rec = Recorder()
        let api = makeMock(rec: rec)
        let vm = AuthViewModel(api: api, auth: makeStore())
        let url = try #require(URL(string: "https://snapceipt.cc/auth/verify?token=deep-tok"))

        await vm.handleDeepLink(url)

        #expect(rec.verifiedTokens == ["deep-tok"])
        #expect(vm.state == .signedIn)
    }

    @Test("handleDeepLink extracts the token from the custom-scheme link too")
    func deepLinkCustomScheme() async throws {
        let rec = Recorder()
        let api = makeMock(rec: rec)
        let vm = AuthViewModel(api: api, auth: makeStore())
        let url = try #require(URL(string: "snapceipt://auth/verify?token=cust-tok"))

        await vm.handleDeepLink(url)

        #expect(rec.verifiedTokens == ["cust-tok"])
        #expect(vm.state == .signedIn)
    }

    @Test("handleDeepLink ignores a non-auth URL")
    func deepLinkIgnored() async throws {
        let rec = Recorder()
        let api = makeMock(rec: rec)
        let vm = AuthViewModel(api: api, auth: makeStore())
        let url = try #require(URL(string: "https://snapceipt.cc/help"))

        await vm.handleDeepLink(url)

        #expect(rec.verifiedTokens.isEmpty)
        #expect(vm.state == .signedOut)
    }

    @Test("resendMagicLink re-requests the pending email")
    func resend() async {
        let rec = Recorder()
        let api = makeMock(rec: rec)
        let vm = AuthViewModel(api: api, auth: makeStore())
        await vm.requestMagicLink(email: "maya@example.com")

        await vm.resendMagicLink()

        #expect(rec.requestedEmails == ["maya@example.com", "maya@example.com"])
        #expect(vm.state == .awaitingLink(email: "maya@example.com"))
    }

    @Test("signOut clears the session and returns to signedOut")
    func signOut() async {
        let rec = Recorder()
        let api = makeMock(rec: rec)
        let store = makeStore()
        let vm = AuthViewModel(api: api, auth: store)
        await vm.verifyMagicLink(token: "good-token")
        #expect(store.session != nil)

        await vm.signOut()

        #expect(store.session == nil)
        #expect(vm.state == .signedOut)
        #expect(rec.signedOut == true)
    }

    @Test("a restored session starts the VM in signedIn")
    func restoredSessionStartsSignedIn() async {
        let rec = Recorder()
        let api = makeMock(rec: rec)
        let store = makeStore()
        store.save(SessionResponse(accessToken: "a", refreshToken: "r", expiresIn: 900,
                                   user: SessionUser(id: "u1", email: nil, displayName: nil)))
        let vm = AuthViewModel(api: api, auth: store)
        #expect(vm.state == .signedIn)
    }

    @Test func devSignInWithTokenReachesSignedInAndSavesSession() async {
        let mock = MockAPIClient()
        mock.magicLinkRequestDevHandler = { _ in "dev-tok" }
        mock.magicLinkVerifyHandler = { token in
            #expect(token == "dev-tok")
            return SessionResponse(accessToken: "a", refreshToken: "r", expiresIn: 900,
                                   user: SessionUser(id: "u-dev", email: "dev@snapceipt.cc", displayName: "Dev"))
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
}
