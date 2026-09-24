import AppKit
import SwiftUI
import TransferCore

/// The window frame, built the way Finder builds it: an AppKit split view controller for the
/// sidebar, content, and inspector, and an AppKit toolbar. The columns' contents are SwiftUI.
struct WindowChrome<Sidebar: View, Detail: View, Inspector: View>: NSViewRepresentable {
    var model: TransferModel
    var title: String
    var subtitle: String
    var viewMode: ViewMode
    var sidebarCollapsed: Bool
    var inspectorShown: Bool
    var searchTick: Int
    var sidebar: Sidebar
    var detail: Detail
    var inspector: Inspector

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> ChromeContainer {
        let controller = ChromeController()
        controller.coordinator = context.coordinator
        controller.install(
            sidebar: NSHostingController(rootView: AnyView(sidebar)),
            detail: NSHostingController(rootView: AnyView(detail)),
            inspector: NSHostingController(rootView: AnyView(inspector))
        )
        context.coordinator.controller = controller
        let container = ChromeContainer(controller: controller)
        apply(to: controller, context: context)
        return container
    }

    /// The hosted columns observe the model themselves and are never re-hosted here.
    func updateNSView(_ container: ChromeContainer, context: Context) {
        context.coordinator.model = model
        apply(to: container.controller, context: context)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChromeContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 960, height: proposal.height ?? 640)
    }

    private func apply(to controller: ChromeController, context: Context) {
        controller.model = model
        controller.setTitle(title, subtitle: subtitle)
        controller.setSidebarCollapsed(sidebarCollapsed)
        controller.setInspectorShown(inspectorShown)
        // List view's column header has its own line, so Finder shows no hover line there.
        controller.hoverLineEnabled = viewMode != .list
        context.coordinator.selectViewMode(viewMode)
        if context.coordinator.searchTick != searchTick {
            context.coordinator.searchTick = searchTick
            context.coordinator.beginSearch(nil)
        }
    }

    /// Toolbar delegate and action target. It reads the model and never owns state.
    @MainActor
    final class Coordinator: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
        var model: TransferModel
        weak var controller: ChromeController?
        var searchTick = 0
        private var viewGroup: NSToolbarItemGroup?
        private var searchView: SearchToolbarView?

        init(model: TransferModel) { self.model = model }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [.toggleSidebar, .sidebarTrackingSeparator, ChromeItem.backForward, .flexibleSpace, ChromeItem.viewMode, ChromeItem.transfers, ChromeItem.search]
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }

        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            switch identifier {
            case .sidebarTrackingSeparator:
                guard let splitView = controller?.splitView else { return nil }
                return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitView, dividerIndex: 0)
            case ChromeItem.backForward:
                let group = makeGroup(identifier, "Back/Forward", symbols: ["chevron.backward", "chevron.forward"],
                                      labels: ["Back", "Forward"], mode: .momentary, action: #selector(navigate(_:)))
                group.isNavigational = true
                return group
            case ChromeItem.viewMode:
                let group = makeGroup(identifier, "View", symbols: ["square.grid.2x2", "list.bullet", "rectangle.split.3x1"],
                                      labels: ["Icons", "List", "Columns"], mode: .selectOne, action: #selector(changeViewMode(_:)))
                group.selectedIndex = index(of: model.snapshot.viewMode)
                viewGroup = group
                return group
            case ChromeItem.transfers:
                let item = NSToolbarItem(itemIdentifier: identifier)
                item.image = symbol("arrow.up.arrow.down.circle")
                item.label = "Transfers"
                item.visibilityPriority = .high
                item.toolTip = "Show or hide transfers"
                item.isBordered = true
                item.target = self
                item.action = #selector(toggleShelf(_:))
                return item
            case ChromeItem.search:
                // Two fixed sizes, switched only by the user. The system search item resizes
                // with free space, shoving other items in and out of the overflow menu.
                let item = NSToolbarItem(itemIdentifier: identifier)
                let view = SearchToolbarView()
                view.field.placeholderString = "Search"
                view.field.delegate = self
                view.field.sendsSearchStringImmediately = true
                view.button.target = self
                view.button.action = #selector(beginSearch(_:))
                view.onCollapse = { [weak self] in self?.model.textEditing = false }
                item.view = view
                view.item = item
                item.label = "Search"
                item.visibilityPriority = .high
                searchView = view
                return item
            default:
                return nil
            }
        }

        private func symbol(_ name: String) -> NSImage {
            NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        }

        private func makeGroup(_ identifier: NSToolbarItem.Identifier, _ label: String, symbols: [String], labels: [String],
                               mode: NSToolbarItemGroup.SelectionMode, action: Selector) -> NSToolbarItemGroup {
            let group = NSToolbarItemGroup(itemIdentifier: identifier, images: symbols.map(symbol), selectionMode: mode,
                                           labels: labels, target: self, action: action)
            group.controlRepresentation = .expanded
            group.visibilityPriority = .high
            group.label = label
            return group
        }

        private func index(of mode: ViewMode) -> Int {
            ViewMode.allCases.firstIndex(of: mode) ?? 0
        }

        func selectViewMode(_ mode: ViewMode) {
            let wanted = index(of: mode)
            if viewGroup?.selectedIndex != wanted { viewGroup?.selectedIndex = wanted }
        }

        /// Command-F and the magnifier. The field takes focus now, so Return and Space reach it
        /// before the first character, when AppKit first reports that searching started.
        @objc func beginSearch(_ sender: Any?) {
            searchView?.expand(focus: true)
            model.textEditing = true
        }

        @objc private func navigate(_ sender: NSToolbarItemGroup) {
            let model = model
            if sender.selectedIndex == 0 { Task { await model.goBack() } } else { Task { await model.goForward() } }
        }

        @objc private func changeViewMode(_ sender: NSToolbarItemGroup) {
            let modes = ViewMode.allCases
            model.setViewMode(modes[min(max(sender.selectedIndex, 0), modes.count - 1)])
        }

        @objc private func toggleShelf(_ sender: Any?) {
            model.showsShelf.toggle()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            model.filter = field.stringValue
        }

        /// One Escape clears the text and collapses the field.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            model.filter = ""
            searchView?.collapse()
            return true
        }

        func searchFieldDidStartSearching(_ sender: NSSearchField) { model.textEditing = true }

        /// Sent when the text becomes empty, by typing or the clear button. A field still being
        /// edited keeps its focus, as Finder's does, and so keeps Return and Space; one that is
        /// not folds back to the magnifier.
        func searchFieldDidEndSearching(_ sender: NSSearchField) {
            model.filter = ""
            guard sender.currentEditor() == nil else { return }
            model.textEditing = false
            searchView?.collapse()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            model.textEditing = false
            // An empty field that loses focus folds back to the magnifier.
            if model.filter.isEmpty { searchView?.collapse() }
        }
    }
}

