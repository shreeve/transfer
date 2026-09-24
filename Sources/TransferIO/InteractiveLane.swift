import Foundation
import TransferCore

/// The file the user is waiting on, one job at a time. Live opens and saves run in order and are
/// never interrupted: a download or upload cancelled partway would only start over. Previews wait
/// behind them, and only the latest preview counts: a newer one replaces a preview that waits or
/// runs. A running preview is never interrupted by a Live job, which could otherwise restart a
/// large view download on every autosave and never let it finish. A job whose caller is
/// cancelled leaves the lane: a waiting one never runs and a running one is cancelled.
actor InteractiveLane {
    /// `preview` is a Quick Look or inspector fetch. `open` is a Live file's download, which the
    /// user is waiting to edit. `save` is a Live file's upload.
    enum Kind { case preview, open, save }

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
            finish?.resume(with: result)
            finish = nil
        }
    }

    private var running: (job: Job, task: Task<Void, Never>)?
    private var live: [Job] = []
    private var preview: Job?

    /// Whether a job is running, and how many wait: tests order their steps by it.
    var isRunning: Bool { running != nil }
    var waiting: Int { live.count + (preview == nil ? 0 : 1) }

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
            live.append(job)
        }
        pump()
    }

    private func cancel(_ job: Job) {
        if let running, running.job === job {
            running.task.cancel()
        } else if preview === job {
            preview = nil
            job.end(.failure(TransferError.cancelled))
        } else if let index = live.firstIndex(where: { $0 === job }) {
            live.remove(at: index)
            job.end(.failure(TransferError.cancelled))
        }
    }

    private func pump() {
        guard running == nil else { return }
        let job: Job
        if !live.isEmpty {
            job = live.removeFirst()
        } else if let waiting = preview {
            preview = nil
            job = waiting
        } else {
            return
        }
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
