import AppKit
import Foundation
import Observation
import TransferCore

@MainActor
@Observable
public final class TransferModel {
    public let session: any RemoteSession
    public var connections: [SavedConnection] = []
    public var snapshot = BrowserSnapshot()
    public var items: [RemoteItem] = []
    public var columns: [RemotePath: [RemoteItem]] = [:]
    public var operations: [TransferOperation] = []
    public var recents: [RemotePath] = []
    public var pins: [RemotePath] = []
    public var livePaths: [RemotePath] = []
    public var conflicts: [RemotePath] = []
    public var filter = ""
    public var folderText = ""
    private var backStack: [RemotePath] = []
    private var forwardStack: [RemotePath] = []
    public var status = "Not connected"
    public var showsInspector = false
    public var showsShelf = false
    public var draft = SavedConnection(name: "", host: "")
    public var sheet: AppSheet?
    public var promptText = ""
    public var promptSecure = ""
    public var saveSecret = false
    public var hostEvent: HostKeyEvent?
    public var collisionNames: Set<String> = []
    public var applyToAll: NameCollisionChoice?
    public var renaming = false
    public var renameText = ""
    public var conflictPath: RemotePath?
    public var collisionName = ""
    public var applyCollisionToAll = false

    public private(set) var prompts: SheetPrompts
    var pendingPrompt: CheckedContinuation<PromptReply, Never>?
    var pendingHost: CheckedContinuation<HostKeyDecision, Never>?
    var pendingCollision: CheckedContinuation<NameCollisionChoice, Never>?

    public init(session: any RemoteSession) {
        self.session = session
        let prompts = SheetPrompts()
        self.prompts = prompts
        prompts.model = self
        if let stored = UserDefaults.standard.string(forKey: "transfer.viewMode"),
           let mode = ViewMode(rawValue: stored) {
            snapshot.viewMode = mode
        }
        snapshot.showsHidden = UserDefaults.standard.bool(forKey: "transfer.showsHidden")
        Task { await reloadConnections() }
        Task { await listen() }
    }

    public func reloadConnections() async {
        connections = (try? await session.savedConnections()) ?? []
    }

    public func connect(_ connection: SavedConnection) async {
        status = "Connecting…"
        do {
            let path = try await session.connect(connection, prompts: prompts)
            snapshot.connectionID = connection.id
            snapshot.path = path
            status = connection.displayName
            await refresh()
            await reloadSidebars()
        } catch {
            status = error.localizedDescription
        }
    }

    public func refresh() async {
        let path = snapshot.path
        var page: [RemoteItem] = []
        do {
            for try await item in session.list(path) {
                page.append(item)
                let sorted = ListingSort.apply(page, sort: snapshot.sort)
                columns[path] = sorted
                items = visible(sorted)
            }
            let sorted = ListingSort.apply(page, sort: snapshot.sort)
            columns[path] = sorted
            items = visible(sorted)
            await session.remember(path)
            await reloadSidebars()
        } catch {
            status = error.localizedDescription
        }
    }

    public func navigate(_ path: RemotePath) async {
        backStack.append(snapshot.path)
        forwardStack.removeAll()
        snapshot.path = path
        snapshot.selection = []
        await refresh()
    }

    public func goBack() async {
        guard let path = backStack.popLast() else { return }
        forwardStack.append(snapshot.path)
        snapshot.path = path
        await refresh()
    }

    public func goForward() async {
        guard let path = forwardStack.popLast() else { return }
        backStack.append(snapshot.path)
        snapshot.path = path
        await refresh()
    }

    public func goParent() async {
        guard let parent = snapshot.path.parent else { return }
        await navigate(parent)
    }

    public func goHome() async {
        guard let connection = connections.first(where: { $0.id == snapshot.connectionID }) else { return }
        let path = connection.remotePath.isEmpty ? RemotePath(string: "/") : RemotePath(string: connection.remotePath)
        await navigate(path)
    }

    public func goToFolder(_ text: String) async {
        let path = text.hasPrefix("/") ? RemotePath(string: text) : snapshot.path.appending(name: Array(text.utf8))
        await navigate(path)
    }

