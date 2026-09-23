import Darwin
import Foundation
import TransferCore

/// What ssh makes of a saved server without logging in: `ssh -G`, and its host name's addresses.
enum SSHResolver {
    /// `ssh -G` for the server's destination and port, or nil when ssh fails or takes over 5 s.
    static func config(for connection: SavedConnection) async -> String? {
        var arguments = ["-G"]
        if !connection.port.isEmpty { arguments += ["-p", connection.port] }
        arguments.append(connection.destination)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let text: String? = await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
        }
        return text
    }

    /// True for an IPv4 or IPv6 literal.
    static func isAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    /// The numeric addresses `host` resolves to; itself when it is one.
    static func addresses(of host: String) -> Set<String> {
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
