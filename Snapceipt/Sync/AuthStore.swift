import Foundation
import Observation

/// Local, observable projection of the backend session. The access token is the
/// Bearer credential; the refresh token is kept here (and in the Keychain) for the
/// refresh-rotation flow. `email`/`displayName` may be nil (backend contract).
struct SessionState: Equatable, Sendable {
    var userId: String
    var email: String?
    var displayName: String?
    var accessToken: String
    var refreshToken: String
    /// Absolute expiry of the access token (epoch seconds), derived from expiresIn.
    var accessExpiresAt: TimeInterval
}

/// Owns auth state for the app: the active session, the stable per-install deviceId,
/// and the Keychain-backed persistence of access + refresh tokens. `@Observable` so
/// SwiftUI re-renders on sign-in/out. Injected into APIClient (Bearer) and SyncEngine.
@Observable
final class AuthStore {
    /// nil when signed out.
    private(set) var session: SessionState?

    @ObservationIgnored private let keychain: Keychain
    /// Backing store for the lazily-materialised deviceId.
    @ObservationIgnored private var cachedDeviceId: String?

    init(keychain: Keychain = Keychain()) {
        self.keychain = keychain
        restore()
    }

    /// Stable identifier for this install, generated once (UUIDv7) and persisted in
    /// the Keychain. Sent to the backend as the `X-Device-Id` header. Survives sign-out.
    var deviceId: String {
        if let cached = cachedDeviceId { return cached }
        if let existing = keychain.string(.deviceId) {
            cachedDeviceId = existing
            return existing
        }
        let fresh = ID.uuidv7()
        keychain.set(fresh, .deviceId)
        cachedDeviceId = fresh
        return fresh
    }

    /// The Authorization header value, or nil when signed out.
    func bearer() -> String? {
        guard let token = session?.accessToken else { return nil }
        return "Bearer \(token)"
    }

    /// Persist a fresh session from the backend: store tokens + a user blob in the
    /// Keychain and publish the in-memory `SessionState`.
    func save(_ s: SessionResponse) {
        let expiresAt = Date().timeIntervalSince1970 + TimeInterval(s.expiresIn)
        let state = SessionState(
            userId: s.user.id,
            email: s.user.email,
            displayName: s.user.displayName,
            accessToken: s.accessToken,
            refreshToken: s.refreshToken,
            accessExpiresAt: expiresAt
        )

        keychain.set(s.accessToken, .accessToken)
        keychain.set(s.refreshToken, .refreshToken)
        persistUser(PersistedUser(id: s.user.id, email: s.user.email, displayName: s.user.displayName))

        session = state
    }

    /// Sign out locally: drop the session and clear tokens. Keeps the deviceId so the
    /// same install re-registers as the same device on the next sign-in.
    func clear() {
        keychain.delete(.accessToken)
        keychain.delete(.refreshToken)
        clearPersistedUser()
        session = nil
    }

    /// Update the in-memory + persisted email after a confirmed change. The session
    /// is a value type, so rebuild it and re-persist the cached user blob.
    func updateEmail(_ email: String?) {
        guard var s = session else { return }
        s.email = email
        session = s
        persistUser(PersistedUser(id: s.userId, email: email, displayName: s.displayName))
    }

    /// Rebuild `session` from the Keychain + cached user blob at launch, if present.
    private func restore() {
        guard let access = keychain.string(.accessToken),
              let refresh = keychain.string(.refreshToken),
              let user = loadPersistedUser() else {
            return
        }
        session = SessionState(
            userId: user.id,
            email: user.email,
            displayName: user.displayName,
            accessToken: access,
            refreshToken: refresh,
            // Unknown on cold restore; treat as already-expired so the next call refreshes.
            accessExpiresAt: 0
        )
    }

    // MARK: - User blob (de)serialization

    /// The user-identity snapshot cached alongside the tokens so the session can be
    /// restored on cold launch. Stored in UserDefaults under a key namespaced by the
    /// Keychain service, so injected/test stores stay isolated from the app's data.
    private struct PersistedUser: Codable {
        let id: String
        let email: String?
        let displayName: String?
    }

    /// UserDefaults key for the cached user, namespaced by the Keychain service so a
    /// test store on a unique service never collides with the real app's session.
    private var userDefaultsKey: String { "sc.sessionUser." + keychain.service }

    private func persistUser(_ user: PersistedUser) {
        guard let data = try? JSONEncoder().encode(user) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    private func loadPersistedUser() -> PersistedUser? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(PersistedUser.self, from: data)
    }

    private func clearPersistedUser() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}
