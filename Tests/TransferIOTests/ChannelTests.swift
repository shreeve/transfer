import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// `SFTPChannel` against a scripted server: what it does with names, renames, and handles that a
/// real server would rarely or never send.
@Suite struct ChannelTests {
    /// A listing whose first READDIR page holds `names` and whose next pages say EOF.
    private static func folder(_ names: [[UInt8]]) -> @Sendable (ScriptedServer.Request) -> Data? {
        let pages = Locked(0)
        return { request in
            switch request.type {
            case SFTPCode.opendir: return ScriptedServer.handle(request.id)
            case SFTPCode.readdir:
                let page = pages.withLock { count in
                    count += 1
                    return count
                }
                return page == 1 ? ScriptedServer.names(request.id, names) : ScriptedServer.status(request.id, SFTPCode.eof)
            case SFTPCode.close: return ScriptedServer.ok(request.id)
            default: return ScriptedServer.status(request.id, SFTPCode.failure)
            }
        }
    }

    /// A server's name becomes a path component under the listed folder, so a name that is not
    /// exactly one (a slash could climb out of a download's folder) never leaves the channel.
    @Test func aListingDropsNamesThatAreNotOneComponent() async throws {
        let hostile: [[UInt8]] = [
            Array("good".utf8), [], Array(".".utf8), Array("..".utf8), Array("a/b".utf8),
            Array("../../../Documents/".utf8), Array("trailing/".utf8), [0x6E, 0x00, 0x6C], Array(".hidden".utf8),
        ]
        let server = try await ScriptedServer(answer: Self.folder(hostile))
        var names: [[UInt8]] = []
        for try await item in await server.channel.list(RemotePath(string: "/srv")) {
            names.append(item.path.nameBytes)
            #expect(item.path.parent == RemotePath(string: "/srv"))
        }
        #expect(names == [Array("good".utf8), Array(".hidden".utf8)])
        await server.stop()
    }

    /// SFC-4: a cancelled listing (fast browsing cancels the last folder's) used to skip its
    /// CLOSE, and the server kept every such directory handle open until the channel died.
    @Test func aCancelledListingClosesItsHandle() async throws {
        let server = try await ScriptedServer { request in
            switch request.type {
            case SFTPCode.opendir: ScriptedServer.handle(request.id)
            case SFTPCode.close: ScriptedServer.ok(request.id)
            default: nil
            }
        }
        let reader = Task {
            for try await _ in await server.channel.list(RemotePath(string: "/srv")) {}
        }
        #expect(await eventually { !server.sent(SFTPCode.readdir).isEmpty })
        reader.cancel()
        _ = try? await reader.value
        #expect(await eventually { server.sent(SFTPCode.close).count == 1 })
        #expect(server.sent(SFTPCode.close).first?.paths == ["h"])
        await server.stop()
    }

    /// A reader that stops early, as a lookup for one name does, also closes the handle.
    @Test func aListingLeftEarlyClosesItsHandle() async throws {
        let server = try await ScriptedServer(answer: Self.folder([Array("a".utf8), Array("b".utf8)]))
        for try await _ in await server.channel.list(RemotePath(string: "/srv")) { break }
        #expect(await eventually { server.sent(SFTPCode.close).count == 1 })
        await server.stop()
    }

    // MARK: Transfers

    /// A server holding one file of `size` bytes, answering reads and writes when `answers`.
    private static func holding(_ size: Int, answers: Bool = true) async throws -> ScriptedServer {
        try await ScriptedServer { request in
            switch request.type {
            case SFTPCode.open: return ScriptedServer.handle(request.id)
            case SFTPCode.close: return ScriptedServer.ok(request.id)
            case SFTPCode.read where answers:
                var reader = ByteReader(request.body)
                _ = try? reader.blob()
                let offset = Int((try? reader.u64()) ?? 0)
                let length = Int((try? reader.u32()) ?? 0)
                guard offset < size else { return ScriptedServer.status(request.id, SFTPCode.eof) }
                return ScriptedServer.data(request.id, Data(repeating: 1, count: min(length, size - offset)))
            case SFTPCode.write where answers: return ScriptedServer.ok(request.id)
            default: return nil
            }
        }
    }

