import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// `TransferHub` with no server.
struct HubTests {
    /// A crash or force-quit leaves a login's askpass folder, host-key probe, and fingerprint scratch
    /// under the library root. The next launch removes them all (the library lock means no other
    /// copy is mid-login), and nothing else.
    @Test func launchRemovesLeftoverLoginScratch() throws {
        let base = TestCaches.fresh("hub")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("library", isDirectory: true)
        let ask = root.appendingPathComponent("ask-\(UUID().uuidString)", isDirectory: true)
        let probe = root.appendingPathComponent("hostkey-\(UUID().uuidString)", isDirectory: true)
        let key = root.appendingPathComponent("key-\(UUID().uuidString)")
        let kept = root.appendingPathComponent("Live/\(UUID().uuidString)", isDirectory: true)
        for folder in [ask, probe, kept] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("#!/bin/sh\n".utf8).write(to: ask.appendingPathComponent("askpass.sh"))
        try Data("host ssh-ed25519 AAAA\n".utf8).write(to: probe.appendingPathComponent("known_hosts"))
        try Data("host ssh-ed25519 AAAA\n".utf8).write(to: key)

        _ = try TransferHub(root: root)

        #expect(!FileManager.default.fileExists(atPath: ask.path))
        #expect(!FileManager.default.fileExists(atPath: probe.path))
        #expect(!FileManager.default.fileExists(atPath: key.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("transfer.sqlite").path))
    }

    /// A download's temp left by a crash goes at the next launch. The recorded path is removed only
    /// when it names a file by a temp's name, never a folder, and every record is forgotten.
    @Test func launchRemovesOnlyLeftoverTempFiles() throws {
        let base = TestCaches.fresh("hubtemp")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("library", isDirectory: true)
        let store = try Store(root: root)
        let temp = base.appendingPathComponent(KeepBothName.temp(for: "a.txt"))
        let folder = base.appendingPathComponent(KeepBothName.temp(for: "b"), isDirectory: true)
        let document = base.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in [temp, folder.appendingPathComponent("inside"), document] { try Data("x".utf8).write(to: file) }
        for recorded in [temp, folder, document] { store.rememberTemp(local: recorded) }

        _ = try TransferHub(root: root)

        #expect(!FileManager.default.fileExists(atPath: temp.path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("inside").path))
        #expect(FileManager.default.fileExists(atPath: document.path))
        #expect(store.localTemps().isEmpty)
        #expect(!TransferHub.isTempName(".a.transfer-1"))
        #expect(!TransferHub.isTempName("a.transfer-\(UUID().uuidString)"))
    }

    /// Two copies on one library would sweep each other's login scratch, temps, and control
    /// sockets, so the second copy is refused until the first lets go.
    @Test func oneCopyOfTransferPerLibrary() async throws {
        let root = TestCaches.fresh("lock")
        defer { try? FileManager.default.removeItem(at: root) }
        var first: TransferHub? = try TransferHub(root: root)
        _ = withExtendedLifetime(first) {
            #expect(throws: TransferError.self) { _ = try TransferHub(root: root) }
        }
        first = nil
        // A process another test is starting at this moment holds a copy of every descriptor
        // until it runs its program, the lock's too, so the lock can take a moment to come free.
        #expect(await waitUntil(2) { (try? TransferHub(root: root)) != nil })
    }

    /// A library at a custom root, as in tests and development builds, keeps its caches inside
    /// that root, never in the user's `~/Library/Caches/Transfer`.
    @Test func aCustomLibraryKeepsItsCachesInside() throws {
        let base = TestCaches.fresh("cache")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("library", isDirectory: true)
        let store = try Store(root: root)
        #expect(store.cacheRoot == root.appendingPathComponent("Caches", isDirectory: true))
    }

    /// Clear Preview Cache once belonged to a server's session, so a window with none did nothing.
    @Test func theHubClearsEveryServersPreviews() async throws {
        let base = TestCaches.fresh("clear")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("library", isDirectory: true)
        let hub = try TransferHub(root: root)
        let page = root.appendingPathComponent("Caches/Preview/box/notes.html")
        try FileManager.default.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<p>".utf8).write(to: page)
        await hub.clearPreviewCache()
        #expect(!FileManager.default.fileExists(atPath: page.path))
    }

