import Testing
import Foundation
@testable import Snapceipt

@Suite("Keychain")
struct KeychainTests {
    /// A fresh, uniquely-namespaced Keychain per test so suites never collide,
    /// with all canonical keys cleared on entry.
    private func freshKeychain() -> Keychain {
        let kc = Keychain(service: "app.snapceipt.tests." + UUID().uuidString)
        for key in KeychainKey.allCases { kc.delete(key) }
        return kc
    }

    @Test("set then string round-trips the exact value")
    func setGetRoundTrip() throws {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }

        #expect(kc.string(.accessToken) == nil)
        kc.set("acc-123", .accessToken)
        #expect(kc.string(.accessToken) == "acc-123")
    }

    @Test("set on an existing key overwrites (update path)")
    func setOverwrites() throws {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }

        kc.set("first", .refreshToken)
        kc.set("second", .refreshToken)
        #expect(kc.string(.refreshToken) == "second")
    }

    @Test("delete removes the value")
    func deleteRemoves() throws {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }

        kc.set("temp", .deviceId)
        #expect(kc.string(.deviceId) == "temp")
        kc.delete(.deviceId)
        #expect(kc.string(.deviceId) == nil)
    }

    @Test("delete on a missing key is a no-op (no crash)")
    func deleteMissingIsNoop() throws {
        let kc = freshKeychain()
        kc.delete(.accessToken)
        #expect(kc.string(.accessToken) == nil)
    }

    @Test("keys are isolated from one another")
    func keysAreIsolated() throws {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }

        kc.set("A", .accessToken)
        kc.set("B", .refreshToken)
        #expect(kc.string(.accessToken) == "A")
        #expect(kc.string(.refreshToken) == "B")
        #expect(kc.string(.deviceId) == nil)
    }

    @Test("values survive within the same store instance (read-after-write)")
    func persistsWithinStore() throws {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }

        kc.set("persisted-value", .refreshToken)
        let again = Keychain(service: kc.service) // a new wrapper over the same service
        #expect(again.string(.refreshToken) == "persisted-value")
    }
}
