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

/// Every field round-trips, in the draft's order; the owner and the times go only as pairs.
@Test func attributesRoundTrip() throws {
    let attrs = SFTPAttrs(size: 99, uid: 501, gid: 20, permissions: 0o100644, atime: 10, mtime: 20)
    var reader = ByteReader(attrs.encoded())
    #expect(try reader.attrs() == attrs)
    #expect(Array(attrs.encoded().prefix(4)) == [0, 0, 0, 0x0F])
    #expect(SFTPAttrs(uid: 501, mtime: 20).encoded() == Data([0, 0, 0, 0]))
    #expect(attrs.kind == .file)
}
