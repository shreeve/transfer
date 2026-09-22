import CryptoKit
import Foundation
import TransferCore

public actor SSHConnection: RemoteSession {
    public nonisolated let connection: SavedConnection

    private let store: Store
    private var editableExtensions: Set<String>
    private var promptSink: (any PromptSink)?
    private var master: Process?
    private var socketPath = ""
    private var askDirectory: URL?
    private var onceKnownHosts: URL?
    private var startPath: RemotePath?
    private var browse: SFTPLink?
    private var interactive: SFTPLink?
    private var walker: SFTPLink?
    private var reopened: Set<ChannelRole> = []
    private var pool: [SFTPLink] = []
    private var busy: Set<ObjectIdentifier> = []
    private var waiters: [CheckedContinuation<SFTPLink, Error>] = []
    private var poolRefused = false
    private var performance = false
    private var prompted = false
    private let pipe = EventPipe()
    private let lane = InteractiveLane()
    private var lives: [LiveFileID: LiveRecord] = [:]
    private var watchers: [LiveFileID: DispatchSourceFileSystemObject] = [:]
    private var fileWatchers: [LiveFileID: DispatchSourceFileSystemObject] = [:]
    private var settling: [LiveFileID: Task<Void, Never>] = [:]

    init(connection: SavedConnection, store: Store, editableExtensions: Set<String>) {
        self.connection = connection
        self.store = store
        self.editableExtensions = editableExtensions
    }

    public nonisolated func events() -> AsyncStream<SessionEvent> { pipe.stream() }

    func setEditableExtensions(_ extensions: Set<String>) {
        editableExtensions = extensions
    }

    public var performanceModeEnabled: Bool { performance }
    public var isConnected: Bool { startPath != nil && master?.isRunning == true }
    public var unsyncedLiveCount: Int { lives.values.filter(\.dirty).count }

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
            _ = try? await run(arguments: ["-S", socketPath, "-O", "exit", connection.destination], timeout: 3)
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        let hostKeyArguments = try await resolveHostKey(prompts)
        let ask = try prepareAskpass()
        askDirectory = ask
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
        performance = await probe() && PerformanceDirectoryCopy.available()
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
        loadLives()
        return resolved
    }

    public func disconnect() async {
        for task in settling.values { task.cancel() }
        settling.removeAll()
        for watcher in watchers.values { watcher.cancel() }
        watchers.removeAll()
        for watcher in fileWatchers.values { watcher.cancel() }
        fileWatchers.removeAll()
        lives.removeAll()
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
                    _ = try? await run(arguments: ["-S", socketPath, "-O", "exit", connection.destination], timeout: 3)
                }
                master.terminate()
            }
        }
        master = nil
        if !socketPath.isEmpty { try? FileManager.default.removeItem(atPath: socketPath) }
        if let onceKnownHosts { try? FileManager.default.removeItem(at: onceKnownHosts.deletingLastPathComponent()) }
        onceKnownHosts = nil
        if let askDirectory { try? FileManager.default.removeItem(at: askDirectory) }
        askDirectory = nil
        performance = false
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
        try await metadataLink().rename(source, to: destination)
        for (id, var record) in lives {
            guard let moved = record.path.replacing(prefix: source, with: destination) else { continue }
            record.path = moved
            let newLocal = record.local.deletingLastPathComponent().appendingPathComponent(String(decoding: moved.nameBytes, as: UTF8.self))
            if newLocal != record.local, (try? FileManager.default.moveItem(at: record.local, to: newLocal)) != nil {
                record.local = newLocal
            }
            lives[id] = record
            persist(record)
            rearmFileWatch(record)
        }
        pipe.emit(.liveChanged)
        if let parent = source.parent { pipe.emit(.directoryChanged(parent)) }
        if let parent = destination.parent, parent != source.parent { pipe.emit(.directoryChanged(parent)) }
    }

    public func remove(_ path: RemotePath) async throws {
        let link: SFTPLink
        if let walker = await liveLink(.walker) { link = walker } else { link = try await metadataLink() }
        try await removeTree(path, link: link)
        for (id, record) in lives where record.path.replacing(prefix: path, with: path) != nil {
            forget(id)
            try? FileManager.default.removeItem(at: record.local.deletingLastPathComponent())
        }
        pipe.emit(.liveChanged)
        if let parent = path.parent { pipe.emit(.directoryChanged(parent)) }
    }

    private func removeTree(_ path: RemotePath, link: SFTPLink) async throws {
        let item = try await link.lstat(path)
        if item.kind == .directory {
            for try await child in await link.list(path) {
                try await removeTree(child.path, link: link)
            }
            try await link.removeDirectory(path)
        } else {
            try await link.removeFile(path)
        }
    }

    // MARK: Single files

    public func download(_ path: RemotePath, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let info = try await stat(path)
        switch info.kind {
        case .directory:
            try await copyDirectory(from: path, to: destination, progress: progress)
        case .symlink:
            let target = try await readlink(path)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        case .other:
            return
        case .file:
            if Self.localFileMatches(destination, item: info) { return }
            guard let placed = try await collisionFile(destination, item: info) else { return }
            try await fetch(path, info: info, to: placed, progress: progress)
        }
    }

    /// Temp-and-rename onto the local disk. No collision check.
    private func fetch(_ path: RemotePath, info: RemoteItem, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(CopyRules.tempName(for: destination.lastPathComponent, transferID: UUID().uuidString))
        store.rememberTemp(temp.path, connection: nil)
        do {
            try await withData { link in
                try await link.download(path, to: temp, size: info.size, progress: progress)
            }
            var attributes: [FileAttributeKey: Any] = [:]
            if let mode = info.mode { attributes[.posixPermissions] = Int(mode & 0o7777) }
            if let mtime = info.mtime { attributes[.modificationDate] = Date(timeIntervalSince1970: TimeInterval(mtime)) }
            if !attributes.isEmpty { try? FileManager.default.setAttributes(attributes, ofItemAtPath: temp.path) }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temp, to: destination)
            store.forgetTemp(temp.path)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            store.forgetTemp(temp.path)
            throw error
        }
    }

    public func upload(_ source: URL, to destination: RemotePath, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
            try await metadataLink().symlink(target: target, link: destination)
            if let parent = destination.parent { pipe.emit(.directoryChanged(parent)) }
            return
        }
        if values.isDirectory == true {
            try await copyDirectory(fromLocal: source, to: destination, progress: progress)
            return
        }
        guard let placed = try await resolvedUploadDestination(source, proposed: destination) else { return }
        try await uploadBytes(source, to: placed, interactive: false, progress: progress)
        if let parent = placed.parent { pipe.emit(.directoryChanged(parent)) }
    }

    /// Temp-and-rename onto the server. No collision check.
    private func uploadBytes(_ source: URL, to placed: RemotePath, interactive: Bool, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let base = String(decoding: placed.nameBytes, as: UTF8.self)
        let parent = placed.parent ?? RemotePath(string: "/")
        let temp = parent.appending(name: Array(CopyRules.tempName(for: base, transferID: UUID().uuidString).utf8))
        store.rememberTemp(temp.display, connection: connection.id)
        do {
            if interactive {
                try await withInteractive { link in try await link.upload(source, to: temp, progress: progress) }
            } else {
                try await withData { link in try await link.upload(source, to: temp, progress: progress) }
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
            let mode = (attributes?[.posixPermissions] as? NSNumber)?.uint32Value
            let mtime = (attributes?[.modificationDate] as? Date).map { UInt32($0.timeIntervalSince1970) }
            let link = try await metadataLink()
            try? await link.setstat(temp, mode: mode, mtime: mtime)
            if !(await link.posixRename(temp, to: placed)) {
                try? await link.removeFile(placed)
                try await link.plainRename(temp, to: placed)
            }
            store.forgetTemp(temp.display)
        } catch {
            try? await metadataLink().removeFile(temp)
            store.forgetTemp(temp.display)
            throw error
        }
    }

    // MARK: Directory copy

    public func copyDirectory(from remote: RemotePath, to local: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let tally = ProgressTally(progress)
        let link: SFTPLink
        if let walker = await liveLink(.walker) { link = walker } else { link = try await metadataLink() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            try await walkDownload(remote, to: local, link: link, group: &group, tally: tally)
            try await group.waitForAll()
        }
    }

    private func walkDownload(
        _ remote: RemotePath,
        to local: URL,
        link: SFTPLink,
        group: inout ThrowingTaskGroup<Void, Error>,
        tally: ProgressTally
    ) async throws {
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        for try await item in await link.list(remote) {
            try Task.checkCancellation()
            let child = local.appendingPathComponent(item.name)
            switch item.kind {
            case .directory:
                try await walkDownload(item.path, to: child, link: link, group: &group, tally: tally)
            case .symlink:
                let target = try await link.readlink(item.path)
                try? FileManager.default.removeItem(at: child)
                try FileManager.default.createSymbolicLink(atPath: child.path, withDestinationPath: target)
                tally.finished(bytes: 0)
            case .file:
                if Self.localFileMatches(child, item: item) {
                    tally.finished(bytes: 0)
                    continue
                }
                guard let placed = try await collisionFile(child, item: item) else { continue }
                group.addTask {
                    try await self.fetch(item.path, info: item, to: placed) { _ in }
                    tally.finished(bytes: item.size ?? 0)
                }
            case .other:
                continue
            }
        }
    }

    public func copyDirectory(fromLocal local: URL, to remote: RemotePath, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let tally = ProgressTally(progress)
        try await withThrowingTaskGroup(of: Void.self) { group in
            try await walkUpload(local, to: remote, group: &group, tally: tally)
            try await group.waitForAll()
        }
        if let parent = remote.parent { pipe.emit(.directoryChanged(parent)) }
    }

    private func walkUpload(
        _ local: URL,
        to remote: RemotePath,
        group: inout ThrowingTaskGroup<Void, Error>,
        tally: ProgressTally
    ) async throws {
        do {
            try await metadataLink().mkdir(remote)
        } catch {
            if (try? await stat(remote))?.kind != .directory { throw error }
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let children = try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: Array(keys), options: [])
        for child in children {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: keys)
            let destination = remote.appending(name: Array(child.lastPathComponent.utf8))
            if values.isSymbolicLink == true {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: child.path)
                try await metadataLink().symlink(target: target, link: destination)
                tally.finished(bytes: 0)
            } else if values.isDirectory == true {
                try await walkUpload(child, to: destination, group: &group, tally: tally)
            } else {
                guard let placed = try await resolvedUploadDestination(child, proposed: destination) else {
                    tally.finished(bytes: 0)
                    continue
                }
                let size = UInt64(values.fileSize ?? 0)
                group.addTask {
                    try await self.uploadBytes(child, to: placed, interactive: false) { _ in }
                    tally.finished(bytes: size)
                }
            }
        }
    }

    // MARK: Open, view, preview

    public func openKind(fileName: String) async -> OpenKind {
        EditableFile.openKind(fileName: fileName, extensions: editableExtensions)
    }

    public func prepareLiveFile(_ path: RemotePath) async throws -> URL {
        let item = try await stat(path)
        guard item.kind == .file else { throw TransferError.typeMismatch(path.display) }
        if let existing = lives.values.first(where: { $0.path == path }) {
            if FileManager.default.fileExists(atPath: existing.local.path) {
                if !existing.dirty, let base = existing.base, Fingerprint(item: item) != base {
                    try await refreshLive(existing.id, from: item)
                }
                return existing.local
            }
            lives[existing.id] = nil
            store.deleteLive(existing.id)
        }
        let id = LiveFileID()
        let folder = store.root.appendingPathComponent("Live/\(connection.id.rawValue.uuidString)/\(id.rawValue.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let file = folder.appendingPathComponent(item.name)
        try await lane.submit(.preview) {
            try await self.fetch(path, info: item, to: file) { _ in }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let record = LiveRecord(id: id, path: path, local: file, base: Fingerprint(item: item))
        lives[id] = record
        persist(record)
        watch(record)
        pipe.emit(.liveChanged)
        return file
    }

    public func prepareViewFile(_ path: RemotePath) async throws -> URL {
        let item = try await stat(path)
        let ext = (item.name as NSString).pathExtension
        let file = try previewURL(path, ext: ext.isEmpty ? "bin" : ext)
        try await lane.submit(.preview) {
            try await self.fetch(path, info: item, to: file) { _ in }
        }
        trimPreviewCache()
        return file
    }

    public func preparePreview(_ path: RemotePath) async throws -> URL {
        let item = try await stat(path)
        if EditableFile.openKind(fileName: item.name, extensions: editableExtensions) == .live {
            let file = try previewURL(path, ext: "html")
            let part = try previewURL(path, ext: "part")
            try await lane.submit(.preview) {
                try await self.fetch(path, info: RemoteItem(path: path, kind: .file, size: min(item.size ?? 0, 512 * 1024)), to: part) { _ in }
            }
            defer { try? FileManager.default.removeItem(at: part) }
            let data = try Data(contentsOf: part)
            guard let text = String(data: data, encoding: .utf8) else {
                return try await prepareViewFile(path)
            }
            let html = SyntaxPreview.html(text: text, fileName: item.name)
            try html.write(to: file, atomically: true, encoding: .utf8)
            trimPreviewCache()
            return file
        }
        return try await prepareViewFile(path)
    }

    public func clearPreviewCache() async {
        try? FileManager.default.removeItem(at: Self.previewCacheDirectory)
    }

    private static var previewCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transfer/Preview", isDirectory: true)
    }

    private func previewURL(_ path: RemotePath, ext: String) throws -> URL {
        var cache = Self.previewCacheDirectory
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? cache.setResourceValues(values)
        let digest = SHA256.hash(data: Data(path.bytes)).map { String(format: "%02x", $0) }.joined()
        return cache.appendingPathComponent("\(digest).\(ext)")
    }

    private func trimPreviewCache() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: Self.previewCacheDirectory, includingPropertiesForKeys: Array(keys)) else { return }
        let entries = files.compactMap { url -> CacheEntry? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            let used = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            return CacheEntry(id: url.path, size: UInt64(values.fileSize ?? 0), lastUsed: used)
        }
        for victim in CacheEviction.victims(entries, limit: CacheEviction.previewLimit) {
            try? FileManager.default.removeItem(atPath: victim)
        }
    }

    // MARK: Live

    public func liveFiles() async -> [LiveFile] {
        lives.values.map {
            LiveFile(id: $0.id, path: $0.path, dirty: $0.dirty, paused: $0.paused, conflict: $0.conflict, uploading: $0.uploading)
        }
        .sorted { $0.path.display < $1.path.display }
    }

    public func discardLiveFile(_ path: RemotePath, force: Bool) async throws {
        guard let record = lives.values.first(where: { $0.path == path }) else { return }
        if record.uploading { throw TransferError.failed("An upload of \(record.name) is in flight") }
        if !force, record.dirty { throw TransferError.liveUnsynced(1) }
        forget(record.id)
        try? FileManager.default.removeItem(at: record.local.deletingLastPathComponent())
        pipe.emit(.liveChanged)
    }

    public func setLivePaused(_ path: RemotePath, paused: Bool) async {
        guard var record = lives.values.first(where: { $0.path == path }) else { return }
        record.paused = paused
        lives[record.id] = record
        if paused {
            settling[record.id]?.cancel()
            settling[record.id] = nil
            emitLive(record, state: .paused)
        } else if record.dirty {
            await syncLive(record.id)
        }
        pipe.emit(.liveChanged)
    }

    public func resolveLive(_ path: RemotePath, choice: LiveConflictChoice) async throws {
        guard var record = lives.values.first(where: { $0.path == path }) else { throw TransferError.noSuchFile(path.display) }
        let server = record.local.deletingLastPathComponent().appendingPathComponent("\(record.name) (server)")
        switch choice {
        case .compare:
            if !FileManager.default.fileExists(atPath: server.path) {
                let item = try await stat(path)
                try await fetch(path, info: item, to: server) { _ in }
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/opendiff")
            process.arguments = [record.local.path, server.path]
            try process.run()
            return
        case .keepLocal:
            let snapshot = try coordinatedSnapshot(of: record.local)
            defer { try? FileManager.default.removeItem(at: snapshot) }
            try await uploadBytes(snapshot, to: path, interactive: true) { _ in }
        case .keepRemote:
            let item = try await stat(path)
            try await fetch(path, info: item, to: record.local) { _ in }
        case .keepBoth:
            let sibling = (path.parent ?? RemotePath(string: "/")).appending(name: Array("\(record.name) (from this Mac)".utf8))
            let snapshot = try coordinatedSnapshot(of: record.local)
            defer { try? FileManager.default.removeItem(at: snapshot) }
            try await uploadBytes(snapshot, to: sibling, interactive: true) { _ in }
            let item = try await stat(path)
            try await fetch(path, info: item, to: record.local) { _ in }
        }
        try? FileManager.default.removeItem(at: server)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.local.path)
        record.base = Fingerprint(item: try await stat(path))
        record.dirty = false
        record.conflict = false
        lives[record.id] = record
        persist(record)
        emitLive(record, state: .succeeded)
        pipe.emit(.liveChanged)
        if let parent = path.parent { pipe.emit(.directoryChanged(parent)) }
    }

    private func loadLives() {
        for row in store.liveFiles(connection: connection.id) {
            let local = URL(fileURLWithPath: row.localPath)
            guard FileManager.default.fileExists(atPath: local.path) else {
                if row.dirty { pipe.emit(.notice("The Live copy of \(row.path.display) is gone; its edits were not uploaded")) }
                store.deleteLive(row.id)
                continue
            }
            var base: Fingerprint?
            if let size = row.baseSize, let mtime = row.baseMtime { base = Fingerprint(kind: .file, size: size, mtime: mtime) }
            var record = LiveRecord(id: row.id, path: row.path, local: local, base: base)
            record.dirty = row.dirty || !Self.localMatchesBase(local, base: base)
            lives[row.id] = record
            watch(record)
            if record.dirty {
                persist(record)
                let id = row.id
                Task { await self.syncLive(id) }
            }
        }
        pipe.emit(.liveChanged)
    }

    private func refreshLive(_ id: LiveFileID, from item: RemoteItem) async throws {
        guard var record = lives[id] else { return }
        try await fetch(record.path, info: item, to: record.local) { _ in }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.local.path)
        record.base = Fingerprint(item: item)
        lives[id] = record
        persist(record)
    }

    /// Watches the workspace folder, which sees safe-saves, and the file itself, which sees writes in place.
    private func watch(_ record: LiveRecord) {
        if let source = Self.watchSource(record.local.deletingLastPathComponent(), id: record.id, owner: self) {
            watchers[record.id] = source
        }
        rearmFileWatch(record)
    }

    private func rearmFileWatch(_ record: LiveRecord) {
        fileWatchers[record.id]?.cancel()
        fileWatchers[record.id] = Self.watchSource(record.local, id: record.id, owner: self)
    }

    private static func watchSource(_ url: URL, id: LiveFileID, owner: SSHConnection) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: .global()
        )
        source.setEventHandler { [weak owner] in
            Task { await owner?.liveChanged(id) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    /// Waits until size and mtime have stopped changing for 400 ms, then syncs.
    private func liveChanged(_ id: LiveFileID) {
        guard let record = lives[id], !record.uploading else { return }
        rearmFileWatch(record)
        settling[id]?.cancel()
        settling[id] = Task { [weak self] in
            var last = Self.stamp(record.local)
            while true {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { return }
                let now = Self.stamp(record.local)
                if now == last { break }
                last = now
            }
            await self?.syncLive(id)
        }
    }

    private func syncLive(_ id: LiveFileID) async {
        guard var record = lives[id], !record.uploading else { return }
        guard FileManager.default.fileExists(atPath: record.local.path) else {
            if record.dirty {
                emitLive(record, state: .failed, message: "The working copy disappeared before its edits were uploaded")
            } else {
                forget(id)
                pipe.emit(.liveChanged)
            }
            return
        }
        if Self.localMatchesBase(record.local, base: record.base) {
            if record.dirty {
                record.dirty = false
                lives[id] = record
                persist(record)
                pipe.emit(.liveChanged)
            }
            return
        }
        record.dirty = true
        lives[id] = record
        persist(record)
        pipe.emit(.liveChanged)
        guard !record.paused, !record.conflict else { return }
        let remote = try? await stat(record.path)
        if remote == nil || Fingerprint(item: remote!) != record.base {
            record.conflict = true
            lives[id] = record
            let server = record.local.deletingLastPathComponent().appendingPathComponent("\(record.name) (server)")
            var comparable = false
            if let remote {
                try? await fetch(record.path, info: remote, to: server) { _ in }
                comparable = FileManager.default.isExecutableFile(atPath: "/usr/bin/opendiff")
                    && Self.isUTF8(record.local) && Self.isUTF8(server)
            }
            emitLive(record, state: .failed, message: "Changed on the server")
            pipe.emit(.conflict(record.path, comparable: comparable))
            pipe.emit(.liveChanged)
            return
        }
        record.uploading = true
        lives[id] = record
        var attempt = 0
        while true {
            do {
                let snapshot = try coordinatedSnapshot(of: record.local)
                defer { try? FileManager.default.removeItem(at: snapshot) }
                let operation = record
                let events = pipe
                try await lane.submit(.save) {
                    try await self.uploadBytes(snapshot, to: operation.path, interactive: true) { progress in
                        events.emit(.operation(TransferOperation(id: operation.id.rawValue.uuidString, title: operation.name, state: .active, progress: progress, livePath: operation.path)))
                    }
                }
                break
            } catch {
                if RetryPolicy.isRetryable(error), let delay = RetryPolicy.delay(afterAttempt: attempt) {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                record.uploading = false
                lives[id] = record
                emitLive(record, state: .failed, message: error.localizedDescription)
                return
            }
        }
        guard var finished = lives[id] else { return }
        finished.uploading = false
        if let updated = try? await stat(finished.path) {
            finished.base = Fingerprint(item: updated)
        }
        finished.dirty = !Self.localMatchesBase(finished.local, base: finished.base)
        lives[id] = finished
        persist(finished)
        emitLive(finished, state: .succeeded)
        pipe.emit(.liveChanged)
        if let parent = finished.path.parent { pipe.emit(.directoryChanged(parent)) }
        if finished.dirty { await syncLive(id) }
    }

    private func emitLive(_ record: LiveRecord, state: OperationState, message: String? = nil) {
        pipe.emit(.operation(TransferOperation(
            id: record.id.rawValue.uuidString,
            title: record.name,
            state: state,
            message: message,
            livePath: record.path
        )))
    }

    private func forget(_ id: LiveFileID) {
        watchers[id]?.cancel()
        watchers[id] = nil
        fileWatchers[id]?.cancel()
        fileWatchers[id] = nil
        settling[id]?.cancel()
        settling[id] = nil
        lives[id] = nil
        store.deleteLive(id)
    }

    private func persist(_ record: LiveRecord) {
        store.saveLive(LiveRow(
            id: record.id,
            connection: connection.id,
            path: record.path,
            baseSize: record.base?.size,
            baseMtime: record.base?.mtime,
            localPath: record.local.path,
            dirty: record.dirty
        ))
    }

    /// A copy of the working file taken under an `NSFileCoordinator` read, with the same mtime.
    private func coordinatedSnapshot(of file: URL) throws -> URL {
        let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: file, options: [], error: &coordinatorError) { url in
            do {
                try FileManager.default.copyItem(at: url, to: snapshot)
                if let date = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date {
                    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: snapshot.path)
                }
            } catch {
                copyError = error
            }
        }
        if let coordinatorError { throw TransferError.failed(coordinatorError.localizedDescription) }
        if let copyError { throw TransferError.failed(copyError.localizedDescription) }
        return snapshot
    }

    private struct LocalStamp: Equatable {
        var size: UInt64
        var mtime: UInt32
    }

    /// Read through FileManager: `URL.resourceValues` caches per URL instance and would report stale stamps.
    private static func stamp(_ url: URL) -> LocalStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let date = attributes[.modificationDate] as? Date else { return nil }
        return LocalStamp(size: size, mtime: UInt32(date.timeIntervalSince1970))
    }

    private static func localMatchesBase(_ url: URL, base: Fingerprint?) -> Bool {
        guard let base, let local = stamp(url) else { return false }
        return local.size == base.size && local.mtime == base.mtime
    }

    private static func isUTF8(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return String(data: data, encoding: .utf8) != nil
    }

    // MARK: Sidebar data

    public func recents() async -> [RemotePath] {
        store.recents(connection: connection.id).map(RemotePath.init(string:))
    }

    public func remember(_ path: RemotePath) async {
        store.remember(connection: connection.id, path: path.display)
    }

    public func pins() async -> [RemotePath] {
        store.pins(connection: connection.id).map(RemotePath.init(string:))
    }

    public func pin(_ path: RemotePath) async {
        store.pin(connection: connection.id, path: path.display, on: true)
    }

    public func unpin(_ path: RemotePath) async {
        store.pin(connection: connection.id, path: path.display, on: false)
    }

    public func duplicate(_ path: RemotePath) async throws {
        let item = try await stat(path)
        guard item.kind == .file, let parent = path.parent else {
            throw TransferError.failed("Only a file can be duplicated")
        }
        let names = try await listedNames(parent)
        let copyName = KeepBothName.duplicate(existing: names, original: item.name)
        let destination = parent.appending(name: Array(copyName.utf8))
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await fetch(path, info: item, to: scratch) { _ in }
        try await uploadBytes(scratch, to: destination, interactive: false) { _ in }
        pipe.emit(.directoryChanged(parent))
    }

    public func terminalCommand(directory: RemotePath) async -> String? {
        guard isConnected else { return nil }
        let remote = "cd \(Self.quote(directory.display)) && exec \"$SHELL\" -l"
        return "/usr/bin/ssh -S \(Self.quote(socketPath)) -o Compression=no -t \(Self.quote(connection.destination)) \(Self.quote(remote))"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Collisions

    private func resolvedUploadDestination(_ source: URL, proposed: RemotePath) async throws -> RemotePath? {
        let local = Self.stamp(source)
        let sourceItem = RemoteItem(path: proposed, kind: .file, size: local?.size ?? 0, mtime: local?.mtime ?? 0)
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
                let parent = proposed.parent ?? RemotePath(string: "/")
                let names = try await listedNames(parent)
                let next = KeepBothName.next(existing: names, original: sourceItem.name)
                return parent.appending(name: Array(next.utf8))
            }
        }
    }

    private func listedNames(_ path: RemotePath) async throws -> Set<String> {
        var names: Set<String> = []
        let link = try await metadataLink()
        for try await item in await link.list(path) {
            names.insert(item.name)
        }
        return names
    }

    private static func localFileMatches(_ url: URL, item: RemoteItem) -> Bool {
        guard let local = stamp(url), let remoteSize = item.size, let remoteTime = item.mtime else { return false }
        return local.size == remoteSize && local.mtime == remoteTime
    }

    private func collisionFile(_ url: URL, item: RemoteItem) async throws -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return url }
        if isDirectory.boolValue { throw TransferError.typeMismatch(url.lastPathComponent) }
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

    // MARK: Channels

    private func requireBrowse() throws -> SFTPLink {
        guard let browse else { throw TransferError.notConnected }
        return browse
    }

    /// The browse passenger, or interactive between its jobs.
    private func metadataLink() async throws -> SFTPLink {
        if let link = await liveLink(.browse) { return link }
        if let link = await liveLink(.interactive) { return link }
        throw TransferError.notConnected
    }

    /// A reserved passenger, reopened once after it dies. Nil when down.
    private func liveLink(_ role: ChannelRole) async -> SFTPLink? {
        let current: SFTPLink?
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

    private func withInteractive<T>(_ body: (SFTPLink) async throws -> T) async throws -> T {
        if let link = await liveLink(.interactive) { return try await body(link) }
        return try await withData(body)
    }

    private func withData<T>(_ body: (SFTPLink) async throws -> T) async throws -> T {
        let link = try await acquire()
        defer { release(link) }
        return try await body(link)
    }

    private func acquire() async throws -> SFTPLink {
        var open: [SFTPLink] = []
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

    private func release(_ link: SFTPLink) {
        let id = ObjectIdentifier(link)
        busy.remove(id)
        guard !waiters.isEmpty else { return }
        busy.insert(id)
        waiters.removeFirst().resume(returning: link)
    }

    private func openLink(_ role: ChannelRole) async throws -> SFTPLink {
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

    // MARK: Probe and host keys

    private func probe() async -> Bool {
        let result = try? await run(
            arguments: ["-S", socketPath, "-o", "Compression=no", "--", connection.destination, "performance-version", "--probe"],
            timeout: 10
        )
        guard let result else { return false }
        return ProbeResult(exitCode: result.code, stdout: result.stdout).enabled
    }

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
            "-S", socketPath,
            "-o", "StrictHostKeyChecking=yes",
        ]
        arguments += hostKeyArguments
        arguments += destinationArguments
        arguments.append(connection.destination)
        return arguments
    }

    /// Learns the offered key with a no-auth ssh run, compares it with the known-hosts files `ssh -G`
    /// reports, and asks the user when it is new or changed. Returns extra ssh arguments for the master.
    private func resolveHostKey(_ prompts: any PromptSink) async throws -> [String] {
        let config = try await run(arguments: ["-G"] + destinationArguments + [connection.destination], timeout: 5)
        let files = KnownHosts.files(sshConfigOutput: config.stdout)
        let probeDirectory = store.root.appendingPathComponent("hostkey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: probeDirectory.path)
        let probeFile = probeDirectory.appendingPathComponent("known_hosts")
        let probe = try await run(arguments: Self.quotedOption("UserKnownHostsFile", probeFile.path) + [
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
        ] + destinationArguments + [connection.destination, "true"], timeout: 30)
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
            onceKnownHosts = probeFile
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

private struct CommandResult {
    var code: Int32
    var stdout: String
    var stderr: String
}

private final class TimeoutFlag: @unchecked Sendable {
    var fired = false
}

private struct LiveRecord {
    var id: LiveFileID
    var path: RemotePath
    var local: URL
    var base: Fingerprint?
    var dirty = false
    var paused = false
    var conflict = false
    var uploading = false

    var name: String { String(decoding: path.nameBytes, as: UTF8.self) }
}

/// Byte and item counts for one directory copy, safe to bump from any task.
final class ProgressTally: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: UInt64 = 0
    private var items = 0
    private let report: @Sendable (TransferProgress) -> Void

    init(_ report: @escaping @Sendable (TransferProgress) -> Void) {
        self.report = report
    }

    func finished(bytes count: UInt64) {
        lock.lock()
        bytes += count
        items += 1
        let progress = TransferProgress(completed: bytes, itemsCompleted: items)
        lock.unlock()
        report(progress)
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
