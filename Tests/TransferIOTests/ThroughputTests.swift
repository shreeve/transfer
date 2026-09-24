import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// How bytes cross the channels: a file's requests pipelined so its chain costs few round trips,
/// one large file split over several channels (PERF-07), and small files sharing a channel
/// (PERF-04). Against scripted servers, so the order of requests on the wire is checked.
@Suite struct PipelineTests {
    private static let path = RemotePath(string: "/srv/file")

    /// Bytes `0..<size` of a file whose every byte is known.
    private static func content(_ size: Int) -> Data {
        Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })
    }

    /// Answers READs from `content`, at most `cap` bytes a reply (20 ms late when `slow`), and
    /// fails every READ after the `failAfter`th.
    private static func reading(_ content: Data, cap: Int, slow: Bool = false, failAfter: Int = .max) async throws -> ScriptedServer {
        let reads = Locked(0)
        let server = Locked<ScriptedServer?>(nil)
        // One queue writes every reply of a slow server, so no two replies interleave on the pipe.
        let replies = DispatchQueue(label: "reading")
        @Sendable func late(_ reply: Data, after seconds: Double) -> Data? {
            guard slow else { return reply }
            replies.asyncAfter(deadline: .now() + seconds) { server.value?.send(reply) }
            return nil
        }
        let made = try await ScriptedServer { request in
            switch request.type {
            case SFTPCode.open: return late(ScriptedServer.handle(request.id), after: 0)
            case SFTPCode.close: return late(ScriptedServer.ok(request.id), after: 0)
            case SFTPCode.read:
                let count = reads.withLock { value in
                    value += 1
                    return value
                }
                guard count <= failAfter else { return ScriptedServer.status(request.id, SFTPCode.failure, "disk error") }
                var reader = ByteReader(request.body)
                _ = try? reader.blob()
                let offset = Int((try? reader.u64()) ?? 0)
                let length = Int((try? reader.u32()) ?? 0)
                let reply = offset < content.count
                    ? ScriptedServer.data(request.id, content.subdata(in: offset..<min(offset + min(length, cap), content.count)))
                    : ScriptedServer.status(request.id, SFTPCode.eof)
                return late(reply, after: 0.02)
            default: return nil
            }
        }
        server.value = made
        return made
    }

    private static func scratchFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-\(UUID().uuidString)")
    }

    /// Two channels read one file into one local file, each from a server that answers short, as
    /// some servers do: every short reply's rest is asked for again, by whichever channel got it,
    /// and the file arrives whole with no gap.
    @Test func twoChannelsFillOneFileFromShortReadingServers() async throws {
        // Several of one channel's 2 MB windows, from a slow server, so the other takes a share.
        let content = Self.content(5_000_003)
        let servers = [try await Self.reading(content, cap: 20_000, slow: true), try await Self.reading(content, cap: 50_000)]
        let file = Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let reports = Locked<[TransferProgress]>([])
        let parts = try DownloadParts(file, size: UInt64(content.count)) { progress in reports.withLock { $0.append(progress) } }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for server in servers { group.addTask { try await server.channel.receive(Self.path, into: parts) } }
            try await group.waitForAll()
        }
        try parts.finish()
        #expect(try Data(contentsOf: file) == content)
        #expect(servers.allSatisfy { !$0.sent(SFTPCode.read).isEmpty })
        #expect(reports.value.last?.completed == UInt64(content.count))
        for server in servers { await server.stop() }
    }

    /// One part failing fails the whole file, and the other channel stops too.
    @Test func aFailedPartFailsTheWholeFile() async throws {
        let content = Self.content(4 << 20)
        let good = try await Self.reading(content, cap: 65_536)
        let failing = try await Self.reading(content, cap: 65_536, failAfter: 3)
        let file = Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let parts = try DownloadParts(file, size: UInt64(content.count)) { _ in }
        await #expect(throws: TransferError.failed("disk error")) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for server in [good, failing] { group.addTask { try await server.channel.receive(Self.path, into: parts) } }
                try await group.waitForAll()
            }
        }
        #expect(throws: TransferError.self) { try parts.finish() }
        await good.stop()
        await failing.stop()
    }

    /// A second channel helps with a file only when the file it opens is the one listed: a file
    /// replaced in the meantime is never read half from each version.
    @Test func aSecondChannelLeavesAReplacedFileAlone() async throws {
        let content = Self.content(200_000)
        let server = try await ScriptedServer { request in
            switch request.type {
            case SFTPCode.open: return ScriptedServer.handle(request.id)
            case SFTPCode.close: return ScriptedServer.ok(request.id)
            case SFTPCode.fstat: return ScriptedServer.attrs(request.id, SFTPAttrs(size: 200_000, permissions: 0o100644, atime: 9, mtime: 9))
            default: return nil
            }
        }
        let file = Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let parts = try DownloadParts(file, size: UInt64(content.count)) { _ in }
        try await server.channel.receive(Self.path, into: parts, matching: Fingerprint(size: 200_000, mtime: 8), helping: true)
        #expect(server.sent(SFTPCode.read).isEmpty)
        #expect(await eventually { server.sent(SFTPCode.close).count == 1 })
        #expect(parts.nextRequest()?.offset == 0)
        await server.stop()
    }

    /// A file that grew since it was listed was read only up to its listed size and placed as
    /// complete, cut short, when no second channel helped (R-T3). The channel that owns a download
    /// checks the open file against the listing too; its check rides with the first READs (this
    /// server answers it only once a READ is in), and fails the download before a byte is written.
    @Test(arguments: [200_000, 300_000]) func theOwningChannelChecksTheFileAgainstItsListing(listed: Int) async throws {
        let content = Self.content(300_000)
        let check = Locked<UInt32?>(nil)
        let server = try await ScriptedServer { request in
            switch request.type {
            case SFTPCode.open: return ScriptedServer.handle(request.id)
            case SFTPCode.close: return ScriptedServer.ok(request.id)
            case SFTPCode.fstat:
                check.value = request.id
                return nil
            case SFTPCode.read:
                var reply = Data()
                if let id = check.withLock({ id in defer { id = nil }; return id }) {
                    reply = ScriptedServer.attrs(id, SFTPAttrs(size: UInt64(content.count), permissions: 0o100644, atime: 9, mtime: 9))
                }
                var reader = ByteReader(request.body)
                _ = try? reader.blob()
                let offset = Int((try? reader.u64()) ?? 0)
                let length = Int((try? reader.u32()) ?? 0)
                return reply + (offset < content.count
                    ? ScriptedServer.data(request.id, content.subdata(in: offset..<min(offset + length, content.count)))
                    : ScriptedServer.status(request.id, SFTPCode.eof))
            default: return nil
            }
        }
        let file = Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let download = { try await server.channel.download(Self.path, to: file, size: UInt64(listed), matching: Fingerprint(size: UInt64(listed), mtime: 9)) { _ in } }
        if listed == content.count {
            try await download()
            #expect(try Data(contentsOf: file) == content)
        } else {
            await #expect(throws: TransferError.failed("“file” changed on the server while it downloaded")) { try await download() }
            #expect(try Data(contentsOf: file).isEmpty)
        }
        #expect(server.sent(SFTPCode.fstat).count == 1)
        // The server answers in order, so once it has the CLOSE every READ reply is out, and none
        // is written into a pipe `stop` has closed.
        #expect(await eventually { server.sent(SFTPCode.close).count == 1 })
        await server.stop()
    }

    /// An upload's close, and its mode and time before that, go out right behind the last write,
    /// not a round trip later: this server answers nothing until it has the close. The stamp
    /// comes after every write, so no write lands after the time is set.
    @Test func anUploadSendsItsStampAndCloseBehindTheLastWrite() async throws {
        let held = Locked(Data())
        let server = try await ScriptedServer { request in
            switch request.type {
            case SFTPCode.open: return ScriptedServer.handle(request.id)
            case SFTPCode.write:
                held.withLock { $0.append(ScriptedServer.ok(request.id)) }
                return nil
            case SFTPCode.fsetstat:
                held.withLock { $0.append(ScriptedServer.ok(request.id)) }
                return nil
            case SFTPCode.close:
                return held.withLock { replies in
                    defer { replies = Data() }
                    return replies + ScriptedServer.ok(request.id)
                }
            default: return nil
            }
        }
        let file = Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try Self.content(300_000).write(to: file)
        try await server.channel.upload(file, to: Self.path, stamp: .stamp(mode: 0o644, mtime: 1_700_000_000)) { _ in }
        let order = server.requests.value.map(\.type).filter { $0 != SFTPCode.initialize }
        #expect(order == [SFTPCode.open] + Array(repeating: SFTPCode.write, count: 5) + [SFTPCode.fsetstat, SFTPCode.close])
        var reader = ByteReader(try #require(server.sent(SFTPCode.fsetstat).first).body)
        _ = try reader.blob()
        let attrs = try reader.attrs()
        #expect(attrs.mtime == 1_700_000_000)
        #expect(attrs.permissions == 0o644)
        await server.stop()
    }

    /// A second channel's share of a large upload writes into the file the first created, never
    /// creating or truncating it, and between them every byte lands at its offset.
    @Test func twoChannelsWriteOneUpload() async throws {
        let content = Self.content(3 << 20)
        let written = Locked(Data(count: content.count))
        // The first server holds its answers until the second has a write, so the first channel,
        // with 2 MB out, cannot take the whole 3 MB before the second has opened.
        let gate = Locked((open: false, held: Data(), first: ScriptedServer?.none))
        func writing(isFirst: Bool) async throws -> ScriptedServer {
            try await ScriptedServer { request in
                switch request.type {
                case SFTPCode.open: return ScriptedServer.handle(request.id)
                case SFTPCode.close: return ScriptedServer.ok(request.id)
                case SFTPCode.write:
                    var reader = ByteReader(request.body)
                    _ = try? reader.blob()
                    guard let offset = try? reader.u64(), let bytes = try? reader.blob() else { return nil }
                    written.withLock { $0.replaceSubrange(Int(offset)..<Int(offset) + bytes.count, with: bytes) }
                    return gate.withLock { gate in
                        if isFirst, !gate.open {
                            gate.held.append(ScriptedServer.ok(request.id))
                            return nil
                        }
                        if !isFirst, !gate.open {
                            gate.open = true
                            gate.first?.send(gate.held)
                        }
                        return ScriptedServer.ok(request.id)
                    }
                default: return nil
                }
            }
        }
        let first = try await writing(isFirst: true)
        gate.withLock { $0.first = first }
        let second = try await writing(isFirst: false)
        let file = Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try content.write(to: file)
        let parts = try UploadParts(file) { _ in }
        let handle = try await first.channel.create(Self.path)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await first.channel.send(parts, to: handle) }
            group.addTask { try await second.channel.send(parts, into: Self.path) }
            try await group.waitForAll()
        }
        #expect(written.value == content)
        #expect(!second.sent(SFTPCode.write).isEmpty)
        var reader = ByteReader(try #require(second.sent(SFTPCode.open).first).body)
        _ = try reader.blob()
        #expect(try reader.u32() == SFTPCode.fxWrite)
        await first.stop()
        await second.stop()
    }

    /// A copy on the server costs two round trips on its channel: both OPENs together, then the
    /// copy, its stamp, and both CLOSEs together. This server answers only once it has them all.
    @Test func aServerCopySendsItsRequestsTogether() async throws {
        let held = Locked((replies: Data(), count: 0))
        let server = try await ScriptedServer(extensions: ["copy-data"]) { request in
            let reply = request.type == SFTPCode.open ? ScriptedServer.handle(request.id, "h\(request.id)") : ScriptedServer.ok(request.id)
            return held.withLock { held in
                held.replies.append(reply)
                held.count += 1
                let opens = request.type == SFTPCode.open && held.count == 2
                let closes = request.type == SFTPCode.close && held.count == 4
                guard opens || closes else { return nil }
                defer { held = (Data(), 0) }
                return held.replies
            }
        }
        try await server.channel.copyData(Self.path, to: RemotePath(string: "/srv/copy"), stamp: .stamp(mode: 0o600, mtime: 5))
        let order = server.requests.value.map(\.type).filter { $0 != SFTPCode.initialize }
        #expect(order == [SFTPCode.open, SFTPCode.open, SFTPCode.extended, SFTPCode.fsetstat, SFTPCode.close, SFTPCode.close])
        await server.stop()
    }
}

