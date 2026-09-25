/// Login secrets the user asked Transfer to remember: generic passwords in the login Keychain,
/// service "Transfer", per saved server and kind. A server's password is under its `ConnectionID`
/// (as 0.1.7 kept any secret), a key passphrase under the id and " passphrase", so a passphrase is
/// never sent to a server as its password.

import Foundation
import Security
import TransferCore

enum KeychainStore {
    enum Kind: Hashable {
        case password
        case passphrase
    }

    static func load(_ id: ConnectionID, _ kind: Kind) -> String? {
        var item: CFTypeRef?
        let search = query(account(id, kind)).merging([kSecReturnData as String: true]) { $1 }
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ secret: String, for id: ConnectionID, _ kind: Kind) {
        let account = account(id, kind)
        SecItemDelete(query(account) as CFDictionary)
        SecItemAdd(query(account).merging([kSecValueData as String: Data(secret.utf8)]) { $1 } as CFDictionary, nil)
    }

    /// Every secret kept for the server.
    static func delete(_ id: ConnectionID) {
        for kind in [Kind.password, .passphrase] { SecItemDelete(query(account(id, kind)) as CFDictionary) }
    }

    private static func account(_ id: ConnectionID, _ kind: Kind) -> String {
        kind == .password ? id.rawValue.uuidString : id.rawValue.uuidString + " passphrase"
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Transfer",
            kSecAttrAccount as String: account,
        ]
    }
}
