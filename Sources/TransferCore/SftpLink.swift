import Foundation

/// Where an `sftp://` link points: the server as the link names it, and a path on it. The server
/// may be a saved server's host, an alias from `~/.ssh/config`, a host name, or an address.
public struct SftpLink: Hashable, Sendable {
    public var user: String?
    public var host: String
    public var port: String?
    /// Nil opens the server's start folder.
    public var path: RemotePath?

    public init(user: String? = nil, host: String, port: String? = nil, path: RemotePath? = nil) {
        self.user = user
        self.host = host
        self.port = port
        self.path = path
    }

    /// Nil for anything but an `sftp://` URL with a host. The path is percent-decoded.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "sftp", let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        self.host = host
        user = url.user(percentEncoded: false).flatMap { $0.isEmpty ? nil : $0 }
        port = url.port.map(String.init)
        let path = url.path(percentEncoded: false)
        self.path = path.isEmpty ? nil : RemotePath(string: path)
    }
}

/// Which saved server an `sftp://` link means.
public enum SftpLinkMatch {
    /// A saved server as ssh resolves it: `ssh -G` for its destination, and the addresses its
    /// host name resolves to.
    public struct Candidate: Sendable {
        public var connection: SavedConnection
        public var hostName: String
        public var user: String
        public var port: String
        public var addresses: Set<String>

        public init(connection: SavedConnection, hostName: String, user: String, port: String, addresses: Set<String> = []) {
            self.connection = connection
            self.hostName = hostName
            self.user = user
            self.port = port
            self.addresses = addresses
        }

        /// From `ssh -G` output; nil when it names no host name.
        public init?(connection: SavedConnection, sshConfigOutput: String, addresses: Set<String> = []) {
            let values = SSHConfigValues.parse(sshConfigOutput)
            guard let hostName = values["hostname"] else { return nil }
            self.init(connection: connection, hostName: hostName, user: values["user"] ?? "", port: values["port"] ?? "22", addresses: addresses)
        }
    }

    /// The link's user and port, when it names them, must be the server's. Of those servers, the
    /// one whose saved host is the link's host wins, then one whose resolved host name is, then
    /// one whose address is.
    public static func best(_ link: SftpLink, among candidates: [Candidate]) -> SavedConnection? {
        let host = link.host.lowercased()
        let fitting = candidates.filter { candidate in
            (link.user == nil || link.user == candidate.user) && (link.port == nil || link.port == candidate.port)
        }
        return (fitting.first { $0.connection.host.lowercased() == host }
            ?? fitting.first { $0.hostName.lowercased() == host }
            ?? fitting.first { $0.addresses.contains(host) })?.connection
    }
}

public enum SSHConfigValues {
    /// `ssh -G` output as lowercase keys and the first value of each.
    public static func parse(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            if values[key] == nil { values[key] = String(parts[1]) }
        }
        return values
    }
}
