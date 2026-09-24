import Foundation
import SQLite3
import Security
import TransferCore

struct LiveRow: Sendable {
    var id: LiveFileID
    var connection: ConnectionID
    var path: RemotePath
    var baseSize: UInt64?
    var baseMtime: UInt32?
    var localPath: String
    var dirty: Bool
    var paused = false
    /// "changed", "removed", or "notAFile" while a conflict is unresolved; the server file's
    /// fingerprint when it was raised, for "changed".
    var conflict: String?
    var conflictSize: UInt64?
    var conflictMtime: UInt32?
    /// The working copy at the last sync: size, exact mtime (seconds since the reference date),
    /// and a SHA-256 of its bytes.
    var syncedSize: UInt64?
    var syncedMtime: Double?
    var syncedDigest: String?
}

final class Store: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "transfer.store")
    let root: URL
    /// Caches that can be rebuilt, such as previews: `~/Library/Caches/Transfer` for the default
    /// library, else `Caches` under the custom root, so a test or a development build never
    /// reads or evicts the user's.
    let cacheRoot: URL

    /// `root` defaults to `~/Library/Application Support/Transfer`.
    init(root customRoot: URL? = nil) throws {
        let standard = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transfer", isDirectory: true)
        let base = customRoot ?? standard
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        self.root = base
        cacheRoot = base.standardizedFileURL == standard.standardizedFileURL
            ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Transfer", isDirectory: true)
            : base.appendingPathComponent("Caches", isDirectory: true)
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
        // Columns added after the first schema. SQLite has no ADD COLUMN IF NOT EXISTS.
        _ = sqlite3_exec(db, "ALTER TABLE live_files ADD COLUMN dirty INTEGER DEFAULT 0", nil, nil, nil)
        _ = sqlite3_exec(db, "ALTER TABLE temps ADD COLUMN connection_id TEXT", nil, nil, nil)
        for column in ["paused INTEGER DEFAULT 0", "conflict TEXT", "conflict_size INTEGER", "conflict_mtime INTEGER",
                       "synced_size INTEGER", "synced_mtime REAL", "synced_digest TEXT"] {
            _ = sqlite3_exec(db, "ALTER TABLE live_files ADD COLUMN \(column)", nil, nil, nil)
        }
    }

    // MARK: Connections

    func connections() -> [SavedConnection] {
        queue.sync { queryConnections() }
    }

    func connection(_ id: ConnectionID) -> SavedConnection? {
        queue.sync { queryConnections().first { $0.id == id } }
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
            let key = id.rawValue.uuidString
            bind("DELETE FROM connections WHERE id = ?", key)
            bind("DELETE FROM recents WHERE connection_id = ?", key)
            bind("DELETE FROM pins WHERE connection_id = ?", key)
            bind("DELETE FROM live_files WHERE connection_id = ?", key)
            bind("DELETE FROM temps WHERE connection_id = ?", key)
        }
    }

    // MARK: Stars

    /// Starred paths live in the `pins` table, named before the sidebar called them Starred.
    func stars(connection: ConnectionID) -> [String] {
        queue.sync { strings("SELECT path FROM pins WHERE connection_id = ? ORDER BY path", connection.rawValue.uuidString) }
    }

    func star(connection: ConnectionID, path: String, on: Bool) {
        queue.sync {
            if on {
                bind("INSERT OR REPLACE INTO pins (connection_id, path) VALUES (?,?)", connection.rawValue.uuidString, path)
            } else {
                bind("DELETE FROM pins WHERE connection_id = ? AND path = ?", connection.rawValue.uuidString, path)
            }
        }
    }

    // MARK: Temps

    /// `connection` is nil for a temp on the local disk.
    func rememberTemp(_ path: String, connection: ConnectionID?) {
        queue.sync {
            bind("INSERT OR REPLACE INTO temps (path, connection_id) VALUES (?,?)", path, connection?.rawValue.uuidString ?? "")
        }
    }

    func forgetTemp(_ path: String) {
        queue.sync { bind("DELETE FROM temps WHERE path = ?", path) }
    }

    func localTemps() -> [String] {
        queue.sync { strings("SELECT path FROM temps WHERE connection_id IS NULL OR connection_id = ''", nil) }
    }

    func remoteTemps(connection: ConnectionID) -> [String] {
        queue.sync { strings("SELECT path FROM temps WHERE connection_id = ?", connection.rawValue.uuidString) }
    }

    // MARK: Live files

    private static let liveColumns = "id, connection_id, path, base_size, base_mtime, local_path, dirty, paused, conflict, conflict_size, conflict_mtime, synced_size, synced_mtime, synced_digest"

    /// Every Live row, or one connection's.
    func liveFiles(connection: ConnectionID? = nil) -> [LiveRow] {
        queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = "SELECT \(Self.liveColumns) FROM live_files" + (connection == nil ? "" : " WHERE connection_id = ?")
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            if let connection { bindText(statement, 1, connection.rawValue.uuidString) }
            var rows: [LiveRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: text(statement, 0)), let owner = UUID(uuidString: text(statement, 1)) else { continue }
                func int(_ column: Int32) -> Int64? {
                    sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
                }
                func string(_ column: Int32) -> String? {
                    sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column)
                }
                rows.append(LiveRow(
                    id: LiveFileID(rawValue: id),
                    connection: ConnectionID(rawValue: owner),
                    path: RemotePath(bytes: Array(text(statement, 2).utf8)),
                    baseSize: int(3).map { UInt64(bitPattern: $0) },
                    baseMtime: int(4).map { UInt32(truncatingIfNeeded: $0) },
                    localPath: text(statement, 5),
                    dirty: sqlite3_column_int(statement, 6) != 0,
                    paused: sqlite3_column_int(statement, 7) != 0,
                    conflict: string(8),
                    conflictSize: int(9).map { UInt64(bitPattern: $0) },
                    conflictMtime: int(10).map { UInt32(truncatingIfNeeded: $0) },
                    syncedSize: int(11).map { UInt64(bitPattern: $0) },
                    syncedMtime: sqlite3_column_type(statement, 12) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 12),
                    syncedDigest: string(13)
                ))
            }
            return rows
        }
    }

    func saveLive(_ row: LiveRow) {
        queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = "INSERT OR REPLACE INTO live_files (\(Self.liveColumns)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            func int(_ column: Int32, _ value: Int64?) {
                if let value { sqlite3_bind_int64(statement, column, value) } else { sqlite3_bind_null(statement, column) }
            }
            func string(_ column: Int32, _ value: String?) {
                if let value { bindText(statement, column, value) } else { sqlite3_bind_null(statement, column) }
            }
            bindText(statement, 1, row.id.rawValue.uuidString)
            bindText(statement, 2, row.connection.rawValue.uuidString)
            bindText(statement, 3, row.path.display)
            int(4, row.baseSize.map { Int64(bitPattern: $0) })
            int(5, row.baseMtime.map { Int64($0) })
            bindText(statement, 6, row.localPath)
            sqlite3_bind_int(statement, 7, row.dirty ? 1 : 0)
            sqlite3_bind_int(statement, 8, row.paused ? 1 : 0)
            string(9, row.conflict)
            int(10, row.conflictSize.map { Int64(bitPattern: $0) })
            int(11, row.conflictMtime.map { Int64($0) })
            int(12, row.syncedSize.map { Int64(bitPattern: $0) })
            if let mtime = row.syncedMtime { sqlite3_bind_double(statement, 13, mtime) } else { sqlite3_bind_null(statement, 13) }
            string(14, row.syncedDigest)
            sqlite3_step(statement)
        }
    }

    func deleteLive(_ id: LiveFileID) {
        queue.sync { bind("DELETE FROM live_files WHERE id = ?", id.rawValue.uuidString) }
    }

    func dirtyLiveCount(connection: ConnectionID? = nil) -> Int {
        queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = connection == nil
                ? "SELECT COUNT(*) FROM live_files WHERE dirty = 1"
                : "SELECT COUNT(*) FROM live_files WHERE dirty = 1 AND connection_id = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
            if let connection { bindText(statement, 1, connection.rawValue.uuidString) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    // MARK: Plumbing

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