    public var displayedItems: [RemoteItem] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter { $0.name.lowercased().contains(query) }
    }

    public func open(_ item: RemoteItem) async {
        if item.kind == .directory {
            await navigate(item.path)
            return
        }
        if item.kind == .symlink {
            if let target = try? await session.readlink(item.path) {
                let next = item.path.parent?.appending(name: Array(target.utf8)) ?? RemotePath(string: target)
                if target.hasSuffix("/") || target.hasPrefix("/") {
                    snapshot.path = target.hasPrefix("/") ? RemotePath(string: target) : next
                    await refresh()
                    return
                }
            }
        }
        do {
            let url: URL
            if await session.openKind(fileName: item.name) == .live {
                url = try await session.prepareLiveFile(item.path)
            } else {
                url = try await session.prepareViewFile(item.path)
            }
            NSWorkspace.shared.open(url)
        } catch {
            status = error.localizedDescription
        }
    }

    public func preview() async {
        guard let path = snapshot.selection.first ?? items.first?.path else { return }
        do {
            let url = try await session.preparePreview(path)
            PreviewPanel.shared.show(url)
        } catch {
            status = error.localizedDescription
        }
    }

    public func downloadSelection(to directory: URL) async {
        for path in snapshot.selection {
            let name = path.nameBytes
            let destination = directory.appendingPathComponent(String(decoding: name, as: UTF8.self))
            await run(title: destination.lastPathComponent) { progress in
                try await self.session.download(path, to: destination, progress: progress)
            }
        }
    }

    public func upload(urls: [URL]) async {
        for url in urls {
            let destination = snapshot.path.appending(name: Array(url.lastPathComponent.utf8))
            await run(title: url.lastPathComponent) { progress in
                try await self.session.upload(url, to: destination, progress: progress)
            }
        }
        await refresh()
    }

    public func downloadCopy() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Download"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        await downloadSelection(to: directory)
    }

    public func mkdir() async {
        let name = "untitled folder"
        do {
            try await session.mkdir(snapshot.path.appending(name: Array(name.utf8)))
            await refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    public func deleteSelection() async {
        for path in snapshot.selection {
            do { try await session.remove(path) } catch { status = error.localizedDescription }
        }
        snapshot.selection = []
        await refresh()
    }

    public func beginRename() {
        guard let path = snapshot.selection.first else { return }
        renameText = String(decoding: path.nameBytes, as: UTF8.self)
        renaming = true
    }

    public func renameSelection(to name: String) async {
        guard let path = snapshot.selection.first, let parent = path.parent else { return }
        do {
            try await session.rename(path, to: parent.appending(name: Array(name.utf8)))
            await refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    public func duplicateSelection() async {
        for path in snapshot.selection {
            do { try await session.duplicate(path) } catch { status = error.localizedDescription }
        }
        await refresh()
    }

    public func toggleHidden() async {
        snapshot.showsHidden.toggle()
        UserDefaults.standard.set(snapshot.showsHidden, forKey: "transfer.showsHidden")
        if let cached = columns[snapshot.path] {
            items = visible(cached)
        }
    }

    public func setViewMode(_ mode: ViewMode) {
        snapshot.viewMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "transfer.viewMode")
    }

    public func openLiveSelection() async {
        guard let item = items.first(where: { snapshot.selection.contains($0.path) }) else { return }
        do {
            let url = try await session.prepareLiveFile(item.path)
            NSWorkspace.shared.open(url)
            await reloadSidebars()
        } catch {
            status = error.localizedDescription
        }
    }

    public func pinCurrent() async {
        await session.pin(snapshot.path)
        await reloadSidebars()
    }

    public func discardSelectedLive() async {
        for path in snapshot.selection {
            try? await session.discardLiveFile(path, force: false)
        }
        await reloadSidebars()
    }

    public func clearPreviewCache() async {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transfer/Preview", isDirectory: true)
        try? FileManager.default.removeItem(at: cache)
    }

    public func copyRemoteURL() {
        guard let connection = connections.first(where: { $0.id == snapshot.connectionID }) else { return }
        let paths = snapshot.selection.isEmpty ? [snapshot.path] : Array(snapshot.selection)
        let text = paths.map { SftpURL.string(connection: connection, path: $0) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func openSelection() async {
        guard let item = displayedItems.first(where: { snapshot.selection.contains($0.path) }) else { return }
        await open(item)
    }

    public func resolveConflict(_ choice: LiveConflictChoice) async {
        guard let path = conflictPath else { return }
        sheet = nil
        do {
            if let server = try await session.resolveLive(path, choice: choice), choice == .compare {
                let local = server.deletingLastPathComponent().appendingPathComponent(server.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " (server)", with: ""))
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/opendiff")
                process.arguments = [local.path, server.path]
                if FileManager.default.isExecutableFile(atPath: process.executableURL!.path) {
                    try? process.run()
                } else {
                    NSWorkspace.shared.open(server)
                }
            }
            await refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    public func requestQuit() async {
        let unsynced = await session.unsyncedLiveCount
        if unsynced > 0 {
            sheet = .quit(unsynced)
        } else {
            NSApp.terminate(nil)
        }
    }

    public func openTerminal() {
        guard let connection = connections.first(where: { $0.id == snapshot.connectionID }) else { return }
        let path = snapshot.path.display.replacingOccurrences(of: "'", with: "'\\''")
        let command = "cd '\(path)' && exec $SHELL -l"
        TerminalLauncher.open(connection: connection, command: command)
    }

    public func saveDraft() async {
        var connection = draft
        if connection.name.isEmpty { connection.name = connection.host }
        do {
            try await session.save(connection)
            await reloadConnections()
            sheet = nil
            await connect(connection)
        } catch {
            status = error.localizedDescription
        }
    }

    public func visible(_ items: [RemoteItem]) -> [RemoteItem] {
        items.filter { snapshot.showsHidden || !$0.isHidden }
    }

    private func run(title: String, body: @escaping @Sendable (@escaping @Sendable (TransferProgress) -> Void) async throws -> Void) async {
        let id = UUID().uuidString
        var operation = TransferOperation(id: id, title: title, state: .active)
        operations.append(operation)
        showsShelf = true
        do {
            try await body { [weak self] progress in
                Task { @MainActor in
                    guard let self, let index = self.operations.firstIndex(where: { $0.id == id }) else { return }
                    self.operations[index].progress = progress
                }
            }
            operation.state = .succeeded
        } catch {
            operation.state = .failed
            operation.message = error.localizedDescription
            status = error.localizedDescription
        }
        if let index = operations.firstIndex(where: { $0.id == id }) {
            operations[index] = operation
        }
        operations.removeAll { $0.state == .succeeded }
        if operations.isEmpty { showsShelf = false }
    }

    private func reloadSidebars() async {
        recents = await session.recents()
        pins = await session.pins()
        livePaths = await session.livePaths.sorted { $0.display < $1.display }
    }

    private func listen() async {
        for await event in session.events() {
            if case .notice(let text) = event { status = text }
            if case .conflict(let path) = event {
                conflictPath = path
                if !conflicts.contains(path) { conflicts.append(path) }
                sheet = .conflict
            }
            if case .operation(let operation) = event {
                showsShelf = true
                if let index = operations.firstIndex(where: { $0.id == operation.id }) {
                    operations[index] = operation
                } else {
                    operations.append(operation)
                }
            }
        }
    }
}

public enum AppSheet: Identifiable {
    case connection
    case prompt(PromptRequest)
    case hostKey(HostKeyEvent)
    case delete
    case collision(String)
    case conflict
    case quit(Int)
    case goToFolder

    public var id: String {
        switch self {
        case .connection: "connection"
        case .prompt: "prompt"
        case .hostKey: "host"
        case .delete: "delete"
        case .collision: "collision"
        case .conflict: "conflict"
        case .quit: "quit"
        case .goToFolder: "goto"
        }
    }
}

public final class SheetPrompts: PromptSink, @unchecked Sendable {
    weak var model: TransferModel?

    public func answer(_ request: PromptRequest) async -> PromptReply {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.model?.pendingPrompt = continuation
                self.model?.sheet = .prompt(request)
            }
        }
    }

    public func resolveCollision(fileName: String) async -> NameCollisionChoice {
        if let remembered = await MainActor.run(body: { model?.applyToAll }) {
            return remembered
        }
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.model?.pendingCollision = continuation
                self.model?.sheet = .collision(fileName)
            }
        }
    }

    public func decideHostKey(_ event: HostKeyEvent) async -> HostKeyDecision {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.model?.pendingHost = continuation
                self.model?.sheet = .hostKey(event)
            }
        }
    }
}

extension TransferModel {
    func finishPrompt(_ reply: PromptReply) {
        pendingPrompt?.resume(returning: reply)
        pendingPrompt = nil
        sheet = nil
    }

    func finishHost(_ decision: HostKeyDecision) {
        pendingHost?.resume(returning: decision)
        pendingHost = nil
        sheet = nil
    }

    func finishCollision(_ choice: NameCollisionChoice, applyToAll: Bool) {
        if applyToAll { self.applyToAll = choice }
        pendingCollision?.resume(returning: choice)
        pendingCollision = nil
        sheet = nil
    }
}
