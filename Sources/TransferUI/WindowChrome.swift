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
        controller.sidebarToggled = { [weak coordinator = context.coordinator] collapsed in
            if coordinator?.model.sidebarCollapsed != collapsed { coordinator?.model.sidebarCollapsed = collapsed }
        }
        controller.inspectorToggled = { [weak coordinator = context.coordinator] shown in
            if coordinator?.model.showsInspector != shown { coordinator?.model.showsInspector = shown }
        }
        let container = ChromeContainer(controller: controller)
        apply(to: controller, context: context)
        return container
    }

    /// The hosted columns observe the model on their own, so they are never re-hosted here;
    /// only the chrome's own state is applied.
    func updateNSView(_ container: ChromeContainer, context: Context) {
        context.coordinator.model = model
        apply(to: container.controller, context: context)
    }

    /// The chrome fills whatever the window offers.
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
            context.coordinator.beginSearch()
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
                let group = NSToolbarItemGroup(
                    itemIdentifier: identifier,
                    images: [symbol("chevron.backward"), symbol("chevron.forward")],
                    selectionMode: .momentary,
                    labels: ["Back", "Forward"],
                    target: self,
                    action: #selector(navigate(_:))
                )
                group.isNavigational = true
                group.controlRepresentation = .expanded
                group.visibilityPriority = .high
                group.label = "Back/Forward"
                return group
            case ChromeItem.viewMode:
                let group = NSToolbarItemGroup(
                    itemIdentifier: identifier,
                    images: [symbol("square.grid.2x2"), symbol("list.bullet"), symbol("rectangle.split.3x1")],
                    selectionMode: .selectOne,
                    labels: ["Icons", "List", "Columns"],
                    target: self,
                    action: #selector(changeViewMode(_:))
                )
                group.controlRepresentation = .expanded
                group.visibilityPriority = .high
                group.label = "View"
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
                // Two fixed sizes, magnifier or field, changed only by the user. The system search
                // item resizes itself whenever the toolbar's free space changes and shoves the
                // other items in and out of the overflow menu as it does.
                let item = NSToolbarItem(itemIdentifier: identifier)
                let view = SearchToolbarView()
                view.field.placeholderString = "Search"
                view.field.delegate = self
                view.field.sendsSearchStringImmediately = true
                view.button.target = self
                view.button.action = #selector(expandSearch(_:))
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

        private func index(of mode: ViewMode) -> Int {
            ViewMode.allCases.firstIndex(of: mode) ?? 0
        }

        func selectViewMode(_ mode: ViewMode) {
            let wanted = index(of: mode)
            if viewGroup?.selectedIndex != wanted { viewGroup?.selectedIndex = wanted }
        }

        func beginSearch() {
            searchView?.expand(focus: true)
        }

        @objc private func expandSearch(_ sender: Any?) {
            searchView?.expand(focus: true)
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

        func searchFieldDidEndSearching(_ sender: NSSearchField) {
            model.textEditing = false
            model.filter = ""
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

/// The split view controller. It also owns the window's toolbar, title, and frame placement,
/// which it applies when it lands in a window.
@MainActor
final class ChromeController: NSSplitViewController {
    weak var coordinator: (any NSToolbarDelegate)?
    private var toolbarInstalled = false
    private var pendingTitle = ""
    private var pendingSubtitle = ""

    func install(sidebar: NSHostingController<AnyView>, detail: NSHostingController<AnyView>, inspector: NSHostingController<AnyView>) {
        // The split view decides the columns' sizes; the hosted SwiftUI content reports none.
        for host in [sidebar, detail, inspector] {
            host.sizingOptions = []
        }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        // Finder's sidebar narrows to about this before a further drag snaps it closed.
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        // The sidebar holds its width while the inspector animates; only the content pane gives up
        // space. Without this the split view shrinks both siblings and the sidebar appears to move.
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        // Collapse and reveal by constraint animation alone. With the other behaviors a reveal
        // grows the content pane's frame past the window, so the pane's safe area holds still and
        // snaps to its final size on the last frame; with constraints it moves on every frame.
        sidebarItem.collapseBehavior = .useConstraints
        // Finder draws no line under the title bar over the sidebar, and over the content only
        // on hover, which the hover line handles. The built-in separators stay off.
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
        // Same as the sidebar: only the constraint animation keeps the content pane's safe area
        // moving in step with the inspector's edge while it opens.
        inspectorItem.collapseBehavior = .useConstraints
        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
        addSplitViewItem(inspectorItem)
        splitView.autosaveName = "Transfer.Split"
    }

    /// Finder shows a faint line under the toolbar, over the content column only, while the
    /// pointer is in the toolbar. This is that line.
    private let hoverLine = NSView()
    private var hoverTracking: NSTrackingArea?
    private var keyObservers: [any NSObjectProtocol] = []
    var hoverLineEnabled = true {
        didSet { refreshHoverLine(animated: false) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        hoverLine.wantsLayer = true
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
            // Enter and exit only prompt a fresh look at where the pointer is; they carry no state
            // of their own, so a dropped event (another app taking focus, a tracking area rebuilt
            // with the pointer already inside) cannot leave the line stuck.
            let area = NSTrackingArea(rect: strip, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
            view.addTrackingArea(area)
            hoverTracking = area
            refreshHoverLine(animated: false)
        }
    }

    /// Just under the toolbar, from the content pane's visible edge to the window's right edge.
    /// The content pane spans the window under the sidebar; the line starts where the pane shows.
    /// Returns the toolbar's height.
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

    /// The line shows while the pointer is in the toolbar, and for as long as the inspector is
    /// out, where it marks the top of the pane the inspector sits beside; it fades with the
    /// inspector as that is dismissed. List view has its own header line and shows none.
    private func refreshHoverLine(animated: Bool) {
        let inspectorOut = splitViewItems.count == 3 && !splitViewItems[2].isCollapsed
        let hovering = pointerInToolbar()
        let target: CGFloat = hoverLineEnabled && (hovering || inspectorOut) ? 1 : 0
        if target > 0 { placeHoverLine() }
        guard hoverLine.alphaValue != target else { return }
        hoverLine.layer?.backgroundColor = NSColor.separatorColor.cgColor
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

    /// SwiftUI re-applies its own titlebar separator style to the window after it appears and
    /// again around inspector and sidebar changes. Automatic draws a line under the toolbar that
    /// then stays until something sets the style again, so the window is watched and every
    /// layout re-asserts none. The hover line is the only line under the toolbar.
    private var separatorObservation: NSKeyValueObservation?
    private var separatorUpdateObserver: (any NSObjectProtocol)?


    /// AppKit hangs a scroll pocket, the macOS 26 scroll-edge effect, under the toolbar over each
    /// section of the window. Over the content section it draws a hard edge for the placeholder
    /// screen and for the inspector, and keeps that edge after the inspector collapses; it has no
    /// public switch and no public class. The hover line is the only line under the toolbar, so
    /// every pocket right of the sidebar is hidden as soon as it appears. The sidebar keeps its
    /// own, which fades its list under the toolbar.
    private func hideContentScrollPockets() {
        guard let frame = view.window?.contentView?.superview, splitViewItems.count == 3 else { return }
        let sidebar = splitViewItems[0].viewController.view
        let sidebarEdge = splitViewItems[0].isCollapsed ? 0 : sidebar.convert(sidebar.bounds, to: nil).maxX
        func walk(_ v: NSView) {
            if String(describing: type(of: v)) == "NSScrollPocket" {
                if !v.isHidden, v.convert(v.bounds, to: nil).minX >= sidebarEdge - 1 { v.isHidden = true }
                return
            }
            v.subviews.forEach(walk)
        }
        walk(frame)
    }

    private func keepSeparatorOff() {
        guard let window = view.window, window.titlebarSeparatorStyle != .none else { return }
        // The title bar keeps the line it drew under the automatic style until it draws again;
        // nothing else makes it, so the whole frame is asked to.
        defer { redraw(window.contentView?.superview) }
        window.titlebarSeparatorStyle = .none
    }

    private func redraw(_ view: NSView?) {
        guard let view else { return }
        view.needsDisplay = true
        view.subviews.forEach(redraw)
    }

    /// Dresses the window the moment the chrome lands in it. SwiftUI orders a new window in before
    /// it inserts the content, but nothing has been drawn yet, so the toolbar, the title bar, and a
    /// new tab's place in its group are all in the first frame. Waiting for `viewDidAppear` showed
    /// the window bare and on its own for a few frames, then tabbed, then with its toolbar.
    func landed(in window: NSWindow) {
        guard !toolbarInstalled else { return }
        toolbarInstalled = true
        Self.live.add(self)
        separatorObservation = window.observe(\.titlebarSeparatorStyle, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.keepSeparatorOff() }
        }
        // The window posts this after every pass of event handling, so a style SwiftUI sets after
        // the last layout of an inspector animation is still caught before the next frame draws.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshHoverLine(animated: true) }
            })
        }
        separatorUpdateObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepSeparatorOff() }
        }
        window.tabbingMode = .preferred
        // A tab takes its window's frame; any other new window is placed.
        if !NewTab.join(window) {
            WindowFrames.place(window, among: Self.live.allObjects.compactMap { $0 === self ? nil : $0.view.window })
        }
        // Watched only once placed: a new window becomes main at SwiftUI's default size first,
        // which would otherwise replace the last-used frame it is about to take.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didBecomeMainNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { [weak window] _ in
                MainActor.assumeIsolated { if let window { WindowFrames.remember(window) } }
            })
        }
        ContentKeys.install()
        if let model { LinkInbox.take(into: model) }
        window.titlebarSeparatorStyle = .none
        // The opaque title bar over the content column draws its own bottom edge regardless of
        // the separator style; a transparent title bar has no edge, and the sidebar is already
        // full height, so nothing changes visually except the line going away.
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

    func setTitle(_ title: String, subtitle: String) {
        pendingTitle = title
        pendingSubtitle = subtitle
        guard let window = view.window else { return }
        keepSeparatorOff()
        if window.title != title { window.title = title }
        if window.subtitle != subtitle { window.subtitle = subtitle }
    }

    private var toggling = false

    func setSidebarCollapsed(_ collapsed: Bool) {
        guard !toggling else { return }
        let item = splitViewItems[0]
        if item.isCollapsed != collapsed { animateCollapse { item.animator().isCollapsed = collapsed } }
    }

    func setInspectorShown(_ shown: Bool) {
        let item = splitViewItems[2]
        guard item.isCollapsed == shown else { return }
        animateCollapse { item.animator().isCollapsed = !shown }
        refreshHoverLine(animated: true)
    }

    /// `TRANSFER_ANIMATION_SCALE=8` in the environment stretches the sidebar and inspector
    /// animations for watching them; unset, AppKit's own timing applies.
    private static let animationScale = Double(ProcessInfo.processInfo.environment["TRANSFER_ANIMATION_SCALE"] ?? "") ?? 1

    private func animateCollapse(_ body: @escaping () -> Void) {
        guard Self.animationScale != 1 else { return body() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25 * Self.animationScale
            body()
        }
    }

    // MARK: Edit menu

    /// Edit > Copy and Paste reach the window here through the responder chain whenever no text
    /// field has focus; a focused field answers them first and keeps its own text editing. When
    /// nothing in the content holds the focus (a folder just opened in icon view, or a toolbar
    /// button has it), the chain skips this controller, and the app delegate, last in the chain,
    /// forwards them here through `KeyWindowEdit`.
    weak var model: TransferModel?

    private static let live = NSHashTable<ChromeController>.weakObjects()

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

    /// Set by the coordinator so the model follows the toolbar's sidebar toggle and divider drags.
    var sidebarToggled: ((Bool) -> Void)?
    var inspectorToggled: ((Bool) -> Void)?

    /// A divider drag can collapse or reveal a column without any toggle; the model is told.
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard !toggling, splitViewItems.count == 3 else { return }
        sidebarToggled?(splitViewItems[0].isCollapsed)
        inspectorToggled?(!splitViewItems[2].isCollapsed)
        keepSeparatorOff()
        hideContentScrollPockets()
        refreshHoverLine(animated: true)
    }

    /// The toolbar's sidebar toggle sends this through the responder chain. The model is told,
    /// and its echo is ignored until AppKit's animation has finished.
    override func toggleSidebar(_ sender: Any?) {
        toggling = true
        super.toggleSidebar(sender)
        sidebarToggled?(splitViewItems[0].isCollapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.toggling = false }
    }
}

