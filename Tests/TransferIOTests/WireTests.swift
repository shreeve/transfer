import Foundation
import Testing
import TransferCore
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

/// A Live open displaced by a preview (the user clicks another file while it downloads) is not
/// dropped: it runs again after the preview and completes.
@Test func aPreviewWaitsForARunningOpen() async throws {
    let lane = InteractiveLane()
    let runs = RunCount()
    let open = Task {
        try await lane.submit(.open) {
            runs.bump()
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    try await lane.submit(.preview) {}
    // The preview ran only after the open finished, which neither restarted nor failed.
    #expect(runs.value == 1)
    try await open.value
}

/// Previews still displace each other: a queued preview is dropped by a newer one.
@Test func aNewerPreviewDropsAQueuedOne() async throws {
    let lane = InteractiveLane()
    let blocker = Task { try await lane.submit(.save) { usleep(200_000) } }
    try await Task.sleep(nanoseconds: 50_000_000)
    let older = Task { try await lane.submit(.preview) {} }
    try await Task.sleep(nanoseconds: 20_000_000)
    try await lane.submit(.preview) {}
    await #expect(throws: TransferError.cancelled) { try await older.value }
    try await blocker.value
}

private final class RunCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
