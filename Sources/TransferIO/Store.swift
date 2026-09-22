import Foundation
import SQLite3
import Security
import TransferCore

final class Store: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "transfer.store")
    let root: URL

    init() throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transfer", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        root = base
        let path = base.appendingPathComponent("transfer.sqlite").path
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw TransferError.failed("Could not open the library")
        }
        try execute("""
        CREATE TABLE IF NOT EXISTS connections (
          id TEXT PRIMARY KEY, name TEXT, host TEXT, user TEXT, port TEXT,
          identity TEXT, remote_path TEXT
        );
        CREATE TABLE IF NOT EXISTS recents (
          connection_id TEXT, path TEXT, used_at REAL,
          PRIMARY KEY (connection_id, path)
        );
        CREATE TABLE IF NOT EXISTS pins (
          connection_id TEXT, path TEXT, PRIMARY KEY (connection_id, path)
        );
        CREATE TABLE IF NOT EXISTS live_files (
          id TEXT PRIMARY KEY, connection_id TEXT, path TEXT,
          base_size INTEGER, base_mtime INTEGER, local_path TEXT
        );
        CREATE TABLE IF NOT EXISTS temps (path TEXT PRIMARY KEY);
        """)
    }

    func connections() -> [SavedConnection] {
        queue.sync { queryConnections() }
    }

    func save(_ connection: SavedConnection) {
        queue.sync {
            bind(
                "INSERT OR REPLACE INTO connections (id, name, host, user, port, identity, remote_path) VALUES (?,?,?,?,?,?,?)",
                connection.id.rawValue.uuidString,
                connection.name,
                connection.host,
                connection.user,
                connection.port,
                connection.identityFile,
                connection.remotePath
            )
        }
    }

    func remove(_ id: ConnectionID) {
        queue.sync {
            bind("DELETE FROM connections WHERE id = ?", id.rawValue.uuidString)
            bind("DELETE FROM recents WHERE connection_id = ?", id.rawValue.uuidString)
            bind("DELETE FROM pins WHERE connection_id = ?", id.rawValue.uuidString)
        }
    }

    func recents(connection: ConnectionID) -> [String] {
        queue.sync {
            strings("SELECT path FROM recents WHERE connection_id = ? ORDER BY used_at DESC LIMIT 10", connection.rawValue.uuidString)
        }
    }

    func remember(connection: ConnectionID, path: String) {
        queue.sync {
            bind(
                "INSERT OR REPLACE INTO recents (connection_id, path, used_at) VALUES (?,?,?)",
                connection.rawValue.uuidString,
                path,
                String(Date().timeIntervalSince1970)
            )
        }
    }

    func pins(connection: ConnectionID) -> [String] {
        queue.sync { strings("SELECT path FROM pins WHERE connection_id = ? ORDER BY path", connection.rawValue.uuidString) }
    }

    func pin(connection: ConnectionID, path: String, on: Bool) {
        queue.sync {
            if on {
                bind("INSERT OR REPLACE INTO pins (connection_id, path) VALUES (?,?)", connection.rawValue.uuidString, path)
            } else {
                bind("DELETE FROM pins WHERE connection_id = ? AND path = ?", connection.rawValue.uuidString, path)
            }
        }
    }

    func rememberTemp(_ path: String) {
        queue.sync { bind("INSERT OR REPLACE INTO temps (path) VALUES (?)", path) }
    }

    func forgetTemp(_ path: String) {
        queue.sync { bind("DELETE FROM temps WHERE path = ?", path) }
    }

    func temps() -> [String] {
        queue.sync { strings("SELECT path FROM temps", nil) }
    }

    private func queryConnections() -> [SavedConnection] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT id, name, host, user, port, identity, remote_path FROM connections ORDER BY name", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        var values: [SavedConnection] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = text(statement, 0)
            values.append(SavedConnection(
                id: ConnectionID(rawValue: UUID(uuidString: id) ?? UUID()),
                name: text(statement, 1),
                host: text(statement, 2),
                user: text(statement, 3),
                port: text(statement, 4),
                identityFile: text(statement, 5),
                remotePath: text(statement, 6)
            ))
        }
        return values
    }

    private func strings(_ sql: String, _ a: String?) -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        if let a { bindText(statement, 1, a) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { values.append(text(statement, 0)) }
        return values
    }

    private func bind(_ sql: String, _ values: String...) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        for (index, value) in values.enumerated() { bindText(statement, Int32(index + 1), value) }
        sqlite3_step(statement)
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func execute(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw TransferError.failed("Could not prepare the library")
        }
    }
}

enum KeychainStore {
    private static let service = "Transfer"

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    static func save(account: String, secret: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
