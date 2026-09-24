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
}
