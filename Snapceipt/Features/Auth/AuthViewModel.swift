import Foundation
import Observation
import AuthenticationServices
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Deep-link parsing

/// Extracts the magic-link `token` from a sign-in URL.
/// Accepts the custom scheme `snapceipt://auth/verify?token=…`, the canonical
/// Universal Link `https://snapceipt.cc/auth/verify?token=…` (spec §9), and the
/// backend-emitted `https://snapceipt.cc/auth/magic?token=…` link.
enum MagicLinkParser {
    static func token(from url: URL) -> String? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        // The verify path is the last two path segments: ".../auth/verify" or ".../auth/magic".
        // For custom-scheme URLs ("snapceipt://auth/verify") the host is "auth" and path is "/verify".
        let segments = ([comps.host] + comps.path.split(separator: "/").map(String.init))
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        let tail = segments.suffix(2).map { $0.lowercased() }
        let isVerify = tail == ["auth", "verify"] || tail == ["auth", "magic"]
        guard isVerify else { return nil }

        guard let raw = comps.queryItems?.first(where: { $0.name == "token" })?.value,
              !raw.isEmpty else { return nil }
        return raw
    }
}

// MARK: - Sign in with Apple nonce

/// Cryptographic nonce for Sign in with Apple. The *raw* nonce is sent to the
/// server (which compares `sha256(rawNonce)` to the identity-token `nonce` claim);
/// the *hashed* nonce is set on the `ASAuthorizationAppleIDRequest`.
enum AppleNonce {
    static func make(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Apple authorization coordinator

/// Result handed back from the system Sign in with Apple sheet.
struct AppleSignInResult {
    let identityToken: String
    let authorizationCode: String
    let fullName: String?
    let email: String?
}

enum AuthError: Error { case appleMissingToken, appleCancelled }

/// Bridges the delegate-based `ASAuthorizationController` API to async/await.
@MainActor
final class AppleSignInCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {

    private var continuation: CheckedContinuation<AppleSignInResult, Error>?

    /// Nonisolated so it can be used as a default argument value for `AuthViewModel.init`
    /// (which is itself `@MainActor`). The type holds no state requiring isolation at init.
    nonisolated override init() { super.init() }

    /// Presents the system sheet for the given hashed nonce and resumes with the
    /// identity token + authorization code (and name/email on first authorization).
    func start(hashedNonce: String) async throws -> AppleSignInResult {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = hashedNonce
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        defer { continuation = nil }
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let identityToken = String(data: tokenData, encoding: .utf8),
            let codeData = credential.authorizationCode,
            let authorizationCode = String(data: codeData, encoding: .utf8)
        else {
            continuation?.resume(throwing: AuthError.appleMissingToken)
            return
        }
        var fullName: String?
        if let name = credential.fullName {
            let parts = [name.givenName, name.familyName].compactMap { $0 }
            if !parts.isEmpty { fullName = parts.joined(separator: " ") }
        }
        continuation?.resume(returning: AppleSignInResult(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            fullName: fullName,
            email: credential.email
        ))
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes
        if let window = scenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) {
            return window
        }
        #endif
        return ASPresentationAnchor()
    }
}

// MARK: - AuthViewModel

@MainActor
@Observable
final class AuthViewModel {
    /// What a 6-digit code is being used for — drives the post-verify step.
    enum CodePurpose: Equatable { case signUp, reset, codeLogin, mfa }

    /// Sign-in state machine. Errors surface via `lastError` on whichever screen is up, so the
    /// state itself only picks the SCREEN (signedOut/working → SignInView, awaitingCode/verifying
    /// → code entry, settingPassword → SetPasswordView, signedIn → shell).
    enum AuthState: Equatable {
        case signedOut
        case working                                          // a login/code request in flight
        case awaitingCode(email: String, purpose: CodePurpose) // code-entry screen
        case verifying                                        // code verify in flight
        case settingPassword                                  // signed in; prompting for a password
        case signedIn
    }

    private(set) var state: AuthState = .signedOut
    /// The email the current flow is for (drives the code screen + resend).
    private(set) var pendingEmail: String?
    private(set) var pendingPurpose: CodePurpose?
    /// Bumped on every successful code (re)send so the code screen can confirm "code sent".
    private(set) var codeSentCount = 0
    /// Last error message, shown by the active screen (cleared when a flow advances).
    private(set) var lastError: String?

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let auth: AuthStore
    @ObservationIgnored private let apple: AppleSignInCoordinator
    /// Wipes local SwiftData + receipt images on sign-out / account-deletion. Injected
    /// (rather than reaching into SwiftData here) so the auth layer stays storage-agnostic
    /// and tests can omit it. Nil in previews/tests.
    @ObservationIgnored private let onWipeLocalData: (() -> Void)?

