import Foundation
import TransferCore

public actor SSHConnection: RemoteSession {
    private let store: Store
    private let editableExtensions: Set<String>
    private var promptSink: (any PromptSink)?
    private var saved: SavedConnection?
    private var master: Process?
    private var socketPath = ""
    private var askDirectory: URL?
    private var browse: SFTPLink?
    private var interactive: SFTPLink?
    private var walker: SFTPLink?
    private var pool: [SFTPLink] = []
    private var busy: Set<ObjectIdentifier> = []
    private var waiters: [CheckedContinuation<SFTPLink, Error>] = []
    private var performance = false
    private var prompted = false
    private let pipe = EventPipe()
    private var lives: [String: LiveRecord] = [:]
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]

    public init() throws {
        store = try Store()
        editableExtensions = ConfigLoader.load(root: store.root).extensionSet
        let temps = store.temps()
        for path in temps where FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
            store.forgetTemp(path)
        }
    }

    public nonisolated func events() -> AsyncStream<SessionEvent> { pipe.stream }

    public func savedConnections() async throws -> [SavedConnection] { store.connections() }
    public func save(_ connection: SavedConnection) async throws { store.save(connection) }
    public func removeConnection(_ id: ConnectionID) async throws {
        store.remove(id)
        KeychainStore.delete(account: id.rawValue.uuidString)
    }

    public var performanceModeEnabled: Bool { performance }
    public var livePaths: Set<RemotePath> { Set(lives.values.map(\.path)) }

    public func connect(_ connection: SavedConnection, prompts: any PromptSink) async throws -> RemotePath {
        await disconnect()
        saved = connection
        promptSink = prompts
        prompted = false
        let directory = store.root.appendingPathComponent("ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        socketPath = directory.appendingPathComponent(connection.id.rawValue.uuidString).path
        if FileManager.default.fileExists(atPath: socketPath) {
            _ = try? await run(arguments: ["-S", socketPath, "-O", "exit", connection.destination], timeout: 3)
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        let known = try await resolveHostKey(connection, prompts: prompts)
        let ask = try prepareAskpass()
        askDirectory = ask
        let poller = Task { await self.servePrompts(prompts, directory: ask) }
        let arguments = masterArguments(connection, knownHosts: known)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.environment = askEnvironment(ask)
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            poller.cancel()
            throw TransferError.failed("Could not start ssh")
        }
        master = process
        let ready = await waitForSocket(process)
        poller.cancel()
        guard ready else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Login failed"
            await disconnect()
            throw TransferError.authenticationFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        performance = await probe() && PerformanceDirectoryCopy.available()
        browse = try await openLink(.browse)
        interactive = try? await openLink(.interactive)
        walker = try? await openLink(.walker)
        let start = connection.remotePath.isEmpty ? RemotePath(string: ".") : RemotePath(string: connection.remotePath)
        return try await requireBrowse().realpath(start)
    }

    public func disconnect() async {
        for link in [browse, interactive, walker].compactMap({ $0 }) + pool {
            await link.closeLink()
        }
        browse = nil
        interactive = nil
        walker = nil
        pool.removeAll()
        busy.removeAll()
        for waiter in waiters { waiter.resume(throwing: TransferError.cancelled) }
        waiters.removeAll()
        if let master, master.isRunning {
            if !socketPath.isEmpty, let saved {
                _ = try? await run(arguments: ["-S", socketPath, "-O", "exit", saved.destination], timeout: 3)
            }
            master.terminate()
        }
        master = nil
        performance = false
        saved = nil
    }

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
    }

    public func rename(_ source: RemotePath, to destination: RemotePath) async throws {
        try await metadataLink().rename(source, to: destination)
    }

    public func remove(_ path: RemotePath) async throws {
        let item = try await stat(path)
        if item.kind == .directory {
            for try await child in list(path) {
                try await remove(child.path)
            }
            try await metadataLink().removeDirectory(path)
        } else {
            try await metadataLink().removeFile(path)
        }
    }

    public func download(_ path: RemotePath, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let info = try await stat(path)
        if info.kind == .directory {
            try await copyDirectory(from: path, to: destination, progress: progress)
            return
        }
        if info.kind == .symlink {
            let target = try await readlink(path)
            try target.write(to: destination, atomically: true, encoding: .utf8)
            return
        }
        try await withData { link in
            try await link.download(path, to: destination, size: info.size, progress: progress)
        }
    }

    public func upload(_ source: URL, to destination: RemotePath, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue {
            try await copyDirectory(fromLocal: source, to: destination, progress: progress)
            return
        }
        let placed = try await resolvedUploadDestination(source, proposed: destination)
        guard let placed else { return }
        let base = String(decoding: placed.nameBytes, as: UTF8.self)
        let temp = placed.parent?.appending(name: Array(CopyRules.tempName(for: base, transferID: UUID().uuidString).utf8)) ?? placed
        store.rememberTemp(temp.display)
        do {
            try await withData { link in
                try await link.upload(source, to: temp, progress: progress)
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
            let mode = (attributes?[.posixPermissions] as? NSNumber)?.uint32Value
            let mtime = (attributes?[.modificationDate] as? Date).map { UInt32($0.timeIntervalSince1970) }
            try? await metadataLink().setstat(temp, mode: mode, mtime: mtime)
            try await metadataLink().rename(temp, to: placed)
            store.forgetTemp(temp.display)
        } catch {
            try? await metadataLink().removeFile(temp)
            store.forgetTemp(temp.display)
            throw error
        }
    }

    public func copyDirectory(from remote: RemotePath, to local: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        var completed: UInt64 = 0
        var items = 0
        let link = try walker ?? metadataLink()
        for try await item in await link.list(remote) {
            let child = local.appendingPathComponent(item.name)
            switch item.kind {
            case .directory:
                try await copyDirectory(from: item.path, to: child, progress: progress)
            case .symlink:
                let target = try await readlink(item.path)
                try? FileManager.default.removeItem(at: child)
                try FileManager.default.createSymbolicLink(atPath: child.path, withDestinationPath: target)
            case .file:
                if localFileMatches(child, item: item) {
                    items += 1
                    continue
                }
                let destinationFile = try await collisionFile(child, item: item)
                guard let destinationFile else { continue }
                try await download(item.path, to: destinationFile, progress: { part in
                    progress(part)
                })
                completed += item.size ?? 0
                items += 1
                progress(TransferProgress(completed: completed, itemsCompleted: items))
            case .other:
                continue
            }
        }
    }

    public func copyDirectory(fromLocal local: URL, to remote: RemotePath, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        do {
            try await metadataLink().mkdir(remote)
        } catch {
            if (try? await stat(remote))?.kind != .directory { throw error }
        }
        let children = try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        var completed: UInt64 = 0
        var items = 0
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            let destination = remote.appending(name: Array(child.lastPathComponent.utf8))
            if values.isSymbolicLink == true {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: child.path)
                try await metadataLink().symlink(target: target, link: destination)
            } else if values.isDirectory == true {
                try await copyDirectory(fromLocal: child, to: destination, progress: progress)
            } else {
                try await upload(child, to: destination, progress: progress)
                completed += UInt64(values.fileSize ?? 0)
                items += 1
            }
        }
    }

    public func openKind(fileName: String) async -> OpenKind {
        EditableFile.openKind(fileName: fileName, extensions: editableExtensions)
    }

    public func prepareLiveFile(_ path: RemotePath) async throws -> URL {
        let id = LiveFileID()
        let folder = store.root.appendingPathComponent("Live/\(saved?.id.rawValue.uuidString ?? "none")/\(id.rawValue.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let item = try await stat(path)
        let file = folder.appendingPathComponent(item.name)
        try await download(path, to: file) { _ in }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let record = LiveRecord(id: id, path: path, local: file, base: Fingerprint(item: item))
        lives[path.display] = record
        watch(record)
        return file
    }

    public func prepareViewFile(_ path: RemotePath) async throws -> URL {
        let file = try previewURL(path, ext: "bin")
        try await download(path, to: file) { _ in }
        return file
    }

    public func preparePreview(_ path: RemotePath) async throws -> URL {
        let item = try await stat(path)
        if EditableFile.openKind(fileName: item.name, extensions: editableExtensions) == .live {
            let file = try previewURL(path, ext: "html")
            let data = try await boundedRead(path, limit: 512 * 1024)
            let html = SyntaxPreview.html(text: String(decoding: data, as: UTF8.self), fileName: item.name)
            try html.write(to: file, atomically: true, encoding: .utf8)
            return file
        }
        return try await prepareViewFile(path)
    }

    public func discardLiveFile(_ path: RemotePath, force: Bool) async throws {
        guard let record = lives[path.display] else { return }
        watchers[path.display]?.cancel()
        watchers[path.display] = nil
        if !force, record.dirty { throw TransferError.failed("This Live file has unsynced edits") }
        lives[path.display] = nil
        try? FileManager.default.removeItem(at: record.local.deletingLastPathComponent())
    }

    public func recents() async -> [RemotePath] {
        guard let saved else { return [] }
        return store.recents(connection: saved.id).map(RemotePath.init(string:))
    }

    public func remember(_ path: RemotePath) async {
        guard let saved else { return }
        store.remember(connection: saved.id, path: path.display)
    }

    public func pins() async -> [RemotePath] {
        guard let saved else { return [] }
        return store.pins(connection: saved.id).map(RemotePath.init(string:))
    }

    public func pin(_ path: RemotePath) async {
        guard let saved else { return }
        store.pin(connection: saved.id, path: path.display, on: true)
    }

    public var unsyncedLiveCount: Int { lives.values.filter(\.dirty).count }

    public func duplicate(_ path: RemotePath) async throws {
        let item = try await stat(path)
        guard item.kind == .file, let parent = path.parent else {
            throw TransferError.failed("Only a file can be duplicated")
        }
        let names = try await listedNames(parent)
        let copyName = KeepBothName.duplicate(existing: names, original: item.name)
        let destination = parent.appending(name: Array(copyName.utf8))
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try await download(path, to: scratch) { _ in }
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await upload(scratch, to: destination) { _ in }
    }

    public func resolveLive(_ path: RemotePath, choice: LiveConflictChoice) async throws -> URL? {
        guard var record = lives[path.display] else { throw TransferError.noSuchFile(path.display) }
        let name = String(decoding: path.nameBytes, as: UTF8.self)
        switch choice {
        case .keepRemote:
            try await download(path, to: record.local) { _ in }
            record.base = Fingerprint(item: try await stat(path))
            record.dirty = false
            lives[path.display] = record
            return nil
        case .keepLocal:
            try await upload(record.local, to: path) { _ in }
            record.base = Fingerprint(item: try await stat(path))
            record.dirty = false
            lives[path.display] = record
            return nil
        case .keepBoth:
            let sibling = path.parent?.appending(name: Array("\(name) (from this Mac)".utf8)) ?? path
            try await upload(record.local, to: sibling) { _ in }
            try await download(path, to: record.local) { _ in }
            record.base = Fingerprint(item: try await stat(path))
            record.dirty = false
            lives[path.display] = record
            return nil
        case .compare:
            let server = record.local.deletingLastPathComponent().appendingPathComponent("\(name) (server)")
            try await download(path, to: server) { _ in }
            return server
        }
    }

    public func unpin(_ path: RemotePath) async {
        guard let saved else { return }
        store.pin(connection: saved.id, path: path.display, on: false)
    }

    private func boundedRead(_ path: RemotePath, limit: Int) async throws -> Data {
        let file = try previewURL(path, ext: "part")
        try await withData { link in
            try await link.download(path, to: file, size: UInt64(limit)) { _ in }
        }
        let data = try Data(contentsOf: file)
        return data.prefix(limit)
    }

    private func previewURL(_ path: RemotePath, ext: String) throws -> URL {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transfer/Preview", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let name = path.display.data(using: .utf8)?.base64EncodedString() ?? UUID().uuidString
        return cache.appendingPathComponent("\(name).\(ext)")
    }

    private func watch(_ record: LiveRecord) {
        let descriptor = open(record.local.deletingLastPathComponent().path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .global())
        source.setEventHandler { [weak self] in
            Task { await self?.liveChanged(record.path) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watchers[record.path.display] = source
    }

    private var pending: [String: Task<Void, Never>] = [:]

    private func liveChanged(_ path: RemotePath) async {
        pending[path.display]?.cancel()
        pending[path.display] = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, var record = lives[path.display] else { return }
            let values = try? record.local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let remote = try? await stat(path)
            if let remote, let base = record.base, Fingerprint(item: remote) != base {
                pipe.emit(.conflict(path))
                return
            }
            record.dirty = true
            lives[path.display] = record
            do {
                let title = record.path.display
                let operationID = record.id.rawValue.uuidString
                let events = pipe
                try await upload(record.local, to: path) { progress in
                    events.emit(.operation(TransferOperation(id: operationID, title: title, state: .active, progress: progress)))
                }
                if let updated = try? await stat(path) {
                    record.base = Fingerprint(item: updated)
                    record.dirty = false
                    lives[path.display] = record
                }
                _ = values
            } catch {
                pipe.emit(.notice(error.localizedDescription))
            }
        }
    }

    private func resolvedUploadDestination(_ source: URL, proposed: RemotePath) async throws -> RemotePath? {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let sourceItem = RemoteItem(
            path: proposed,
            kind: .file,
            size: UInt64(values.fileSize ?? 0),
            mtime: UInt32(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        )
        let existing = try? await stat(proposed)
        switch CopyRules.fileDisposition(source: sourceItem, destination: existing, transferID: "place", liveSave: false) {
        case .skip:
            return nil
        case .typeMismatch:
            throw TransferError.typeMismatch(proposed.display)
        case .write:
            return proposed
        case .collide:
            let choice = await promptSink?.resolveCollision(fileName: sourceItem.name) ?? .skip
            switch choice {
            case .skip:
                return nil
            case .replace:
                return proposed
            case .keepBoth:
                let names = try await listedNames(proposed.parent ?? RemotePath(string: "/"))
                let next = KeepBothName.next(existing: names, original: sourceItem.name)
                return (proposed.parent ?? RemotePath(string: "/")).appending(name: Array(next.utf8))
            }
        }
    }

    private func listedNames(_ path: RemotePath) async throws -> Set<String> {
        var names: Set<String> = []
        let link = try metadataLink()
        for try await item in await link.list(path) {
            names.insert(item.name)
        }
        return names
    }

    private func localFileMatches(_ url: URL, item: RemoteItem) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              let date = attrs[.modificationDate] as? Date,
              let remoteSize = item.size,
              let remoteTime = item.mtime else { return false }
        return size == remoteSize && UInt32(date.timeIntervalSince1970) == remoteTime
    }

    private func collisionFile(_ url: URL, item: RemoteItem) async throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let choice = await promptSink?.resolveCollision(fileName: item.name) ?? .skip
        switch choice {
        case .skip:
            return nil
        case .replace:
            return url
        case .keepBoth:
            let folder = url.deletingLastPathComponent()
            let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            let next = KeepBothName.next(existing: existing, original: item.name)
            return folder.appendingPathComponent(next)
        }
    }

    private func requireBrowse() throws -> SFTPLink {
        guard let browse else { throw TransferError.notConnected }
        return browse
    }

    private func metadataLink() throws -> SFTPLink {
        if let browse { return browse }
        if let interactive { return interactive }
        throw TransferError.notConnected
    }

    private func withData<T>(_ body: (SFTPLink) async throws -> T) async throws -> T {
        let link = try await acquire()
        defer { release(link) }
        return try await body(link)
    }

    private func acquire() async throws -> SFTPLink {
        if let free = pool.first(where: { !busy.contains(ObjectIdentifier($0)) }) {
            busy.insert(ObjectIdentifier(free))
            return free
        }
        if pool.count < 7 {
            let link = try await openLink(.data)
            pool.append(link)
            busy.insert(ObjectIdentifier(link))
            return link
        }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    private func release(_ link: SFTPLink) {
        let id = ObjectIdentifier(link)
        busy.remove(id)
        guard !waiters.isEmpty else { return }
        busy.insert(id)
        waiters.removeFirst().resume(returning: link)
    }

    private func openLink(_ role: ChannelRole) async throws -> SFTPLink {
        guard let saved else { throw TransferError.notConnected }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = ["-S", socketPath, "-o", "Compression=no", "-o", "ControlMaster=no", "-s", "sftp", "--", saved.destination]
        if !saved.port.isEmpty { arguments.insert(contentsOf: ["-p", saved.port], at: 0) }
        process.arguments = arguments
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let chunks = ChunkPipe()
        let link = SFTPLink(
            role: role,
            process: process,
            input: input.fileHandleForWriting,
            output: output.fileHandleForReading,
            chunks: chunks
        )
        await link.start()
        try await link.handshake()
        return link
    }

    private func probe() async -> Bool {
        guard let saved else { return false }
        let result = try? await run(
            arguments: ["-S", socketPath, "-o", "Compression=no", "--", saved.destination, "performance-version", "--probe"],
            timeout: 10
        )
        guard let result else { return false }
        return ProbeResult(exitCode: result.code, stdout: result.stdout).enabled
    }

    private func masterArguments(_ connection: SavedConnection, knownHosts: String) -> [String] {
        var arguments = [
            "-N",
            "-o", "ControlMaster=yes",
            "-o", "Compression=no",
            "-o", "ControlPath=\(socketPath)",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(knownHosts)",
            "-o", "GlobalKnownHostsFile=/dev/null",
        ]
        if !connection.port.isEmpty { arguments += ["-p", connection.port] }
        if !connection.identityFile.isEmpty {
            arguments += ["-o", "IdentityFile=\(connection.identityFile)"]
        }
        arguments.append(connection.destination)
        return arguments
    }

    private func resolveHostKey(_ connection: SavedConnection, prompts: any PromptSink) async throws -> String {
        let hostsFile = store.root.appendingPathComponent("known_hosts").path
        if !FileManager.default.fileExists(atPath: hostsFile) {
            FileManager.default.createFile(atPath: hostsFile, contents: nil)
        }
        var scan = ["-T", "5"]
        if !connection.port.isEmpty { scan += ["-p", connection.port] }
        scan.append(connection.host)
        let scanned = try await run(launch: "/usr/bin/ssh-keyscan", arguments: scan, timeout: 8)
        let line = scanned.stdout.split(separator: "\n").map(String.init).first { !$0.hasPrefix("#") && $0.contains("ssh-") } ?? ""
        guard !line.isEmpty else { throw TransferError.failed("Could not read the host key") }
        let stored = (try? String(contentsOfFile: hostsFile, encoding: .utf8)) ?? ""
        let key = line.split(separator: " ").last.map(String.init) ?? line
        let situation: HostKeySituation
        if stored.isEmpty || !stored.contains("ssh-") {
            situation = .firstSeen
        } else if stored.contains(key) {
            situation = .unchanged
        } else if stored.contains(connection.host) {
            situation = .changed
        } else {
            situation = .firstSeen
        }
        let fingerprint = await fingerprint(line)
        let event = HostKeyEvent(situation: situation, keyType: line.contains("ed25519") ? "ed25519" : "ssh", fingerprint: fingerprint, line: line)
        if situation == .unchanged { return hostsFile }
        switch await prompts.decideHostKey(event) {
        case .cancel:
            throw TransferError.hostKeyRejected
        case .trustOnce:
            let once = store.root.appendingPathComponent("known_hosts-\(UUID().uuidString)").path
            try line.appending("\n").write(toFile: once, atomically: true, encoding: .utf8)
            return once
        case .alwaysTrust, .replace:
            var next = stored.split(separator: "\n").map(String.init).filter { !$0.contains(connection.host) }
            next.append(line)
            try next.joined(separator: "\n").appending("\n").write(toFile: hostsFile, atomically: true, encoding: .utf8)
            return hostsFile
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

    private func prepareAskpass() throws -> URL {
        let directory = store.root.appendingPathComponent("ask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let script = directory.appendingPathComponent("askpass.sh")
        let source = """
        #!/bin/sh
        dir="$TRANSFER_ASK_DIR"
        umask 077
        printf '%s' "$1" > "$dir/prompt"
        i=0
        while [ ! -s "$dir/reply" ]; do
          i=$((i+1))
          if [ "$i" -gt 600 ]; then exit 1; fi
          sleep 0.1
        done
        cat "$dir/reply"
        rm -f "$dir/prompt" "$dir/reply"
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return directory
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
                let account = saved?.id.rawValue.uuidString ?? ""
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
                try? (answer.text ?? "").write(to: reply, atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: prompt)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func waitForSocket(_ process: Process) async -> Bool {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: socketPath) { return true }
            if !process.isRunning { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return FileManager.default.fileExists(atPath: socketPath)
    }

    private func run(arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        try await run(launch: "/usr/bin/ssh", arguments: arguments, timeout: timeout)
    }

    private func run(launch: String, arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: CommandResult(code: process.terminationStatus, stdout: stdout, stderr: stderr))
            }
            // timeout left to the caller for the probe via process lifetime
            _ = timeout
        }
    }
}

private struct CommandResult {
    var code: Int32
    var stdout: String
    var stderr: String
}

private struct LiveRecord {
    var id: LiveFileID
    var path: RemotePath
    var local: URL
    var base: Fingerprint?
    var dirty = false
}

final class EventPipe: @unchecked Sendable {
    let stream: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    init() {
        var continuation: AsyncStream<SessionEvent>.Continuation!
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }
    func emit(_ event: SessionEvent) { continuation.yield(event) }
}
