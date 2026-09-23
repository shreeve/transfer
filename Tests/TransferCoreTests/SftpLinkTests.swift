import Foundation
import Testing
import TransferCore

struct SftpLinkTests {
    @Test func aLinkReadsUserHostPortAndADecodedPath() throws {
        let link = try #require(SftpLink(url: URL(string: "sftp://shreeve@live:2222/home/shreeve/My%20Notes/caf%C3%A9.txt")!))
        #expect(link.user == "shreeve")
        #expect(link.host == "live")
        #expect(link.port == "2222")
        #expect(link.path == RemotePath(string: "/home/shreeve/My Notes/café.txt"))
    }

    @Test func aLinkWithNoPathOpensTheStartFolder() throws {
        let link = try #require(SftpLink(url: URL(string: "sftp://live")!))
        #expect(link.user == nil)
        #expect(link.port == nil)
        #expect(link.path == nil)
    }

    @Test func onlySftpLinksWithAHostAreRead() {
        #expect(SftpLink(url: URL(string: "https://live/home")!) == nil)
        #expect(SftpLink(url: URL(string: "sftp:///home")!) == nil)
    }

    /// The link that Copy Remote URL writes opens the same place.
    @Test func copyRemoteURLRoundTrips() throws {
        let saved = SavedConnection(name: "Live", host: "live", user: "shreeve")
        let path = RemotePath(string: "/srv/a b/#1?.txt")
        let link = try #require(SftpLink(url: URL(string: SftpURL.string(connection: saved, path: path))!))
        #expect(link.path == path)
        #expect(link.host == "live")
        #expect(link.user == "shreeve")
    }

    private let live = SavedConnection(name: "Live", host: "live")
    private let edi = SavedConnection(name: "EDI", host: "trust")

    private var candidates: [SftpLinkMatch.Candidate] {
        [
            .init(connection: edi, hostName: "136.115.245.56", user: "shreeve", port: "22", addresses: ["136.115.245.56"]),
            .init(connection: live, hostName: "34.22.36.78", user: "shreeve", port: "22", addresses: ["34.22.36.78"]),
        ]
    }

    @Test func theSavedHostWinsThenTheResolvedNameThenTheAddress() {
        #expect(SftpLinkMatch.best(SftpLink(host: "LIVE"), among: candidates) == live)
        #expect(SftpLinkMatch.best(SftpLink(host: "136.115.245.56"), among: candidates) == edi)
        let byAddress = [SftpLinkMatch.Candidate(connection: live, hostName: "live.example.com", user: "shreeve", port: "22", addresses: ["34.22.36.78"])]
        #expect(SftpLinkMatch.best(SftpLink(host: "34.22.36.78"), among: byAddress) == live)
        #expect(SftpLinkMatch.best(SftpLink(host: "elsewhere"), among: candidates) == nil)
    }

    @Test func aNamedUserOrPortMustBeTheServers() {
        #expect(SftpLinkMatch.best(SftpLink(user: "shreeve", host: "live"), among: candidates) == live)
        #expect(SftpLinkMatch.best(SftpLink(user: "root", host: "live"), among: candidates) == nil)
        #expect(SftpLinkMatch.best(SftpLink(host: "live", port: "2222"), among: candidates) == nil)
    }

    @Test func aCandidateComesFromSSHConfigOutput() throws {
        let output = "user shreeve\nhostname 34.22.36.78\nport 22\nsendenv LANG\nsendenv LC_*\n"
        let candidate = try #require(SftpLinkMatch.Candidate(connection: live, sshConfigOutput: output))
        #expect(candidate.hostName == "34.22.36.78")
        #expect(candidate.user == "shreeve")
        #expect(candidate.port == "22")
        #expect(SSHConfigValues.parse(output)["sendenv"] == "LANG")
    }
}
