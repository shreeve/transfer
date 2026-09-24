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

    /// A ProxyJump host's password prompt, or a one-time code, never gets the server's stored
    /// secret, and a key's passphrase is kept apart from the password, so it never reaches a server.
    @Test func aStoredSecretAnswersOnlyThisServersPassword() {
        #expect(SSHConnection.storedSecretKind("alice@box.example's password: ", user: "alice", host: "box.example") == .password)
        #expect(SSHConnection.storedSecretKind("(alice@box.example) Password: ", user: "alice", host: "box.example") == .password)
        #expect(SSHConnection.storedSecretKind("Enter passphrase for key '/Users/alice/.ssh/id_ed25519': ", user: "alice", host: "box.example") == .passphrase)
        #expect(SSHConnection.storedSecretKind("alice@jump.example's password: ", user: "alice", host: "box.example") == nil)
        #expect(SSHConnection.storedSecretKind("(alice@box.example) Verification code: ", user: "alice", host: "box.example") == nil)
    }

    /// Always Trust saves where `ssh -G` says; when `ssh -G` failed it says so rather than
    /// quietly trusting for this login only.
    @Test func alwaysTrustNeedsTheSSHConfiguration() throws {
        #expect(try SSHConnection.knownHostsFile(sshConfig: "user alice\nuserknownhostsfile /Users/alice/.ssh/known_hosts /Users/alice/.ssh/known_hosts2\n") == "/Users/alice/.ssh/known_hosts")
        #expect(try SSHConnection.knownHostsFile(sshConfig: "userknownhostsfile /dev/null\n") == nil)
        #expect(try SSHConnection.knownHostsFile(sshConfig: "user alice\n") == nil)
        #expect(throws: TransferError.self) { try SSHConnection.knownHostsFile(sshConfig: nil) }
    }

    @Test func controlCharactersAreFound() {
        #expect("a\rb".unicodeScalars.contains(where: SSHConnection.isControl))
        #expect("a\u{15}b".unicodeScalars.contains(where: SSHConnection.isControl))
        #expect("a\u{9B}b".unicodeScalars.contains(where: SSHConnection.isControl))
        #expect(!"/srv/My Files/été".unicodeScalars.contains(where: SSHConnection.isControl))
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

    /// A child the process left running, as an askpass helper still waiting for a reply is, may
    /// hold its pipes open: the runner returns soon after the process itself exits (R-S1).
    @Test func theRunnerDoesNotWaitForAChildHoldingItsPipes() async throws {
        let started = ContinuousClock.now
        let result = try await Subprocess.run("/bin/sh", ["-c", "sleep 8 & echo out; echo err >&2"], timeout: .seconds(20))
        #expect(ContinuousClock.now - started < .seconds(4))
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
    }
}

