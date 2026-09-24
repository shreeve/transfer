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
