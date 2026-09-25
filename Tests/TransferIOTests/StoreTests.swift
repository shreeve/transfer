import Foundation
import SQLite3
import Testing
import TransferCore
@testable import TransferIO

/// The library database: every older library opens with every row intact, and the Store's own
/// writes round-trip. Fixtures are built here from the DDL each earlier build ran, through a raw
/// SQLite connection, as those builds wrote them.
struct StoreTests {
    /// Every schema a user's library can have from before `user_version`.
    enum Shape: CaseIterable {
        /// 987e85d, the first build: five tables, nothing added.
        case first
        /// 912741b: `live_files.dirty` and `temps.connection_id` added.
        case owners
        /// 0.1.0 through 0.1.7: and the Live sync columns.
        case released

        /// The statements that build ran at every launch, verbatim.
        var ddl: String {
            let base = """
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
            """
            let owners = """
            ALTER TABLE live_files ADD COLUMN dirty INTEGER DEFAULT 0;
            ALTER TABLE temps ADD COLUMN connection_id TEXT;
            """
            let sync = ["paused INTEGER DEFAULT 0", "conflict TEXT", "conflict_size INTEGER", "conflict_mtime INTEGER",
                        "synced_size INTEGER", "synced_mtime REAL", "synced_digest TEXT"]
                .map { "ALTER TABLE live_files ADD COLUMN \($0);" }.joined(separator: "\n")
            switch self {
            case .first: return base
            case .owners: return base + owners
            case .released: return base + owners + sync
            }
        }

        /// Rows as that build's Store wrote them: text paths, `Int64(bitPattern:)` sizes.
        var rows: String {
            var sql = """
            INSERT INTO connections VALUES ('\(alpha)', 'Alpha', 'alpha.example', 'ann', '2222', '/Users/ann/.ssh/id_ed25519', '/srv/www');
            INSERT INTO connections VALUES ('\(beta)', 'Beta', 'beta.example', '', '', '', '');
            INSERT INTO recents VALUES ('\(alpha)', '/srv', 1.5);
            INSERT INTO pins VALUES ('\(alpha)', '/srv/www'), ('\(alpha)', '/home/zoë'), ('\(beta)', '/');
            """
            switch self {
            case .first:
                sql += """
                INSERT INTO live_files VALUES ('\(one)', '\(alpha)', '/srv/www/café.txt', 1234, 1700000000, '/lib/Live/café.txt');
                INSERT INTO live_files VALUES ('\(two)', '\(beta)', '/big.bin', -1, NULL, '/lib/Live/big.bin');
                INSERT INTO temps VALUES ('/tmp/.a.transfer-1');
                """
            case .owners:
                sql += """
                INSERT INTO live_files VALUES ('\(one)', '\(alpha)', '/srv/www/café.txt', 1234, 1700000000, '/lib/Live/café.txt', 1);
                INSERT INTO live_files VALUES ('\(two)', '\(beta)', '/big.bin', -1, NULL, '/lib/Live/big.bin', 0);
                """
            case .released:
                sql += """
                INSERT INTO live_files VALUES ('\(one)', '\(alpha)', '/srv/www/café.txt', 1234, 1700000000, '/lib/Live/café.txt', 1,
                  1, 'changed', 99, 4294967295, 1234, 780000000.25, 'ab12');
                INSERT INTO live_files VALUES ('\(two)', '\(beta)', '/big.bin', -1, NULL, '/lib/Live/big.bin', 0,
                  0, NULL, NULL, NULL, NULL, NULL, NULL);
                """
            }
            if self != .first {
                sql += """
                INSERT INTO temps VALUES ('/tmp/.a.transfer-1', ''), ('/srv/.b.transfer-2', '\(alpha)'), ('/tmp/.c.transfer-3', NULL);
                """
            }
            return sql
        }

        var expectedLive: [LiveRow] {
            let synced = self == .released
            return [
                LiveRow(id: LiveFileID(rawValue: one), connection: ConnectionID(rawValue: alpha),
                        path: RemotePath(string: "/srv/www/café.txt"), baseSize: 1234, baseMtime: 1_700_000_000,
                        localPath: "/lib/Live/café.txt", dirty: self != .first, paused: synced,
                        conflict: synced ? "changed" : nil, conflictSize: synced ? 99 : nil,
                        conflictMtime: synced ? UInt32.max : nil, syncedSize: synced ? 1234 : nil,
                        syncedMtime: synced ? 780_000_000.25 : nil, syncedDigest: synced ? "ab12" : nil),
                LiveRow(id: LiveFileID(rawValue: two), connection: ConnectionID(rawValue: beta),
                        path: RemotePath(string: "/big.bin"), baseSize: UInt64.max, baseMtime: nil,
                        localPath: "/lib/Live/big.bin", dirty: false),
            ]
        }

