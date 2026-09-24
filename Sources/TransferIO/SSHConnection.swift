import Foundation
import TransferCore

public actor SSHConnection: RemoteSession {
    public nonisolated let connection: SavedConnection

    let store: Store
    private(set) var editableExtensions: Set<String>
    private(set) var promptSink: (any PromptSink)?
    private var master: Process?
    private var socketPath = ""
    /// Per-login folders under the library root, removed on disconnect. Lists, not single values:
    /// two windows can start a login on one connection at once, and neither may orphan the other's.
    private var askDirectories: [URL] = []
    private var onceKnownHosts: [URL] = []
    private var startPath: RemotePath?
    private var browse: SFTPChannel?
    private var interactive: SFTPChannel?
    private var walker: SFTPChannel?
    private var reopened: Set<ChannelRole> = []
    private var pool: [SFTPChannel] = []
    private var busy: Set<ObjectIdentifier> = []
    private var waiters: [CheckedContinuation<SFTPChannel, Error>] = []
    private var poolRefused = false
    private var prompted = false
    let pipe = EventPipe()
    let lane = InteractiveLane()
    /// Live files are `LiveSync`'s; this connection is its `LiveServer` and forwards the Live API.
    let live: LiveSync
    private let ownsLive: Bool

    /// The hub passes its one `LiveSync`. Without one, as in tests, the connection makes its own
    /// and closes it on disconnect.
    init(connection: SavedConnection, store: Store, editableExtensions: Set<String>, live: LiveSync? = nil) {
        self.connection = connection
        self.store = store
        self.editableExtensions = editableExtensions
        self.live = live ?? LiveSync(store: store)
        ownsLive = live == nil
    }

    public nonisolated func events() -> AsyncStream<SessionEvent> { pipe.stream() }

    func setEditableExtensions(_ extensions: Set<String>) {
        editableExtensions = extensions
    }

    public var isConnected: Bool { startPath != nil && master?.isRunning == true }
    public var unsyncedLiveCount: Int { get async { await live.unsyncedCount(on: connection.id) } }

    // MARK: Login

    public func connect(prompts: any PromptSink) async throws -> RemotePath {
        if let startPath, master?.isRunning == true { return startPath }
        await disconnect()
        promptSink = prompts
        prompted = false
        let directory = store.root.appendingPathComponent("ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        socketPath = directory.appendingPathComponent(connection.id.socketName).path
        if FileManager.default.fileExists(atPath: socketPath) {
            _ = try? await run(arguments: ["-S", socketPath, "-O", "exit", "--", connection.destination], timeout: 3)
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        let hostKeyArguments = try await resolveHostKey(prompts)
        let ask: URL
        do {
            ask = try prepareAskpass()
        } catch {
            await disconnect()
            throw error
        }
        askDirectories.append(ask)
        let poller = Task { await self.servePrompts(prompts, directory: ask) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = masterArguments(hostKeyArguments)
        process.environment = askEnvironment(ask)
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            poller.cancel()
            await disconnect()
            throw TransferError.failed("Could not start ssh")
        }
        master = process
        let ready = await waitForSocket(process)
        poller.cancel()
        guard ready else {
            let text = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let line = text.split(separator: "\n").last.map(String.init) ?? "Login failed"
            await disconnect()
            if text.contains("Host key verification failed") || text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
                throw TransferError.hostKeyRejected
            }
            throw TransferError.authenticationFailed(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.masterEnded() }
        }
        let resolved: RemotePath
        do {
            browse = try await openLink(.browse)
            interactive = try? await openLink(.interactive)
            walker = try? await openLink(.walker)
            let start = connection.remotePath.isEmpty ? RemotePath(string: ".") : RemotePath(string: connection.remotePath)
            resolved = try await requireBrowse().realpath(start)
        } catch {
            await disconnect()
            throw error
        }
        startPath = resolved
        await removeRecordedRemoteTemps()
        await live.connected(connection.id, server: self)
        return resolved
    }

    public func disconnect() async {
        if ownsLive { await live.closeAll() } else { await live.disconnected(connection.id, server: self) }
        for link in [browse, interactive, walker].compactMap({ $0 }) + pool {
            await link.closeLink()
        }
        browse = nil
        interactive = nil
        walker = nil
        reopened.removeAll()
        pool.removeAll()
        busy.removeAll()
        poolRefused = false
        for waiter in waiters { waiter.resume(throwing: TransferError.cancelled) }
        waiters.removeAll()
        if let master {
            master.terminationHandler = nil
            if master.isRunning {
                if !socketPath.isEmpty {
                    _ = try? await run(arguments: ["-S", socketPath, "-O", "exit", "--", connection.destination], timeout: 3)
                }
                master.terminate()
            }
        }
        master = nil
        if !socketPath.isEmpty { try? FileManager.default.removeItem(atPath: socketPath) }
        for file in onceKnownHosts { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        onceKnownHosts.removeAll()
        for folder in askDirectories { try? FileManager.default.removeItem(at: folder) }
        askDirectories.removeAll()
        startPath = nil
    }

    private func masterEnded() async {
        guard master != nil, startPath != nil else { return }
        await disconnect()
        pipe.emit(.disconnected("The SSH connection to \(connection.displayName) closed"))
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

    public func recents() async -> [RemotePath] {
        store.recents(connection: connection.id).map(RemotePath.init(string:))
    }

    public func remember(_ path: RemotePath) async {
        store.remember(connection: connection.id, path: path.display)
    }

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
        return "/usr/bin/ssh -S \(Self.quote(socketPath)) -o Compression=no -t -- \(Self.quote(connection.destination)) \(Self.quote(remote))"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Channels

    private func requireBrowse() throws -> SFTPChannel {
        guard let browse else { throw TransferError.notConnected }
        return browse
    }

    /// The browse passenger, or interactive between its jobs.
    func metadataLink() async throws -> SFTPChannel {
        if let link = await liveLink(.browse) { return link }
        if let link = await liveLink(.interactive) { return link }
        throw TransferError.notConnected
    }

    /// A reserved passenger, reopened once after it dies. Nil when down.
    func liveLink(_ role: ChannelRole) async -> SFTPChannel? {
        let current: SFTPChannel?
        switch role {
        case .browse: current = browse
        case .interactive: current = interactive
        case .walker: current = walker
        case .data: return nil
        }
        if let current, await current.isOpen { return current }
        guard master?.isRunning == true, !reopened.contains(role) else { return nil }
        reopened.insert(role)
        guard let link = try? await openLink(role) else { return nil }
        switch role {
        case .browse: browse = link
        case .interactive: interactive = link
        case .walker: walker = link
        case .data: break
        }
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
        if pool.count < 7, !poolRefused {
            do {
                let link = try await openLink(.data)
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

    private func openLink(_ role: ChannelRole) async throws -> SFTPChannel {
        guard master?.isRunning == true else { throw TransferError.notConnected }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // With -s the subsystem name is the command argument, so it must follow the destination.
        process.arguments = ["-S", socketPath, "-o", "Compression=no", "-o", "ControlMaster=no", "-s", "--", connection.destination, "sftp"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A channel whose ssh has exited makes the next write fail with EPIPE, which the link
        // reports as a lost connection and a transfer retries; the default SIGPIPE would end
        // the whole app before the write returned.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        let chunks = ChunkPipe()
        let link = SFTPChannel(
            role: role,
            process: process,
            input: input.fileHandleForWriting,
            output: output.fileHandleForReading,
            chunks: chunks
        )
        await link.start()
        do {
            try await link.handshake()
        } catch {
            await link.closeLink()
            throw error
        }
        return link
    }

    private func removeRecordedRemoteTemps() async {
        for path in store.remoteTemps(connection: connection.id) {
            try? await metadataLink().removeFile(RemotePath(string: path))
            store.forgetTemp(path)
        }
    }

    // MARK: Host keys

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
            "-o", "Compression=no",
            // A dead network is noticed in about 45 s instead of hanging every request on it.
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-S", socketPath,
            "-o", "StrictHostKeyChecking=yes",
        ]
        arguments += hostKeyArguments
        arguments += destinationArguments
        arguments += ["--", connection.destination]
        return arguments
    }

    /// Learns the offered key with a no-auth ssh run, compares it with the known-hosts files `ssh -G`
    /// reports, and asks the user when it is new or changed. Returns extra ssh arguments for the master.
    private func resolveHostKey(_ prompts: any PromptSink) async throws -> [String] {
        let config = try await run(arguments: ["-G"] + destinationArguments + ["--", connection.destination], timeout: 5)
        let files = KnownHosts.files(sshConfigOutput: config.stdout)
        let probeDirectory = store.root.appendingPathComponent("hostkey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        let probeFile = probeDirectory.appendingPathComponent("known_hosts")
        let probe: CommandResult
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: probeDirectory.path)
            probe = try await run(arguments: Self.quotedOption("UserKnownHostsFile", probeFile.path) + [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "HashKnownHosts=no",
                "-o", "BatchMode=yes",
                "-o", "PasswordAuthentication=no",
                "-o", "PubkeyAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "ControlMaster=no",
                "-o", "ControlPath=none",
                "-o", "Compression=no",
                "-o", "ConnectTimeout=15",
            ] + destinationArguments + ["--", connection.destination, "true"], timeout: 30)
        } catch {
            try? FileManager.default.removeItem(at: probeDirectory)
            throw error
        }
        let text = (try? String(contentsOf: probeFile, encoding: .utf8)) ?? ""
        let offered = text.split(separator: "\n").compactMap { HostKeyLine(line: String($0)) }.first
        guard let offered else {
            try? FileManager.default.removeItem(at: probeDirectory)
            let reason = probe.stderr.split(separator: "\n").last.map(String.init) ?? "no reply"
            throw TransferError.failed("Could not read the host key: \(reason)")
        }
        var stored: [HostKeyLine] = []
        for file in files where FileManager.default.fileExists(atPath: file) {
            let found = try? await run(launch: "/usr/bin/ssh-keygen", arguments: ["-F", offered.host, "-f", file], timeout: 5)
            stored += KnownHosts.entries(keygenOutput: found?.stdout ?? "")
        }
        let situation = KnownHosts.situation(offered: offered, stored: stored)
        if situation == .unchanged {
            try? FileManager.default.removeItem(at: probeDirectory)
            return []
        }
        let fingerprint = await fingerprint(offered.text)
        let event = HostKeyEvent(situation: situation, keyType: offered.keyType, fingerprint: fingerprint, line: offered.text)
        switch await prompts.decideHostKey(event) {
        case .cancel:
            try? FileManager.default.removeItem(at: probeDirectory)
            throw TransferError.hostKeyRejected
        case .trustOnce:
            onceKnownHosts.append(probeFile)
            return Self.quotedOption("UserKnownHostsFile", probeFile.path)
        case .alwaysTrust, .replace:
            try? FileManager.default.removeItem(at: probeDirectory)
            guard let target = files.first else { throw TransferError.failed("ssh reports no known_hosts file") }
            if situation == .changed {
                for file in files where FileManager.default.fileExists(atPath: file) {
                    _ = try? await run(launch: "/usr/bin/ssh-keygen", arguments: ["-R", offered.host, "-f", file], timeout: 5)
                }
            }
            let folder = (target as NSString).deletingLastPathComponent
            if !FileManager.default.fileExists(atPath: folder) {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            if !FileManager.default.fileExists(atPath: target) {
                FileManager.default.createFile(atPath: target, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: target))
            defer { try? handle.close() }
            try handle.seekToEnd()
            let existing = (try? String(contentsOfFile: target, encoding: .utf8)) ?? ""
            let prefix = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            try handle.write(contentsOf: Data((prefix + offered.text + "\n").utf8))
            return []
        }
    }

    private func fingerprint(_ line: String) async -> String {
        let file = store.root.appendingPathComponent("key-\(UUID().uuidString)").path
        try? line.write(toFile: file, atomically: true, encoding: .utf8)
        let result = try? await run(launch: "/usr/bin/ssh-keygen", arguments: ["-lf", file], timeout: 3)
        try? FileManager.default.removeItem(atPath: file)
        let parts = result?.stdout.split(separator: " ") ?? []
        return parts.count > 1 ? String(parts[1]) : line
    }

    // MARK: Askpass

    /// Prefixes of the per-login files and folders under the library root: askpass folders, host-key
    /// probes, and fingerprint scratch files.
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

    private func writeAskpass(in directory: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let script = directory.appendingPathComponent("askpass.sh")
        let source = """
        #!/bin/sh
        dir="$TRANSFER_ASK_DIR"
        umask 077
        printf '%s' "$1" > "$dir/prompt"
        i=0
        while [ ! -f "$dir/reply" ]; do
          i=$((i+1))
          if [ "$i" -gt 6000 ]; then exit 1; fi
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

    private func servePrompts(_ prompts: any PromptSink, directory: URL) async {
        let prompt = directory.appendingPathComponent("prompt")
        let reply = directory.appendingPathComponent("reply")
        while !Task.isCancelled {
            if FileManager.default.fileExists(atPath: prompt.path),
               let text = try? String(contentsOf: prompt, encoding: .utf8), !text.isEmpty {
                let account = connection.id.rawValue.uuidString
                let stored = KeychainStore.load(account: account)
                let answer: PromptReply
                if !prompted, let stored {
                    answer = PromptReply(text: stored)
                } else {
                    answer = await prompts.answer(PromptRequest(text: text, offerKeychain: !prompted))
                }
                prompted = true
                if answer.saveInKeychain, let text = answer.text {
                    KeychainStore.save(account: account, secret: text)
                }
                guard let text = answer.text else {
                    master?.terminate()
                    return
                }
                try? FileManager.default.removeItem(at: prompt)
                try? text.write(to: reply, atomically: true, encoding: .utf8)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func waitForSocket(_ process: Process) async -> Bool {
        for _ in 0..<3000 {
            if FileManager.default.fileExists(atPath: socketPath) { return true }
            if !process.isRunning { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return FileManager.default.fileExists(atPath: socketPath)
    }

    // MARK: Processes

    private func run(arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        try await run(launch: "/usr/bin/ssh", arguments: arguments, timeout: timeout)
    }

    private func run(launch: String, arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let flag = TimeoutFlag()
        try process.run()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled, process.isRunning {
                flag.fired = true
                process.terminate()
            }
        }
        let result: CommandResult = await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: CommandResult(code: process.terminationStatus, stdout: stdout, stderr: stderr))
            }
        }
        watchdog.cancel()
        if flag.fired { throw TransferError.timeout((launch as NSString).lastPathComponent) }
        return result
    }
}

/// The SFTP channels on one master: three reserved passengers opened at login, and data channels
/// opened on demand.
enum ChannelRole {
    case browse
    case interactive
    case walker
    case data
}

private struct CommandResult {
    var code: Int32
    var stdout: String
    var stderr: String
}

private final class TimeoutFlag: @unchecked Sendable {
    var fired = false
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
        let written = WrittenBox()
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

/// Carries a save's fingerprint out of the interactive lane's closure.
private final class WrittenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Fingerprint?
    var value: Fingerprint? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
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
