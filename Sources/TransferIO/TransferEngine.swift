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
            guard try await destination.existing(target) != nil else { throw error }
        }
        // Two paths on one server may be one folder, through a link or a bind mount.
        let parents = Set(paths.compactMap(\.parent)).subtracting([request.folder])
        try await proveApart { try await destination.holds($0, inAny: parents) ? Self.ontoItself("the folder the items came from, reached another way") : nil }
        if let refused = try await sameItem(path, at: target, on: destination) { return refused }
        return try await place(index, at: target) {
            try await destination.copy(path, to: target, tally: tally(index, sum.next()))
        } original: { try await destination.tree(path) } remove: { try await destination.removeMoved(path, verified: $0, savedSince: liveMark) }
    }

    /// Down from the other server into a scratch folder on this Mac, then up, one item at a time.
    private func across(_ paths: [RemotePath], from source: SSHConnection) async throws {
        if request.moving {
            let parents = Set(paths.compactMap(\.parent))
            try await proveApart { try await source.holds($0, inAny: parents) ? Self.ontoItself("the folder the items came from, reached through another saved server") : nil }
        }
        // Recorded like a temp, so the next launch removes what a crash left (XFR-07).
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Transfer-\(UUID().uuidString)", isDirectory: true)
        destination.store.rememberTemp(local: scratch)
        defer { destination.removeScratch(scratch) }
        let ignoresCase = (try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames != true
        try await each(paths, place: "on the other server", name: \.name) { index, path in
            // The Mac's disk may not hold two names the server keeps apart. Refused before
            // anything is copied, since one of the two would stand in for the other.
            var clash = NameClash(ignoringCase: ignoresCase)
            for try await (key, _) in source.walkTree(path) {
                // APFS holds only UTF-8 names: this one would land renamed.
                guard String(validating: key.bytes, as: UTF8.self) != nil else {
                    return .failed("“\(key)” has a name that is not UTF-8, which this Mac's disk cannot hold")
                }
                clash.add(key)
            }
            if let (first, second) = clash.found { return .clash(first.description, second.description) }
            let target = request.folder.appending(name: path.nameBytes)
            if request.moving, let refused = try await sameItem(path, at: target, on: source) { return refused }
            let local = scratch.appendingPathComponent(String(index))
            defer { try? FileManager.default.removeItem(at: local) }
            return try await place(index, at: target) {
                try await source.download(path, to: local, progress: sum.next())
                try await destination.upload(local, to: target, tally: tally(index, sum.next()))
            } original: { try await source.tree(path) } remove: { try await source.removeMoved(path, verified: $0, savedSince: liveMark) }
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

/// Joins the progress of several copies, one after another, into one row on the shelf.
final class ProgressSum: Sendable {
    private let report: @Sendable (TransferProgress) -> Void
    private let total: UInt64?
    /// What the finished copies reported, and the running one.
    private let state = Locked((base: TransferProgress(completed: 0), current: TransferProgress(completed: 0)))

    init(_ report: @escaping @Sendable (TransferProgress) -> Void, total: UInt64?) {
        self.report = report
        self.total = total.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The reporter for the next copy. What the previous one reported is kept.
    func next() -> @Sendable (TransferProgress) -> Void {
        state.withLock { state in
            state.base.completed = state.base.completed.saturatingAdd(state.current.completed)
            state.base.itemsCompleted += state.current.itemsCompleted
            state.current = TransferProgress(completed: 0)
        }
        return { [self] progress in
            let combined = state.withLock { state in
                state.current = progress
                return TransferProgress(
                    completed: state.base.completed.saturatingAdd(progress.completed),
                    total: total,
                    itemsCompleted: state.base.itemsCompleted + progress.itemsCompleted
                )
            }
            report(combined)
        }
    }
}
