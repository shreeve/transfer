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
            try await self.removeTree(path, link: try await self.walkerLink())
        }
        if let parent = path.parent { pipe.emit(.directoryChanged(parent)) }
    }

    /// The walker passenger, else the browse one.
    private func walkerLink() async throws -> SFTPChannel {
        if let walker = await liveLink(.walker) { return walker }
        return try await metadataLink()
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

    /// `destination` is a folder on this Mac chosen by the caller, which may be reached through
    /// links, plus the name to give the item there. Everything below it comes from the server and
    /// is placed through `LocalPlacement`.
    public func download(_ path: RemotePath, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let item = try await stat(path)
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = try await walkerLink()
        let tally = CopyTally(progress)
        try await withThrowingTaskGroup(of: Void.self) { group in
            try await placeDown(item, named: destination.lastPathComponent, in: folder, link: link, group: &group, tally: tally)
            try await group.waitForAll()
        }
        try tally.check()
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
            // A temp that cannot be removed now stays recorded, and the next launch removes it.
            if unlink(temp.path) == 0 || errno == ENOENT { store.forgetTemp(temp.path) }
            throw error
        }
    }

    public func upload(_ source: URL, to destination: RemotePath, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        try await copyToServer(.mac(source), at: destination, progress: progress)
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
        try await withRemoteTemp(for: placed) { temp in
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
            return written
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

    /// Places the server's `item` as `name` in `folder`, a real folder on this Mac: a folder is
    /// merged or made and walked, a link is made, and a file's bytes go to the data channels.
    /// `taken` says an earlier entry of the same listing claimed the name.
    private func placeDown(
        _ item: RemoteItem,
        named name: String,
        in folder: URL,
        taken: Bool = false,
        link: SFTPChannel,
        group: inout ThrowingTaskGroup<Void, Error>,
        tally: CopyTally
    ) async throws {
        switch item.kind {
        case .directory:
            guard let local = try await localFolder(named: name, in: folder, taken: taken) else { return }
            // Names this listing already used. A later one that folds the same (a duplicate, or two
            // names this Mac's disk takes for one) collides even before the first has landed.
            var used: Set<String> = []
            for try await child in await link.list(item.path) {
                try Task.checkCancellation()
                let taken = !used.insert(Placement.fold(child.name)).inserted
                do {
                    try await placeDown(child, named: child.name, in: local, taken: taken, link: link, group: &group, tally: tally)
                } catch {
                    try tally.failed(child.name, error)
                }
            }
        case .symlink:
            try await localLink(try await link.readlink(item.path), named: name, in: folder, taken: taken)
            tally.finished()
        case .file:
            guard let placed = try await settleLocally(.file(Fingerprint(item: item)), named: name, in: folder, taken: taken) else {
                return tally.finished()
            }
            group.addTask {
                do {
                    try await self.fetch(item.path, info: item, to: placed.url, progress: tally.file())
                    tally.finished()
                } catch {
                    try tally.failed(name, error)
                }
            }
        case .other:
            return
        }
    }

    /// Where `incoming` lands as `name` in `folder`, a real folder on this Mac, and what holds that
    /// spot now; nil to skip it. What holds the name is read without following a link, and anything
    /// but the same file or link is asked about. `taken` says an earlier entry of the same listing
    /// claimed the name and may not have landed yet.
    private func settleLocally(_ incoming: PlacedItem, named name: String, in folder: URL, taken: Bool = false) async throws -> (url: URL, found: PlacedItem?)? {
        let url = try LocalPlacement.child(folder, name: name)
        var found = try LocalPlacement.occupant(url)
        if taken, found == nil { found = .other }
        switch Placement.settle(incoming, onto: found) {
        case .write, .merge:
            return (url, found)
        case .skip:
            return nil
        case .typeMismatch:
            throw TransferError.typeMismatch(name)
        case .collide:
            switch try await collisionChoice(for: name) {
            case .skip: return nil
            case .replace: return (url, found)
            case .keepBoth: return (try LocalPlacement.keepBoth(url), nil)
            }
        }
    }

    /// The real folder a server folder named `name` merges into or is made as; nil to skip it.
    private func localFolder(named name: String, in folder: URL, taken: Bool = false) async throws -> URL? {
        guard let spot = try await settleLocally(.folder, named: name, in: folder, taken: taken) else { return nil }
        if spot.found != .folder { try LocalPlacement.makeFolder(spot.url, replacing: spot.found != nil) }
        return spot.url
    }

    private func localLink(_ target: String, named name: String, in folder: URL, taken: Bool = false) async throws {
        guard let spot = try await settleLocally(.link(target), named: name, in: folder, taken: taken) else { return }
        try LocalPlacement.makeLink(spot.url, target: target)
    }

    // MARK: Copies onto the server

    public func copy(_ source: RemotePath, to destination: RemotePath, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        if let refusal = PasteRules.refusal(sources: [source], into: destination) { throw TransferError.failed(refusal) }
        try await copyToServer(.server(try await stat(source)), at: destination, progress: progress)
    }

    /// Where a copy onto the server comes from: this Mac, or the same server.
    private enum Source: Sendable {
        case mac(URL)
        case server(RemoteItem)
    }

    /// Copies an upload or a copy on the server to `destination`. A folder copy goes on past an
    /// item that fails and reports them all at the end.
    private func copyToServer(_ source: Source, at destination: RemotePath, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let link = try await walkerLink()
        guard let incoming = try await incoming(source, link: link) else {
            if case .mac(let url) = source { throw TransferError.noSuchFile(url.path) }
            return
        }
        let found = try await existing(destination)
        let tally = CopyTally(progress)
        try await withThrowingTaskGroup(of: Void.self) { group in
            try await placeUp(source, incoming, at: destination, found: found, link: link, group: &group, tally: tally)
            try await group.waitForAll()
        }
        if let parent = destination.parent { pipe.emit(.directoryChanged(parent)) }
        try tally.check()
    }

    /// Places `source`, which is `incoming`, at `destination` on the server, where `found` is: a
    /// folder is merged or made and walked, a link is made, and a file's bytes go to the data channels.
    private func placeUp(
        _ source: Source,
        _ incoming: PlacedItem,
        at destination: RemotePath,
        found: RemoteItem?,
        link: SFTPChannel,
        group: inout ThrowingTaskGroup<Void, Error>,
        tally: CopyTally
    ) async throws {
        switch incoming {
        case .other:
            // A socket, FIFO, or device has no bytes to copy, and opening a FIFO blocks until
            // someone writes to it. Skipped, as a download skips the server's.
            return
        case .link(let target):
            try await remoteLink(target, at: destination, found: found)
            tally.finished()
        case .folder:
            guard let folder = try await remoteFolder(destination, found: found) else { return }
            switch source {
            case .mac(let url):
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try Task.checkCancellation()
                    try await placeChild(.mac(child), in: folder, link: link, group: &group, tally: tally)
                }
            case .server(let item):
                for try await child in await link.list(item.path) {
                    try Task.checkCancellation()
                    try await placeChild(.server(child), in: folder, link: link, group: &group, tally: tally)
                }
            }
        case .file:
            guard let placed = try await settleRemotely(incoming, at: destination, found: found) else { return tally.finished() }
            group.addTask {
                do {
                    switch source {
                    case .mac(let url):
                        try await self.uploadBytes(url, to: placed.path, interactive: false, progress: tally.file())
                        tally.finished()
                    case .server(let item):
                        try await self.copyFile(item, to: placed.path)
                        tally.finished(bytes: item.size ?? 0)
                    }
                } catch {
                    try tally.failed(destination.name, error)
                }
            }
        }
    }

    /// One entry of a folder being copied onto the server. Its failure is recorded, not thrown,
    /// unless it ends the whole copy.
    private func placeChild(_ source: Source, in folder: RemotePath, link: SFTPChannel, group: inout ThrowingTaskGroup<Void, Error>, tally: CopyTally) async throws {
        let name: [UInt8]
        switch source {
        case .mac(let url): name = Array(url.lastPathComponent.utf8)
        case .server(let item): name = item.path.nameBytes
        }
        let destination = folder.appending(name: name)
        do {
            guard let incoming = try await incoming(source, link: link) else { return }
            try await placeUp(source, incoming, at: destination, found: try await existing(destination), link: link, group: &group, tally: tally)
        } catch {
            try tally.failed(destination.name, error)
        }
    }

    /// What `source` is to the placement rules, read without following a link; nil when a file
    /// on this Mac is gone.
    private func incoming(_ source: Source, link: SFTPChannel) async throws -> PlacedItem? {
        switch source {
        case .mac(let url): try LocalPlacement.occupant(url)
        case .server(let item): try await placedItem(item, link: link)
        }
    }

    /// What the server's `item` is to the placement rules; a link's target is read from the server.
    private func placedItem(_ item: RemoteItem?, link: SFTPChannel? = nil) async throws -> PlacedItem? {
        guard let item else { return nil }
        switch item.kind {
        case .file: return .file(Fingerprint(item: item))
        case .directory: return .folder
        case .symlink:
            let reader = if let link { link } else { try await metadataLink() }
            return .link(try await reader.readlink(item.path))
        case .other: return .other
        }
    }

    /// The server's twin of `settleLocally`: where `incoming` lands at `proposed`, where `found`
    /// is, and what holds that spot; nil to skip it.
    private func settleRemotely(_ incoming: PlacedItem, at proposed: RemotePath, found: RemoteItem?) async throws -> (path: RemotePath, found: PlacedItem?)? {
        let there = try await placedItem(found)
        switch Placement.settle(incoming, onto: there) {
        case .write, .merge:
            return (proposed, there)
        case .skip:
            return nil
        case .typeMismatch:
            throw TransferError.typeMismatch(proposed.display)
        case .collide:
            switch try await collisionChoice(for: proposed.name) {
            case .skip:
                return nil
            case .replace:
                return (proposed, there)
            case .keepBoth:
                let parent = proposed.parent ?? RemotePath(string: "/")
                let name = Placement.keepBoth(proposed.name, among: try await listedNames(parent))
                return (parent.appending(name: Array(name.utf8)), nil)
            }
        }
    }

    /// The server folder a folder merges into or is made as; nil to skip it. A link or special
    /// file in the way goes only when the user chose Replace, and a folder never does.
    private func remoteFolder(_ path: RemotePath, found: RemoteItem?) async throws -> RemotePath? {
        guard let spot = try await settleRemotely(.folder, at: path, found: found) else { return nil }
        if spot.found == .folder { return spot.path }
        let link = try await metadataLink()
        if spot.found != nil { try await link.removeFile(spot.path) }
        try await link.mkdir(spot.path)
        return spot.path
    }

    /// A link is copied as a link, settled like a file: the same link is kept, anything else is
    /// asked about, and Replace swaps it in with one rename.
    private func remoteLink(_ target: String, at destination: RemotePath, found: RemoteItem?) async throws {
        guard let spot = try await settleRemotely(.link(target), at: destination, found: found) else { return }
        let link = try await metadataLink()
        guard spot.found != nil else { return try await link.symlink(target: target, link: spot.path) }
        try await withRemoteTemp(for: spot.path) { temp in
            try await link.symlink(target: target, link: temp)
            try await link.replace(temp, onto: spot.path)
        }
    }

    /// Temp-and-rename on the server, keeping the source's mode and time so a later copy of the
    /// same file is skipped. `copy-data` when the server has it; else down to the Mac and back.
    private func copyFile(_ item: RemoteItem, to placed: RemotePath) async throws {
        try await withRemoteTemp(for: placed) { temp in
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
        }
    }

    /// Runs `body` on a hidden temp beside `placed`, recorded so a later login removes it if this
    /// run cannot. `body` writes the temp and renames it into place.
    private func withRemoteTemp<T>(for placed: RemotePath, _ body: (RemotePath) async throws -> T) async throws -> T {
        let parent = placed.parent ?? RemotePath(string: "/")
        let temp = parent.appending(name: Array(CopyRules.tempName(for: placed.name, transferID: UUID().uuidString).utf8))
        store.rememberTemp(temp.display, connection: connection.id)
        do {
            let result = try await body(temp)
            store.forgetTemp(temp.display)
            return result
        } catch {
            await discardRemoteTemp(temp)
            throw error
        }
    }

    /// Removes a temp left by a failed or cancelled write and forgets it once it is gone. The
    /// removal runs in a task of its own, so the cancel that stopped the write does not stop it
    /// too. When the server cannot be reached, the record stays and the next login removes it.
    func discardRemoteTemp(_ temp: RemotePath) async {
        await Task {
            do {
                try await metadataLink().removeFile(temp)
            } catch TransferError.noSuchFile {
            } catch {
                return
            }
            store.forgetTemp(temp.display)
        }.value
    }

    public nonisolated func walkTree(_ root: RemotePath) -> AsyncThrowingStream<(String, TreeEntry), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let link = try await self.walkerLink()
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

    func listedNames(_ path: RemotePath) async throws -> Set<String> {
        var names: Set<String> = []
        let link = try await metadataLink()
        for try await item in await link.list(path) {
            names.insert(item.name)
        }
        return names
    }
}

