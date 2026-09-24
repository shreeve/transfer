import Foundation
import TransferCore
@testable import TransferIO

/// Plays the server end of an `SFTPChannel` in process, over two pipes. Every packet the channel
/// sends reaches `answer`, whose bytes go back, so a test scripts exactly the server it needs: a
/// hostile one, a broken one, or one without an extension. `send` writes raw bytes, for frames no
/// well-formed reply could produce.
final class ScriptedServer: @unchecked Sendable {
    struct Request: Sendable {
        let type: UInt8
        /// The request id; for INIT, the version asked for.
        let id: UInt32
        /// The fields after the id.
        let body: Data

        /// The fields read as a list of strings: the paths of LSTAT, RENAME, REMOVE, and the like.
        var strings: [Data] {
            var reader = ByteReader(body)
            var values: [Data] = []
            while let value = try? reader.blob() { values.append(value) }
            return values
        }

        var paths: [String] { strings.map { String(decoding: $0, as: UTF8.self) } }
    }

    let channel: SFTPChannel
    /// Every request the channel sent, in order.
    let requests = Locked<[Request]>([])
    private let toServer = Pipe()
    private let toChannel = Pipe()
    private let buffer = Locked(Data())

    /// With `extensions`, INIT is answered with a VERSION that lists them and the handshake is done
    /// before this returns. With nil, nothing is answered until the test sends it. After answering a
    /// request of type `stopReadingAfter`, the server reads nothing more, as a hung one, and the
    /// channel's pipe fills.
    init(
        extensions: [String]? = [],
        stopReadingAfter: UInt8? = nil,
        stallLimit: Duration = .seconds(60),
        handshakeLimit: Duration = .seconds(15),
        answer: @escaping @Sendable (Request) -> Data? = { _ in nil }
    ) async throws {
        channel = SFTPChannel(
            process: nil,
            input: toServer.fileHandleForWriting,
            output: toChannel.fileHandleForReading,
            stallLimit: stallLimit,
            handshakeLimit: handshakeLimit
        )
        let replies = toChannel.fileHandleForWriting
        let (buffer, requests) = (buffer, requests)
        toServer.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let packets: [Request] = buffer.withLock { buffer in
                buffer.append(data)
                var packets: [Request] = []
                while let packet = try? SFTPWire.popPacket(from: &buffer) {
                    var reader = ByteReader(packet.rest)
                    let id = (try? reader.u32()) ?? 0
                    packets.append(Request(type: packet.type, id: id, body: Data(packet.rest.dropFirst(4))))
                }
                return packets
            }
            for request in packets {
                requests.withLock { $0.append(request) }
                let reply = request.type == SFTPCode.initialize
                    ? extensions.map(Self.version) : answer(request)
                if let reply { try? replies.write(contentsOf: reply) }
                if request.type == stopReadingAfter {
                    handle.readabilityHandler = nil
                    return
                }
            }
        }
        await channel.start()
        if extensions != nil { try await channel.handshake() }
    }

    /// Writes raw bytes to the channel.
    func send(_ bytes: Data) {
        try? toChannel.fileHandleForWriting.write(contentsOf: bytes)
    }

    /// Ends the server's output, as a server process that exits does.
    func hangUp() {
        try? toChannel.fileHandleForWriting.close()
    }

    /// The requests of one type, in order.
    func sent(_ type: UInt8) -> [Request] {
        requests.value.filter { $0.type == type }
    }

    func stop() async {
        await channel.closeLink()
        toServer.fileHandleForReading.readabilityHandler = nil
        try? toChannel.fileHandleForWriting.close()
        try? toServer.fileHandleForReading.close()
    }

    // MARK: Replies

    static func version(_ extensions: [String]) -> Data {
        frame(SFTPCode.version) { packet in
            packet.appendU32(3)
            for name in extensions {
                packet.appendString(name)
                packet.appendString("1")
            }
        }
    }

    static func status(_ id: UInt32, _ code: UInt32, _ text: String = "") -> Data {
        frame(SFTPCode.status) { packet in
            packet.appendU32(id)
            packet.appendU32(code)
            packet.appendString(text)
            packet.appendString("")
        }
    }

    static func ok(_ id: UInt32) -> Data { status(id, SFTPCode.ok) }

    static func handle(_ id: UInt32, _ handle: String = "h") -> Data {
        frame(SFTPCode.handle) { packet in
            packet.appendU32(id)
            packet.appendString(handle)
        }
    }

    static func attrs(_ id: UInt32, _ attrs: SFTPAttrs = file) -> Data {
        frame(SFTPCode.attrs) { packet in
            packet.appendU32(id)
            packet.append(attrs.encoded())
        }
    }

    static func names(_ id: UInt32, _ names: [[UInt8]], attrs: SFTPAttrs = file) -> Data {
        frame(SFTPCode.name) { packet in
            packet.appendU32(id)
            packet.appendU32(UInt32(names.count))
            for name in names {
                packet.appendBlob(Data(name))
                packet.appendString("")
                packet.append(attrs.encoded())
            }
        }
    }

    static func names(_ id: UInt32, _ names: [String]) -> Data {
        Self.names(id, names.map { Array($0.utf8) })
    }

    static func data(_ id: UInt32, _ bytes: Data) -> Data {
        frame(SFTPCode.data) { packet in
            packet.appendU32(id)
            packet.appendBlob(bytes)
        }
    }

    static var file: SFTPAttrs {
        var attrs = SFTPAttrs()
        attrs.size = 1
        attrs.permissions = 0o100644
        return attrs
    }
}

/// One packet of `type` with the fields `build` appends.
private func frame(_ type: UInt8, _ build: (inout Data) -> Void) -> Data {
    var body = Data()
    build(&body)
    return SFTPWire.packet(type: type, body: body)
}

/// Polls `condition` until it holds or five seconds pass.
func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}
