import Foundation

/// An `sftp://` URL: the server as the link names it, and a path on it. The server may be a saved
/// server's host, an alias from `~/.ssh/config`, a host name, or an address. Parsed from links
/// other apps open, built by Copy Remote URL, and matched to a saved server by `Match`.
public struct SFTPURL: Hashable, Sendable {
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

    /// Nil for anything but an `sftp://` URL with a host. The path is percent-decoded to the exact
    /// bytes, UTF-8 or not. A user or host that ssh could read as an option, or that holds spaces
    /// or control characters, is no link: they come from other apps, and they end up on ssh's
    /// command line. Nor is a path with a control character (a NUL on the wire ends the SFTP
    /// channel) or a broken escape: opening the start folder instead would be the wrong place.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "sftp", let host = url.host(percentEncoded: false),
              Self.isPlainName(host) else { return nil }
        let user = url.user(percentEncoded: false).flatMap { $0.isEmpty ? nil : $0 }
        if let user, !Self.isPlainName(user) { return nil }
        guard let path = Self.decode(url.path(percentEncoded: true)), !Self.hasControl(path) else { return nil }
        self.host = host
        self.user = user
        port = url.port.map(String.init)
        self.path = path.isEmpty ? nil : RemotePath(bytes: path)
    }

    /// The bytes `%XX` escapes stand for; nil for a `%` not followed by two hex digits.
    private static func decode(_ text: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var input = Array(text.utf8)[...]
        while let byte = input.popFirst() {
            guard byte == UInt8(ascii: "%") else {
                bytes.append(byte)
                continue
            }
            guard input.count >= 2, let high = hexValue(input.popFirst()!), let low = hexValue(input.popFirst()!) else { return nil }
            bytes.append(high << 4 | low)
        }
        return bytes
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    /// C0 controls, DEL, and C1 controls as UTF-8 writes them (C2 80 to C2 9F).
    private static func hasControl(_ bytes: [UInt8]) -> Bool {
        bytes.contains { $0 < 0x20 || $0 == 0x7F }
            || zip(bytes, bytes.dropFirst()).contains { $0 == 0xC2 && (0x80...0x9F).contains($1) }
    }

    private static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-")
            && !name.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }

    /// The link to `path` on `connection`, as Copy Remote URL writes it: the path's exact bytes,
    /// escaped, so a name that is not UTF-8 opens the same file. An IPv6 address goes in
    /// brackets, as `xfer` writes it, so the port after it still parses.
    public static func string(connection: SavedConnection, path: RemotePath) -> String {
        var host = connection.host
        if host.contains(":"), !host.hasPrefix("[") {
            host = "[\(host.replacingOccurrences(of: "%", with: "%25"))]"
        } else if !host.hasPrefix("[") {
            host = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? host
        }
        if !connection.port.isEmpty { host += ":\(connection.port)" }
        let user = connection.user.trimmingCharacters(in: .whitespaces)
        let authority = user.isEmpty ? host : "\(percent(Array(user.utf8)))@\(host)"
        let encoded = percent(path.bytes, keeping: "/")
        let suffix = encoded.hasPrefix("/") ? encoded : "/" + encoded
        return "sftp://\(authority)\(suffix)"
    }

    /// `bytes` with every byte but the unreserved characters, the sub-delimiters, and `keeping`
    /// written as `%XX`.
    private static func percent(_ bytes: [UInt8], keeping: String = "") -> String {
        let plain = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=".utf8).union(keeping.utf8)
        return bytes.map { plain.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }

    /// Which saved server an `sftp://` link means.
    public enum Match {
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
        public static func best(_ link: SFTPURL, among candidates: [Candidate]) -> SavedConnection? {
            let host = link.host.lowercased()
            let fitting = candidates.filter { candidate in
                (link.user == nil || link.user == candidate.user) && (link.port == nil || link.port == candidate.port)
            }
            return (fitting.first { $0.connection.host.lowercased() == host }
                ?? fitting.first { $0.hostName.lowercased() == host }
                ?? fitting.first { $0.addresses.contains(host) })?.connection
        }
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
