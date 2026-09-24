import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// The transfer engine against the local sshd where copies meet what is already there: nothing
/// outside the chosen folder is written, and nothing already there is removed or replaced
/// without the operation's prompt. Serialized: each test logs in, and more logins at once than
/// the local sshd's MaxStartups (10) drops some.
@Suite(.serialized, .enabled(if: ServerHarness.available, "needs the local sshd from Scripts/local-sshd.sh"))
struct TransferServerTests {
    /// A remote link over a local folder of the same name deleted the whole folder (SEC-4, SES-01).
    @Test func aLinkNeverReplacesALocalFolder() async throws {
        try await withHarness("linkdir", connected: true) { h in
            let elsewhere = h.remote.appendingPathComponent("elsewhere")
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: h.remote.appendingPathComponent("Projects").path, withDestinationPath: "elsewhere")
            let downloads = h.staging.appendingPathComponent("Downloads")
            let main = downloads.appendingPathComponent("Projects/app/src/main.swift")
            try FileManager.default.createDirectory(at: main.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("main".utf8).write(to: main)

            let projects = h.remotePath.appending(name: Array("Projects".utf8))
            await #expect(throws: TransferError.typeMismatch("Projects")) {
                try await h.session.download(projects, to: downloads.appendingPathComponent("Projects")) { _ in }
            }
            #expect(try Data(contentsOf: main) == Data("main".utf8))

            // Inside a folder download, too.
            let docs = h.remote.appendingPathComponent("dl")
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: docs.appendingPathComponent("Projects").path, withDestinationPath: "../elsewhere")
            await #expect(throws: TransferError.self) {
                try await h.session.download(h.remotePath.appending(name: Array("dl".utf8)), to: downloads) { _ in }
            }
            #expect(try Data(contentsOf: main) == Data("main".utf8))
            #expect(h.prompts.collisions == 0)
        }
    }

    /// A remote link over a local file is a collision like any other: asked, and replaced only on Replace.
    @Test func aLinkOverAFileIsAsked() async throws {
        try await withHarness("linkfile", connected: true) { h in
            try FileManager.default.createSymbolicLink(atPath: h.remote.appendingPathComponent("latest").path, withDestinationPath: "v2")
            let latest = h.remotePath.appending(name: Array("latest".utf8))
            let local = h.staging.appendingPathComponent("latest")
            try Data("mine".utf8).write(to: local)

            await OperationPrompts.$current.withValue(nil) {
                await #expect(throws: TransferError.self) { try await h.session.download(latest, to: local) { _ in } }
            }
            #expect(try Data(contentsOf: local) == Data("mine".utf8))

            try await h.session.download(latest, to: local) { _ in }
            #expect(h.prompts.collisions == 1)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: local.path) == "v2")

            // The same link again is already there: nothing asked.
            try await h.session.download(latest, to: local) { _ in }
            #expect(h.prompts.collisions == 1)
        }
    }

    /// A stock server: `site/cur` was a link out of the download folder on the first download,
    /// then became a real folder. The second download wrote through the stale local link (SEC-3).
    @Test func aStaleLocalLinkIsNeverWrittenThrough() async throws {
        try await withHarness("stale", connected: true) { h in
            let victim = h.staging.appendingPathComponent("victim")
            try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
            let site = h.remote.appendingPathComponent("site")
            try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
            try Data("index".utf8).write(to: site.appendingPathComponent("index.html"))
            try FileManager.default.createSymbolicLink(atPath: site.appendingPathComponent("cur").path, withDestinationPath: victim.path)
            let remoteSite = h.remotePath.appending(name: Array("site".utf8))
            let local = h.staging.appendingPathComponent("Downloads/site")

            try await h.session.download(remoteSite, to: local) { _ in }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: local.appendingPathComponent("cur").path) == victim.path)

            try FileManager.default.removeItem(at: site.appendingPathComponent("cur"))
            try FileManager.default.createDirectory(at: site.appendingPathComponent("cur"), withIntermediateDirectories: true)
            try Data("through".utf8).write(to: site.appendingPathComponent("cur/through.txt"))

            await OperationPrompts.$current.withValue(nil) {
                await #expect(throws: TransferError.self) { try await h.session.download(remoteSite, to: local) { _ in } }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: victim.path).isEmpty)

            // Replace swaps the link for a real folder; the link's target is untouched.
            try await h.session.download(remoteSite, to: local) { _ in }
            #expect(h.prompts.collisions == 1)
            #expect(try FileManager.default.contentsOfDirectory(atPath: victim.path).isEmpty)
            #expect(try Data(contentsOf: local.appendingPathComponent("cur/through.txt")) == Data("through".utf8))
            #expect(try LocalPlacement.occupant(local.appendingPathComponent("cur")) == .folder)
        }
    }

    /// The download's own destination may already be a link, left by the user or an earlier copy.
    @Test func aLinkAtTheDestinationIsNeverFollowed() async throws {
        try await withHarness("destlink", connected: true) { h in
            let victim = h.staging.appendingPathComponent("victim")
            try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
            let site = h.remote.appendingPathComponent("site")
            try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
            try Data("index".utf8).write(to: site.appendingPathComponent("index.html"))
            let local = h.staging.appendingPathComponent("site")
            try FileManager.default.createSymbolicLink(atPath: local.path, withDestinationPath: victim.path)

            await OperationPrompts.$current.withValue(nil) {
                await #expect(throws: TransferError.self) {
                    try await h.session.download(h.remotePath.appending(name: Array("site".utf8)), to: local) { _ in }
                }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: victim.path).isEmpty)
        }
    }

    /// A link already at an upload's or a copy's destination was left alone whatever it was, so
    /// a file or another link of that name passed for the copy (SES-39, CLIP-16).
    @Test func linksCollideLikeFiles() async throws {
        try await withHarness("links", connected: true) { h in
            let tree = h.staging.appendingPathComponent("tree")
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("current").path, withDestinationPath: "v2")
            let up = h.remotePath.appending(name: Array("up".utf8))
            let upURL = h.remote.appendingPathComponent("up")
            try FileManager.default.createDirectory(at: upURL, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: upURL.appendingPathComponent("current").path, withDestinationPath: "v1")

            await OperationPrompts.$current.withValue(nil) {
                await #expect(throws: TransferError.self) { try await h.session.upload(tree, to: up) { _ in } }
            }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: upURL.appendingPathComponent("current").path) == "v1")

            try await h.session.upload(tree, to: up) { _ in }
            #expect(h.prompts.collisions == 1)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: upURL.appendingPathComponent("current").path) == "v2")
            try await h.session.upload(tree, to: up) { _ in }
            #expect(h.prompts.collisions == 1, "the same link is already there")

            // A link onto a file on the server, by a copy there.
            let copy = h.remotePath.appending(name: Array("copy".utf8))
            let copyURL = h.remote.appendingPathComponent("copy")
            try FileManager.default.createDirectory(at: copyURL, withIntermediateDirectories: true)
            try Data("file".utf8).write(to: copyURL.appendingPathComponent("current"))
            try await h.session.copy(up, to: copy) { _ in }
            #expect(h.prompts.collisions == 2)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copyURL.appendingPathComponent("current").path) == "v2")
            let leftovers = try FileManager.default.subpathsOfDirectory(atPath: h.remote.path).filter { $0.contains(".transfer-") }
            #expect(leftovers.isEmpty)
        }
    }

    /// A FIFO in an uploaded folder blocked the upload forever, and a socket failed the whole copy (SES-08).
    @Test(.timeLimit(.minutes(1))) func specialFilesAreSkippedOnUpload() async throws {
        try await withHarness("special", connected: true) { h in
            let tree = h.staging.appendingPathComponent("t")
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: tree.appendingPathComponent("kept.txt"))
            #expect(mkfifo(tree.appendingPathComponent("fifo").path, 0o600) == 0)
            let socket = try bindSocket(at: tree.appendingPathComponent("s"))
            defer { close(socket) }

            let up = h.remotePath.appending(name: Array("t".utf8))
            try await h.session.upload(tree, to: up) { _ in }
            let names = try FileManager.default.contentsOfDirectory(atPath: h.remote.appendingPathComponent("t").path)
            #expect(names == ["kept.txt"])
        }
    }

    /// One unreadable file stopped a folder copy at once, cancelling the rest (SES-18).
    @Test func aFolderCopyFinishesPastAFailedFile() async throws {
        try await withHarness("partial", connected: true) { h in
            let site = h.remote.appendingPathComponent("site")
            try FileManager.default.createDirectory(at: site.appendingPathComponent("sub"), withIntermediateDirectories: true)
            for name in ["a.txt", "b.txt", "sub/c.txt"] { try Data(name.utf8).write(to: site.appendingPathComponent(name)) }
            let locked = site.appendingPathComponent("locked.txt")
            try Data("secret".utf8).write(to: locked)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path) }

            let local = h.staging.appendingPathComponent("site")
            await #expect(throws: TransferError.self) {
                try await h.session.download(h.remotePath.appending(name: Array("site".utf8)), to: local) { _ in }
            }
            for name in ["a.txt", "b.txt", "sub/c.txt"] {
                #expect(try Data(contentsOf: local.appendingPathComponent(name)) == Data(name.utf8))
            }
            #expect(!FileManager.default.fileExists(atPath: local.appendingPathComponent("locked.txt").path))
            let leftovers = try FileManager.default.subpathsOfDirectory(atPath: local.path).filter { $0.contains(".transfer-") }
            #expect(leftovers.isEmpty)

            // The same for an upload, with two failures named in one error.
            let tree = h.staging.appendingPathComponent("tree")
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            try Data("ok".utf8).write(to: tree.appendingPathComponent("ok.txt"))
            for name in ["x.txt", "y.txt"] {
                let file = tree.appendingPathComponent(name)
                try Data(name.utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
            }
            do {
                try await h.session.upload(tree, to: h.remotePath.appending(name: Array("tree".utf8))) { _ in }
                Issue.record("the upload should report its failures")
            } catch {
                let text = error.localizedDescription
                #expect(text.contains("2 items") && text.contains("x.txt") && text.contains("y.txt"))
            }
            #expect(try Data(contentsOf: h.remote.appendingPathComponent("tree/ok.txt")) == Data("ok".utf8))
        }
    }

    /// A large file inside a folder showed no progress until it was done (SES-24).
    @Test func folderProgressMovesInsideAFile() async throws {
        try await withHarness("progress", connected: true) { h in
            let site = h.remote.appendingPathComponent("big")
            try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
            try Data(count: 3_000_000).write(to: site.appendingPathComponent("big.bin"))
            let reports = Locked<[TransferProgress]>([])
            try await h.session.download(h.remotePath.appending(name: Array("big".utf8)), to: h.staging.appendingPathComponent("big")) { progress in
                reports.withLock { $0.append(progress) }
            }
            #expect(reports.value.contains { $0.itemsCompleted == 0 && $0.completed > 0 })
            #expect(reports.value.last == TransferProgress(completed: 3_000_000, itemsCompleted: 1))
        }
    }

    /// A cancelled or cut-off upload forgot its hidden temp even when removing it failed, so the
    /// partial file stayed on the server for good (SES-07).
    @Test func anInterruptedUploadLeavesNoTempBehind() async throws {
        try await withHarness("temps", connected: true) { h in
            let big = h.staging.appendingPathComponent("big.bin")
            FileManager.default.createFile(atPath: big.path, contents: nil)
            try FileHandle(forWritingTo: big).truncate(atOffset: 2 << 30)
            let destination = h.remotePath.appending(name: Array("big.bin".utf8))
            let records = try Store(root: h.root)
            func temps() throws -> [String] {
                try FileManager.default.contentsOfDirectory(atPath: h.remote.path).filter { $0.contains(".transfer-") }
            }

            // Cancelled: the temp is removed even though the task that wrote it was cancelled.
            let started = Locked(false)
            let upload = Task {
                try await OperationPrompts.$current.withValue(h.prompts) {
                    try await h.session.upload(big, to: destination) { if $0.completed > 0 { started.value = true } }
                }
            }
            #expect(await waitUntil { started.value })
            upload.cancel()
            _ = await upload.result
            #expect(try temps().isEmpty)
            #expect(records.remoteTemps(connection: h.session.connection.id).isEmpty)

            // Cut off: the temp cannot be removed, so it stays recorded, and the next login removes it.
            started.value = false
            let cut = Task {
                try await OperationPrompts.$current.withValue(h.prompts) {
                    try await h.session.upload(big, to: destination) { if $0.completed > 0 { started.value = true } }
                }
            }
            #expect(await waitUntil { started.value })
            await h.session.disconnect()
            _ = await cut.result
            let left = try temps()
            #expect(left.count == 1)
            #expect(records.remoteTemps(connection: h.session.connection.id).count == 1)
            _ = try await h.session.connect(prompts: h.prompts)
            #expect(try temps().isEmpty)
            #expect(records.remoteTemps(connection: h.session.connection.id).isEmpty)
        }
    }
}

/// A listening unix socket at `url`, as a dev tool leaves in a project folder.
private func bindSocket(at url: URL) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(url.path.utf8)
    guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { throw TransferError.failed("socket path too long") }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        for (index, byte) in path.enumerated() { buffer[index] = byte }
    }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0 else { throw TransferError.failed("bind: \(String(cString: strerror(errno)))") }
    return fd
}
