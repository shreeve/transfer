import AppKit
import Foundation
import Observation
import QuickLookUI
import SwiftUI
import TransferCore
import UniformTypeIdentifiers

/// Keys for the global preferences that Settings and the menus share.
public enum Preferences {
    public static let caseInsensitiveSort = "transfer.sortCaseInsensitive"
    public static let foldersFirst = "transfer.foldersFirst"
    public static let showsAppIcon = "transfer.showsAppIcon"

    /// On unless the user turned it off.
    public static func showsAppIconValue(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsAppIcon) == nil ? true : defaults.bool(forKey: showsAppIcon)
    }

    /// On unless the user turned it off; a missing default reads as true.
    public static func foldersFirstValue(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: foldersFirst) == nil ? true : defaults.bool(forKey: foldersFirst)
    }
    public static let showsHidden = "transfer.showsHidden"
    public static let viewMode = "transfer.viewMode"
}

public enum SidebarItem: Hashable {
    case server(ConnectionID)
    case recent(RemotePath)
    case pin(RemotePath)
    case live(RemotePath)
    case conflict(RemotePath)
}

/// One window's state. Windows and tabs share sessions through the provider.
@MainActor
@Observable
public final class TransferModel {
    public let provider: any SessionProvider
    public private(set) var session: (any RemoteSession)?
    public var connections: [SavedConnection] = []
    public var snapshot = BrowserSnapshot()
    public var items: [RemoteItem] = []
    public var columns: [RemotePath: [RemoteItem]] = [:]
    public var columnRoot: RemotePath?
    public var operations: [TransferOperation] = []
    public var recents: [RemotePath] = []
    public var pins: [RemotePath] = []
    public var liveFiles: [LiveFile] = []
    public var conflicts: [RemotePath] = []
    public var conflictComparable = false
    public var conflictConfirm: LiveConflictChoice?
    public var filter = ""
    public var filterFocusTick = 0
    /// True while a text field in the window has focus, so Space and Return stay with the field.
    public var textEditing = false
    public var folderText = ""
    public var status = "Not connected"
    public var showsInspector = false
    public var sidebarCollapsed = false
    public var showsAppIcon = Preferences.showsAppIconValue()

    public func toggleSidebar() {
        sidebarCollapsed.toggle()
    }
    public var showsShelf = false
    public var draft = SavedConnection(name: "", host: "")
    public var draftIsEdit = false
    public var sheet: AppSheet?
    public var promptSecure = ""
    public var saveSecret = false
    public var renaming = false
    public var renameText = ""
    public var conflictPath: RemotePath?
    public var applyCollisionToAll = false
    public var sidebarSelection: SidebarItem?
    public var inspectorLinkTarget: String?
    public var terminalAvailable = TerminalLauncher.anyInstalled()

    public private(set) var prompts: SheetPrompts
    var pendingPrompt: CheckedContinuation<PromptReply, Never>?
    var pendingHost: CheckedContinuation<HostKeyDecision, Never>?
    var pendingCollision: CheckedContinuation<NameCollisionChoice, Never>?
    var applyToAll: NameCollisionChoice?

    private var backStack: [RemotePath] = []
    private var forwardStack: [RemotePath] = []
    private var listener: Task<Void, Never>?
    private var listing: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var runners: [String: Runner] = [:]

    private struct Runner {
        var body: @Sendable (@escaping @Sendable (TransferProgress) -> Void) async throws -> Void
        var task: Task<Void, Never>?
    }

