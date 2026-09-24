import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// InteractiveLane's order. Each step waits for the lane to reach the state it needs, and jobs are
/// held open by a `Gate`: fixed sleeps lost those races under load.
@Suite struct LaneTests {
    /// A save that a preview arrives behind must not be cancelled, or run again: a second run
    /// would upload twice and, for a Live file, meet its own bytes on the server.
    @Test func aPreviewNeitherInterruptsNorRepeatsASave() async throws {
        let lane = InteractiveLane()
        let gate = Gate()
        let runs = Locked(0)
        let cancelled = Locked(false)
        let save = Task {
            try await lane.submit(.save) {
                runs.withLock { $0 += 1 }
                await gate.wait()
                cancelled.value = Task.isCancelled
            }
        }
        #expect(await eventually { await lane.isRunning })
        let preview = Task { try await lane.submit(.preview) {} }
        #expect(await eventually { await lane.waiting == 1 })
        await gate.open()
        try await save.value
        try await preview.value
        #expect(runs.value == 1)
        #expect(!cancelled.value)
    }

    /// A Live open that a preview arrives behind (the user clicks another file while it downloads)
    /// runs to the end first; the preview runs after it.
    @Test func aPreviewWaitsForARunningOpen() async throws {
        let lane = InteractiveLane()
        let gate = Gate()
        let order = Locked<[String]>([])
        let open = Task {
            try await lane.submit(.open) {
                await gate.wait()
                order.withLock { $0.append("open") }
            }
        }
        #expect(await eventually { await lane.isRunning })
        let preview = Task { try await lane.submit(.preview) { order.withLock { $0.append("preview") } } }
        #expect(await eventually { await lane.waiting == 1 })
        await gate.open()
        try await open.value
        try await preview.value
        #expect(order.value == ["open", "preview"])
    }

    /// A running preview is not interrupted by a Live save, which waits for it: interrupting would
    /// restart a large view download on every autosave.
    @Test func aSaveWaitsForARunningPreview() async throws {
        let lane = InteractiveLane()
        let gate = Gate()
        let order = Locked<[String]>([])
        let preview = Task {
            try await lane.submit(.preview) {
                await gate.wait()
                order.withLock { $0.append(Task.isCancelled ? "preview cancelled" : "preview") }
            }
        }
        #expect(await eventually { await lane.isRunning })
        let save = Task { try await lane.submit(.save) { order.withLock { $0.append("save") } } }
        #expect(await eventually { await lane.waiting == 1 })
        await gate.open()
        try await preview.value
        try await save.value
        #expect(order.value == ["preview", "save"])
    }

    /// Live jobs waiting together run in the order they came, ahead of a preview that came first.
    @Test func liveJobsRunInOrderAheadOfAWaitingPreview() async throws {
        let lane = InteractiveLane()
        let gate = Gate()
        let order = Locked<[String]>([])
        let blocker = Task { try await lane.submit(.save) { await gate.wait() } }
        #expect(await eventually { await lane.isRunning })
        var jobs: [Task<Void, Error>] = []
        for (kind, name) in [(InteractiveLane.Kind.preview, "preview"), (.save, "save"), (.open, "open")] {
            let count = jobs.count
            jobs.append(Task { try await lane.submit(kind) { order.withLock { $0.append(name) } } })
            #expect(await eventually { await lane.waiting == count + 1 })
        }
        await gate.open()
        try await blocker.value
        for job in jobs { try await job.value }
        #expect(order.value == ["save", "open", "preview"])
    }

    /// Previews still displace each other: a waiting preview is dropped by a newer one.
    @Test func aNewerPreviewDropsAWaitingOne() async throws {
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

    /// ...and a running preview is cancelled by a newer one.
    @Test func aNewerPreviewCancelsARunningOne() async throws {
        let lane = InteractiveLane()
        let older = Task {
            try await lane.submit(.preview) { try await Task.sleep(for: .seconds(30)) }
        }
        #expect(await eventually { await lane.isRunning })
        let newer = Task { try await lane.submit(.preview) {} }
        await #expect(throws: CancellationError.self) { try await older.value }
        try await newer.value
    }

    /// SES-34: a caller that gives up takes its waiting job off the lane; it never runs.
    @Test func aCancelledCallersWaitingJobNeverRuns() async throws {
        let lane = InteractiveLane()
        let gate = Gate()
        let ran = Locked(false)
        let blocker = Task { try await lane.submit(.save) { await gate.wait() } }
        #expect(await eventually { await lane.isRunning })
        let open = Task { try await lane.submit(.open) { ran.value = true } }
        #expect(await eventually { await lane.waiting == 1 })
        open.cancel()
        await #expect(throws: TransferError.cancelled) { try await open.value }
        #expect(await lane.waiting == 0)
        await gate.open()
        try await blocker.value
        #expect(!ran.value)
    }

    /// A caller that gives up on a running job cancels it.
    @Test func aCancelledCallersRunningJobIsCancelled() async throws {
        let lane = InteractiveLane()
        let save = Task {
            try await lane.submit(.save) { try await Task.sleep(for: .seconds(30)) }
        }
        #expect(await eventually { await lane.isRunning })
        save.cancel()
        await #expect(throws: CancellationError.self) { try await save.value }
        #expect(await eventually { await !lane.isRunning })
    }
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
