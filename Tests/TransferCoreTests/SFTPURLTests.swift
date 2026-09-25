import Foundation
import Testing
import TransferCore

struct SFTPURLTests {
    @Test func aLinkReadsUserHostPortAndADecodedPath() throws {
        let link = try #require(SFTPURL(url: URL(string: "sftp://shreeve@live:2222/home/shreeve/My%20Notes/caf%C3%A9.txt")!))
        #expect(link.user == "shreeve")
        #expect(link.host == "live")
        #expect(link.port == "2222")
        #expect(link.path == RemotePath(string: "/home/shreeve/My Notes/café.txt"))
    }

    @Test func aLinkWithNoPathOpensTheStartFolder() throws {
        let link = try #require(SFTPURL(url: URL(string: "sftp://live")!))
        #expect(link.user == nil)
        #expect(link.port == nil)
        #expect(link.path == nil)
    }

    @Test func onlySftpLinksWithAHostAreRead() {
        #expect(SFTPURL(url: URL(string: "https://live/home")!) == nil)
        #expect(SFTPURL(url: URL(string: "sftp:///home")!) == nil)
    }

    /// A user or host ssh could take for an option never reaches the New Connection sheet.
    @Test func aUserOrHostThatLooksLikeAnOptionIsNoLink() {
        #expect(SFTPURL(url: URL(string: "sftp://-oProxyCommand=sh%20-c%20id@example.com/")!) == nil)
        #expect(SFTPURL(url: URL(string: "sftp://-oProxyCommand=id/")!) == nil)
        #expect(SFTPURL(url: URL(string: "sftp://a%20b@example.com/")!) == nil)
        #expect(SFTPURL(url: URL(string: "sftp://me%0A@example.com/")!) == nil)
        #expect(SFTPURL(url: URL(string: "sftp://me-too@my-host/")!)?.user == "me-too")
    }

    @Test func sftpURLOmitsThePassword() {
        let connection = SavedConnection(name: "Box", host: "example.com", user: "ada", port: "22")
        let url = SFTPURL.string(connection: connection, path: RemotePath(string: "/work/a b.txt"))
        #expect(url == "sftp://ada@example.com:22/work/a%20b.txt")
    }

    /// The link that Copy Remote URL writes opens the same place.
    @Test func copyRemoteURLRoundTrips() throws {
        let saved = SavedConnection(name: "Live", host: "live", user: "shreeve")
        let path = RemotePath(string: "/srv/a b/#1?.txt")
        let link = try #require(SFTPURL(url: URL(string: SFTPURL.string(connection: saved, path: path))!))
        #expect(link.path == path)
        #expect(link.host == "live")
        #expect(link.user == "shreeve")
    }

    /// Copy Remote URL once wrote `sftp://u@::1:22/x`, which no URL parser reads (SFC-7).
    @Test func anIPv6HostIsBracketedAndRoundTrips() throws {
        let saved = SavedConnection(name: "Six", host: "::1", user: "ada", port: "2222")
        let text = SFTPURL.string(connection: saved, path: RemotePath(string: "/srv/a b"))
        #expect(text == "sftp://ada@[::1]:2222/srv/a%20b")
        let url = try #require(URL(string: text))
        let link = try #require(SFTPURL(url: url))
        #expect(link.host == "::1")
        #expect(link.port == "2222")
        #expect(link.user == "ada")
        #expect(link.path == RemotePath(string: "/srv/a b"))
        let bare = try #require(URL(string: SFTPURL.string(connection: SavedConnection(name: "Six", host: "fe80::1"), path: RemotePath(string: "/"))))
        #expect(SFTPURL(url: bare)?.host == "fe80::1")
        let zoned = try #require(URL(string: SFTPURL.string(connection: SavedConnection(name: "Six", host: "fe80::1%en0"), path: RemotePath(string: "/"))))
        #expect(SFTPURL(url: zoned)?.host == "fe80::1%en0")
        let bracketed = SavedConnection(name: "Six", host: "[::1]")
        #expect(SFTPURL.string(connection: bracketed, path: RemotePath(string: "/x")) == "sftp://[::1]/x")
    }

