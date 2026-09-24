import CryptoKit
import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// Live sync against the ways real editors save, with the real FSEvents watcher. Runs only
/// against a local sshd (`Scripts/local-sshd.sh`), like `ServerTests`. Each scenario prints one
/// `MATRIX` line: uploads counted two ways, from `.succeeded` shelf events and from renames onto
/// the server file (inode changes), plus every distinct server content seen along the way.
@Suite(.serialized)
struct EditorMatrix {
    private static var port: String? { ProcessInfo.processInfo.environment["TRANSFER_TEST_PORT"] }
    private static var identity: String? { ProcessInfo.processInfo.environment["TRANSFER_TEST_IDENTITY"] }

    private struct Harness {
        let session: SSHConnection
        let root: URL
        let remote: URL
        let staging: URL
        let prompts: TestPrompts
        let events: MatrixEvents
        let logger: Task<Void, Never>

        var remotePath: RemotePath { RemotePath(string: remote.path) }

        func cleanUp() async {
            logger.cancel()
            await session.disconnect()
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
    }

    private final class TestPrompts: PromptSink, @unchecked Sendable {
        func answer(_ request: PromptRequest) async -> PromptReply { PromptReply(text: nil) }
        func decideHostKey(_ event: HostKeyEvent) async -> HostKeyDecision { .trustOnce }
        func resolveCollision(fileName: String) async -> NameCollisionChoice? { .replace }
    }

    private func harness(_ name: String) throws -> Harness? {
        guard let port = Self.port, let identity = Self.identity else { return nil }
        let base = TestCaches.fresh(name)
        let root = base.appendingPathComponent("library", isDirectory: true)
        let remote = base.appendingPathComponent("remote", isDirectory: true)
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        let store: Store
        do {
            for folder in [root, remote, staging] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            store = try Store(root: root)
        } catch {
            try? FileManager.default.removeItem(at: base)
            throw error
        }
        let saved = SavedConnection(name: name, host: "127.0.0.1", user: NSUserName(), port: port, identityFile: identity, remotePath: remote.path)
        let session = SSHConnection(connection: saved, store: store, editableExtensions: TransferConfig.builtIn.extensionSet)
        let events = MatrixEvents()
        let stream = session.events()
        let logger = Task { for await event in stream { events.record(event) } }
        return Harness(session: session, root: root, remote: remote, staging: staging, prompts: TestPrompts(), events: events, logger: logger)
    }

    /// Runs `body` with a connected harness and always awaits its cleanup, when it throws too. Does
    /// nothing without a server.
    private func withHarness(_ name: String, _ body: (Harness) async throws -> Void) async throws {
        guard let h = try harness(name) else { return }
        do {
            _ = try await h.session.connect(prompts: h.prompts)
            try await body(h)
        } catch {
            await h.cleanUp()
            throw error
        }
        await h.cleanUp()
    }

    private struct LiveCase {
        let local: URL
        let remoteFile: URL
        let path: RemotePath
        let watch: ServerWatch
    }

    private func open(_ h: Harness, _ name: String, _ contents: Data) async throws -> LiveCase {
        let remoteFile = h.remote.appendingPathComponent(name)
        try contents.write(to: remoteFile)
        // An older server time, as a real file has; the working copy gets it too.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: remoteFile.path)
        let path = h.remotePath.appending(name: Array(name.utf8))
        let local = try await h.session.prepareLiveFile(path)
        #expect(try Data(contentsOf: local) == contents)
        return LiveCase(local: local, remoteFile: remoteFile, path: path, watch: ServerWatch(remoteFile))
    }

    private func waitUntil(_ seconds: Double = 8, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await condition()
    }

