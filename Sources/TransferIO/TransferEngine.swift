import Foundation
import TransferCore

/// Pastes and drops (`SessionProvider.transfer`): items copied or moved into a folder on a server,
/// from that server, another one, or this Mac.
///
/// A move is the only operation that deletes the user's data. It removes an original, or trashes a
/// file from this Mac, only when `MoveCheck` finds that this item wrote a complete copy of it: a
/// file or link counts only where this item's own copy wrote it (D6), so nothing else at the
/// destination, a lookalike the user skipped or another item's copy of the same name, ever passes
/// for it. A lookalike already there is asked about, never skipped. A move first proves the two
/// ends are different folders on disk: two servers, or two paths on one, may reach one disk; and
/// that a folder already at an item's name is not the item itself.
///
/// A retry passes the same request, whose memo keeps what earlier attempts did: finished items are
/// skipped, chosen names reused, and what each item wrote remembered.
struct TransferEngine {
    let request: TransferRequest
    let destination: SSHConnection
    let sum: ProgressSum
    /// Where a moved original from this Mac goes; a test sends it somewhere other than the user's Trash.
    var trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    /// What a copy between servers keeps in flight; a test sets less.
    var relayLimits = RelayLimits()

    init(request: TransferRequest, destination: SSHConnection, progress: @escaping @Sendable (TransferProgress) -> Void) {
        self.request = request
        self.destination = destination
        // Between servers, every byte passes twice: down to this Mac and up again.
        var total = request.bytes
        if case .server(let id, _) = request.sources, id != request.connection { total = total.map { $0.saturatingAdd($0) } }
        sum = ProgressSum(progress, total: total)
    }

    /// `source` is the server the items are on, when it is not the destination.
    func run(from source: SSHConnection?) async throws {
        if memo.withLock({ $0.liveMark }) == nil {
            let mark = await destination.live.saveMark()
            memo.withLock { $0.liveMark = mark }
        }
        switch request.sources {
        case .server(_, let paths):
            if let source { try await across(paths, from: source) } else { try await onServer(paths) }
        case .mac(let urls):
            try await fromMac(urls)
        }
    }

    // MARK: The three routes

    /// Copied on the server, or renamed when moving. A paste into the folder an item came from
    /// makes "name copy" beside it, as Finder does; anywhere else it keeps its name, byte for byte.
    private func onServer(_ paths: [RemotePath]) async throws {
        let folder = request.folder
        var names: Set<String>?
        try await each(paths, place: "on the server", name: \.name) { index, path in
            if request.moving { return try await move(index, path, among: paths) }
            let target: RemotePath
            if let chosen = memo.withLock({ $0.targets[index] }) {
                target = chosen
            } else if path.parent == folder {
                var taken = if let names { names } else { try await destination.listedNames(folder) }
                let isFolder = try await destination.stat(path).kind == .directory
                let name = KeepBothName.duplicate(existing: taken, original: path.name, isFolder: isFolder)
                taken.insert(name)
                names = taken
                target = folder.appending(name)
            } else {
                target = folder.appending(name: path.nameBytes)
            }
            memo.withLock { $0.targets[index] = target }
            try await destination.copy(path, to: target, tally: tally(index, sum.next()))
            finish(index)
            return nil
        }
    }

    /// A move on one server: one rename, which never replaces. Onto a name the folder already
    /// holds, it goes as a move between servers does, so the operation asks about the collision:
    /// copied on the server, and the original removed only once `MoveCheck` passes.
    private func move(_ index: Int, _ path: RemotePath, among paths: [RemotePath]) async throws -> TransferKept.Reason? {
        let target = request.folder.appending(name: path.nameBytes)
        do {
            if path.parent != request.folder { try await destination.rename(path, to: target) }
            finish(index)
            return nil
        } catch {
            if CopyTally.ends(error) { throw error }
            guard try await destination.existing(target) != nil else { throw error }
            // A retry after a rename whose reply was lost finds the item already moved.
            if try await destination.existing(path) == nil {
                finish(index)
                return nil
            }
        }
        // Two paths on one server may be one folder, through a link or a bind mount.
        let parents = Set(paths.compactMap(\.parent)).subtracting([request.folder])
        try await proveApart { try await destination.holds($0, inAny: parents) ? Self.ontoItself("the folder the items came from, reached another way") : nil }
        if let refused = try await sameItem(path, at: target, on: destination) { return refused }
        return try await place(index, at: target) {
            try await destination.copy(path, to: target, tally: tally(index, sum.next()))
        } original: { try await destination.tree(path) } remove: { try await destination.removeMoved(path, verified: $0, savedSince: liveMark) }
    }

