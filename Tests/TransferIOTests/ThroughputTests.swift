import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// How bytes cross the channels: a file's requests pipelined so its chain costs few round trips,
/// and small files sharing a channel (PERF-04). Against scripted servers, so the order of
/// requests on the wire is checked.
@Suite struct PipelineTests {
    private static let path = RemotePath(string: "/srv/file")

    /// Bytes `0..<size` of a file whose every byte is known.
    private static func content(_ size: Int) -> Data {
        Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })
    }

    private static func scratchFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-\(UUID().uuidString)")
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

/// The same against the local sshd: small files share data channels and a large one never does.
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
}