    /// Waits for the server to hold `expected` and the file to be clean, then a further 1.5 s so a
    /// late second upload is counted too. Returns the upload count from shelf events.
    @discardableResult
    private func expectSynced(_ label: String, _ h: Harness, _ c: LiveCase, _ expected: Data, allowed: Set<String> = [],
                              maxUploads: Int? = 1, sourceLocation: SourceLocation = #_sourceLocation) async -> Int {
        let landed = await waitUntil {
            guard (try? Data(contentsOf: c.remoteFile)) == expected else { return false }
            guard let file = await h.session.liveFiles().first(where: { $0.path == c.path }) else { return false }
            return !file.dirty && !file.uploading && !file.conflict
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        c.watch.stop()
        let file = await h.session.liveFiles().first(where: { $0.path == c.path })
        let uploads = h.events.succeeded(c.path)
        let digests = c.watch.digests
        let valid = allowed.union([Self.digest(expected), c.watch.initialDigest])
        let partial = digests.filter { !valid.contains($0) }
        let finalBytes = (try? Data(contentsOf: c.remoteFile)) == expected
        #expect(landed, "\(label): server never held the final bytes and a clean file", sourceLocation: sourceLocation)
        #expect(finalBytes, "\(label): server bytes changed after landing", sourceLocation: sourceLocation)
        #expect(file?.conflict == false, "\(label): conflict raised", sourceLocation: sourceLocation)
        #expect(file?.dirty == false, "\(label): still dirty", sourceLocation: sourceLocation)
        #expect(file?.uploading == false, "\(label): still uploading", sourceLocation: sourceLocation)
        #expect(partial.isEmpty, "\(label): server held bytes that were never a whole save", sourceLocation: sourceLocation)
        #expect(uploads >= 1, "\(label): no upload event", sourceLocation: sourceLocation)
        if let maxUploads { #expect(uploads <= maxUploads, "\(label): \(uploads) uploads, expected at most \(maxUploads)", sourceLocation: sourceLocation) }
        return uploads
    }

    private func noStrays(_ label: String, _ h: Harness, allowed: Set<String>, sourceLocation: SourceLocation = #_sourceLocation) {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: h.remote.path)) ?? [])
        let strays = names.subtracting(allowed)
        #expect(strays.isEmpty, "\(label): stray files on the server: \(strays.sorted())", sourceLocation: sourceLocation)
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String], sourceLocation: SourceLocation = #_sourceLocation) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 { print("MATRIX tool \(tool) \(arguments) exited \(process.terminationStatus): \(stderr)") }
        #expect(process.terminationStatus == 0, "\(tool) failed: \(stderr)", sourceLocation: sourceLocation)
        return process.terminationStatus
    }

    private func python(_ script: String, _ arguments: [String]) throws {
        try run("/usr/bin/python3", ["-c", script] + arguments)
    }

    private let vimText = Data("line one\nanother one\nnothing here\n".utf8)
    private let vimDone = Data("line two\nanother two\nnothing here\n".utf8)

    // MARK: 1. vim

    @Test(arguments: ["default", "yes", "no", "auto"])
    func vimWrites(_ backupcopy: String) async throws {
        try await withHarness("vim") { h in
            let c = try await open(h, "note.txt", vimText)
            var args = ["-Nu", "NONE", "-n", "-es"]
            if backupcopy != "default" { args += ["-c", "set backupcopy=\(backupcopy)"] }
            args += ["-c", "%s/one/two/", "-c", "wq", c.local.path]
            try run("/usr/bin/vim", args)
            #expect(try Data(contentsOf: c.local) == vimDone)
            await expectSynced("1 vim backupcopy=\(backupcopy)", h, c, vimDone)
            noStrays("1 vim backupcopy=\(backupcopy)", h, allowed: ["note.txt"])
        }
    }

    // MARK: 2. vim with a swap file

    @Test func vimWithItsOwnSwapFile() async throws {
        try await withHarness("vimswap") { h in
            let c = try await open(h, "note.txt", vimText)
            // No -n: vim makes .note.txt.swp itself, writes, and removes it.
            try run("/usr/bin/vim", ["-Nu", "NONE", "-es", "-c", "set updatecount=1", "-c", "%s/one/two/", "-c", "w", "-c", "q", c.local.path])
            await expectSynced("2 vim real swap", h, c, vimDone)
            noStrays("2 vim real swap", h, allowed: ["note.txt"])
        }
    }

    @Test func vimWithALongLivedSwapFile() async throws {
        try await withHarness("vimswap2") { h in
            let c = try await open(h, "note.txt", vimText)
            let swap = c.local.deletingLastPathComponent().appendingPathComponent(".note.txt.swp")
            try Data(repeating: 0x55, count: 4096).write(to: swap)
            try await Task.sleep(nanoseconds: 800_000_000)
            // Swap churn before the write, as vim updates it while typing.
            for index in 0..<4 {
                try Data(repeating: UInt8(index), count: 4096 * (index + 1)).write(to: swap)
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            #expect(h.events.succeeded(c.path) == 0, "swap churn alone uploaded the file")
            try run("/usr/bin/vim", ["-Nu", "NONE", "-n", "-es", "-c", "%s/one/two/", "-c", "wq", c.local.path])
            try Data(repeating: 9, count: 100).write(to: swap)
            try FileManager.default.removeItem(at: swap)
            await expectSynced("2 vim fake swap", h, c, vimDone)
            noStrays("2 vim fake swap", h, allowed: ["note.txt"])
        }
    }

    // MARK: 3. VS Code: truncate and write in place

    @Test func inPlaceSmallWrite() async throws {
        try await withHarness("vscode") { h in
            let c = try await open(h, "app.js", Data("let a = 1\n".utf8))
            let final = Data("let a = 2\nlet b = 3\n".utf8)
            try python("import sys\nopen(sys.argv[1],'w').write(sys.argv[2])", [c.local.path, String(decoding: final, as: UTF8.self)])
            await expectSynced("3 in-place small", h, c, final)
        }
    }

    private static let chunkedWriter = """
    import sys, time, os
    path, source, chunks, gap, stall_at, stall = sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4]), int(sys.argv[5]), float(sys.argv[6])
    data = open(source, 'rb').read()
    step = len(data) // chunks
    with open(path, 'wb') as f:
        for i in range(chunks):
            f.write(data[i*step : (i+1)*step if i < chunks - 1 else len(data)])
            f.flush()
            os.fsync(f.fileno())
            time.sleep(stall if i == stall_at else gap)
    """

    private func bigData(_ count: Int, seed: UInt8) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            var x = UInt32(seed) &* 2654435761 &+ 1
            for index in 0..<count {
                x ^= x << 13; x ^= x >> 17; x ^= x << 5
                buffer[index] = UInt8(truncatingIfNeeded: x)
            }
        }
        return data
    }

