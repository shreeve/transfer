import CryptoKit
import Foundation
import TransferCore

/// The transfer engine: removal, single files, directory copies both ways, copies on the server,
/// tree walks, the view and preview cache, and name collisions. Login, channels, and Live
/// forwarding are in `SSHConnection.swift`.
extension SSHConnection {
    // MARK: Remove

    public func remove(_ path: RemotePath) async throws {
        try await live.remove(path, on: connection.id) {
            let link: SFTPChannel
            if let walker = await self.liveLink(.walker) { link = walker } else { link = try await self.metadataLink() }
            try await self.removeTree(path, link: link)
        }
        if let parent = path.parent { pipe.emit(.directoryChanged(parent)) }
    }

    private func removeTree(_ path: RemotePath, link: SFTPChannel) async throws {
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
    func fetch(_ path: RemotePath, info: RemoteItem, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
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
    func uploadBytes(
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
            let mtime = (attributes?[.modificationDate] as? Date).map(SFTPTime.seconds)
            let link = try await metadataLink()
            // A Live save keeps the server file's permissions, set below: the working copy is
            // private (0600), and its mode would take a script's execute bit and make a web page
            // unreadable. Any other upload carries the local file's mode, as a copy does.
            try? await link.setstat(temp, mode: expecting == nil ? mode : nil, mtime: mtime)
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
                // A new file keeps the mode the server gave the temp when it was created.
                if let kept = found?.mode { try? await link.setstat(temp, mode: kept & 0o7777, mtime: nil) }
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
    func existing(_ path: RemotePath, on link: SFTPChannel? = nil) async throws -> RemoteItem? {
        do {
            if let link { return try await link.lstat(path) }
            return try await stat(path)
        } catch TransferError.noSuchFile {
            return nil
        }
    }

    // MARK: Directory copy

    func copyDirectory(from remote: RemotePath, to local: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let tally = ProgressTally(progress)
        let link: SFTPChannel
        if let walker = await liveLink(.walker) { link = walker } else { link = try await metadataLink() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            try await walkDownload(remote, to: local, link: link, group: &group, tally: tally)
            try await group.waitForAll()
        }
    }

    private func walkDownload(
        _ remote: RemotePath,
        to local: URL,
        link: SFTPChannel,
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

    func copyDirectory(fromLocal local: URL, to remote: RemotePath, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
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
            let link: SFTPChannel
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
        link: SFTPChannel,
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
    private func copyLink(_ source: RemotePath, to destination: RemotePath, link: SFTPChannel) async throws {
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

    public nonisolated func walkTree(_ root: RemotePath) -> AsyncThrowingStream<(String, TreeEntry), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let link: SFTPChannel
                    if let walker = await self.liveLink(.walker) { link = walker } else { link = try await self.metadataLink() }
                    let item = try await link.lstat(root)
                    continuation.yield(("", TreeEntry(item)))
                    if item.kind == .directory {
                        try await self.walk(root, prefix: "", link: link) { continuation.yield(($0, $1)) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func walk(_ folder: RemotePath, prefix: String, link: SFTPChannel, visit: @escaping @Sendable (String, TreeEntry) -> Void) async throws {
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

    // MARK: View and preview

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
        return localSize == size && SFTPTime.seconds(localDate) == mtime
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
        try? FileManager.default.removeItem(at: previewCacheDirectory)
    }

    private var previewCacheDirectory: URL {
        store.cacheRoot.appendingPathComponent("Preview", isDirectory: true)
    }

    private func previewURL(_ path: RemotePath, ext: String) throws -> URL {
        var cache = previewCacheDirectory
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? cache.setResourceValues(values)
        let digest = SHA256.hash(data: Data(path.bytes)).map { String(format: "%02x", $0) }.joined()
        return cache.appendingPathComponent("\(digest).\(ext)")
    }

    private func trimPreviewCache() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: previewCacheDirectory, includingPropertiesForKeys: Array(keys)) else { return }
        let entries = files.compactMap { url -> CacheEntry? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            let used = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            return CacheEntry(id: url.path, size: UInt64(values.fileSize ?? 0), lastUsed: used)
        }
        for victim in CacheEviction.victims(entries, limit: CacheEviction.previewLimit) {
            try? FileManager.default.removeItem(atPath: victim)
        }
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
        return LocalStamp(size: size, mtime: SFTPTime.seconds(date))
    }

    // MARK: Duplicate

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

    // MARK: Collisions

    /// The operation's answer for a file that already has the name. Never the login sink, which
    /// belongs to whichever window logged in; with nobody to ask, the operation fails.
    private func collisionChoice(for name: String) async throws -> NameCollisionChoice {
        guard let choice = await OperationPrompts.current?.resolveCollision(fileName: name) else {
            throw TransferError.failed("“\(name)” already exists there, and there is no window to ask whether to replace it")
        }
        return choice
    }

    private func resolvedUploadDestination(_ source: URL, proposed: RemotePath) async throws -> RemotePath? {
        let local = Self.stamp(source)
        return try await resolvedDestination(size: local?.size ?? 0, mtime: local?.mtime ?? 0, proposed: proposed)
    }

    /// Where a file of this size and time lands at `proposed`: nil to skip it, else the path to
    /// write, after asking the user when a different file already has the name.
    private func resolvedDestination(size: UInt64, mtime: UInt32, proposed: RemotePath) async throws -> RemotePath? {
        let sourceItem = RemoteItem(path: proposed, kind: .file, size: size, mtime: mtime)
        let existing = try? await stat(proposed)
        switch CopyRules.fileDisposition(source: sourceItem, destination: existing) {
        case .skip:
            return nil
        case .typeMismatch:
            throw TransferError.typeMismatch(proposed.display)
        case .write:
            return proposed
        case .collide:
            let choice = try await collisionChoice(for: sourceItem.name)
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

    func listedNames(_ path: RemotePath) async throws -> Set<String> {
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
        let choice = try await collisionChoice(for: item.name)
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