/// Window frames as Finder keeps them. A new window opens at the size of the window used last,
/// cascaded from the front window, or where that window was when no other is open. A window that
/// state restoration brings back keeps its own frame, and a tab takes its window's.
///
/// One frame autosave name cannot serve this: only one open window may hold a name, and a second
/// window that asks for it is refused and left with none. SwiftUI's own names count windows
/// (`browser-AppWindow-1`, `-2`, …) and open a new window at the scene's default size. So every
/// browser window drops its autosave name, and the frame of the window used last is kept here
/// under one key.
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

/// File > New Tab. SwiftUI opens the new window, and it would not become a tab on its own: its
/// tabbing mode is set only once it is on screen, and `newWindowForTab:` only reaches SwiftUI's
/// window opener. So the browser window that asked is remembered, and the next browser window
/// to appear joins it as a tab.
@MainActor
public enum NewTab {
    private static weak var host: NSWindow?

    /// Call just before opening the window. Without a browser window in front, it is a new window.
    public static func request() {
        host = (ChromeController.keyWindowController ?? ChromeController.browsers.first)?.view.window
    }

    static func join(_ window: NSWindow) -> Bool {
        guard let target = host, target !== window, target.isVisible else {
            host = nil
            return false
        }
        host = nil
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
    /// Windows a link has been handed to. A window stays idle until its login starts, which is
    /// after `ssh -G` and a DNS lookup, so without this a second link could pick it too and one
    /// of the two would be lost.
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
        // With no browser window open (launched by the link, or every window closed), SwiftUI
        // opens one for the link itself, and it takes the link as it appears; so may a window
        // restored at launch. Otherwise one window is asked for at a time, and each that appears
        // asks for the next, so every link gets exactly one.
        if !requested, !browsers.isEmpty { requestWindow() }
    }