/// The same against the local sshd: small files share data channels and a large one never does,
/// a large file moves over several channels at once, and a part that fails leaves no temp.
@Suite(.serialized, .enabled(if: ServerHarness.available, "needs the local sshd from Scripts/local-sshd.sh"))
struct ThroughputServerTests {
    /// Small jobs share a channel, up to sixteen on one; a whole-channel job shares with nobody;
    /// and there are never more than seven data channels.
    @Test func smallJobsShareDataChannelsAndWholeOnesDoNot() async throws {
        try await withHarness("share", connected: true) { h in
            let state = Locked((holders: [ObjectIdentifier: (small: Int, whole: Int)](), peak: 0, overfull: false, mixed: false))
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<48 {
                    let share: SSHConnection.DataShare = index % 6 == 0 ? .whole : .small
                    group.addTask {
                        try await h.session.withData(share) { link in
                            state.withLock { state in
                                var held = state.holders[ObjectIdentifier(link)] ?? (0, 0)
                                if share == .whole { held.whole += 1 } else { held.small += 1 }
                                state.holders[ObjectIdentifier(link)] = held
                                state.peak = max(state.peak, state.holders.values.reduce(0) { $0 + $1.small + $1.whole })
                                if held.small > SSHConnection.DataShare.whole.rawValue { state.overfull = true }
                                if held.whole > 0, held.small + held.whole > 1 { state.mixed = true }
                            }
                            try await Task.sleep(for: .milliseconds(30))
                            _ = try await link.realpath(RemotePath(string: "."))
                            state.withLock { state in
                                if share == .whole { state.holders[ObjectIdentifier(link)]?.whole -= 1 } else { state.holders[ObjectIdentifier(link)]?.small -= 1 }
                            }
                        }
                    }
                }
                try await group.waitForAll()
            }
            #expect(state.value.holders.count <= SSHConnection.dataChannels)
            #expect(state.value.peak > SSHConnection.dataChannels)
            #expect(!state.value.overfull)
            #expect(!state.value.mixed)
        }
    }

    /// Folder copies of many small files in every direction, where files share channels, land
    /// every byte, on a fresh connection whose channels all open during the copy.
    @Test func manySmallFilesCopyWhole() async throws {
        try await withHarness("small", connected: true) { h in
            let source = h.staging.appendingPathComponent("tree")
            var expected: [String: Data] = [:]
            for index in 0..<300 {
                let folder = source.appendingPathComponent("d\(index % 3)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let data = Data((0..<(100 + index * 37)).map { UInt8(truncatingIfNeeded: $0 &+ index) })
                try data.write(to: folder.appendingPathComponent("f\(index)"))
                expected["d\(index % 3)/f\(index)"] = data
            }
            func check(_ root: URL) throws {
                for (key, data) in expected { #expect(try Data(contentsOf: root.appendingPathComponent(key)) == data) }
                let names = try FileManager.default.subpathsOfDirectory(atPath: root.path)
                #expect(!names.contains { $0.contains(".transfer-") })
            }
            let up = h.remotePath.appending(name: Array("up".utf8))
            try await h.session.upload(source, to: up) { _ in }
            try check(h.remote.appendingPathComponent("up"))
            try await h.session.copy(up, to: h.remotePath.appending(name: Array("copied".utf8))) { _ in }
            try check(h.remote.appendingPathComponent("copied"))
            let down = h.staging.appendingPathComponent("down")
            try await h.session.download(up, to: down) { _ in }
            try check(down)
        }
    }

    /// A large file goes both ways over several data channels at once, whole and with its time.
    @Test func aLargeFileMovesOverSeveralChannels() async throws {
        try await withHarness("stripe", connected: true) { h in
            let size = Int(SSHConnection.stripeSize) * 3 + 12_345
            let local = h.staging.appendingPathComponent("big.bin")
            var data = Data(count: size)
            data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, size) }
            try data.write(to: local)
            let when = Date(timeIntervalSince1970: 1_600_000_000)
            try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: local.path)
            let before = try await passengers(h).count
            let remote = h.remotePath.appending(name: Array("big.bin".utf8))
            try await h.session.upload(local, to: remote) { _ in }
            #expect(try Data(contentsOf: h.remote.appendingPathComponent("big.bin")) == data)
            let attributes = try FileManager.default.attributesOfItem(atPath: h.remote.appendingPathComponent("big.bin").path)
            #expect(attributes[.modificationDate] as? Date == when)
            #expect(try await passengers(h).count >= before + 2)
            let down = h.staging.appendingPathComponent("down.bin")
            try await h.session.download(remote, to: down) { _ in }
            #expect(try Data(contentsOf: down) == data)
            #expect(try FileManager.default.contentsOfDirectory(atPath: h.staging.path).sorted() == ["big.bin", "down.bin"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: h.remote.path) == ["big.bin"])
        }
    }

    /// A file listed before it grew, small or large enough to split across channels, was placed
    /// cut to its listed size as if complete (R-T3). It now fails, and nothing is placed.
    @Test(arguments: [100, Int(SSHConnection.stripeSize) + 1]) func aFileThatGrewSinceItWasListedIsNotPlacedShort(size: Int) async throws {
        try await withHarness("stale", connected: true) { h in
            let served = h.remote.appendingPathComponent("grows.bin")
            try Data(count: size).write(to: served)
            let path = h.remotePath.appending(name: Array("grows.bin".utf8))
            let listed = try await h.session.stat(path)
            let handle = try FileHandle(forWritingTo: served)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(count: 1000))
            try handle.close()
            let down = h.staging.appendingPathComponent("grows.bin")
            await #expect(throws: TransferError.failed("“grows.bin” changed on the server while it downloaded")) {
                try await h.session.fetch(path, info: listed, to: down) { _ in }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: h.staging.path).isEmpty)
            try await h.session.fetch(path, info: try await h.session.stat(path), to: down) { _ in }
            #expect(try Data(contentsOf: down).count == size + 1000)
        }
    }

    /// A channel dying under one part of a large file fails the whole file, and no temp is left
    /// on either side.
    @Test func aPartThatFailsLeavesNoTemp() async throws {
        try await withHarness("sfail", connected: true) { h in
            let size = 48 << 20
            let local = h.staging.appendingPathComponent("big.bin")
            try Data(count: size).write(to: local)
            try Data(count: size).write(to: h.remote.appendingPathComponent("there.bin"))
            // Four data channels, open and idle, so a transfer's parts start on all of them at once.
            let reserved = Set(try await passengers(h).map(\.pid))
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<4 { group.addTask { try await h.session.withData { _ in try await Task.sleep(for: .milliseconds(300)) } } }
                try await group.waitForAll()
            }
            let data = try await passengers(h).map(\.pid).filter { !reserved.contains($0) }
            #expect(data.count == 4)
            let down = h.staging.appendingPathComponent("down")
            try FileManager.default.createDirectory(at: down, withIntermediateDirectories: true)
            await #expect(throws: TransferError.self) {
                try await h.session.download(h.remotePath.appending(name: Array("there.bin".utf8)), to: down.appendingPathComponent("there.bin"), progress: killingOne(data))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: down.path).isEmpty)

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<4 { group.addTask { try await h.session.withData { _ in try await Task.sleep(for: .milliseconds(300)) } } }
                try await group.waitForAll()
            }
            let alive = try await passengers(h).map(\.pid).filter { !reserved.contains($0) }
            #expect(alive.count == 4)
            await #expect(throws: TransferError.self) {
                try await h.session.upload(local, to: h.remotePath.appending(name: Array("up.bin".utf8)), progress: killingOne(alive))
            }
            #expect(await waitUntil { (try? FileManager.default.contentsOfDirectory(atPath: h.remote.path)) == ["there.bin"] })
        }
    }
}

/// Kills one of `pids` at the first progress report, which comes with a transfer's first bytes.
private func killingOne(_ pids: [pid_t]) -> @Sendable (TransferProgress) -> Void {
    let victims = Locked(pids)
    return { _ in if let pid = victims.withLock({ $0.popLast() }) { kill(pid, SIGKILL) } }
}

/// The session's SFTP passengers: its reserved channels and its data channels.
private func passengers(_ h: ServerHarness) async throws -> [(pid: pid_t, command: String)] {
    let socket = h.root.appendingPathComponent("ssh/\(h.session.connection.id.socketName)").path
    let listed = try await Subprocess.run("/bin/ps", ["-axwwo", "pid=,command="], timeout: .seconds(5))
    return listed.stdout.split(separator: "\n").compactMap { line in
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.contains(socket), text.contains("/usr/bin/ssh"), text.contains(" sftp"),
              let space = text.firstIndex(of: " "), let pid = pid_t(text[..<space]) else { return nil }
        return (pid, String(text[space...]))
    }
}
