import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// The server is untrusted input: a frame no SFTP server sends, text before VERSION, or a server
/// that stops answering or reading must fail the channel promptly and clearly, never wedge it or
/// buffer without bound.
@Suite struct FrameTests {
    private static let path = RemotePath(string: "/srv/a")

    /// A server that answers every LSTAT with `reply(id)`.
    private static func answering(
        stallLimit: Duration = .seconds(60),
        _ reply: @escaping @Sendable (UInt32) -> Data?
    ) async throws -> ScriptedServer {
        try await ScriptedServer(stallLimit: stallLimit) { request in
            request.type == SFTPCode.lstat ? reply(request.id) : nil
        }
    }

    private static func length(_ value: UInt32) -> Data {
        var data = Data()
        data.appendU32(value)
        return data
    }

    // MARK: Frames

    @Test func popPacketWaitsForAWholePacket() throws {
        let packet = SFTPWire.packet(type: SFTPCode.status, body: Data([0, 0, 0, 7]))
        var buffer = packet.prefix(6)
        #expect(try SFTPWire.popPacket(from: &buffer) == nil)
        buffer.append(packet.dropFirst(6))
        let message = try SFTPWire.popPacket(from: &buffer)
        #expect(message?.type == SFTPCode.status)
        #expect(message?.rest == Data([0, 0, 0, 7]))
        #expect(buffer.isEmpty)
    }

    @Test func popPacketRefusesZeroAndOversizedLengths() {
        var zero = Self.length(0)
        #expect(throws: SFTPWire.BadFrame.self) { try SFTPWire.popPacket(from: &zero) }
        var oversized = Self.length(UInt32(SFTPWire.maxPacket + 1))
        #expect(throws: SFTPWire.BadFrame.self) { try SFTPWire.popPacket(from: &oversized) }
        // The longest allowed length only waits for its bytes.
        var longest = Self.length(UInt32(SFTPWire.maxPacket))
        #expect(throws: Never.self) { try SFTPWire.popPacket(from: &longest) }
    }