    /// Progress reaches the caller at most ten times a second and always ends at the total: each
    /// report is a hop to the main actor, and there is one 64 KB request every few microseconds.
    @Test func progressIsPacedAndEndsAtTheTotal() async throws {
        let size = 4 << 20
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("paced-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 2, count: size).write(to: file)
        let server = try await Self.holding(size)
        let reports = Locked<[TransferProgress]>([])
        try await server.channel.upload(file, to: RemotePath(string: "/srv/up")) { progress in reports.withLock { $0.append(progress) } }
        #expect(reports.value.count < 10)
        #expect(reports.value.last?.completed == UInt64(size))
        reports.value = []
        try await server.channel.download(RemotePath(string: "/srv/down"), to: file, size: UInt64(size)) { progress in reports.withLock { $0.append(progress) } }
        #expect(reports.value.count < 10)
        #expect(reports.value.last?.completed == UInt64(size))
        #expect(try Data(contentsOf: file) == Data(repeating: 1, count: size))
        await server.stop()
    }

    /// A transfer cancelled while the server sits on its requests stops at once, not when the
    /// channel's stall limit ends it.
    @Test func aCancelledTransferStopsWithoutItsReplies() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stuck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 2, count: 1 << 20).write(to: file)
        let server = try await Self.holding(1 << 20, answers: false)
        let transfers = [
            Task { try await server.channel.upload(file, to: RemotePath(string: "/srv/up")) { _ in } },
            Task { try await server.channel.download(RemotePath(string: "/srv/down"), to: file.appendingPathExtension("down"), size: 1 << 20) { _ in } },
        ]
        #expect(await eventually { server.sent(SFTPCode.write).count == 16 && server.sent(SFTPCode.read).count == 16 })
        let started = ContinuousClock.now
        for transfer in transfers {
            transfer.cancel()
            await #expect(throws: (any Error).self) { try await transfer.value }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        try? FileManager.default.removeItem(at: file.appendingPathExtension("down"))
        await server.stop()
    }

    /// A server whose folder /srv lists `names`, where LSTAT finds what `lookup` says, and which
    /// has posix-rename.
    private static func renaming(_ names: [String], lookup: @escaping @Sendable (String) -> UInt32?) async throws -> ScriptedServer {
        let listing = folder(names.map { Array($0.utf8) })
        return try await ScriptedServer(extensions: ["posix-rename@openssh.com"]) { request in
            switch request.type {
            case SFTPCode.lstat:
                let path = request.paths[0]
                if let code = lookup(path) { return ScriptedServer.status(request.id, code) }
                return ScriptedServer.attrs(request.id)
            case SFTPCode.rename, SFTPCode.extended: return ScriptedServer.ok(request.id)
            default: return listing(request)
            }
        }
    }