enum ChromeItem {
    static let backForward = NSToolbarItem.Identifier("transfer.backForward")
    static let viewMode = NSToolbarItem.Identifier("transfer.viewMode")
    static let transfers = NSToolbarItem.Identifier("transfer.transfers")
    static let search = NSToolbarItem.Identifier("transfer.search")
}

/// The split view controller. It also sets the window's toolbar, title, and frame when it lands.
@MainActor
final class ChromeController: NSSplitViewController {
    weak var coordinator: (any NSToolbarDelegate)?
    weak var model: TransferModel?
    /// Every browser window's controller, while its window is open.
    private static let live = NSHashTable<ChromeController>.weakObjects()
    private var toolbarInstalled = false
    private var pendingTitle = ""
    private var pendingSubtitle = ""
    /// Finder's faint line under the toolbar, over the content column only, shown on toolbar hover.
    private let hoverLine = HoverLine()
    private var hoverTracking: NSTrackingArea?
    var hoverLineEnabled = true {
        didSet { refreshHoverLine(animated: false) }
    }
    /// Notification observers on this controller's window, removed when the window closes.
    private var windowObservers: [any NSObjectProtocol] = []
    private var separatorObservation: NSKeyValueObservation?

    func install(sidebar: NSHostingController<AnyView>, detail: NSHostingController<AnyView>, inspector: NSHostingController<AnyView>) {
        // The split view decides the columns' sizes; the hosted SwiftUI content reports none.
        for host in [sidebar, detail, inspector] { host.sizingOptions = [] }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        // Finder's sidebar narrows to about this before a further drag snaps it closed.
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        // Holds its width while the inspector animates; else both siblings shrink and it moves.
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        // Other behaviors grow the content pane past the window on reveal, so its safe area holds
        // still and snaps to its final size on the last frame. Constraints move it every frame.
        sidebarItem.collapseBehavior = .useConstraints
        // Separators off: Finder draws none over the sidebar, and `hoverLine` covers the content.
        sidebarItem.titlebarSeparatorStyle = .none
        // Finder's content column starts below the toolbar; only the sidebar runs behind the title
        // bar. Content under the toolbar would keep the system's scroll-pocket edge showing at rest.
        detail.safeAreaRegions = []
        inspector.safeAreaRegions = []
        let detailItem = NSSplitViewItem(viewController: BelowToolbarController(hosting: detail))
        // Low enough that the content pane can absorb the whole inspector without the split view
        // ever pushing into the sidebar; one column stays visible at the minimum.
        detailItem.minimumThickness = 260
        detailItem.titlebarSeparatorStyle = .none
        // Lowest priority, so the content pane is the one that resizes for the inspector.
        detailItem.holdingPriority = NSLayoutConstraint.Priority(250)
        // The sidebar and inspector float over the content pane, which spans the whole window; the
        // regions they cover arrive as the pane's safe-area insets, animated with them. Icon and
        // list views stay inside the safe area. The column view lets its stack run under the sidebar.
        detailItem.automaticallyAdjustsSafeAreaInsets = true
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: BelowToolbarController(hosting: inspector))
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 320
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = true
        inspectorItem.titlebarSeparatorStyle = .none
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(260)
        // See the sidebar: only constraints keep the safe area moving with the inspector's edge.
        inspectorItem.collapseBehavior = .useConstraints
        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
        addSplitViewItem(inspectorItem)
        // One name for all windows, as in Finder: a new one opens with the sidebar and inspector
        // as the last left them, and the model follows via `splitViewDidResizeSubviews`.
        splitView.autosaveName = "Transfer.Split"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        hoverLine.alphaValue = 0
        view.addSubview(hoverLine, positioned: .above, relativeTo: nil)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        keepSeparatorOff()
        hideContentScrollPockets()
        let top = placeHoverLine()
        let strip = NSRect(x: 0, y: view.bounds.height - top, width: view.bounds.width, height: top)
        if hoverTracking?.rect != strip {
            if let hoverTracking { view.removeTrackingArea(hoverTracking) }
            // Enter and exit just prompt a pointer read: a dropped event (focus to another app,
            // an area rebuilt with the pointer inside) cannot leave the line stuck.
            let area = NSTrackingArea(rect: strip, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
            view.addTrackingArea(area)
            hoverTracking = area
            refreshHoverLine(animated: false)
        }
    }

