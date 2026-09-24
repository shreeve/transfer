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
