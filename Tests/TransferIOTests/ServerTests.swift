import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// The real SSH master, SFTP channels, copies, and Live sync against the local sshd
/// (`ServerHarness`).
@Suite(.enabled(if: ServerHarness.available, "needs the local sshd from Scripts/local-sshd.sh"))
struct ServerTests {
    private func randomData(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            for index in 0..<count { buffer[index] = UInt8.random(in: 0...255) }
        }
        return data
    }

    @Test func loginListsAndMovesBytes() async throws {
        try await withHarness("bytes") { h in
            let start = try await h.session.connect(prompts: h.prompts)
            #expect(start.display == h.remote.resolvingSymlinksInPath().path)
            #expect(await h.session.isConnected)

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
            let box = Locked(TransferProgress(completed: 0))
            try await h.session.upload(local, to: uploaded) { box.value = $0 }
            last = box.value
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

            // With nobody to ask, a collision fails the operation and leaves the file alone; the
            // login's prompts are never asked.
            let other = randomData(100)
            try other.write(to: down)
            await OperationPrompts.$current.withValue(nil) {
                await #expect(throws: TransferError.self) { try await h.session.download(uploaded, to: down) { _ in } }
                await #expect(throws: TransferError.self) { try await h.session.upload(down, to: uploaded) { _ in } }
            }
            #expect(h.prompts.collisions == 1)
            #expect(try Data(contentsOf: down) == other)
            #expect(try Data(contentsOf: h.remote.appendingPathComponent("up.bin")) == payload)

            let command = await h.session.terminalCommand(directory: h.remotePath)
            #expect(command?.hasPrefix("/usr/bin/ssh -S ") == true)
            #expect(command?.contains("Compression=no") == true)

            let socket = h.root.appendingPathComponent("ssh").appendingPathComponent(h.session.connection.id.socketName)
            #expect(FileManager.default.fileExists(atPath: socket.path))
            await h.session.disconnect()
            #expect(!FileManager.default.fileExists(atPath: socket.path))
            #expect(await h.session.isConnected == false)
        }
    }

    @Test func viewFileReusesTheCachedCopyUntilTheRemoteChanges() async throws {
        try await withHarness("vc") { h in
            _ = try await h.session.connect(prompts: h.prompts)
            let local = h.remote.appendingPathComponent("note.txt")
            try Data("first".utf8).write(to: local)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: local.path)
            let remote = h.remotePath.appending(name: Array("note.txt".utf8))

            let first = try await h.session.prepareViewFile(remote)
            #expect(try String(contentsOf: first, encoding: .utf8) == "first")
            #expect(first.path.hasPrefix(h.root.appendingPathComponent("Caches/Preview").path + "/"), "the cache is the test library's own")
            let identity = try first.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier

            let again = try await h.session.prepareViewFile(remote)
            let sameIdentity = try again.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
            #expect(identity?.isEqual(sameIdentity) == true, "an unchanged file is not downloaded twice")

            // Same size, later mtime: a real change that the cache must not hide.
            try Data("later".utf8).write(to: local)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_060)], ofItemAtPath: local.path)
            let changed = try await h.session.prepareViewFile(remote)
            #expect(try String(contentsOf: changed, encoding: .utf8) == "later")
        }
    }

    /// The inspector downloaded a whole text file, up to 8 MB, to show its first 64 KB (UIM-20).
    /// It now fetches only that head, reused while the file's size and time are unchanged.
    @Test func aTextPreviewFetchesOnlyTheHead() async throws {
        try await withHarness("head", connected: true) { h in
            let head = EditableFile.previewHead
            let big = h.remote.appendingPathComponent("big.txt")
            func put(_ fill: String, at time: TimeInterval) throws {
                try Data(String(repeating: fill, count: 3 << 20).utf8).write(to: big)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: big.path)
            }
            try put("a", at: 1_700_000_000)
            let remote = h.remotePath.appending(name: Array("big.txt".utf8))
            func identity(_ url: URL) throws -> NSObject? {
                try url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
            }

            let first = try await h.session.prepareInspectorPreview(remote)
            #expect(try Data(contentsOf: first) == Data(String(repeating: "a", count: head).utf8))
            let again = try await h.session.prepareInspectorPreview(remote)
            #expect(again == first)
            #expect(try identity(again) == identity(first), "an unchanged file's head is not fetched twice")

            try put("b", at: 1_700_000_060)
            let changed = try await h.session.prepareInspectorPreview(remote)
            #expect(try Data(contentsOf: changed) == Data(String(repeating: "b", count: head).utf8))

            // Viewing still fetches the whole file, and a file that is not text is previewed whole.
            let whole = try await h.session.prepareViewFile(remote)
            #expect(try Data(contentsOf: whole).count == 3 << 20)
            try Data(count: 100_000).write(to: h.remote.appendingPathComponent("blob.bin"))
            let blob = try await h.session.prepareInspectorPreview(h.remotePath.appending(name: Array("blob.bin".utf8)))
            #expect(try Data(contentsOf: blob).count == 100_000)
        }
    }

    /// Links were followed one hop, so a chain such as /usr/bin/java → /etc/alternatives/java →
    /// the JDK's binary would not open (UIM-19). The server's REALPATH follows the whole chain;
    /// a loop or a dangling link fails with an error rather than hanging.
    @Test func linkChainsResolveToTheirEnd() async throws {
        try await withHarness("chain", connected: true) { h in
            let fm = FileManager.default
            try fm.createDirectory(at: h.remote.appendingPathComponent("jdk/bin"), withIntermediateDirectories: true)
            try Data("java".utf8).write(to: h.remote.appendingPathComponent("jdk/bin/java"))
            try fm.createDirectory(at: h.remote.appendingPathComponent("alternatives"), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: h.remote.appendingPathComponent("alternatives/java").path, withDestinationPath: "../jdk/bin/java")
            try fm.createSymbolicLink(atPath: h.remote.appendingPathComponent("java").path, withDestinationPath: "alternatives/java")
            try fm.createSymbolicLink(atPath: h.remote.appendingPathComponent("home").path, withDestinationPath: "alternatives/../jdk")
            try fm.createSymbolicLink(atPath: h.remote.appendingPathComponent("here").path, withDestinationPath: "home")
            try fm.createSymbolicLink(atPath: h.remote.appendingPathComponent("loop-a").path, withDestinationPath: "loop-b")
            try fm.createSymbolicLink(atPath: h.remote.appendingPathComponent("loop-b").path, withDestinationPath: "loop-a")
            try fm.createSymbolicLink(atPath: h.remote.appendingPathComponent("gone").path, withDestinationPath: "nowhere")
            func path(_ name: String) -> RemotePath { h.remotePath.appending(name: Array(name.utf8)) }

            let java = try await h.session.resolve(path("java"))
            #expect(java.kind == .file)
            #expect(java.size == 4)
            #expect(java.path == RemotePath(string: h.remote.appendingPathComponent("jdk/bin/java").path))
            let folder = try await h.session.resolve(path("here"))
            #expect(folder.kind == .directory)
            #expect(folder.path == path("jdk"))
            #expect(try await h.session.resolve(path("jdk")).path == path("jdk"))
            for name in ["loop-a", "gone"] {
                let error = await #expect(throws: TransferError.self) { try await h.session.resolve(path(name)) }
                #expect(error?.localizedDescription.contains(path(name).display) == true)
            }
            #expect(try await h.session.resolve(path("java")).kind == .file, "the channel still works")
        }
    }

    @Test func directoryCopyRoundTripsWithSymlinks() async throws {
        try await withHarness("tree") { h in
            _ = try await h.session.connect(prompts: h.prompts)
            let tree = h.root.appendingPathComponent("tree", isDirectory: true)
            try FileManager.default.createDirectory(at: tree.appendingPathComponent("a/b"), withIntermediateDirectories: true)
            try Data("one".utf8).write(to: tree.appendingPathComponent("one.txt"))
            try randomData(2_500_000).write(to: tree.appendingPathComponent("a/big.bin"))
            try Data("deep".utf8).write(to: tree.appendingPathComponent("a/b/deep.txt"))
            try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("link").path, withDestinationPath: "one.txt")

            let up = h.remotePath.appending(name: Array("tree-up".utf8))
            let box = Locked(TransferProgress(completed: 0))
            try await h.session.upload(tree, to: up) { box.value = $0 }
            #expect(box.value.itemsCompleted == 4)
            // Uploading the same tree again merges into it; the link already there is kept.
            try await h.session.upload(tree, to: up) { _ in }
            #expect(h.prompts.collisions == 0)
            let upURL = h.remote.appendingPathComponent("tree-up")
            #expect(try Data(contentsOf: upURL.appendingPathComponent("a/b/deep.txt")) == Data("deep".utf8))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: upURL.appendingPathComponent("link").path) == "one.txt")
            #expect(try Data(contentsOf: upURL.appendingPathComponent("a/big.bin")) == Data(contentsOf: tree.appendingPathComponent("a/big.bin")))

            let down = h.root.appendingPathComponent("tree-down", isDirectory: true)
            try await h.session.download(up, to: down) { _ in }
            #expect(try Data(contentsOf: down.appendingPathComponent("one.txt")) == Data("one".utf8))
            #expect(try Data(contentsOf: down.appendingPathComponent("a/big.bin")) == Data(contentsOf: tree.appendingPathComponent("a/big.bin")))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: down.appendingPathComponent("link").path) == "one.txt")
            #expect(h.prompts.collisions == 0)

            // A second download skips every matching file and asks about nothing.
            try await h.session.download(up, to: down) { _ in }
            #expect(h.prompts.collisions == 0)

            try await h.session.remove(up)
            #expect(!FileManager.default.fileExists(atPath: upURL.path))
            await h.session.disconnect()
        }
    }

    @Test func serverCopyMergesTreesAndWalksThem() async throws {
        try await withHarness("paste") { h in
            _ = try await h.session.connect(prompts: h.prompts)
            let tree = h.remote.appendingPathComponent("site", isDirectory: true)
            try FileManager.default.createDirectory(at: tree.appendingPathComponent("a/b"), withIntermediateDirectories: true)
            try Data("one".utf8).write(to: tree.appendingPathComponent("one.txt"))
            let big = randomData(2_500_000)
            try big.write(to: tree.appendingPathComponent("a/big.bin"))
            try Data("deep".utf8).write(to: tree.appendingPathComponent("a/b/deep.txt"))
            try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("link").path, withDestinationPath: "one.txt")
            let site = h.remotePath.appending(name: Array("site".utf8))

            let entries = try await sizes(h.session.tree(site))
            #expect(entries == ["": .directory, "one.txt": .file(size: 3), "a": .directory, "a/big.bin": .file(size: UInt64(big.count)),
                                    "a/b": .directory, "a/b/deep.txt": .file(size: 4), "link": .link])

            // The Mac's own sftp-server offers copy-data, so this copy never leaves the server.
            let copy = h.remotePath.appending(name: Array("site copy".utf8))
            let box = Locked(TransferProgress(completed: 0))
            try await h.session.copy(site, to: copy) { box.value = $0 }
            #expect(box.value.itemsCompleted == 4)
            let copyURL = h.remote.appendingPathComponent("site copy")
            #expect(try Data(contentsOf: copyURL.appendingPathComponent("a/big.bin")) == big)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copyURL.appendingPathComponent("link").path) == "one.txt")
            let copied = try await h.session.tree(copy)
            #expect(try await MoveCheck.verdict(source: h.session.tree(site), before: [:], after: copied) == .remove)
            let sourceTime = try FileManager.default.attributesOfItem(atPath: tree.appendingPathComponent("a/big.bin").path)[.modificationDate] as? Date
            let copyTime = try FileManager.default.attributesOfItem(atPath: copyURL.appendingPathComponent("a/big.bin").path)[.modificationDate] as? Date
            #expect(sourceTime.map { Int($0.timeIntervalSince1970) } == copyTime.map { Int($0.timeIntervalSince1970) })
            let leftovers = try FileManager.default.subpathsOfDirectory(atPath: copyURL.path).filter { $0.contains(".transfer-") }
            #expect(leftovers.isEmpty)

            // Pasting again merges: every file matches in size and time, so nothing is asked.
            try await h.session.copy(site, to: copy) { _ in }
            #expect(h.prompts.collisions == 0)
            // A changed file collides and the prompt's Replace wins.
            try Data("changed".utf8).write(to: copyURL.appendingPathComponent("one.txt"))
            try await h.session.copy(site, to: copy) { _ in }
            #expect(h.prompts.collisions == 1)
            #expect(try Data(contentsOf: copyURL.appendingPathComponent("one.txt")) == Data("one".utf8))

            // A single file, and a folder into itself.
            let file = site.appending(name: Array("one.txt".utf8))
            try await h.session.copy(file, to: h.remotePath.appending(name: Array("one copy.txt".utf8))) { _ in }
            #expect(try Data(contentsOf: h.remote.appendingPathComponent("one copy.txt")) == Data("one".utf8))
            await #expect(throws: TransferError.self) {
                try await h.session.copy(site, to: site.appending(name: Array("a".utf8)).appending(name: Array("site".utf8))) { _ in }
            }
            await h.session.disconnect()
        }
    }

    @Test func liveFileUploadsSavesAndSeesConflicts() async throws {
        try await withHarness("live") { h in
            _ = try await h.session.connect(prompts: h.prompts)
            let remoteFile = h.remote.appendingPathComponent("note.txt")
            try Data("first".utf8).write(to: remoteFile)
            let path = h.remotePath.appending(name: Array("note.txt".utf8))

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
            // The event reaches the log through its own task, a moment after the flag is set.
            let conflicted = await waitUntil { await h.session.liveFiles().first?.conflict == true && h.events.conflicts(path) > 0 }
            #expect(conflicted)
            #expect(try Data(contentsOf: remoteFile) == Data("remote-edit".utf8))
            #expect(h.events.conflicts(path) > 0)
            #expect(FileManager.default.fileExists(atPath: local.deletingLastPathComponent().appendingPathComponent("note.txt (server)").path))

            try await h.session.resolveLive(path, choice: .keepLocal)
            #expect(try Data(contentsOf: remoteFile) == Data("third".utf8))
            #expect(await h.session.liveFiles().first?.conflict == false)
            #expect(await h.session.liveFiles().first?.dirty == false)

            // Rename keeps the mapping and the working copy's name, which an editor may hold open;
            // its next save goes to the new remote name.
            let renamed = h.remotePath.appending(name: Array("renamed.txt".utf8))
            try await h.session.rename(path, to: renamed)
            let live = await h.session.liveFiles().first
            #expect(live?.path == renamed)
            #expect(FileManager.default.fileExists(atPath: local.path))
            #expect(!FileManager.default.fileExists(atPath: local.deletingLastPathComponent().appendingPathComponent("renamed.txt").path))
            try Data("fourth".utf8).write(to: local)
            let renamedFile = h.remote.appendingPathComponent("renamed.txt")
            let followed = await waitUntil { (try? Data(contentsOf: renamedFile)) == Data("fourth".utf8) }
            #expect(followed)
            #expect(!FileManager.default.fileExists(atPath: remoteFile.path))
            let settled = await waitUntil { await h.session.liveFiles().first?.dirty == false }
            #expect(settled)

            try await h.session.discardLiveFile(renamed, force: false)
            #expect(await h.session.liveFiles().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: local.deletingLastPathComponent().path))
            await h.session.disconnect()
        }
    }

    /// A Live save once gave the server file the working copy's private 0600, so a script lost
    /// its execute bit and a web page stopped being readable.
    @Test func liveSaveKeepsTheServerFilesMode() async throws {
        try await withHarness("mode") { h in
            _ = try await h.session.connect(prompts: h.prompts)
            let remoteFile = h.remote.appendingPathComponent("deploy.sh")
            try Data("echo one\n".utf8).write(to: remoteFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: remoteFile.path)
            let path = h.remotePath.appending(name: Array("deploy.sh".utf8))

            let local = try await h.session.prepareLiveFile(path)
            try Data("echo two\n".utf8).write(to: local)
            let uploaded = await waitUntil { (try? Data(contentsOf: remoteFile)) == Data("echo two\n".utf8) }
            #expect(uploaded)
            let mode = try FileManager.default.attributesOfItem(atPath: remoteFile.path)[.posixPermissions] as? Int
            #expect(mode == 0o755)

            try await h.session.discardLiveFile(path, force: true)
            await h.session.disconnect()
        }
    }

    /// Rename and a move between folders once replaced whatever already had the name.
    @Test func renameNeverReplacesAnExistingItem() async throws {
        try await withHarness("rename") { h in
            _ = try await h.session.connect(prompts: h.prompts)
            try Data("A".utf8).write(to: h.remote.appendingPathComponent("a.txt"))
            try Data("B".utf8).write(to: h.remote.appendingPathComponent("b.txt"))
            try FileManager.default.createDirectory(at: h.remote.appendingPathComponent("full/inside"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: h.remote.appendingPathComponent("empty"), withIntermediateDirectories: true)
            func remote(_ name: String) -> RemotePath { h.remotePath.appending(name: Array(name.utf8)) }

            await #expect(throws: (any Error).self) { try await h.session.rename(remote("a.txt"), to: remote("b.txt")) }
            #expect(try Data(contentsOf: h.remote.appendingPathComponent("a.txt")) == Data("A".utf8))
            #expect(try Data(contentsOf: h.remote.appendingPathComponent("b.txt")) == Data("B".utf8))

            // OpenSSH's plain rename would replace an empty folder.
            await #expect(throws: (any Error).self) { try await h.session.rename(remote("full"), to: remote("empty")) }
            #expect(FileManager.default.fileExists(atPath: h.remote.appendingPathComponent("full/inside").path))

            // A change of case alone still renames, on this case-insensitive disk too.
            try await h.session.rename(remote("a.txt"), to: remote("A.txt"))
            let names = try FileManager.default.contentsOfDirectory(atPath: h.remote.path)
            #expect(names.contains("A.txt") && !names.contains("a.txt"))

            try await h.session.rename(remote("b.txt"), to: remote("c.txt"))
            #expect(try Data(contentsOf: h.remote.appendingPathComponent("c.txt")) == Data("B".utf8))
            await h.session.disconnect()
        }
    }

    @Test func liveMappingSurvivesRelaunch() async throws {
        try await withHarness("relaunch") { h in
            _ = try await h.session.connect(prompts: h.prompts)
            let remoteFile = h.remote.appendingPathComponent("keep.txt")
            try Data("v1".utf8).write(to: remoteFile)
            let path = h.remotePath.appending(name: Array("keep.txt".utf8))
            let local = try await h.session.prepareLiveFile(path)
            await h.session.disconnect()

            // Edited while Transfer was closed.
            try Data("v2-offline".utf8).write(to: local)

            try await h.withSecondSession { again in
                _ = try await again.connect(prompts: h.prompts)
                #expect(await again.liveFiles().map(\.path) == [path])
                let uploaded = await waitUntil { (try? Data(contentsOf: remoteFile)) == Data("v2-offline".utf8) }
                #expect(uploaded)
            }
        }
    }

    @Test func rejectedHostKeyNeverLogsIn() async throws {
        try await withHarness("hostkey") { h in
            h.prompts.hostDecision = .cancel
            await #expect(throws: TransferError.hostKeyRejected) {
                _ = try await h.session.connect(prompts: h.prompts)
            }
            #expect(await h.session.isConnected == false)
        }
    }
}

/// A walked tree with files kept by size alone; the times are the server's.
private func sizes(_ tree: [String: TreeEntry]) -> [String: TreeEntry] {
    tree.mapValues { entry in
        if case .file(let size, _) = entry { .file(size: size) } else { entry }
    }
}