    /// Just under the toolbar, from where the content pane shows (it runs under the sidebar) to the
    /// window's right edge. Returns the toolbar's height.
    @discardableResult private func placeHoverLine() -> CGFloat {
        let top = view.window?.contentView?.safeAreaInsets.top ?? 0
        let content = splitViewItems[1].viewController.view
        let x = content.convert(content.safeAreaRect, to: view).minX
        let frame = NSRect(x: x, y: view.bounds.height - top - 1, width: view.bounds.width - x, height: 1)
        if hoverLine.frame != frame { hoverLine.frame = frame }
        return top
    }

    private func pointerInToolbar() -> Bool {
        guard let window = view.window, window.isKeyWindow, let rect = hoverTracking?.rect else { return false }
        return rect.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// Shown while the pointer is in the toolbar or the inspector is out, where it marks the pane's
    /// top and fades as the inspector goes. List view has its own header line and shows none.
    private func refreshHoverLine(animated: Bool) {
        let inspectorOut = splitViewItems.count == 3 && !splitViewItems[2].isCollapsed
        let hovering = pointerInToolbar()
        let target: CGFloat = hoverLineEnabled && (hovering || inspectorOut) ? 1 : 0
        if target > 0 { placeHoverLine() }
        guard hoverLine.alphaValue != target else { return }
        guard animated else {
            hoverLine.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = target > 0 ? 0.2 : 0.35
            hoverLine.animator().alphaValue = target
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === hoverTracking else { return super.mouseEntered(with: event) }
        refreshHoverLine(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === hoverTracking else { return super.mouseExited(with: event) }
        refreshHoverLine(animated: true)
    }

    /// AppKit hangs a scroll pocket (the macOS 26 scroll-edge effect) under the toolbar over each
    /// window section. Over the content it draws a hard edge for the placeholder and the inspector
    /// and keeps it after the inspector collapses. No public switch or class exists, so each pocket
    /// right of the sidebar is hidden on sight. The sidebar keeps its own, which fades its list.
    private func hideContentScrollPockets() {
        guard let frame = view.window?.contentView?.superview, splitViewItems.count == 3 else { return }
        let sidebar = splitViewItems[0].viewController.view
        let sidebarEdge = splitViewItems[0].isCollapsed ? 0 : sidebar.convert(sidebar.bounds, to: nil).maxX
        guard let pocket = Self.scrollPocketClass else { return }
        func walk(_ v: NSView) {
            if v.isKind(of: pocket) {
                if !v.isHidden, v.convert(v.bounds, to: nil).minX >= sidebarEdge - 1 { v.isHidden = true }
                return
            }
            v.subviews.forEach(walk)
        }
        walk(frame)
    }

    /// Looked up once. A future AppKit without the class hides nothing, which only costs a line.
    private static let scrollPocketClass: AnyClass? = NSClassFromString("NSScrollPocket")

    /// SwiftUI re-applies its titlebar separator style after the window appears and around
    /// inspector and sidebar changes. Automatic draws a line under the toolbar that stays until the
    /// style is set again, so the window is watched and every layout re-asserts `.none`.
    private func keepSeparatorOff() {
        guard let window = view.window, window.titlebarSeparatorStyle != .none else { return }
        // The title bar keeps its automatic-style line until redrawn, so the whole frame redraws.
        defer { redraw(window.contentView?.superview) }
        window.titlebarSeparatorStyle = .none
    }

    private func redraw(_ view: NSView?) {
        guard let view else { return }
        view.needsDisplay = true
        view.subviews.forEach(redraw)
    }

    /// Dresses the window as the chrome lands: SwiftUI orders it in before inserting the content,
    /// but before any drawing, so toolbar, title bar, and tab group are all in the first frame.
    /// Waiting for `viewDidAppear` showed it bare and alone for frames, then tabbed, then dressed.
    func landed(in window: NSWindow) {
        guard !toolbarInstalled else { return }
        toolbarInstalled = true
        Self.live.add(self)
        separatorObservation = window.observe(\.titlebarSeparatorStyle, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.keepSeparatorOff() }
        }
        func observe(_ names: NSNotification.Name..., run: @escaping @MainActor @Sendable () -> Void) {
            for name in names {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { _ in
                    MainActor.assumeIsolated(run)
                })
            }
        }
        observe(NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification) { [weak self] in self?.refreshHoverLine(animated: true) }
        // The window posts this after every pass of event handling, so a style SwiftUI sets after
        // the last layout of an inspector animation is still caught before the next frame draws.
        observe(NSWindow.didUpdateNotification) { [weak self] in self?.keepSeparatorOff() }
        observe(NSWindow.willCloseNotification) { [weak self] in self?.windowWillClose() }
        window.tabbingMode = .preferred
        // A tab takes its window's frame; any other new window is placed.
        if !NewTab.join(window) {
            WindowFrames.place(window, among: Self.live.allObjects.compactMap { $0 === self ? nil : $0.view.window })
        }
        // Watched only once placed: a new window first becomes main at SwiftUI's default size and
        // would overwrite the saved frame. A live resize is saved once, when it ends.
        observe(NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didBecomeMainNotification) { [weak window] in
            if let window, !window.inLiveResize { WindowFrames.remember(window) }
        }
        ContentKeys.install()
        if let model { LinkInbox.take(into: model) }
        window.titlebarSeparatorStyle = .none
        // An opaque title bar draws a bottom edge in any separator style; a transparent one has
        // none, and with the full-height sidebar nothing else changes visually.
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        // Full-height sidebar: the content extends under the title bar, as in Finder.
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .visible
        let toolbar = NSToolbar(identifier: "Transfer.Toolbar")
        toolbar.delegate = coordinator
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.title = pendingTitle
        window.subtitle = pendingSubtitle
    }

    /// A closed window is no browser: links and New Tab must not pick its controller while it
    /// waits to be released, its observers must not outlive it, and its model stops its work.
    private func windowWillClose() {
        Self.live.remove(self)
        model?.close()
        separatorObservation?.invalidate()
        separatorObservation = nil
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
    }

    func setTitle(_ title: String, subtitle: String) {
        pendingTitle = title
        pendingSubtitle = subtitle
        guard let window = view.window else { return }
        keepSeparatorOff()
        if window.title != title { window.title = title }
        if window.subtitle != subtitle { window.subtitle = subtitle }
    }

    func setSidebarCollapsed(_ collapsed: Bool) {
        let item = splitViewItems[0]
        if item.isCollapsed != collapsed { animateCollapse { item.animator().isCollapsed = collapsed } }
    }

    func setInspectorShown(_ shown: Bool) {
        let item = splitViewItems[2]
        guard item.isCollapsed == shown else { return }
        animateCollapse { item.animator().isCollapsed = !shown }
        refreshHoverLine(animated: true)
    }

    /// `TRANSFER_ANIMATION_SCALE=6` stretches the sidebar and inspector animations for watching.
    private static let animationScale = Double(ProcessInfo.processInfo.environment["TRANSFER_ANIMATION_SCALE"] ?? "") ?? 1

    private func animateCollapse(_ body: @escaping () -> Void) {
        guard Self.animationScale != 1 else { return body() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25 * Self.animationScale
            body()
        }
    }

    // MARK: Edit menu

    static var keyWindowController: ChromeController? {
        guard let key = NSApp.keyWindow else { return nil }
        return live.allObjects.first { $0.view.window === key }
    }

    /// Every browser window's controller, those on screen front to back first.
    static var browsers: [ChromeController] {
        let all = live.allObjects
        let ordered = NSApp.orderedWindows.compactMap { window in all.first { $0.view.window === window } }
        return ordered + all.filter { controller in !ordered.contains { $0 === controller } }
    }

    /// Edit > Copy and Paste arrive via the responder chain unless a focused text field takes them.
    /// With no focus in the content (a folder just opened in icon view, a toolbar button focused)
    /// the chain skips this controller; the app delegate, last in it, forwards via `KeyWindowEdit`.
    @objc func copy(_ sender: Any?) {
        model?.copySelection()
    }

    @objc func paste(_ sender: Any?) {
        guard let model else { return }
        Task { await model.paste(moving: false) }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): model?.canCopy == true
        case #selector(paste(_:)): model?.canPaste == true
        default: super.validateUserInterfaceItem(item)
        }
    }

    /// The sidebar toggle and divider drags bypass the model; it follows here. `isCollapsed` takes
    /// its new value when the animation starts and holds it every frame (measured), so the echo
    /// through `setSidebarCollapsed` and `setInspectorShown` changes nothing, and a model change
    /// mid-animation (Command-B right after a toolbar toggle) simply reverses it.
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard splitViewItems.count == 3 else { return }
        if let model {
            let collapsed = splitViewItems[0].isCollapsed
            let shown = !splitViewItems[2].isCollapsed
            if model.sidebarCollapsed != collapsed { model.sidebarCollapsed = collapsed }
            if model.showsInspector != shown { model.showsInspector = shown }
        }
        keepSeparatorOff()
        hideContentScrollPockets()
        refreshHoverLine(animated: true)
    }
}