/// One copy's byte and item counts and the items that failed, safe to touch from any task. A
/// folder copy goes on past an item that fails and reports them all at the end; a cancel, a
/// dropped connection, or a timeout ends it at once, so the operation can stop or retry.
final class CopyTally: Sendable {
    private struct State {
        var bytes: UInt64 = 0
        var items = 0
        var failures: [(name: String, error: any Error)] = []
    }

    private let state = Locked(State())
    private let report: @Sendable (TransferProgress) -> Void

    init(_ report: @escaping @Sendable (TransferProgress) -> Void) {
        self.report = report
    }

    /// A progress handler for one file's bytes, which adds what is new since its last report, so
    /// a large file inside a folder moves the bar as it goes.
    func file() -> @Sendable (TransferProgress) -> Void {
        let seen = Locked<UInt64>(0)
        return { [self] progress in
            let added = seen.withLock { last in
                defer { last = max(last, progress.completed) }
                return progress.completed > last ? progress.completed - last : 0
            }
            add(bytes: added, items: 0)
        }
    }

    /// An item is done: copied, or skipped as already there. `bytes` are those not reported as they went.
    func finished(bytes: UInt64 = 0) {
        add(bytes: bytes, items: 1)
    }

    /// Records that `name` failed and lets the copy go on, or rethrows an error that ends it.
    func failed(_ name: String, _ error: any Error) throws {
        if error is CancellationError || RetryPolicy.isRetryable(error) { throw error }
        if let error = error as? TransferError, error == .cancelled || error == .notConnected { throw error }
        state.withLock { $0.failures.append((name, error)) }
    }

    /// Throws the one failure as it was, or one error that names them all.
    func check() throws {
        let failures = state.value.failures
        guard let first = failures.first else { return }
        if failures.count == 1 { throw first.error }
        let shown = failures.prefix(3).map { "“\($0.name)”" }.joined(separator: ", ")
        let more = failures.count > 3 ? " and \(failures.count - 3) more" : ""
        throw TransferError.failed("\(failures.count) items could not be copied: \(shown)\(more). \(first.error.localizedDescription)")
    }

    private func add(bytes: UInt64, items: Int) {
        let progress = state.withLock { state in
            state.bytes += bytes
            state.items += items
            return TransferProgress(completed: state.bytes, itemsCompleted: state.items)
        }
        report(progress)
    }
}
