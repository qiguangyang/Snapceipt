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
    /// First-run / sign-in state machine.
    enum AuthState: Equatable {
        case signedOut
        case requestingLink
        case awaitingLink(email: String)
        case awaitingOTP(email: String)
        case verifying
        case signedIn
        case error(String)
    }

    private(set) var state: AuthState = .signedOut
    /// The email a magic link was last sent to (drives resend + the wait screen).
    private(set) var pendingEmail: String?
    /// Monotonic count of magic links successfully sent. Lives on the VM (not the
    /// wait view's `@State`) so the "Link sent" confirmation survives the
    /// `.requestingLink → .awaitingLink` view recreation RootView performs, and so a
    /// fresh send supersedes the prior confirmation timer via `.task(id:)`.
    private(set) var linkSentCount = 0

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
        state = .verifying
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
            state = .error(Self.message(for: e))
        } catch {
            if (error as NSError).code == ASAuthorizationError.canceled.rawValue {
                state = .signedOut
            } else {
                state = .error("Couldn't sign in with Apple. Please try again.")
            }
        }
    }

    // MARK: Magic link

    func requestMagicLink(email: String) async {
        let normalized = Self.normalize(email)
        guard Self.isValidEmail(normalized) else {
            state = .error("Enter a valid email address.")
            return
        }
        state = .requestingLink
        pendingEmail = normalized
        do {
            try await api.magicLinkRequest(email: normalized)
            state = .awaitingLink(email: normalized)
            linkSentCount += 1   // success only → the wait screen confirms "Link sent"
        } catch let e as APIError {
            state = .error(Self.message(for: e))
        } catch {
            state = .error("Couldn't send the link. Check your connection and try again.")
        }
    }

    func resendMagicLink() async {
        guard let email = pendingEmail else { return }
        await requestMagicLink(email: email)
    }

    func verifyMagicLink(token: String) async {
        state = .verifying
        do {
            let session = try await api.magicLinkVerify(token: token)
            auth.save(session)
            state = .signedIn
        } catch let e as APIError {
            state = .error(Self.message(for: e))
        } catch {
            state = .error("This link is invalid or has expired. Request a new one.")
        }
    }

    // MARK: OTP (cross-device sign-in code fallback)

    func requestOTP(email: String) async {
        let normalized = Self.normalize(email)
        guard Self.isValidEmail(normalized) else {
            state = .error("Enter a valid email address.")
            return
        }
        state = .requestingLink
        pendingEmail = normalized
        do {
            try await api.otpRequest(email: normalized)
            state = .awaitingOTP(email: normalized)
            linkSentCount += 1
        } catch let e as APIError {
            state = .error(Self.message(for: e))
        } catch {
            state = .error("Couldn't send the code. Check your connection and try again.")
        }
    }

    func verifyOTP(code: String) async {
        guard let email = pendingEmail else { return }
        state = .verifying
        do {
            let session = try await api.otpVerify(email: email, code: code)
            auth.save(session)
            state = .signedIn
        } catch let e as APIError {
            state = .error(Self.message(for: e))
        } catch {
            state = .error("That code is invalid or has expired. Request a new one.")
        }
    }

    // MARK: Dev sign-in

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
            await verifyMagicLink(token: token)   // existing path → saves session, sets .signedIn
        } catch {
            state = .error("Dev sign-in failed: \(error.localizedDescription)")
        }
    }
    #endif

    // MARK: Deep link

    func handleDeepLink(_ url: URL) async {
        // Ignore magic-link taps while already signed in: a stray, forwarded, or stale
        // link shouldn't silently tear down and replace the active session.
        guard state != .signedIn else { return }
        guard let token = MagicLinkParser.token(from: url) else { return }
        await verifyMagicLink(token: token)
    }

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