/// The line under the toolbar, colored in `updateLayer` so a light/dark switch recolors it.
final class HoverLine: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

/// Window frames as Finder keeps them. A new window opens at the size of the window used last,
/// cascaded from the front window, or where that window was when no other is open. A restored
/// window keeps its own frame, and a tab takes its window's.
///
/// No frame autosave name can do this: only one open window may hold a name, a second is refused
/// and left with none, and SwiftUI's names count windows (`browser-AppWindow-1`, `-2`, …) and open
/// at the default size. So windows drop their autosave names; the last-used frame is kept here.
@MainActor
public enum WindowFrames {
    private static let key = "transfer.windowFrame"
    /// AppKit restores windows between will- and did-finish-launching, so a window that lands
    /// before the app has finished launching is one that restoration placed.
    private static var launched = false

    /// Called from `applicationDidFinishLaunching`.
    public static func launchFinished() { launched = true }

    static func place(_ window: NSWindow, among others: [NSWindow]) {
        window.setFrameAutosaveName("")
        guard launched, (window.tabbedWindows?.count ?? 1) <= 1,
              let saved = UserDefaults.standard.string(forKey: key) else { return }
        window.setFrame(from: saved)
        let open = others.filter { $0.isVisible && !$0.isMiniaturized && !$0.styleMask.contains(.fullScreen) }
        guard let front = open.first(where: \.isMainWindow) ?? NSApp.orderedWindows.first(where: open.contains) else { return }
        // Placed at the front window's corner, then one cascade step down and to the right.
        let next = window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY))
        window.cascadeTopLeft(from: next)
    }

    static func remember(_ window: NSWindow) {
        guard window.isVisible, !window.isMiniaturized, !window.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(window.frameDescriptor, forKey: key)
    }
}