        var expectedLocalTemps: [URL] {
            (self == .first ? ["/tmp/.a.transfer-1"] : ["/tmp/.a.transfer-1", "/tmp/.c.transfer-3"]).map(URL.init(fileURLWithPath:))
        }

        var expectedRemoteTemps: [RemotePath] {
            self == .first ? [] : [RemotePath(string: "/srv/.b.transfer-2")]
        }
    }

    static let alpha = UUID(uuidString: "A1A1A1A1-0000-4000-8000-000000000001")!
    static let beta = UUID(uuidString: "B2B2B2B2-0000-4000-8000-000000000002")!
    static let one = UUID(uuidString: "11111111-0000-4000-8000-000000000001")!
    static let two = UUID(uuidString: "22222222-0000-4000-8000-000000000002")!

    @Test(arguments: Shape.allCases)
    func anOlderLibraryKeepsEveryRow(shape: Shape) throws {
        let root = TestCaches.fresh("store")
        defer { try? FileManager.default.removeItem(at: root) }
        try Raw.fixture(shape, at: root)

        let store = try Store(root: root)

        #expect(store.connections() == [
            SavedConnection(id: ConnectionID(rawValue: Self.alpha), name: "Alpha", host: "alpha.example", user: "ann",
                            port: "2222", identityFile: "/Users/ann/.ssh/id_ed25519", remotePath: "/srv/www"),
            SavedConnection(id: ConnectionID(rawValue: Self.beta), name: "Beta", host: "beta.example"),
        ])
        #expect(stars(store, Self.alpha) == ["/home/zoë", "/srv/www"])
        #expect(stars(store, Self.beta) == ["/"])
        #expect(describe(store.liveFiles()) == describe(shape.expectedLive))
        #expect(store.localTemps() == shape.expectedLocalTemps)
        #expect(store.remoteTemps(connection: ConnectionID(rawValue: Self.alpha)) == shape.expectedRemoteTemps)

        let raw = try Raw(root)
        #expect(raw.value("PRAGMA user_version") == "\(Store.schemaVersion)")
        #expect(raw.value("SELECT count(*) FROM sqlite_master WHERE name = 'recents'") == "0")
        // UTF-8 paths stay text, as an older Transfer matches them.
        for table in ["live_files", "pins", "temps"] {
            #expect(raw.value("SELECT group_concat(DISTINCT typeof(path)) FROM \(table)") == "text")
        }
        #expect(raw.value("PRAGMA journal_mode") == "wal")
    }

    /// Opening again, re-running every step over a migrated library, and a 0.1.7 app launching on it
    /// in between (it recreates `recents` and writes a text path) all leave the same rows.
    @Test func migrationIsIdempotentAndSurvivesADowngrade() throws {
        let root = TestCaches.fresh("store")
        defer { try? FileManager.default.removeItem(at: root) }
        try Raw.fixture(.released, at: root)
        let migrated = try dump(Store(root: root))

        #expect(try dump(Store(root: root)) == migrated)
        try Raw(root).run("PRAGMA user_version = 0")
        #expect(try dump(Store(root: root)) == migrated)

        let old = try Raw(root)
        old.launchAs017()
        let three = UUID()
        old.run("INSERT OR REPLACE INTO live_files (id, connection_id, path, local_path, dirty) VALUES ('\(three)', '\(Self.beta)', '/old/résumé.txt', '/lib/Live/x', 1)")
        let store = try Store(root: root)
        let added = store.liveFiles().first { $0.id.rawValue == three }
        #expect(added?.path == RemotePath(string: "/old/résumé.txt"))
        store.deleteLive(LiveFileID(rawValue: three))
        #expect(dump(store) == migrated)

        // A star and a temp 0.1.7 writes, as it writes them, are the same rows, and go with them.
        old.run("INSERT OR REPLACE INTO pins VALUES ('\(Self.beta)', '/'), ('\(Self.beta)', '/old'); INSERT OR REPLACE INTO temps VALUES ('/old/.t', '\(Self.alpha)')")
        #expect(stars(store, Self.beta) == ["/", "/old"])
        #expect(store.remoteTemps(connection: ConnectionID(rawValue: Self.alpha)).map(\.display) == ["/old/.t", "/srv/.b.transfer-2"])
        store.star(connection: ConnectionID(rawValue: Self.beta), path: RemotePath(string: "/old"), on: false)
        store.forgetTemp(RemotePath(string: "/old/.t"))
        #expect(dump(store) == migrated)
        try Raw(root).run("PRAGMA user_version = 2")
        #expect(try dump(Store(root: root)) == migrated)
    }

    /// Transfer 0.1.7 unstars and forgets temps with `path = ?` bound as text. On a migrated
    /// library, and on rows this build wrote, that still finds the path (R-L5); a path that is not
    /// UTF-8, stored as a blob, is one 0.1.7 could never have written.
    @Test func olderTransferStillMatchesMigratedAndNewPaths() throws {
        let root = TestCaches.fresh("store")
        defer { try? FileManager.default.removeItem(at: root) }
        try Raw.fixture(.released, at: root)
        let store = try Store(root: root)
        let alpha = ConnectionID(rawValue: Self.alpha)
        store.star(connection: alpha, path: RemotePath(string: "/srv/new"), on: true)
        store.rememberTemp(RemotePath(string: "/srv/.n.transfer-9"), connection: alpha)
        #expect(stars(store, Self.alpha) == ["/home/zoë", "/srv/new", "/srv/www"])

        let old = try Raw(root)
        old.launchAs017()
        for (sql, value) in [("DELETE FROM pins WHERE connection_id = ? AND path = ?", "/srv/www"),
                             ("DELETE FROM pins WHERE connection_id = ? AND path = ?", "/home/zoë"),
                             ("DELETE FROM pins WHERE connection_id = ? AND path = ?", "/srv/new")] {
            old.bindText(sql, Self.alpha.uuidString, value)
        }
        old.bindText("DELETE FROM temps WHERE path = ?", "/srv/.n.transfer-9")
        old.bindText("INSERT OR REPLACE INTO pins (connection_id, path) VALUES (?,?)", Self.beta.uuidString, "/")
        #expect(stars(store, Self.alpha).isEmpty)
        #expect(stars(store, Self.beta) == ["/"])
        #expect(old.value("SELECT count(*) FROM pins WHERE connection_id = '\(Self.beta)'") == "1")
        #expect(store.remoteTemps(connection: alpha) == [RemotePath(string: "/srv/.b.transfer-2")])
    }

    /// Stars and remote temps were stored as text decoded from the path, so a name that is not
    /// UTF-8 came back as a different path: a star that opened nothing, a temp never removed.
    @Test func aNonUTF8StarAndTempRoundTripExactly() throws {
        let root = TestCaches.fresh("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = RemotePath(bytes: Array("/srv/caf".utf8) + [0xE9, 0xFF, 0x80])
        let lookalike = RemotePath(bytes: Array("/srv/caf".utf8) + [0xE9])
        let alpha = ConnectionID(rawValue: Self.alpha)
        let store = try Store(root: root)
        for each in [path, lookalike] {
            store.star(connection: alpha, path: each, on: true)
            store.rememberTemp(each, connection: alpha)
        }

        let reopened = try Store(root: root)
        #expect(Set(reopened.stars(connection: alpha)) == [path, lookalike])
        #expect(Set(reopened.remoteTemps(connection: alpha)) == [path, lookalike])
        reopened.star(connection: alpha, path: path, on: false)
        reopened.forgetTemp(path)
        #expect(reopened.stars(connection: alpha) == [lookalike])
        #expect(reopened.remoteTemps(connection: alpha) == [lookalike])
    }

    /// A Live file's remote path is the server's bytes, UTF-8 or not (SFC-3, LIVE-07).
    @Test func aNonUTF8LivePathRoundTripsExactly() throws {
        let root = TestCaches.fresh("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes: [UInt8] = Array("/srv/caf".utf8) + [0xE9, 0xFF, 0x80] + Array(".txt".utf8)
        let row = LiveRow(id: LiveFileID(rawValue: UUID()), connection: ConnectionID(rawValue: Self.alpha),
                          path: RemotePath(bytes: bytes), localPath: "/lib/Live/caf.txt", dirty: true)
        try Store(root: root).saveLive(row)

        let read = try Store(root: root).liveFiles()
        #expect(read.map(\.path.bytes) == [bytes])
    }

    /// A library from a newer Transfer is refused, with a reason, and left as it was.
    @Test func aNewerLibraryIsRefusedAndUntouched() throws {
        let root = TestCaches.fresh("store")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let future = Store.schemaVersion + 1
        try Raw(root).run("CREATE TABLE future (x); PRAGMA user_version = \(future)")

        let error = #expect(throws: TransferError.self) { try Store(root: root) }
        #expect(error?.localizedDescription.contains("newer version of Transfer") == true)

        let raw = try Raw(root)
        #expect(raw.value("PRAGMA user_version") == "\(future)")
        #expect(raw.value("PRAGMA journal_mode") == "delete")
        #expect(raw.value("SELECT count(*) FROM sqlite_master WHERE name = 'future'") == "1")
    }

    /// A write that meets another process's lock waits for it rather than being dropped (SFC-12).
    @Test func aWriteWaitsForAnotherProcesssLock() throws {
        let root = TestCaches.fresh("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root)
        let other = try Raw(root)
        other.run("BEGIN IMMEDIATE; INSERT INTO pins VALUES ('\(Self.beta)', '/held')")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { other.run("COMMIT") }

        store.star(connection: ConnectionID(rawValue: Self.alpha), path: RemotePath(string: "/waited"), on: true)

        #expect(stars(store, Self.alpha) == ["/waited"])
        #expect(stars(store, Self.beta) == ["/held"])
    }

    /// Removing a server drops its rows from every table and nobody else's.
    @Test func removeTakesOnlyThatServer() throws {
        let root = TestCaches.fresh("store")
        defer { try? FileManager.default.removeItem(at: root) }
        try Raw.fixture(.released, at: root)
        let store = try Store(root: root)

        store.remove(ConnectionID(rawValue: Self.alpha))

        #expect(store.connections().map(\.name) == ["Beta"])
        #expect(stars(store, Self.alpha).isEmpty)
        #expect(stars(store, Self.beta) == ["/"])
        #expect(store.liveFiles().map(\.id.rawValue) == [Self.two])
        #expect(store.remoteTemps(connection: ConnectionID(rawValue: Self.alpha)).isEmpty)
        #expect(store.localTemps() == Shape.released.expectedLocalTemps)
    }

    private func describe(_ rows: [LiveRow]) -> [String] {
        rows.map { String(describing: $0) }.sorted()
    }

    private func stars(_ store: Store, _ connection: UUID) -> [String] {
        store.stars(connection: ConnectionID(rawValue: connection)).map(\.display)
    }

    private func dump(_ store: Store) -> [String] {
        store.connections().map { String(describing: $0) }
            + [Self.alpha, Self.beta].flatMap { stars(store, $0) }
            + describe(store.liveFiles())
            + store.localTemps().map(\.path)
            + store.remoteTemps(connection: ConnectionID(rawValue: Self.alpha)).map(\.display)
    }
}

/// A plain SQLite connection to `transfer.sqlite` under a root, standing in for an older build or
/// another process.
private final class Raw: @unchecked Sendable {
    private var db: OpaquePointer?

    init(_ root: URL) throws {
        guard sqlite3_open(root.appendingPathComponent("transfer.sqlite").path, &db) == SQLITE_OK else {
            throw TransferError.failed("open")
        }
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit {
        sqlite3_close(db)
    }

    static func fixture(_ shape: StoreTests.Shape, at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let raw = try Raw(root)
        raw.run(shape.ddl)
        raw.run(shape.rows)
    }

    /// What Transfer 0.1.7's `Store.init` ran on every launch, errors ignored as it ignored them.
    func launchAs017() {
        run(StoreTests.Shape.first.ddl)
        for column in ["dirty INTEGER DEFAULT 0", "paused INTEGER DEFAULT 0", "conflict TEXT", "conflict_size INTEGER",
                       "conflict_mtime INTEGER", "synced_size INTEGER", "synced_mtime REAL", "synced_digest TEXT"] {
            sqlite3_exec(db, "ALTER TABLE live_files ADD COLUMN \(column)", nil, nil, nil)
        }
        sqlite3_exec(db, "ALTER TABLE temps ADD COLUMN connection_id TEXT", nil, nil, nil)
    }

    func run(_ sql: String) {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &message)
        #expect(result == SQLITE_OK, "\(message.map { String(cString: $0) } ?? "")")
        sqlite3_free(message)
    }

    /// Runs `sql` with every parameter bound as text, as 0.1.7 bound paths.
    func bindText(_ sql: String, _ values: String...) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK)
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        #expect(sqlite3_step(statement) == SQLITE_DONE)
    }

    /// The first column of the first row, as text.
    func value(_ sql: String) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }
}
