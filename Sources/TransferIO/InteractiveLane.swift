import Foundation
import TransferCore

/// The file the user is waiting on, one job at a time. Opens and saves run in order, never
/// interrupted: a transfer cancelled partway would only start over. Previews wait behind them and
/// only the latest counts: a newer preview replaces one that waits or runs. No other job interrupts
/// a running preview, or a large one could restart on every autosave and never finish. A job whose
/// caller is cancelled leaves the lane: a waiting one never runs and a running one is cancelled.
actor InteractiveLane {
    /// `preview` is a Quick Look, inspector, or prefetch fetch. `view` is a file the user opened
    /// to view, and `open` a Live file's download the user is waiting to edit: a preview must never
    /// cancel either, or the double-click does nothing. `save` is a Live file's upload.
    enum Kind { case preview, view, open, save }

    /// Touched only on the lane.
    private final class Job: @unchecked Sendable {
        let kind: Kind
        let body: @Sendable () async throws -> Void
        var finish: CheckedContinuation<Void, Error>?

        init(kind: Kind, body: @escaping @Sendable () async throws -> Void) {
            self.kind = kind
            self.body = body
        }

        func end(_ result: Result<Void, Error>) {
            finish.take()?.resume(with: result)
        }
    }

    private var running: (job: Job, task: Task<Void, Never>)?
    private var ordered: [Job] = []
    private var preview: Job?

    /// Whether a job is running, and how many wait: tests order their steps by it.
    var isRunning: Bool { running != nil }
    var waiting: Int { ordered.count + (preview == nil ? 0 : 1) }

    func submit(_ kind: Kind, _ body: @escaping @Sendable () async throws -> Void) async throws {
        try Task.checkCancellation()
        let job = Job(kind: kind, body: body)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.finish = continuation
                enqueue(job)
            }
        } onCancel: {
            Task { await self.cancel(job) }
        }
    }

    private func enqueue(_ job: Job) {
        if job.kind == .preview {
            preview?.end(.failure(TransferError.cancelled))
            preview = job
            if let running, running.job.kind == .preview { running.task.cancel() }
        } else {
            ordered.append(job)
        }
        pump()
    }

    /// A job in no slot has already ended, so `end` does nothing to it.
    private func cancel(_ job: Job) {
        if let running, running.job === job { return running.task.cancel() }
        if preview === job { preview = nil }
        ordered.removeAll { $0 === job }
        job.end(.failure(TransferError.cancelled))
    }

    private func pump() {
        guard running == nil, let job = ordered.isEmpty ? preview.take() : ordered.removeFirst() else { return }
        let task = Task {
            do {
                try await job.body()
                finished(job, .success(()))
            } catch {
                finished(job, .failure(error))
            }
        }
        running = (job, task)
    }

    private func finished(_ job: Job, _ result: Result<Void, Error>) {
        running = nil
        job.end(result)
        pump()
    }
}
