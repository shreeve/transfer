/// Login passwords the user asked Transfer to remember: generic passwords in the login Keychain,
/// service "Transfer", one per saved server, keyed by its `ConnectionID`.

import Foundation
import Security

enum KeychainStore {
    static func load(account: String) -> String? {
        var item: CFTypeRef?
        let search = query(account).merging([kSecReturnData as String: true]) { $1 }
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(account: String, secret: String) {
        delete(account: account)
        SecItemAdd(query(account).merging([kSecValueData as String: Data(secret.utf8)]) { $1 } as CFDictionary, nil)
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Transfer",
            kSecAttrAccount as String: account,
        ]
    }
}