/// File > New Tab. SwiftUI opens the window, which would not become a tab by itself: its tabbing
/// mode is set only once on screen, and `newWindowForTab:` only reaches SwiftUI's window opener. So
/// the window that asked is remembered, and the next browser window to appear joins it as a tab.
@MainActor
public enum NewTab {
    private static weak var host: NSWindow?

    /// Call just before opening the window. Without a browser window in front, it is a new window.
    public static func request() {
        host = (ChromeController.keyWindowController ?? ChromeController.browsers.first)?.view.window
    }

    static func join(_ window: NSWindow) -> Bool {
        let target = host
        host = nil
        guard let target, target !== window, target.isVisible else { return false }
        target.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        return true
    }
}

/// `sftp://` links from other apps, such as a Command-click on a link a terminal shows. A link
/// opens in a browser window that shows no server yet, the key window first; otherwise in a new
/// tab of the front window. At launch it waits for the first window to appear.
@MainActor
public enum LinkInbox {
    private static var pending: [SFTPURL] = []
    /// Windows handed a link. One stays idle until login starts (after `ssh -G` and DNS), so
    /// without this a second link could pick it too and one of the two would be lost.
    private static var opening: Set<ObjectIdentifier> = []
    /// A window was asked for and none has appeared since.
    private static var requested = false
    /// Opens a new browser window. Set by each browser window as it appears, since only a view
    /// can reach SwiftUI's window opener.
    public static var openWindow: (() -> Void)?