    @Test func inPlaceLargeChunkedWrite() async throws {
        try await withHarness("big") { h in
            let c = try await open(h, "big.txt", bigData(4_000_000, seed: 1))
            let final = bigData(5_000_000, seed: 2)
            let source = h.staging.appendingPathComponent("final.bin")
            try final.write(to: source)
            // Ten chunks, 100 ms apart, each flushed and fsynced: about a second of writing.
            try python(Self.chunkedWriter, [c.local.path, source.path, "10", "0.1", "-1", "0"])
            await expectSynced("3 in-place 5MB chunked", h, c, final)
        }
    }

    /// A writer that stalls longer than the settle time mid-file may have its partial bytes
    /// uploaded, by design; the final bytes must still land.
    @Test func inPlaceLargeWriteWithAStall() async throws {
        try await withHarness("stall") { h in
            let c = try await open(h, "big.txt", bigData(4_000_000, seed: 3))
            let final = bigData(5_000_000, seed: 4)
            let source = h.staging.appendingPathComponent("final.bin")
            try final.write(to: source)
            try python(Self.chunkedWriter, [c.local.path, source.path, "10", "0.1", "4", "1.2"])
            let landed = await waitUntil {
                guard (try? Data(contentsOf: c.remoteFile)) == final else { return false }
                return await h.session.liveFiles().first?.dirty == false
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            c.watch.stop()
            #expect(landed)
        }
    }

    // MARK: 4. Temp and rename in the same folder

    @Test func atomicTempAndRename() async throws {
        try await withHarness("atomic") { h in
            let c = try await open(h, "main.go", Data("package main\n".utf8))
            let final = Data("package main\n\nfunc main() {}\n".utf8)
            try python("""
            import sys, os, tempfile
            path, text = sys.argv[1], sys.argv[2]
            d, n = os.path.split(path)
            fd, tmp = tempfile.mkstemp(prefix='.' + n + '.tmp', dir=d)
            os.write(fd, text.encode()); os.fsync(fd); os.close(fd)
            os.chmod(tmp, 0o600)
            os.rename(tmp, path)
            """, [c.local.path, String(decoding: final, as: UTF8.self)])
            await expectSynced("4 temp+rename", h, c, final)
            noStrays("4 temp+rename", h, allowed: ["main.go"])
        }
    }

    // MARK: 5. NSDocument / TextEdit

    @Test func replaceItemAtFromItemReplacementDirectory() async throws {
        try await withHarness("nsdoc") { h in
            let c = try await open(h, "doc.txt", Data("draft\n".utf8))
            let final = Data("final draft, saved by NSDocument\n".utf8)
            let scratch = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: c.local, create: true)
            let temp = scratch.appendingPathComponent(c.local.lastPathComponent)
            try final.write(to: temp)
            _ = try FileManager.default.replaceItemAt(c.local, withItemAt: temp)
            try? FileManager.default.removeItem(at: scratch)
            await expectSynced("5 replaceItemAt", h, c, final)
        }
    }