    /// Down from the other server into a scratch folder on this Mac and up again, pipelined: one
    /// task walks the items in order and settles each name at the destination, asking there about
    /// any collision, and hands each file to a job that downloads it into a scratch file of its
    /// own, uploads that, and removes it once the upload's rename has landed. So while some files
    /// go up the next come down, across items too, within the limits `Relay` keeps. An item is
    /// checked, and in a move its original removed, once all of its own jobs are done.
    private func across(_ paths: [RemotePath], from source: SSHConnection) async throws {
        if request.moving {
            let parents = Set(paths.compactMap(\.parent))
            try await proveApart { try await source.holds($0, inAny: parents) ? Self.ontoItself("the folder the items came from, reached through another saved server") : nil }
        }
        let scratch = try destination.store.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let pending = paths.indices.filter { !isDone($0) }
        let nested = request.moving ? Self.nesting(paths, pending) : [:]
        let lookUp: @Sendable (Int) -> Task<Lookup, Error> = { [request, destination] index in
            let (path, target) = (paths[index], request.folder.appending(name: paths[index].nameBytes))
            return Task {
                async let tree = RelayTree.walk(path, on: source)
                async let found = destination.existing(target)
                return Lookup(tree: try await tree, found: try await found)
            }
        }
        // What each item is, looked up a few items ahead: one at a time, its two round trips
        // would hold every item up, as long as a small file takes to move.
        var ahead: [Int: Task<Lookup, Error>] = [:]
        defer { for lookup in ahead.values { lookup.cancel() } }
        let outcomes = try await withThrowingTaskGroup(of: Relay.Event.self) { group in
            var relay = Relay(scratch: scratch, limits: relayLimits)
            for (position, index) in pending.enumerated() {
                for next in pending[position..<min(position + Self.lookAhead, pending.count)] where ahead[next] == nil && nested[next] == nil {
                    ahead[next] = lookUp(next)
                }
                do {
                    let lookup: Task<Lookup, Error>
                    if let earlier = nested[index] {
                        // Inside an earlier item of this move, or holding one: that item goes
                        // first, whole, and this one is looked at as it left it.
                        try await relay.waitFor(earlier, &group)
                        lookup = lookUp(index)
                    } else {
                        lookup = ahead.removeValue(forKey: index)!
                    }
                    let looked = try await withTaskCancellationHandler { try await lookup.value } onCancel: { lookup.cancel() }
                    if let refused = try await relayItem(index, paths[index], looked, from: source, relay: &relay, group: &group) {
                        relay.outcomes[index] = .kept(refused)
                    }
                } catch {
                    if CopyTally.ends(error) { throw error }
                    relay.outcomes[index] = .failed(error)
                }
            }
            try await relay.drainAll(&group)
            return relay.outcomes
        }
        var undone = Undone()
        for (index, path) in paths.enumerated() {
            switch outcomes[index] {
            case .kept(let reason)?: undone.keep(path.name, reason)
            case .failed(let error)?: try undone.failed(path.name, error)
            case nil: break
            }
        }
        try undone.check(moving: request.moving, place: "on the other server")
    }

    /// Items looked up at once ahead of the one being placed.
    static let lookAhead = 16