    /// A browser window that just appeared takes the oldest waiting link, and asks for another
    /// window while links still wait.
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

/// Keys that act on the content pane: Command-Down opens the selection, as in Finder (a second
/// shortcut for File > Open, with no menu item of its own), and Space toggles Quick Look.
/// `NSBrowser`'s columns take Command-Down as a plain Down arrow before the browser sees the key,
/// and the table, the browser, and the icon grid would each have to catch Space for themselves, so
/// both are watched here with one monitor, as Escape is in `Clipboard`.
@MainActor
enum ContentKeys {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { takes(event) } ? nil : event
        }
    }

    /// Only for the content pane in any view, or a window with nothing focused: text fields,
    /// sheets, the sidebar, the inspector, and windows that are not browsers keep the keys.
    /// Held down, a key acts once.
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

/// Copy and Paste for the key window when its content holds no focus. The app delegate, last in
/// the responder chain, sends them here.
@MainActor
public enum KeyWindowEdit {
    public static func copy() { ChromeController.keyWindowController?.copy(nil) }
    public static func paste() { ChromeController.keyWindowController?.paste(nil) }

    public static func canCopy() -> Bool { ChromeController.keyWindowController?.model?.canCopy == true }
    public static func canPaste() -> Bool { ChromeController.keyWindowController?.model?.canPaste == true }
}

