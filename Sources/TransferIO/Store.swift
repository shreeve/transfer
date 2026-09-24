/// The library database, `transfer.sqlite` under the library root: saved servers, stars, Live
/// file records, and the temps a copy has in flight. Its schema version is `PRAGMA user_version`.
/// Opening a library carries it forward through `migrations`, one transaction per step, and
/// refuses one written by a newer Transfer rather than guess at its schema.

import Foundation
import os
import SQLite3
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
    private static let log = Logger(subsystem: "com.github.shreeve.transfer", category: "library")
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
        do {
            guard sqlite3_open(path, &db) == SQLITE_OK else { throw TransferError.failed("Could not open the library") }
            try open()
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: Schema

    /// The newest schema this build knows; `migrate(from:)` has a step for each one before it.
    static let schemaVersion = 3

    private func open() throws {
        // A development build and the installed app can have the same library open; a write
        // waits for the other's lock instead of failing at once.
        sqlite3_busy_timeout(db, 5_000)
        while try transaction(migrateOneStep) {}
        // WAL makes a commit one append to the log instead of a rollback journal's create, write,
        // fsync, and unlink, and lets a reader in the other process proceed during a write. The
        // mode is kept in the file. It cannot change during another process's transaction; then
        // this launch keeps the old mode and the next one tries again. FULL still fsyncs the log
        // at every commit, so a power loss cannot roll back a Live record that was written;
        // NORMAL would halve the cost again (0.035 ms a temps pair) but give up that promise.
        report("switch the library to WAL") { try execute("PRAGMA journal_mode = WAL") }
        try execute("PRAGMA synchronous = FULL")
    }

    /// Runs inside a write transaction, so the version it reads is not stale: another process may
    /// have migrated while this one waited for the lock. False once the library is current.
    private func migrateOneStep() throws -> Bool {
        let version = try userVersion()
        guard version <= Self.schemaVersion else {
            throw TransferError.failed("This library was written by a newer version of Transfer (schema \(version); this version knows \(Self.schemaVersion)). Update Transfer to open it.")
        }
        guard version < Self.schemaVersion else { return false }
        try migrate(from: version)
        try execute("PRAGMA user_version = \(version + 1)")
        return true
    }

    /// Brings the library from `version` to `version + 1`.
    private func migrate(from version: Int) throws {
        switch version {
        case 0:
            try adoptReleasedSchema()
        case 1:
            // Recents were written and never read. A Live file's remote path is the server's exact
            // bytes, which need not be UTF-8; earlier builds stored it as text, and a text row
            // converts to the same bytes.
            try execute("""
            DROP TABLE IF EXISTS recents;
            UPDATE live_files SET path = CAST(path AS BLOB) WHERE typeof(path) = 'text';
            """)
        case 2:
            // Stars and remote temps are server paths too. A text row and a blob of the same bytes
            // are different keys, so a row one of them already holds is replaced, not doubled.
            try execute("""
            UPDATE OR REPLACE pins SET path = CAST(path AS BLOB) WHERE typeof(path) = 'text';
            UPDATE OR REPLACE temps SET path = CAST(path AS BLOB) WHERE typeof(path) = 'text';
            """)
        default:
            preconditionFailure("No migration from library schema \(version)")
        }
    }

    /// Version 1 is the schema of Transfer 0.1.0 through 0.1.7, which kept no version: every launch
    /// created missing tables and tried to add each column a later build had introduced. Any
    /// library at version 0, from those releases or the builds before them, becomes exactly that.
    private func adoptReleasedSchema() throws {
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
        let added = [
            ("live_files", "dirty INTEGER DEFAULT 0"), ("temps", "connection_id TEXT"),
            ("live_files", "paused INTEGER DEFAULT 0"), ("live_files", "conflict TEXT"),
            ("live_files", "conflict_size INTEGER"), ("live_files", "conflict_mtime INTEGER"),
            ("live_files", "synced_size INTEGER"), ("live_files", "synced_mtime REAL"),
            ("live_files", "synced_digest TEXT"),
        ]
        for (table, column) in added {
            var present = false
            try run("SELECT 1 FROM pragma_table_info(?) WHERE name = ?", table, String(column.prefix { $0 != " " })) { _ in present = true }
            if !present { try execute("ALTER TABLE \(table) ADD COLUMN \(column)") }
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
        write(
            "INSERT OR REPLACE INTO connections (id, name, host, user, port, identity, remote_path) VALUES (?,?,?,?,?,?,?)",
            connection.id.rawValue.uuidString, connection.name, connection.host, connection.user,
            connection.port, connection.identityFile, connection.remotePath
        )
    }

    /// Everything the library holds for a server, in one transaction.
    func remove(_ id: ConnectionID) {
        queue.sync {
            let key = id.rawValue.uuidString
            report("remove a saved server") {
                try transaction {
                    try run("DELETE FROM connections WHERE id = ?", key)
                    for table in ["pins", "live_files", "temps"] {
                        try run("DELETE FROM \(table) WHERE connection_id = ?", key)
                    }
                }
            }
        }
    }

    // MARK: Stars

    // Paths in `pins` and `temps` are blobs of their exact bytes. They are matched and read as
    // blobs, so a text row an older Transfer writes to the same library is the same path.

    /// Starred paths live in the `pins` table, named before the sidebar called them Starred.
    func stars(connection: ConnectionID) -> [RemotePath] {
        paths("SELECT DISTINCT CAST(path AS BLOB) FROM pins WHERE connection_id = ? ORDER BY 1", connection.rawValue.uuidString)
            .map(RemotePath.init(bytes:))
    }

    func star(connection: ConnectionID, path: RemotePath, on: Bool) {
        if on {
            write("INSERT OR REPLACE INTO pins (connection_id, path) VALUES (?,?)", connection.rawValue.uuidString, path.bytes)
        } else {
            write("DELETE FROM pins WHERE connection_id = ? AND CAST(path AS BLOB) = ?", connection.rawValue.uuidString, path.bytes)
        }
    }

    // MARK: Temps

    func rememberTemp(_ path: RemotePath, connection: ConnectionID) {
        write("INSERT OR REPLACE INTO temps (path, connection_id) VALUES (?,?)", path.bytes, connection.rawValue.uuidString)
    }

    func rememberTemp(local url: URL) {
        write("INSERT OR REPLACE INTO temps (path, connection_id) VALUES (?,?)", Array(url.path.utf8), "")
    }

    func forgetTemp(_ path: RemotePath) {
        write("DELETE FROM temps WHERE CAST(path AS BLOB) = ?", path.bytes)
    }

    func forgetTemp(local url: URL) {
        write("DELETE FROM temps WHERE CAST(path AS BLOB) = ?", Array(url.path.utf8))
    }

    func localTemps() -> [URL] {
        paths("SELECT DISTINCT CAST(path AS BLOB) FROM temps WHERE connection_id IS NULL OR connection_id = '' ORDER BY 1")
            .map { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) }
    }

    func remoteTemps(connection: ConnectionID) -> [RemotePath] {
        paths("SELECT DISTINCT CAST(path AS BLOB) FROM temps WHERE connection_id = ? ORDER BY 1", connection.rawValue.uuidString)
            .map(RemotePath.init(bytes:))
    }

    // MARK: Live files

    private static let liveColumns = "id, connection_id, path, base_size, base_mtime, local_path, dirty, paused, conflict, conflict_size, conflict_mtime, synced_size, synced_mtime, synced_digest"

    /// Every Live row, or one connection's.
    func liveFiles(connection: ConnectionID? = nil) -> [LiveRow] {
        queue.sync {
            var rows: [LiveRow] = []
            let sql = "SELECT \(Self.liveColumns) FROM live_files" + (connection == nil ? "" : " WHERE connection_id = ?")
            report("read Live files") {
                try run(sql, connection.map { [$0.rawValue.uuidString] } ?? []) { row in
                    guard let id = UUID(uuidString: row.text(0)), let owner = UUID(uuidString: row.text(1)) else { return }
                    rows.append(LiveRow(
                        id: LiveFileID(rawValue: id),
                        connection: ConnectionID(rawValue: owner),
                        path: RemotePath(bytes: row.bytes(2)),
                        baseSize: row.int(3).map { UInt64(bitPattern: $0) },
                        baseMtime: row.int(4).map { UInt32(truncatingIfNeeded: $0) },
                        localPath: row.text(5),
                        dirty: (row.int(6) ?? 0) != 0,
                        paused: (row.int(7) ?? 0) != 0,
                        conflict: row.string(8),
                        conflictSize: row.int(9).map { UInt64(bitPattern: $0) },
                        conflictMtime: row.int(10).map { UInt32(truncatingIfNeeded: $0) },
                        syncedSize: row.int(11).map { UInt64(bitPattern: $0) },
                        syncedMtime: row.double(12),
                        syncedDigest: row.string(13)
                    ))
                }
            }
            return rows
        }
    }

    func saveLive(_ row: LiveRow) {
        write(
            "INSERT OR REPLACE INTO live_files (\(Self.liveColumns)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            row.id.rawValue.uuidString, row.connection.rawValue.uuidString, row.path.bytes,
            row.baseSize.map { Int64(bitPattern: $0) }, row.baseMtime.map { Int64($0) }, row.localPath,
            Int64(row.dirty ? 1 : 0), Int64(row.paused ? 1 : 0), row.conflict,
            row.conflictSize.map { Int64(bitPattern: $0) }, row.conflictMtime.map { Int64($0) },
            row.syncedSize.map { Int64(bitPattern: $0) }, row.syncedMtime, row.syncedDigest
        )
    }

    func deleteLive(_ id: LiveFileID) {
        write("DELETE FROM live_files WHERE id = ?", id.rawValue.uuidString)
    }

    // MARK: Plumbing

    private func queryConnections() -> [SavedConnection] {
        var values: [SavedConnection] = []
        report("read saved servers") {
            try run("SELECT id, name, host, user, port, identity, remote_path FROM connections ORDER BY name") { row in
                values.append(SavedConnection(
                    id: ConnectionID(rawValue: UUID(uuidString: row.text(0)) ?? UUID()),
                    name: row.text(1),
                    host: row.text(2),
                    user: row.text(3),
                    port: row.text(4),
                    identityFile: row.text(5),
                    remotePath: row.text(6)
                ))
            }
        }
        return values
    }

    private func paths(_ sql: String, _ value: String? = nil) -> [[UInt8]] {
        queue.sync {
            var values: [[UInt8]] = []
            report("read the library") { try run(sql, value.map { [$0] } ?? []) { values.append($0.bytes(0)) } }
            return values
        }
    }

    /// The public API cannot throw, so a failed statement is logged with SQLite's reason.
    private func write(_ sql: String, _ values: (any SQLValue)?...) {
        queue.sync { report("write the library") { try run(sql, values) } }
    }

    private func report(_ action: String, _ body: () throws -> Void) {
        do { try body() } catch { Self.log.error("Could not \(action, privacy: .public): \(error.localizedDescription, privacy: .public)") }
    }

    private func run(_ sql: String, _ values: (any SQLValue)?..., row: (Row) -> Void = { _ in }) throws {
        try run(sql, values, row: row)
    }

    /// The one way a statement runs: prepare, bind `values` in order, step to the end calling
    /// `row` for each result row, finalize. Any result other than a row or done throws.
    private func run(_ sql: String, _ values: [(any SQLValue)?], row: (Row) -> Void = { _ in }) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            try check(value.map { $0.bind(statement, position) } ?? sqlite3_bind_null(statement, position))
        }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { return try check(result) }
            row(Row(statement: statement))
        }
    }

    /// Runs one or more statements that bind nothing and return no rows.
    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil))
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func userVersion() throws -> Int {
        var version = 0
        try run("PRAGMA user_version") { version = Int($0.int(0) ?? 0) }
        return version
    }

    private func check(_ result: Int32) throws {
        guard result != SQLITE_OK else { return }
        throw TransferError.failed("Library: \(String(cString: sqlite3_errmsg(db)))")
    }
}

