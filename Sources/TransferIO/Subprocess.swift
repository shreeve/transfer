import Foundation
import TransferCore

/// Short-lived helper processes (`ssh -G`, `ssh -O exit`, the host-key probe, `ssh-keygen`): one
/// runner, with a timeout, that reads both pipes as they fill so a chatty process never blocks.
enum Subprocess {
    struct Result: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Runs `launch` to its end, killing it on `timeout` (throws `.timeout`) or task cancellation
    /// (throws `.cancelled`). Blocking reads run on Dispatch threads, never Swift's cooperative pool.
    static func run(_ launch: String, _ arguments: [String], environment: [String: String]? = nil, timeout: Duration) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let stopped = Locked((timedOut: false, cancelled: false))
        let name = (launch as NSString).lastPathComponent
        let result: Result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: TransferError.failed("Could not run \(name)"))
                        return
                    }
                    if stopped.value.cancelled { process.terminate() }
                    let watchdog = DispatchWorkItem {
                        guard process.isRunning else { return }
                        stopped.withLock { $0.timedOut = true }
                        process.terminate()
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout / .seconds(1), execute: watchdog)
                    let stderr = Locked(Data())
                    let reading = DispatchGroup()
                    DispatchQueue.global().async(group: reading) { stderr.value = errors.fileHandleForReading.readDataToEndOfFile() }
                    let stdout = output.fileHandleForReading.readDataToEndOfFile()
                    reading.wait()
                    process.waitUntilExit()
                    watchdog.cancel()
                    continuation.resume(returning: Result(
                        status: process.terminationStatus,
                        stdout: String(decoding: stdout, as: UTF8.self),
                        stderr: String(decoding: stderr.value, as: UTF8.self)))
                }
            }
        } onCancel: {
            stopped.withLock { $0.cancelled = true }
            if process.isRunning { process.terminate() }
        }
        if stopped.value.cancelled { throw TransferError.cancelled }
        if stopped.value.timedOut { throw TransferError.timeout(name) }
        return result
    }
}

/// The last few kilobytes a process writes to a pipe, read as they arrive so the writer never
/// blocks on a full pipe, however long it lives.
final class OutputTail: Sendable {
    let pipe = Pipe()
    private let data = Locked(Data())
    private let ended = Locked(false)

    init(limit: Int = 8192) {
        pipe.fileHandleForReading.readabilityHandler = { [data, ended] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // At end of file the handler would otherwise keep firing with nothing to read.
                handle.readabilityHandler = nil
                ended.value = true
                return
            }
            data.withLock {
                $0.append(chunk)
                if $0.count > limit { $0.removeFirst($0.count - limit) }
            }
        }
    }

    var text: String { String(decoding: data.value, as: UTF8.self) }

    /// Waits, at most a second, for everything the process wrote before it exited.
    func waitForEnd() async {
        for _ in 0..<50 where !ended.value {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

extension String {
    /// The last non-empty line, trimmed: what ssh says last is why it stopped.
    var lastLine: String {
        split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}