    init(api: APIClient, auth: AuthStore, apple: AppleSignInCoordinator = AppleSignInCoordinator(),
         onWipeLocalData: (() -> Void)? = nil) {
        self.api = api
        self.auth = auth
        self.apple = apple
        self.onWipeLocalData = onWipeLocalData
        // If a session was restored from the Keychain, start already signed in.
        if auth.session != nil { state = .signedIn }
    }

    // MARK: Sign in with Apple

    func signInWithApple() async {
        lastError = nil
        state = .working
        let rawNonce = AppleNonce.make()
        let hashedNonce = AppleNonce.sha256(rawNonce)
        do {
            let result = try await apple.start(hashedNonce: hashedNonce)
            let body = AppleAuthBody(
                identityToken: result.identityToken,
                authorizationCode: result.authorizationCode,
                rawNonce: rawNonce,
                fullName: result.fullName,
                email: result.email
            )
            let session = try await api.authApple(body)
            auth.save(session)
            state = .signedIn
        } catch is AuthError {
            state = .signedOut  // user cancelled / no token — silently return to sign-in
        } catch let e as APIError {
            lastError = Self.message(for: e); state = .signedOut
        } catch {
            let ns = error as NSError
            if ns.code == ASAuthorizationError.canceled.rawValue {
                state = .signedOut
            } else {
                lastError = "Apple sign-in failed: \(ns.domain) \(ns.code) — \(ns.localizedDescription)"
                state = .signedOut
            }
        }
    }

    // MARK: Password login (email + password; new device → 6-digit MFA)

    func signInWithPassword(email: String, password: String) async {
        let normalized = Self.normalize(email)
        guard Self.isValidEmail(normalized) else { lastError = "Enter a valid email address."; return }
        guard !password.isEmpty else { lastError = "Enter your password."; return }
        lastError = nil
        state = .working
        pendingEmail = normalized
        do {
            switch try await api.passwordLogin(email: normalized, password: password) {
            case .session(let s):
                auth.save(s); state = .signedIn
            case .mfaRequired:
                // New device → the backend emailed a code; verify it to trust the device + sign in.
                pendingPurpose = .mfa
                codeSentCount += 1
                state = .awaitingCode(email: normalized, purpose: .mfa)
            }
        } catch let e as APIError {
            lastError = Self.message(for: e); state = .signedOut
        } catch {
            lastError = "Couldn't sign in. Check your connection and try again."; state = .signedOut
        }
    }

    // MARK: 6-digit code flows (sign-up / reset / passwordless login)

    /// Request a 6-digit code and move to the code-entry screen. `purpose` drives the post-verify
    /// step (sign-up/reset → set a password; codeLogin → straight in).
    func startCode(email: String, purpose: CodePurpose) async {
        let normalized = Self.normalize(email)
        guard Self.isValidEmail(normalized) else { lastError = "Enter a valid email address."; return }
        lastError = nil
        state = .working
        pendingEmail = normalized
        pendingPurpose = purpose
        do {
            try await api.otpRequest(email: normalized)
            codeSentCount += 1
            state = .awaitingCode(email: normalized, purpose: purpose)
        } catch let e as APIError {
            lastError = Self.message(for: e); state = .signedOut
        } catch {
            lastError = "Couldn't send the code. Check your connection and try again."; state = .signedOut
        }
    }

    /// Re-send the current code (from the code screen).
    func resendCode() async {
        guard let email = pendingEmail, let purpose = pendingPurpose else { return }
        await startCode(email: email, purpose: purpose)
    }

    /// Verify the 6-digit code. Always signs the user in; sign-up/reset then prompt for a password.
    func verifyCode(_ code: String) async {
        guard let email = pendingEmail else { return }
        let purpose = pendingPurpose
        lastError = nil
        state = .verifying
        do {
            let session = try await api.otpVerify(email: email, code: code)
            auth.save(session)
            state = (purpose == .signUp || purpose == .reset) ? .settingPassword : .signedIn
        } catch let e as APIError {
            lastError = Self.message(for: e)
            state = .awaitingCode(email: email, purpose: purpose ?? .codeLogin)
        } catch {
            lastError = "That code is invalid or has expired. Request a new one."
            state = .awaitingCode(email: email, purpose: purpose ?? .codeLogin)
        }
    }