/// A value `Store.run` can bind to a statement parameter; `nil` binds NULL.
private protocol SQLValue {
    func bind(_ statement: OpaquePointer?, _ index: Int32) -> Int32
}

extension String: SQLValue {
    fileprivate func bind(_ statement: OpaquePointer?, _ index: Int32) -> Int32 {
        sqlite3_bind_text(statement, index, self, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}

extension Int64: SQLValue {
    fileprivate func bind(_ statement: OpaquePointer?, _ index: Int32) -> Int32 {
        sqlite3_bind_int64(statement, index, self)
    }
}

extension Double: SQLValue {
    fileprivate func bind(_ statement: OpaquePointer?, _ index: Int32) -> Int32 {
        sqlite3_bind_double(statement, index, self)
    }
}

extension [UInt8]: SQLValue {
    /// A blob, byte for byte. An empty one is bound as a zero-length blob, not NULL.
    fileprivate func bind(_ statement: OpaquePointer?, _ index: Int32) -> Int32 {
        withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return sqlite3_bind_zeroblob(statement, index, 0) }
            return sqlite3_bind_blob(statement, index, base, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }
}

/// One result row, valid only inside the `row` callback.
private struct Row {
    let statement: OpaquePointer?

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    /// The column's bytes: a blob's as stored, a text's in UTF-8.
    func bytes(_ column: Int32) -> [UInt8] {
        guard let base = sqlite3_column_blob(statement, column) else { return [] }
        return Array(UnsafeRawBufferPointer(start: base, count: Int(sqlite3_column_bytes(statement, column))))
    }

    /// "" for NULL.
    func text(_ column: Int32) -> String {
        String(decoding: bytes(column), as: UTF8.self)
    }

    func string(_ column: Int32) -> String? {
        isNull(column) ? nil : text(column)
    }

    func int(_ column: Int32) -> Int64? {
        isNull(column) ? nil : sqlite3_column_int64(statement, column)
    }

    func double(_ column: Int32) -> Double? {
        isNull(column) ? nil : sqlite3_column_double(statement, column)
    }
}
