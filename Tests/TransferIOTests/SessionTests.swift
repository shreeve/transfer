import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// The session layer's pure parts: the process runner.
struct SessionUnitTests {
    /// More output than a pipe holds never stalls the runner, and a slow command is stopped.
    @Test func theRunnerReadsLargeOutputAndTimesOut() async throws {
        let big = try await Subprocess.run("/bin/sh", ["-c", "head -c 1000000 /dev/zero; echo done >&2"], timeout: .seconds(10))
        #expect(big.stdout.utf8.count == 1_000_000)
        #expect(big.stderr == "done\n")
        let started = ContinuousClock.now
        await #expect(throws: TransferError.timeout("sleep")) {
            _ = try await Subprocess.run("/bin/sleep", ["30"], timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        let slow = Task { try await Subprocess.run("/bin/sleep", ["30"], timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(200))
        slow.cancel()
        await #expect(throws: TransferError.cancelled) { _ = try await slow.value }
    }
}