    public static func deliver(_ link: SFTPURL) {
        NSApp.activate()
        let browsers = ChromeController.browsers
        let free = browsers.first { $0 === ChromeController.keyWindowController && isFree($0.model) }
            ?? browsers.first { isFree($0.model) }
        if let free, let model = free.model {
            free.view.window?.makeKeyAndOrderFront(nil)
            open(link, in: model)
            return
        }
        pending.append(link)
        // With no browser window open (launched by the link, or all closed), SwiftUI opens one
        // that takes the link as it appears, as may a window restored at launch. Otherwise windows
        // are requested one at a time, each asking for the next, so every link gets exactly one.
        if !requested, !browsers.isEmpty { requestWindow() }
    }

    /// A newly appeared window takes the oldest waiting link and asks for another while links wait.
    static func take(into model: TransferModel) {
        requested = false
        guard !pending.isEmpty else { return }
        if isFree(model) { open(pending.removeFirst(), in: model) }
        if !pending.isEmpty { requestWindow() }
    }

    private static func isFree(_ model: TransferModel?) -> Bool {
        guard let model else { return false }
        return model.isIdle && !opening.contains(ObjectIdentifier(model))
    }

    private static func open(_ link: SFTPURL, in model: TransferModel) {
        let id = ObjectIdentifier(model)
        opening.insert(id)
        Task {
            await model.open(link: link)
            opening.remove(id)
        }
    }