/// Anchors the AppKit split view to the size SwiftUI assigns. SwiftUI's host view is not part
/// of the constraint engine, so the engine would otherwise size this subtree to its content.
/// Explicit width and height constraints on the container, kept equal to its frame, give the
/// engine a root to solve against.
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
    let hosted: NSView

    init(hosted: NSView) {
        self.hosted = hosted
        super.init(frame: .zero)
        hosted.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosted)
        // The safe area is what no toolbar, sidebar, or inspector covers. Constraints to its guide
        // follow it frame by frame through those animations; a frame set in layout() would not,
        // because AppKit gives a view no callback when only its safe-area insets change.
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
        guard !isExpanded else {
            if focus { window?.makeFirstResponder(field) }
            return
        }
        isExpanded = true
        button.isHidden = true
        field.isHidden = false
        minWidth.constant = Self.expandedMinWidth
        preferredWidth.constant = Self.expandedWidth
        maxWidth.constant = Self.expandedWidth
        remeasure()
        if focus { window?.makeFirstResponder(field) }
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        field.stringValue = ""
        if window?.firstResponder === field.currentEditor() || window?.firstResponder === field {
            window?.makeFirstResponder(nil)
        }
        field.isHidden = true
        button.isHidden = false
        minWidth.constant = Self.collapsedWidth
        preferredWidth.constant = Self.collapsedWidth
        maxWidth.constant = Self.collapsedWidth
        remeasure()
        onCollapse?()
    }

    private func remeasure() {
        guard let item else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            item.view = self
        }
    }
}