    /// For each of the `pending` items that is, holds, or lies inside an earlier one, those earlier
    /// items: in a move, its copy waits for theirs to be checked and removed, as one item at a
    /// time did. Found by each item's folders, not by comparing every pair.
    static func nesting(_ paths: [RemotePath], _ pending: [Int]) -> [Int: [Int]] {
        var at: [RemotePath: [Int]] = [:]
        var below: [RemotePath: [Int]] = [:]
        for index in pending {
            let path = paths[index].normalized
            at[path, default: []].append(index)
            var folder = path.parent
            while let above = folder {
                below[above, default: []].append(index)
                folder = above.parent
            }
        }
        var nested: [Int: [Int]] = [:]
        for index in pending {
            let path = paths[index].normalized
            var related = (at[path] ?? []) + (below[path] ?? [])
            var folder = path.parent
            while let above = folder {
                related += at[above] ?? []
                folder = above.parent
            }
            let earlier = related.filter { $0 < index }
            if !earlier.isEmpty { nested[index] = earlier }
        }
        return nested
    }

    /// An item ahead: its tree on the other server, walked whole, and what holds its name at the
    /// destination then.
    private struct Lookup: Sendable {
        var tree: RelayTree
        var found: RemoteItem?
    }

    /// Source `index`, at `path` on `source`, as `lookup` found it: its entries settled at the
    /// destination and its files handed to `relay`. Returns why a move refused it, or nil once it
    /// is on its way, its outcome to come from `relay`.
    private func relayItem(
        _ index: Int,
        _ path: RemotePath,
        _ lookup: Lookup,
        from source: SSHConnection,
        relay: inout Relay,
        group: inout ThrowingTaskGroup<Relay.Event, Error>
    ) async throws -> TransferKept.Reason? {
        let tree = lookup.tree
        let target = request.folder.appending(name: path.nameBytes)
        if request.moving, let refused = try await sameItem(path, at: target, on: source) { return refused }
        // An earlier item still writing this name goes first, so this one meets its copy as it
        // would one at a time: as something already there.
        try await relay.waitForName(target.name, &group)
        let reserved = relay.names
        // Looked up ahead, before an earlier item of this paste may have written the name.
        let again = relay.wrote(target.name)
        relay.begin(index, name: target.name)
        let tally = tally(index, sum.next())
        do {
            let found = again ? try await destination.existing(target) : lookup.found
            try await relayEntry(tree.root, key: "", in: tree, at: target, found: found, reserved: reserved, from: source, item: index, tally: tally, relay: &relay, group: &group)
        } catch {
            relay.abandon(index)
            throw error
        }
        try await relay.walked(index, landed: tally.landed(target)?.name, &group) { [self] in
            do {
                destination.pipe.emit(.directoryChanged(request.folder))
                try tally.check()
                return .kept(try await settled(index, at: target) { try await source.tree(path) } remove: { try await source.removeMoved(path, verified: $0, savedSince: liveMark) })
            } catch {
                if CopyTally.ends(error) { throw error }
                return .failed(error)
            }
        }
        return nil
    }

