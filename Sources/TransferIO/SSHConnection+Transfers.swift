import CryptoKit
import Foundation
import TransferCore

/// Removal, downloads, uploads, copies on the server, tree walks, and the preview cache. Every
/// name from a server reaches this Mac's disk through `LocalPlacement`, and whatever holds a
/// destination's name is settled by `Placement`, the same way in every direction.
extension SSHConnection {
    // MARK: Remove

    public func remove(_ path: RemotePath, force: Bool = false) async throws {
        try await live.remove(path, on: connection.id, force: force) {
            let link = try await self.walkerLink()
            _ = try await self.removeTree(path, as: TreeEntry(try await link.lstat(path)), link: link)
        }
        if let parent = path.parent { pipe.emit(.directoryChanged(parent)) }
    }

    /// Removes a moved original: only what the move verified of it, `verified` by key as it was
    /// then. A file changed or added since stays, with the folders holding it, and so does all of
    /// it when a Live file under it was saved since `mark` (`LiveSync.saveMark`, read before the
    /// copy): the copy may lack those bytes. Returns whether all of it went.
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
    func walkerLink() async throws -> SFTPChannel {
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
        // Small files of a folder go in tar batches; a single file is never worth a stream. The
        // probe, once per login, runs while the walk lists the first folders.
        let batch = item.kind == .directory && tarCommand != nil ? TarBatcher(self) : nil
        if batch != nil { Task { _ = await self.tarReady() } }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                try await placeDown(item, named: destination.lastPathComponent, in: folder, link: link, batch: batch, group: &group, tally: tally)
                if let batch {
                    let rest = batch.drain()
                    // No batch went: the rest goes over SFTP, on every channel.
                    if !rest.stream { releaseTarPlaces(batch.feeds) }
                    if !rest.jobs.isEmpty {
                        if tally.addingJob() { _ = try await group.next() }
                        group.addTask { try await self.receiveBatch(rest.jobs, in: rest.stream ? batch.feeds : nil, tally: tally) }
                    }
                    batch.feeds.finish()
                }
                try await group.waitForAll()
            }
        } catch {
            batch?.feeds.cancel()
            throw error
        }
        try tally.check()
    }

    /// One batch, sent down one of `feeds`' streams: what it does not land goes over SFTP, each
    /// file on its own, and a file that fails is the copy's failure as any other is.
    private func receiveBatch(_ jobs: [TarJob], in feeds: TarFeeds?, tally: CopyTally) async throws {
        var left = jobs
        if let ticket = await feeds?.submit(jobs, store: store) {
            let written = await withTaskCancellationHandler { await ticket.written() } onCancel: { ticket.feed.cancel() }
            left = []
            for (job, outcome) in zip(jobs, try await landTarBatch(jobs, temps: ticket.temps, written: written)) {
                switch outcome {
                case .landed:
                    tarLanded += 1
                    tally.finished(bytes: job.item.size ?? 0)
                case .sftp: left.append(job)
                case .failed(let error): try tally.failed(job.destination.lastPathComponent, error)
                }
            }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for job in left {
                group.addTask {
                    do {
                        try await self.fetch(job.item.path, info: job.item, to: job.destination, replacing: job.replacing, progress: tally.file())
                        tally.finished()
                    } catch {
                        try tally.failed(job.destination.lastPathComponent, error)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// Temp-and-rename into `destination`'s folder, which the caller made. No collision check, but
    /// without `replacing` the rename refuses a name that something took since it was looked up.
    /// The file takes the server's permissions under this process's umask, as `sftp get` does,
    /// without setuid, setgid, or sticky, which an untrusted server must not grant; `readOnly`
    /// drops the write bits too, and a `live` working copy is private (0600) as it lands. Every
    /// download is quarantined as a browser's is, a Live working copy too, as the app it opens in may
    /// run it (D2), except a Live Terminal script, which Gatekeeper lets no editor open
    /// (`EditableFile.quarantinesLiveCopy`); being 0600, it runs nowhere. A temp in the library's
    /// `Scratch/`, which each launch empties, is not `recorded`.
    func fetch(
        _ path: RemotePath,
        info: RemoteItem,
        to destination: URL,
        replacing: Bool = true,
        readOnly: Bool = false,
        live: Bool = false,
        interactive: Bool = false,
        recorded: Bool = true,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let folder = destination.deletingLastPathComponent()
        let temp = folder.appendingPathComponent(KeepBothName.temp(for: destination.lastPathComponent))
        if recorded { store.rememberTemp(local: temp) }
        do {
            try await receive(path, info: info, into: temp, interactive: interactive, progress: progress)
            try Self.land(temp, as: destination, info: info, replacing: replacing, readOnly: readOnly, live: live)
            if recorded { store.forgetTemp(local: temp) }
        } catch {
            // A temp that cannot be removed now stays recorded, and the next launch removes it.
            if unlink(temp.path) == 0 || errno == ENOENT, recorded { store.forgetTemp(local: temp) }
            throw error
        }
    }

    /// Puts the finished `temp`, the server's file `info`, in place as `destination`: quarantined,
    /// given its mode and time, and renamed, replacing what holds the name only when `replacing`.
    nonisolated static func land(_ temp: URL, as destination: URL, info: RemoteItem, replacing: Bool, readOnly: Bool = false, live: Bool = false) throws {
        // Marked first: a file without write bits takes no extended attribute. The channel
        // created it with 0o666 under the umask, which no mode listed keeps.
        if !live || EditableFile.quarantinesLiveCopy(fileName: info.path.name) { LocalPlacement.quarantine(temp) }
        let mode = live ? 0o600 : (info.mode ?? 0o666) & (readOnly ? 0o555 : 0o777) & ~Self.fileMask
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: Int(mode)]
        if let mtime = info.mtime { attributes[.modificationDate] = Date(timeIntervalSince1970: TimeInterval(mtime)) }
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: temp.path)
        // One rename replaces the destination, so a watched Live copy is never briefly missing.
        let placed = replacing ? Darwin.rename(temp.path, destination.path) : renamex_np(temp.path, destination.path, UInt32(RENAME_EXCL))
        guard placed == 0 else {
            throw TransferError.failed("Could not place \(destination.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    /// This process's umask. Read once: reading it means setting it, which races with any file
    /// another thread creates meanwhile.
    private static let fileMask: UInt32 = {
        let mask = umask(0o022)
        umask(mask)
        return UInt32(mask)
    }()

    public func upload(_ source: URL, to destination: RemotePath, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        try await upload(source, to: destination, tally: CopyTally(progress))
    }

    /// An upload whose `tally` may belong to a move or a retried paste (`TransferEngine`).
    func upload(_ source: URL, to destination: RemotePath, tally: CopyTally) async throws {
        try await copyToServer(.mac(source), at: destination, tally: tally)
    }

    /// Temp-and-rename onto the server, over the data channels. `replacing` is what the user chose
    /// to replace there, which alone goes; nil for a free name, which the rename refuses to take
    /// from something that took it since it was looked up.
    func uploadBytes(_ source: URL, to placed: RemotePath, replacing: PlacedItem?, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let local = LiveSync.stamp(source)
        let mode = ((try? FileManager.default.attributesOfItem(atPath: source.path))?[.posixPermissions] as? NSNumber)?.uint32Value
        let stamp = SFTPAttrs.stamp(mode: mode, mtime: local?.fingerprint.mtime)
        try await withRemoteTemp(for: placed) { temp in
            // The temp is renamed on the channel that wrote it, once every write is acknowledged.
            try await withData(DataShare(size: local?.size)) { link in
                try await self.send(source, size: local?.size, to: temp, on: link, stamp: stamp, progress: progress)
                try await self.place(temp, onto: placed, replacing: replacing, on: link)
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
            let found = try await link.lookup(placed)
            // "Absent" means nothing at all there: a folder or a link is not absent.
            let matches = switch expecting {
            case .file(let print): found.flatMap(Fingerprint.init(item:)) == print
            case .absent: found == nil
            }
            if !matches { throw LiveRemoteChanged() }
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
    /// it opened is still the one `info` lists, whose size says where to stop. An `interactive`
    /// file, one the user waits on, starts on the interactive channel: the data pool serves its
    /// waiters in order, behind every job of a folder copy (SES2-02).
    private func receive(_ path: RemotePath, info: RemoteItem, into file: URL, interactive: Bool, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let print = Fingerprint(item: info)
        guard let size = info.size, size >= Self.stripeSize, let print else {
            // The channel creates the file, off this actor, once the job holds the channel.
            return try await withChannel(interactive: interactive, DataShare(size: info.size)) { link in
                try await link.download(path, to: file, size: info.size, matching: print, progress: progress)
            }
        }
        try await withChannel(interactive: interactive, .whole) { link in
            let parts = try DownloadParts(file, size: size, progress: progress)
            try await striped({ try await link.receive(path, into: parts, matching: print) }) {
                try await $0.receive(path, into: parts, matching: print, helping: true)
            }
            try parts.finish()
        }
    }

    private func withChannel<T>(interactive: Bool, _ share: DataShare, _ body: (SFTPChannel) async throws -> T) async throws -> T {
        if interactive { return try await withInteractive(body) }
        return try await withData(share, body)
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

    /// `SFTPChannel.lookup` on the metadata channel.
    func existing(_ path: RemotePath) async throws -> RemoteItem? {
        try await metadataLink().lookup(path)
    }

    /// Whether any of `folders` holds `name`.
    func holds(_ name: String, inAny folders: Set<RemotePath>) async throws -> Bool {
        for folder in folders where try await existing(folder.appending(name)) != nil { return true }
        return false
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
        listed: Task<[RemoteItem], Error>? = nil,
        batch: TarBatcher? = nil,
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
            // Folders wait until the rest of the listing is placed, so they can be listed ahead.
            var folders: [(item: RemoteItem, taken: Bool)] = []
            let children: AsyncThrowingStream<RemoteItem, Error> = if let listed { Self.stream(listed) } else { await link.list(item.path) }
            for try await child in children {
                try Task.checkCancellation()
                let taken = !used.insert(child.name.diskFolded).inserted
                if child.kind == .directory {
                    folders.append((child, taken))
                    continue
                }
                do {
                    try await placeDown(child, named: child.name, in: local.url, taken: taken, link: link, batch: batch, group: &group, tally: tally)
                } catch {
                    try tally.failed(child.name, error)
                }
            }
            // Each folder is listed while those before it are placed, up to `walkWidth` at once
            // across every walk (`listings`): one at a time, each folder's listing cost its own
            // round trips before a byte of it moved.
            var ahead: [Task<[RemoteItem], Error>] = []
            defer { for listing in ahead { listing.cancel() } }
            for (index, folder) in folders.enumerated() {
                while ahead.count < min(folders.count, index + Self.walkWidth) {
                    let path = folders[ahead.count].item.path
                    ahead.append(Task { [listings] in
                        await listings.enter()
                        defer { listings.leave() }
                        var items: [RemoteItem] = []
                        for try await child in await link.list(path) { items.append(child) }
                        return items
                    })
                }
                do {
                    try await placeDown(folder.item, named: folder.item.name, in: local.url, taken: folder.taken, link: link, listed: ahead[index], batch: batch, group: &group, tally: tally)
                } catch {
                    try tally.failed(folder.item.name, error)
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
            // Places for the streams are kept from the first small file (`keepTarPlaces`).
            if let batch, !tarMissing, TarBatching.takes(size: item.size, mtime: item.mtime) { keepTarPlaces(batch.feeds) }
            if let batch, !tarMissing, TarBatching.takes(size: item.size, mtime: item.mtime),
               let full = batch.add(TarJob(item: item, destination: placed.url, replacing: placed.found != nil)) {
                guard !full.isEmpty else { return }
                if tally.addingJob() { _ = try await group.next() }
                group.addTask { try await self.receiveBatch(full, in: batch.feeds, tally: tally) }
                return
            }
            if tally.addingJob() { _ = try await group.next() }
            group.addTask {
                do {
                    try await self.fetch(item.path, info: item, to: placed.url, replacing: placed.found != nil, progress: tally.file())
                    tally.finished()
                } catch {
                    try tally.failed(name, error)
                }
            }
        case .other:
            return
        }
    }

    /// A listing read ahead, as the stream `SFTPChannel.list` gives one.
    private static func stream(_ listed: Task<[RemoteItem], Error>) -> AsyncThrowingStream<RemoteItem, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for item in try await listed.value { continuation.yield(item) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
            let held = folder.made ? Holdings() : try await holdings(folder.path, link: link)
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
            guard let placed = try await settleRemotely(incoming, at: destination, found: found, tally: tally) else {
                // Already there, as after a retry: its bytes count, so the row reaches its total.
                guard case .file(let print?) = incoming else { return tally.finished() }
                return tally.finished(bytes: print.size)
            }
            let replacing = placed.found
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

    /// What `folder` holds now, listed once on `link`, else the walker passenger.
    func holdings(_ folder: RemotePath, link: SFTPChannel? = nil) async throws -> Holdings {
        let reader = if let link { link } else { try await walkerLink() }
        var held = Holdings()
        for try await item in await reader.list(folder) { held.add(item) }
        return held
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
    /// before, unasked; in a move, only a copy this move wrote passes for the same file. Keep Both
    /// also passes over `reserved`, names other items of the paste are still writing.
    func settleRemotely(_ incoming: PlacedItem, at proposed: RemotePath, found: RemoteItem?, tally: CopyTally, reserved: Set<String> = []) async throws -> (path: RemotePath, found: PlacedItem?)? {
        if let landed = tally.landed(proposed) {
            return try await settleRemotely(incoming, at: landed, found: try await existing(landed), tally: tally, reserved: reserved)
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
            let name = Placement.keepBoth(proposed.name, among: try await listedNames(parent).union(reserved), isFolder: incoming == .folder)
            let landed = parent.appending(name: Array(name.utf8))
            tally.record(landed, for: proposed)
            return (landed, nil)
        }
    }

    /// The server folder a folder merges into or is made as, and whether it was made; nil to skip
    /// it. A link or special file in the way goes only when the user chose Replace, and only if it
    /// still holds the name: a listing may be stale, and something else may have taken the name
    /// while the question was up. A folder never goes.
    func remoteFolder(_ path: RemotePath, found: RemoteItem?, tally: CopyTally, reserved: Set<String> = []) async throws -> (path: RemotePath, made: Bool)? {
        guard let spot = try await settleRemotely(.folder, at: path, found: found, tally: tally, reserved: reserved) else { return nil }
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
    func remoteLink(_ target: String, at destination: RemotePath, found: RemoteItem?, tally: CopyTally, reserved: Set<String> = []) async throws {
        guard let spot = try await settleRemotely(.link(target), at: destination, found: found, tally: tally, reserved: reserved) else { return }
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
    private func copyFile(_ item: RemoteItem, to placed: RemotePath, replacing: PlacedItem?) async throws {
        let stamp = SFTPAttrs.stamp(mode: item.mode.map { $0 & 0o7777 }, mtime: item.mtime)
        try await withRemoteTemp(for: placed) { temp in
            let onServer = try await withData(DataShare(size: item.size)) { link in
                guard await link.extensions.contains("copy-data") else { return false }
                try await link.copyData(item.path, to: temp, stamp: stamp)
                try await self.place(temp, onto: placed, replacing: replacing, on: link)
                return true
            }
            guard !onServer else { return }
            let scratch = try store.makeScratch()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let file = scratch.appendingPathComponent("file")
            try await fetch(item.path, info: item, to: file) { _ in }
            try await withData(DataShare(size: item.size)) { link in
                try await self.send(file, size: item.size, to: temp, on: link, stamp: stamp) { _ in }
                try await self.place(temp, onto: placed, replacing: replacing, on: link)
            }
        }
    }

    /// Renames the finished `temp` onto `placed` on `link`, the channel that wrote it. `replacing`
    /// is what the user chose to replace, looked up again first: the bytes took a while, and
    /// anything else there now fails the file, so nothing the user was not asked about is
    /// replaced. Without it the rename refuses a name taken since it was looked up, which is said
    /// so rather than with the server's bare "Failure" (XFR-06).
    private func place(_ temp: RemotePath, onto placed: RemotePath, replacing asked: PlacedItem?, on link: SFTPChannel) async throws {
        let replacing = asked != nil
        if let asked, try await placedItem(try await link.lookup(placed), link: link) != asked {
            throw TransferError.failed("“\(placed.name)” changed on the server while it was being replaced; nothing was removed")
        }
        do {
            try await link.place(temp, onto: placed, replacing: replacing, log: asides)
        } catch where !replacing && !CopyTally.ends(error) {
            guard try await link.lookup(placed) != nil else { throw error }
            throw TransferError.failed("“\(placed.name)” appeared at the destination while it was being copied, and was not replaced")
        }
    }

    /// Runs `body` on a hidden temp beside `placed`, recorded so a later login removes it if this
    /// run cannot. `body` writes the temp and renames it into place.
    private func withRemoteTemp<T>(for placed: RemotePath, _ body: (RemotePath) async throws -> T) async throws -> T {
        let parent = placed.parent ?? RemotePath(string: "/")
        let temp = parent.appending(name: Array(KeepBothName.temp(for: placed.name).utf8))
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
            remember: { store.rememberTemp(Self.asideRecord($0, $1), connection: id, aside: true) },
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
        walk(root) { TreeEntry($0) }
    }

    /// `walkTree` with each entry as the listing gave it: parents before what they hold.
    nonisolated func walkItems(_ root: RemotePath) -> AsyncThrowingStream<(TreeKey, RemoteItem), Error> {
        walk(root) { $0 }
    }

    private nonisolated func walk<Entry: Sendable>(_ root: RemotePath, as entry: @escaping @Sendable (RemoteItem) -> Entry) -> AsyncThrowingStream<(TreeKey, Entry), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let link = try await self.walkerLink()
                    let item = try await link.lstat(root)
                    continuation.yield(("", entry(item)))
                    if item.kind == .directory {
                        try await self.walk(root, key: "", link: link) { _ = continuation.yield(($0, entry($1))) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The whole tree `walkTree` streams, by key.
    func tree(_ root: RemotePath) async throws -> [TreeKey: TreeEntry] {
        var entries: [TreeKey: TreeEntry] = [:]
        for try await (key, entry) in walkTree(root) { entries[key] = entry }
        return entries
    }

    /// Folders a walk lists at once on its one channel, and all walks on one connection together
    /// (`listings`). One at a time, each folder cost its own round trips: at 20 ms, a 2,000-file
    /// tree in ten folders took 761 ms to walk; eight at once, 225 ms.
    static let walkWidth = 8

    /// Visits what `folder` holds, and below. A folder is visited before what it holds, and
    /// listed once its parent's listing found it, up to `walkWidth` folders at once.
    private nonisolated func walk(_ folder: RemotePath, key: TreeKey, link: SFTPChannel, visit: @escaping @Sendable (TreeKey, RemoteItem) -> Void) async throws {
        try await withThrowingTaskGroup(of: [(RemotePath, TreeKey)].self) { group in
            var waiting = [(folder, key)]
            var listing = 0
            while !waiting.isEmpty || listing > 0 {
                while listing < Self.walkWidth, let (next, parent) = waiting.popLast() {
                    listing += 1
                    group.addTask { [listings] in
                        await listings.enter()
                        defer { listings.leave() }
                        var folders: [(RemotePath, TreeKey)] = []
                        for try await child in await link.list(next) {
                            try Task.checkCancellation()
                            // Special files are reported too: no copy writes them, so a move that
                            // compares the trees keeps a folder holding one instead of removing it unseen.
                            let key = parent.appending(child.path.nameBytes)
                            visit(key, child)
                            if child.kind == .directory { folders.append((child.path, key)) }
                        }
                        return folders
                    }
                }
                if let found = try await group.next() {
                    listing -= 1
                    waiting.append(contentsOf: found.reversed())
                }
            }
        }
    }

    // MARK: View and preview

    public func prepareViewFile(_ path: RemotePath) async throws -> URL {
        try await cachedCopy(stat(path), lane: .view)
    }

    /// The inspector previews a file that is not text only up to this size (10 MB). A download
    /// reads no more than the size listed, so the limit holds against what is read; a file listed
    /// without one could be read without end, and is refused (SEC2-03).
    static let inspectorLimit = InspectorPreviewPlan.limit

    public func prepareInspectorPreview(_ path: RemotePath) async throws -> URL {
        let item = try await stat(path)
        let head = UInt64(EditableFile.previewHead)
        guard EditableFile.openKind(fileName: item.name, extensions: editableExtensions) == .live, (item.size ?? .max) > head else {
            guard (item.size ?? .max) <= Self.inspectorLimit else { throw TransferError.failed("“\(item.name)” is too large to preview here") }
            return try await cachedCopy(item, lane: .preview)
        }
        // Only the head of a text file is shown, so only the head is fetched. The copy is named for
        // the file's size and time, so an unchanged file reuses it.
        let print = Fingerprint(item: item)
        let file = try previewURL(path, name: item.name, version: "head " + (print.map { "\($0.size):\($0.mtime)" } ?? ""))
        if print != nil, FileManager.default.fileExists(atPath: file.path) { return file }
        try await fetchHead(path, limit: head, to: file)
        trimPreviewCache()
        return file
    }

    /// The first `limit` bytes of `path`, on the preview lane.
    private func fetchHead(_ path: RemotePath, limit: UInt64, to file: URL) async throws {
        try await lane.submit(.preview) {
            try await self.fetch(path, info: RemoteItem(path: path, kind: .file, size: limit), to: file, readOnly: true, interactive: true) { _ in }
        }
    }

    /// The whole file in the preview cache, fetched on the lane as `kind`.
    private func cachedCopy(_ item: RemoteItem, lane kind: InteractiveLane.Kind) async throws -> URL {
        let path = item.path
        let file = try previewURL(path, name: item.name)
        // The copy carries the remote size and mtime; the same pair means the same bytes.
        if let print = Fingerprint(item: item), (try? LocalPlacement.occupant(file)) == .file(print) { return file }
        try await lane.submit(kind) {
            try await self.fetch(path, info: item, to: file, readOnly: true, interactive: true) { _ in }
        }
        trimPreviewCache()
        return file
    }

    public func preparePreview(_ path: RemotePath) async throws -> URL {
        let item = try await stat(path)
        // The listing the window checked may be old: the size read now decides too.
        if QuickLookPlan.plan(kind: item.kind, size: item.size) == .tooLarge {
            throw TransferError.failed(QuickLookPlan.tooLargeMessage(name: item.name))
        }
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
            // A head cut short may end inside a character: up to three of its bytes are dropped.
            let cut = (item.size ?? .max) > limit ? 3 : 0
            guard let text = (0...cut).lazy.compactMap({ String(validating: data.dropLast($0), as: UTF8.self) }).first else {
                return try await cachedCopy(item, lane: .preview)
            }
            let html = SyntaxPreview.html(text: text)
            try html.write(to: file, atomically: true, encoding: .utf8)
            trimPreviewCache()
            return file
        }
        return try await cachedCopy(item, lane: .preview)
    }

    /// The cache file for `path` on this server: the remote file's own name (plus `suffix`, cut to
    /// fit), in a folder named for the server, the path, and `version`, since two servers can hold
    /// different files at one path. The name is what Quick Look's Open With and an app viewing the
    /// copy show and open, where a digest meant nothing.
    private func previewURL(_ path: RemotePath, name: String, suffix: String = "", version: String = "") throws -> URL {
        var cache = store.previewCache
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? cache.setResourceValues(values)
        let key = Data(connection.id.rawValue.uuidString.utf8) + Data(path.bytes) + Data([0]) + Data(version.utf8)
        let digest = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        let folder = cache.appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fits = suffix.isEmpty && name.utf8.count <= 255
        return try LocalPlacement.child(folder, name: fits ? name : LiveDecision.siblingName(of: name, suffix: suffix))
    }

    /// Evicts whole entries, each a file's folder (or a digest-named file from before names were
    /// kept), by the last use of what it holds, in one walk of the cache.
    private func trimPreviewCache() {
        let root = store.previewCache.path
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: store.previewCache, includingPropertiesForKeys: Array(keys)) else { return }
        var entries: [String: (id: String, size: UInt64, lastUsed: Date)] = [:]
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            let used = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            let parent = url.deletingLastPathComponent().path
            let id = values.isDirectory == true || parent == root ? url.path : parent
            var entry = entries[id] ?? (id, 0, .distantPast)
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
    /// next. Only a job holding a channel has a file open. At 20 ms, 224 jobs moved 2,000
    /// small files fastest of 16, 112, and 224 in every direction (2,194 files/s down).
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
    /// connection, or a timeout, on which it stops or is retried. A file that changed on the
    /// server is that file's fault: the others go on, and a retry fetches only it (XFR-05).
    static func ends(_ error: any Error) -> Bool {
        if case .changedOnServer? = error as? TransferError { return false }
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
            state.bytes = state.bytes.saturatingAdd(bytes)
            state.items += items
            return TransferProgress(completed: state.bytes, itemsCompleted: state.items)
        }
        report(progress)
    }
}

/// What a destination folder on the server holds, by name, from one listing; empty for a folder
/// just made.
struct Holdings: Sendable {
    private var items: [[UInt8]: RemoteItem] = [:]
    private var folded: Set<String> = []

    mutating func add(_ item: RemoteItem) {
        items[item.path.nameBytes] = item
        folded.insert(item.name.diskFolded)
    }

    /// The item named `name`. A name the listing holds only in another case or Unicode form is
    /// looked up, since the server's disk may take the two for one.
    func item(named name: [UInt8], at path: RemotePath, on session: SSHConnection) async throws -> RemoteItem? {
        if let item = items[name] { return item }
        guard folded.contains(String(decoding: name, as: UTF8.self).diskFolded) else { return nil }
        return try await session.existing(path)
    }
}

/// At most `width` holders at once, the rest let in as holders leave, in the order they came.
/// A holder always leaves, so a waiter cancelled meanwhile gets in and finds itself cancelled.
final class ListingGate: Sendable {
    private let state: Locked<(free: Int, waiting: [CheckedContinuation<Void, Never>])>

    init(_ width: Int) {
        state = Locked((width, []))
    }

    func enter() async {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state in
                guard state.free > 0 else {
                    state.waiting.append(continuation)
                    return false
                }
                state.free -= 1
                return true
            }
            if now { continuation.resume() }
        }
    }

    func leave() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiting.isEmpty else {
                state.free += 1
                return nil
            }
            return state.waiting.removeFirst()
        }
        next?.resume()
    }
}
