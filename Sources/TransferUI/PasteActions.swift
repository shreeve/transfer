import AppKit
import TransferCore

/// Copy, Paste, and Move Item Here. The clipboard itself is `Clipboard.shared`; this is what one
/// window does with it. Paste always lands in the window's current folder.
///
/// A move is the one operation here that deletes: it removes an original only when `MoveCheck`
/// finds that this move wrote a complete copy of it. What the destination already held before the
/// move began never counts as that copy, so a file of the same name, size, and time, or the
/// original itself seen through a second saved server, keeps the original where it is.
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
    /// another server travel through a scratch folder on this Mac. Files from Finder upload. A move
    /// clears the clipboard only once it has succeeded, so a refused or failed one can be tried again.
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
                guard moving else {
                    pasteOnServer(paths, into: folder, session: session, tally: clip.tally)
                    return
                }
                let outside = paths.filter { $0.parent != folder }
                guard !outside.isEmpty else {
                    status = paths.count == 1 ? "“\(paths[0].name)” is already in this folder." : "These items are already in this folder."
                    return
                }
                await move(outside, into: folder)
                if await Self.allGone(outside, from: session) { Clipboard.shared.clear(ifStill: clip.id) }
            } else {
                let source: any RemoteSession
                do {
                    source = try await provider.session(for: id)
                } catch TransferError.noSuchFile {
                    status = "The server these items were copied from is no longer in the library."
                    return
                } catch {
                    status = "Could not reach the server these items were copied from: \(error.localizedDescription)"
                    return
                }
                pasteAcross(paths, from: source, into: folder, session: session, moving: moving, clip: clip)
            }
        case .finder(let urls):
            if moving {
                moveFromFinder(urls, into: folder, session: session, clip: clip.id)
            } else {
                await upload(urls: urls, into: folder)
            }
        }
    }

    /// Whether every path is gone from the server, so a clip of them is spent. Only "no such file"
    /// counts; any other answer keeps the clip.
    nonisolated private static func allGone(_ paths: [RemotePath], from session: any RemoteSession) async -> Bool {
        for path in paths {
            do {
                _ = try await session.stat(path)
                return false
            } catch TransferError.noSuchFile {
                continue
            } catch {
                return false
            }
        }
        return true
    }

    private func pasteOnServer(_ paths: [RemotePath], into folder: RemotePath, session: any RemoteSession, tally: ClipTally) {
        // Survives a retry, which runs the body again: an item already copied is not copied
        // twice, and "name copy" is not joined by "name copy 2".
        let state = Locked(PasteState())
        enqueue(title: Self.title("Paste", paths.map(\.name)), path: folder) { progress in
            // A paste into the folder the items came from makes "name copy" beside each one.
            var existing: Set<String> = []
            if paths.contains(where: { $0.parent == folder }) {
                for try await item in session.list(folder) { existing.insert(item.name) }
            }
            let sum = ProgressSum(progress, tally: tally, passes: 1)
            for path in paths where !state.value.done.contains(path) {
                let target = state.withLock { state in
                    if let chosen = state.targets[path] { return chosen }
                    // Elsewhere the item keeps its own name, byte for byte.
                    let chosen = path.parent == folder
                        ? folder.appending(name: Array(PasteRules.destinationName(for: path, into: folder, existing: existing).utf8))
                        : folder.appending(name: path.nameBytes)
                    state.targets[path] = chosen
                    return chosen
                }
                existing.insert(target.name)
                try await session.copy(path, to: target, progress: sum.next())
                state.withLock { _ = $0.done.insert(path) }
            }
        }
    }

    /// Down from the source server into a scratch folder, then up to this one, one item at a
    /// time. A move removes each original only once `MoveCheck` says this move wrote its copy.
    private func pasteAcross(_ paths: [RemotePath], from source: any RemoteSession, into folder: RemotePath, session: any RemoteSession, moving: Bool, clip: Clipboard.Clip) {
        // The source server may need its own login; its sheets name it, not this window's server.
        let login = prompts.login(source.connection)
        let tally = clip.tally
        let clipID = clip.id
        let state = Locked(PasteState())
        let parents = Set(paths.compactMap(\.parent))
        enqueue(title: Self.title(moving ? "Move" : "Paste", paths.map(\.name)), path: folder) { progress in
            if !(await source.isConnected) { _ = try await source.connect(prompts: login) }
            if moving, !state.value.checked {
                let same = try await Self.sameFolder(folder, on: session) { name in
                    for parent in parents {
                        do {
                            _ = try await source.stat(parent.appending(name: Array(name.utf8)))
                            return true
                        } catch TransferError.noSuchFile {
                            continue
                        }
                    }
                    return false
                }
                if same {
                    throw TransferError.failed("Nothing was moved: this is the folder the items came from, reached through another saved server, so each item would be copied onto itself.")
                }
                state.withLock { $0.checked = true }
            }
            let ignoresCase = Clipboard.diskIgnoresCase
            let sum = ProgressSum(progress, tally: tally, passes: 2)
            var kept: [(name: String, reason: KeptReason)] = []
            for path in paths where !state.value.done.contains(path) {
                // The Mac's disk may not hold two names the server keeps apart. Refused before
                // anything is copied, since one of the two would silently stand in for the other.
                var clash = NameClash(ignoringCase: ignoresCase)
                for try await (key, _) in source.walkTree(path) { clash.add(key) }
                if let pair = clash.found {
                    kept.append((path.name, .clash(pair.0, pair.1)))
                    continue
                }
                let destination = folder.appending(name: path.nameBytes)
                let before = moving ? try await Self.snapshot(destination, on: session, into: state) : [:]
                let scratch = Clipboard.scratchFolder()
                defer { try? FileManager.default.removeItem(at: scratch) }
                let local = scratch.appendingPathComponent(path.name)
                try await source.download(path, to: local, progress: sum.next())
                try await session.upload(local, to: destination, progress: sum.next())
                if moving {
                    let verdict = MoveCheck.verdict(source: try await source.tree(path), before: before, after: try await session.tree(destination))
                    if let reason = KeptReason(verdict) {
                        kept.append((path.name, reason))
                        continue
                    }
                    do {
                        try await source.remove(path)
                    } catch TransferError.liveUnsynced(let count) {
                        kept.append((path.name, .live(count)))
                        continue
                    }
                }
                state.withLock { _ = $0.done.insert(path) }
            }
            if !kept.isEmpty { throw TransferError.failed(Self.keptMessage(kept, moving: moving, where: "on the other server")) }
            if moving { await MainActor.run { Clipboard.shared.clear(ifStill: clipID) } }
        }
    }

    /// One upload per item, as a drop does; each original goes to the Trash once `MoveCheck` says
    /// this move wrote its copy.
    private func moveFromFinder(_ urls: [URL], into folder: RemotePath, session: any RemoteSession, clip: UUID) {
        let remaining = Locked(urls.count)
        for url in urls {
            let destination = folder.appending(name: Array(url.lastPathComponent.utf8))
            let state = Locked(PasteState())
            enqueue(title: "Move \(url.lastPathComponent)", path: destination) { progress in
                if !state.value.checked {
                    let parent = url.deletingLastPathComponent()
                    let same = try await Self.sameFolder(folder, on: session) { name in
                        FileManager.default.fileExists(atPath: parent.appendingPathComponent(name).path)
                    }
                    if same {
                        throw TransferError.failed("Nothing was moved: this folder on the server is the folder on this Mac that “\(url.lastPathComponent)” is in, so it would be copied onto itself.")
                    }
                    state.withLock { $0.checked = true }
                }
                let before = try await Self.snapshot(destination, on: session, into: state)
                try await session.upload(url, to: destination, progress: progress)
                let verdict = MoveCheck.verdict(source: LocalTree.entries(url), before: before, after: try await session.tree(destination))
                if let reason = KeptReason(verdict) {
                    throw TransferError.failed(Self.keptMessage([(url.lastPathComponent, reason)], moving: true, where: "on this Mac"))
                }
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                if remaining.withLock({ $0 -= 1; return $0 == 0 }) {
                    await MainActor.run { Clipboard.shared.clear(ifStill: clip) }
                }
            }
        }
    }

    /// What the destination held before this move first reached it, kept across retries: a
    /// retry must not count the first attempt's own copy as something that was already there.
    nonisolated private static func snapshot(_ destination: RemotePath, on session: any RemoteSession, into state: Locked<PasteState>) async throws -> [String: TreeEntry] {
        if let taken = state.value.before[destination] { return taken }
        var present = true
        do {
            _ = try await session.stat(destination)
        } catch TransferError.noSuchFile {
            present = false
        }
        // Only the root's own absence means "nothing there". A walk that loses a folder halfway
        // throws "no such file" too, which is no evidence the destination was empty: it is thrown on.
        let taken = present ? try await session.tree(destination) : [:]
        state.withLock { $0.before[destination] = taken }
        return taken
    }

    /// Whether `folder` is, on the storage itself, the folder a move's originals are in: two saved
    /// servers for one host (a name and its address, or two users), or two hosts sharing a disk.
    /// A folder with a name no one else uses is made in `folder`; `seen` looks for that name
    /// beside the originals. Only "no such file" there proves two places.
    nonisolated private static func sameFolder(_ folder: RemotePath, on session: any RemoteSession, seen: @Sendable (String) async throws -> Bool) async throws -> Bool {
        let name = ".transfer-move-check-\(UUID().uuidString)"
        let probe = folder.appending(name: Array(name.utf8))
        try await session.mkdir(probe)
        let found: Bool
        do {
            found = try await seen(name)
        } catch {
            try? await session.remove(probe)
            throw error
        }
        try? await session.remove(probe)
        return found
    }

    nonisolated private static func title(_ verb: String, _ names: [String]) -> String {
        names.count == 1 ? "\(verb) \(names[0])" : "\(verb) \(names.count) items"
    }

    /// One sentence per reason: "Kept “a” and “b” on the other server: the copy is not complete."
    nonisolated private static func keptMessage(_ kept: [(name: String, reason: KeptReason)], moving: Bool, where place: String) -> String {
        var sentences: [String] = []
        for reason in kept.map(\.reason).uniqued() {
            let names = kept.filter { $0.reason == reason }.map { "“\($0.name)”" }
            let list = ListFormatter.localizedString(byJoining: names)
            switch reason {
            case .clash(let first, let second):
                sentences.append("Did not \(moving ? "move" : "paste") \(list): “\(first)” and “\(second)” differ only in case or accents, and this Mac's disk, which the items pass through, cannot hold both.")
            case .alreadyThere:
                sentences.append("Kept \(list) \(place): something with that name was already at the destination, so this move cannot tell its own copy from it.")
            case .incomplete:
                sentences.append("Kept \(list) \(place): the copy is not complete.")
            case .live(let count):
                sentences.append("Kept \(list) \(place): \(TransferError.liveUnsynced(count).localizedDescription).")
            }
        }
        return sentences.joined(separator: " ")
    }

    /// Operations still queued, running, or paused in every window, for the quit guard. Live
    /// uploads are counted by the guard's own unsynced count.
    public static var unfinishedOperations: Int {
        ChromeController.browsers.compactMap(\.model).reduce(0) { total, model in
            total + model.operations.filter { $0.livePath == nil && [.queued, .active, .paused].contains($0.state) }.count
        }
    }
}