    /// Remove Server refuses while a Live copy holds unsynced edits, and leaves the copy alone.
    @Test func removeServerRefusesWhileLiveEditsAreUnsynced() async throws {
        let base = TestCaches.fresh("hubrm")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("library", isDirectory: true)
        let store = try Store(root: root)
        let saved = SavedConnection(name: "box", host: "box.invalid", user: "u", port: "", identityFile: "", remotePath: "")
        store.save(saved)
        let id = LiveFileID()
        let folder = root.appendingPathComponent("Live/\(saved.id.rawValue.uuidString)/\(id.rawValue.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("notes.txt")
        try Data("edited".utf8).write(to: copy)
        store.saveLive(LiveRow(id: id, connection: saved.id, path: RemotePath(string: "/notes.txt"), baseSize: 1, baseMtime: 1, localPath: copy.path, dirty: true))

        let hub = try TransferHub(root: root)
        await #expect(throws: TransferError.liveUnsynced(1)) { try await hub.removeConnection(saved.id) }
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(try await hub.savedConnections().map(\.id) == [saved.id])
    }

    @Test func extensionsAreCleanedAndSaved() async throws {
        let base = TestCaches.fresh("hubext")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("library", isDirectory: true)
        let hub = try TransferHub(root: root)
        try await hub.setEditableExtensions([" .TXT", "md", "txt", "", ".Swift."])
        #expect(await hub.editableExtensions() == ["txt", "md", "swift"])
        #expect(ConfigLoader.load(root: root).editableExtensions == ["txt", "md", "swift"])
    }

    /// Every window gets the one session for a server until the saved server changes; a save that
    /// changes nothing keeps it. The session replaced never logs in again.
    @Test func sessionsAreSharedUntilTheServerChanges() async throws {
        let base = TestCaches.fresh("hubshare")
        defer { try? FileManager.default.removeItem(at: base) }
        let hub = try TransferHub(root: base.appendingPathComponent("library", isDirectory: true))
        var saved = SavedConnection(name: "box", host: "box.invalid", user: "u", port: "", identityFile: "", remotePath: "")
        try await hub.save(saved)
        let first = try #require(try await hub.session(for: saved.id) as? SSHConnection)
        try await hub.save(saved)
        let again = try #require(try await hub.session(for: saved.id) as? SSHConnection)
        #expect(first === again)
        saved.host = "other.invalid"
        try await hub.save(saved)
        let replaced = try #require(try await hub.session(for: saved.id) as? SSHConnection)
        #expect(replaced !== first)
        #expect(replaced.connection.host == "other.invalid")
        await #expect(throws: SSHConnection.retiredError) { _ = try await first.connect(prompts: TestPrompts()) }
    }

    /// The first launch writes the built-in list, and a config.json as 0.1.7 wrote it, with the
    /// bundled file's layout, loads as it is and is left alone.
    @Test func theFirstLaunchWritesTheDefaultsAnd017sConfigLoads() throws {
        let root = TestCaches.fresh("config017")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("config.json")
        #expect(ConfigLoader.load(root: root) == .builtIn)
        #expect(ConfigLoader.load(root: root) == .builtIn)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let released = Data("{\n  \"editableExtensions\": [\n    \"rip\",\n    \"txt\",\n    \"log\"\n  ]\n}\n".utf8)
        try released.write(to: file)
        #expect(ConfigLoader.load(root: root).editableExtensions == ["rip", "txt", "log"])
        #expect(try Data(contentsOf: file) == released)
    }

    /// A config.json that no longer decodes is copied aside before the defaults take over, since
    /// the next Settings save rewrites it.
    @Test func anUnreadableConfigIsKeptAside() throws {
        let root = TestCaches.fresh("config")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("config.json")
        try Data("{ not json".utf8).write(to: file)
        let config = ConfigLoader.load(root: root)
        #expect(!config.editableExtensions.isEmpty)
        #expect(try Data(contentsOf: root.appendingPathComponent("config.json.bak")) == Data("{ not json".utf8))
        #expect(try Data(contentsOf: file) == Data("{ not json".utf8))
    }
}