    /// A new tab of the front window, through SwiftUI's opener. Before any browser window has
    /// lent the opener there is nothing to ask; the link waits for SwiftUI's own first window.
    private static func requestWindow() {
        guard let openWindow else { return }
        requested = true
        NewTab.request()
        openWindow()
    }
}

/// Content-pane keys: Command-Down opens the selection as in Finder (a second File > Open shortcut
/// with no menu item), and Space toggles Quick Look. `NSBrowser`'s columns take Command-Down as
/// Down before the browser sees it, and each view would have to catch Space itself, so one monitor
/// watches both, as `Clipboard` does Escape.
@MainActor
enum ContentKeys {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { takes(event) } ? nil : event
        }
    }

    /// Only for the content pane or a window with nothing focused: text fields, sheets, sidebar,
    /// inspector, and non-browser windows keep the keys. Held down, a key acts once.
    private static func takes(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let open = event.keyCode == 125 && modifiers == .command
        let look = event.keyCode == 49 && modifiers.isEmpty
        guard open || look,
              let window = event.window, window.isKeyWindow, window.attachedSheet == nil, !(window.firstResponder is NSText),
              let controller = ChromeController.keyWindowController, let model = controller.model, model.plainKeysAvailable else { return false }
        if let focused = window.firstResponder as? NSView, focused !== window.contentView,
           !focused.isDescendant(of: controller.splitViewItems[1].viewController.view) { return false }
        guard !event.isARepeat else { return true }
        if open {
            Task { await model.openSelection() }
        } else {
            model.togglePreview()
        }
        return true
    }
}

/// Copy and Paste for the key window when its content holds no focus; the app delegate sends them.
@MainActor
public enum KeyWindowEdit {
    public static func copy() { ChromeController.keyWindowController?.copy(nil) }
    public static func paste() { ChromeController.keyWindowController?.paste(nil) }

    public static func canCopy() -> Bool { ChromeController.keyWindowController?.model?.canCopy == true }
    public static func canPaste() -> Bool { ChromeController.keyWindowController?.model?.canPaste == true }
}