    public init(provider: any SessionProvider) {
        self.provider = provider
        let prompts = SheetPrompts()
        self.prompts = prompts
        prompts.model = self
        if let stored = UserDefaults.standard.string(forKey: "transfer.viewMode"),
           let mode = ViewMode(rawValue: stored) {
            snapshot.viewMode = mode
        }
        snapshot.showsHidden = UserDefaults.standard.bool(forKey: "transfer.showsHidden")
        snapshot.sort.caseInsensitive = UserDefaults.standard.bool(forKey: Preferences.caseInsensitiveSort)
        snapshot.sort.foldersFirst = Preferences.foldersFirstValue()
        Task { await reloadConnections() }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.applyPreferences() }
        }
    }

    /// Picks up changes made in Settings while the window is open.
    private func applyPreferences() {
        let defaults = UserDefaults.standard
        var changed = false
        let hidden = defaults.bool(forKey: "transfer.showsHidden")
        if hidden != snapshot.showsHidden {
            snapshot.showsHidden = hidden
            changed = true
        }
        let folded = defaults.bool(forKey: Preferences.caseInsensitiveSort)
        let foldersFirst = Preferences.foldersFirstValue(defaults)
        if folded != snapshot.sort.caseInsensitive || foldersFirst != snapshot.sort.foldersFirst {
            snapshot.sort.caseInsensitive = folded
            snapshot.sort.foldersFirst = foldersFirst
            for (path, list) in columns { columns[path] = ListingSort.apply(list, sort: snapshot.sort) }
            changed = true
        }
        let icon = Preferences.showsAppIconValue(defaults)
        if icon != showsAppIcon { showsAppIcon = icon }
        if let stored = defaults.string(forKey: "transfer.viewMode"), let mode = ViewMode(rawValue: stored), mode != snapshot.viewMode {
            snapshot.viewMode = mode
            if mode == .columns { columnRoot = snapshot.path }
        }
        if changed { items = visible(columns[snapshot.path] ?? []) }
    }

    // MARK: Servers

    public func reloadConnections() async {
        connections = (try? await provider.savedConnections()) ?? []
    }

    public var currentConnection: SavedConnection? {
        connections.first { $0.id == snapshot.connectionID }
    }

    public func connect(_ connection: SavedConnection) async {
        status = "Connecting to \(connection.displayName)…"
        do {
            let session = try await provider.session(for: connection.id)
            self.session = session
            listen(to: session)
            let path = try await session.connect(prompts: prompts)
            snapshot.connectionID = connection.id
            snapshot.selection = []
            backStack.removeAll()
            forwardStack.removeAll()
            columns.removeAll()
            loadPreferences(for: connection.id)
            status = connection.displayName
            snapshot.path = path
            columnRoot = path
            await refresh()
            await reloadSidebars()
        } catch {
            status = error.localizedDescription
        }
    }

    public func disconnect() async {
        await session?.disconnect()
        snapshot.connectionID = nil
        items = []
        columns.removeAll()
        liveFiles = []
        status = "Not connected"
    }

    public func newConnection() {
        draft = SavedConnection(name: "", host: "")
        draftIsEdit = false
        sheet = .connection
    }

    public func editConnection(_ connection: SavedConnection) {
        draft = connection
        draftIsEdit = true
        sheet = .connection
    }

    public func saveDraft() async {
        var connection = draft
        if connection.name.isEmpty { connection.name = connection.host }
        let wasEdit = draftIsEdit
        do {
            try await provider.save(connection)
            await reloadConnections()
            sheet = nil
            if !wasEdit { await connect(connection) }
        } catch {
            status = error.localizedDescription
        }
    }

    public func askToRemove(_ connection: SavedConnection) {
        sheet = .removeServer(connection)
    }

    public func removeServer(_ connection: SavedConnection) async {
        sheet = nil
        do {
            if snapshot.connectionID == connection.id { await disconnect() }
            try await provider.removeConnection(connection.id)
            await reloadConnections()
        } catch {
            status = error.localizedDescription
        }
    }

    // MARK: Listing

    public func refresh() async {
        let path = snapshot.path
        guard let session else { return }
        listing?.cancel()
        let task = Task { [weak self] in
            var page: [RemoteItem] = []
            var lastFlush = ContinuousClock.now
            let hadCache = self?.columns[path] != nil
            do {
                for try await item in session.list(path) {
                    if Task.isCancelled { return }
                    page.append(item)
                    if !hadCache, lastFlush.duration(to: .now) > .milliseconds(80) {
                        self?.publish(page, for: path)
                        lastFlush = .now
                    }
                }
                self?.publish(page, for: path)
                await session.remember(path)
                await self?.reloadSidebars()
            } catch is CancellationError {
                return
            } catch {
                if !page.isEmpty { self?.publish(page, for: path) }
                self?.status = error.localizedDescription
            }
        }
        listing = task
        await task.value
    }

    private func publish(_ page: [RemoteItem], for path: RemotePath) {
        let sorted = ListingSort.apply(page, sort: snapshot.sort)
        columns[path] = sorted
        if path == snapshot.path { items = visible(sorted) }
    }

    /// Lists one folder for the column view without navigating.
    public func loadColumn(_ path: RemotePath) {
        guard let session, columns[path] == nil else { return }
        columns[path] = []
        Task { [weak self] in
            var page: [RemoteItem] = []
            do {
                for try await item in session.list(path) { page.append(item) }
            } catch {
                self?.status = error.localizedDescription
            }
            self?.publish(page, for: path)
        }
    }

    public func navigate(_ path: RemotePath) async {
        if path != snapshot.path {
            backStack.append(snapshot.path)
            forwardStack.removeAll()
        }
        await show(path)
    }

    private func show(_ path: RemotePath) async {
        snapshot.path = path
        snapshot.selection = []
        columnRoot = path
        items = visible(columns[path] ?? [])
        await refresh()
    }

    public func goBack() async {
        guard let path = backStack.popLast() else { return }
        forwardStack.append(snapshot.path)
        await show(path)
    }

    public func goForward() async {
        guard let path = forwardStack.popLast() else { return }
        backStack.append(snapshot.path)
        await show(path)
    }

    public func goParent() async {
        guard let parent = snapshot.path.parent else { return }
        await navigate(parent)
    }

    public func goHome() async {
        guard let session else { return }
        do {
            let path = try await session.connect(prompts: prompts)
            await navigate(path)
        } catch {
            status = error.localizedDescription
        }
    }

    public func goToFolder(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let path = trimmed.hasPrefix("/") ? RemotePath(string: trimmed) : snapshot.path.appending(name: Array(trimmed.utf8))
        await navigate(path)
    }

    public var displayedItems: [RemoteItem] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter { $0.name.lowercased().contains(query) }
    }

    public func visible(_ items: [RemoteItem]) -> [RemoteItem] {
        items.filter { snapshot.showsHidden || !$0.isHidden }
    }

    /// Selected items may live in another column's listing when a folder is selected in column
    /// view, so the lookup falls back to every cached listing.
    public var primaryItem: RemoteItem? {
        if let item = displayedItems.first(where: { snapshot.selection.contains($0.path) }) { return item }
        for list in columns.values {
            if let item = list.first(where: { snapshot.selection.contains($0.path) }) { return item }
        }
        return nil
    }

    /// Menu items whose shortcut is a plain key stay out of the way of text entry.
    public var plainKeysAvailable: Bool { !textEditing && sheet == nil }

    public var selectedItems: [RemoteItem] {
        let shown = displayedItems.filter { snapshot.selection.contains($0.path) }
        if shown.count == snapshot.selection.count { return shown }
        var found: [RemotePath: RemoteItem] = [:]
        for list in columns.values {
            for item in list where snapshot.selection.contains(item.path) { found[item.path] = item }
        }
        return found.values.sorted { $0.path.display < $1.path.display }
    }

    /// A single selected folder becomes the current location, as in Finder, and stays selected.
    /// Files and multiple selections leave the location at their parent.
    public func selectInColumns(_ selected: [RemoteItem], parent: RemotePath) {
        snapshot.selection = Set(selected.map(\.path))
        if let folder = selected.first, selected.count == 1, folder.kind == .directory {
            loadColumn(folder.path)
            snapshot.path = folder.path
            items = visible(columns[folder.path] ?? [])
            Task { await session?.remember(folder.path) }
        } else {
            snapshot.path = parent
            items = visible(columns[parent] ?? [])
        }
    }

    /// The roots of a drag: the selection when it holds the dragged row, else that row alone.
    public func dragItems(including item: RemoteItem) -> [RemoteItem] {
        let selected = selectedItems
        return selected.contains(where: { $0.path == item.path }) ? selected : [item]
    }

    // MARK: Sort

    public func setSort(column: String, ascending: Bool) {
        snapshot.sort.column = column
        snapshot.sort.ascending = ascending
        if let id = snapshot.connectionID, let data = try? JSONEncoder().encode(snapshot.sort) {
            UserDefaults.standard.set(data, forKey: "transfer.sort.\(id.rawValue.uuidString)")
        }
        for (path, list) in columns { columns[path] = ListingSort.apply(list, sort: snapshot.sort) }
        items = visible(columns[snapshot.path] ?? [])
    }

    private func loadPreferences(for id: ConnectionID) {
        let key = id.rawValue.uuidString
        let folded = UserDefaults.standard.bool(forKey: Preferences.caseInsensitiveSort)
        let foldersFirst = Preferences.foldersFirstValue()
        if let data = UserDefaults.standard.data(forKey: "transfer.sort.\(key)"),
           var sort = try? JSONDecoder().decode(SortConfiguration.self, from: data) {
            sort.caseInsensitive = folded
            sort.foldersFirst = foldersFirst
            snapshot.sort = sort
        } else {
            snapshot.sort = SortConfiguration(caseInsensitive: folded, foldersFirst: foldersFirst)
        }
    }

    /// The Status column and inspector text for a path: Live state or an active transfer.
    public func statusText(for path: RemotePath) -> String {
        if let live = liveFile(for: path) {
            if live.conflict { return "Conflict" }
            if live.uploading { return "Uploading" }
            if live.paused { return "Paused" }
            return live.dirty ? "Live, unsynced" : "Live"
        }
        let name = String(decoding: path.nameBytes, as: UTF8.self)
        if operations.contains(where: { $0.state == .active && $0.title.hasSuffix(name) }) {
            return "Transferring"
        }
        return ""
    }

    public func toggleHidden() {
        snapshot.showsHidden.toggle()
        UserDefaults.standard.set(snapshot.showsHidden, forKey: "transfer.showsHidden")
        items = visible(columns[snapshot.path] ?? [])
    }

    public func setViewMode(_ mode: ViewMode) {
        snapshot.viewMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "transfer.viewMode")
        if mode == .columns { columnRoot = snapshot.path }
    }

    // MARK: Open

    public func open(_ item: RemoteItem) async {
        guard let session else { return }
        var target = item
        if item.kind == .symlink {
            do {
                let link = try await session.readlink(item.path)
                let resolved = link.hasPrefix("/") ? RemotePath(string: link) : (item.path.parent ?? RemotePath(string: "/")).appending(name: Array(link.utf8))
                target = try await session.stat(resolved)
                if target.kind == .symlink {
                    status = "\(item.name) points at another link"
                    return
                }
            } catch {
                status = error.localizedDescription
                return
            }
        }
        if target.kind == .directory {
            await navigate(target.path)
            return
        }
        guard target.kind == .file else { return }
        do {
            let url: URL
            if await session.openKind(fileName: target.name) == .live {
                url = try await session.prepareLiveFile(target.path)
            } else {
                url = try await session.prepareViewFile(target.path)
            }
            NSWorkspace.shared.open(url)
            await reloadSidebars()
        } catch TransferError.cancelled {
        } catch {
            status = error.localizedDescription
        }
    }

    public func openSelection() async {
        guard let item = primaryItem else { return }
        await open(item)
    }

    public func openLiveSelection() async {
        guard let session, let item = primaryItem, item.kind == .file else { return }
        do {
            let url = try await session.prepareLiveFile(item.path)
            NSWorkspace.shared.open(url)
            await reloadSidebars()
        } catch TransferError.cancelled {
        } catch {
            status = error.localizedDescription
        }
    }

    // MARK: Preview

    public func togglePreview() {
        if PreviewPanel.shared.isVisible {
            PreviewPanel.shared.close()
            previewTask?.cancel()
            return
        }
        showPreview()
    }

    public func showPreview() {
        guard let session, let item = primaryItem else { return }
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            do {
                var path = item.path
                if item.kind == .symlink {
                    let link = try await session.readlink(item.path)
                    path = link.hasPrefix("/") ? RemotePath(string: link) : (item.path.parent ?? RemotePath(string: "/")).appending(name: Array(link.utf8))
                }
                let url = try await session.preparePreview(path)
                if Task.isCancelled { return }
                PreviewPanel.shared.show(url)
            } catch TransferError.cancelled {
            } catch is CancellationError {
            } catch {
                self?.status = error.localizedDescription
            }
        }
    }

    public func selectionChanged() {
        if PreviewPanel.shared.isVisible {
            if primaryItem != nil { showPreview() } else { PreviewPanel.shared.close() }
        }
        inspectorLinkTarget = nil
        if let item = primaryItem, item.kind == .symlink, let session {
            Task { [weak self] in
                let target = try? await session.readlink(item.path)
                self?.inspectorLinkTarget = target
            }
        }
    }

    public func focusFilter() {
        filterFocusTick += 1
    }

    // MARK: Transfers

    public func downloadSelection(to directory: URL) async {
        for item in selectedItems {
            let destination = directory.appendingPathComponent(item.name)
            let path = item.path
            enqueue(title: "Download \(item.name)") { [weak self] progress in
                guard let session = await self?.session else { throw TransferError.notConnected }
                try await session.download(path, to: destination, progress: progress)
            }
        }
    }

    public func downloadCopy() async {
        guard !selectedItems.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        await downloadSelection(to: directory)
    }

    public func upload(urls: [URL], into folder: RemotePath? = nil) async {
        let target = folder ?? snapshot.path
        for url in urls {
            let destination = target.appending(name: Array(url.lastPathComponent.utf8))
            enqueue(title: "Upload \(url.lastPathComponent)") { [weak self] progress in
                guard let session = await self?.session else { throw TransferError.notConnected }
                try await session.upload(url, to: destination, progress: progress)
            }
        }
    }

    public func uploadFromPanel() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        guard panel.runModal() == .OK else { return }
        await upload(urls: panel.urls)
    }

    func perform(_ action: DropAction) async {
        switch action {
        case .uploadFiles(let urls, let folder):
            await upload(urls: urls, into: folder)
        case .moveRemote(let paths, let folder):
            await move(paths, into: folder)
        }
    }

    /// One SFTP rename per item. Never copy-then-delete.
    public func move(_ paths: [RemotePath], into folder: RemotePath) async {
        guard let session else { return }
        for path in paths {
            do {
                try await session.rename(path, to: folder.appending(name: path.nameBytes))
            } catch {
                status = "Could not move \(String(decoding: path.nameBytes, as: UTF8.self)): \(error.localizedDescription)"
            }
        }
        columns[folder] = nil
        await refresh()
    }

    private func enqueue(title: String, body: @escaping @Sendable (@escaping @Sendable (TransferProgress) -> Void) async throws -> Void) {
        let id = UUID().uuidString
        operations.append(TransferOperation(id: id, title: title, state: .queued))
        runners[id] = Runner(body: body, task: nil)
        showsShelf = true
        start(id)
    }

    private func start(_ id: String) {
        guard let runner = runners[id] else { return }
        runner.task?.cancel()
        update(id) { $0.state = .active; $0.message = nil }
        let body = runner.body
        let prompts = prompts
        let reporter = ProgressReporter { [weak self] progress in self?.update(id) { $0.progress = progress } }
        let task = Task { [weak self] in
            var attempt = 0
            while true {
                do {
                    if let session = self?.session, !(await session.isConnected) {
                        _ = try await session.connect(prompts: prompts)
                    }
                    try await body { progress in reporter.report(progress) }
                    self?.finish(id, state: .succeeded, message: nil)
                    return
                } catch {
                    if error is CancellationError || (error as? TransferError) == .cancelled {
                        return
                    }
                    if RetryPolicy.isRetryable(error), let delay = RetryPolicy.delay(afterAttempt: attempt) {
                        attempt += 1
                        self?.update(id) { $0.state = .queued; $0.message = "Retrying in \(Int(delay)) s" }
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        if Task.isCancelled { return }
                        self?.update(id) { $0.state = .active; $0.message = nil }
                        continue
                    }
                    self?.finish(id, state: .failed, message: error.localizedDescription)
                    return
                }
            }
        }
        runners[id]?.task = task
    }

    private func update(_ id: String, _ change: (inout TransferOperation) -> Void) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        change(&operations[index])
    }

    private func finish(_ id: String, state: OperationState, message: String?) {
        update(id) { $0.state = state; $0.message = message }
        if state == .succeeded {
            operations.removeAll { $0.id == id }
            runners[id] = nil
        } else if let message {
            status = message
        }
        if operations.isEmpty { showsShelf = false }
        Task { await refresh() }
    }

    public func pause(_ operation: TransferOperation) async {
        if let path = operation.livePath {
            await session?.setLivePaused(path, paused: true)
            return
        }
        update(operation.id) { $0.state = .paused; $0.message = nil }
        runners[operation.id]?.task?.cancel()
    }

    public func resume(_ operation: TransferOperation) async {
        if let path = operation.livePath {
            await session?.setLivePaused(path, paused: false)
            return
        }
        start(operation.id)
    }

    public func remove(_ operation: TransferOperation) {
        runners[operation.id]?.task?.cancel()
        runners[operation.id] = nil
        operations.removeAll { $0.id == operation.id }
        if operations.isEmpty { showsShelf = false }
    }

    // MARK: Edits

    public func mkdir() async {
        guard let session else { return }
        let existing = Set(items.map(\.name))
        var name = "untitled folder"
        var n = 2
        while existing.contains(name) {
            name = "untitled folder \(n)"
            n += 1
        }
        do {
            let path = snapshot.path.appending(name: Array(name.utf8))
            try await session.mkdir(path)
            await refresh()
            snapshot.selection = [path]
        } catch {
            status = error.localizedDescription
        }
    }

    public var unsyncedInSelection: Int {
        liveFiles.filter { live in live.dirty && snapshot.selection.contains { live.path.isInside($0) } }.count
    }

    public func askToDelete() {
        guard !snapshot.selection.isEmpty else { return }
        sheet = .delete
    }

    public func deleteSelection() async {
        guard let session else { return }
        for path in snapshot.selection {
            do { try await session.remove(path) } catch { status = error.localizedDescription }
        }
        snapshot.selection = []
        await refresh()
        await reloadSidebars()
    }

    public func beginRename() {
        guard let item = primaryItem else { return }
        renameText = item.name
        renaming = true
    }

    public func renameSelection(to name: String) async {
        renaming = false
        guard let session, let item = primaryItem, let parent = item.path.parent, name != item.name, !name.isEmpty else { return }
        do {
            let destination = parent.appending(name: Array(name.utf8))
            try await session.rename(item.path, to: destination)
            await refresh()
            snapshot.selection = [destination]
        } catch {
            status = error.localizedDescription
        }
    }

    public func duplicateSelection() async {
        guard let session else { return }
        for item in selectedItems where item.kind == .file {
            do { try await session.duplicate(item.path) } catch { status = error.localizedDescription }
        }
        await refresh()
    }

    public func pinCurrent() async {
        await session?.pin(snapshot.path)
        await reloadSidebars()
    }

    public func unpin(_ path: RemotePath) async {
        await session?.unpin(path)
        await reloadSidebars()
    }

    public func discardLive(_ path: RemotePath, force: Bool = false) async {
        guard let session else { return }
        do {
            try await session.discardLiveFile(path, force: force)
            conflicts.removeAll { $0 == path }
            await reloadSidebars()
        } catch TransferError.liveUnsynced {
            sheet = .discardLive(path)
        } catch {
            status = error.localizedDescription
        }
    }

    public func discardSelectedLive() async {
        for item in selectedItems where liveFiles.contains(where: { $0.path == item.path }) {
            await discardLive(item.path)
        }
    }

    public func liveFile(for path: RemotePath) -> LiveFile? {
        liveFiles.first { $0.path == path }
    }

    public func clearPreviewCache() async {
        await session?.clearPreviewCache()
    }

    public func copyRemoteURL() {
        guard let connection = currentConnection else { return }
        let paths = snapshot.selection.isEmpty ? [snapshot.path] : Array(snapshot.selection)
        let text = paths.map { SftpURL.string(connection: connection, path: $0) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Conflicts

    public func chooseConflict(_ choice: LiveConflictChoice) async {
        switch choice {
        case .keepLocal, .keepRemote:
            if conflictConfirm == choice {
                await resolveConflict(choice)
            } else {
                conflictConfirm = choice
            }
        case .compare, .keepBoth:
            await resolveConflict(choice)
        }
    }

    private func resolveConflict(_ choice: LiveConflictChoice) async {
        guard let path = conflictPath, let session else { return }
        conflictConfirm = nil
        if choice != .compare { sheet = nil }
        do {
            try await session.resolveLive(path, choice: choice)
            if choice != .compare {
                conflicts.removeAll { $0 == path }
                await refresh()
            }
        } catch {
            status = error.localizedDescription
        }
    }

    // MARK: Sidebar

    public func sidebarSelected(_ item: SidebarItem?) async {
        guard let item else { return }
        switch item {
        case .server(let id):
            guard let connection = connections.first(where: { $0.id == id }) else { return }
            if snapshot.connectionID != id { await connect(connection) }
        case .recent(let path), .pin(let path):
            await navigate(path)
        case .live(let path):
            await reveal(path)
        case .conflict(let path):
            conflictPath = path
            sheet = .conflict
        }
    }

    public func reveal(_ path: RemotePath) async {
        guard let parent = path.parent else { return }
        if parent != snapshot.path { await navigate(parent) }
        snapshot.selection = [path]
    }

    public func requestQuit() async {
        let unsynced = await provider.unsyncedLiveCount
        if unsynced > 0 {
            sheet = .quit(unsynced)
        } else {
            NSApp.terminate(nil)
        }
    }

    public func openTerminal() async {
        guard let session, let command = await session.terminalCommand(directory: snapshot.path) else { return }
        TerminalLauncher.open(command: command)
    }

    private func reloadSidebars() async {
        guard let session else { return }
        recents = await session.recents()
        pins = await session.pins()
        liveFiles = await session.liveFiles()
        conflicts = liveFiles.filter(\.conflict).map(\.path)
    }

    private func listen(to session: any RemoteSession) {
        listener?.cancel()
        listener = Task { [weak self] in
            for await event in session.events() {
                guard let self else { return }
                switch event {
                case .notice(let text):
                    status = text
                case .conflict(let path, let comparable):
                    conflictPath = path
                    conflictComparable = comparable
                    conflictConfirm = nil
                    if !conflicts.contains(path) { conflicts.append(path) }
                    if sheet == nil { sheet = .conflict }
                case .liveChanged:
                    await reloadSidebars()
                case .directoryChanged(let path):
                    columns[path] = nil
                    if path == snapshot.path { await refresh() }
                case .disconnected(let text):
                    status = text
                case .operation(let operation):
                    if operation.state == .succeeded {
                        operations.removeAll { $0.id == operation.id }
                    } else if let index = operations.firstIndex(where: { $0.id == operation.id }) {
                        operations[index] = operation
                    } else {
                        operations.append(operation)
                    }
                    showsShelf = showsShelf || !operations.isEmpty
                    if operations.isEmpty { showsShelf = false }
                }
            }
        }
    }
}

/// Forwards transfer progress to the main actor.
private final class ProgressReporter: Sendable {
    private let apply: @MainActor (TransferProgress) -> Void

    init(_ apply: @escaping @MainActor (TransferProgress) -> Void) {
        self.apply = apply
    }

    func report(_ progress: TransferProgress) {
        Task { @MainActor in self.apply(progress) }
    }
}

public extension RemoteItem {
    var sortMtime: UInt32 { mtime ?? 0 }
    var sortSize: UInt64 { size ?? 0 }
    var kindLabel: String {
        switch kind {
        case .directory: "Folder"
        case .symlink: "Alias"
        case .other: "Special"
        case .file:
            UTType(filenameExtension: (name as NSString).pathExtension)?.localizedDescription ?? "Document"
        }
    }
    var statusLabel: String { "" }
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
    case removeServer(SavedConnection)
    case discardLive(RemotePath)

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
        case .removeServer: "remove"
        case .discardLive: "discard"
        }
    }
}

