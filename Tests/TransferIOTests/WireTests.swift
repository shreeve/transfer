import Foundation
import Testing
@testable import TransferIO

@Test func initPacketIsVersionThree() {
    var body = Data()
    body.appendU32(3)
    let packet = SFTPWire.packet(type: SFTPCode.initialize, body: body)
    #expect(Array(packet) == [0, 0, 0, 5, 1, 0, 0, 0, 3])
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