/// Anchors the AppKit split view to the size SwiftUI assigns. SwiftUI's host view is outside the
/// constraint engine, which would otherwise size this subtree to its content; width and height
/// constraints kept equal to the frame give the engine a root to solve against.
final class ChromeContainer: NSView {
    let controller: ChromeController
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!

    init(controller: ChromeController) {
        self.controller = controller
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        let root = controller.view
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        let split = controller.splitView
        split.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthConstraint, heightConstraint,
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { controller.landed(in: window) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if widthConstraint.constant != newSize.width { widthConstraint.constant = newSize.width }
        if heightConstraint.constant != newSize.height { heightConstraint.constant = newSize.height }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layoutSubtreeIfNeeded()
    }
}

/// Holds a hosted column below the window's toolbar, leaving the title bar area empty.
@MainActor
final class BelowToolbarController: NSViewController {
    let hosting: NSViewController

    init(hosting: NSViewController) {
        self.hosting = hosting
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = BelowToolbarView(hosted: hosting.view)
        addChild(hosting)
    }
}

final class BelowToolbarView: NSView {
    init(hosted: NSView) {
        super.init(frame: .zero)
        hosted.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosted)
        // The safe-area guide follows each frame of sidebar and inspector animations; a frame set
        // in layout() would not, as AppKit calls nothing when only the safe-area insets change.
        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: guide.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The search control: a magnifier that becomes a fixed-width field on demand.
final class SearchToolbarView: NSView {
    static let collapsedWidth: CGFloat = 32
    /// Expanded, the toolbar may give the field anything in this range; it prefers the top.
    static let expandedMinWidth: CGFloat = 90
    static let expandedWidth: CGFloat = 160

    let button = NSButton()
    let field = NSSearchField()
    var onCollapse: (() -> Void)?
    /// The toolbar measures a view item once, when the view is attached. After a state change the
    /// view is attached again so the toolbar re-reads the new range and lays out for it.
    weak var item: NSToolbarItem?
    private(set) var isExpanded = false
    private var minWidth: NSLayoutConstraint!
    private var maxWidth: NSLayoutConstraint!
    private var preferredWidth: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        minWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: Self.collapsedWidth)
        maxWidth = widthAnchor.constraint(lessThanOrEqualToConstant: Self.collapsedWidth)
        preferredWidth = widthAnchor.constraint(equalToConstant: Self.collapsedWidth)
        preferredWidth.priority = .defaultLow
        button.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        button.bezelStyle = .toolbar
        button.isBordered = true
        button.toolTip = "Search the listed names"
        button.setAccessibilityLabel("Search")
        field.controlSize = .regular
        for subview in [button, field] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
            NSLayoutConstraint.activate([
                subview.leadingAnchor.constraint(equalTo: leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: trailingAnchor),
                subview.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([minWidth, maxWidth, preferredWidth, heightAnchor.constraint(equalToConstant: 28)])
        field.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func expand(focus: Bool) {
        if !isExpanded {
            isExpanded = true
            show(expanded: true)
        }
        if focus { window?.makeFirstResponder(field) }
    }

    func collapse() {
        guard isExpanded else { return }
        // First: resigning the field ends its editing, which calls collapse again.
        isExpanded = false
        field.stringValue = ""
        if window?.firstResponder === field.currentEditor() || window?.firstResponder === field {
            window?.makeFirstResponder(nil)
        }
        show(expanded: false)
        onCollapse?()
    }

    private func show(expanded: Bool) {
        button.isHidden = expanded
        field.isHidden = !expanded
        minWidth.constant = expanded ? Self.expandedMinWidth : Self.collapsedWidth
        preferredWidth.constant = expanded ? Self.expandedWidth : Self.collapsedWidth
        maxWidth.constant = expanded ? Self.expandedWidth : Self.collapsedWidth
        guard let item else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            item.view = self
        }
    }
}
