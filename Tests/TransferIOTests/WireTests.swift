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

/// A save that completes while a preview displaces it must not run again: a second run would
/// upload twice and, for a Live file, meet its own bytes on the server.
@Test func finishedSaveIsNotRunAgainWhenDisplaced() async throws {
    let lane = InteractiveLane()
    let runs = RunCount()
    let save = Task {
        try await lane.submit(.save) {
            runs.bump()
            // Uninterruptible work, so the save finishes even though it is cancelled mid-way.
            usleep(200_000)
        }
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    try await lane.submit(.preview) {}
    try await save.value
    #expect(runs.value == 1)
}

private final class RunCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
