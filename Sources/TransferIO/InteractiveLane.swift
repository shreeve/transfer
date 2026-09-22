import Foundation
import TransferCore

/// The one file the user is waiting on. A new preview, view, open, or save cancels the running job.
/// A displaced preview is dropped. A displaced save stays pending and runs next.
actor InteractiveLane {
    enum Kind { case preview, save }

    private final class Job: @unchecked Sendable {
        let kind: Kind
        let body: @Sendable () async throws -> Void
        let finish: CheckedContinuation<Void, Error>
        var preempted = false

        init(kind: Kind, body: @escaping @Sendable () async throws -> Void, finish: CheckedContinuation<Void, Error>) {
            self.kind = kind
            self.body = body
            self.finish = finish
        }
    }

    private var running: (job: Job, task: Task<Void, Never>)?
    private var queue: [Job] = []

    func submit(_ kind: Kind, _ body: @escaping @Sendable () async throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueue(Job(kind: kind, body: body, finish: continuation))
        }
    }

    private func enqueue(_ job: Job) {
        if job.kind == .preview {
            for old in queue where old.kind == .preview {
                old.finish.resume(throwing: TransferError.cancelled)
            }
            queue.removeAll { $0.kind == .preview }
        }
        queue.insert(job, at: 0)
        if let running {
            running.job.preempted = true
            running.task.cancel()
        } else {
            pump()
        }
    }

    private func pump() {
        guard running == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        let task = Task { [weak self] in
            do {
                try await job.body()
                await self?.finished(job, error: nil)
            } catch {
                await self?.finished(job, error: error)
            }
        }
        running = (job, task)
    }

    private func finished(_ job: Job, error: Error?) {
        running = nil
        if job.preempted, job.kind == .save {
            job.preempted = false
            queue.insert(job, at: min(1, queue.count))
        } else if let error {
            job.finish.resume(throwing: error)
        } else {
            job.finish.resume(returning: ())
        }
        pump()
    }
}
