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
    let runs = Locked(0)
    let save = Task {
        try await lane.submit(.save) {
            runs.withLock { $0 += 1 }
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
    let runs = Locked(0)
    let open = Task {
        try await lane.submit(.open) {
            runs.withLock { $0 += 1 }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    try await lane.submit(.preview) {}
    // The preview ran only after the open finished, which neither restarted nor failed.
    #expect(runs.value == 1)
    try await open.value
}

/// Previews still displace each other: a queued preview is dropped by a newer one. Each step
/// waits for the lane to reach the state it needs; fixed sleeps lost that race under load.
@Test func aNewerPreviewDropsAQueuedOne() async throws {
    let lane = InteractiveLane()
    let gate = Gate()
    let blocker = Task { try await lane.submit(.save) { await gate.wait() } }
    #expect(await eventually { await lane.isRunning })
    let older = Task { try await lane.submit(.preview) {} }
    #expect(await eventually { await lane.waiting == 1 })
    let newer = Task { try await lane.submit(.preview) {} }
    await #expect(throws: TransferError.cancelled) { try await older.value }
    #expect(await lane.waiting == 1)
    await gate.open()
    try await blocker.value
    try await newer.value
}

/// Polls `condition` until it holds or five seconds pass.
private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

/// Holds a job running until the test opens it.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
