import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// `TransferHub` with no server.
struct HubTests {
    /// A crash or force-quit leaves a login's askpass folder, host-key probe, and fingerprint scratch
    /// under the library root. The next launch removes them and nothing else. Another copy of
    /// Transfer on the same library may be mid-login: scratch a running process owns stays.
    @Test func launchRemovesLeftoverLoginScratch() throws {
        let base = TestCaches.fresh("hub")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("library", isDirectory: true)
        // Above the largest process id, so nobody owns it.
        let ask = root.appendingPathComponent("ask-999999-\(UUID().uuidString)", isDirectory: true)
        let probe = root.appendingPathComponent("hostkey-\(UUID().uuidString)", isDirectory: true)
        let key = root.appendingPathComponent("key-\(UUID().uuidString)")
        let kept = root.appendingPathComponent("Live/\(UUID().uuidString)", isDirectory: true)
        let running = root.appendingPathComponent("ask-\(getppid())-\(UUID().uuidString)", isDirectory: true)
        for folder in [ask, probe, kept, running] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("#!/bin/sh\n".utf8).write(to: ask.appendingPathComponent("askpass.sh"))
        try Data("host ssh-ed25519 AAAA\n".utf8).write(to: probe.appendingPathComponent("known_hosts"))
        try Data("host ssh-ed25519 AAAA\n".utf8).write(to: key)

        _ = try TransferHub(root: root)

        #expect(!FileManager.default.fileExists(atPath: ask.path))
        #expect(!FileManager.default.fileExists(atPath: probe.path))
        #expect(!FileManager.default.fileExists(atPath: key.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(FileManager.default.fileExists(atPath: running.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("transfer.sqlite").path))
    }

    /// Two copies on one library would sweep each other's login scratch, temps, and control
    /// sockets, so the second copy is refused until the first lets go.
    @Test func oneCopyOfTransferPerLibrary() throws {
        let root = TestCaches.fresh("lock")
        defer { try? FileManager.default.removeItem(at: root) }
        var first: TransferHub? = try TransferHub(root: root)
        #expect(throws: TransferError.self) { _ = try TransferHub(root: root) }
        #expect(first != nil)
        first = nil
        _ = try TransferHub(root: root)
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

    /// Remove Server refuses while a Live copy holds unsynced edits, and leaves the copy alone.
    @Test func removeServerRefusesWhileLiveEditsAreUnsynced() async throws {
        let base = TestCaches.fresh("hubrm")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("library", isDirectory: true)
        let store = try Store(root: root)
        let saved = SavedConnection(name: "box", host: "box.invalid", user: "u", port: "", identityFile: "", remotePath: "")
        store.save(saved)
        let folder = root.appendingPathComponent("Live/\(saved.id.rawValue.uuidString)/one", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("notes.txt")
        try Data("edited".utf8).write(to: copy)
        store.saveLive(LiveRow(id: LiveFileID(), connection: saved.id, path: RemotePath(string: "/notes.txt"), baseSize: 1, baseMtime: 1, localPath: copy.path, dirty: true))

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

    /// Every window gets the one session for a server until the saved server changes.
    @Test func sessionsAreSharedUntilTheServerChanges() async throws {
        let base = TestCaches.fresh("hubshare")
        defer { try? FileManager.default.removeItem(at: base) }
        let hub = try TransferHub(root: base.appendingPathComponent("library", isDirectory: true))
        var saved = SavedConnection(name: "box", host: "box.invalid", user: "u", port: "", identityFile: "", remotePath: "")
        try await hub.save(saved)
        let first = try #require(try await hub.session(for: saved.id) as? SSHConnection)
        let again = try #require(try await hub.session(for: saved.id) as? SSHConnection)
        #expect(first === again)
        saved.host = "other.invalid"
        try await hub.save(saved)
        let replaced = try #require(try await hub.session(for: saved.id) as? SSHConnection)
        #expect(replaced !== first)
        #expect(replaced.connection.host == "other.invalid")
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
