import CryptoKit
import Foundation
import TransferCore

/// Removal, downloads, uploads, copies on the server, tree walks, and the preview cache. Every
/// name from a server reaches this Mac's disk through `LocalPlacement`, and whatever holds a
/// destination's name is settled by `Placement`, the same way in every direction.
extension SSHConnection {
    // MARK: Remove

    public func remove(_ path: RemotePath, force: Bool) async throws {
        try await live.remove(path, on: connection.id, force: force) {
            let link = try await self.walkerLink()
            _ = try await self.removeTree(path, as: TreeEntry(try await link.lstat(path)), link: link)
        }
        if let parent = path.parent { pipe.emit(.directoryChanged(parent)) }
    }

    /// Removes a moved original: only what the move verified of it, `verified` by key as it was
    /// then. A file changed or added since stays, with the folders holding it, and so does all of
    /// it when a Live file under it was saved since `mark` (`LiveSync.saveMark`, read before the
    /// walk): the copy lacks those bytes. Returns whether all of it went.
    func removeMoved(_ path: RemotePath, verified: [TreeKey: TreeEntry], savedSince mark: UInt64) async throws -> Bool {
        defer { if let parent = path.parent { pipe.emit(.directoryChanged(parent)) } }
        do {
            try await live.remove(path, on: connection.id) {
                // Thrown when anything stays, so its Live files are not forgotten as removed. Those
                // whose server file did go are settled by their next pass.
                if await self.live.saved(under: path, on: self.connection.id, since: mark) { throw ChangedDuringMove() }
                let link = try await self.walkerLink()
                guard try await self.removeTree(path, as: TreeEntry(try await link.lstat(path)), verified: verified, link: link) else { throw ChangedDuringMove() }
            }
        } catch is ChangedDuringMove {
            return false
        }
        return true
    }

    private struct ChangedDuringMove: Error {}

    /// The walker passenger, else the browse one.
    private func walkerLink() async throws -> SFTPChannel {
        if let walker = await liveLink(.walker) { return walker }
        return try await metadataLink()
    }