    /// `item`, at `key` in its source's `tree`, placed at `target` on the destination, where
    /// `found` is: a folder made or merged into and what it holds placed in turn, a link copied as
    /// a link, a file settled and handed to `relay`. As in a copy onto the server, a failure below
    /// the item is recorded in `tally` and the rest goes on. `reserved` are names other items are
    /// still writing beside the item, which Keep Both passes over.
    private func relayEntry(
        _ item: RemoteItem,
        key: TreeKey,
        in tree: RelayTree,
        at target: RemotePath,
        found: RemoteItem?,
        reserved: Set<String> = [],
        from source: SSHConnection,
        item index: Int,
        tally: CopyTally,
        relay: inout Relay,
        group: inout ThrowingTaskGroup<Relay.Event, Error>
    ) async throws {
        switch item.kind {
        case .other:
            // A socket, FIFO, or device has no bytes to copy: skipped, as a download skips one.
            return
        case .symlink:
            try await destination.remoteLink(try await source.readlink(item.path), at: target, found: found, tally: tally, reserved: reserved)
            tally.finished()
        case .directory:
            guard let folder = try await destination.remoteFolder(target, found: found, tally: tally, reserved: reserved) else { return }
            let held = folder.made ? Holdings() : try await destination.holdings(folder.path)
            for child in tree.children[key] ?? [] {
                try Task.checkCancellation()
                let name = child.path.nameBytes
                let to = folder.path.appending(name: name)
                do {
                    let there = try await held.item(named: name, at: to, on: destination)
                    try await relayEntry(child, key: key.appending(name), in: tree, at: to, found: there, from: source, item: index, tally: tally, relay: &relay, group: &group)
                } catch {
                    try tally.failed(to.name, error)
                }
            }
        case .file:
            let placed: (path: RemotePath, found: PlacedItem?)
            if found == nil, tally.landed(target) == nil {
                // A free name, which `Placement.settle` writes: no hop onto the destination's
                // actor, which its uploads keep busy, to be told so.
                placed = (target, nil)
            } else {
                guard let settled = try await destination.settleRemotely(.file(Fingerprint(item: item)), at: target, found: found, tally: tally, reserved: reserved) else {
                    return tally.finished()
                }
                placed = settled
            }
            // What the user chose to replace, looked up again just before the rename.
            let replacing = placed.found
            try await relay.send(index, size: item.size, &group) { [destination] local in
                do {
                    // Removed once its upload's rename has landed, or as soon as either half fails.
                    defer { try? FileManager.default.removeItem(at: local) }
                    // In `Scratch/`, which each launch empties: its temp needs no record.
                    try await source.fetch(item.path, info: item, to: local, recorded: false, progress: tally.file())
                    try await destination.uploadBytes(local, to: placed.path, replacing: replacing, progress: tally.file())
                    tally.finished()
                    tally.record(placed.path)
                } catch {
                    try tally.failed(target.name, error)
                }
            }
        }
    }

    /// Uploads; a move then puts each original in the Trash.
    private func fromMac(_ urls: [URL]) async throws {
        let parents = Set(urls.map { $0.deletingLastPathComponent() })
        // A server may reach this Mac's disk, where a folder pasted into itself would walk into its
        // own output (XFR-02): the probe is looked for under each folder along the destination's
        // path, from its last component back.
        let folders = urls.filter { (try? LocalPlacement.occupant($0)) == .folder }
        let tail = request.folder.normalized.display.split(separator: "/").map(String.init)
        if request.moving || !folders.isEmpty {
            try await proveApart { name in
                if request.moving, try parents.contains(where: { try LocalPlacement.occupant($0.appendingPathComponent(name)) != nil }) {
                    return Self.ontoItself("the folder on this Mac the items are in")
                }
                let inside = folders.first { folder in
                    (0...tail.count).contains { (try? LocalPlacement.occupant(tail.suffix($0).reduce(folder) { $0.appendingPathComponent($1) }.appendingPathComponent(name))) != nil }
                }
                return inside.map { "“\($0.lastPathComponent)” cannot be pasted into itself." }
            }
        }
        try await each(urls, place: "on this Mac", name: \.lastPathComponent) { index, url in
            let target = request.folder.appending(name: Array(url.lastPathComponent.utf8))
            return try await place(index, at: target) {
                try await destination.upload(url, to: target, tally: tally(index, sum.next()))
            } original: { try LocalTree.entries(url) } remove: { _ in
                // The Trash keeps anything added since the walk too, where the user can find it.
                try trash(url)
                return true
            }
        }
    }

    /// Runs `body` on each source not done yet, which returns why it was kept, and then throws
    /// what was left undone.
    private func each<Source>(_ sources: [Source], place: String, name: (Source) -> String, _ body: (Int, Source) async throws -> TransferKept.Reason?) async throws {
        var undone = Undone()
        for (index, source) in sources.enumerated() where !isDone(index) {
            do {
                undone.keep(name(source), try await body(index, source))
            } catch {
                try undone.failed(name(source), error)
            }
        }
        try undone.check(moving: request.moving, place: place)
    }

    // MARK: The move's checks