/// Login, host keys, and channels against the local sshd (`ServerHarness`).
@Suite(.enabled(if: ServerHarness.available, "needs the local sshd from Scripts/local-sshd.sh"))
struct SessionServerTests {
    @Test func concurrentConnectsShareOneLogin() async throws {
        try await withHarness("single", knownHost: false) { h in
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
        try await withHarness("stall", knownHost: false) { h in
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
            // Both sheets were taken back, not left up for an answer nobody reads (R-S2).
            #expect(await waitUntil(3) { prompts.withdrawn.value == 2 })
            let running = try await processes(h, "")
            let scratch = try loginScratch(h)
            #expect(running.isEmpty)
            #expect(scratch.isEmpty)
        }
    }

    /// A caller arriving while a login it could join is stopping, its callers all gone, gets a
    /// login of its own rather than that one's cancellation (R-S4).
    @Test func aLoginEveryoneLeftIsNotJoined() async throws {
        try await withHarness("rejoin", knownHost: false) { h in
            let stalled = StalledPrompts()
            let first = Task { try await h.session.connect(prompts: stalled) }
            #expect(await waitUntil { stalled.asked.value > 0 })
            first.cancel()
            let prompts = RecordingPrompts(.trustOnce)
            _ = try await h.session.connect(prompts: prompts)
            #expect(prompts.events.count == 1)
            await #expect(throws: TransferError.cancelled) { _ = try await first.value }
        }
    }

    /// Cancel on a question a ProxyJump host asks during the host-key probe stops the login at
    /// once. The probe's askpass helper, still waiting for a reply, used to hold the probe's
    /// stderr open, and the login hung until the helper gave up minutes later (R-S1).
    @Test(.timeLimit(.minutes(1))) func cancellingAQuestionDuringTheProbeStopsTheLogin() async throws {
        try await withHarness("probe") { h in
            let port = try #require(ProcessInfo.processInfo.environment["TRANSFER_TEST_PORT"])
            let key = h.base.appendingPathComponent("jump_key")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: h.session.connection.identityFile), to: key)
            _ = try await Subprocess.run("/usr/bin/ssh-keygen", ["-q", "-p", "-P", "", "-N", "jump secret", "-f", key.path], timeout: .seconds(10))
            // The jump host is known and asks for its key's passphrase; the server behind it,
            // under another key alias, is not known, so the login gets as far as the probe.
            try """
            Host *
              UserKnownHostsFile "\(knownHosts(h).path)"
              GlobalKnownHostsFile /dev/null
              IdentityAgent none
            Host jump
              HostName 127.0.0.1
              Port \(port)
              IdentityFile "\(key.path)"
              IdentitiesOnly yes
            Host 127.0.0.1
              ProxyJump jump
              HostKeyAlias transfer-probe-test

            """.write(to: h.configFile, atomically: true, encoding: .utf8)
            let prompts = PassphraseOnce("jump secret")
            let started = ContinuousClock.now
            await #expect(throws: TransferError.cancelled) { _ = try await h.session.connect(prompts: prompts) }
            #expect(ContinuousClock.now - started < .seconds(15))
            #expect(prompts.asked.value == 2)
            #expect(try await processes(h, "").isEmpty)
            #expect(try loginScratch(h).isEmpty)
        }
    }

    /// Trust Once writes no known-hosts file, and the next login asks again.
    @Test func trustOnceIsForOneLogin() async throws {
        try await withHarness("once", knownHost: false) { h in
            let prompts = RecordingPrompts(.trustOnce)
            _ = try await h.session.connect(prompts: prompts)
            _ = try await h.session.stat(h.remotePath)
            #expect(!FileManager.default.fileExists(atPath: knownHosts(h).path))
            await h.session.disconnect()
            #expect(try loginScratch(h).isEmpty)
            _ = try await h.session.connect(prompts: prompts)
            #expect(prompts.events.map(\.situation) == [.firstSeen, .firstSeen])
        }
    }

    /// A passenger whose master is gone fails; it never logs in on its own, with none of the
    /// master's settings (R-S3). The config here would let such a login succeed.
    @Test func aPassengerNeverLogsInOnItsOwn() async throws {
        try await withHarness("nomux") { h in
            let port = try #require(ProcessInfo.processInfo.environment["TRANSFER_TEST_PORT"])
            try writeConfig(h, extra: "Port \(port)\n  IdentityFile \"\(h.session.connection.identityFile)\"\n  IdentitiesOnly yes")
            try await connectKnown(h)
            try FileManager.default.removeItem(atPath: socketPath(h))
            try await killPassengers(h)
            await #expect(throws: (any Error).self) { _ = try await h.session.stat(h.remotePath) }
        }
    }

    /// A session that replaces another for the same server, as the hub makes when its settings
    /// change, logs in once the old one is gone, and the old one's teardown leaves it working.
    @Test func aReplacingSessionOutlivesTheOneItReplaced() async throws {
        try await withHarness("replace") { h in
            try await connectKnown(h)
            let replacement = SSHConnection(connection: h.session.connection, store: try Store(root: h.root), editableExtensions: [],
                                            live: h.live, sshConfigFile: h.configFile.path, replacing: h.session)
            _ = try await replacement.connect(prompts: RecordingPrompts(.cancel))
            #expect(await h.session.isConnected == false)
            await h.session.disconnect()
            try await killPassengers(h)
            _ = try await replacement.stat(h.remotePath)
            #expect(await replacement.isConnected)
            await replacement.disconnect()
            #expect(try await processes(h, "").isEmpty)
        }
    }

    /// ssh checks the host key itself, so a key trusted only in a global file (as on managed Macs)
    /// logs in without a question.
    @Test func aKeyTrustedGloballyAsksNothing() async throws {
        try await withHarness("global", knownHost: false) { h in
            let global = h.base.appendingPathComponent("global_known_hosts")
            try "\(try hostPattern()) \(try ServerHarness.hostKey())\n".write(to: global, atomically: true, encoding: .utf8)
            try writeConfig(h, global: global.path)
            let prompts = RecordingPrompts(.cancel)
            _ = try await h.session.connect(prompts: prompts)
            #expect(prompts.events.isEmpty)
        }
    }

    @Test func alwaysTrustHashesWhenAskedAndIsNotAskedAgain() async throws {
        try await withHarness("hashed", knownHost: false) { h in
            try writeConfig(h, extra: "HashKnownHosts yes")
            let prompts = RecordingPrompts(.alwaysTrust)
            _ = try await h.session.connect(prompts: prompts)
            let event = try #require(prompts.events.first)
            #expect(event.situation == .firstSeen)
            let listed = try await Subprocess.run("/usr/bin/ssh-keygen", ["-lf", ServerHarness.hostKeyFile().path], timeout: .seconds(5))
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
            #expect(known.contains(try ServerHarness.hostKey()))
        }
    }

    /// Cancel on a first contact's key is a plain Cancel; Cancel on a changed key refuses it.
    @Test func cancellingAHostKeyQuestion() async throws {
        try await withHarness("hkcancel", knownHost: false) { h in
            await #expect(throws: TransferError.cancelled) { _ = try await h.session.connect(prompts: RecordingPrompts(.cancel)) }
            try "\(try hostPattern()) \(try await otherKey(h))\n".write(to: knownHosts(h), atomically: true, encoding: .utf8)
            await #expect(throws: TransferError.hostKeyRejected) { _ = try await h.session.connect(prompts: RecordingPrompts(.cancel)) }
            #expect(try await processes(h, "").isEmpty)
            #expect(try loginScratch(h).isEmpty)
        }
    }

    @Test func aRevokedKeyIsRefusedWithoutAQuestion() async throws {
        try await withHarness("revoked") { h in
            try "@revoked \(try hostPattern()) \(try ServerHarness.hostKey())\n".write(to: knownHosts(h), atomically: true, encoding: .utf8)
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

    /// However many callers want one at once, at most seven data channels open (sshd's MaxSessions
    /// of 10 less the three reserved), and every caller gets one.
    @Test func dataChannelsNeverExceedSeven() async throws {
        try await withHarness("pool") { h in
            try await connectKnown(h)
            let seen = Locked((inUse: 0, peak: 0, links: Set<ObjectIdentifier>()))
            let peakProcesses = Locked(0)
            let refusedBefore = try sessionRefusals()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<40 {
                    group.addTask {
                        try await h.session.withData { link in
                            seen.withLock {
                                $0.inUse += 1
                                $0.peak = max($0.peak, $0.inUse)
                                $0.links.insert(ObjectIdentifier(link))
                            }
                            try await Task.sleep(for: .milliseconds(40))
                            _ = try await link.realpath(RemotePath(string: "."))
                            seen.withLock { $0.inUse -= 1 }
                        }
                    }
                }
                group.addTask {
                    let count = try await processes(h, " sftp").count
                    peakProcesses.withLock { $0 = max($0, count) }
                }
                try await group.waitForAll()
            }
            #expect(seen.value.peak <= SSHConnection.dataChannels)
            #expect(seen.value.links.count <= SSHConnection.dataChannels)
            #expect(try await processes(h, " sftp").count <= 3 + SSHConnection.dataChannels)
            #expect(peakProcesses.value <= 3 + SSHConnection.dataChannels)
            // sshd would refuse an eighth; none was even tried.
            #expect(try sessionRefusals() == refusedBefore)
        }
    }

    /// A caller queued for a data channel leaves the queue as soon as it is cancelled.
    @Test func aCancelledCallerLeavesTheChannelQueue() async throws {
        try await withHarness("queue") { h in
            try await connectKnown(h)
            let held = Locked(0)
            let open = Locked(false)
            let holders = Task {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<SSHConnection.dataChannels {
                        group.addTask {
                            try await h.session.withData { _ in
                                held.withLock { $0 += 1 }
                                while !open.value { try await Task.sleep(for: .milliseconds(20)) }
                            }
                        }
                    }
                    try await group.waitForAll()
                }
            }
            #expect(await waitUntil { held.value == SSHConnection.dataChannels })
            let queued = Task { try await h.session.withData { _ in } }
            try await Task.sleep(for: .milliseconds(200))
            queued.cancel()
            await #expect(throws: TransferError.cancelled) { try await queued.value }
            #expect(!open.value)
            open.value = true
            try await holders.value
            try await h.session.withData { _ in }
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

    /// Open in Terminal types this command into a shell, so a control byte in a folder name the
    /// server chose must never reach it.
    @Test func theTerminalCommandRefusesControlCharacters() async throws {
        try await withHarness("terminal") { h in
            try await connectKnown(h)
            #expect(await h.session.terminalCommand(directory: RemotePath(string: "/tmp/x\r touch /tmp/pwned\r")) == nil)
            #expect(await h.session.terminalCommand(directory: RemotePath(string: "/tmp/x\u{15}y")) == nil)
            let command = try #require(await h.session.terminalCommand(directory: RemotePath(string: "/tmp/it's here")))
            #expect(command.contains("-o 'ControlMaster=no'"))
            #expect(command.contains("-o 'RemoteCommand=none'"))
            #expect(command.contains("-p '\(h.session.connection.port)'"))
            #expect(command.contains("-i '\(h.session.connection.identityFile)'"))
            #expect(command.contains("-- '\(h.session.connection.destination)'"))
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

/// A host-key sheet nobody answers, taken back when its question is cancelled.
private final class StalledPrompts: PromptSink {
    let asked = Locked(0)
    let withdrawn = Locked(0)

    func answer(_ request: PromptRequest) async -> PromptReply { PromptReply(text: nil) }
    func decideHostKey(_ event: HostKeyEvent) async -> HostKeyDecision {
        asked.withLock { $0 += 1 }
        do { try await Task.sleep(for: .seconds(120)) } catch { withdrawn.withLock { $0 += 1 } }
        return .cancel
    }
    func resolveCollision(fileName: String) async -> NameCollisionChoice? { nil }
}

/// Types the passphrase the first time it is asked, and Cancel after that.
private final class PassphraseOnce: PromptSink {
    let passphrase: String
    let asked = Locked(0)

    init(_ passphrase: String) { self.passphrase = passphrase }

    func answer(_ request: PromptRequest) async -> PromptReply {
        let count = asked.withLock { $0 += 1; return $0 }
        return PromptReply(text: count == 1 ? passphrase : nil)
    }
    func decideHostKey(_ event: HostKeyEvent) async -> HostKeyDecision { .trustOnce }
    func resolveCollision(fileName: String) async -> NameCollisionChoice? { nil }
}

private func hostPattern() throws -> String {
    "[127.0.0.1]:\(try #require(ProcessInfo.processInfo.environment["TRANSFER_TEST_PORT"]))"
}

/// How many channels the local sshd has refused for MaxSessions, from the log `local-sshd.sh`
/// writes beside the keys.
private func sessionRefusals() throws -> Int {
    let log = try ServerHarness.hostKeyFile().deletingLastPathComponent().appendingPathComponent("sshd.log")
    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    return text.components(separatedBy: "no more sessions").count - 1
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

/// Logs in with the server's key already in known_hosts, asking nothing.
private func connectKnown(_ h: ServerHarness) async throws {
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

private func socketPath(_ h: ServerHarness) -> String {
    h.root.appendingPathComponent("ssh/\(h.session.connection.id.socketName)").path
}

/// The ssh processes on this harness's control socket whose command line contains `marker`.
private func processes(_ h: ServerHarness, _ marker: String) async throws -> [(pid: pid_t, command: String)] {
    let socket = socketPath(h)
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