/// One paste's memory across the retries of its operation.
private struct PasteState {
    /// Items finished: copied, or moved and removed.
    var done: Set<RemotePath> = []
    /// Where each item of a paste on one server goes.
    var targets: [RemotePath: RemotePath] = [:]
    /// Each destination's tree before the move reached it.
    var before: [RemotePath: [String: TreeEntry]] = [:]
    /// Whether the two ends of a move were proven to be different folders.
    var checked = false
}

private enum KeptReason: Hashable {
    case clash(String, String)
    case alreadyThere
    case incomplete
    case live(Int)

    init?(_ verdict: MoveCheck.Verdict) {
        switch verdict {
        case .remove: return nil
        case .alreadyThere: self = .alreadyThere
        case .incomplete: self = .incomplete
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

/// Joins the progress of several copies, one after another, into one row on the shelf. The
/// clip's count gives the total once it is known; a move between servers passes twice.
private final class ProgressSum: Sendable {
    private let report: @Sendable (TransferProgress) -> Void
    private let total: UInt64?
    /// What the finished copies reported, and the running one.
    private let state = Locked((base: TransferProgress(completed: 0), current: TransferProgress(completed: 0)))

    init(_ report: @escaping @Sendable (TransferProgress) -> Void, tally: ClipTally, passes: UInt64) {
        self.report = report
        total = tally.complete && tally.bytes > 0 ? tally.bytes * passes : nil
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
