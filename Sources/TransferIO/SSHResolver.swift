import Darwin
import Foundation
import TransferCore

/// What ssh makes of a saved server without logging in: `ssh -G`, and its host name's addresses.
enum SSHResolver {
    /// `ssh -G` for the server's destination and port, or nil when ssh fails or takes over 5 s.
    /// `configFile` replaces `~/.ssh/config`, as a connection's `sshConfigFile` does.
    static func config(for connection: SavedConnection, configFile: String? = nil) async -> String? {
        var arguments = configFile.map { ["-F", $0] } ?? []
        arguments.append("-G")
        if !connection.port.isEmpty { arguments += ["-p", connection.port] }
        arguments += ["--", connection.destination]
        guard let result = try? await Subprocess.run("/usr/bin/ssh", arguments, timeout: .seconds(5)), result.status == 0 else { return nil }
        return result.stdout
    }

    /// True for an IPv4 or IPv6 literal.
    static func isAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    /// The numeric addresses `host` resolves to; itself when it is one. `getaddrinfo` blocks for as
    /// long as DNS takes, so it runs on a Dispatch thread, never on Swift's cooperative pool.
    static func addresses(of host: String) async -> Set<String> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: resolve(host)) }
        }
    }

    private static func resolve(_ host: String) -> Set<String> {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0 else { return [] }
        defer { freeaddrinfo(list) }
        var found: Set<String> = []
        var next = list
        while let info = next?.pointee {
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.ai_addr, info.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                found.insert(String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            next = info.ai_next
        }
        return found
    }
}