    @Test func coordinatedAtomicWrite() async throws {
        try await withHarness("coord") { h in
            let c = try await open(h, "doc.txt", Data("draft\n".utf8))
            let final = Data("coordinated\n".utf8)
            var coordinatorError: NSError?
            var writeError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: c.local, options: .forReplacing, error: &coordinatorError) { url in
                do { try final.write(to: url, options: .atomic) } catch { writeError = error }
            }
            #expect(coordinatorError == nil && writeError == nil)
            await expectSynced("5 coordinated .atomic", h, c, final)
            noStrays("5 coordinated .atomic", h, allowed: ["doc.txt"])
        }
    }

    @Test func coordinatedInPlaceWrite() async throws {
        try await withHarness("coord2") { h in
            let c = try await open(h, "doc.txt", Data("draft\n".utf8))
            let final = Data("coordinated in place\n".utf8)
            var coordinatorError: NSError?
            var writeError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: c.local, options: .forReplacing, error: &coordinatorError) { url in
                do { try final.write(to: url) } catch { writeError = error }
            }
            #expect(coordinatorError == nil && writeError == nil)
            await expectSynced("5 coordinated in place", h, c, final)
        }
    }

    // MARK: 6. Rapid successive saves

    @Test(arguments: [false, true])
    func rapidSaves(_ sameSize: Bool) async throws {
        try await withHarness("rapid") { h in
            let c = try await open(h, "rapid.txt", Data("start!\n".utf8))
            var allowed: Set<String> = []
            for index in 1...5 {
                let text = sameSize ? Data("save-\(index)\n".utf8) : Data(String(repeating: "x", count: index * 7).utf8 + Data("\n".utf8))
                allowed.insert(Self.digest(text))
                try text.write(to: c.local)
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let final = sameSize ? Data("final!\n".utf8) : Data("the final save\n".utf8)
            try final.write(to: c.local)
            await expectSynced("6 rapid saves sameSize=\(sameSize)", h, c, final, allowed: allowed, maxUploads: nil)
        }
    }

    /// Saves spaced just past the settle time, so each may start an upload that the next one overtakes.
    @Test func savesSpacedAroundTheSettleTime() async throws {
        try await withHarness("rapid2") { h in
            let c = try await open(h, "rapid.txt", Data("start!\n".utf8))
            var allowed: Set<String> = []
            for index in 1...5 {
                let text = Data("save-\(index)\n".utf8)
                allowed.insert(Self.digest(text))
                try text.write(to: c.local)
                try await Task.sleep(nanoseconds: 700_000_000)
            }
            let final = Data("final!\n".utf8)
            try final.write(to: c.local)
            await expectSynced("6 saves every 700ms", h, c, final, allowed: allowed, maxUploads: nil)
        }
    }

    // MARK: 7. Metadata only

    @Test func touchChmodAndXattrUploadNothing() async throws {
        try await withHarness("meta") { h in
            let c = try await open(h, "meta.txt", Data("unchanged\n".utf8))
            try await Task.sleep(nanoseconds: 500_000_000)
            try run("/usr/bin/touch", [c.local.path])
            try await Task.sleep(nanoseconds: 1_200_000_000)
            try run("/bin/chmod", ["644", c.local.path])
            try await Task.sleep(nanoseconds: 1_200_000_000)
            try run("/usr/bin/xattr", ["-w", "com.test", "x", c.local.path])
            try await Task.sleep(nanoseconds: 2_000_000_000)
            c.watch.stop()
            let file = await h.session.liveFiles().first
            #expect(h.events.succeeded(c.path) == 0)
            #expect(c.watch.renames == 0)
            #expect(file?.dirty == false && file?.uploading == false && file?.conflict == false)
            #expect(await h.session.unsyncedLiveCount == 0)
        }
    }

    // MARK: 8. Delete, then recreate

    @Test(arguments: [200, 300, 800])
    func deleteThenRecreate(_ gapMilliseconds: Int) async throws {
        try await withHarness("unlink") { h in
            let c = try await open(h, "gone.txt", Data("before\n".utf8))
            try await Task.sleep(nanoseconds: 500_000_000)
            let final = Data("after the unlink, gap \(gapMilliseconds)\n".utf8)
            try FileManager.default.removeItem(at: c.local)
            try await Task.sleep(nanoseconds: UInt64(gapMilliseconds) * 1_000_000)
            try final.write(to: c.local)
            await expectSynced("8 unlink+recreate \(gapMilliseconds)ms", h, c, final)
            #expect(FileManager.default.fileExists(atPath: c.local.path))
        }
    }

    /// An unlink that lands while a pass from an earlier event is pending, then a recreate 900 ms
    /// later: inside the one-second grace for a missing copy.
    @Test(arguments: [450, 550])
    func deleteWhileAPassIsPending(_ deleteAfter: Int) async throws {
        try await withHarness("pend") { h in
            let c = try await open(h, "gone.txt", Data("before\n".utf8))
            try await Task.sleep(nanoseconds: 1_500_000_000)
            try run("/usr/bin/touch", [c.local.path])
            try await Task.sleep(nanoseconds: UInt64(deleteAfter) * 1_000_000)
            try FileManager.default.removeItem(at: c.local)
            try await Task.sleep(nanoseconds: 900_000_000)
            let final = Data("recreated\n".utf8)
            let recreated = (try? final.write(to: c.local)) != nil
            #expect(recreated, "the Live folder was removed before the one-second grace ran out")
            if recreated { await expectSynced("8b pending pass \(deleteAfter)", h, c, final) }
        }
    }

    /// vim-like: a touch schedules a pass; swap-file churn (ignored) takes FSEvents' next delivery
    /// slot; the unlink lands just before the pass, so its own event is delivered ~300 ms later.
    @Test(arguments: [620, 635, 650])
    func unlinkBehindSwapChurn(_ unlinkAt: Int) async throws {
        try await withHarness("churn") { h in
            let c = try await open(h, "gone.txt", Data("before\n".utf8))
            let swap = c.local.deletingLastPathComponent().appendingPathComponent(".gone.txt.swp")
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let t0 = ContinuousClock.now
            try run("/usr/bin/touch", [c.local.path])
            try await Task.sleep(until: t0 + .milliseconds(560), clock: .continuous)
            try Data(repeating: 1, count: 4096).write(to: swap)
            try await Task.sleep(until: t0 + .milliseconds(unlinkAt), clock: .continuous)
            try FileManager.default.removeItem(at: c.local)
            try await Task.sleep(until: t0 + .milliseconds(unlinkAt + 800), clock: .continuous)
            let final = Data("recreated\n".utf8)
            let recreated = (try? final.write(to: c.local)) != nil
            try? FileManager.default.removeItem(at: swap)
            #expect(recreated, "the Live folder was removed before the one-second grace ran out")
            if recreated { await expectSynced("8c churn \(unlinkAt)", h, c, final) }
        }
    }

    // MARK: 9. The server changed behind the app's back

    @Test func saveAfterServerChangeIsAConflict() async throws {
        try await withHarness("conflict") { h in
            let c = try await open(h, "note.txt", Data("first\n".utf8))
            let remoteEdit = Data("remote-edit\n".utf8)
            try remoteEdit.write(to: c.remoteFile)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: c.remoteFile.path)
            let mine = Data("mine, saved in place\n".utf8)
            try mine.write(to: c.local)
            let conflicted = await waitUntil { await h.session.liveFiles().first?.conflict == true && h.events.conflicts(c.path) > 0 }
            let serverCopy = c.local.deletingLastPathComponent().appendingPathComponent("note.txt (server)")
            let renamesBefore = c.watch.renames
            #expect(conflicted)
            #expect((try? Data(contentsOf: serverCopy)) == remoteEdit)
            #expect(try Data(contentsOf: c.remoteFile) == remoteEdit)
            #expect(renamesBefore == 0)
            try await h.session.resolveLive(c.path, choice: .keepLocal)
            await expectSynced("9 conflict then keepLocal", h, c, mine, allowed: [Self.digest(remoteEdit)], maxUploads: 2)
            #expect(c.watch.renames == 1, "keepLocal made \(c.watch.renames) renames on the server")
            #expect(!FileManager.default.fileExists(atPath: serverCopy.path))
            noStrays("9", h, allowed: ["note.txt"])
        }
    }

    // MARK: 10. Two Live files at once

    @Test func twoFilesSavedTogether() async throws {
        try await withHarness("two") { h in
            let a = try await open(h, "a.txt", Data("a0\n".utf8))
            let b = try await open(h, "b.txt", Data("b0\n".utf8))
            let finalA = Data("a1, saved first\n".utf8)
            let finalB = Data("b1, saved 30 ms later\n".utf8)
            try finalA.write(to: a.local)
            try await Task.sleep(nanoseconds: 30_000_000)
            let temp = b.local.deletingLastPathComponent().appendingPathComponent(".b.txt.tmp")
            try finalB.write(to: temp)
            #expect(Darwin.rename(temp.path, b.local.path) == 0)
            await expectSynced("10 two files: a (in place)", h, a, finalA)
            await expectSynced("10 two files: b (rename)", h, b, finalB)
        }
    }
}

