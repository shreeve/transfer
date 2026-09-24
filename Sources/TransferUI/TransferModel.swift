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
    /// Posted when Settings sets the view mode, which every open window then takes. A window's
    /// own choice is only the default for new windows.
    public static let viewModeChosen = Notification.Name("TransferViewModeChosen")
    /// Posted when a window adds, edits, or removes a server, so every window's sidebar follows.
    public static let libraryChanged = Notification.Name("TransferLibraryChanged")
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
    private var liveByPath: [RemotePath: LiveFile] = [:]
    /// Live files the server changed under an edit, from the Live files themselves.
    public var conflicts: [RemotePath] { liveFiles.filter(\.conflict).map(\.path) }
    /// Whether Compare can open each conflict, as its event said. A conflict from before a
    /// relaunch is not known to be comparable.
    @ObservationIgnored private var comparableConflicts: [RemotePath: Bool] = [:]
    /// Conflicts that arrived while another sheet was up, shown in turn once it closes.
    @ObservationIgnored private var waitingConflicts: [RemotePath] = []
    /// The Keep Local or Keep Remote press waiting for its confirming second press.
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
    /// What the user should know, such as what failed: shown under the toolbar until dismissed
    /// or replaced by the next message. A listing that works never clears it.
    public var status: String?
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
    public var sheet: AppSheet? {
        didSet { sheetChanged() }
    }
    public var promptSecure = ""
    public var saveSecret = false
    public var renaming = false
    public var renameText = ""
    /// What the rename bar renames, fixed when it opens.
    @ObservationIgnored private var renameTarget: RemotePath?
    public var applyCollisionToAll = false
    public var sidebarSelection: SidebarItem?
    public var inspectorLinkTarget: String?
    /// Whether Terminal, iTerm2, or Ghostty is installed, learned in `start`.
    public var terminalAvailable = false

    public private(set) var prompts: SheetPrompts

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
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

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

    /// Reads the preferences and nothing else: SwiftUI may build a window's model more than once
    /// and keep only the first, so the work waits for `start`.
    public init(provider: any SessionProvider) {
        self.provider = provider
        let prompts = SheetPrompts()
        self.prompts = prompts
        prompts.model = self
        applyPreferences()
        if let stored = UserDefaults.standard.string(forKey: Preferences.viewMode), let mode = ViewMode(rawValue: stored) {
            snapshot.viewMode = mode
        }
    }

    /// Loads the library and follows changes to preferences and to the library. The window
    /// calls it once it is on screen.
    public func start() {
        guard observers.isEmpty else { return }
        terminalAvailable = TerminalLauncher.anyInstalled()
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ act: @escaping @MainActor (TransferModel) async -> Void) -> any NSObjectProtocol {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in if let self { await act(self) } }
            }
        }
        observers = [
            observe(UserDefaults.didChangeNotification) { $0.applyPreferences() },
            observe(Preferences.libraryChanged) { await $0.reloadConnections() },
            observe(Preferences.viewModeChosen) { model in
                if let stored = UserDefaults.standard.string(forKey: Preferences.viewMode), let mode = ViewMode(rawValue: stored) {
                    model.setViewMode(mode)
                }
            },
        ]
        Task { await reloadConnections() }
    }

    /// A closed window stops listening and listing. Its queued transfers run on without it, and
    /// its waiting questions get the safe answer.
    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        context?.close()
        sidebarReload?.cancel()
        prompts.cancelAll()
    }

    /// Reads the global preferences at launch and whenever they change. Hidden files and the sort
    /// switches are global, as in Finder; the view mode is not, and follows `viewModeChosen`.
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

    /// Reads the saved servers. A window whose server another window removed shows none.
    public func reloadConnections() async {
        guard let loaded = try? await provider.savedConnections() else { return }
        Self.lastConnections = loaded
        if connections != loaded { connections = loaded }
        if let id = snapshot.connectionID, !loaded.contains(where: { $0.id == id }) { uninstall() }
    }

    public var currentConnection: SavedConnection? {
        connections.first { $0.id == snapshot.connectionID }
    }

    /// The window's title: the server it shows, or the one it is logging in to.
    public var title: String {
        if let connectingTo { return "Connecting to \(connectingTo.displayName)…" }
        return currentConnection?.displayName ?? context?.connection.displayName ?? "Not connected"
    }

    /// Shows what went wrong. A cancellation is not an error.
    func report(_ error: any Error) {
        if Self.isCancellation(error) { return }
        status = error.localizedDescription
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? TransferError) == .cancelled
    }

    /// Runs `body`, showing what it throws.
    private func reporting(_ body: () async throws -> Void) async {
        do { try await body() } catch { report(error) }
    }

    /// One message for the items an action on several could not handle: "Could not delete
    /// “a”: Permission denied", or "Could not delete 2 of 5 items. “a”: …; “b”: …".
    private func reportFailures(_ verb: String, _ failures: [(name: String, error: any Error)], of total: Int) {
        let failures = failures.filter { !Self.isCancellation($0.error) }
        guard !failures.isEmpty else { return }
        let each = failures.map { "“\($0.name)”: \($0.error.localizedDescription)" }.joined(separator: "; ")
        status = total == 1 ? "Could not \(verb) \(each)" : "Could not \(verb) \(failures.count) of \(total) items. \(each)"
    }

    /// Logs in and shows the start folder, or `landing` when given: that folder, or the file
    /// selected in its folder. Nothing in the window changes until the login has worked, so a
    /// failed or cancelled login leaves the window on the server it showed; when connects
    /// overlap, the last one asked for wins, whichever finishes first.
    public func connect(_ connection: SavedConnection, landing: RemotePath? = nil) async {
        connectGeneration &+= 1
        let generation = connectGeneration
        connectingTo = connection
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
            let start = try await session.connect(prompts: prompts.login(connection))
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
            await refresh()
            scheduleSidebarReload()
            if let missing { status = "No such file or folder: \(missing.display)" }
        } catch {
            guard generation == connectGeneration else { return }
            report(error)
        }
    }

    /// Makes `fresh` the window's server in one step: its session, listener, location, and
    /// empty caches. The old server's listener and listings stop; its queued transfers go on.
    private func install(_ fresh: ServerContext, path: RemotePath, selection: Set<RemotePath>) {
        leaveServer(keepingRowsOf: fresh.connection.id)
        context = fresh
        snapshot.connectionID = fresh.connection.id
        snapshot.path = path
        snapshot.selection = selection
        columnRoot = path
        loadPreferences(for: fresh.connection.id)
        refreshItems()
        syncSidebarSelection()
    }

    /// Leaves the window showing no server.
    private func uninstall() {
        leaveServer(keepingRowsOf: nil)
        snapshot.connectionID = nil
        snapshot.selection = []
        refreshItems()
        syncSidebarSelection()
    }

    /// Forgets what the window knew about the server it showed, and stops listening to it.
    private func leaveServer(keepingRowsOf id: ConnectionID?) {
        context?.close()
        context = nil
        backStack.removeAll()
        forwardStack.removeAll()
        listings.removeAll()
        listingUse.removeAll()
        starIsFolder.removeAll()
        stars = []
        liveFiles = []
        waitingConflicts.removeAll()
        comparableConflicts.removeAll()
        if case .conflict = sheet { sheet = nil }
        dropLiveRows(keeping: id)
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
        await reporting {
            try await provider.save(connection)
            await reloadConnections()
            NotificationCenter.default.post(name: Preferences.libraryChanged, object: nil)
            sheet = nil
            let landing = pendingLanding
            pendingLanding = nil
            if !wasEdit { await connect(connection, landing: landing) }
        }
    }

    public func askToRemove(_ connection: SavedConnection) {
        sheet = .removeServer(connection)
    }

    /// The library refuses while the server has unsynced Live edits, and only a removal that
    /// worked logs out, so a refusal leaves every window on that server as it was.
    public func removeServer(_ connection: SavedConnection) async {
        sheet = nil
        await reporting {
            try await provider.removeConnection(connection.id)
            UserDefaults.standard.removeObject(forKey: Self.sortKey(connection.id))
            if snapshot.connectionID == connection.id { uninstall() }
            await reloadConnections()
            NotificationCenter.default.post(name: Preferences.libraryChanged, object: nil)
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
            listOrder = ListingSort.merge(page, into: listOrder, sort: sort)
            // A list already in name order, as by default, serves the columns too.
            nameOrder = byName == sort ? listOrder : ListingSort.merge(page, into: nameOrder, sort: byName)
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
                report(error)
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
        guard let context else { return }
        await reporting {
            let path = try await context.session.connect(prompts: prompts.login(context.connection))
            await navigate(path)
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

    /// The inspector's line for a path: its Live state, or an active transfer.
    public func statusText(for path: RemotePath) -> String {
        if let live = liveByPath[path] { return live.state.label }
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

    /// Leaving column view drops a selected folder that is the location itself: the other views
    /// show its contents with nothing highlighted, and Delete or Rename would act on it unseen.
    public func setViewMode(_ mode: ViewMode) {
        if snapshot.viewMode == .columns, mode != .columns, snapshot.selection == [snapshot.path] { snapshot.selection = [] }
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
        await reporting {
            let target = try await Self.resolveLink(item, session: session)
            if target.kind == .directory {
                await navigate(target.path)
                return
            }
            guard target.kind == .file else { return }
            let rule = await session.openKind(fileName: target.name)
            let url = forceLive || rule == .live ? try await session.prepareLiveFile(target.path) : try await session.prepareViewFile(target.path)
            try await FileOpener.open(url)
            await reloadSidebars()
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

    /// Quick Look on `item`, or on the primary selected item. A fetch that finishes after the
    /// panel was put away leaves it closed.
    public func showPreview(_ item: RemoteItem? = nil) {
        guard let session, let item = item ?? primaryItem else { return }
        previewTask?.cancel()
        let generation = PreviewPanel.shared.generation
        previewTask = Task { [weak self] in
            do {
                let target = try await Self.resolveLink(item, session: session)
                let url = try await session.preparePreview(target.path)
                if Task.isCancelled { return }
                PreviewPanel.shared.show(url, generation: generation)
            } catch {
                self?.report(error)
            }
        }
    }

    public func selectionChanged() {
        if renaming, let renameTarget, snapshot.selection != [renameTarget] { renaming = false }
        if PreviewPanel.shared.isVisible {
            if primaryItem != nil { showPreview() } else { PreviewPanel.shared.close() }
        }
        refreshInspectorPreview()
        inspectorLinkTarget = nil
        if let item = primaryItem, item.kind == .symlink, let session {
            Task { [weak self] in
                let target = try? await session.readlink(item.path)
                // A reply for a link the selection has since left is dropped.
                guard let self, primaryItem?.path == item.path else { return }
                inspectorLinkTarget = target
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
        let timeline: [(at: Duration, step: @MainActor (TransferModel) -> Void)] = [
            (PreviewTiming.hold, { $0.inspectorPreview = nil }),
            (PreviewTiming.icon, { $0.inspectorWait = .icon }),
            (PreviewTiming.spinner, { $0.inspectorWait = .spinner }),
        ]
        inspectorTasks = [
            // The wait, step by step, until the fetch lands and cancels it.
            Task { [weak self] in
                for (at, step) in timeline {
                    try? await Task.sleep(until: now + at)
                    guard let self, !Task.isCancelled, generation == inspectorGeneration else { return }
                    step(self)
                }
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

    /// The preview for one file, ready to draw: text, a decoded picture, or the local copy for
    /// Quick Look. Nil when it is not a small file after all. The copy is read off the main
    /// thread.
    private static func fetchPreview(_ item: RemoteItem, session: any RemoteSession) async -> InspectorPreview? {
        do {
            let target = try await Self.resolveLink(item, session: session)
            guard target.kind == .file, (target.size ?? 0) <= inspectorPreviewLimit else { return nil }
            let url = try await session.prepareViewFile(target.path)
            let isText = await session.openKind(fileName: target.name) == .live
            let isPicture = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            let read = await Task.detached(priority: .userInitiated) { () -> InspectorPreview? in
                if isText, let text = previewText(url) { return .text(text) }
                if isPicture, let picture = decodePicture(url) { return .picture(picture) }
                return nil
            }.value
            return read ?? .file(url)
        } catch {
            return nil
        }
    }

    /// Warms the cache for the files on either side of `item`, one at a time, so an arrow key
    /// lands on a copy that is already here. A newer selection cancels this like everything else.
    private func prefetchNeighbors(of item: RemoteItem, session: any RemoteSession, generation: Int) {
        let list = displayedItems
        guard let index = displayedIndex[item.path] else { return }
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
    nonisolated private static func previewText(_ url: URL) -> String? {
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
        var failures: [(name: String, error: any Error)] = []
        for path in paths {
            do {
                try await session.rename(path, to: folder.appending(name: path.nameBytes))
            } catch {
                failures.append((path.name, error))
            }
        }
        reportFailures("move", failures, of: paths.count)
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
        let login = prompts.login(runner.connection)
        let operationPrompts = runner.prompts
        // IO reports every 64 KB, thousands of times a second. The latest report waits in a box
        // and reaches the shelf at most every 100 ms, as one main-actor task.
        let latest = Locked<TransferProgress?>(nil)
        let report: @Sendable (TransferProgress) -> Void = { [weak self] progress in
            let idle = latest.withLock { box in
                defer { box = progress }
                return box == nil
            }
            guard idle else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                guard let progress = latest.withLock({ box in
                    defer { box = nil }
                    return box
                }) else { return }
                self?.update(id) { $0.progress = progress }
            }
        }
        let task = Task { [weak self] in
            var attempt = 0
            while true {
                do {
                    if !(await session.isConnected) {
                        _ = try await session.connect(prompts: login)
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
        guard let context else { return }
        let existing = Set((listings[snapshot.path]?.items ?? items).map(\.name))
        let name = KeepBothName.untitledFolder(existing: existing)
        let path = snapshot.path.appending(name: Array(name.utf8))
        await reporting {
            try await context.session.mkdir(path)
            await refresh()
            if isCurrent(context) { snapshot.selection = [path] }
        }
    }

    public var unsyncedInSelection: Int {
        liveFiles.filter { live in live.dirty && snapshot.selection.contains { live.path.isInside($0) } }.count
    }

    public func askToDelete() {
        guard !snapshot.selection.isEmpty else { return }
        sheet = .delete
    }

    /// Deletes the selection and says which items could not go. What failed stays selected.
    /// The Delete sheet has warned about unsynced Live edits under the selection, so those Live
    /// files are discarded first; the session refuses to remove a path that still holds one.
    public func deleteSelection() async {
        guard let context else { return }
        let paths = snapshot.selection.sorted { $0.display < $1.display }
        let live = liveFiles
        var removed: [RemotePath] = []
        var failures: [(name: String, error: any Error)] = []
        for path in paths {
            do {
                for file in live where file.path.isInside(path) {
                    try await context.session.discardLiveFile(file.path, force: true)
                }
                try await context.session.remove(path)
                removed.append(path)
            } catch {
                failures.append((path.name, error))
            }
        }
        guard isCurrent(context) else { return }
        reportFailures("delete", failures, of: paths.count)
        snapshot.selection.subtract(removed)
        await stepOut(of: removed)
        await reloadSidebars()
    }

    /// After `gone` left their places: a window standing in one of them moves up to its parent,
    /// keeping the column view's columns when that parent is one, and the location lists again.
    private func stepOut(of gone: [RemotePath]) async {
        for path in listings.keys where gone.contains(where: path.isInside) { listings[path] = nil }
        guard let left = gone.first(where: snapshot.path.isInside), let parent = left.parent else {
            await refresh()
            return
        }
        if snapshot.viewMode == .columns, let root = columnRoot, parent.isInside(root) {
            snapshot.path = parent
            snapshot.selection = []
            context?.cancelListings(keeping: isShown)
            refreshItems()
            await refresh()
        } else {
            await show(parent)
        }
    }

    /// Opens the rename bar for `item`, or the primary selected item. The rename acts on that
    /// item whatever is selected when it is confirmed; moving the selection closes the bar.
    public func beginRename(_ item: RemoteItem? = nil) {
        guard let item = item ?? primaryItem else { return }
        renameTarget = item.path
        renameText = item.name
        renaming = true
    }

    public func renameSelection(to name: String) async {
        renaming = false
        guard let context, let source = renameTarget, let parent = source.parent else { return }
        renameTarget = nil
        guard name != source.name else { return }
        guard Self.isValidName(name) else {
            status = "“\(name)” cannot be a name: it must not be empty, “.” or “..”, or hold a “/”."
            return
        }
        let destination = parent.appending(name: Array(name.utf8))
        await reporting {
            try await context.session.rename(source, to: destination)
            guard isCurrent(context) else { return }
            if snapshot.path.isInside(source) {
                // The location itself was renamed, as a folder selected in column view is.
                let moved = RemotePath(bytes: destination.bytes + snapshot.path.bytes.dropFirst(source.bytes.count))
                await stepOut(of: [source])
                if snapshot.path == parent, snapshot.viewMode == .columns {
                    snapshot.selection = [destination]
                    snapshot.path = moved
                    refreshItems()
                    await refresh()
                } else {
                    await show(moved)
                }
            } else {
                await refresh()
                snapshot.selection = [destination]
            }
        }
    }

    /// One item's name as the server takes it: not empty, not `.` or `..`, and with no `/` or
    /// NUL, which would put the item somewhere else or fail.
    private static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// Copies each selected file, link, or folder beside itself as "name copy", on the server,
    /// with its progress on the shelf.
    public func duplicateSelection() async {
        guard let session else { return }
        var taken: [RemotePath: Set<String>] = [:]
        for item in selectedItems {
            guard let parent = item.path.parent else { continue }
            var existing = taken[parent] ?? Set(listings[parent]?.items.map(\.name) ?? [])
            let name = KeepBothName.duplicate(existing: existing, original: item.name)
            existing.insert(name)
            taken[parent] = existing
            let source = item.path
            let destination = parent.appending(name: Array(name.utf8))
            enqueue(title: "Duplicate \(item.name)", path: destination) { progress in
                try await session.copy(source, to: destination, progress: progress)
            }
        }
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
        guard starIsFolder[path] == nil, let isFolder = await Self.isFolder(path, session: session) else { return }
        starIsFolder[path] = isFolder
    }

    /// Whether `path` is a folder, through a link; nil when the server cannot say.
    private static func isFolder(_ path: RemotePath, session: any RemoteSession) async -> Bool? {
        guard let item = try? await session.stat(path), let target = try? await resolveLink(item, session: session) else { return nil }
        return target.kind == .directory
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
        await reporting {
            let item = try await session.stat(path)
            if item.kind == .directory {
                await navigate(path)
            } else {
                await reveal(path)
                await open(item)
            }
        }
    }

    public func discardLive(_ path: RemotePath, force: Bool = false) async {
        guard let session else { return }
        do {
            try await session.discardLiveFile(path, force: force)
            waitingConflicts.removeAll { $0 == path }
            await reloadSidebars()
        } catch TransferError.liveUnsynced {
            sheet = .discardLive(path)
        } catch {
            report(error)
        }
    }

    public func resumeLive(_ path: RemotePath) async {
        await session?.setLivePaused(path, paused: false)
    }

    /// Drops every mapping whose working copy matches the server. Nothing is lost: the remote
    /// file is the source of truth and the next open downloads it again.
    public func forgetSyncedLive() async {
        guard let session else { return }
        for live in liveFiles where live.isSynced {
            try? await session.discardLiveFile(live.path, force: false)
        }
        await reloadSidebars()
    }

    public func discardSelectedLive() async {
        for item in selectedItems where liveByPath[item.path] != nil {
            await discardLive(item.path)
        }
    }

    /// Live files with something happening: edited, uploading, paused, or in conflict. A synced
    /// mapping keeps working in the background but is not worth a sidebar row.
    public var activeLiveFiles: [LiveFile] {
        liveFiles.filter { $0.state != .synced }
    }

    public func liveFile(for path: RemotePath) -> LiveFile? {
        liveByPath[path]
    }

    public func clearPreviewCache() async {
        await session?.clearPreviewCache()
    }

    /// Puts `sftp://` links on the pasteboard: for `paths` when given, as for the folder of an
    /// empty-area menu, else for the selection, or the location with nothing selected.
    public func copyRemoteURL(_ paths: [RemotePath]? = nil) {
        guard let connection = currentConnection else { return }
        let paths = paths ?? (snapshot.selection.isEmpty ? [snapshot.path] : snapshot.selection.sorted { $0.display < $1.display })
        let text = paths.map { SFTPURL.string(connection: connection, path: $0) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Conflicts

    /// Keep Local and Keep Remote need a second press; each choice acts on the file its sheet
    /// was opened for.
    public func chooseConflict(_ choice: LiveConflictChoice) async {
        guard case .conflict(let path, _) = sheet else { return }
        switch choice {
        case .keepLocal, .keepRemote:
            if conflictConfirm == choice {
                await resolveConflict(path, choice)
            } else {
                conflictConfirm = choice
            }
        case .compare, .keepBoth:
            await resolveConflict(path, choice)
        }
    }

    private func resolveConflict(_ path: RemotePath, _ choice: LiveConflictChoice) async {
        guard let session else { return }
        conflictConfirm = nil
        if choice != .compare {
            waitingConflicts.removeAll { $0 == path }
            sheet = nil
        }
        do {
            try await session.resolveLive(path, choice: choice)
        } catch {
            report(error)
        }
    }

    /// Shows the conflict sheet for `path` now, or once the sheet on screen closes.
    private func showConflict(_ path: RemotePath) {
        if case .conflict(let shown, _) = sheet, shown == path { return }
        guard sheet == nil else {
            if !waitingConflicts.contains(path) { waitingConflicts.append(path) }
            return
        }
        conflictConfirm = nil
        sheet = .conflict(path, comparable: comparableConflicts[path] ?? false)
    }

    /// A sheet came or went: a waiting question goes first, then a waiting conflict.
    private func sheetChanged() {
        prompts.sheetChanged()
        if sheet == nil, !waitingConflicts.isEmpty { showConflict(waitingConflicts.removeFirst()) }
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
            showConflict(path)
        }
        // A row is a command: the selection goes back to the server shown, so clicking the
        // same star, Live file, or conflict again acts again.
        syncSidebarSelection()
    }

    /// Selects the sidebar row of the server the window shows.
    private func syncSidebarSelection() {
        let shown = snapshot.connectionID.map(SidebarItem.server)
        if sidebarSelection != shown { sidebarSelection = shown }
    }

    public func reveal(_ path: RemotePath) async {
        guard let parent = path.parent else { return }
        if parent != snapshot.path { await navigate(parent) }
        snapshot.selection = [path]
    }

    public func openTerminal() async {
        guard let session, let command = await session.terminalCommand(directory: snapshot.path) else { return }
        if let problem = await TerminalLauncher.open(command: command) { status = problem }
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
                group.addTask { await Self.isFolder(path, session: session).map { (path, $0) } }
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
            comparableConflicts[path] = comparable
            showConflict(path)
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

/// What a Live file is doing, the most pressing first: a conflict, then an upload, a pause, and
/// unsynced edits. Every label, symbol, and tooltip for it comes from here.
public enum LiveState: Equatable {
    case conflict, uploading, paused, dirty, synced

    public var label: String {
        switch self {
        case .conflict: "Conflict"
        case .uploading: "Uploading"
        case .paused: "Paused"
        case .dirty: "Live, unsynced"
        case .synced: "Live"
        }
    }

    public var symbolName: String {
        switch self {
        case .conflict: "exclamationmark.triangle.fill"
        case .uploading: "arrow.up.circle.fill"
        case .paused: "pause.circle"
        case .dirty: "pencil.circle.fill"
        case .synced: "checkmark.circle"
        }
    }

    public var help: String {
        switch self {
        case .conflict: "Changed on the server; needs a decision"
        case .uploading: "Uploading"
        case .paused: "Paused"
        case .dirty: "Edited here, not yet uploaded"
        case .synced: "Synced; saves in the editor upload"
        }
    }
}

public extension LiveFile {
    var state: LiveState {
        if conflict { return .conflict }
        if uploading { return .uploading }
        if paused { return .paused }
        return dirty ? .dirty : .synced
    }

    /// The working copy matches the server, so forgetting the mapping loses nothing. A paused
    /// file with nothing unsynced counts.
    var isSynced: Bool { !dirty && !uploading && !conflict }
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
    /// A login question, for the server named when it is known. `ask` ties the sheet to the
    /// question waiting for it.
    case prompt(PromptRequest, server: String?, ask: Int)
    case hostKey(HostKeyEvent, server: String?, ask: Int)
    case delete
    case collision(String, ask: Int)
    /// A Live file changed on the server, and whether Compare can open it.
    case conflict(RemotePath, comparable: Bool)
    case goToFolder
    case removeServer(SavedConnection)
    case discardLive(RemotePath)

    public var id: String {
        switch self {
        case .connection: "connection"
        case .prompt(_, _, let ask): "prompt-\(ask)"
        case .hostKey(_, _, let ask): "host-\(ask)"
        case .delete: "delete"
        case .collision(_, let ask): "collision-\(ask)"
        case .conflict(let path, _): "conflict-\(path.display)"
        case .goToFolder: "goto"
        case .removeServer: "remove"
        case .discardLive: "discard"
        }
    }

    /// The question this sheet answers, for the sheets that answer one.
    var ask: Int? {
        switch self {
        case .prompt(_, _, let ask), .hostKey(_, _, let ask), .collision(_, let ask): ask
        default: nil
        }
    }
}

/// Answers the questions sessions and operations ask, with sheets in this window. Questions
/// wait in line and show one at a time, in the order they came, each once no other sheet is
/// up; two at once never replace each other. A question whose sheet goes away unanswered, whose
/// task is cancelled, or whose window closes gets the safe answer: no password, no trust, and no
/// choice, which fails its operation rather than guess.
@MainActor
public final class SheetPrompts: PromptSink {
    weak var model: TransferModel?
    private var queue: [Ask] = []
    /// The question on screen, the first in the queue once shown.
    private var shown: Int?
    private var lastAsk = 0

    private struct Ask {
        let id: Int
        let sheet: AppSheet
        let waiting: Waiting
    }

    private enum Waiting {
        case login(CheckedContinuation<PromptReply, Never>)
        case hostKey(CheckedContinuation<HostKeyDecision, Never>)
        case collision(CheckedContinuation<(choice: NameCollisionChoice, toAll: Bool)?, Never>)

        func cancel() {
            switch self {
            case .login(let continuation): continuation.resume(returning: PromptReply(text: nil))
            case .hostKey(let continuation): continuation.resume(returning: .cancel)
            case .collision(let continuation): continuation.resume(returning: nil)
            }
        }
    }

    public func answer(_ request: PromptRequest) async -> PromptReply {
        await answer(request, server: nil)
    }

    func answer(_ request: PromptRequest, server: String?) async -> PromptReply {
        guard model != nil else { return PromptReply(text: nil) }
        return await ask { id, continuation in Ask(id: id, sheet: .prompt(request, server: server, ask: id), waiting: .login(continuation)) }
    }

    public func decideHostKey(_ event: HostKeyEvent) async -> HostKeyDecision {
        await decideHostKey(event, server: nil)
    }

    func decideHostKey(_ event: HostKeyEvent, server: String?) async -> HostKeyDecision {
        guard model != nil else { return .cancel }
        return await ask { id, continuation in Ask(id: id, sheet: .hostKey(event, server: server, ask: id), waiting: .hostKey(continuation)) }
    }

    /// One answer, with no operation to remember Apply to All for; nil once the window is gone.
    public func resolveCollision(fileName: String) async -> NameCollisionChoice? {
        await askCollision(fileName)?.choice
    }

    /// Shows the collision sheet, with Apply to All unchecked. The choice, and whether it covers
    /// the rest of the operation; nil when nobody answered.
    func askCollision(_ fileName: String) async -> (choice: NameCollisionChoice, toAll: Bool)? {
        guard model != nil else { return nil }
        return await ask { id, continuation in Ask(id: id, sheet: .collision(fileName, ask: id), waiting: .collision(continuation)) }
    }

    private func ask<Answer>(_ make: (Int, CheckedContinuation<Answer, Never>) -> Ask) async -> Answer {
        lastAsk += 1
        let id = lastAsk
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.append(make(id, continuation))
                presentIfIdle()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.withdraw(id) }
        }
    }

    /// Shows the first question once nothing else is on screen.
    private func presentIfIdle() {
        guard let model, model.sheet == nil, shown == nil, let first = queue.first else { return }
        shown = first.id
        model.applyCollisionToAll = false
        model.sheet = first.sheet
    }

    /// The window's sheet changed. A question whose sheet was dismissed or replaced without an
    /// answer gets the safe one, and the next question shows when the window is free.
    func sheetChanged() {
        guard let model else { return }
        if let shown, model.sheet?.ask != shown, let index = queue.firstIndex(where: { $0.id == shown }) {
            self.shown = nil
            queue.remove(at: index).waiting.cancel()
        }
        presentIfIdle()
    }

    /// Takes back a question whose task was cancelled, as when its transfer is paused.
    private func withdraw(_ id: Int) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let ask = queue.remove(at: index)
        ask.waiting.cancel()
        if shown == id {
            shown = nil
            if model?.sheet?.ask == id { model?.sheet = nil }
        }
    }

    /// The first question's answer, from its sheet's buttons.
    private func finish(_ answer: (Waiting) -> Bool) {
        guard let shown, let index = queue.firstIndex(where: { $0.id == shown }), answer(queue[index].waiting) else { return }
        queue.remove(at: index)
        self.shown = nil
        model?.sheet = nil
    }

    func finishLogin(_ reply: PromptReply) {
        finish { waiting in
            guard case .login(let continuation) = waiting else { return false }
            continuation.resume(returning: reply)
            return true
        }
    }

    func finishHostKey(_ decision: HostKeyDecision) {
        finish { waiting in
            guard case .hostKey(let continuation) = waiting else { return false }
            continuation.resume(returning: decision)
            return true
        }
    }

    func finishCollision(_ choice: NameCollisionChoice, toAll: Bool) {
        finish { waiting in
            guard case .collision(let continuation) = waiting else { return false }
            continuation.resume(returning: (choice, toAll))
            return true
        }
    }

    /// The window closed: every waiting question gets the safe answer.
    func cancelAll() {
        let waiting = queue
        queue.removeAll()
        shown = nil
        for ask in waiting { ask.waiting.cancel() }
    }

    /// This window's sheets for one server's login, which name that server.
    func login(_ connection: SavedConnection) -> any PromptSink {
        LoginPrompts(window: self, server: connection.displayName)
    }
}

/// A login's questions, shown in the window that asked and naming the server they are for, so a
/// password or host key is never typed for the wrong one.
private struct LoginPrompts: PromptSink {
    let window: SheetPrompts
    let server: String

    func answer(_ request: PromptRequest) async -> PromptReply {
        await window.answer(request, server: server)
    }

    func decideHostKey(_ event: HostKeyEvent) async -> HostKeyDecision {
        await window.decideHostKey(event, server: server)
    }

    func resolveCollision(fileName: String) async -> NameCollisionChoice? {
        await window.resolveCollision(fileName: fileName)
    }
}

/// One user operation's prompts: a download, upload, paste, drag, or clipboard staging. Sheets go
/// to the window that started it, and Apply to All holds for this operation alone, never for
/// another operation or window. Bound with `OperationPrompts.$current` around the operation.
/// The operation's files that collide at once are asked about one at a time, so an Apply to All
/// answers the ones still waiting too.
@MainActor
final class OperationPrompt: PromptSink {
    private let window: SheetPrompts
    private var applyToAll: NameCollisionChoice?
    private var asking: Task<(choice: NameCollisionChoice, toAll: Bool)?, Never>?

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
        while let current = asking {
            _ = await current.value
            if asking == current { asking = nil }
        }
        if let applyToAll { return applyToAll }
        let window = window
        // The question records Apply to All itself, before anyone waiting on it looks.
        let question = Task { [weak self] in
            let answer = await window.askCollision(fileName)
            if let answer, answer.toAll { self?.applyToAll = answer.choice }
            return answer
        }
        asking = question
        let answer = await withTaskCancellationHandler { await question.value } onCancel: { question.cancel() }
        if asking == question { asking = nil }
        return answer?.choice
    }
}

extension TransferModel {
    /// Keychain saving applies only where the sheet offered it; a later question in the same
    /// login, such as a one-time code, never replaces the saved password.
    func finishPrompt(_ reply: PromptReply, offered: Bool) {
        var reply = reply
        reply.saveInKeychain = reply.saveInKeychain && offered
        promptSecure = ""
        saveSecret = false
        prompts.finishLogin(reply)
    }

    func finishHost(_ decision: HostKeyDecision) {
        prompts.finishHostKey(decision)
    }

    func finishCollision(_ choice: NameCollisionChoice, applyToAll: Bool) {
        prompts.finishCollision(choice, toAll: applyToAll)
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

    /// Runs `command` in a running Terminal, iTerm2, or Ghostty, otherwise the first installed
    /// one. What went wrong, if anything, in words for the window.
    @MainActor
    static func open(command: String) async -> String? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let choice = apps.first { running.contains($0.bundle) }
            ?? apps.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundle) != nil }
        guard let choice, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: choice.bundle) else {
            return "Open in Terminal needs Terminal, iTerm2, or Ghostty."
        }
        let script: String
        switch choice.name {
        case "Terminal":
            script = "tell application \"Terminal\"\nactivate\ndo script \(appleScriptString(command))\nend tell"
        case "iTerm2":
            script = "tell application \"iTerm\"\nactivate\ncreate window with default profile command \(appleScriptString(command))\nend tell"
        default:
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["-e", command]
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                return nil
            } catch {
                return "\(choice.name) did not open: \(error.localizedDescription)"
            }
        }
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        guard let error else { return nil }
        // errAEEventNotPermitted: the user has not let Transfer control the app.
        if error[NSAppleScript.errorNumber] as? Int == -1743 {
            return "Transfer may not control \(choice.name). Allow it in System Settings > Privacy & Security > Automation."
        }
        return error[NSAppleScript.errorMessage] as? String ?? "\(choice.name) did not run the command."
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// The Quick Look panel, one per app. Quick Look calls its data source and delegate on the main
/// thread. `close` moves `generation` on, so a fetch that finishes after the user put the panel
/// away does not bring it back.
@MainActor
final class PreviewPanel: NSObject, @MainActor QLPreviewPanelDataSource, @MainActor QLPreviewPanelDelegate {
    static let shared = PreviewPanel()
    private var url: URL?
    private(set) var generation = 0

    private enum Key {
        static let space: UInt16 = 49
        static let escape: UInt16 = 53
        static let arrows: ClosedRange<UInt16> = 123...126
    }

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    /// Shows `url`, unless the panel was closed since `generation` was read.
    func show(_ url: URL, generation: Int) {
        guard generation == self.generation, let panel = QLPreviewPanel.shared() else { return }
        self.url = url
        panel.dataSource = self
        panel.delegate = self
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        generation &+= 1
        guard isVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        (url ?? URL(fileURLWithPath: "/")) as NSURL
    }

    /// Space and Escape put the panel away; the arrow keys go to the browser behind it, so the
    /// selection moves and the panel follows, as Finder's does.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case Key.space, Key.escape:
            close()
            return true
        case Key.arrows:
            if let responder = NSApp.mainWindow?.firstResponder as? NSView { responder.keyDown(with: event) }
            return true
        default:
            return false
        }
    }
}

public enum InspectorPreview: Equatable, Sendable {
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
