import Foundation
import Security

/// The three secrets Snapceipt persists in the iOS Keychain.
/// `rawValue` is the `kSecAttrAccount` for each generic-password item.
enum KeychainKey: String, CaseIterable, Sendable {
    case accessToken
    case refreshToken
    case deviceId
}

/// Thin, typed wrapper over the Security framework's generic-password items.
/// Items use service "app.snapceipt" and kSecAttrAccessibleAfterFirstUnlock so
/// the app can read tokens during background sync after the first unlock.
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

    /// Upsert a UTF-8 string under `key` (add, or update if it already exists).
    func set(_ value: String, _ key: KeychainKey) {
        let data = Data(value.utf8)

        var addQuery = baseQuery(key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Item exists — update just its data.
            let update: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
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