    /// Copies source `index` to `target`. A move then walks the `original` and, only when
    /// `MoveCheck` passes, has `remove` take what the walk found, which says whether all of it went;
    /// a Live file under it with unsynced edits keeps it too. Returns why the original was kept,
    /// or nil once the item is done.
    private func place(
        _ index: Int,
        at target: RemotePath,
        copy: () async throws -> Void,
        original: () async throws -> [TreeKey: TreeEntry],
        remove: ([TreeKey: TreeEntry]) async throws -> Bool
    ) async throws -> TransferKept.Reason? {
        try await copy()
        return try await settled(index, at: target, original: original, remove: remove)
    }

    /// After source `index`'s copy to `target`: a move walks the `original` and, only when
    /// `MoveCheck` passes, has `remove` take what the walk found. Returns why the original was
    /// kept, or nil once the item is done.
    private func settled(
        _ index: Int,
        at target: RemotePath,
        original: () async throws -> [TreeKey: TreeEntry],
        remove: ([TreeKey: TreeEntry]) async throws -> Bool
    ) async throws -> TransferKept.Reason? {
        if request.moving {
            let tree = try await original()
            if let reason = try await keptReason(index, target: target, source: tree) { return reason }
            do {
                if try await !remove(tree) { return .changed }
            } catch TransferError.liveUnsynced(let count) {
                return .live(count)
            }
        }
        finish(index)
        return nil
    }

    private var memo: Locked<TransferMemo> { request.memo }

    /// The Live save count read before anything was copied (`removeMoved`).
    private var liveMark: UInt64 { memo.withLock { $0.liveMark } ?? 0 }

    private func isDone(_ index: Int) -> Bool { memo.withLock { $0.done.contains(index) } }

    private func finish(_ index: Int) { memo.withLock { _ = $0.done.insert(index) } }

    /// The tally for source `index`'s copy: it counts only what that copy wrote as its own.
    private func tally(_ index: Int, _ progress: @escaping @Sendable (TransferProgress) -> Void) -> CopyTally {
        CopyTally(progress, memo: memo, item: index, moving: request.moving)
    }

    /// Once per request: has `probe` look at the sources for a folder made at the destination.
    /// Found there, the two ends are one place on disk (two saved servers for one host, two hosts
    /// on one disk, a link), and `refusal` says why nothing goes.
    private func proveApart(_ refusal: @Sendable (String) async throws -> String?) async throws {
        guard !memo.withLock({ $0.checked }) else { return }
        if let refused = try await probe(in: request.folder, refusal) { throw TransferError.failed(refused) }
        memo.withLock { $0.checked = true }
    }

    /// A folder already at `target` may be the item at `path` itself, reached another way (a bind
    /// mount, one share at two paths), which no check of their parents sees. Replace would copy
    /// each file onto itself and the removal take the only copy. A probe made in that folder and
    /// found under the item refuses it.
    private func sameItem(_ path: RemotePath, at target: RemotePath, on source: SSHConnection) async throws -> TransferKept.Reason? {
        guard try await destination.existing(target)?.kind == .directory else { return nil }
        return try await probe(in: target) { name in
            try await source.existing(path.appending(name)) != nil ? .failed("the folder of that name at the destination is this item itself, reached another way") : nil
        }
    }

    /// Makes a uniquely named folder in `folder` at the destination, returns what `found` makes of
    /// its name, and removes it. Only "no such file" proves two places.
    private func probe<Found>(in folder: RemotePath, _ found: (String) async throws -> Found?) async throws -> Found? {
        let name = ".transfer-move-check-\(UUID().uuidString)"
        let probe = folder.appending(name)
        // Recorded like a temp, so a dropped connection leaves no folder behind for good.
        destination.store.rememberTemp(probe, connection: destination.connection.id)
        let result: Found?
        do {
            try await destination.mkdir(probe)
            result = try await found(name)
        } catch {
            await destination.discardRemoteTemp(probe)
            throw error
        }
        await destination.discardRemoteTemp(probe)
        destination.pipe.emit(.directoryChanged(folder))
        return result
    }

