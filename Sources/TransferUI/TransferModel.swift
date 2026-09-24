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

    /// On unless the user turned it off; a missing default reads as true.
    public static func foldersFirstValue(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: foldersFirst) == nil ? true : defaults.bool(forKey: foldersFirst)
    }
    public static let showsHidden = "transfer.showsHidden"
    public static let viewMode = "transfer.viewMode"
    /// Off unless turned on: the inspector's source preview wraps long lines.
    public static let wrapsPreview = "transfer.wrapsPreview"
}

public enum SidebarItem: Hashable {
    case server(ConnectionID)
    case star(RemotePath)
    case live(RemotePath)
    case conflict(RemotePath)
}

/// The server a window shows, as one value: made when a connect starts, installed only once the
/// login has worked, and never changed after that. Switching servers installs a new one and
/// closes the old, which cancels its event listener and listings. Work that belongs to a server
/// holds its context, and a result counts only while that context is still the installed one,
/// so a slow listing or a late login never lands in a window that has moved on.
@MainActor
final class ServerContext {
    let connection: SavedConnection
    let session: any RemoteSession
    /// Which connect made it, so a notice raised during that login can be shown before it lands.
    let generation: Int
    var listener: Task<Void, Never>?
    /// The listing running for each folder, at most one per folder.
    var jobs: [RemotePath: ListingJob] = [:]

    init(connection: SavedConnection, session: any RemoteSession, generation: Int) {
        self.connection = connection
        self.session = session
        self.generation = generation
    }

    func close() {
        listener?.cancel()
        for job in jobs.values { job.task?.cancel() }
        jobs.removeAll()
    }

    /// Stops the listings of folders the window no longer shows.
    func cancelListings(keeping kept: (RemotePath) -> Bool) {
        for (path, job) in jobs where !kept(path) {
            job.task?.cancel()
            jobs[path] = nil
        }
    }
}

/// One folder's listing in flight. A change that arrives while it runs asks for one more pass
/// instead of starting a second listing of the same folder.
@MainActor
final class ListingJob {
    var task: Task<Void, Never>?
    var again = false
}

/// One folder as the window has it: all its items in the list view's order, and the column
/// view's name order with hidden files already left out when they are hidden. Both are kept
/// sorted, so reading a column costs nothing. `complete` is false for a listing that stopped
/// part way, which is shown only until a fresh one replaces it.
struct FolderListing {
    var items: [RemoteItem]
    var byName: [RemoteItem]
    var columnItems: [RemoteItem]
    var complete: Bool
}

