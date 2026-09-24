import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// The session layer's pure parts: how ssh's host-key refusals are read, known_hosts lines,
/// fingerprints, which prompts a stored secret may answer, and the process runner.
struct SessionUnitTests {
    @Test func hostKeyFailuresAreReadFromSsh() {
        #expect(HostKeyFailure(sshErrors: """
            No ED25519 host key is known for [127.0.0.1]:2241 and you have requested strict checking.
            Host key verification failed.
            """) == .unknown)
        #expect(HostKeyFailure(sshErrors: """
            @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
            Host key for [127.0.0.1]:2241 has changed and you have requested strict checking.
            Host key verification failed.
            """) == .changed)
        #expect(HostKeyFailure(sshErrors: """
            @       WARNING: REVOKED HOST KEY DETECTED!               @
            ED25519 host key for [127.0.0.1]:2241 was revoked and you have requested strict checking.
            Host key verification failed.
            """) == .revoked)
        #expect(HostKeyFailure(sshErrors: "user@box: Permission denied (publickey).") == nil)
    }

    @Test func fingerprintAndHashedLinesMatchOpenSSH() async throws {
        let folder = TestCaches.fresh("keys")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = folder.appendingPathComponent("key")
        _ = try await Subprocess.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key.path], timeout: .seconds(10))
        let parts = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8).split(separator: " ").map(String.init)
        let listed = try await Subprocess.run("/usr/bin/ssh-keygen", ["-lf", key.appendingPathExtension("pub").path], timeout: .seconds(5))
        #expect(SSHConnection.fingerprint(parts[1]) == listed.stdout.split(separator: " ")[1].description)

        let offered = HostKeyLine(host: "[box.example]:2200,10.0.0.9", keyType: parts[0], key: parts[1])
        #expect(SSHConnection.knownHostsLines(offered, hashed: false) == ["[box.example]:2200,10.0.0.9 \(parts[0]) \(parts[1])"])
        let hashed = SSHConnection.knownHostsLines(offered, hashed: true)
        #expect(hashed.count == 2)
        #expect(hashed.allSatisfy { $0.hasPrefix("|1|") && !$0.contains("box.example") })
        let file = folder.appendingPathComponent("known_hosts")
        try (hashed.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        for host in ["[box.example]:2200", "10.0.0.9"] {
            let found = try await Subprocess.run("/usr/bin/ssh-keygen", ["-F", host, "-f", file.path], timeout: .seconds(5))
            #expect(found.status == 0, "ssh-keygen finds \(host)")
        }
    }

    /// A ProxyJump host's password prompt, or a one-time code, never gets the server's stored secret.
    @Test func aStoredSecretAnswersOnlyThisServersPassword() {
        #expect(SSHConnection.takesStoredSecret("alice@box.example's password: ", user: "alice", host: "box.example"))
        #expect(SSHConnection.takesStoredSecret("(alice@box.example) Password: ", user: "alice", host: "box.example"))
        #expect(SSHConnection.takesStoredSecret("Enter passphrase for key '/Users/alice/.ssh/id_ed25519': ", user: "alice", host: "box.example"))
        #expect(!SSHConnection.takesStoredSecret("alice@jump.example's password: ", user: "alice", host: "box.example"))
        #expect(!SSHConnection.takesStoredSecret("(alice@box.example) Verification code: ", user: "alice", host: "box.example"))
    }

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

/// Login, host keys, and channels against the local sshd (`ServerHarness`).
@Suite(.enabled(if: ServerHarness.available, "needs the local sshd from Scripts/local-sshd.sh"))
struct SessionServerTests {
    @Test func concurrentConnectsShareOneLogin() async throws {
        try await withHarness("single") { h in
            let prompts = RecordingPrompts(.trustOnce)
            async let first = h.session.connect(prompts: prompts)
            async let second = h.session.connect(prompts: prompts)
            let (a, b) = try await (first, second)
            #expect(a == b)
            #expect(prompts.events.count == 1)
            #expect(try await processes(h, "-N").count == 1)
            await h.session.disconnect()
            #expect(try await processes(h, "").isEmpty)
            #expect(try loginScratch(h).isEmpty)
        }
    }

    /// A login held up by a question nobody answers stops when the session disconnects or when
    /// its only caller is cancelled, and leaves nothing running.
    @Test func aStalledLoginStops() async throws {
        try await withHarness("stall") { h in
            let prompts = StalledPrompts()
            let login = Task { try await h.session.connect(prompts: prompts) }
            #expect(await waitUntil { prompts.asked.value > 0 })
            await h.session.disconnect()
            await #expect(throws: TransferError.cancelled) { _ = try await login.value }

            let again = Task { try await h.session.connect(prompts: prompts) }
            #expect(await waitUntil { prompts.asked.value > 1 })
            again.cancel()
            await #expect(throws: TransferError.cancelled) { _ = try await again.value }
            #expect(await h.session.isConnected == false)
            let running = try await processes(h, "")
            let scratch = try loginScratch(h)
            #expect(running.isEmpty)
            #expect(scratch.isEmpty)
        }
    }

    /// ssh checks the host key itself, so a key trusted only in a global file (as on managed Macs)
    /// logs in without a question.
    @Test func aKeyTrustedGloballyAsksNothing() async throws {
        try await withHarness("global") { h in
            let global = h.base.appendingPathComponent("global_known_hosts")
            try "\(try hostPattern()) \(try hostKey())\n".write(to: global, atomically: true, encoding: .utf8)
            try writeConfig(h, global: global.path)
            let prompts = RecordingPrompts(.cancel)
            _ = try await h.session.connect(prompts: prompts)
            #expect(prompts.events.isEmpty)
        }
    }

    @Test func alwaysTrustHashesWhenAskedAndIsNotAskedAgain() async throws {
        try await withHarness("hashed") { h in
            try writeConfig(h, extra: "HashKnownHosts yes")
            let prompts = RecordingPrompts(.alwaysTrust)
            _ = try await h.session.connect(prompts: prompts)
            let event = try #require(prompts.events.first)
            #expect(event.situation == .firstSeen)
            let listed = try await Subprocess.run("/usr/bin/ssh-keygen", ["-lf", hostKeyFile().path], timeout: .seconds(5))
            #expect(event.fingerprint == listed.stdout.split(separator: " ")[1].description)
            let known = try String(contentsOf: knownHosts(h), encoding: .utf8)
            #expect(known.hasPrefix("|1|"))
            #expect(!known.contains("127.0.0.1"))
            await h.session.disconnect()

            let again = RecordingPrompts(.cancel)
            _ = try await h.session.connect(prompts: again)
            #expect(again.events.isEmpty)
        }
    }

    @Test func aChangedKeyIsReplaced() async throws {
        try await withHarness("changed") { h in
            let other = try await otherKey(h)
            try "\(try hostPattern()) \(other)\n".write(to: knownHosts(h), atomically: true, encoding: .utf8)
            let prompts = RecordingPrompts(.replace)
            _ = try await h.session.connect(prompts: prompts)
            #expect(prompts.events.map(\.situation) == [.changed])
            let known = try String(contentsOf: knownHosts(h), encoding: .utf8)
            #expect(!known.contains(other))
            #expect(known.contains(try hostKey()))
        }
    }

    @Test func aRevokedKeyIsRefusedWithoutAQuestion() async throws {
        try await withHarness("revoked") { h in
            try "@revoked \(try hostPattern()) \(try hostKey())\n".write(to: knownHosts(h), atomically: true, encoding: .utf8)
            let prompts = RecordingPrompts(.alwaysTrust)
            await #expect(throws: TransferError.hostKeyRejected) { _ = try await h.session.connect(prompts: prompts) }
            #expect(prompts.events.isEmpty)
            #expect(try await processes(h, "").isEmpty)
        }
    }

    /// Settings meant for the user's own shells (a remote command, a TTY, forwards, a local command,
    /// a persisting master) change nothing for Transfer.
    @Test func shellSettingsInTheConfigDoNotBreakChannels() async throws {
        try await withHarness("shellish") { h in
            let marker = h.base.appendingPathComponent("local-command-ran")
            let port = 20000 + Int.random(in: 0..<20000)
            try writeConfig(h, extra: """
                RemoteCommand tmux new-session -A -s main
                RequestTTY yes
                ControlPersist 10m
                LocalForward 127.0.0.1:\(port) 127.0.0.1:9
                ExitOnForwardFailure yes
                PermitLocalCommand yes
                LocalCommand touch "\(marker.path)"
              """)
            try await connectKnown(h)
            #expect(await h.session.isConnected)
            var names: [String] = []
            try FileManager.default.createDirectory(at: h.remote.appendingPathComponent("folder"), withIntermediateDirectories: true)
            for try await item in h.session.list(h.remotePath) { names.append(item.name) }
            #expect(names == ["folder"])
            let local = h.staging.appendingPathComponent("up.txt")
            try Data("up".utf8).write(to: local)
            try await h.session.upload(local, to: h.remotePath.appending(name: Array("up.txt".utf8))) { _ in }
            #expect(try Data(contentsOf: h.remote.appendingPathComponent("up.txt")) == Data("up".utf8))
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            await h.session.disconnect()
            #expect(try await processes(h, "").isEmpty)
        }
    }

    /// Dead reserved channels are reopened, as often as every 5 s; a live master with no channel
    /// is a lost connection, which transfers retry, and the master's death is reported.
    @Test func reservedChannelsReopenAndTheMastersDeathIsReported() async throws {
        try await withHarness("reopen") { h in
            try await connectKnown(h)
            let disconnected = Locked(false)
            let stream = h.session.events()
            let listener = Task {
                for await event in stream { if case .disconnected = event { disconnected.value = true } }
            }
            defer { listener.cancel() }
            try await killPassengers(h)
            _ = try await h.session.stat(h.remotePath)
            try await killPassengers(h)
            _ = try await h.session.stat(h.remotePath)
            try await killPassengers(h)
            let lost = await #expect(throws: TransferError.self) { _ = try await h.session.stat(h.remotePath) }
            #expect(lost.map(RetryPolicy.isRetryable) == true)
            try await Task.sleep(for: .milliseconds(5200))
            _ = try await h.session.stat(h.remotePath)

            let master = try #require(try await processes(h, "-N").first)
            kill(master.pid, SIGTERM)
            #expect(await waitUntil { disconnected.value })
            #expect(await h.session.isConnected == false)
            _ = try await h.session.connect(prompts: h.prompts)
            _ = try await h.session.stat(h.remotePath)
        }
    }
}

// MARK: Helpers

/// Records every host-key question and gives one answer to all of them.
private final class RecordingPrompts: PromptSink {
    private let decision: HostKeyDecision
    private let seen = Locked<[HostKeyEvent]>([])
    var events: [HostKeyEvent] { seen.value }

    init(_ decision: HostKeyDecision) { self.decision = decision }

    func answer(_ request: PromptRequest) async -> PromptReply { PromptReply(text: nil) }
    func decideHostKey(_ event: HostKeyEvent) async -> HostKeyDecision {
        seen.withLock { $0.append(event) }
        return decision
    }
    func resolveCollision(fileName: String) async -> NameCollisionChoice? { nil }
}

/// A host-key sheet nobody answers.
private final class StalledPrompts: PromptSink {
    let asked = Locked(0)

    func answer(_ request: PromptRequest) async -> PromptReply { PromptReply(text: nil) }
    func decideHostKey(_ event: HostKeyEvent) async -> HostKeyDecision {
        asked.withLock { $0 += 1 }
        try? await Task.sleep(for: .seconds(120))
        return .cancel
    }
    func resolveCollision(fileName: String) async -> NameCollisionChoice? { nil }
}

private func hostKeyFile() throws -> URL {
    let identity = try #require(ProcessInfo.processInfo.environment["TRANSFER_TEST_IDENTITY"])
    return URL(fileURLWithPath: identity).deletingLastPathComponent().appendingPathComponent("host_key.pub")
}

/// The local sshd's host key, as `type base64`.
private func hostKey() throws -> String {
    try String(contentsOf: hostKeyFile(), encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
}

private func hostPattern() throws -> String {
    "[127.0.0.1]:\(try #require(ProcessInfo.processInfo.environment["TRANSFER_TEST_PORT"]))"
}

private func knownHosts(_ h: ServerHarness) -> URL {
    h.base.appendingPathComponent("known_hosts")
}

/// A key the server does not hold, as `type base64`.
private func otherKey(_ h: ServerHarness) async throws -> String {
    let file = h.base.appendingPathComponent("other_key")
    _ = try await Subprocess.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", file.path], timeout: .seconds(10))
    return try String(contentsOf: file.appendingPathExtension("pub"), encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
}

/// Logs in with the server's key already in known_hosts: one connection, where a first contact
/// takes three (refused, probe, master), which many suites at once would crowd into sshd's
/// MaxStartups.
private func connectKnown(_ h: ServerHarness) async throws {
    try "\(try hostPattern()) \(try hostKey())\n".write(to: knownHosts(h), atomically: true, encoding: .utf8)
    let prompts = RecordingPrompts(.cancel)
    _ = try await h.session.connect(prompts: prompts)
    #expect(prompts.events.isEmpty)
}

/// Rewrites the harness's ssh config: its own known_hosts, a global file, and `extra` lines.
private func writeConfig(_ h: ServerHarness, global: String = "/dev/null", extra: String = "") throws {
    try """
    Host *
      UserKnownHostsFile "\(knownHosts(h).path)"
      GlobalKnownHostsFile "\(global)"
      IdentityAgent none
      \(extra)

    """.write(to: h.configFile, atomically: true, encoding: .utf8)
}

/// The ssh processes on this harness's control socket whose command line contains `marker`.
private func processes(_ h: ServerHarness, _ marker: String) async throws -> [(pid: pid_t, command: String)] {
    let socket = h.root.appendingPathComponent("ssh/\(h.session.connection.id.socketName)").path
    let listed = try await Subprocess.run("/bin/ps", ["-axwwo", "pid=,command="], timeout: .seconds(5))
    return listed.stdout.split(separator: "\n").compactMap { line in
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.contains(socket), text.contains("/usr/bin/ssh"), marker.isEmpty || text.contains(marker),
              let space = text.firstIndex(of: " "), let pid = pid_t(text[..<space]) else { return nil }
        return (pid, String(text[space...]))
    }
}

/// Kills every SFTP passenger and waits until their channels notice.
private func killPassengers(_ h: ServerHarness) async throws {
    for passenger in try await processes(h, " sftp") { kill(passenger.pid, SIGKILL) }
    try await Task.sleep(for: .milliseconds(500))
}

private func loginScratch(_ h: ServerHarness) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: h.root.path).filter { name in
        SSHConnection.loginScratchPrefixes.contains { name.hasPrefix($0) }
    }
}
