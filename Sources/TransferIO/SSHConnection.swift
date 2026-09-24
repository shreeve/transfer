import CryptoKit
import Foundation
import TransferCore

/// One saved server over the Mac's own /usr/bin/ssh: the ControlMaster login (askpass, host keys),
/// the SFTP passengers riding it (browse, interactive, walker, and at most seven data channels),
/// and the Live API it forwards to `LiveSync`. The transfer engine is in
/// SSHConnection+Transfers.swift. HANDOFF.md explains the design and the traps it avoids.
public actor SSHConnection: RemoteSession {
    public nonisolated let connection: SavedConnection

    let store: Store
    private(set) var editableExtensions: Set<String>
    /// Every passenger joins the master here. It is one path per saved server, so a login waits
    /// for the previous master to be gone (`releasing`) before it binds the path again.
    private let socketPath: String
    private var master: Process?
    private var masterErrors: OutputTail?
    /// Per-login files under the library root (the askpass folder, a Trust Once known-hosts file),
    /// removed on disconnect.
    private var scratch: [URL] = []
    private var startPath: RemotePath?
    /// The one login in flight. Every `connect` meanwhile joins it rather than starting another.
    private var login: Task<RemotePath, Error>?
    private var loginWaiters = (waiting: 0, cancelled: 0)
    /// The latest release of a master and its channels. The next login waits for it, so an old
    /// master never exits, unlinking the socket, after a new one has bound it.
    private var releasing: Task<Void, Never>?
    /// Bumped by every login and teardown, so a channel that finishes opening afterwards is closed.
    private var generation = 0
    private var reserved: [ChannelRole: SFTPChannel] = [:]
    private var reopenedAt: [ChannelRole: ContinuousClock.Instant] = [:]
    private var pool: [SFTPChannel] = []
    private var busy: Set<ObjectIdentifier> = []
    private var waiters: [CheckedContinuation<SFTPChannel, Error>] = []
    private var poolRefused = false
    let pipe = EventPipe()
    let lane = InteractiveLane()
    /// Live files are `LiveSync`'s; this connection is its `LiveServer` and forwards the Live API.
    let live: LiveSync
    private let ownsLive: Bool
    /// A config file every ssh this connection runs reads with `-F` in place of `~/.ssh/config`.
    /// Nil in the app. Tests set it so they never read the developer's config or known hosts.
    private let sshConfigFile: String?

    /// sshd's default MaxSessions is 10: three reserved passengers and seven data channels.
    static let dataChannels = 7
    /// How long a login may take, prompts included, before it gives up.
    static let loginTimeout: Duration = .seconds(300)
    static let handshakeTimeout: Duration = .seconds(15)

    /// The hub passes its one `LiveSync`. Without one, as in tests, the connection makes its own
    /// and closes it on disconnect.
    init(connection: SavedConnection, store: Store, editableExtensions: Set<String>, live: LiveSync? = nil, sshConfigFile: String? = nil) {
        self.connection = connection
        self.store = store
        self.editableExtensions = editableExtensions
        self.live = live ?? LiveSync(store: store)
        ownsLive = live == nil
        self.sshConfigFile = sshConfigFile
        socketPath = store.root.appendingPathComponent("ssh/\(connection.id.socketName)").path
    }

    public nonisolated func events() -> AsyncStream<SessionEvent> { pipe.stream() }

    func setEditableExtensions(_ extensions: Set<String>) {
        editableExtensions = extensions
    }

    public var isConnected: Bool { startPath != nil && master?.isRunning == true }
    var unsyncedLiveCount: Int { get async { await live.unsyncedCount(on: connection.id) } }

    // MARK: Login

    /// Joins the login in flight when there is one, so two windows or a retry never log in twice.
    /// The login stops once every caller waiting for it is cancelled.
    public func connect(prompts: any PromptSink) async throws -> RemotePath {
        if let startPath, master?.isRunning == true { return startPath }
        let task: Task<RemotePath, Error>
        if let login {
            task = login
        } else {
            task = Task { try await self.logIn(prompts) }
            login = task
            loginWaiters = (0, 0)
        }
        loginWaiters.waiting += 1
        defer { if login == task { login = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await self.loginWaiterCancelled(task) }
        }
    }

    private func loginWaiterCancelled(_ task: Task<RemotePath, Error>) {
        guard login == task else { return }
        loginWaiters.cancelled += 1
        if loginWaiters.cancelled >= loginWaiters.waiting { task.cancel() }
    }

    /// Stops a login in flight and closes the session.
    public func disconnect() async {
        while let login {
            self.login = nil
            login.cancel()
            _ = await login.result
        }
        await tearDown(reason: .cancelled)
    }

    /// What one login has started, released together when it fails or the session ends.
    private struct Held {
        var master: Process?
        var errors: OutputTail?
        var reserved: [ChannelRole: SFTPChannel] = [:]
        var pool: [SFTPChannel] = []
        var scratch: [URL] = []
    }

    private func logIn(_ prompts: any PromptSink) async throws -> RemotePath {
        // Whatever an earlier login left, such as a master that died; also waits out any release.
        await tearDown(reason: .connectionLost("The SSH connection closed"))
        var held = Held()
        do {
            let resolved = try await start(prompts, holding: &held)
            try Task.checkCancellation()
            master = held.master
            masterErrors = held.errors
            reserved = held.reserved
            scratch = held.scratch
            startPath = resolved
            generation += 1
        } catch {
            await release(held)
            throw error is CancellationError ? TransferError.cancelled : error
        }
        await removeRecordedRemoteTemps()
        await live.connected(connection.id, server: self)
        guard let startPath else { throw TransferError.notConnected }
        return startPath
    }

    /// Starts the master and lets ssh check the host key against the user's own files. Only when
    /// ssh refuses the key does the user decide, and then the master starts once more.
    private func start(_ prompts: any PromptSink, holding held: inout Held) async throws -> RemotePath {
        let folder = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        if FileManager.default.fileExists(atPath: socketPath) {
            // A master left behind by a crash.
            _ = try? await ssh(["-S", socketPath, "-O", "exit", "--", connection.destination], timeout: .seconds(3))
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        let ask = try prepareAskpass()
        held.scratch.append(ask)
        let deadline = ContinuousClock.now + Self.loginTimeout
        let current = Locked<Process?>(nil)
        let refused = Locked(false)
        let poller = Task { await self.servePrompts(prompts, directory: ask, ssh: current, refused: refused) }
        defer { poller.cancel() }
        var hostKeyArguments: [String] = []
        var askedAboutHostKey = false
        var drops = 0
        while true {
            let (process, errors) = try startMaster(hostKeyArguments, ask: ask)
            held.master = process
            held.errors = errors
            current.value = process
            if try await waitForSocket(process, until: deadline) { break }
            await Self.stop(process)
            held.master = nil
            if refused.value { throw TransferError.cancelled }
            if ContinuousClock.now >= deadline { throw TransferError.timeout("login") }
            await errors.waitForEnd()
            guard let failure = HostKeyFailure(sshErrors: errors.text) else {
                let line = errors.lastLine
                guard Self.droppedBeforeLogin(line) else { throw TransferError.authenticationFailed(line) }
                drops += 1
                if drops > 2 { throw TransferError.connectionLost(line) }
                try await Task.sleep(for: .milliseconds(500 * drops))
                continue
            }
            if failure == .revoked || askedAboutHostKey { throw TransferError.hostKeyRejected }
            askedAboutHostKey = true
            hostKeyArguments = try await trustHostKey(failure, prompts: prompts, ask: ask, holding: &held)
        }
        let browse = try await openLink()
        held.reserved[.browse] = browse
        held.reserved[.interactive] = try? await openLink()
        held.reserved[.walker] = try? await openLink()
        let start = connection.remotePath.isEmpty ? RemotePath(string: ".") : RemotePath(string: connection.remotePath)
        return try await browse.realpath(start)
    }

    /// sshd dropped the connection before authentication, as its MaxStartups and PerSourcePenalties
    /// do under load: worth another try, unlike a refused login.
    static func droppedBeforeLogin(_ line: String) -> Bool {
        line.hasPrefix("Connection reset") || line.hasPrefix("Connection closed") || line.hasPrefix("kex_exchange_identification")
    }

    private func startMaster(_ hostKeyArguments: [String], ask: URL) throws -> (Process, OutputTail) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = masterArguments(hostKeyArguments)
        process.environment = askEnvironment(ask)
        // Drained for the master's whole life: ssh blocks once a pipe nobody reads is full.
        let errors = OutputTail()
        process.standardError = errors.pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            Task { await self?.masterEnded(process) }
        }
        do {
            try process.run()
        } catch {
            throw TransferError.failed("Could not start ssh")
        }
        return (process, errors)
    }

    private func waitForSocket(_ process: Process, until deadline: ContinuousClock.Instant) async throws -> Bool {
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: socketPath) { return true }
            if !process.isRunning { return false }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Closes everything the session holds. Waiting callers get `reason`: a disconnect nobody
    /// asked for is a lost connection, which a transfer retries, not a cancel.
    private func tearDown(reason: TransferError) async {
        let held = Held(master: master, errors: masterErrors, reserved: reserved, pool: pool, scratch: scratch)
        master = nil
        masterErrors = nil
        reserved.removeAll()
        reopenedAt.removeAll()
        pool.removeAll()
        busy.removeAll()
        poolRefused = false
        scratch.removeAll()
        startPath = nil
        generation += 1
        for waiter in waiters { waiter.resume(throwing: reason) }
        waiters.removeAll()
        if ownsLive { await live.closeAll() } else { await live.disconnected(connection.id, server: self) }
        await release(held)
    }

    /// Stops what `held` started, after any earlier release: when the last release returns, no
    /// master of this connection runs and the socket path is free.
    private func release(_ held: Held) async {
        let previous = releasing
        let task = Task {
            await previous?.value
            for link in Array(held.reserved.values) + held.pool { await link.closeLink() }
            if let master = held.master {
                master.terminationHandler = nil
                if master.isRunning {
                    _ = try? await ssh(["-S", socketPath, "-O", "exit", "--", connection.destination], timeout: .seconds(3))
                    await Self.stop(master)
                }
                try? FileManager.default.removeItem(atPath: socketPath)
            }
            for folder in held.scratch { try? FileManager.default.removeItem(at: folder) }
        }
        releasing = task
        await task.value
    }

    /// Terminates `process` and waits for it to exit, killing it after 3 s.
    private static func stop(_ process: Process) async {
        if process.isRunning { process.terminate() }
        for _ in 0..<60 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func masterEnded(_ process: Process) async {
        guard master === process, startPath != nil else { return }
        let errors = masterErrors
        await tearDown(reason: .connectionLost("The SSH connection closed"))
        await errors?.waitForEnd()
        let reason = errors?.lastLine ?? ""
        pipe.emit(.disconnected("The SSH connection to \(connection.displayName) closed" + (reason.isEmpty ? "" : ": \(reason)")))
    }

    // MARK: Metadata

    public nonisolated func list(_ path: RemotePath) -> AsyncThrowingStream<RemoteItem, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let link = try await metadataLink()
                    for try await item in await link.list(path) {
                        continuation.yield(item)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stat(_ path: RemotePath) async throws -> RemoteItem {
        try await metadataLink().lstat(path)
    }

    public func readlink(_ path: RemotePath) async throws -> String {
        try await metadataLink().readlink(path)
    }

    public func mkdir(_ path: RemotePath) async throws {
        try await metadataLink().mkdir(path)
        if let parent = path.parent { pipe.emit(.directoryChanged(parent)) }
    }

    public func rename(_ source: RemotePath, to destination: RemotePath) async throws {
        try await live.rename(source, to: destination, on: connection.id) {
            try await self.metadataLink().rename(source, to: destination)
        }
        if let parent = source.parent { pipe.emit(.directoryChanged(parent)) }
        if let parent = destination.parent, parent != source.parent { pipe.emit(.directoryChanged(parent)) }
    }

    // MARK: Open

    public func openKind(fileName: String) async -> OpenKind {
        EditableFile.openKind(fileName: fileName, extensions: editableExtensions)
    }

    public func prepareLiveFile(_ path: RemotePath) async throws -> URL {
        try await live.open(path, on: connection.id)
    }

    // MARK: Live

    public func liveFiles() async -> [LiveFile] {
        await live.files(on: connection.id)
    }

    public func discardLiveFile(_ path: RemotePath, force: Bool) async throws {
        try await live.discard(path, on: connection.id, force: force)
    }

    public func setLivePaused(_ path: RemotePath, paused: Bool) async {
        await live.setPaused(path, on: connection.id, paused: paused)
    }

    public func resolveLive(_ path: RemotePath, choice: LiveConflictChoice) async throws {
        try await live.resolve(path, on: connection.id, choice: choice)
    }

    // MARK: Sidebar data

    public func stars() async -> [RemotePath] {
        store.stars(connection: connection.id).map(RemotePath.init(string:))
    }

    public func star(_ path: RemotePath) async {
        store.star(connection: connection.id, path: path.display, on: true)
    }

    public func unstar(_ path: RemotePath) async {
        store.star(connection: connection.id, path: path.display, on: false)
    }

    public func terminalCommand(directory: RemotePath) async -> String? {
        guard isConnected else { return nil }
        let remote = "cd \(Self.quote(directory.display)) && exec \"$SHELL\" -l"
        let config = sshConfigFile.map { " -F \(Self.quote($0))" } ?? ""
        return "/usr/bin/ssh -S \(Self.quote(socketPath))\(config) -o Compression=no -t -- \(Self.quote(connection.destination)) \(Self.quote(remote))"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Channels

    /// The browse passenger, or interactive between its jobs.
    func metadataLink() async throws -> SFTPChannel {
        if let link = await liveLink(.browse) { return link }
        if let link = await liveLink(.interactive) { return link }
        // A live master with no channel is a lost connection, which callers retry.
        throw master?.isRunning == true ? TransferError.connectionLost("The SFTP channels closed") : TransferError.notConnected
    }

    /// A reserved passenger, reopened when it has died, at most once every 5 s. Nil when down.
    func liveLink(_ role: ChannelRole) async -> SFTPChannel? {
        if let current = reserved[role], await current.isOpen { return current }
        guard master?.isRunning == true else { return nil }
        let now = ContinuousClock.now
        if let last = reopenedAt[role], now - last < .seconds(5) { return nil }
        reopenedAt[role] = now
        let generation = generation
        guard let link = try? await openLink() else { return nil }
        guard generation == self.generation else {
            await link.closeLink()
            return nil
        }
        reserved[role] = link
        return link
    }

    func withInteractive<T>(_ body: (SFTPChannel) async throws -> T) async throws -> T {
        if let link = await liveLink(.interactive) { return try await body(link) }
        return try await withData(body)
    }

    func withData<T>(_ body: (SFTPChannel) async throws -> T) async throws -> T {
        let link = try await acquire()
        defer { release(link) }
        return try await body(link)
    }

    private func acquire() async throws -> SFTPChannel {
        var open: [SFTPChannel] = []
        for link in pool where await link.isOpen { open.append(link) }
        pool = open
        if let free = pool.first(where: { !busy.contains(ObjectIdentifier($0)) }) {
            busy.insert(ObjectIdentifier(free))
            return free
        }
        if pool.count < Self.dataChannels, !poolRefused, master?.isRunning == true {
            do {
                let link = try await openLink()
                pool.append(link)
                busy.insert(ObjectIdentifier(link))
                return link
            } catch {
                poolRefused = true
                if pool.isEmpty { throw error }
            }
        }
        guard !pool.isEmpty else { throw TransferError.notConnected }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    private func release(_ link: SFTPChannel) {
        let id = ObjectIdentifier(link)
        busy.remove(id)
        guard !waiters.isEmpty else { return }
        busy.insert(id)
        waiters.removeFirst().resume(returning: link)
    }

    /// A passenger on the master. It gives up when the server has not started SFTP within 15 s,
    /// as when a shell startup file prints text ahead of it, or when the caller is cancelled.
    private func openLink() async throws -> SFTPChannel {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // With -s the subsystem name is the command argument, so it must follow the destination.
        // BatchMode: if the master is gone, ssh falls back to a login of its own, which must not prompt.
        process.arguments = configArguments + ["-S", socketPath, "-o", "Compression=no", "-o", "ControlMaster=no", "-o", "BatchMode=yes"]
            + Self.plainSession + ["-s", "--", connection.destination, "sftp"]
        let input = Pipe()
        let output = Pipe()
        let errors = OutputTail(limit: 1024)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors.pipe
        // A channel whose ssh has exited makes the next write fail with EPIPE, which the link
        // reports as a lost connection and a transfer retries; the default SIGPIPE would end
        // the whole app before the write returned.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        let link = SFTPChannel(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading)
        await link.start()
        let timedOut = Locked(false)
        let watchdog = Task {
            try await Task.sleep(for: Self.handshakeTimeout)
            timedOut.value = true
            await link.closeLink()
        }
        defer { watchdog.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await link.handshake()
            } onCancel: {
                Task { await link.closeLink() }
            }
        } catch {
            await link.closeLink()
            if timedOut.value {
                throw TransferError.failed("The server did not start SFTP within 15 s. A shell startup file that prints text can cause this.")
            }
            if Task.isCancelled { throw TransferError.cancelled }
            await errors.waitForEnd()
            let line = errors.lastLine
            throw line.isEmpty ? error : TransferError.connectionLost(line)
        }
        return link
    }

    /// Forgets a recorded temp only once it is gone from the server.
    private func removeRecordedRemoteTemps() async {
        for path in store.remoteTemps(connection: connection.id) {
            do {
                try await metadataLink().removeFile(RemotePath(string: path))
                store.forgetTemp(path)
            } catch TransferError.noSuchFile {
                store.forgetTemp(path)
            } catch {
                continue
            }
        }
    }

    // MARK: Arguments

    /// For every ssh that joins or runs on the server: `~/.ssh/config` may name a remote command, a
    /// TTY, forwards, or a local command for the host, meant for the user's own logins. Any of them
    /// breaks an SFTP passenger or makes the master hold the user's forwarded ports.
    private static let plainSession = [
        "-o", "RemoteCommand=none",
        "-o", "RequestTTY=no",
        "-o", "ClearAllForwardings=yes",
        "-o", "PermitLocalCommand=no",
    ]

    /// Paths go through flags (`-i`, `-S`) or quoted `-o` values: ssh splits a bare `-o` value on
    /// spaces, and the library lives under "Application Support".
    private var destinationArguments: [String] {
        var arguments: [String] = []
        if !connection.port.isEmpty { arguments += ["-p", connection.port] }
        if !connection.identityFile.isEmpty {
            arguments += ["-i", connection.identityFile, "-o", "IdentitiesOnly=yes"]
        }
        return arguments
    }

    private static func quotedOption(_ name: String, _ path: String) -> [String] {
        ["-o", "\(name)=\"\(path.replacingOccurrences(of: "\"", with: "\\\""))\""]
    }

    private func masterArguments(_ hostKeyArguments: [String]) -> [String] {
        var arguments = [
            "-N",
            "-o", "ControlMaster=yes",
            // A ControlPersist or ForkAfterAuthentication in ~/.ssh/config would fork the master
            // into the background, where this process can neither watch nor stop it.
            "-o", "ControlPersist=no",
            "-o", "ForkAfterAuthentication=no",
            "-o", "Compression=no",
            // A dead network is noticed in about 45 s instead of hanging every request on it.
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-S", socketPath,
            "-o", "StrictHostKeyChecking=yes",
        ]
        arguments += Self.plainSession
        arguments += hostKeyArguments
        arguments += destinationArguments
        arguments += ["--", connection.destination]
        return configArguments + arguments
    }

    private var configArguments: [String] {
        sshConfigFile.map { ["-F", $0] } ?? []
    }

    private func ssh(_ arguments: [String], environment: [String: String]? = nil, timeout: Duration) async throws -> Subprocess.Result {
        try await Subprocess.run("/usr/bin/ssh", configArguments + arguments, environment: environment, timeout: timeout)
    }

    // MARK: Host keys

    /// After ssh refused the host key: learns the key the server offers with a probe that reads no
    /// known-hosts file, asks the user, and returns the arguments for the master's second try.
    /// Always Trust and Replace write the first user file `ssh -G` names; Trust Once hands the
    /// master the probe's file, removed on disconnect.
    private func trustHostKey(_ failure: HostKeyFailure, prompts: any PromptSink, ask: URL, holding held: inout Held) async throws -> [String] {
        let values = SSHConfigValues.parse(await SSHResolver.config(for: connection, configFile: sshConfigFile) ?? "")
        let probeDirectory = store.root.appendingPathComponent("hostkey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: probeDirectory) } }
        let probeFile = probeDirectory.appendingPathComponent("known_hosts")
        // No authentication, so it never logs in; the askpass environment lets a ProxyJump host ask.
        let probeArguments = Self.quotedOption("UserKnownHostsFile", probeFile.path) + [
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "KnownHostsCommand=none",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "HashKnownHosts=no",
            "-o", "PasswordAuthentication=no",
            "-o", "PubkeyAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ConnectTimeout=15",
        ] + Self.plainSession + destinationArguments + ["--", connection.destination, "true"]
        var probe = try await ssh(probeArguments, environment: askEnvironment(ask), timeout: .seconds(30))
        for drop in 1...2 where !FileManager.default.fileExists(atPath: probeFile.path) && Self.droppedBeforeLogin(probe.stderr.lastLine) {
            try await Task.sleep(for: .milliseconds(500 * drop))
            probe = try await ssh(probeArguments, environment: askEnvironment(ask), timeout: .seconds(30))
        }
        let text = (try? String(contentsOf: probeFile, encoding: .utf8)) ?? ""
        guard let offered = text.split(separator: "\n").compactMap({ HostKeyLine(line: String($0)) }).first else {
            let reason = probe.stderr.lastLine
            throw TransferError.failed("Could not read the host key: \(reason.isEmpty ? "no reply" : reason)")
        }
        let event = HostKeyEvent(situation: failure == .changed ? .changed : .firstSeen, keyType: offered.keyType, fingerprint: Self.fingerprint(offered.key), line: offered.text)
        switch try await Self.untilCancelled({ await prompts.decideHostKey(event) }) {
        case .cancel:
            throw TransferError.hostKeyRejected
        case .trustOnce:
            keep = true
            held.scratch.append(probeDirectory)
            return Self.quotedOption("UserKnownHostsFile", probeFile.path)
        case .alwaysTrust, .replace:
            let userFiles = (values["userknownhostsfile"] ?? "").split(separator: " ").map(String.init)
            guard let target = userFiles.first, target != "/dev/null", target != "none" else {
                pipe.emit(.notice("Trusted for this login only: the SSH configuration names no known_hosts file to save the key in"))
                keep = true
                held.scratch.append(probeDirectory)
                return Self.quotedOption("UserKnownHostsFile", probeFile.path)
            }
            if failure == .changed {
                for file in userFiles where FileManager.default.fileExists(atPath: file) {
                    for host in offered.host.split(separator: ",") {
                        _ = try? await Subprocess.run("/usr/bin/ssh-keygen", ["-R", String(host), "-f", file], timeout: .seconds(5))
                    }
                }
            }
            try Self.append(Self.knownHostsLines(offered, hashed: values["hashknownhosts"] == "yes"), to: target)
            return []
        }
    }

    /// The lines for known_hosts, one per host name hashed as ssh's `HashKnownHosts` does when
    /// `hashed`: `|1|salt|HMAC-SHA1(salt, name)`.
    static func knownHostsLines(_ offered: HostKeyLine, hashed: Bool) -> [String] {
        guard hashed else { return [offered.text] }
        return offered.host.split(separator: ",").map { name in
            let salt = SymmetricKey(size: .init(bitCount: 160))
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(name.utf8), using: salt)
            let saltText = salt.withUnsafeBytes { Data($0).base64EncodedString() }
            return "|1|\(saltText)|\(Data(mac).base64EncodedString()) \(offered.keyType) \(offered.key)"
        }
    }

    /// Appends in one `O_APPEND` write, so two logins trusting at once never overwrite each other.
    private static func append(_ lines: [String], to path: String) throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(path, O_RDWR | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw TransferError.failed("Could not open \(path)") }
        defer { close(fd) }
        var last: UInt8 = 0x0A
        let size = lseek(fd, 0, SEEK_END)
        if size > 0 { _ = pread(fd, &last, 1, size - 1) }
        let bytes = Array(((last == 0x0A ? "" : "\n") + lines.joined(separator: "\n") + "\n").utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else { throw TransferError.failed("Could not write \(path)") }
    }

    /// `SHA256:` and the unpadded base64 digest of the key blob, as ssh prints it.
    static func fingerprint(_ key: String) -> String {
        guard let blob = Data(base64Encoded: key) else { return key }
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// `body`'s answer, or `.cancelled` as soon as the calling task is cancelled. A prompt sheet
    /// cannot be withdrawn; its late answer is dropped.
    private static func untilCancelled<T: Sendable>(_ body: @escaping @Sendable () async -> T) async throws -> T {
        let slot = Locked<CheckedContinuation<T, Error>?>(nil)
        let take: @Sendable () -> CheckedContinuation<T, Error>? = { slot.withLock { waiting in defer { waiting = nil }; return waiting } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                slot.value = continuation
                if Task.isCancelled {
                    take()?.resume(throwing: TransferError.cancelled)
                    return
                }
                Task {
                    let answer = await body()
                    take()?.resume(returning: answer)
                }
            }
        } onCancel: {
            take()?.resume(throwing: TransferError.cancelled)
        }
    }

    // MARK: Askpass

    /// Prefixes of the per-login files and folders under the library root: askpass folders and
    /// host-key probes. `key-` is what 0.1.7 left for a fingerprint.
    static let loginScratchPrefixes = ["ask-", "hostkey-", "key-"]

    /// Removes per-login scratch left under `root` by a session that never disconnected: the app
    /// crashed or was force-quit. The hub calls this at launch, before any session exists; the app
    /// runs as a single instance, so nothing found here is in use.
    static func removeLoginScratch(in root: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where loginScratchPrefixes.contains(where: { name.hasPrefix($0) }) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    private func prepareAskpass() throws -> URL {
        let directory = store.root.appendingPathComponent("ask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try writeAskpass(in: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return directory
    }

    /// The helper ssh runs for each prompt. It gives up with the login (`loginTimeout`) or as soon
    /// as its folder is removed, so none outlives a login that ended.
    private func writeAskpass(in directory: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let script = directory.appendingPathComponent("askpass.sh")
        let ticks = Self.loginTimeout.components.seconds * 10
        let source = """
        #!/bin/sh
        dir="$TRANSFER_ASK_DIR"
        umask 077
        printf '%s' "$1" > "$dir/prompt" || exit 1
        i=0
        while [ ! -f "$dir/reply" ]; do
          i=$((i+1))
          if [ "$i" -gt \(ticks) ] || [ ! -d "$dir" ]; then exit 1; fi
          sleep 0.1
        done
        cat "$dir/reply"
        rm -f "$dir/prompt" "$dir/reply"
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }

    private func askEnvironment(_ directory: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = directory.appendingPathComponent("askpass.sh").path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["TRANSFER_ASK_DIR"] = directory.path
        environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
        return environment
    }

    /// Answers ssh's prompts for one login. The Keychain secret answers only this server's own
    /// password prompt (or a key's passphrase), never a ProxyJump host's, and only once: a second
    /// prompt means it was wrong, so the user is asked and may save a new one. Cancel stops ssh.
    private func servePrompts(_ prompts: any PromptSink, directory: URL, ssh: Locked<Process?>, refused: Locked<Bool>) async {
        let prompt = directory.appendingPathComponent("prompt")
        let reply = directory.appendingPathComponent("reply")
        let account = connection.id.rawValue.uuidString
        var storedTried = false
        var target: (user: String, host: String)?
        while !Task.isCancelled {
            if let text = try? String(contentsOf: prompt, encoding: .utf8), !text.isEmpty {
                try? FileManager.default.removeItem(at: prompt)
                if target == nil { target = await passwordTarget() }
                let secret = target.map { Self.takesStoredSecret(text, user: $0.user, host: $0.host) } ?? false
                let answer: PromptReply
                if secret, !storedTried, let stored = KeychainStore.load(account: account) {
                    storedTried = true
                    answer = PromptReply(text: stored)
                } else {
                    guard let asked = try? await Self.untilCancelled({ await prompts.answer(PromptRequest(text: text, offerKeychain: secret)) }) else { return }
                    answer = asked
                }
                guard let text = answer.text else {
                    refused.value = true
                    ssh.value?.terminate()
                    return
                }
                if answer.saveInKeychain { KeychainStore.save(account: account, secret: text) }
                try? text.write(to: reply, atomically: true, encoding: .utf8)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The user and host ssh names in this server's password prompt: `user@host's password:`, or
    /// `(user@host) Password:` for keyboard-interactive.
    private func passwordTarget() async -> (user: String, host: String) {
        let values = SSHConfigValues.parse(await SSHResolver.config(for: connection, configFile: sshConfigFile) ?? "")
        let alias = values["hostkeyalias"].flatMap { $0 == "none" ? nil : $0 }
        return (values["user"] ?? connection.user, alias ?? values["hostname"] ?? connection.host)
    }

    /// Whether a stored secret may answer `prompt`: this server's own password prompt, or a
    /// passphrase for a key, which never leaves the Mac.
    static func takesStoredSecret(_ prompt: String, user: String, host: String) -> Bool {
        if prompt.hasPrefix("Enter passphrase for") { return true }
        return prompt.contains("\(user)@\(host)") && prompt.lowercased().contains("password")
    }
}

/// Why ssh refused a login over the host key, read from its error output.
enum HostKeyFailure: Equatable {
    case unknown
    case changed
    case revoked

    init?(sshErrors text: String) {
        if text.contains("REVOKED HOST KEY") || text.contains("was revoked") {
            self = .revoked
        } else if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || text.contains("has changed and you have requested strict checking") {
            self = .changed
        } else if text.contains("Host key verification failed") {
            self = .unknown
        } else {
            return nil
        }
    }
}

/// The reserved passengers, opened at login. Data channels open on demand and have no role.
enum ChannelRole {
    case browse
    case interactive
    case walker
}

extension SSHConnection: LiveServer {
    func liveLookup(_ path: RemotePath) async throws -> RemoteItem? {
        try await existing(path)
    }

    func liveFetch(_ item: RemoteItem, to local: URL, interactive: Bool) async throws {
        if interactive {
            try await lane.submit(.open) { try await self.fetch(item.path, info: item, to: local) { _ in } }
        } else {
            try await fetch(item.path, info: item, to: local) { _ in }
        }
    }

    func liveSave(_ snapshot: URL, to path: RemotePath, expecting: ServerExpectation, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> Fingerprint {
        // Carries the fingerprint out of the lane's closure.
        let written = Locked<Fingerprint?>(nil)
        try await lane.submit(.save) {
            written.value = try await self.uploadBytes(snapshot, to: path, interactive: true, expecting: expecting, measure: true, progress: progress)
        }
        guard let print = written.value else { throw TransferError.failed("The server did not report the saved file") }
        return print
    }

    func liveNames(in folder: RemotePath) async throws -> Set<String> {
        try await listedNames(folder)
    }

    nonisolated func liveEmit(_ event: SessionEvent) {
        pipe.emit(event)
    }
}

final class EventPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]

    func stream() -> AsyncStream<SessionEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            subscribers[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subscribers[id] = nil
                self.lock.unlock()
            }
        }
    }

    func emit(_ event: SessionEvent) {
        lock.lock()
        let targets = Array(subscribers.values)
        lock.unlock()
        for target in targets { target.yield(event) }
    }
}

extension RemotePath {
    /// The path with `prefix` swapped for `replacement` when this path is `prefix` or lies under it.
    func replacing(prefix: RemotePath, with replacement: RemotePath) -> RemotePath? {
        if bytes == prefix.bytes { return replacement }
        let head = prefix.isRoot ? prefix.bytes : prefix.bytes + [0x2F]
        guard bytes.count > head.count, Array(bytes[..<head.count]) == head else { return nil }
        return RemotePath(bytes: replacement.bytes + [0x2F] + Array(bytes[head.count...]))
    }
}
