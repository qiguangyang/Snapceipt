import Foundation
import Security

/// The three secrets Snapceipt persists in the iOS Keychain.
/// `rawValue` is the `kSecAttrAccount` for each generic-password item.
enum KeychainKey: String, CaseIterable, Sendable {
    case accessToken
    case refreshToken
    case deviceId
    /// The DeviceCheck App Attest key identifier (Base64), persisted once after the
    /// backend verifies the attestation. Its presence marks the key as already attested
    /// (App Attest keys can be attested only once), so a relaunch reuses it for
    /// assertions rather than re-attesting. See `AppAttestor`.
    case appAttestKeyId
}

/// Thin, typed wrapper over the Security framework's generic-password items.
/// Items use service "app.snapceipt" and
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable for background sync
/// after the first unlock, but pinned to THIS device — so tokens + the bound deviceId
/// can't ride an encrypted backup onto another device (which would undermine device
/// binding / remote revocation).
struct Keychain: Sendable {
    /// kSecAttrService for all items. Default is the app's bundle-style id;
    /// tests inject a unique value to stay isolated.
    let service: String

    init(service: String = "app.snapceipt") {
        self.service = service
    }

    /// Read a stored UTF-8 string for `key`, or nil if absent / unreadable.
    func string(_ key: KeychainKey) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Upsert a UTF-8 string under `key`. Delete-then-add (not SecItemUpdate-on-duplicate)
    /// so the accessibility attribute is (re)applied on every write — `SecItemUpdate`
    /// cannot change `kSecAttrAccessible`, so an in-place update would strand a
    /// pre-existing item on its old, weaker policy. This also makes any existing
    /// token/deviceId self-migrate to ThisDeviceOnly the next time it's written.
    func set(_ value: String, _ key: KeychainKey) {
        let data = Data(value.utf8)
        SecItemDelete(baseQuery(key) as CFDictionary)
        var addQuery = baseQuery(key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// One-time migration: rewrite every present item so it picks up the current
    /// (ThisDeviceOnly) accessibility policy. Needed because pre-existing items written
    /// before this change keep their old policy until rewritten, and the rarely-rewritten
    /// `deviceId` would otherwise never migrate. Idempotent; only touches present items.
    func reapplyAccessibility() {
        for key in KeychainKey.allCases where string(key) != nil {
            set(string(key)!, key)
        }
    }

    /// Remove the value under `key`. Missing item is treated as success (no-op).
    func delete(_ key: KeychainKey) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    /// The class/service/account selector shared by every operation.
    private func baseQuery(_ key: KeychainKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}