    // MARK: Set / skip password (after a sign-up or reset code; the user is already signed in)

    /// Set the password (min 8). Returns false (with `lastError` set) so the screen stays put.
    @discardableResult
    func setPassword(_ password: String) async -> Bool {
        guard password.count >= 8 else { lastError = "Use at least 8 characters."; return false }
        lastError = nil
        do {
            try await api.passwordSet(password: password)
            state = .signedIn
            return true
        } catch let e as APIError {
            lastError = Self.message(for: e); return false
        } catch {
            lastError = "Couldn't save your password. Try again."; return false
        }
    }

    /// Sign-up only: continue without setting a password (code login still works).
    func skipPasswordSetup() { lastError = nil; state = .signedIn }

    /// Whether the set-password screen may be skipped (sign-up only; a reset must set a new one).
    var canSkipPasswordSetup: Bool { pendingPurpose == .signUp }

    /// The current code purpose (defaults to passwordless login) — drives the code screen copy.
    var codePurpose: CodePurpose { pendingPurpose ?? .codeLogin }

    /// Abandon the current code/password flow and return to the sign-in screen.
    func cancelFlow() { lastError = nil; pendingEmail = nil; pendingPurpose = nil; state = .signedOut }

    // MARK: Dev sign-in

    #if DEBUG
    /// One-tap dev sign-in via the backend's dev token (E2E_TEST_MODE). Errors clearly if the
    /// backend isn't in dev mode. (Uses the magic-link dev endpoint, which is still present.)
    func devSignIn() async {
        pendingEmail = nil
        lastError = nil
        state = .working
        do {
            guard let token = try await api.magicLinkRequestDev(email: DevAccount.email) else {
                lastError = "Dev sign-in needs the backend running in dev mode (E2E_TEST_MODE)."
                state = .signedOut
                return
            }
            let session = try await api.magicLinkVerify(token: token)
            auth.save(session)
            state = .signedIn
        } catch {
            lastError = "Dev sign-in failed: \(error.localizedDescription)"; state = .signedOut
        }
    }
    #endif

    // MARK: Deep link

    /// Legacy magic-link deep links are no longer used (code + password replaced them); ignore.
    func handleDeepLink(_ url: URL) async { _ = url }

    // MARK: Sign out

    func signOut() async {
        try? await api.signOut()
        // Set state FIRST so the RootView session-cleared observer (handleSessionInvalidated)
        // no-ops here — this path does its own wipe below; we don't want it to run twice.
        state = .signedOut
        auth.clear()
        // Wipe local financial data + receipt images so nothing survives on the device
        // after sign-out / account deletion (both paths funnel through here). A returning
        // sign-in re-pulls from the server with a fresh cursor.
        onWipeLocalData?()
        pendingEmail = nil
    }

    /// Re-evaluates the state after an external session restore (used at launch).
    func refreshAuthState() {
        state = auth.session != nil ? .signedIn : .signedOut
    }

    /// The session was cleared out from under a signed-in shell — the APIClient does this
    /// after an unrecoverable refresh failure (expired/revoked refresh token, account
    /// deleted elsewhere, signing-key rotation). Wipe the prior user's local data (so a
    /// different account on this device can't inherit it) and route to sign-in. Guarded to
    /// `.signedIn` so it never fires during the transient magic-link/OTP flow (whose states
    /// legitimately have a nil session), nor double-acts after an explicit `signOut()`
    /// (which sets `.signedOut` first).
    func handleSessionInvalidated() {
        guard auth.session == nil, state == .signedIn else { return }
        onWipeLocalData?()
        state = .signedOut
    }

    // MARK: Helpers

    static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isValidEmail(_ email: String) -> Bool {
        // Minimal RFC-ish check; the server is the real validator.
        guard let at = email.firstIndex(of: "@"), at != email.startIndex else { return false }
        let domain = email[email.index(after: at)...]
        return domain.contains(".") && !domain.hasSuffix(".") && !email.contains(" ")
    }

    private static func message(for error: APIError) -> String {
        switch error.code {
        case "AUTH_INVALID_TOKEN", "AUTH_SESSION_REVOKED":
            return "This link is invalid or has expired. Request a new one."
        case "AUTH_DEVICE_MISMATCH":
            return "Open the link on the device that requested it, or use a sign-in code instead."
        case "RATE_LIMITED":
            return "Too many attempts. Please wait a moment and try again."
        case "VALIDATION_FAILED":
            return "That email didn't look right. Please check it and try again."
        default:
            return error.message.isEmpty ? "Something went wrong. Please try again." : error.message
        }
    }
}
