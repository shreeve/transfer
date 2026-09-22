import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// These run only against a local sshd. Start one with `Scripts/local-sshd.sh` and export the
/// variables it prints: TRANSFER_TEST_PORT and TRANSFER_TEST_IDENTITY.
struct ServerTests {
    private static var port: String? { ProcessInfo.processInfo.environment["TRANSFER_TEST_PORT"] }
    private static var identity: String? { ProcessInfo.processInfo.environment["TRANSFER_TEST_IDENTITY"] }

    private struct Harness {
        let session: SSHConnection
        let root: URL
        let remote: URL
        let prompts: TestPrompts

        var remotePath: RemotePath { RemotePath(string: remote.path) }

        func cleanUp() async {
            await session.disconnect()
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
    }

    private final class TestPrompts: PromptSink, @unchecked Sendable {
        var hostDecision: HostKeyDecision = .trustOnce
        var collision: NameCollisionChoice = .replace
        var collisions = 0

        func answer(_ request: PromptRequest) async -> PromptReply { PromptReply(text: nil) }
        func decideHostKey(_ event: HostKeyEvent) async -> HostKeyDecision { hostDecision }
        func resolveCollision(fileName: String) async -> NameCollisionChoice {
            collisions += 1
            return collision
        }
    }

    private func harness(_ name: String) throws -> Harness? {
        guard let port = Self.port, let identity = Self.identity else { return nil }
        // Short on purpose: the control socket lives under this root and socket paths are capped at 104 bytes.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TransferTests/\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let root = base.appendingPathComponent("library", isDirectory: true)
        let remote = base.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let store = try Store(root: root)
        let saved = SavedConnection(name: name, host: "127.0.0.1", user: NSUserName(), port: port, identityFile: identity, remotePath: remote.path)
        let session = SSHConnection(connection: saved, store: store, editableExtensions: TransferConfig.builtIn.extensionSet)
        return Harness(session: session, root: root, remote: remote, prompts: TestPrompts())
    }

    private func randomData(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            for index in 0..<count { buffer[index] = UInt8.random(in: 0...255) }
        }
        return data
    }

    private func waitUntil(_ seconds: Double = 8, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await condition()
    }

    @Test func loginListsAndMovesBytes() async throws {
        guard let h = try harness("bytes") else { return }
        defer { Task { await h.cleanUp() } }
        let start = try await h.session.connect(prompts: h.prompts)
        #expect(start.display == h.remote.resolvingSymlinksInPath().path)
        #expect(await h.session.isConnected)
        #expect(await h.session.performanceModeEnabled == false)

        let many = h.remote.appendingPathComponent("many")
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        for index in 0..<300 {
            try Data("\(index)".utf8).write(to: many.appendingPathComponent("file-\(index).txt"))
        }
        var names: [String] = []
        for try await item in h.session.list(h.remotePath.appending(name: Array("many".utf8))) {
            names.append(item.name)
        }
        #expect(names.count == 300)
        #expect(!names.contains("."))

        let payload = randomData(3 * 1024 * 1024 + 12345)
        let local = h.root.appendingPathComponent("up.bin")
        try payload.write(to: local)
        let uploaded = h.remotePath.appending(name: Array("up.bin".utf8))
        var last = TransferProgress(completed: 0)
        let box = ProgressBox()
        try await h.session.upload(local, to: uploaded) { box.last = $0 }
        last = box.last
        #expect(last.completed == UInt64(payload.count))
        #expect(try Data(contentsOf: h.remote.appendingPathComponent("up.bin")) == payload)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: h.remote.path).filter { $0.contains(".transfer-") }
        #expect(leftovers.isEmpty)

        let info = try await h.session.stat(uploaded)
        #expect(info.kind == .file)
        #expect(info.size == UInt64(payload.count))
        let localTime = try local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        #expect(info.mtime == UInt32(localTime.timeIntervalSince1970))

        // Same size and whole-second mtime: skipped without a collision prompt.
        try await h.session.upload(local, to: uploaded) { _ in }
        #expect(h.prompts.collisions == 0)

        let down = h.root.appendingPathComponent("down.bin")
        try await h.session.download(uploaded, to: down) { _ in }
        #expect(try Data(contentsOf: down) == payload)

        // A different file on the same name asks, and Replace wins.
        try randomData(100).write(to: down)
        try await h.session.download(uploaded, to: down) { _ in }
        #expect(h.prompts.collisions == 1)
        #expect(try Data(contentsOf: down) == payload)

        let command = await h.session.terminalCommand(directory: h.remotePath)
        #expect(command?.hasPrefix("/usr/bin/ssh -S ") == true)
        #expect(command?.contains("Compression=no") == true)

        let socket = h.root.appendingPathComponent("ssh").appendingPathComponent(h.session.connection.id.socketName)
        #expect(FileManager.default.fileExists(atPath: socket.path))
        await h.session.disconnect()
        #expect(!FileManager.default.fileExists(atPath: socket.path))
        #expect(await h.session.isConnected == false)
    }

