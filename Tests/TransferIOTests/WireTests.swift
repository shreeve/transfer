import Foundation
import Testing
import TransferCore
@testable import TransferIO

@Test func initPacketIsVersionThree() {
    let packet = SFTPWire.packet(type: SFTPCode.initialize) { $0.appendU32(3) }
    #expect(Array(packet) == [0, 0, 0, 5, 1, 0, 0, 0, 3])
}

/// The length counts the type and every field, and is right whatever capacity was guessed.
@Test func aPacketsLengthCoversItsFields() {
    let payload = Data(repeating: 0xAB, count: 70_000)
    for capacity in [0, 64, 70_100] {
        let packet = SFTPWire.packet(type: SFTPCode.write, capacity: capacity) {
            $0.appendU32(9)
            $0.appendPath(RemotePath(string: "/a b"))
            $0.appendBlob(payload)
        }
        #expect(packet.prefix(4).loadU32() == UInt32(packet.count - 4))
        #expect(packet[4] == SFTPCode.write)
        #expect(Array(packet[5..<17]) == [0, 0, 0, 9, 0, 0, 0, 4, 0x2F, 0x61, 0x20, 0x62])
        #expect(packet.suffix(payload.count) == payload)
    }
}

@Test func attributesRoundTripSizeAndTime() throws {
    var attrs = SFTPAttrs()
    attrs.size = 99
    attrs.permissions = 0o100644
    attrs.atime = 10
    attrs.mtime = 20
    var reader = ByteReader(attrs.encoded())
    let decoded = try reader.attrs()
    #expect(decoded.size == 99)
    #expect(decoded.mtime == 20)
    #expect(decoded.kind == .file)
}
