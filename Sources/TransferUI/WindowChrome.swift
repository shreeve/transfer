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
        private var searchItem: NSSearchToolbarItem?

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
                group.label = "View"
                group.selectedIndex = index(of: model.snapshot.viewMode)
                viewGroup = group
                return group
            case ChromeItem.transfers:
                let item = NSToolbarItem(itemIdentifier: identifier)
                item.image = symbol("arrow.up.arrow.down.circle")
                item.label = "Transfers"
                item.toolTip = "Show or hide transfers"
                item.isBordered = true
                item.target = self
                item.action = #selector(toggleShelf(_:))
                return item
            case ChromeItem.search:
                let item = NSSearchToolbarItem(itemIdentifier: identifier)
                item.label = "Search"
                item.preferredWidthForSearchField = 150
                item.resignsFirstResponderWithCancel = true
                item.searchField.placeholderString = "Search"
                item.searchField.delegate = self
                item.searchField.sendsSearchStringImmediately = true
                searchItem = item
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
            searchItem?.beginSearchInteraction()
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

        /// One Escape clears the text and collapses the field, rather than the item's two-step.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            model.filter = ""
            searchItem?.searchField.stringValue = ""
            searchItem?.endSearchInteraction()
            control.window?.makeFirstResponder(nil)
            return true
        }

        func searchFieldDidStartSearching(_ sender: NSSearchField) { model.textEditing = true }

        func searchFieldDidEndSearching(_ sender: NSSearchField) {
            model.textEditing = false
            model.filter = ""
        }

        func controlTextDidEndEditing(_ notification: Notification) { model.textEditing = false }
    }
}

enum ChromeItem {
    static let backForward = NSToolbarItem.Identifier("transfer.backForward")
    static let viewMode = NSToolbarItem.Identifier("transfer.viewMode")
    static let transfers = NSToolbarItem.Identifier("transfer.transfers")
    static let search = NSToolbarItem.Identifier("transfer.search")
}

/// The split view controller. It also owns the window's toolbar, title, and frame autosave,
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
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        // Finder draws no line under the title bar over the sidebar, and over the content only
        // on hover, which the hover line handles. The built-in separators stay off.
        sidebarItem.titlebarSeparatorStyle = .none
        // Finder's content column starts below the toolbar; only the sidebar runs behind the title
        // bar. Content under the toolbar would keep the system's scroll-pocket edge showing at rest.
        detail.safeAreaRegions = []
        inspector.safeAreaRegions = []
        let detailItem = NSSplitViewItem(viewController: BelowToolbarController(hosting: detail))
        detailItem.minimumThickness = 420
        detailItem.titlebarSeparatorStyle = .none
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: BelowToolbarController(hosting: inspector))
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 320
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = true
        inspectorItem.titlebarSeparatorStyle = .none
        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
        addSplitViewItem(inspectorItem)
        splitView.autosaveName = "Transfer.Split"
    }

    /// Finder shows a faint line under the toolbar, over the content column only, while the
    /// pointer is in the toolbar. This is that line.
    private let hoverLine = NSView()
    private var hoverTracking: NSTrackingArea?
    var hoverLineEnabled = true {
        didSet { if !hoverLineEnabled { hoverLine.alphaValue = 0 } }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        hoverLine.wantsLayer = true
        hoverLine.alphaValue = 0
        view.addSubview(hoverLine, positioned: .above, relativeTo: nil)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let top = view.window?.contentView?.safeAreaInsets.top ?? 0
        let content = splitViewItems[1].viewController.view
        let x = content.convert(content.bounds, to: view).minX
        hoverLine.frame = NSRect(x: x, y: view.bounds.height - top - 1, width: view.bounds.width - x, height: 1)
        let strip = NSRect(x: 0, y: view.bounds.height - top, width: view.bounds.width, height: top)
        if hoverTracking?.rect != strip {
            if let hoverTracking { view.removeTrackingArea(hoverTracking) }
            let area = NSTrackingArea(rect: strip, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
            view.addTrackingArea(area)
            hoverTracking = area
            // A new tracking area drops the pending exit event; follow the pointer's real position.
            setHoverLine(visible: pointerInToolbar(), animated: false)
        }
    }

    private func pointerInToolbar() -> Bool {
        guard let window = view.window, window.isKeyWindow, let rect = hoverTracking?.rect else { return false }
        return rect.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func setHoverLine(visible: Bool, animated: Bool) {
        let target: CGFloat = visible && hoverLineEnabled ? 1 : 0
        guard hoverLine.alphaValue != target else { return }
        hoverLine.layer?.backgroundColor = NSColor.separatorColor.cgColor
        guard animated else {
            hoverLine.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.2 : 0.35
            hoverLine.animator().alphaValue = target
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === hoverTracking else { return super.mouseEntered(with: event) }
        setHoverLine(visible: true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === hoverTracking else { return super.mouseExited(with: event) }
        setHoverLine(visible: false, animated: true)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window, !toolbarInstalled else { return }
        toolbarInstalled = true
        window.setFrameAutosaveName("Transfer.Browser")
        window.tabbingMode = .preferred
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
        // SwiftUI re-applies its own separator style after the window appears; keep it off.
        if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        if window.title != title { window.title = title }
        if window.subtitle != subtitle { window.subtitle = subtitle }
    }

    private var toggling = false

    func setSidebarCollapsed(_ collapsed: Bool) {
        guard !toggling else { return }
        let item = splitViewItems[0]
        if item.isCollapsed != collapsed { item.animator().isCollapsed = collapsed }
    }

    func setInspectorShown(_ shown: Bool) {
        let item = splitViewItems[2]
        if item.isCollapsed == shown { item.animator().isCollapsed = !shown }
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
        hosted.translatesAutoresizingMaskIntoConstraints = true
        hosted.autoresizingMask = [.width, .height]
        addSubview(hosted)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let inset = window?.contentView?.safeAreaInsets.top ?? 0
        let frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height - inset, 0))
        if hosted.frame != frame { hosted.frame = frame }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }
}
