import AppKit
import TransferCore

/// Copy, Paste, and Move Item Here: what one window does with `Clipboard.shared`. Paste lands in
/// the window's current folder.
///
/// A paste or drop is the provider's `transfer`, tested in TransferIO: a move removes an original
/// only after checking this move wrote a complete copy. This side picks the folder and queues it.
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

    /// A move clears the clipboard only on success, so a refused or failed one can be tried again.
    public func paste(moving: Bool) async {
        guard let session, let clip = Clipboard.shared.clip else { return }
        var folder = snapshot.path
        let sources: TransferRequest.Sources
        switch clip.source {
        case .remote(let id, _, var paths):
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
                    paths = paths.filter { $0.parent != folder }
                    guard !paths.isEmpty else {
                        status = clip.name.map { "“\($0)” is already in this folder." } ?? "These items are already in this folder."
                        return
                    }
                }
            }
            sources = .server(id, paths)
        case .finder(let urls):
            sources = .mac(urls)
        }
        let clipID = clip.id
        await transfer(sources, into: folder, moving: moving, bytes: clip.tally.complete ? clip.tally.bytes : nil) {
            if moving { Clipboard.shared.clear(ifStill: clipID) }
        }
    }

    /// Queues a paste, a drop, or an upload as one operation. Items on another server log in there
    /// first, with sheets that name that server, not this window's. `done` runs once it has succeeded.
    func transfer(
        _ sources: TransferRequest.Sources,
        into folder: RemotePath,
        moving: Bool,
        bytes: UInt64? = nil,
        done: @escaping @MainActor @Sendable () -> Void = {}
    ) async {
        guard let session else { return }
        let names: [[UInt8]]
        var verb = moving ? "Move" : "Copy"
        var source: (any RemoteSession)?
        switch sources {
        case .server(let id, let paths):
            names = paths.map(\.nameBytes)
            if id != session.connection.id {
                do {
                    source = try await provider.session(for: id)
                } catch TransferError.noSuchFile {
                    status = "The server these items were copied from is no longer in the library."
                    return
                } catch {
                    status = "Could not reach the server these items were copied from: \(error.localizedDescription)"
                    return
                }
            }
        case .mac(let urls):
            names = urls.map { Array($0.lastPathComponent.utf8) }
            if !moving { verb = "Upload" }
        }
        let login = source.map { ($0, prompts.login($0.connection)) }
        let request = TransferRequest(sources, into: folder, on: session.connection.id, moving: moving, bytes: bytes)
        let provider = provider
        // A row for one item names it and is matched to it.
        let one = names.count == 1 ? folder.appending(name: names[0]) : nil
        enqueue(title: one.map { "\(verb) \($0.name)" } ?? "\(verb) \(names.count) items", path: one ?? folder) { progress in
            if let (source, sink) = login, !(await source.isConnected) { _ = try await source.connect(prompts: sink) }
            try await provider.transfer(request, progress: progress)
            await done()
        }
    }

    /// Unfinished operations in all windows, for the quit guard (Live uploads are counted apart).
    public static var unfinishedOperations: Int {
        ChromeController.browsers.compactMap(\.model).reduce(0) { total, model in
            total + model.operations.filter { $0.livePath == nil && [.queued, .active, .paused].contains($0.state) }.count
        }
    }
}