    /// A name that is not UTF-8 is written and read back as its exact bytes. It used to be
    /// written as U+FFFD, a different file, and a link to such a path opened the start folder,
    /// since the path would not decode to text (R-C2).
    @Test func aPathThatIsNotUTF8RoundTripsByteForByte() throws {
        let path = RemotePath(bytes: [0x2F, 0x61, 0xFF])
        let text = SFTPURL.string(connection: live, path: path)
        #expect(text == "sftp://live/a%FF")
        #expect(SFTPURL(url: try #require(URL(string: text)))?.path == path)
        #expect(SFTPURL(url: URL(string: "sftp://live/caf%E9/%C3%A9t%C3%A9")!)?.path == RemotePath(bytes: Array("/caf".utf8) + [0xE9] + Array("/été".utf8)))
        let spaced = RemotePath(bytes: Array("/a b/%/".utf8) + [0x80, 0x7E])
        #expect(SFTPURL(url: try #require(URL(string: SFTPURL.string(connection: live, path: spaced))))?.path == spaced)
    }

    /// A host goes into the link escaped, as the path does, and comes back as saved.
    @Test func aHostIsEscapedAndRoundTrips() throws {
        let saved = SavedConnection(name: "Books", host: "bücher.example", user: "ada")
        let text = SFTPURL.string(connection: saved, path: RemotePath(string: "/x"))
        #expect(text == "sftp://ada@b%C3%BCcher.example/x")
        #expect(SFTPURL(url: try #require(URL(string: text)))?.host == "bücher.example")
    }

    /// A NUL in a path reached the wire and ended the channel (SFC-9).
    @Test func aPathWithAControlCharacterIsNoLink() {
        #expect(SFTPURL(url: URL(string: "sftp://live/tmp/a%00b")!) == nil)
        #expect(SFTPURL(url: URL(string: "sftp://live/tmp/a%0Ab")!) == nil)
        #expect(SFTPURL(url: URL(string: "sftp://live/tmp/a%7Fb")!) == nil)
        #expect(SFTPURL(url: URL(string: "sftp://live/tmp/a%C2%85b")!) == nil)
        // Format characters are not controls: emoji sequences join with U+200D.
        #expect(SFTPURL(url: URL(string: "sftp://live/tmp/%F0%9F%91%A9%E2%80%8D%F0%9F%92%BB.txt")!)?.path == RemotePath(string: "/tmp/👩‍💻.txt"))
    }

    private let live = SavedConnection(name: "Live", host: "live")
    private let edi = SavedConnection(name: "EDI", host: "trust")

    private var candidates: [SFTPURL.Match.Candidate] {
        [
            .init(connection: edi, hostName: "136.115.245.56", user: "shreeve", port: "22", addresses: ["136.115.245.56"]),
            .init(connection: live, hostName: "34.22.36.78", user: "shreeve", port: "22", addresses: ["34.22.36.78"]),
        ]
    }

    @Test func theSavedHostWinsThenTheResolvedNameThenTheAddress() {
        #expect(SFTPURL.Match.best(SFTPURL(host: "LIVE"), among: candidates) == live)
        #expect(SFTPURL.Match.best(SFTPURL(host: "136.115.245.56"), among: candidates) == edi)
        let byAddress = [SFTPURL.Match.Candidate(connection: live, hostName: "live.example.com", user: "shreeve", port: "22", addresses: ["34.22.36.78"])]
        #expect(SFTPURL.Match.best(SFTPURL(host: "34.22.36.78"), among: byAddress) == live)
        #expect(SFTPURL.Match.best(SFTPURL(host: "elsewhere"), among: candidates) == nil)
    }

    @Test func aNamedUserOrPortMustBeTheServers() {
        #expect(SFTPURL.Match.best(SFTPURL(user: "shreeve", host: "live"), among: candidates) == live)
        #expect(SFTPURL.Match.best(SFTPURL(user: "root", host: "live"), among: candidates) == nil)
        #expect(SFTPURL.Match.best(SFTPURL(host: "live", port: "2222"), among: candidates) == nil)
    }

    @Test func aCandidateComesFromSSHConfigOutput() throws {
        let output = "user shreeve\nhostname 34.22.36.78\nport 22\nsendenv LANG\nsendenv LC_*\n"
        let candidate = try #require(SFTPURL.Match.Candidate(connection: live, sshConfigOutput: output))
        #expect(candidate.hostName == "34.22.36.78")
        #expect(candidate.user == "shreeve")
        #expect(candidate.port == "22")
        #expect(SSHConfigValues.parse(output)["sendenv"] == "LANG")
    }
}