    @Test func viewFileReusesTheCachedCopyUntilTheRemoteChanges() async throws {
        guard let h = try harness("vc") else { return }
        _ = try await h.session.connect(prompts: h.prompts)
        let local = h.remote.appendingPathComponent("note.txt")
        try Data("first".utf8).write(to: local)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: local.path)
        let remote = h.remotePath.appending(name: Array("note.txt".utf8))

        let first = try await h.session.prepareViewFile(remote)
        #expect(try String(contentsOf: first, encoding: .utf8) == "first")
        let identity = try first.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier

        let again = try await h.session.prepareViewFile(remote)
        let sameIdentity = try again.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        #expect(identity?.isEqual(sameIdentity) == true, "an unchanged file is not downloaded twice")

        // Same size, later mtime: a real change that the cache must not hide.
        try Data("later".utf8).write(to: local)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_060)], ofItemAtPath: local.path)
        let changed = try await h.session.prepareViewFile(remote)
        #expect(try String(contentsOf: changed, encoding: .utf8) == "later")
        await h.cleanUp()
    }

    @Test func directoryCopyRoundTripsWithSymlinks() async throws {
        guard let h = try harness("tree") else { return }
        defer { Task { await h.cleanUp() } }
        _ = try await h.session.connect(prompts: h.prompts)
        let tree = h.root.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: tree.appendingPathComponent("one.txt"))
        try randomData(2_500_000).write(to: tree.appendingPathComponent("a/big.bin"))
        try Data("deep".utf8).write(to: tree.appendingPathComponent("a/b/deep.txt"))
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("link").path, withDestinationPath: "one.txt")

        let up = h.remotePath.appending(name: Array("tree-up".utf8))
        let box = ProgressBox()
        try await h.session.copyDirectory(fromLocal: tree, to: up) { box.last = $0 }
        #expect(box.last.itemsCompleted == 4)
        let upURL = h.remote.appendingPathComponent("tree-up")
        #expect(try Data(contentsOf: upURL.appendingPathComponent("a/b/deep.txt")) == Data("deep".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: upURL.appendingPathComponent("link").path) == "one.txt")
        #expect(try Data(contentsOf: upURL.appendingPathComponent("a/big.bin")) == Data(contentsOf: tree.appendingPathComponent("a/big.bin")))

        let down = h.root.appendingPathComponent("tree-down", isDirectory: true)
        try await h.session.copyDirectory(from: up, to: down) { _ in }
        #expect(try Data(contentsOf: down.appendingPathComponent("one.txt")) == Data("one".utf8))
        #expect(try Data(contentsOf: down.appendingPathComponent("a/big.bin")) == Data(contentsOf: tree.appendingPathComponent("a/big.bin")))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: down.appendingPathComponent("link").path) == "one.txt")
        #expect(h.prompts.collisions == 0)

        // A second download skips every matching file and asks about nothing.
        try await h.session.copyDirectory(from: up, to: down) { _ in }
        #expect(h.prompts.collisions == 0)

        try await h.session.remove(up)
        #expect(!FileManager.default.fileExists(atPath: upURL.path))
        await h.session.disconnect()
    }

    @Test func liveFileUploadsSavesAndSeesConflicts() async throws {
        guard let h = try harness("live") else { return }
        defer { Task { await h.cleanUp() } }
        _ = try await h.session.connect(prompts: h.prompts)
        let remoteFile = h.remote.appendingPathComponent("note.txt")
        try Data("first".utf8).write(to: remoteFile)
        let path = h.remotePath.appending(name: Array("note.txt".utf8))

        let events = EventLog()
        let stream = h.session.events()
        let logger = Task { for await event in stream { events.record(event) } }

        let local = try await h.session.prepareLiveFile(path)
        #expect(try Data(contentsOf: local) == Data("first".utf8))
        #expect(local.path.contains("/Live/"))
        let attributes = try FileManager.default.attributesOfItem(atPath: local.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(await h.session.liveFiles().map(\.path) == [path])

        // A safe-save style replacement, as editors do.
        let staged = local.deletingLastPathComponent().appendingPathComponent("staged")
        try Data("second".utf8).write(to: staged)
        _ = try FileManager.default.replaceItemAt(local, withItemAt: staged)
        let uploaded = await waitUntil { (try? Data(contentsOf: remoteFile)) == Data("second".utf8) }
        #expect(uploaded)
        let clean = await waitUntil { await h.session.liveFiles().first?.dirty == false }
        #expect(clean)
        #expect(await h.session.unsyncedLiveCount == 0)

        // Someone else changes the server copy; the next local edit becomes a conflict.
        try Data("remote-edit".utf8).write(to: remoteFile)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: remoteFile.path)
        try Data("third".utf8).write(to: local)
        let conflicted = await waitUntil { await h.session.liveFiles().first?.conflict == true }
        #expect(conflicted)
        #expect(try Data(contentsOf: remoteFile) == Data("remote-edit".utf8))
        #expect(events.conflicts.contains(path))
        #expect(FileManager.default.fileExists(atPath: local.deletingLastPathComponent().appendingPathComponent("note.txt (server)").path))

        try await h.session.resolveLive(path, choice: .keepLocal)
        #expect(try Data(contentsOf: remoteFile) == Data("third".utf8))
        #expect(await h.session.liveFiles().first?.conflict == false)
        #expect(await h.session.liveFiles().first?.dirty == false)

        // Rename keeps the mapping and moves the working copy's name.
        let renamed = h.remotePath.appending(name: Array("renamed.txt".utf8))
        try await h.session.rename(path, to: renamed)
        let live = await h.session.liveFiles().first
        #expect(live?.path == renamed)
        #expect(FileManager.default.fileExists(atPath: local.deletingLastPathComponent().appendingPathComponent("renamed.txt").path))

        try await h.session.discardLiveFile(renamed, force: false)
        #expect(await h.session.liveFiles().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: local.deletingLastPathComponent().path))
        logger.cancel()
        await h.session.disconnect()
    }

    @Test func liveMappingSurvivesRelaunch() async throws {
        guard let h = try harness("relaunch") else { return }
        defer { Task { await h.cleanUp() } }
        _ = try await h.session.connect(prompts: h.prompts)
        let remoteFile = h.remote.appendingPathComponent("keep.txt")
        try Data("v1".utf8).write(to: remoteFile)
        let path = h.remotePath.appending(name: Array("keep.txt".utf8))
        let local = try await h.session.prepareLiveFile(path)
        await h.session.disconnect()

        // Edited while Transfer was closed.
        try Data("v2-offline".utf8).write(to: local)

        let store = try Store(root: h.root)
        let again = SSHConnection(connection: h.session.connection, store: store, editableExtensions: TransferConfig.builtIn.extensionSet)
        _ = try await again.connect(prompts: h.prompts)
        #expect(await again.liveFiles().map(\.path) == [path])
        let uploaded = await waitUntil { (try? Data(contentsOf: remoteFile)) == Data("v2-offline".utf8) }
        #expect(uploaded)
        await again.disconnect()
    }

    @Test func rejectedHostKeyNeverLogsIn() async throws {
        guard let h = try harness("hostkey") else { return }
        defer { Task { await h.cleanUp() } }
        h.prompts.hostDecision = .cancel
        await #expect(throws: TransferError.hostKeyRejected) {
            _ = try await h.session.connect(prompts: h.prompts)
        }
        #expect(await h.session.isConnected == false)
    }
}

private final class ProgressBox: @unchecked Sendable {
    var last = TransferProgress(completed: 0)
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SessionEvent] = []

    func record(_ event: SessionEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var conflicts: [RemotePath] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap { if case .conflict(let path, _) = $0 { path } else { nil } }
    }
}