public final class SheetPrompts: PromptSink, @unchecked Sendable {
    weak var model: TransferModel?

    public func answer(_ request: PromptRequest) async -> PromptReply {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                guard let model = self.model else {
                    continuation.resume(returning: PromptReply(text: nil))
                    return
                }
                model.pendingPrompt = continuation
                model.sheet = .prompt(request)
            }
        }
    }

    public func resolveCollision(fileName: String) async -> NameCollisionChoice {
        if let remembered = await MainActor.run(body: { model?.applyToAll }) {
            return remembered
        }
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                guard let model = self.model else {
                    continuation.resume(returning: .skip)
                    return
                }
                model.pendingCollision = continuation
                model.sheet = .collision(fileName)
            }
        }
    }

    public func decideHostKey(_ event: HostKeyEvent) async -> HostKeyDecision {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                guard let model = self.model else {
                    continuation.resume(returning: .cancel)
                    return
                }
                model.pendingHost = continuation
                model.sheet = .hostKey(event)
            }
        }
    }
}

extension TransferModel {
    func finishPrompt(_ reply: PromptReply) {
        pendingPrompt?.resume(returning: reply)
        pendingPrompt = nil
        promptSecure = ""
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

enum TerminalLauncher {
    private static let apps: [(name: String, bundle: String)] = [
        ("Terminal", "com.apple.Terminal"),
        ("iTerm2", "com.googlecode.iterm2"),
        ("Ghostty", "com.mitchellh.ghostty"),
    ]

    @MainActor
    static func anyInstalled() -> Bool {
        apps.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundle) != nil }
    }

    /// A running Terminal, iTerm2, or Ghostty, otherwise the first installed one.
    @MainActor
    static func open(command: String) {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let choice = apps.first { running.contains($0.bundle) }
            ?? apps.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundle) != nil }
        guard let choice, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: choice.bundle) else { return }
        switch choice.name {
        case "Terminal":
            let script = "tell application \"Terminal\"\nactivate\ndo script \(appleScriptString(command))\nend tell"
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        case "iTerm2":
            let script = "tell application \"iTerm\"\nactivate\ncreate window with default profile command \(appleScriptString(command))\nend tell"
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        default:
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["-e", command]
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

final class PreviewPanel: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate, @unchecked Sendable {
    static let shared = PreviewPanel()
    private let lock = NSLock()
    private var url: URL?

    @MainActor
    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    @MainActor
    func show(_ url: URL) {
        lock.lock()
        self.url = url
        lock.unlock()
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor
    func close() {
        guard isVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        lock.lock()
        defer { lock.unlock() }
        return (url ?? URL(fileURLWithPath: "/")) as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        false
    }
}
