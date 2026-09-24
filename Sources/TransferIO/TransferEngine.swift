import Foundation
import TransferCore

/// Pastes and drops (`SessionProvider.transfer`): items copied or moved into a folder on a server,
/// from that server, another one, or this Mac.
///
/// A move is the one operation in Transfer that deletes the user's data. It removes an original,
/// or puts a file from this Mac in the Trash, only when `MoveCheck` finds that this move wrote a
/// complete copy of it. The destination is walked before the move first reaches it, and nothing it
/// held then counts as the copy unless the user chose Replace; a lookalike file already there is
/// asked about, never skipped. Before anything is copied, a move proves that the two ends are
/// different folders on the storage itself, since two saved servers may reach one disk.
///
/// A retry passes the same request, whose memo keeps what earlier attempts did: finished items
/// are not done again, a chosen name is reused, and the first attempt's own copy is never taken
/// for something that was already there.
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
        var passes: UInt64 = 1
        if case .server(let id, _) = request.sources, id != request.connection { passes = 2 }
        sum = ProgressSum(progress, total: request.bytes.map { $0 * passes })
    }

    /// `source` is the server the items are on, when it is not the destination.
    func run(from source: SSHConnection?) async throws {
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
        let failures = CopyTally { _ in }
        var names: Set<String>?
        for (index, path) in paths.enumerated() where !isDone(index) {
            if request.moving {
                do {
                    if path.parent != folder { try await destination.rename(path, to: folder.appending(name: path.nameBytes)) }
                } catch {
                    try failures.failed(path.name, error)
                    continue
                }
            } else {
                let target: RemotePath
                if let chosen = memo.withLock({ $0.targets[index] }) {
                    target = chosen
                } else if path.parent == folder {
                    var taken = if let names { names } else { try await destination.listedNames(folder) }
                    let name = KeepBothName.duplicate(existing: taken, original: path.name)
                    taken.insert(name)
                    names = taken
                    target = folder.appending(name)
                } else {
                    target = folder.appending(name: path.nameBytes)
                }
                memo.withLock { $0.targets[index] = target }
                try await destination.copy(path, to: target, tally: tally(sum.next()))
            }
            finish(index)
        }
        try failures.check()
    }

    /// Down from the other server into a scratch folder on this Mac, then up, one item at a time.
    private func across(_ paths: [RemotePath], from source: SSHConnection) async throws {
        let parents = Set(paths.compactMap(\.parent))
        try await proveApart(from: "the folder the items came from, reached through another saved server") { name in
            for parent in parents {
                if try await source.existing(parent.appending(name)) != nil { return true }
            }
            return false
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Transfer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let ignoresCase = (try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames != true
        var kept: [TransferKept.Item] = []
        for (index, path) in paths.enumerated() where !isDone(index) {
            // The Mac's disk may not hold two names the server keeps apart. Refused before
            // anything is copied, since one of the two would stand in for the other.
            var clash = NameClash(ignoringCase: ignoresCase)
            for try await (key, _) in source.walkTree(path) { clash.add(key) }
            if let (first, second) = clash.found {
                kept.append(TransferKept.Item(path.name, .clash(first.description, second.description)))
                continue
            }
            let local = scratch.appendingPathComponent(String(index))
            defer { try? FileManager.default.removeItem(at: local) }
            let target = request.folder.appending(name: path.nameBytes)
            let reason = try await place(index, at: target) {
                try await source.download(path, to: local, progress: sum.next())
                try await destination.upload(local, to: target, tally: tally(sum.next()))
            } original: {
                try await source.tree(path)
            } remove: {
                try await source.remove(path)
            }
            if let reason { kept.append(TransferKept.Item(path.name, reason)) }
        }
        if !kept.isEmpty { throw TransferKept(kept, moving: request.moving, place: "on the other server") }
    }

    /// Uploads; a move then puts each original in the Trash.
    private func fromMac(_ urls: [URL]) async throws {
        let parents = Set(urls.map { $0.deletingLastPathComponent() })
        try await proveApart(from: "the folder on this Mac the items are in") { name in
            try parents.contains { try LocalPlacement.occupant($0.appendingPathComponent(name)) != nil }
        }
        var kept: [TransferKept.Item] = []
        for (index, url) in urls.enumerated() where !isDone(index) {
            let target = request.folder.appending(name: Array(url.lastPathComponent.utf8))
            let reason = try await place(index, at: target) {
                try await destination.upload(url, to: target, tally: tally(sum.next()))
            } original: {
                try LocalTree.entries(url)
            } remove: {
                try trash(url)
            }
            if let reason { kept.append(TransferKept.Item(url.lastPathComponent, reason)) }
        }
        if !kept.isEmpty { throw TransferKept(kept, moving: true, place: "on this Mac") }
    }

    // MARK: The move's checks

    /// Copies source `index` to `target`. A move then walks the `original` and removes it only
    /// when `MoveCheck` passes; a Live file under it with unsynced edits keeps it too. Returns
    /// why the original was kept, or nil once the item is done.
    private func place(
        _ index: Int,
        at target: RemotePath,
        copy: () async throws -> Void,
        original: () async throws -> [TreeKey: TreeEntry],
        remove: () async throws -> Void
    ) async throws -> TransferKept.Reason? {
        try await snapshot(index, target)
        try await copy()
        if request.moving {
            if let reason = try await keptReason(index, target: target, source: try await original()) { return reason }
            do {
                try await remove()
            } catch TransferError.liveUnsynced(let count) {
                return .live(count)
            }
        }
        finish(index)
        return nil
    }

    private var memo: Locked<TransferMemo> { request.memo }

    private func isDone(_ index: Int) -> Bool { memo.withLock { $0.done.contains(index) } }

    private func finish(_ index: Int) { memo.withLock { _ = $0.done.insert(index) } }

    private func tally(_ progress: @escaping @Sendable (TransferProgress) -> Void) -> CopyTally {
        CopyTally(progress, memo: memo, moving: request.moving)
    }

    /// Once per move: whether the destination folder is, on the storage itself, the folder the
    /// originals are in (two saved servers for one host, or two hosts sharing a disk). A folder
    /// named as nothing else is made in the destination, and `seen` looks for that name beside
    /// the originals. Only "no such file" there proves two places.
    private func proveApart(from place: String, seen: @Sendable (String) async throws -> Bool) async throws {
        guard request.moving, !memo.withLock({ $0.checked }) else { return }
        let name = ".transfer-move-check-\(UUID().uuidString)"
        let probe = request.folder.appending(name)
        try await destination.mkdir(probe)
        let found: Bool
        do {
            found = try await seen(name)
        } catch {
            try? await destination.remove(probe)
            throw error
        }
        try? await destination.remove(probe)
        if found { throw TransferError.failed("Nothing was moved: this folder is \(place), so each item would be copied onto itself.") }
        memo.withLock { $0.checked = true }
    }

    /// What `target` held before the move first reached it. Only the root's own absence means
    /// nothing was there: a walk that loses a folder halfway throws "no such file" too, which is
    /// no evidence the destination was empty, so it is thrown on.
    private func snapshot(_ index: Int, _ target: RemotePath) async throws {
        guard request.moving, memo.withLock({ $0.before[index] }) == nil else { return }
        let taken = try await destination.existing(target) == nil ? [:] : try await destination.tree(target)
        memo.withLock { $0.before[index] = taken }
    }

    /// Why the original of source `index` must stay, or nil when it may go. `source` is its tree
    /// now. Each entry is looked for where the copy put it, following Keep Both; what the
    /// destination held before counts only at the very place it was.
    private func keptReason(_ index: Int, target: RemotePath, source: [TreeKey: TreeEntry]) async throws -> TransferKept.Reason? {
        let (before, written, landed) = memo.withLock { ($0.before[index] ?? [:], $0.written, $0.landed) }
        let root = landed[target] ?? target
        let now: [TreeKey: TreeEntry]
        do {
            now = try await destination.tree(root)
        } catch TransferError.noSuchFile {
            now = [:]
        }
        var there: [TreeKey: TreeEntry] = [:]
        var after: [TreeKey: TreeEntry] = [:]
        var ours: Set<TreeKey> = []
        for key in source.keys {
            var path = root
            var placed = TreeKey(bytes: [])
            for name in key.components {
                let offered = path.appending(name: name)
                path = landed[offered] ?? offered
                placed = placed.appending(path.nameBytes)
            }
            if root == target, placed == key { there[key] = before[key] }
            after[key] = now[placed]
            if written.contains(path) { ours.insert(key) }
        }
        return TransferKept.Reason(MoveCheck.verdict(source: source, before: there, after: after, written: ours))
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
            state.base.completed += state.current.completed
            state.base.itemsCompleted += state.current.itemsCompleted
            state.current = TransferProgress(completed: 0)
        }
        return { [self] progress in
            let combined = state.withLock { state in
                state.current = progress
                return TransferProgress(
                    completed: state.base.completed + progress.completed,
                    total: total,
                    itemsCompleted: state.base.itemsCompleted + progress.itemsCompleted
                )
            }
            report(combined)
        }
    }
}