    private static func ontoItself(_ place: String) -> String {
        "Nothing was moved: this folder is \(place), so each item would be copied onto itself."
    }

    /// Why the original of source `index` must stay, or nil when it may go. `source` is its tree
    /// now. Each entry is looked for where the copy put it, following Keep Both, and counts only
    /// if this item wrote it there.
    private func keptReason(_ index: Int, target: RemotePath, source: [TreeKey: TreeEntry]) async throws -> TransferKept.Reason? {
        let (written, landed) = memo.withLock { ($0.written[index] ?? [], $0.landed[index] ?? [:]) }
        // A retry that met a new occupant where Keep Both sent an entry chose another name again.
        func followed(_ offered: RemotePath) -> RemotePath {
            var path = offered
            for _ in landed { if let next = landed[path] { path = next } }
            return path
        }
        let root = followed(target)
        let now: [TreeKey: TreeEntry]
        do {
            now = try await destination.tree(root)
        } catch TransferError.noSuchFile {
            now = [:]
        }
        var after: [TreeKey: TreeEntry] = [:]
        var ours: Set<TreeKey> = []
        for key in source.keys {
            var path = root
            var placed = TreeKey(bytes: [])
            for name in key.components {
                path = followed(path.appending(name: name))
                placed = placed.appending(path.nameBytes)
            }
            after[key] = now[placed]
            if written.contains(path) { ours.insert(key) }
        }
        return TransferKept.Reason(MoveCheck.verdict(source: source, after: after, written: ours))
    }
}


/// What a paste left undone, item by item: originals kept and why, and items that failed. Every
/// item has its turn; only a cancel, a dropped connection, or a timeout ends the paste at once, so
/// it can stop or retry.
private struct Undone {
    private var items: [TransferKept.Item] = []
    private var errors: [any Error] = []

    mutating func keep(_ name: String, _ reason: TransferKept.Reason?) {
        if let reason { items.append(TransferKept.Item(name, reason)) }
    }

    mutating func failed(_ name: String, _ error: any Error) throws {
        if CopyTally.ends(error) { throw error }
        items.append(TransferKept.Item(name, .failed(error.localizedDescription)))
        errors.append(error)
    }

    /// Throws what was left undone: one failure alone as it came, else all of it together.
    func check(moving: Bool, place: String) throws {
        guard !items.isEmpty else { return }
        if items.count == 1, let only = errors.first { throw only }
        throw TransferKept(items, moving: moving, place: place)
    }
}

/// A file or folder on this Mac walked as `RemoteSession.walkTree` walks one on a server, read
/// with `lstat` through FileManager's attributes: `URL.resourceValues` caches per URL instance
/// and can return the size and time of an earlier walk.
enum LocalTree {
    static func entries(_ root: URL) throws -> [TreeKey: TreeEntry] {
        let manager = FileManager.default
        guard try LocalPlacement.occupant(root) != nil else { return [:] }
        var all: [TreeKey: TreeEntry] = ["": TreeEntry(try manager.attributesOfItem(atPath: root.path))]
        guard all[""] == .directory, let enumerator = manager.enumerator(atPath: root.path) else { return all }
        while let key = enumerator.nextObject() as? String {
            if let attributes = enumerator.fileAttributes { all[TreeKey(bytes: Array(key.utf8))] = TreeEntry(attributes) }
        }
        return all
    }
}

/// Joins the progress of several copies into one row on the shelf. Between servers the items'
/// copies overlap, so each reports into a slot of its own and the row shows their sum.
final class ProgressSum: Sendable {
    private let report: @Sendable (TransferProgress) -> Void
    private let total: UInt64?
    /// The sum of every copy's latest report, and each copy's latest.
    private let state = Locked((sum: TransferProgress(completed: 0), parts: [TransferProgress]()))