/// Watches the server file by polling: every rename onto it (a new inode) and every distinct content.
private final class ServerWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var inode: UInt64?
    private var stamp: String?
    private var renameCount = 0
    private var seen: [String] = []
    private var running = true
    let initialDigest: String
    private var thread: Thread?

    init(_ file: URL) {
        initialDigest = (try? Data(contentsOf: file)).map(EditorMatrix.digest) ?? ""
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        stamp = Self.describe(attributes)
        let thread = Thread { [weak self] in
            while let self, self.isRunning {
                self.sample(file)
                usleep(5_000)
            }
        }
        self.thread = thread
        thread.start()
    }

    private static func describe(_ attributes: [FileAttributeKey: Any]?) -> String? {
        guard let attributes else { return nil }
        return "\(attributes[.systemFileNumber] ?? "")-\(attributes[.size] ?? "")-\(attributes[.modificationDate] ?? "")"
    }

    private var isRunning: Bool { lock.withLock { running } }

    private func sample(_ file: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let now = Self.describe(attributes)
        let number = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        let changed = lock.withLock { () -> Bool in
            guard now != stamp else { return false }
            stamp = now
            if let number, number != inode {
                inode = number
                renameCount += 1
            }
            return true
        }
        if changed, let data = try? Data(contentsOf: file) {
            let digest = EditorMatrix.digest(data)
            lock.withLock { if seen.last != digest, digest != initialDigest || !seen.isEmpty { seen.append(digest) } }
        }
    }

    func stop() { lock.withLock { running = false } }
    var renames: Int { lock.withLock { renameCount } }
    var digests: Set<String> { lock.withLock { Set(seen) } }
}

private final class MatrixEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SessionEvent] = []

    func record(_ event: SessionEvent) { lock.withLock { events.append(event) } }

    func succeeded(_ path: RemotePath) -> Int {
        lock.withLock {
            events.filter { if case .operation(let op) = $0 { op.livePath == path && op.state == .succeeded } else { false } }.count
        }
    }

    func conflicts(_ path: RemotePath) -> Int {
        lock.withLock { events.filter { if case .conflict(let p, _) = $0 { p == path } else { false } }.count }
    }
}
