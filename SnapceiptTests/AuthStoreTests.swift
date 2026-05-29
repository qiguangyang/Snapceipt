import Testing
import Foundation
@testable import Snapceipt

@Suite("AuthStore")
struct AuthStoreTests {
    /// A Keychain on a unique service with all keys cleared.
    private func freshKeychain() -> Keychain {
        let kc = Keychain(service: "app.snapceipt.tests." + UUID().uuidString)
        for key in KeychainKey.allCases { kc.delete(key) }
        return kc
    }

    private func session(access: String = "acc-tok", refresh: String = "ref-tok",
                         email: String? = "maya@example.com",
                         name: String? = "Maya Reyes") -> SessionResponse {
        SessionResponse(
            accessToken: access,
            refreshToken: refresh,
            expiresIn: 900,
            user: SessionUser(id: "u1", email: email, displayName: name)
        )
    }

    @Test("bearer() is nil before any session is saved")
    func bearerNilWhenSignedOut() {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }
        let store = AuthStore(keychain: kc)
        #expect(store.bearer() == nil)
        #expect(store.session == nil)
    }

    @Test("save persists tokens to Keychain and exposes the session")
    func savePersistsTokensAndSession() {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }
        let store = AuthStore(keychain: kc)

        store.save(session())

        #expect(store.bearer() == "Bearer acc-tok")
        #expect(kc.string(.accessToken) == "acc-tok")
        #expect(kc.string(.refreshToken) == "ref-tok")
        #expect(store.session?.userId == "u1")
        #expect(store.session?.email == "maya@example.com")
        #expect(store.session?.displayName == "Maya Reyes")
        #expect(store.session?.refreshToken == "ref-tok")
    }

    @Test("save tolerates null email and displayName")
    func saveWithNullProfileFields() {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }
        let store = AuthStore(keychain: kc)

        store.save(session(email: nil, name: nil))
        #expect(store.session?.userId == "u1")
        #expect(store.session?.email == nil)
        #expect(store.session?.displayName == nil)
        #expect(store.bearer() == "Bearer acc-tok")
    }

    @Test("a new AuthStore over the same Keychain restores the session at init")
    func restoresSessionOnInit() {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }
        AuthStore(keychain: kc).save(session(access: "live-acc", refresh: "live-ref"))

        let restored = AuthStore(keychain: kc)
        #expect(restored.bearer() == "Bearer live-acc")
        #expect(restored.session?.refreshToken == "live-ref")
        #expect(restored.session?.userId == "u1")
    }

    @Test("clear empties tokens, session and Keychain")
    func clearEmptiesEverything() {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }
        let store = AuthStore(keychain: kc)
        store.save(session())

        store.clear()

        #expect(store.session == nil)
        #expect(store.bearer() == nil)
        #expect(kc.string(.accessToken) == nil)
        #expect(kc.string(.refreshToken) == nil)
    }

    @Test("clear preserves the deviceId (only the session is revoked locally)")
    func clearKeepsDeviceId() {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }
        let store = AuthStore(keychain: kc)
        let device = store.deviceId
        store.save(session())

        store.clear()
        #expect(store.deviceId == device)
        #expect(kc.string(.deviceId) == device)
    }

    @Test("deviceId is generated once and is a UUIDv7-shaped string")
    func deviceIdShapeAndStability() {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }
        let store = AuthStore(keychain: kc)

        let id = store.deviceId
        // RFC 9562 v7: version nibble 7, variant nibble 8/9/a/b.
        #expect(id.range(
            of: "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil)
        // Stable across repeated access on the same instance.
        #expect(store.deviceId == id)
    }

    @Test("deviceId is stable across AuthStore instances sharing a Keychain")
    func deviceIdStableAcrossInstances() {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }

        let first = AuthStore(keychain: kc).deviceId
        let second = AuthStore(keychain: kc).deviceId
        #expect(first == second)
        #expect(kc.string(.deviceId) == first)
    }
}