    init(_ report: @escaping @Sendable (TransferProgress) -> Void, total: UInt64?) {
        self.report = report
        self.total = total.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The reporter for the next copy. What the others report is kept.
    func next() -> @Sendable (TransferProgress) -> Void {
        let slot = state.withLock { state in
            state.parts.append(TransferProgress(completed: 0))
            return state.parts.count - 1
        }
        return { [self] progress in
            // Reported under the lock, so the row hears the sum in the order it grew: a copy's
            // counts only grow, and a report overtaken by an older one would read as a file
            // started over.
            state.withLock { state in
                let last = state.parts[slot]
                let completed = max(last.completed, progress.completed)
                let items = max(last.itemsCompleted, progress.itemsCompleted)
                state.sum.completed = state.sum.completed.saturatingAdd(completed - last.completed)
                state.sum.itemsCompleted += items - last.itemsCompleted
                state.parts[slot] = TransferProgress(completed: completed, itemsCompleted: items)
                report(TransferProgress(completed: state.sum.completed, total: total, itemsCompleted: state.sum.itemsCompleted))
            }
        }
    }
}

/// What a copy between servers keeps in flight (`Relay`).
struct RelayLimits: Sendable {
    /// The scratch space its files may take, by their listed sizes: over a second of either half
    /// at 100 MB/s, and far from a full disk however large the tree. A file larger than this
    /// goes alone.
    var bytes: UInt64 = 256 << 20
    /// Jobs in its task group: each a file going down and up, or an item's check. As many as a
    /// copy onto the server keeps, so each half can fill its data channels.
    var jobs = CopyTally.jobLimit
}

/// A copy between servers in flight: its jobs, and the scratch space their files take, within
/// its `RelayLimits`. Kept by the one task that walks the items, which reads each job's end from
/// the group.
private struct Relay {
    enum Event: Sendable {
        /// A file's job ended, giving back its share of the scratch space.
        case file(item: Int, bytes: UInt64)
        case checked(item: Int, Outcome)
    }

    enum Outcome: Sendable {
        /// Done (nil), or its original kept, and why.
        case kept(TransferKept.Reason?)
        case failed(any Error)
    }

    /// An item walking or walked whose check has not ended.
    private struct Item {
        /// The name it writes in the destination folder, and the one Keep Both gave it.
        var names: Set<String>
        var jobs = 0
        var check: (@Sendable () async throws -> Outcome)?
        var abandoned = false
    }

    let scratch: URL
    let limits: RelayLimits
    var outcomes: [Int: Outcome] = [:]
    private var items: [Int: Item] = [:]
    /// Every name, folded, that an item of this paste began writing.
    private var written: Set<String> = []
    private var jobs = 0
    private var bytes: UInt64 = 0
    private var files = 0

    init(scratch: URL, limits: RelayLimits) {
        self.scratch = scratch
        self.limits = limits
    }

    /// The names items in flight write in the destination folder.
    var names: Set<String> { items.values.reduce(into: []) { $0.formUnion($1.names) } }

    /// Waits until no item in flight writes `name`, as a disk that ignores case may fold it.
    mutating func waitForName(_ name: String, _ group: inout ThrowingTaskGroup<Event, Error>) async throws {
        let folded = name.diskFolded
        while items.values.contains(where: { $0.names.contains { $0.diskFolded == folded } }) {
            try await take(&group)
        }
    }

    /// Waits until each of `earlier` has ended, its check too.
    mutating func waitFor(_ earlier: [Int], _ group: inout ThrowingTaskGroup<Event, Error>) async throws {
        while earlier.contains(where: { items[$0] != nil }) {
            try await take(&group)
        }
    }

    mutating func begin(_ item: Int, name: String) {
        items[item] = Item(names: [name])
        written.insert(name.diskFolded)
    }

    /// Whether an item of this paste began writing `name`, as a disk that ignores case may fold it.
    func wrote(_ name: String) -> Bool { written.contains(name.diskFolded) }