    /// A zero-length frame used to be left unconsumed, so the reader stalled and every request
    /// on the channel hung.
    @Test func aZeroLengthFrameClosesTheChannel() async throws {
        let server = try await Self.answering { _ in Self.length(0) }
        await #expect(throws: TransferError.connectionLost("The server sent a malformed SFTP packet")) {
            _ = try await server.channel.lstat(Self.path)
        }
        #expect(await !server.channel.isOpen)
        await #expect(throws: TransferError.connectionLost("SSH channel closed")) {
            _ = try await server.channel.lstat(Self.path)
        }
        await server.stop()
    }

    /// A claimed 4 GB packet fails at its length, not after buffering what the server dribbles.
    @Test func anOversizedLengthFailsAtOnce() async throws {
        let server = try await Self.answering { _ in Self.length(.max) + Data(repeating: 0, count: 100) }
        await #expect(throws: TransferError.connectionLost("The server sent a malformed SFTP packet")) {
            _ = try await server.channel.lstat(Self.path)
        }
        await server.stop()
    }

    @Test func aReplyTooShortForItsIDClosesTheChannel() async throws {
        let server = try await Self.answering { _ in Self.length(2) + Data([SFTPCode.status, 0]) }
        await #expect(throws: TransferError.connectionLost("The server sent a malformed SFTP packet")) {
            _ = try await server.channel.lstat(Self.path)
        }
        await server.stop()
    }

    /// A reply to a request nobody waits for (one that was cancelled) is dropped; the channel
    /// carries on.
    @Test func aReplyNobodyWaitsForIsDropped() async throws {
        let server = try await Self.answering { id in ScriptedServer.ok(id + 100) + ScriptedServer.attrs(id) }
        let item = try await server.channel.lstat(Self.path)
        #expect(item.kind == .file)
        #expect(await server.channel.isOpen)
        await server.stop()
    }

    @Test func truncatedAttributesAreAnError() throws {
        var attrs = SFTPAttrs()
        attrs.size = 1
        attrs.permissions = 0o100644
        var reader = ByteReader(attrs.encoded().dropLast(2))
        #expect(throws: TransferError.failed("Short SFTP packet")) { try reader.attrs() }
        // An extended-attribute count far past the packet's end stops at the end.
        var extended = Data()
        extended.appendU32(0x8000_0000)
        extended.appendU32(.max)
        var long = ByteReader(extended)
        #expect(throws: TransferError.failed("Short SFTP packet")) { try long.attrs() }
    }

    // MARK: Handshake

    /// A shell startup file that prints (`echo Welcome` in .bashrc) puts text before VERSION. It
    /// used to read as a 1.4 GB length and hang the login; now it fails with the text.
    @Test func textBeforeVersionFailsTheHandshakeAndShowsIt() async throws {
        for banner in ["Welcome to the build host\r\n", "hi\n"] {
            let server = try await ScriptedServer(extensions: nil)
            let handshake = Task { try await server.channel.handshake() }
            #expect(await eventually { !server.sent(SFTPCode.initialize).isEmpty })
            server.send(Data(banner.utf8) + ScriptedServer.version([]))
            let error = await #expect(throws: TransferError.self) { try await handshake.value }
            let text = banner.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(error == .failed("The server printed “\(text)” before SFTP started. Remove that output from the shell startup files on the server, such as .bashrc."))
            await server.stop()
        }
    }

    @Test func aFirstPacketThatIsNotVersionFailsTheHandshake() async throws {
        let server = try await ScriptedServer(extensions: nil)
        let handshake = Task { try await server.channel.handshake() }
        #expect(await eventually { !server.sent(SFTPCode.initialize).isEmpty })
        server.send(ScriptedServer.ok(0))
        await #expect(throws: TransferError.failed("The server did not answer in SFTP")) { try await handshake.value }
        await server.stop()
    }

    @Test func aHandshakeWithNoAnswerTimesOut() async throws {
        let server = try await ScriptedServer(extensions: nil, handshakeLimit: .milliseconds(200))
        let started = ContinuousClock.now
        await #expect(throws: TransferError.timeout("The server did not start SFTP")) {
            try await server.channel.handshake()
        }
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(await !server.channel.isOpen)
        await server.stop()
    }

    @Test func cancellingAHandshakeClosesTheChannel() async throws {
        let server = try await ScriptedServer(extensions: nil)
        let handshake = Task { try await server.channel.handshake() }
        #expect(await eventually { !server.sent(SFTPCode.initialize).isEmpty })
        handshake.cancel()
        await #expect(throws: TransferError.cancelled) { try await handshake.value }
        #expect(await !server.channel.isOpen)
        await server.stop()
    }

    // MARK: Stalls

    @Test func aServerThatStopsAnsweringTimesOut() async throws {
        let server = try await Self.answering(stallLimit: .milliseconds(200)) { _ in nil }
        await #expect(throws: TransferError.timeout("The server stopped answering")) {
            _ = try await server.channel.lstat(Self.path)
        }
        #expect(await !server.channel.isOpen)
        await server.stop()
    }

    /// copy-data answers only when the whole file is written, so its silence is not a stall.
    @Test func copyDataMayOutlastTheStallLimit() async throws {
        let server = try await ScriptedServer(stallLimit: .milliseconds(200)) { request in
            switch request.type {
            case SFTPCode.open: ScriptedServer.handle(request.id)
            case SFTPCode.close: ScriptedServer.ok(request.id)
            default: nil
            }
        }
        let copy = Task { try await server.channel.copyData(Self.path, to: RemotePath(string: "/srv/b")) }
        #expect(await eventually { !server.sent(SFTPCode.extended).isEmpty })
        try await Task.sleep(for: .seconds(1))
        server.send(ScriptedServer.ok(server.sent(SFTPCode.extended)[0].id))
        try await copy.value
        #expect(await eventually { server.sent(SFTPCode.close).count == 2 })
        await server.stop()
    }

    /// A server that stops reading fills ssh's stdin pipe. The writes wait on the channel's own
    /// queue, so the actor still runs: the stall is seen and the upload fails instead of hanging.
    @Test func aServerThatStopsReadingDoesNotHoldTheChannel() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("frame-\(UUID().uuidString)")
        try Data(repeating: 7, count: 4 << 20).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = try await ScriptedServer(stopReadingAfter: SFTPCode.open, stallLimit: .milliseconds(300)) { request in
            request.type == SFTPCode.open ? ScriptedServer.handle(request.id) : nil
        }
        await #expect(throws: TransferError.timeout("The server stopped answering")) {
            try await server.channel.upload(file, to: Self.path) { _ in }
        }
        await server.stop()
    }
}