    /// Removes `path`, which is `entry` now, and what it holds; with `verified`, only entries that
    /// are still as it holds them under `key`, and a folder only once it is empty. Returns whether
    /// all of it went. A folder is listed in full, closing its handle, before what it holds is
    /// removed: one handle open at a time however deep the tree, and nothing is unlinked while the
    /// server reads it.
    private func removeTree(_ path: RemotePath, as entry: TreeEntry, key: TreeKey = "", verified: [TreeKey: TreeEntry]? = nil, link: SFTPChannel) async throws -> Bool {
        if let verified, verified[key] != entry { return false }
        guard entry == .directory else {
            try await link.removeFile(path)
            return true
        }
        var children: [RemoteItem] = []
        for try await child in await link.list(path) { children.append(child) }
        var whole = true
        for child in children {
            try Task.checkCancellation()
            let gone = try await removeTree(child.path, as: TreeEntry(child), key: key.appending(child.path.nameBytes), verified: verified, link: link)
            whole = whole && gone
        }
        if whole { try await link.removeDirectory(path) }
        return whole
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

    /// Temp-and-rename onto the local disk. No collision check, but without `replacing` the
    /// rename refuses a name that something took since it was looked up. The file takes the
    /// server's permissions without setuid, setgid, or sticky, which an untrusted server must not
    /// grant. `quarantine` marks it for Gatekeeper, as a browser marks its downloads; a Live
    /// working copy is not marked, since it only ever opens in an editor.
    func fetch(
        _ path: RemotePath,
        info: RemoteItem,
        to destination: URL,
        replacing: Bool = true,
        quarantine: Bool = false,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(CopyRules.tempName(for: destination.lastPathComponent, transferID: UUID().uuidString))
        store.rememberTemp(local: temp)
        do {
            try await receive(path, info: info, into: temp, progress: progress)
            var attributes: [FileAttributeKey: Any] = [:]
            if let mode = info.mode { attributes[.posixPermissions] = Int(mode & 0o777) }
            if let mtime = info.mtime { attributes[.modificationDate] = Date(timeIntervalSince1970: TimeInterval(mtime)) }
            if !attributes.isEmpty { try? FileManager.default.setAttributes(attributes, ofItemAtPath: temp.path) }
            if quarantine { LocalPlacement.quarantine(temp) }
            // One rename replaces the destination, so a watched Live copy is never briefly missing.
            let placed = replacing ? Darwin.rename(temp.path, destination.path) : renamex_np(temp.path, destination.path, UInt32(RENAME_EXCL))
            guard placed == 0 else {
                throw TransferError.failed("Could not place \(destination.lastPathComponent): \(String(cString: strerror(errno)))")
            }
            store.forgetTemp(local: temp)
        } catch {
            // A temp that cannot be removed now stays recorded, and the next launch removes it.
            if unlink(temp.path) == 0 || errno == ENOENT { store.forgetTemp(local: temp) }
            throw error
        }
    }

    public func upload(_ source: URL, to destination: RemotePath, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        try await upload(source, to: destination, tally: CopyTally(progress))
    }

    /// An upload whose `tally` may belong to a move or a retried paste (`TransferEngine`).
    func upload(_ source: URL, to destination: RemotePath, tally: CopyTally) async throws {
        try await copyToServer(.mac(source), at: destination, tally: tally)
    }

    /// Temp-and-rename onto the server, over the data channels. No collision check, but without
    /// `replacing` the rename refuses a name that something took since it was looked up.
    func uploadBytes(_ source: URL, to placed: RemotePath, replacing: Bool, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let local = LiveSync.stamp(source)
        let mode = ((try? FileManager.default.attributesOfItem(atPath: source.path))?[.posixPermissions] as? NSNumber)?.uint32Value
        let stamp = SFTPAttrs.stamp(mode: mode, mtime: local?.fingerprint.mtime)
        try await withRemoteTemp(for: placed) { temp in
            // The temp is renamed on the channel that wrote it, once every write is acknowledged.
            try await withData(DataShare(size: local?.size)) { link in
                try await self.send(source, size: local?.size, to: temp, on: link, stamp: stamp, progress: progress)
                try await link.place(temp, onto: placed, replacing: replacing, log: self.asides)
            }
        }
    }

    /// A Live save, on the interactive channel: `expecting` is what the destination must still be
    /// just before the rename; anything else throws `LiveRemoteChanged` and the temp is removed,
    /// so another person's edit is never overwritten. Returns the temp's fingerprint, which the
    /// rename carries onto the destination: read from our own temp, it cannot pick up someone
    /// else's later edit.
    func saveBytes(_ source: URL, to placed: RemotePath, expecting: ServerExpectation, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> Fingerprint? {
        // Only the time: a Live save keeps the server file's permissions, set below. The working
        // copy is private (0600), and its mode would take a script's execute bit and make a web
        // page unreadable.
        let stamp = SFTPAttrs.stamp(mode: nil, mtime: LiveSync.stamp(source)?.fingerprint.mtime)
        return try await withRemoteTemp(for: placed) { temp in
            try await withInteractive { link in try await link.upload(source, to: temp, stamp: stamp, progress: progress) }
            let link = try await metadataLink()
            let written = Fingerprint(item: try await link.lstat(temp))
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
            if let kept = found?.mode { try? await link.setstat(temp, SFTPAttrs(permissions: kept & 0o7777)) }
            try await link.replace(temp, onto: placed, log: asides)
            return written
        }
    }

    /// Files at least this large are split across up to `stripeWidth` data channels: one channel
    /// moves at most its 2 MB window per round trip, 100 MB/s at 20 ms (PERF-07).
    static let stripeSize: UInt64 = 8 << 20
    static let stripeWidth = 4

    /// Reads the server's file into `file` over one data channel, which a small file shares with
    /// others, and a large one also over the channels free now. Every channel checks that the file
    /// it opened is still the one `info` lists, whose size says where to stop.
    private func receive(_ path: RemotePath, info: RemoteItem, into file: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let print = Fingerprint(item: info)
        guard let size = info.size, size >= Self.stripeSize, let print else {
            // The channel creates the file, off this actor, once the job holds the channel.
            return try await withData(DataShare(size: info.size)) { link in
                try await link.download(path, to: file, size: info.size, matching: print, progress: progress)
            }
        }
        try await withData(.whole) { link in
            let parts = try DownloadParts(file, size: size, progress: progress)
            try await striped({ try await link.receive(path, into: parts, matching: print) }) {
                try await $0.receive(path, into: parts, matching: print, helping: true)
            }
            try parts.finish()
        }
    }

    /// Runs `first`, and `helper` on each of up to three more data channels free now, each taking
    /// the parts of the file it asks for next, until all are done. Any failing fails the whole.
    private func striped(_ first: @escaping @Sendable () async throws -> Void, helper: @escaping @Sendable (SFTPChannel) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask(operation: first)
            for _ in 1..<Self.stripeWidth {
                group.addTask { _ = try await self.withSpareData(helper) }
            }
            try await group.waitForAll()
        }
    }

    /// Writes `source`, of `size` bytes, into `temp`, a file it creates, over `link`, and a large
    /// one also over the channels free now. `stamp` goes on once every part is in.
    private func send(
        _ source: URL,
        size: UInt64?,
        to temp: RemotePath,
        on link: SFTPChannel,
        stamp: SFTPAttrs,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        guard let size, size >= Self.stripeSize else {
            // The channel opens the local file, off this actor.
            return try await link.upload(source, to: temp, stamp: stamp, progress: progress)
        }
        let parts = try UploadParts(source, progress: progress)
        let handle = try await link.create(temp)
        try await striped({ try await link.send(parts, to: handle) }) { try await $0.send(parts, into: temp) }
        try? await link.setstat(temp, stamp)
        parts.finish()
    }

    /// `SFTPChannel.lookup` on `link`, else on the metadata channel.
    func existing(_ path: RemotePath, on link: SFTPChannel? = nil) async throws -> RemoteItem? {
        if let link { return try await link.lookup(path) }
        return try await metadataLink().lookup(path)
    }

    // MARK: Directory copy

    /// Places the server's `item` as `name` in `folder`, a real folder on this Mac. `taken` says an
    /// earlier entry of the same listing claimed the name.
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
            guard let local = try await settleLocally(.folder, named: name, in: folder, taken: taken) else { return }
            if local.found != .folder {
                try LocalPlacement.makeFolder(local.url, replacing: local.found != nil)
                LocalPlacement.quarantine(local.url)
            }
            // Names this listing already used. A later one that folds the same (a duplicate, or two
            // names this Mac's disk takes for one) collides even before the first has landed.
            var used: Set<String> = []
            for try await child in await link.list(item.path) {
                try Task.checkCancellation()
                let taken = !used.insert(Placement.fold(child.name)).inserted
                do {
                    try await placeDown(child, named: child.name, in: local.url, taken: taken, link: link, group: &group, tally: tally)
                } catch {
                    try tally.failed(child.name, error)
                }
            }
        case .symlink:
            let target = try await link.readlink(item.path)
            if let spot = try await settleLocally(.link(target), named: name, in: folder, taken: taken) {
                try LocalPlacement.makeLink(spot.url, target: target, replacing: spot.found != nil)
            }
            tally.finished()
        case .file:
            guard let placed = try await settleLocally(.file(Fingerprint(item: item)), named: name, in: folder, taken: taken) else {
                return tally.finished()
            }
            if tally.addingJob() { _ = try await group.next() }
            group.addTask {
                do {
                    try await self.fetch(item.path, info: item, to: placed.url, replacing: placed.found != nil, quarantine: true, progress: tally.file())
                    tally.finished()
                } catch {
                    try tally.failed(name, error)
                }
            }
        case .other:
            return
        }
    }

    /// Where `incoming` lands as `name` in `folder`, and what holds that spot now; nil to skip it.
    /// What holds the name is read without following a link. `taken` says an earlier entry of the
    /// same listing claimed the name and may not have landed yet.
    private func settleLocally(_ incoming: PlacedItem, named name: String, in folder: URL, taken: Bool) async throws -> (url: URL, found: PlacedItem?)? {
        let url = try LocalPlacement.child(folder, name: name)
        var found = try LocalPlacement.occupant(url)
        if taken, found == nil { found = .other }
        switch try await settle(incoming, onto: found, named: name, shown: name) {
        case .skip: return nil
        case .replace: return (url, found)
        case .keepBoth: return (try LocalPlacement.keepBoth(url, isFolder: incoming == .folder), nil)
        }
    }

    // MARK: Copies onto the server

    public func copy(_ source: RemotePath, to destination: RemotePath, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        try await copy(source, to: destination, tally: CopyTally(progress))
    }

    /// A copy on the server whose `tally` may belong to a retried paste (`TransferEngine`). A
    /// folder is never copied into itself, as named or as the server resolves the two folders:
    /// through a link into the source, the walk would read its own output until the disk filled.
    func copy(_ source: RemotePath, to destination: RemotePath, tally: CopyTally) async throws {
        if let refusal = PasteRules.refusal(sources: [source], into: destination) { throw TransferError.failed(refusal) }
        if let from = source.parent, let into = destination.parent {
            let link = try await metadataLink()
            let real = try await link.realpath(from).appending(name: source.nameBytes)
            let target = try await link.realpath(into).appending(name: destination.nameBytes)
            if let refusal = PasteRules.refusal(sources: [real], into: target) { throw TransferError.failed(refusal) }
        }
        try await copyToServer(.server(try await stat(source)), at: destination, tally: tally)
    }

    /// Where a copy onto the server comes from: this Mac, or the same server.
    private enum Source: Sendable {
        case mac(URL)
        case server(RemoteItem)
    }

    private func copyToServer(_ source: Source, at destination: RemotePath, tally: CopyTally) async throws {
        let link = try await walkerLink()
        guard let incoming = try await incoming(source, link: link) else {
            if case .mac(let url) = source { throw TransferError.noSuchFile(url.path) }
            return
        }
        let found = try await existing(destination)
        try await withThrowingTaskGroup(of: Void.self) { group in
            try await placeUp(source, incoming, at: destination, found: found, link: link, group: &group, tally: tally)
            try await group.waitForAll()
        }
        if let parent = destination.parent { pipe.emit(.directoryChanged(parent)) }
        try tally.check()
    }

    /// Places `source`, which is `incoming`, at `destination` on the server, where `found` is.
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
            try await remoteLink(target, at: destination, found: found, tally: tally)
            tally.finished()
        case .folder:
            guard let folder = try await remoteFolder(destination, found: found, tally: tally) else { return }
            // A folder already there is listed once, not looked up name by name (PERF-03).
            var held = Holdings()
            if !folder.made { for try await item in await link.list(folder.path) { held.add(item) } }
            switch source {
            case .mac(let url):
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try Task.checkCancellation()
                    try await placeChild(.mac(child), in: folder.path, held: held, link: link, group: &group, tally: tally)
                }
            case .server(let item):
                for try await child in await link.list(item.path) {
                    try Task.checkCancellation()
                    try await placeChild(.server(child), in: folder.path, held: held, link: link, group: &group, tally: tally)
                }
            }
        case .file:
            guard let placed = try await settleRemotely(incoming, at: destination, found: found, tally: tally) else { return tally.finished() }
            let replacing = placed.found != nil
            if tally.addingJob() { _ = try await group.next() }
            group.addTask {
                do {
                    switch source {
                    case .mac(let url):
                        try await self.uploadBytes(url, to: placed.path, replacing: replacing, progress: tally.file())
                        tally.finished()
                    case .server(let item):
                        try await self.copyFile(item, to: placed.path, replacing: replacing)
                        tally.finished(bytes: item.size ?? 0)
                    }
                    tally.record(placed.path)
                } catch {
                    try tally.failed(destination.name, error)
                }
            }
        }
    }

    /// One entry of a folder being copied onto the server, which holds `held`. Its failure is
    /// recorded, not thrown, unless it ends the whole copy.
    private func placeChild(
        _ source: Source,
        in folder: RemotePath,
        held: Holdings,
        link: SFTPChannel,
        group: inout ThrowingTaskGroup<Void, Error>,
        tally: CopyTally
    ) async throws {
        let name = switch source {
        case .mac(let url): Array(url.lastPathComponent.utf8)
        case .server(let item): item.path.nameBytes
        }
        let destination = folder.appending(name: name)
        do {
            guard let incoming = try await incoming(source, link: link) else { return }
            try await placeUp(source, incoming, at: destination, found: try await held.item(named: name, at: destination, on: self), link: link, group: &group, tally: tally)
        } catch {
            try tally.failed(destination.name, error)
        }
    }

    /// `source` to the placement rules, read without following a link; nil for a Mac file gone.
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
    /// is, and what holds that spot; nil to skip it. A retry goes where Keep Both sent the item
    /// before, unasked; in a move, only a copy this move wrote passes for the same file.
    private func settleRemotely(_ incoming: PlacedItem, at proposed: RemotePath, found: RemoteItem?, tally: CopyTally) async throws -> (path: RemotePath, found: PlacedItem?)? {
        if let landed = tally.landed(proposed) {
            return try await settleRemotely(incoming, at: landed, found: try await existing(landed), tally: tally)
        }
        let there = try await placedItem(found)
        let moving = tally.moving && !tally.wrote(proposed)
        switch try await settle(incoming, onto: there, moving: moving, named: proposed.name, shown: proposed.display) {
        case .skip:
            return nil
        case .replace:
            return (proposed, there)
        case .keepBoth:
            let parent = proposed.parent ?? RemotePath(string: "/")
            let name = Placement.keepBoth(proposed.name, among: try await listedNames(parent), isFolder: incoming == .folder)
            let landed = parent.appending(name: Array(name.utf8))
            tally.record(landed, for: proposed)
            return (landed, nil)
        }
    }

    /// The server folder a folder merges into or is made as, and whether it was made; nil to skip
    /// it. A link or special file in the way goes only when the user chose Replace, and only if it
    /// still holds the name: a listing may be stale, and something else may have taken the name
    /// while the question was up. A folder never goes.
    private func remoteFolder(_ path: RemotePath, found: RemoteItem?, tally: CopyTally) async throws -> (path: RemotePath, made: Bool)? {
        guard let spot = try await settleRemotely(.folder, at: path, found: found, tally: tally) else { return nil }
        if spot.found == .folder { return (spot.path, false) }
        let link = try await metadataLink()
        if let asked = spot.found {
            guard try await placedItem(try await link.lookup(spot.path), link: link) == asked else {
                throw TransferError.failed("“\(spot.path.name)” changed on the server while it was being replaced; nothing was removed")
            }
            try await link.removeFile(spot.path)
        }
        try await link.mkdir(spot.path)
        tally.record(spot.path)
        return (spot.path, true)
    }

    /// A link is copied as a link, settled like a file: the same link is kept, anything else is
    /// asked about, and Replace swaps it in with one rename.
    private func remoteLink(_ target: String, at destination: RemotePath, found: RemoteItem?, tally: CopyTally) async throws {
        guard let spot = try await settleRemotely(.link(target), at: destination, found: found, tally: tally) else { return }
        let link = try await metadataLink()
        if spot.found == nil {
            try await link.symlink(target: target, link: spot.path)
        } else {
            try await withRemoteTemp(for: spot.path) { temp in
                try await link.symlink(target: target, link: temp)
                try await link.replace(temp, onto: spot.path, log: asides)
            }
        }
        tally.record(spot.path)
    }

    /// Temp-and-rename on the server, keeping the source's mode and time so a later copy of the
    /// same file is skipped. `copy-data` when the server has it; else down to the Mac and back.
    /// The temp is renamed on the channel that wrote it, once the copy and its close are acknowledged.
    private func copyFile(_ item: RemoteItem, to placed: RemotePath, replacing: Bool) async throws {
        let stamp = SFTPAttrs.stamp(mode: item.mode.map { $0 & 0o7777 }, mtime: item.mtime)
        try await withRemoteTemp(for: placed) { temp in
            let onServer = try await withData(DataShare(size: item.size)) { link in
                guard await link.extensions.contains("copy-data") else { return false }
                try await link.copyData(item.path, to: temp, stamp: stamp)
                try await link.place(temp, onto: placed, replacing: replacing, log: self.asides)
                return true
            }
            guard !onServer else { return }
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: scratch) }
            try await fetch(item.path, info: item, to: scratch) { _ in }
            try await withData(DataShare(size: item.size)) { link in
                try await self.send(scratch, size: item.size, to: temp, on: link, stamp: stamp) { _ in }
                try await link.place(temp, onto: placed, replacing: replacing, log: self.asides)
            }
        }
    }

    /// Runs `body` on a hidden temp beside `placed`, recorded so a later login removes it if this
    /// run cannot. `body` writes the temp and renames it into place.
    private func withRemoteTemp<T>(for placed: RemotePath, _ body: (RemotePath) async throws -> T) async throws -> T {
        let parent = placed.parent ?? RemotePath(string: "/")
        let temp = parent.appending(name: Array(CopyRules.tempName(for: placed.name, transferID: UUID().uuidString).utf8))
        store.rememberTemp(temp, connection: connection.id)
        do {
            let result = try await body(temp)
            store.forgetTemp(temp)
            return result
        } catch {
            await discardRemoteTemp(temp)
            throw error
        }
    }

    /// Removes a temp left by a failed or cancelled write, or a move's empty probe folder, and
    /// forgets it once it is gone; a file `replace` set aside goes back to its name, unless the
    /// replace got as far as putting the new file there. The work runs in a task of its own, so
    /// the cancel that stopped the write does not stop it too. When the server cannot be reached,
    /// the record stays and the next login does it.
    func discardRemoteTemp(_ temp: RemotePath) async {
        await Task {
            do {
                let link = try await metadataLink()
                if let (aside, placed) = Self.aside(in: temp) {
                    if try await link.lookup(aside) != nil {
                        if try await link.lookup(placed) == nil { try await link.rename(aside, to: placed) } else { try await link.removeFile(aside) }
                    }
                } else {
                    do {
                        try await link.removeFile(temp)
                    } catch TransferError.noSuchFile {
                    } catch {
                        guard try await link.lookup(temp)?.kind == .directory else { throw error }
                        try await link.removeDirectory(temp)
                    }
                }
            } catch TransferError.noSuchFile {
            } catch {
                return
            }
            store.forgetTemp(temp)
        }.value
    }

    /// Records the files `replace` sets aside with the temps.
    var asides: SFTPChannel.AsideLog {
        let (store, id) = (store, connection.id)
        return SFTPChannel.AsideLog(
            remember: { store.rememberTemp(Self.asideRecord($0, $1), connection: id) },
            forget: { store.forgetTemp(Self.asideRecord($0, $1)) }
        )
    }

    /// The temp record of a file set aside: its path and its name's, joined by a NUL, which no
    /// path holds.
    static func asideRecord(_ aside: RemotePath, _ placed: RemotePath) -> RemotePath {
        RemotePath(bytes: aside.bytes + [0] + placed.bytes)
    }

    /// The aside and its name, from an `asideRecord`; nil for any other record.
    static func aside(in record: RemotePath) -> (aside: RemotePath, placed: RemotePath)? {
        guard let split = record.bytes.firstIndex(of: 0) else { return nil }
        return (RemotePath(bytes: Array(record.bytes[..<split])), RemotePath(bytes: Array(record.bytes[(split + 1)...])))
    }

    public nonisolated func walkTree(_ root: RemotePath) -> AsyncThrowingStream<(TreeKey, TreeEntry), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let link = try await self.walkerLink()
                    let item = try await link.lstat(root)
                    continuation.yield(("", TreeEntry(item)))
                    if item.kind == .directory {
                        try await self.walk(root, key: "", link: link) { continuation.yield(($0, $1)) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func walk(_ folder: RemotePath, key parent: TreeKey, link: SFTPChannel, visit: @escaping @Sendable (TreeKey, TreeEntry) -> Void) async throws {
        for try await child in await link.list(folder) {
            try Task.checkCancellation()
            // Special files are reported too: no copy writes them, so a move that compares the
            // trees keeps a folder holding one instead of removing it unseen.
            let key = parent.appending(child.path.nameBytes)
            visit(key, TreeEntry(child))
            if child.kind == .directory {
                try await walk(child.path, key: key, link: link, visit: visit)
            }
        }
    }

    // MARK: View and preview

    public func prepareViewFile(_ path: RemotePath) async throws -> URL {
        try await cachedCopy(stat(path), lane: .view)
    }

    public func prepareInspectorPreview(_ path: RemotePath) async throws -> URL {
        let item = try await stat(path)
        let head = UInt64(EditableFile.previewHead)
        guard EditableFile.openKind(fileName: item.name, extensions: editableExtensions) == .live,
              let print = Fingerprint(item: item), print.size > head else {
            return try await cachedCopy(item, lane: .preview)
        }
        // Only the head of a text file is shown, so only the head is fetched. The copy is named for
        // the file's size and time, so an unchanged file reuses it.
        let file = try previewURL(path, name: item.name, version: "head \(print.size):\(print.mtime)")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        try await fetchHead(path, limit: head, to: file)
        trimPreviewCache()
        return file
    }

    /// The first `limit` bytes of `path`, on the preview lane.
    private func fetchHead(_ path: RemotePath, limit: UInt64, to file: URL) async throws {
        try await lane.submit(.preview) {
            try await self.fetch(path, info: RemoteItem(path: path, kind: .file, size: limit), to: file, quarantine: true) { _ in }
        }
    }

    /// The whole file in the preview cache, fetched on the lane as `kind`.
    private func cachedCopy(_ item: RemoteItem, lane kind: InteractiveLane.Kind) async throws -> URL {
        let path = item.path
        let file = try previewURL(path, name: item.name)
        // The copy carries the remote size and mtime; the same pair means the same bytes.
        if let print = Fingerprint(item: item), (try? LocalPlacement.occupant(file)) == .file(print) { return file }
        try await lane.submit(kind) {
            try await self.fetch(path, info: item, to: file, quarantine: true) { _ in }
        }
        trimPreviewCache()
        return file
    }

    public func preparePreview(_ path: RemotePath) async throws -> URL {
        let item = try await stat(path)
        if EditableFile.openKind(fileName: item.name, extensions: editableExtensions) == .live {
            // The page is named for the file's size and time too, so an unchanged file reuses it.
            let print = Fingerprint(item: item)
            let file = try previewURL(path, name: item.name, suffix: ".html", version: print.map { "\($0.size):\($0.mtime)" } ?? "")
            if print != nil, FileManager.default.fileExists(atPath: file.path) { return file }
            let part = try previewURL(path, name: item.name, suffix: ".part")
            let limit: UInt64 = 512 * 1024
            try await fetchHead(path, limit: min(item.size ?? limit, limit), to: part)
            defer { try? FileManager.default.removeItem(at: part) }
            let data = try Data(contentsOf: part)
            guard let text = String(data: data, encoding: .utf8) else {
                return try await cachedCopy(item, lane: .preview)
            }
            let html = SyntaxPreview.html(text: text, fileName: item.name)
            try html.write(to: file, atomically: true, encoding: .utf8)
            trimPreviewCache()
            return file
        }
        return try await cachedCopy(item, lane: .preview)
    }

    public func clearPreviewCache() async {
        try? FileManager.default.removeItem(at: previewCacheDirectory)
    }

    private var previewCacheDirectory: URL {
        store.cacheRoot.appendingPathComponent("Preview", isDirectory: true)
    }

    /// The cache file for `path` on this server: the remote file's own name (plus `suffix`, cut to
    /// fit), in a folder named for the server, the path, and `version`, since two servers can hold
    /// different files at one path. The name is what Quick Look's Open With and an app viewing the
    /// copy show and open, where a digest meant nothing.
    private func previewURL(_ path: RemotePath, name: String, suffix: String = "", version: String = "") throws -> URL {
        var cache = previewCacheDirectory
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? cache.setResourceValues(values)
        let key = Data(connection.id.rawValue.uuidString.utf8) + Data(path.bytes) + Data([0]) + Data(version.utf8)
        let digest = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        let folder = cache.appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fits = suffix.isEmpty && name.utf8.count <= 255
        return folder.appendingPathComponent(fits ? name : LiveDecision.siblingName(of: name, suffix: suffix))
    }

    /// Evicts whole entries, each a file's folder (or a digest-named file from before names were
    /// kept), by the last use of what it holds, in one walk of the cache.
    private func trimPreviewCache() {
        let root = previewCacheDirectory.path
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: previewCacheDirectory, includingPropertiesForKeys: Array(keys)) else { return }
        var entries: [String: CacheEntry] = [:]
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            let used = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            let parent = url.deletingLastPathComponent().path
            let id = values.isDirectory == true || parent == root ? url.path : parent
            var entry = entries[id] ?? CacheEntry(id: id, size: 0, lastUsed: .distantPast)
            if values.isDirectory != true { entry.size += UInt64(values.fileSize ?? 0) }
            entry.lastUsed = max(entry.lastUsed, used)
            entries[id] = entry
        }
        for victim in CacheEviction.victims(Array(entries.values), limit: CacheEviction.previewLimit) {
            try? FileManager.default.removeItem(atPath: victim)
        }
    }

    // MARK: Collisions

    /// Where `incoming` goes when `found` holds its name, on either side: `.replace` writes there
    /// (onto nothing, into a folder it merges with, or over what the user chose to replace),
    /// `.keepBoth` beside it. A collision is the operation's question, never the login sink's,
    /// which belongs to whichever window logged in; with nobody to ask, the operation fails.
    /// `shown` names the item in a type mismatch.
    private func settle(_ incoming: PlacedItem, onto found: PlacedItem?, moving: Bool = false, named name: String, shown: String) async throws -> NameCollisionChoice {
        switch Placement.settle(incoming, onto: found, moving: moving) {
        case .write, .merge: return .replace
        case .skip: return .skip
        case .typeMismatch: throw TransferError.typeMismatch(shown)
        case .collide:
            guard let choice = await OperationPrompts.current?.resolveCollision(fileName: name) else {
                throw TransferError.failed("“\(name)” already exists there, and there is no window to ask whether to replace it")
            }
            return choice
        }
    }

    func listedNames(_ path: RemotePath) async throws -> Set<String> {
        var names: Set<String> = []
        for try await item in try await metadataLink().list(path) { names.insert(item.name) }
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
    /// File jobs in the copy's task group not yet taken back from it.
    private let jobs = Locked(0)
    /// A move's copy: the same file already at a destination is asked about, not skipped.
    let moving: Bool
    /// What a paste wrote and where Keep Both sent items, kept across its retries; nil for a copy
    /// that is not part of one. Only the entries of source `item` are this copy's.
    private let memo: Locked<TransferMemo>?
    private let item: Int

    /// Twice what the data channels carry at once (seven, sixteen small files each): as many jobs
    /// again have settled their names and wait, so a channel never idles while the walk finds the
    /// next. Only a job holding a channel has a file open. 2,000 small files at 20 ms, files/s
    /// down / up / server copy: 16 jobs 339 / 226 / 199; 112 jobs 1,590 / 1,578 / 1,269; 224 jobs
    /// 2,194 / 1,624 / 1,482.
    static let jobLimit = 2 * SSHConnection.dataChannels * SSHConnection.DataShare.whole.rawValue

    init(_ report: @escaping @Sendable (TransferProgress) -> Void, memo: Locked<TransferMemo>? = nil, item: Int = 0, moving: Bool = false) {
        self.report = report
        self.memo = memo
        self.item = item
        self.moving = moving
    }

    /// `path` was written by this copy: a file, a link, or a folder it made.
    func record(_ path: RemotePath) {
        memo?.withLock { _ = $0.written[item, default: []].insert(path) }
    }

    func wrote(_ path: RemotePath) -> Bool {
        memo?.withLock { $0.written[item]?.contains(path) } ?? false
    }

    /// Keep Both sent the entry offered at `proposed` to `landed`.
    func record(_ landed: RemotePath, for proposed: RemotePath) {
        memo?.withLock { $0.landed[item, default: [:]][proposed] = landed }
    }

    func landed(_ proposed: RemotePath) -> RemotePath? {
        memo?.withLock { $0.landed[item]?[proposed] }
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

    /// Counts a file job in, and says whether one must first be taken back from the task group,
    /// since a walk finds names faster than the channels move bytes. At the limit, one taken back
    /// and one added leaves the count there.
    func addingJob() -> Bool {
        jobs.withLock { count in
            if count == Self.jobLimit { return true }
            count += 1
            return false
        }
    }

    /// An item is done: copied, or skipped as already there. `bytes` are those not reported as they went.
    func finished(bytes: UInt64 = 0) {
        add(bytes: bytes, items: 1)
    }

    /// Records that `name` failed and lets the copy go on, or rethrows an error that ends it.
    func failed(_ name: String, _ error: any Error) throws {
        if Self.ends(error) { throw error }
        state.withLock { $0.failures.append((name, error)) }
    }

    /// Whether `error` ends a whole copy or paste, not just one item: a cancel, a dropped
    /// connection, or a timeout, on which it stops or is retried.
    static func ends(_ error: any Error) -> Bool {
        if error is CancellationError || RetryPolicy.isRetryable(error) { return true }
        guard let error = error as? TransferError else { return false }
        return error == .cancelled || error == .notConnected
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

/// What a destination folder on the server holds, by name, from one listing; empty for a folder
/// just made.
private struct Holdings: Sendable {
    private var items: [[UInt8]: RemoteItem] = [:]
    private var folded: Set<String> = []

    mutating func add(_ item: RemoteItem) {
        items[item.path.nameBytes] = item
        folded.insert(Placement.fold(item.name))
    }

    /// The item named `name`. A name the listing holds only in another case or Unicode form is
    /// looked up, since the server's disk may take the two for one.
    func item(named name: [UInt8], at path: RemotePath, on session: SSHConnection) async throws -> RemoteItem? {
        if let item = items[name] { return item }
        guard folded.contains(Placement.fold(String(decoding: name, as: UTF8.self))) else { return nil }
        return try await session.existing(path)
    }
}