    /// Adds a job for a file of `item`, of `size` bytes, with a scratch file of its own, once the
    /// limits leave room for it.
    mutating func send(_ item: Int, size: UInt64?, _ group: inout ThrowingTaskGroup<Event, Error>, _ job: @escaping @Sendable (URL) async throws -> Void) async throws {
        let room = RelayRoom(jobs: limits.jobs, bytes: limits.bytes)
        let share = room.share(size: size)
        while !room.admits(share, running: jobs, held: bytes) {
            try await take(&group)
        }
        let local = scratch.appendingPathComponent(String(files))
        files += 1
        jobs += 1
        bytes += share
        items[item]?.jobs += 1
        group.addTask {
            try await job(local)
            return .file(item: item, bytes: share)
        }
    }

    /// `item`'s walk is done: `check` runs once its last job has. One that would start now waits
    /// for room among the jobs first; one started as a job ends takes that job's place.
    mutating func walked(_ item: Int, landed: String?, _ group: inout ThrowingTaskGroup<Event, Error>, check: @escaping @Sendable () async throws -> Outcome) async throws {
        if let landed {
            items[item]?.names.insert(landed)
            written.insert(landed.diskFolded)
        }
        if items[item]?.jobs == 0 {
            while jobs >= limits.jobs { try await take(&group) }
        }
        items[item]?.check = check
        startCheck(item, &group)
    }

    /// `item`'s walk failed: its jobs run out, and nothing checks it.
    mutating func abandon(_ item: Int) {
        items[item]?.abandoned = true
        if items[item]?.jobs == 0 { items[item] = nil }
    }

    /// Waits for every job and every check to end.
    mutating func drainAll(_ group: inout ThrowingTaskGroup<Event, Error>) async throws {
        while jobs > 0 { try await take(&group) }
    }

    /// Takes the next job to end back from the group. One that ends the paste throws here, and
    /// leaving the group cancels the rest.
    private mutating func take(_ group: inout ThrowingTaskGroup<Event, Error>) async throws {
        guard let event = try await group.next() else {
            // Nothing is left to wait for, which only a slip in these counts could bring: an item
            // still waiting fails rather than passing as done, and no wait loops for ever.
            for item in items.keys where outcomes[item] == nil {
                outcomes[item] = .failed(TransferError.failed("The copy lost track of this item"))
            }
            items = [:]
            jobs = 0
            bytes = 0
            return
        }
        jobs -= 1
        switch event {
        case .file(let item, let share):
            bytes -= share
            items[item]?.jobs -= 1
            if items[item]?.abandoned == true, items[item]?.jobs == 0 { items[item] = nil }
            startCheck(item, &group)
        case .checked(let item, let outcome):
            items[item] = nil
            outcomes[item] = outcome
        }
    }

    private mutating func startCheck(_ item: Int, _ group: inout ThrowingTaskGroup<Event, Error>) {
        guard let state = items[item], !state.abandoned, state.jobs == 0, let check = state.check else { return }
        items[item]?.check = nil
        jobs += 1
        group.addTask { .checked(item: item, try await check()) }
    }
}

/// An item's tree on the other server, walked whole before any of it is copied. The copy takes
/// only what this walk found, so a destination the source reaches too (two saved servers for one
/// disk) never feeds the copy its own output. No name of it reaches this Mac's disk: each file
/// passes through a numbered scratch file, so names the Mac's disk could not hold apart, or that
/// are not UTF-8, go as the server holds them.
private struct RelayTree: Sendable {
    let root: RemoteItem
    /// What each folder holds, by the folder's key, in the listing's order.
    var children: [TreeKey: [RemoteItem]]

    static func walk(_ path: RemotePath, on source: SSHConnection) async throws -> RelayTree {
        var root: RemoteItem?
        var children: [TreeKey: [RemoteItem]] = [:]
        for try await (key, item) in source.walkItems(path) {
            if key.bytes.isEmpty {
                root = item
            } else {
                let parent = key.bytes.lastIndex(of: 0x2F).map { TreeKey(bytes: Array(key.bytes[..<$0])) } ?? ""
                children[parent, default: []].append(item)
            }
        }
        guard let root else { throw TransferError.noSuchFile(path.display) }
        return RelayTree(root: root, children: children)
    }
}