/// One window's state. Windows and tabs share sessions through the provider.
@MainActor
@Observable
public final class TransferModel {
    public let provider: any SessionProvider
    private var context: ServerContext?
    /// The server this window shows; nil before the first login and while none is chosen.
    public var session: (any RemoteSession)? { context?.session }
    /// The server a connect is logging in to, until it lands or fails.
    public private(set) var connectingTo: SavedConnection?
    @ObservationIgnored private var connectGeneration = 0
    /// Starts from the list the last window loaded, so a new window or tab shows its servers in
    /// its first frame instead of an empty sidebar that fills in a moment later.
    public var connections: [SavedConnection] = TransferModel.lastConnections
    private static var lastConnections: [SavedConnection] = []
    public var snapshot = BrowserSnapshot()
    /// The location's items in list order, hidden ones left out unless shown.
    public private(set) var items: [RemoteItem] = []
    /// `items` narrowed by the toolbar filter: what the icon and list views draw.
    public private(set) var displayedItems: [RemoteItem] = []
    /// Each displayed item's row, built when a selection first needs it.
    @ObservationIgnored private var displayedIndexCache: [RemotePath: Int]?
    private var displayedIndex: [RemotePath: Int] {
        if let displayedIndexCache { return displayedIndexCache }
        let index = Dictionary(displayedItems.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first })
        displayedIndexCache = index
        return index
    }
    /// The location's column narrowed by the filter; nil while no filter is typed.
    private var filteredColumn: [RemoteItem]?
    private var listings: [RemotePath: FolderListing] = [:]
    /// When each cached listing was last shown, for keeping only the recent ones.
    @ObservationIgnored private var listingUse: [RemotePath: Int] = [:]
    @ObservationIgnored private var useClock = 0
    private static let cachedListingLimit = 64
    private static let historyLimit = 100
    public var columnRoot: RemotePath?
    public var operations: [TransferOperation] = []
    public var stars: [RemotePath] = []
    /// Whether each starred path is a folder, from the server, so a starred file is never listed.
    private var starIsFolder: [RemotePath: Bool] = [:]
    public var liveFiles: [LiveFile] = [] {
        didSet { liveByPath = Dictionary(liveFiles.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    @ObservationIgnored private var liveByPath: [RemotePath: LiveFile] = [:]
    public var conflicts: [RemotePath] = []
    public var conflictComparable = false
    public var conflictConfirm: LiveConflictChoice?
    public var filter = "" {
        didSet { if filter != oldValue { refreshItems() } }
    }
    public var filterFocusTick = 0
    /// When an icon cell last took a mouse down, in system uptime, so the grid's background tap
    /// that follows the same click does not clear the selection the cell just made. A time rather
    /// than a flag: a click that becomes a drag is never followed by a tap.
    @ObservationIgnored public var itemClickTime: TimeInterval = 0
    /// True while a text field in the window has focus, so Space and Return stay with the field.
    public var textEditing = false
    public var folderText = ""
    public var status = "Not connected"
    public var showsInspector = false {
        didSet { if showsInspector != oldValue { refreshInspectorPreview() } }
    }
    /// The primary file for the inspector's preview, when it is small enough: its first lines
    /// when it is text, a decoded picture, else a local copy for Quick Look. Stays on the
    /// previous file for a moment after the selection moves, so a fast fetch swaps with no gap.
    public var inspectorPreview: InspectorPreview?
    /// What the pane shows while no preview is up: nothing, the file's icon, or the icon with a
    /// spinner once the wait has grown long.
    public var inspectorWait: InspectorWait = .nothing
    @ObservationIgnored private var inspectorTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var inspectorGeneration = 0
    @ObservationIgnored private var lastSelectionChange = ContinuousClock.now - .seconds(10)
    private static let inspectorPreviewLimit = 8 << 20
    public var sidebarCollapsed = false
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
    var pendingCollision: CheckedContinuation<(choice: NameCollisionChoice, toAll: Bool)?, Never>?

    /// Where a connection made from an `sftp://` link's filled-in sheet lands.
    @ObservationIgnored private var pendingLanding: RemotePath?
    private var backStack: [RemotePath] = []
    private var forwardStack: [RemotePath] = []
    private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var runners: [String: Runner] = [:]
    /// The session behind each Live row on the shelf, which the session's own events put there,
    /// so Pause and Resume reach that server whatever the window shows now.
    @ObservationIgnored private var liveRowSessions: [String: any RemoteSession] = [:]
    @ObservationIgnored private var sidebarReload: Task<Void, Never>?
    @ObservationIgnored private var sidebarReloadAgain = false

    /// One queued transfer. It keeps the server it was queued for: a retry, a Resume, or a
    /// Retry after a failure runs there even when the window has moved to another server.
    private struct Runner {
        var body: @Sendable (@escaping @Sendable (TransferProgress) -> Void) async throws -> Void
        /// This operation's own prompts, kept across retries and Resume.
        var prompts: OperationPrompt
        let connection: SavedConnection
        let session: any RemoteSession
        var task: Task<Void, Never>?
    }

    public init(provider: any SessionProvider) {
        self.provider = provider
        let prompts = SheetPrompts()
        self.prompts = prompts
        prompts.model = self
        applyPreferences()
        Task { await reloadConnections() }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.applyPreferences() }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var defaultsObserver: (any NSObjectProtocol)?

    /// A closed window stops listening and listing. Its queued transfers run on without it.
    isolated deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        context?.close()
        sidebarReload?.cancel()
    }

    /// Reads the global preferences at launch and whenever Settings changes them.
    private func applyPreferences() {
        let defaults = UserDefaults.standard
        var changed = false
        let hidden = defaults.bool(forKey: Preferences.showsHidden)
        if hidden != snapshot.showsHidden {
            snapshot.showsHidden = hidden
            refilterListings()
            changed = true
        }
        let folded = defaults.bool(forKey: Preferences.caseInsensitiveSort)
        let foldersFirst = Preferences.foldersFirstValue(defaults)
        if folded != snapshot.sort.caseInsensitive || foldersFirst != snapshot.sort.foldersFirst {
            snapshot.sort.caseInsensitive = folded
            snapshot.sort.foldersFirst = foldersFirst
            resortListings(names: true)
            changed = true
        }
        if let stored = defaults.string(forKey: Preferences.viewMode), let mode = ViewMode(rawValue: stored), mode != snapshot.viewMode {
            snapshot.viewMode = mode
            if mode == .columns { columnRoot = snapshot.path }
        }
        if changed { refreshItems() }
    }

    /// Puts every cached listing in the current order: the list order always, and the column
    /// view's name order too when `names`, since only case and folders-first change that.
    private func resortListings(names: Bool) {
        let byName = Self.nameOrder(snapshot.sort)
        for (path, listing) in listings {
            var sorted = listing
            sorted.items = ListingSort.apply(listing.items, sort: snapshot.sort)
            if names { sorted.byName = ListingSort.apply(listing.byName, sort: byName) }
            sorted.columnItems = visible(sorted.byName)
            listings[path] = sorted
        }
    }

    /// Hidden files were shown or hidden: the columns follow.
    private func refilterListings() {
        for (path, listing) in listings { listings[path]?.columnItems = visible(listing.byName) }
    }

    /// The column view is always in name order, like Finder's, while honoring the case and
    /// folders-first settings. The list view's column choice applies to the other views.
    private static func nameOrder(_ sort: SortConfiguration) -> SortConfiguration {
        var byName = sort
        byName.column = "name"
        byName.ascending = true
        return byName
    }

    /// `sorted` with `page` merged in. Only the page is sorted; the standard library's sort finds
    /// the two sorted runs and merges them in linear time, so a listing that streams in pages
    /// never sorts what it already has. A Core merge helper is on its way; this is the stopgap.
    private static func merged(_ sorted: [RemoteItem], _ page: [RemoteItem], sort: SortConfiguration) -> [RemoteItem] {
        let page = ListingSort.apply(page, sort: sort)
        return sorted.isEmpty ? page : ListingSort.apply(sorted + page, sort: sort)
    }

    /// Derives what the views draw from the location's listing, the filter, and hidden files.
    private func refreshItems() {
        let listing = listings[snapshot.path]
        let shown = visible(listing?.items ?? [])
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let displayed = query.isEmpty ? shown : shown.filter { $0.name.lowercased().contains(query) }
        let column = query.isEmpty ? nil : listing?.columnItems.filter { $0.name.lowercased().contains(query) }
        if items != shown { items = shown }
        if displayedItems != displayed {
            displayedItems = displayed
            displayedIndexCache = nil
        }
        if filteredColumn != column { filteredColumn = column }
    }

    // MARK: Servers

    public func reloadConnections() async {
        let loaded = (try? await provider.savedConnections()) ?? []
        Self.lastConnections = loaded
        if connections != loaded { connections = loaded }
    }

    public var currentConnection: SavedConnection? {
        connections.first { $0.id == snapshot.connectionID }
    }

    /// Logs in and shows the start folder, or `landing` when given: that folder, or the file
    /// selected in its folder. Nothing in the window changes until the login has worked, so a
    /// failed or cancelled login leaves the window on the server it showed; when connects
    /// overlap, the last one asked for wins, whichever finishes first.
    public func connect(_ connection: SavedConnection, landing: RemotePath? = nil) async {
        connectGeneration &+= 1
        let generation = connectGeneration
        connectingTo = connection
        status = "Connecting to \(connection.displayName)…"
        var pending: ServerContext?
        defer {
            if let pending, pending !== context { pending.close() }
            if generation == connectGeneration { connectingTo = nil }
        }
        do {
            let session = try await provider.session(for: connection.id)
            guard generation == connectGeneration else { return }
            let fresh = ServerContext(connection: connection, session: session, generation: generation)
            pending = fresh
            // Listening before the login catches the notices the login itself raises.
            listen(fresh)
            let start = try await session.connect(prompts: prompts)
            var path = start
            var selection: Set<RemotePath> = []
            var missing: RemotePath?
            if let landing {
                if let found = await Self.landing(landing, session: session) {
                    (path, selection) = found
                } else {
                    missing = landing
                }
            }
            guard generation == connectGeneration else { return }
            install(fresh, path: path, selection: selection)
            status = connection.displayName
            await refresh()
            scheduleSidebarReload()
            if let missing { status = "No such file or folder: \(missing.display)" }
        } catch {
            guard generation == connectGeneration else { return }
            status = error.localizedDescription
        }
    }

    /// Makes `fresh` the window's server in one step: its session, listener, location, and
    /// empty caches. The old server's listener and listings stop; its queued transfers go on.
    private func install(_ fresh: ServerContext, path: RemotePath, selection: Set<RemotePath>) {
        let old = context
        context = fresh
        old?.close()
        snapshot.connectionID = fresh.connection.id
        snapshot.path = path
        snapshot.selection = selection
        columnRoot = path
        backStack.removeAll()
        forwardStack.removeAll()
        listings.removeAll()
        listingUse.removeAll()
        starIsFolder.removeAll()
        stars = []
        liveFiles = []
        dropLiveRows(keeping: fresh.connection.id)
        loadPreferences(for: fresh.connection.id)
        refreshItems()
    }

    /// Leaves the window showing no server.
    private func uninstall() {
        context?.close()
        context = nil
        snapshot.connectionID = nil
        snapshot.selection = []
        listings.removeAll()
        listingUse.removeAll()
        starIsFolder.removeAll()
        stars = []
        liveFiles = []
        dropLiveRows(keeping: nil)
        refreshItems()
        status = "Not connected"
    }

    /// Live rows arrive from the shown server's events; once the window leaves that server
    /// nothing would update or remove them.
    private func dropLiveRows(keeping id: ConnectionID?) {
        let gone = operations.filter { $0.livePath != nil && liveRowSessions[$0.id]?.connection.id != id }.map(\.id)
        guard !gone.isEmpty else { return }
        operations.removeAll { gone.contains($0.id) }
        for id in gone { liveRowSessions[id] = nil }
        if operations.isEmpty { showsShelf = false }
    }

    /// True while `context` is still the window's server.
    private func isCurrent(_ context: ServerContext) -> Bool {
        context === self.context
    }

    /// Where a link to `path` lands: the folder itself, or a file's folder with the file selected.
    /// A link to a link follows one hop. Nil when there is nothing at `path`.
    private static func landing(_ path: RemotePath, session: any RemoteSession) async -> (RemotePath, Set<RemotePath>)? {
        guard let item = try? await session.stat(path), let target = try? await resolveLink(item, session: session) else { return nil }
        if target.kind == .directory { return (path, []) }
        guard let parent = path.parent else { return nil }
        return (parent, [path])
    }

    /// True while this window shows no server and asks nothing, so a link can open here rather
    /// than in a new tab.
    public var isIdle: Bool { snapshot.connectionID == nil && sheet == nil && connectingTo == nil }

    /// Opens an `sftp://` link here: the saved server it names, at its folder or with its file
    /// selected. A server not in the library opens the New Connection sheet, filled in from the
    /// link; nothing is saved until Connect.
    public func open(link: SFTPURL) async {
        if let connection = await provider.connection(matching: link) {
            await connect(connection, landing: link.path)
            return
        }
        draft = SavedConnection(name: "", host: link.host, user: link.user ?? "", port: link.port ?? "")
        draftIsEdit = false
        pendingLanding = link.path
        sheet = .connection
    }

    public func newConnection() {
        pendingLanding = nil
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
            let landing = pendingLanding
            pendingLanding = nil
            if !wasEdit { await connect(connection, landing: landing) }
        } catch {
            status = error.localizedDescription
        }
    }

    public func askToRemove(_ connection: SavedConnection) {
        sheet = .removeServer(connection)
    }

    /// The library refuses while the server has unsynced Live edits, and only a removal that
    /// worked logs out, so a refusal leaves every window on that server as it was.
    public func removeServer(_ connection: SavedConnection) async {
        sheet = nil
        do {
            try await provider.removeConnection(connection.id)
            UserDefaults.standard.removeObject(forKey: Self.sortKey(connection.id))
            if snapshot.connectionID == connection.id { uninstall() }
            await reloadConnections()
        } catch {
            status = error.localizedDescription
        }
    }

    // MARK: Listing

    /// Lists the location again and returns once that listing is done.
    public func refresh() async {
        await relist(snapshot.path)?.value
    }

    /// Lists `path`, or asks the listing already running for it to go once more, so a burst of
    /// changes costs one or two listings rather than one each.
    @discardableResult
    private func relist(_ path: RemotePath) -> Task<Void, Never>? {
        guard let context else { return nil }
        if let job = context.jobs[path] {
            job.again = true
            return job.task
        }
        let job = ListingJob()
        context.jobs[path] = job
        job.task = Task { [weak self] in
            repeat {
                job.again = false
                guard let self, await stream(path, in: context) else { break }
            } while job.again
            if context.jobs[path] === job { context.jobs[path] = nil }
        }
        return job.task
    }

    /// Streams one listing of `path` into the cache. A complete cached listing stays on screen
    /// until the new one is complete; without one, the pages that have come are shown every
    /// 80 ms. True when the whole listing arrived. A cancelled listing publishes nothing more,
    /// and neither does one for a server the window has left.
    private func stream(_ path: RemotePath, in context: ServerContext) async -> Bool {
        let flushEarly = listings[path]?.complete != true
        var sort = snapshot.sort
        var listOrder: [RemoteItem] = []
        var nameOrder: [RemoteItem] = []
        var page: [RemoteItem] = []
        var lastFlush = ContinuousClock.now
        func flush(complete: Bool) {
            if sort != snapshot.sort {
                if Self.nameOrder(sort) != Self.nameOrder(snapshot.sort) {
                    nameOrder = ListingSort.apply(nameOrder, sort: Self.nameOrder(snapshot.sort))
                }
                sort = snapshot.sort
                listOrder = ListingSort.apply(listOrder, sort: sort)
            }
            let byName = Self.nameOrder(sort)
            listOrder = Self.merged(listOrder, page, sort: sort)
            // A list already in name order, as by default, serves the columns too.
            nameOrder = byName == sort ? listOrder : Self.merged(nameOrder, page, sort: byName)
            page.removeAll()
            publish(FolderListing(items: listOrder, byName: nameOrder, columnItems: visible(nameOrder), complete: complete), for: path)
        }
        do {
            for try await item in context.session.list(path) {
                page.append(item)
                if flushEarly, lastFlush.duration(to: .now) > .milliseconds(80) {
                    guard !Task.isCancelled, isCurrent(context) else { return false }
                    flush(complete: false)
                    lastFlush = .now
                }
            }
            // A cancelled consumer ends the loop normally rather than by throwing.
            guard !Task.isCancelled, isCurrent(context) else { return false }
            flush(complete: true)
            // A listing that worked ends any earlier error in the title.
            if let name = currentConnection?.displayName { status = name }
            return true
        } catch {
            guard !Task.isCancelled, isCurrent(context) else { return false }
            // What arrived is shown, marked incomplete, so the column stops asking for it and the
            // next visit lists it again.
            flush(complete: false)
            if case .noSuchFile? = error as? TransferError {
                // The server's text is just "No such file"; name the folder instead.
                status = "No such folder: \(path.display)"
            } else {
                status = error.localizedDescription
            }
            return false
        }
    }

    private func publish(_ listing: FolderListing, for path: RemotePath) {
        listings[path] = listing
        touch(path)
        trimListings()
        if path == snapshot.path { refreshItems() }
    }

    /// Marks `path` as just shown, for `trimListings`.
    private func touch(_ path: RemotePath) {
        useClock += 1
        listingUse[path] = useClock
    }

    /// Keeps the folders shown most recently, and always the ones on screen.
    private func trimListings() {
        let excess = listings.count - Self.cachedListingLimit
        guard excess > 0 else { return }
        let oldest = listings.keys.filter { !isShown($0) }.sorted { (listingUse[$0] ?? 0) < (listingUse[$1] ?? 0) }
        for path in oldest.prefix(excess) {
            listings[path] = nil
            listingUse[path] = nil
        }
    }

    /// Whether `path`'s listing is on screen: the location, or in column view a folder on the
    /// way down to it.
    private func isShown(_ path: RemotePath) -> Bool {
        if path == snapshot.path { return true }
        guard snapshot.viewMode == .columns, let root = columnRoot else { return false }
        return snapshot.path.isInside(path) && path.isInside(root)
    }

    /// A folder's items in the column view's order, or nil before it has been listed. The
    /// location's column follows the toolbar filter, as Finder's search narrows it.
    public func columnItems(_ path: RemotePath) -> [RemoteItem]? {
        if path == snapshot.path, let filteredColumn { return filteredColumn }
        return listings[path]?.columnItems
    }

    /// Lists a folder the column view shows and has no listing for. Pages show as they arrive.
    public func loadColumn(_ path: RemotePath) {
        guard listings[path] == nil, context?.jobs[path] == nil else { return }
        relist(path)
    }

    public func navigate(_ path: RemotePath) async {
        if path != snapshot.path {
            remember(snapshot.path, in: &backStack)
            forwardStack.removeAll()
        }
        await show(path)
    }

    private func remember(_ path: RemotePath, in stack: inout [RemotePath]) {
        stack.append(path)
        if stack.count > Self.historyLimit { stack.removeFirst() }
    }

    private func show(_ path: RemotePath) async {
        snapshot.path = path
        snapshot.selection = []
        columnRoot = path
        context?.cancelListings(keeping: isShown)
        touch(path)
        refreshItems()
        await refresh()
    }

    public func goBack() async {
        guard let path = backStack.popLast() else { return }
        remember(snapshot.path, in: &forwardStack)
        await show(path)
    }

    public func goForward() async {
        guard let path = forwardStack.popLast() else { return }
        remember(snapshot.path, in: &backStack)
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

    public func visible(_ items: [RemoteItem]) -> [RemoteItem] {
        snapshot.showsHidden ? items : items.filter { !$0.isHidden }
    }

    /// A selected item the location does not list. In column view a selected folder is the
    /// location itself, so it is in its parent's listing.
    private func listedItem(_ path: RemotePath) -> RemoteItem? {
        guard let parent = path.parent else { return nil }
        return listings[parent]?.items.first { $0.path == path }
    }

    public var primaryItem: RemoteItem? {
        let shown = displayedItems
        guard !snapshot.selection.isEmpty else { return nil }
        if let index = snapshot.selection.compactMap({ displayedIndex[$0] }).min() { return shown[index] }
        return snapshot.selection.compactMap(listedItem).min { $0.path.display < $1.path.display }
    }

    /// Menu items whose shortcut is a plain key stay out of the way of text entry.
    public var plainKeysAvailable: Bool { !textEditing && sheet == nil }

    public var selectedItems: [RemoteItem] {
        let shown = displayedItems
        guard !snapshot.selection.isEmpty else { return [] }
        let indexes = snapshot.selection.compactMap { displayedIndex[$0] }
        if indexes.count == snapshot.selection.count { return indexes.sorted().map { shown[$0] } }
        return snapshot.selection.compactMap(listedItem).sorted { $0.path.display < $1.path.display }
    }

    /// A single selected folder becomes the current location, as in Finder, and stays selected.
    /// Files and multiple selections leave the location at their parent. Listings of folders no
    /// longer on screen stop.
    public func selectInColumns(_ selected: [RemoteItem], parent: RemotePath) {
        snapshot.selection = Set(selected.map(\.path))
        if let folder = selected.first, selected.count == 1, folder.kind == .directory {
            snapshot.path = folder.path
            touch(folder.path)
            // Revealing a folder lists it again, as opening one does in the other views.
            relist(folder.path)
        } else {
            snapshot.path = parent
        }
        context?.cancelListings(keeping: isShown)
        refreshItems()
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
            UserDefaults.standard.set(data, forKey: Self.sortKey(id))
        }
        resortListings(names: false)
        refreshItems()
    }

    /// Where a server's list-view column and direction are kept.
    private static func sortKey(_ id: ConnectionID) -> String {
        "transfer.sort.\(id.rawValue.uuidString)"
    }

    private func loadPreferences(for id: ConnectionID) {
        let folded = UserDefaults.standard.bool(forKey: Preferences.caseInsensitiveSort)
        let foldersFirst = Preferences.foldersFirstValue()
        if let data = UserDefaults.standard.data(forKey: Self.sortKey(id)),
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
        if let live = liveByPath[path] {
            if live.conflict { return "Conflict" }
            if live.uploading { return "Uploading" }
            if live.paused { return "Paused" }
            return live.dirty ? "Live, unsynced" : "Live"
        }
        if operations.contains(where: { $0.state == .active && $0.path == path }) {
            return "Transferring"
        }
        return ""
    }

    /// The operation that moves `path`, if one is queued or running.
    public func operation(for path: RemotePath) -> TransferOperation? {
        operations.first { $0.path == path || $0.livePath == path }
    }

    public func toggleHidden() {
        snapshot.showsHidden.toggle()
        UserDefaults.standard.set(snapshot.showsHidden, forKey: Preferences.showsHidden)
        refilterListings()
        refreshItems()
    }

    public func setViewMode(_ mode: ViewMode) {
        snapshot.viewMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Preferences.viewMode)
        if mode == .columns { columnRoot = snapshot.path }
    }

    // MARK: Open

    /// One hop through a symlink. A second hop is an error.
    private static func resolveLink(_ item: RemoteItem, session: any RemoteSession) async throws -> RemoteItem {
        guard item.kind == .symlink else { return item }
        let link = try await session.readlink(item.path)
        let resolved = link.hasPrefix("/") ? RemotePath(string: link) : (item.path.parent ?? RemotePath(string: "/")).appending(name: Array(link.utf8))
        let target = try await session.stat(resolved)
        if target.kind == .symlink { throw TransferError.failed("\(item.name) points at another link") }
        return target
    }

    /// Follows the double-click rule, or forces Live when asked. Folders navigate.
    public func open(_ item: RemoteItem, forceLive: Bool = false) async {
        guard let session else { return }
        do {
            let target = try await Self.resolveLink(item, session: session)
            if target.kind == .directory {
                await navigate(target.path)
                return
            }
            guard target.kind == .file else { return }
            let rule = await session.openKind(fileName: target.name)
            let live = forceLive || rule == .live
            let url: URL
            if live {
                url = try await session.prepareLiveFile(target.path)
            } else {
                url = try await session.prepareViewFile(target.path)
            }
            await FileOpener.open(url)
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
        guard let item = primaryItem, item.kind == .file else { return }
        await open(item, forceLive: true)
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
                let target = try await Self.resolveLink(item, session: session)
                let url = try await session.preparePreview(target.path)
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
        refreshInspectorPreview()
        inspectorLinkTarget = nil
        if let item = primaryItem, item.kind == .symlink, let session {
            Task { [weak self] in
                let target = try? await session.readlink(item.path)
                self?.inspectorLinkTarget = target
            }
        }
    }

    /// Starts fetching the primary file the instant the selection moves; nothing waits on an
    /// animation. The old preview stays up for `hold` so a quick fetch swaps with no gap, then
    /// the pane clears, the icon arrives once the wait is plainly long, and a spinner joins it
    /// later still. A held arrow key coalesces: only a change that follows another within
    /// `coalesce` waits.
    private func refreshInspectorPreview() {
        for task in inspectorTasks { task.cancel() }
        inspectorTasks.removeAll()
        inspectorGeneration &+= 1
        let generation = inspectorGeneration
        let now = ContinuousClock.now
        let rapid = lastSelectionChange.duration(to: now) < PreviewTiming.coalesce
        lastSelectionChange = now
        inspectorWait = .nothing
        guard showsInspector, let session, let item = primaryItem else {
            inspectorPreview = nil
            return
        }
        guard item.kind != .directory else {
            inspectorPreview = nil
            inspectorWait = .icon
            return
        }
        inspectorTasks = [
            Task { [weak self] in
                try? await Task.sleep(for: PreviewTiming.hold)
                guard let self, !Task.isCancelled, generation == inspectorGeneration else { return }
                inspectorPreview = nil
            },
            Task { [weak self] in
                try? await Task.sleep(for: PreviewTiming.icon)
                guard let self, !Task.isCancelled, generation == inspectorGeneration else { return }
                inspectorWait = .icon
            },
            Task { [weak self] in
                try? await Task.sleep(for: PreviewTiming.spinner)
                guard let self, !Task.isCancelled, generation == inspectorGeneration else { return }
                inspectorWait = .spinner
            },
            Task { [weak self] in
                if rapid { try? await Task.sleep(for: PreviewTiming.coalesce) }
                guard !Task.isCancelled else { return }
                let preview = await Self.fetchPreview(item, session: session)
                guard let self, !Task.isCancelled, generation == inspectorGeneration else { return }
                for task in inspectorTasks { task.cancel() }
                inspectorPreview = preview
                inspectorWait = preview == nil ? .icon : .nothing
                if preview != nil { prefetchNeighbors(of: item, session: session, generation: generation) }
            },
        ]
    }

    /// The preview for one file, ready to draw: text, a decoded picture, or a local copy for
    /// Quick Look. Nil when it is not a small file after all.
    private static func fetchPreview(_ item: RemoteItem, session: any RemoteSession) async -> InspectorPreview? {
        do {
            let target = try await Self.resolveLink(item, session: session)
            guard target.kind == .file, (target.size ?? 0) <= inspectorPreviewLimit else { return nil }
            let url = try await session.prepareViewFile(target.path)
            if await session.openKind(fileName: target.name) == .live, let text = previewText(url) {
                return .text(text)
            }
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
               let picture = await Task.detached(priority: .userInitiated, operation: { decodePicture(url) }).value {
                return .picture(picture)
            }
            return .file(try await session.preparePreview(target.path))
        } catch {
            return nil
        }
    }

    /// Warms the cache for the files on either side of `item`, one at a time, so an arrow key
    /// lands on a copy that is already here. A newer selection cancels this like everything else.
    private func prefetchNeighbors(of item: RemoteItem, session: any RemoteSession, generation: Int) {
        let list = items
        guard let index = list.firstIndex(of: item) else { return }
        let neighbors = [index + 1, index - 1].filter(list.indices.contains).map { list[$0] }
            .filter { $0.kind == .file && ($0.size ?? 0) <= Self.inspectorPreviewLimit }
        guard !neighbors.isEmpty else { return }
        inspectorTasks.append(Task { [weak self] in
            for neighbor in neighbors {
                guard !Task.isCancelled, self?.inspectorGeneration == generation else { return }
                _ = try? await session.prepareViewFile(neighbor.path)
            }
        })
    }

    /// A picture decoded at a size the pane can use, so showing it never stalls the main thread.
    nonisolated private static func decodePicture(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The first lines of a text file; nil when the bytes are not text after all.
    private static func previewText(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: 64 << 10) else { return nil }
        if data.prefix(8 << 10).contains(0) { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func focusFilter() {
        filterFocusTick += 1
    }

    // MARK: Transfers

    public func downloadSelection(to directory: URL) async {
        guard let session else { return }
        for item in selectedItems {
            let destination = directory.appendingPathComponent(item.name)
            let path = item.path
            enqueue(title: "Download \(item.name)", path: path) { progress in
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
        guard let session else { return }
        let target = folder ?? snapshot.path
        for url in urls {
            let destination = target.appending(name: Array(url.lastPathComponent.utf8))
            enqueue(title: "Upload \(url.lastPathComponent)", path: destination) { progress in
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

    /// One SFTP rename per item. Never copy-then-delete. The server's change events relist the
    /// folders on screen.
    public func move(_ paths: [RemotePath], into folder: RemotePath) async {
        guard let session else { return }
        for path in paths {
            do {
                try await session.rename(path, to: folder.appending(name: path.nameBytes))
            } catch {
                status = "Could not move \(String(decoding: path.nameBytes, as: UTF8.self)): \(error.localizedDescription)"
            }
        }
    }

    /// Queues `body` against the server the window shows now; it stays with that server.
    func enqueue(title: String, path: RemotePath, body: @escaping @Sendable (@escaping @Sendable (TransferProgress) -> Void) async throws -> Void) {
        guard let context else { return }
        let id = UUID().uuidString
        operations.append(TransferOperation(id: id, title: title, state: .queued, path: path))
        runners[id] = Runner(body: body, prompts: operationPrompts(), connection: context.connection, session: context.session, task: nil)
        showsShelf = true
        start(id)
    }

    private func start(_ id: String) {
        guard let runner = runners[id] else { return }
        runner.task?.cancel()
        update(id) { $0.state = .active; $0.message = nil }
        let body = runner.body
        let session = runner.session
        let prompts = prompts
        let operationPrompts = runner.prompts
        let report: @Sendable (TransferProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.update(id) { $0.progress = progress } }
        }
        let task = Task { [weak self] in
            var attempt = 0
            while true {
                do {
                    if !(await session.isConnected) {
                        _ = try await session.connect(prompts: prompts)
                    }
                    try await OperationPrompts.$current.withValue(operationPrompts) { try await body(report) }
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

    /// Ends a row. What changed on the server arrives as change events, which relist the
    /// folders on screen, so nothing is relisted here.
    private func finish(_ id: String, state: OperationState, message: String?) {
        update(id) { $0.state = state; $0.message = message }
        if state == .succeeded {
            operations.removeAll { $0.id == id }
            runners[id] = nil
        } else if let message {
            status = message
        }
        if operations.isEmpty { showsShelf = false }
    }

    /// Prompts for one new user operation: its collision sheets come to this window, and its
    /// Apply to All is its own.
    func operationPrompts() -> OperationPrompt {
        OperationPrompt(window: prompts)
    }

    /// The server a shelf row belongs to, named when it is not the one the window shows.
    public func otherServerName(for operation: TransferOperation) -> String? {
        let owner = runners[operation.id]?.connection ?? liveRowSessions[operation.id]?.connection
        guard let owner, owner.id != snapshot.connectionID else { return nil }
        return connections.first { $0.id == owner.id }?.displayName ?? owner.displayName
    }

    public func pause(_ operation: TransferOperation) async {
        if let path = operation.livePath {
            await (liveRowSessions[operation.id] ?? session)?.setLivePaused(path, paused: true)
            return
        }
        update(operation.id) { $0.state = .paused; $0.message = nil }
        runners[operation.id]?.task?.cancel()
    }

    public func resume(_ operation: TransferOperation) async {
        if let path = operation.livePath {
            await (liveRowSessions[operation.id] ?? session)?.setLivePaused(path, paused: false)
            return
        }
        start(operation.id)
    }

    public func remove(_ operation: TransferOperation) {
        runners[operation.id]?.task?.cancel()
        runners[operation.id] = nil
        liveRowSessions[operation.id] = nil
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

    public func isStarred(_ path: RemotePath) -> Bool {
        stars.contains(path)
    }

    /// Starred entries whose kind is unknown are treated as folders; a starred file is one the
    /// user has seen listed, so its kind is in a cached listing.
    public func starredIsFolder(_ path: RemotePath) -> Bool {
        if let known = starIsFolder[path] { return known }
        return listedItem(path).map { $0.kind == .directory } ?? true
    }

    /// Asks the server about `path` once, following a link, and remembers the answer.
    private func learnStarred(_ path: RemotePath, session: any RemoteSession) async {
        guard starIsFolder[path] == nil else { return }
        guard let item = try? await session.stat(path), let target = try? await Self.resolveLink(item, session: session) else { return }
        starIsFolder[path] = target.kind == .directory
    }

    /// Starred files and folders sit in the sidebar for one-click return.
    public func setStarred(_ paths: [RemotePath], _ starred: Bool) async {
        for path in paths {
            if starred { await session?.star(path) } else { await session?.unstar(path); starIsFolder[path] = nil }
        }
        await reloadSidebars()
    }

    /// What View > Add to Starred acts on: the selection, or the current folder with nothing selected.
    public var starTargets: [RemotePath] {
        let selected = selectedItems.map(\.path)
        return selected.isEmpty ? [snapshot.path] : selected
    }

    /// "Remove from Starred" when every one of `paths` is starred, else "Add to Starred".
    public func starTitle(_ paths: [RemotePath]) -> String {
        !paths.isEmpty && paths.allSatisfy(isStarred) ? "Remove from Starred" : "Add to Starred"
    }

    /// Unstars `paths` when all are starred, else stars the ones that are not.
    public func toggleStar(_ paths: [RemotePath]) async {
        let starred = !paths.isEmpty && paths.allSatisfy(isStarred)
        await setStarred(starred ? paths : paths.filter { !isStarred($0) }, !starred)
    }

    /// Opens a starred entry: a folder is entered, a file is revealed in its folder and opened.
    public func openStarred(_ path: RemotePath) async {
        guard let session else { return }
        do {
            let item = try await session.stat(path)
            if item.kind == .directory {
                await navigate(path)
            } else {
                await reveal(path)
                await open(item)
            }
        } catch {
            status = error.localizedDescription
        }
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

    public func resumeLive(_ path: RemotePath) async {
        await session?.setLivePaused(path, paused: false)
    }

    /// Drops every mapping whose working copy matches the server. Nothing is lost: the remote
    /// file is the source of truth and the next open downloads it again.
    public func forgetSyncedLive() async {
        guard let session else { return }
        for live in liveFiles where !live.dirty && !live.uploading && !live.conflict {
            try? await session.discardLiveFile(live.path, force: false)
        }
        await reloadSidebars()
    }

    public func discardSelectedLive() async {
        for item in selectedItems where liveFiles.contains(where: { $0.path == item.path }) {
            await discardLive(item.path)
        }
    }

    /// Live files with something happening: edited, uploading, paused, or in conflict. A synced
    /// mapping keeps working in the background but is not worth a sidebar row.
    public var activeLiveFiles: [LiveFile] {
        liveFiles.filter { $0.dirty || $0.uploading || $0.paused || $0.conflict }
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
        let text = paths.map { SFTPURL.string(connection: connection, path: $0) }.joined(separator: "\n")
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
        case .star(let path):
            // A starred folder opens; a starred file is revealed in its folder.
            if let session { await learnStarred(path, session: session) }
            if starredIsFolder(path) { await navigate(path) } else { await reveal(path) }
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

    public func openTerminal() async {
        guard let session, let command = await session.terminalCommand(directory: snapshot.path) else { return }
        TerminalLauncher.open(command: command)
    }

    /// Reads the server's stars and Live files. A star whose kind is not known yet is published
    /// first and learned after, all at once, so a slow server never holds the sidebar back.
    private func reloadSidebars() async {
        guard let context else { return }
        let session = context.session
        let starred = await session.stars()
        let live = await session.liveFiles()
        guard isCurrent(context) else { return }
        if stars != starred { stars = starred }
        if liveFiles != live { liveFiles = live }
        let unknown = starred.filter { starIsFolder[$0] == nil }
        guard !unknown.isEmpty else { return }
        let learned = await withTaskGroup(of: (RemotePath, Bool)?.self) { group in
            for path in unknown {
                group.addTask {
                    guard let item = try? await session.stat(path), let target = try? await Self.resolveLink(item, session: session) else { return nil }
                    return (path, target.kind == .directory)
                }
            }
            var found: [(RemotePath, Bool)] = []
            for await answer in group { if let answer { found.append(answer) } }
            return found
        }
        guard isCurrent(context) else { return }
        for (path, isFolder) in learned { starIsFolder[path] = isFolder }
    }

    /// Reloads the sidebar soon, once however many changes ask for it meanwhile.
    private func scheduleSidebarReload() {
        guard sidebarReload == nil else {
            sidebarReloadAgain = true
            return
        }
        sidebarReload = Task { [weak self] in
            repeat {
                self?.sidebarReloadAgain = false
                await self?.reloadSidebars()
            } while self?.sidebarReloadAgain == true && !Task.isCancelled
            self?.sidebarReload = nil
        }
    }

    /// Starts `context`'s event listener. Events are handled at once, never awaited, so a long
    /// listing or a slow star lookup never holds a conflict or an operation update back.
    private func listen(_ context: ServerContext) {
        let events = context.session.events()
        context.listener = Task { [weak self, weak context] in
            for await event in events {
                guard let self, let context else { return }
                handle(event, from: context)
            }
        }
    }

    private func handle(_ event: SessionEvent, from source: ServerContext) {
        guard isCurrent(source) else {
            // Before its login lands, a server's notices still matter to the window that asked.
            if case .notice(let text) = event, source.generation == connectGeneration { status = text }
            return
        }
        switch event {
        case .notice(let text), .disconnected(let text):
            status = text
        case .conflict(let path, let comparable):
            conflictPath = path
            conflictComparable = comparable
            conflictConfirm = nil
            if !conflicts.contains(path) { conflicts.append(path) }
            if sheet == nil { sheet = .conflict }
        case .liveChanged:
            scheduleSidebarReload()
        case .directoryChanged(let path):
            // A folder on screen is listed again, its cached listing shown until the new one is
            // complete; any other is listed again when it is next shown.
            if isShown(path) { relist(path) }
        case .operation(let operation):
            liveRowSessions[operation.id] = source.session
            if operation.state == .succeeded {
                operations.removeAll { $0.id == operation.id }
                liveRowSessions[operation.id] = nil
            } else if let index = operations.firstIndex(where: { $0.id == operation.id }) {
                operations[index] = operation
            } else {
                operations.append(operation)
                showsShelf = true
            }
            if operations.isEmpty { showsShelf = false }
        }
    }
}

public extension ViewMode {
    var title: String {
        switch self {
        case .icon: "Icons"
        case .list: "List"
        case .columns: "Columns"
        }
    }
}

public extension RemoteItem {
    var kindLabel: String {
        switch kind {
        case .directory: "Folder"
        case .symlink: "Alias"
        case .other: "Special"
        case .file:
            UTType(filenameExtension: (name as NSString).pathExtension)?.localizedDescription ?? "Document"
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
        case .goToFolder: "goto"
        case .removeServer: "remove"
        case .discardLive: "discard"
        }
    }
}

/// Answers the session's prompts by showing sheets and parking the continuation until a button resolves it.
@MainActor
public final class SheetPrompts: PromptSink {
    weak var model: TransferModel?

    public func answer(_ request: PromptRequest) async -> PromptReply {
        guard let model else { return PromptReply(text: nil) }
        return await withCheckedContinuation { continuation in
            model.pendingPrompt = continuation
            model.sheet = .prompt(request)
        }
    }

    /// One answer, with no operation to remember Apply to All for; nil once the window is gone.
    public func resolveCollision(fileName: String) async -> NameCollisionChoice? {
        await askCollision(fileName)?.choice
    }

    /// Shows the collision sheet, with Apply to All unchecked. The choice, and whether it covers
    /// the rest of the operation; nil once the window is gone.
    func askCollision(_ fileName: String) async -> (choice: NameCollisionChoice, toAll: Bool)? {
        guard let model else { return nil }
        return await withCheckedContinuation { continuation in
            model.pendingCollision = continuation
            model.applyCollisionToAll = false
            model.sheet = .collision(fileName)
        }
    }

    public func decideHostKey(_ event: HostKeyEvent) async -> HostKeyDecision {
        guard let model else { return .cancel }
        return await withCheckedContinuation { continuation in
            model.pendingHost = continuation
            model.sheet = .hostKey(event)
        }
    }
}

/// One user operation's prompts: a download, upload, paste, drag, or clipboard staging. Sheets go
/// to the window that started it, and Apply to All holds for this operation alone, never for
/// another operation or window. Bound with `OperationPrompts.$current` around the operation.
@MainActor
final class OperationPrompt: PromptSink {
    private let window: SheetPrompts
    private var applyToAll: NameCollisionChoice?

    init(window: SheetPrompts) {
        self.window = window
    }

    func answer(_ request: PromptRequest) async -> PromptReply {
        await window.answer(request)
    }

    func decideHostKey(_ event: HostKeyEvent) async -> HostKeyDecision {
        await window.decideHostKey(event)
    }

    func resolveCollision(fileName: String) async -> NameCollisionChoice? {
        if let applyToAll { return applyToAll }
        guard let answer = await window.askCollision(fileName) else { return nil }
        if answer.toAll { applyToAll = answer.choice }
        return answer.choice
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
        pendingCollision?.resume(returning: (choice, applyToAll))
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

    /// Space and Escape put the panel away; the arrow keys go to the browser behind it, so the
    /// selection moves and the panel follows, as Finder's does.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 49, 53:
            MainActor.assumeIsolated { close() }
            return true
        case 123, 124, 125, 126:
            // The panel calls this on the main thread; NSEvent just is not marked Sendable.
            nonisolated(unsafe) let forwarded = event!
            MainActor.assumeIsolated {
                if let responder = NSApp.mainWindow?.firstResponder as? NSView { responder.keyDown(with: forwarded) }
            }
            return true
        default:
            return false
        }
    }
}

public enum InspectorPreview: Equatable {
    case file(URL)
    case text(String)
    case picture(CGImage)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.file(let a), .file(let b)): a == b
        case (.text(let a), .text(let b)): a == b
        case (.picture(let a), .picture(let b)): a === b
        default: false
        }
    }
}

public enum InspectorWait: Equatable {
    case nothing, icon, spinner
}

/// The inspector's choreography. The fetch always starts at once; these only shape what shows
/// while it runs. Under 100 ms reads as instant, so a swap inside `hold` needs no animation.
/// Finder's own pane goes blank rather than showing an icon, then adds a spinner near half a
/// second; an icon that lands and is replaced within a few frames is a flicker, so it waits.
public enum PreviewTiming {
    /// How long the previous preview stays up while the next one is on its way.
    public static let hold: Duration = .milliseconds(100)
    /// Selection changes closer together than this are a held key; only then does the fetch wait.
    public static let coalesce: Duration = .milliseconds(120)
    /// When the file's icon fills the empty pane, and when it gains a spinner.
    public static let icon: Duration = .milliseconds(500)
    public static let spinner: Duration = .seconds(1)
    /// The old preview leaving, and the icon or a picture arriving over what was there.
    public static let swap: TimeInterval = 0.12
    public static let reveal: TimeInterval = 0.2
}
