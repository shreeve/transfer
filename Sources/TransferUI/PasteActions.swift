import AppKit
import TransferCore

/// Copy, Paste, and Move Item Here. The clipboard itself is `Clipboard.shared`; this is what one
/// window does with it. Paste always lands in the window's current folder.
extension TransferModel {
    public var canCopy: Bool { session != nil && !snapshot.selection.isEmpty }

    public var canPaste: Bool { session != nil && snapshot.connectionID != nil && Clipboard.shared.clip != nil }

    /// "Move Item Here" or "Move 3 Items Here", as in Finder's Edit menu.
    public var moveTitle: String {
        let count: Int
        switch Clipboard.shared.clip?.source {
        case .remote(_, _, let paths): count = paths.count
        case .finder(let urls): count = urls.count
        case nil: count = 1
        }
        return count == 1 ? "Move Item Here" : "Move \(count) Items Here"
    }

    public func copySelection() {
        guard let session, let connection = currentConnection else { return }
        let items = selectedItems
        guard let first = items.first else { return }
        let folder = first.path.parent ?? snapshot.path
        Clipboard.shared.copy(items, session: session, place: "\(connection.displayName):\(folder.display)", prompts: operationPrompts())
    }

    /// Items on this window's server are copied on the server, or renamed when moving. Items on
    /// another server travel through a scratch folder on this Mac. Files from Finder upload.
    public func paste(moving: Bool) async {
        guard let session, let clip = Clipboard.shared.clip else { return }
        var folder = snapshot.path
        switch clip.source {
        case .remote(let id, _, let paths):
            if id == session.connection.id {
                // Selecting a folder in column view makes it the location, so Copy then Paste on a
                // selected folder would paste it into itself. Finder makes "name copy" beside it.
                if snapshot.viewMode == .columns, paths.contains(folder), snapshot.selection == [folder], let parent = folder.parent {
                    folder = parent
                }
                if let refusal = PasteRules.refusal(sources: paths, into: folder) {
                    status = refusal
                    NSSound.beep()
                    return
                }
                if moving {
                    Clipboard.shared.clear()
                    let outside = paths.filter { $0.parent != folder }
                    if !outside.isEmpty { await move(outside, into: folder) }
                } else {
                    pasteOnServer(paths, into: folder, session: session, tally: clip.tally)
                }
            } else {
                guard let source = try? await provider.session(for: id) else {
                    status = "The server these items were copied from is no longer in the library."
                    return
                }
                if moving { Clipboard.shared.clear() }
                pasteAcross(paths, from: source, into: folder, session: session, moving: moving, tally: clip.tally)
            }
        case .finder(let urls):
            if moving {
                Clipboard.shared.clear()
                moveFromFinder(urls, into: folder, session: session)
            } else {
                await upload(urls: urls, into: folder)
            }
        }
    }

    private func pasteOnServer(_ paths: [RemotePath], into folder: RemotePath, session: any RemoteSession, tally: ClipTally) {
        enqueue(title: Self.title("Paste", paths.map(\.name)), path: folder) { progress in
            // A paste into the folder the items came from makes "name copy" beside each one.
            var existing: Set<String> = []
            if paths.contains(where: { $0.parent == folder }) {
                for try await item in session.list(folder) { existing.insert(item.name) }
            }
            let sum = ProgressSum(progress, tally: tally, passes: 1)
            for path in paths {
                let name = PasteRules.destinationName(for: path, into: folder, existing: existing)
                existing.insert(name)
                try await session.copy(path, to: folder.appending(name: Array(name.utf8)), progress: sum.next())
            }
        }
    }

    /// Down from the source server into a scratch folder, then up to this one. A move removes
    /// each original only once the copy holds everything it did.
    private func pasteAcross(_ paths: [RemotePath], from source: any RemoteSession, into folder: RemotePath, session: any RemoteSession, moving: Bool, tally: ClipTally) {
        let prompts = prompts
        enqueue(title: Self.title(moving ? "Move" : "Paste", paths.map(\.name)), path: folder) { progress in
            if !(await source.isConnected) { _ = try await source.connect(prompts: prompts) }
            let scratch = Clipboard.scratchFolder()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let sum = ProgressSum(progress, tally: tally, passes: 2)
            var kept: [String] = []
            for path in paths {
                let local = scratch.appendingPathComponent(path.name)
                let destination = folder.appending(name: path.nameBytes)
                try await source.download(path, to: local, progress: sum.next())
                try await session.upload(local, to: destination, progress: sum.next())
                guard moving else { continue }
                let original = try await source.tree(path)
                let copied = try await session.tree(destination)
                if TreeCheck.missing(source: original, destination: copied).isEmpty {
                    try await source.remove(path)
                } else {
                    kept.append(path.name)
                }
            }
            if !kept.isEmpty { throw TransferError.failed(Self.keptMessage(kept, where: "on the other server")) }
        }
    }

    /// One upload per item, as a drop does; each original goes to the Trash once the server holds
    /// everything it did.
    private func moveFromFinder(_ urls: [URL], into folder: RemotePath, session: any RemoteSession) {
        for url in urls {
            let destination = folder.appending(name: Array(url.lastPathComponent.utf8))
            enqueue(title: "Move \(url.lastPathComponent)", path: destination) { progress in
                try await session.upload(url, to: destination, progress: progress)
                let copied = try await session.tree(destination)
                guard TreeCheck.missing(source: LocalTree.entries(url), destination: copied).isEmpty else {
                    throw TransferError.failed(Self.keptMessage([url.lastPathComponent], where: "on this Mac"))
                }
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
    }

    nonisolated private static func title(_ verb: String, _ names: [String]) -> String {
        names.count == 1 ? "\(verb) \(names[0])" : "\(verb) \(names.count) items"
    }

    nonisolated private static func keptMessage(_ names: [String], where place: String) -> String {
        let list = names.map { "“\($0)”" }.joined(separator: ", ")
        return "Kept \(list) \(place): the copy is not complete."
    }
}

/// Joins the progress of several copies, one after another, into one row on the shelf. The
/// clip's count gives the total once it is known; a move between servers passes twice.
private final class ProgressSum: @unchecked Sendable {
    private let lock = NSLock()
    private let report: @Sendable (TransferProgress) -> Void
    private let total: UInt64?
    private var base = TransferProgress(completed: 0)
    private var current = TransferProgress(completed: 0)

    init(_ report: @escaping @Sendable (TransferProgress) -> Void, tally: ClipTally, passes: UInt64) {
        self.report = report
        total = tally.complete && tally.bytes > 0 ? tally.bytes * passes : nil
    }

    /// The reporter for the next copy. What the previous one reported is kept.
    func next() -> @Sendable (TransferProgress) -> Void {
        lock.withLock {
            base.completed += current.completed
            base.itemsCompleted += current.itemsCompleted
            current = TransferProgress(completed: 0)
        }
        return { [self] progress in
            let combined = lock.withLock {
                current = progress
                return TransferProgress(
                    completed: base.completed + progress.completed,
                    total: total,
                    itemsCompleted: base.itemsCompleted + progress.itemsCompleted
                )
            }
            report(combined)
        }
    }
}