    /// On a case-sensitive server `Notes.txt` is a second file, not the source under another case.
    /// Renaming `notes.txt` to it must refuse, not posix-rename over it.
    @Test func aCaseOnlyRenameNeverReplacesASecondFile() async throws {
        let server = try await Self.renaming(["notes.txt", "Notes.txt"]) { _ in nil }
        await #expect(throws: TransferError.failed("“Notes.txt” already exists there")) {
            try await server.channel.rename(RemotePath(string: "/srv/notes.txt"), to: RemotePath(string: "/srv/Notes.txt"))
        }
        #expect(server.sent(SFTPCode.extended).isEmpty)
        #expect(server.sent(SFTPCode.rename).isEmpty)
        await server.stop()
    }

    /// On a case-insensitive server the lookup finds the source itself; the listing shows no
    /// second file, so the case change goes through posix-rename.
    @Test func aCaseOnlyRenameOnACaseInsensitiveServerUsesPosixRename() async throws {
        let server = try await Self.renaming(["notes.txt"]) { _ in nil }
        try await server.channel.rename(RemotePath(string: "/srv/notes.txt"), to: RemotePath(string: "/srv/Notes.txt"))
        let sent = server.sent(SFTPCode.extended)
        #expect(sent.count == 1)
        #expect(sent.first?.paths == ["posix-rename@openssh.com", "/srv/notes.txt", "/srv/Notes.txt"])
        await server.stop()
    }

    /// With nothing at the new name, a case-only rename is a plain RENAME, like any other.
    @Test func aCaseOnlyRenameToAFreeNameIsAPlainRename() async throws {
        let server = try await Self.renaming(["notes.txt"]) { $0 == "/srv/Notes.txt" ? SFTPCode.noSuchFile : nil }
        try await server.channel.rename(RemotePath(string: "/srv/notes.txt"), to: RemotePath(string: "/srv/Notes.txt"))
        #expect(server.sent(SFTPCode.rename).first?.paths == ["/srv/notes.txt", "/srv/Notes.txt"])
        #expect(server.sent(SFTPCode.extended).isEmpty)
        await server.stop()
    }

    // MARK: Replace without posix-rename

    private static let temp = RemotePath(string: "/srv/.a.transfer-1")
    private static let placed = RemotePath(string: "/srv/a")

    /// A server without posix-rename, where `placed` is `kind` (nil: absent) and a RENAME of the
    /// temp onto it answers `onto`, nil for no answer.
    private static func stepping(_ kind: SFTPAttrs?, onto: UInt32? = SFTPCode.ok) async throws -> ScriptedServer {
        try await ScriptedServer { request in
            switch request.type {
            case SFTPCode.lstat:
                guard let kind else { return ScriptedServer.status(request.id, SFTPCode.noSuchFile) }
                return ScriptedServer.attrs(request.id, kind)
            case SFTPCode.rename:
                if request.paths[0] == temp.display {
                    return onto.map { ScriptedServer.status(request.id, $0) }
                }
                return ScriptedServer.ok(request.id)
            case SFTPCode.remove: return ScriptedServer.ok(request.id)
            default: return ScriptedServer.status(request.id, SFTPCode.failure)
            }
        }
    }

    /// The old file steps aside, the temp takes its name, and only then is the old file removed.
    @Test func aReplaceWithoutPosixRenameMovesTheOldFileAsideFirst() async throws {
        let server = try await Self.stepping(ScriptedServer.file)
        try await server.channel.replace(Self.temp, onto: Self.placed)
        let renames = server.sent(SFTPCode.rename).map(\.paths)
        #expect(renames.count == 2)
        let aside = renames[0][1]
        #expect(renames[0][0] == "/srv/a" && aside.hasPrefix("/srv/.transfer-old-"))
        #expect(renames[1] == ["/srv/.a.transfer-1", "/srv/a"])
        #expect(server.sent(SFTPCode.remove).map(\.paths) == [[aside]])
        await server.stop()
    }

    /// LIVE-08: when the temp cannot take the name, the old file comes back and nothing is
    /// removed, so the server never ends with neither version.
    @Test func aFailedReplaceWithoutPosixRenamePutsTheOldFileBack() async throws {
        let server = try await Self.stepping(ScriptedServer.file, onto: SFTPCode.failure)
        await #expect(throws: TransferError.failed("")) { try await server.channel.replace(Self.temp, onto: Self.placed) }
        let renames = server.sent(SFTPCode.rename).map(\.paths)
        #expect(renames.count == 3)
        #expect(renames[2] == [renames[0][1], "/srv/a"])
        #expect(server.sent(SFTPCode.remove).isEmpty)
        await server.stop()
    }

    /// Cancelled after the old file stepped aside, the replace still puts it back.
    @Test func aCancelledReplaceWithoutPosixRenameStillPutsTheOldFileBack() async throws {
        let server = try await Self.stepping(ScriptedServer.file, onto: nil)
        let replace = Task { try await server.channel.replace(Self.temp, onto: Self.placed) }
        #expect(await eventually { server.sent(SFTPCode.rename).count == 2 })
        replace.cancel()
        try await Task.sleep(for: .milliseconds(50))
        server.send(ScriptedServer.status(server.sent(SFTPCode.rename)[1].id, SFTPCode.failure))
        await #expect(throws: (any Error).self) { try await replace.value }
        let renames = server.sent(SFTPCode.rename).map(\.paths)
        #expect(renames.count == 3)
        #expect(renames.last == [renames[0][1], "/srv/a"])
        await server.stop()
    }

    @Test func aReplaceOntoNothingIsOneRename() async throws {
        let server = try await Self.stepping(nil)
        try await server.channel.replace(Self.temp, onto: Self.placed)
        #expect(server.sent(SFTPCode.rename).map(\.paths) == [["/srv/.a.transfer-1", "/srv/a"]])
        await server.stop()
    }

    @Test func aReplaceNeverReplacesAFolder() async throws {
        var folder = SFTPAttrs()
        folder.permissions = 0o040755
        let server = try await Self.stepping(folder)
        await #expect(throws: TransferError.typeMismatch("a")) { try await server.channel.replace(Self.temp, onto: Self.placed) }
        #expect(server.sent(SFTPCode.rename).isEmpty)
        await server.stop()
    }

    /// A lookup that fails for any reason but "no such file" is not evidence the name is free.
    @Test func aRenameWhoseLookupFailsRenamesNothing() async throws {
        let server = try await Self.renaming([]) { _ in SFTPCode.permission }
        await #expect(throws: TransferError.permissionDenied("")) {
            try await server.channel.rename(RemotePath(string: "/srv/a"), to: RemotePath(string: "/srv/b"))
        }
        #expect(server.sent(SFTPCode.rename).isEmpty)
        await server.stop()
    }
}
