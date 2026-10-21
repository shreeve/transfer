import AppKit
import SwiftUI
import Testing
import TransferCore
@testable import TransferUI

/// A shelf row's speed and time left: shown while a transfer runs, gone for every other row, new
/// for each attempt, and never moving or growing the row. Time is the model's fake clock; a report
/// still takes the shelf's 100 ms to arrive.
@MainActor @Suite(.serialized)
struct ShelfRateTests {
    let server = SavedConnection(name: "A", host: "a")
    let total: UInt64 = 1_000_000_000

    /// A transfer the test drives: each attempt hands over its progress callback, then waits until
    /// told to end, succeeding or failing.
    final class Drive: Sendable {
        let report = Locked<(@Sendable (TransferProgress) -> Void)?>(nil)
        let attempts = Locked(0)
        let ends = Locked(false)
        let fails = Locked(false)
    }

    func connected(_ time: Locked<Double>) async -> (TransferModel, FakeSession) {
        let session = FakeSession(server)
        let model = TransferModel(provider: FakeProvider([session]))
        await model.connect(server)
        model.clock = { time.value }
        return (model, session)
    }

    func run(_ model: TransferModel, _ drive: Drive) async {
        model.enqueue(title: "Download big.iso", path: RemotePath(string: "/home/big.iso")) { _, progress in
            drive.report.value = progress
            drive.attempts.withLock { $0 += 1 }
            while !drive.ends.value { try await Task.sleep(for: .milliseconds(5)) }
            if drive.fails.value { throw TransferError.permissionDenied("big.iso") }
        }
        _ = await eventually { drive.attempts.value == 1 }
    }

    /// Reports `bytes` done at `at` seconds and waits for the shelf to hear it.
    func report(_ model: TransferModel, _ drive: Drive, _ time: Locked<Double>, at: Double, _ bytes: UInt64) async {
        time.value = at
        drive.report.value?(TransferProgress(completed: bytes, total: total))
        #expect(await eventually { model.operations.first?.progress.completed == bytes })
    }

    @Test func aRunningRowShowsItsSpeedAndTimeLeftAndAFinishedRowNeither() async throws {
        let time = Locked(0.0)
        let (model, _) = await connected(time)
        let drive = Drive()
        await run(model, drive)
        await report(model, drive, time, at: 0, 10_000_000)
        await report(model, drive, time, at: 1, 20_000_000)
        var operation = try #require(model.operations.first)
        #expect(model.rateText(for: operation) == nil)
        await report(model, drive, time, at: 3, 40_000_000)
        operation = try #require(model.operations.first)
        #expect(model.rateText(for: operation) == "10 MB/s · about 2 minutes left")
        // The inspector says what the shelf says.
        #expect(model.inspectorStatus(operation) == "10 MB/s · about 2 minutes left")

        // Five seconds with no byte: no estimate of days, and the inspector agrees.
        time.value = 8
        #expect(model.rateText(for: operation) == "Stalled")
        #expect(model.inspectorStatus(operation) == "Stalled")

        // Stopped, it shows neither; restarted, it starts again from nothing.
        await model.pause(operation)
        operation = try #require(model.operations.first)
        #expect(model.rateText(for: operation) == nil)
        #expect(model.inspectorStatus(operation) == "Stopped")
        await model.resume(operation)
        #expect(await eventually { drive.attempts.value == 2 })
        operation = try #require(model.operations.first)
        #expect(operation.state == .active)
        #expect(model.rateText(for: operation) == nil)
        await report(model, drive, time, at: 8.1, 5_000_000)
        await report(model, drive, time, at: 10.1, 25_000_000)
        operation = try #require(model.operations.first)
        #expect(model.rateText(for: operation) == "10 MB/s · about 2 minutes left")

        // Finished, the row goes, and with it its rate.
        drive.ends.value = true
        #expect(await eventually { model.operations.isEmpty })
        #expect(model.rateText(for: operation) == nil)
    }

    @Test func aFailedRowAndALiveRowShowNeither() async throws {
        let time = Locked(0.0)
        let (model, session) = await connected(time)
        let drive = Drive()
        await run(model, drive)
        await report(model, drive, time, at: 0, 10_000_000)
        await report(model, drive, time, at: 3, 40_000_000)
        #expect(model.rateText(for: try #require(model.operations.first)) != nil)
        drive.fails.value = true
        drive.ends.value = true
        #expect(await eventually { model.operations.first?.state == .failed })
        let failed = try #require(model.operations.first)
        #expect(model.rateText(for: failed) == nil)
        #expect(model.stateLabel(failed) == "Failed")

        let live = TransferOperation(id: "live", title: "Uploading notes.md", state: .active,
                                     progress: TransferProgress(completed: 1_000, total: 2_000), livePath: RemotePath(string: "/home/notes.md"))
        session.send.yield(.operation(live))
        #expect(await eventually { model.operations.contains { $0.id == "live" } })
        time.value = 10
        #expect(model.rateText(for: live) == nil)
        #expect(model.inspectorStatus(live) == "Active")
    }

    /// The row is as tall with its rate as without it, and the rate's slot as wide whatever it
    /// reads, so the shelf never moves as the numbers change.
    @Test func theRateNeverMovesOrGrowsTheRow() async throws {
        let time = Locked(0.0)
        let (model, _) = await connected(time)
        let drive = Drive()
        await run(model, drive)
        let id = try #require(model.operations.first?.id)
        let slots = InspectorSlots()
        _ = NSApplication.shared
        let window = OffscreenWindow(contentRect: NSRect(x: -5000, y: -5000, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: DetailColumn(model: model).environment(\.detailSlots, slots).frame(width: 800, height: 500))
        window.orderFrontRegardless()
        defer { window.close() }

        func frames() async -> (row: CGRect, rate: CGRect)? {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
            guard let row = slots.frames["shelfRow \(id)"], let rate = slots.frames["shelfRate \(id)"] else { return nil }
            return (row, rate)
        }
        // The first report brings the total, and with it the progress bar.
        await report(model, drive, time, at: 0, 10_000_000)
        #expect(await eventually { slots.frames["shelfRate \(id)"].map { $0.width > 0 } ?? false })
        let empty = try #require(await frames())
        #expect(model.rateText(for: try #require(model.operations.first)) == nil)
        await report(model, drive, time, at: 3, 40_000_000)
        #expect(model.rateText(for: try #require(model.operations.first)) == "10 MB/s · about 2 minutes left")
        let reading = try #require(await frames())
        time.value = 8.5
        let stalled = try #require(await frames())
        for shown in [reading, stalled] {
            #expect(shown.row == empty.row)
            #expect(shown.rate == empty.rate)
        }
        // The slot is no taller than the row's own title line needs.
        #expect(empty.rate.height < empty.row.height)
        drive.ends.value = true
        #expect(await eventually { model.operations.isEmpty })
    }
}
