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
    /// Per-login folders under the library root, removed on disconnect. Lists, not single values:
    /// two windows can start a login on one connection at once, and neither may orphan the other's.
    private var askDirectories: [URL] = []
    private var onceKnownHosts: [URL] = []
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
    /// Live files are `LiveSync`'s; this connection is its `LiveServer` and forwards the Live API.
    private let live: LiveSync
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

    public var performanceModeEnabled: Bool { performance }
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
            _ = try? await run(arguments: ["-S", socketPath, "-O", "exit", connection.destination], timeout: 3)
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
                    _ = try? await run(arguments: ["-S", socketPath, "-O", "exit", connection.destination], timeout: 3)
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
        try await live.rename(source, to: destination, on: connection.id) {
            try await self.metadataLink().rename(source, to: destination)
        }
        if let parent = source.parent { pipe.emit(.directoryChanged(parent)) }
        if let parent = destination.parent, parent != source.parent { pipe.emit(.directoryChanged(parent)) }
    }

    public func remove(_ path: RemotePath) async throws {
        try await live.remove(path, on: connection.id) {
            let link: SFTPLink
            if let walker = await self.liveLink(.walker) { link = walker } else { link = try await self.metadataLink() }
            try await self.removeTree(path, link: link)
        }
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
            // One rename replaces the destination, so a watched Live copy is never briefly missing.
            guard Darwin.rename(temp.path, destination.path) == 0 else {
                throw TransferError.failed("Could not place \(destination.lastPathComponent): \(String(cString: strerror(errno)))")
            }
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
            // A link already at the destination is left alone, as a copy on the server does.
            if (try? await stat(destination)) == nil {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
                try await metadataLink().symlink(target: target, link: destination)
            }
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

    /// Temp-and-rename onto the server. No collision check. A Live save passes `expecting`, what
    /// the destination must still be just before the rename; anything else throws
    /// `LiveRemoteChanged` and the temp is removed, so another person's edit is never overwritten.
    /// With `measure`, returns the temp's fingerprint, which the rename carries onto the
    /// destination: read from our own temp, it cannot pick up someone else's later edit.
    @discardableResult
    private func uploadBytes(
        _ source: URL,
        to placed: RemotePath,
        interactive: Bool,
        expecting: ServerExpectation? = nil,
        measure: Bool = false,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> Fingerprint? {
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
            var written: Fingerprint?
            if measure || expecting != nil { written = Fingerprint(item: try await link.lstat(temp)) }
            if let expecting {
                let found = try await existing(placed, on: link)
                let now = found.flatMap(Fingerprint.init(item:))
                // "Absent" means nothing at all there: a folder or a link is not absent.
                let matches = switch expecting {
                case .file(let print): now == print
                case .absent: found == nil
                }
                // A save that runs again after it already landed finds its own bytes there.
                if !matches, now == nil || now != written { throw LiveRemoteChanged() }
            }
            try await link.replace(temp, onto: placed)
            store.forgetTemp(temp.display)
            return written
        } catch {
            try? await metadataLink().removeFile(temp)
            store.forgetTemp(temp.display)
            throw error
        }
    }

    /// The item at `path`, or nil when there is none. Any other failure, such as a dropped
    /// connection, is thrown: it is not evidence that the file was removed.
    private func existing(_ path: RemotePath, on link: SFTPLink? = nil) async throws -> RemoteItem? {
        do {
            if let link { return try await link.lstat(path) }
            return try await stat(path)
        } catch TransferError.noSuchFile {
            return nil
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
                if (try? await stat(destination)) == nil {
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: child.path)
                    try await metadataLink().symlink(target: target, link: destination)
                }
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

    // MARK: Copy on the server

    public func copy(_ source: RemotePath, to destination: RemotePath, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        if let refusal = PasteRules.refusal(sources: [source], into: destination) { throw TransferError.failed(refusal) }
        let item = try await stat(source)
        let tally = ProgressTally(progress)
        switch item.kind {
        case .directory:
            let link: SFTPLink
            if let walker = await liveLink(.walker) { link = walker } else { link = try await metadataLink() }
            try await withThrowingTaskGroup(of: Void.self) { group in
                try await walkCopy(source, to: destination, link: link, group: &group, tally: tally)
                try await group.waitForAll()
            }
        case .symlink:
            try await copyLink(source, to: destination, link: try await metadataLink())
            tally.finished(bytes: 0)
        case .file:
            try await copyFile(item, to: destination)
            tally.finished(bytes: item.size ?? 0)
        case .other:
            return
        }
        if let parent = destination.parent { pipe.emit(.directoryChanged(parent)) }
    }

    private func walkCopy(
        _ source: RemotePath,
        to destination: RemotePath,
        link: SFTPLink,
        group: inout ThrowingTaskGroup<Void, Error>,
        tally: ProgressTally
    ) async throws {
        do {
            try await metadataLink().mkdir(destination)
        } catch {
            let existing = try? await stat(destination)
            if existing?.kind != .directory {
                if existing != nil { throw TransferError.typeMismatch(destination.display) }
                throw error
            }
        }
        for try await child in await link.list(source) {
            try Task.checkCancellation()
            let target = destination.appending(name: child.path.nameBytes)
            switch child.kind {
            case .directory:
                try await walkCopy(child.path, to: target, link: link, group: &group, tally: tally)
            case .symlink:
                try await copyLink(child.path, to: target, link: link)
                tally.finished(bytes: 0)
            case .file:
                group.addTask {
                    try await self.copyFile(child, to: target)
                    tally.finished(bytes: child.size ?? 0)
                }
            case .other:
                continue
            }
        }
    }

    /// A link is copied as a link. One already at the destination is left alone.
    private func copyLink(_ source: RemotePath, to destination: RemotePath, link: SFTPLink) async throws {
        if (try? await stat(destination)) != nil { return }
        let target = try await link.readlink(source)
        try await metadataLink().symlink(target: target, link: destination)
    }

    /// Temp-and-rename on the server, keeping the source's mode and time so a later copy of the
    /// same file is skipped. `copy-data` when the server has it; else down to the Mac and back.
    private func copyFile(_ item: RemoteItem, to proposed: RemotePath) async throws {
        guard let placed = try await resolvedDestination(size: item.size ?? 0, mtime: item.mtime ?? 0, proposed: proposed) else { return }
        let parent = placed.parent ?? RemotePath(string: "/")
        let temp = parent.appending(name: Array(CopyRules.tempName(for: placed.name, transferID: UUID().uuidString).utf8))
        store.rememberTemp(temp.display, connection: connection.id)
        do {
            let onServer = try await withData { link in
                guard await link.extensions.contains("copy-data") else { return false }
                try await link.copyData(item.path, to: temp)
                return true
            }
            if !onServer {
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: scratch) }
                try await fetch(item.path, info: item, to: scratch) { _ in }
                try await withData { link in try await link.upload(scratch, to: temp) { _ in } }
            }
            let link = try await metadataLink()
            try? await link.setstat(temp, mode: item.mode.map { $0 & 0o7777 }, mtime: item.mtime)
            try await link.replace(temp, onto: placed)
            store.forgetTemp(temp.display)
        } catch {
            try? await metadataLink().removeFile(temp)
            store.forgetTemp(temp.display)
            throw error
        }
    }

    public func walkTree(_ root: RemotePath, visit: @escaping @Sendable (String, TreeEntry) -> Void) async throws {
        let link: SFTPLink
        if let walker = await liveLink(.walker) { link = walker } else { link = try await metadataLink() }
        let item = try await link.lstat(root)
        visit("", TreeEntry(item))
        guard item.kind == .directory else { return }
        try await walk(root, prefix: "", link: link, visit: visit)
    }

    private func walk(_ folder: RemotePath, prefix: String, link: SFTPLink, visit: @escaping @Sendable (String, TreeEntry) -> Void) async throws {
        for try await child in await link.list(folder) {
            try Task.checkCancellation()
            guard child.kind != .other else { continue }
            let key = prefix + child.name
            visit(key, TreeEntry(child))
            if child.kind == .directory {
                try await walk(child.path, prefix: key + "/", link: link, visit: visit)
            }
        }
    }

    // MARK: Open, view, preview

    public func openKind(fileName: String) async -> OpenKind {
        EditableFile.openKind(fileName: fileName, extensions: editableExtensions)
    }

    public func prepareLiveFile(_ path: RemotePath) async throws -> URL {
        try await live.open(path, on: connection.id)
    }

    public func prepareViewFile(_ path: RemotePath) async throws -> URL {
        let item = try await stat(path)
        let ext = (item.name as NSString).pathExtension
        let file = try previewURL(path, ext: ext.isEmpty ? "bin" : ext)
        // The copy carries the remote size and mtime; the same pair means the same bytes.
        if Self.cachedCopyMatches(file, item) { return file }
        try await lane.submit(.preview) {
            try await self.fetch(path, info: item, to: file) { _ in }
        }
        trimPreviewCache()
        return file
    }

    private static func cachedCopyMatches(_ file: URL, _ item: RemoteItem) -> Bool {
        guard let mtime = item.mtime, let size = item.size,
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let localSize = attributes[.size] as? UInt64,
              let localDate = attributes[.modificationDate] as? Date else { return false }
        return localSize == size && UInt32(localDate.timeIntervalSince1970) == mtime
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
        return try await resolvedDestination(size: local?.size ?? 0, mtime: local?.mtime ?? 0, proposed: proposed)
    }

    /// Where a file of this size and time lands at `proposed`: nil to skip it, else the path to
    /// write, after asking the user when a different file already has the name.
    private func resolvedDestination(size: UInt64, mtime: UInt32, proposed: RemotePath) async throws -> RemotePath? {
        let sourceItem = RemoteItem(path: proposed, kind: .file, size: size, mtime: mtime)
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
            // A dead network is noticed in about 45 s instead of hanging every request on it.
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
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
            ] + destinationArguments + [connection.destination, "true"], timeout: 30)
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
