import AppKit
import SwiftUI
import TransferCore
import UniformTypeIdentifiers

/// The column view. It reads `TransferModel` state and owns none of it.
struct ColumnBrowser: NSViewRepresentable {
    var model: TransferModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> ColumnStack {
        let browser = TiledBrowser()
        browser.model = model
        browser.setCellClass(CenteredBrowserCell.self)
        browser.delegate = context.coordinator
        browser.target = context.coordinator
        browser.action = #selector(Coordinator.selectionChanged(_:))
        browser.doubleAction = #selector(Coordinator.doubleClicked(_:))
        browser.sendsActionOnArrowKeys = true
        browser.allowsMultipleSelection = true
        browser.columnResizingType = .userColumnResizing
        browser.minColumnWidth = 180
        browser.setDefaultColumnWidth(TiledBrowser.columnWidth)
        browser.isTitled = false
        browser.registerForDraggedTypes([.fileURL, remoteDragType])
        browser.setDraggingSourceOperationMask(.copy, forLocal: false)
        browser.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        // The stack keeps the browser at least as wide as its columns, so it never scrolls sideways.
        browser.hasHorizontalScroller = false
        let menu = NSMenu()
        menu.delegate = context.coordinator
        browser.menu = menu
        let stack = ColumnStack(browser: browser)
        context.coordinator.browser = browser
        context.coordinator.stack = stack
        return stack
    }

    func updateNSView(_ stack: ColumnStack, context: Context) {
        context.coordinator.model = model
        context.coordinator.sync(stack.browser)
        stack.needsLayout = true
    }

    @MainActor
    final class Coordinator: NSObject, NSBrowserDelegate, NSMenuDelegate {
        var model: TransferModel
        weak var browser: NSBrowser?
        weak var stack: ColumnStack?
        private var root: RemotePath?
        /// What each loaded column shows, by folder, and the only listing the browser's callbacks
        /// read. `sync` fills it from the model and reloads a column exactly when its entry
        /// changes, so every row AppKit asks about is a row the column was loaded with, and a
        /// folder is sorted once per change instead of once for every row asked for.
        private var shown: [RemotePath: [RemoteItem]] = [:]
        private var syncing = false

        init(model: TransferModel) { self.model = model }

        /// Reloads only the columns whose listing changed, then puts back what the reload dropped.
        func sync(_ browser: NSBrowser) {
            let newRoot = model.columnRoot ?? model.snapshot.path
            syncing = true
            defer { syncing = false }
            var trail: [ColumnTrail.Column]?
            if root != newRoot {
                // A new root rebuilds every column, so each one takes its selection from the
                // trail below, exactly as after a reload; otherwise a view switch, a link to a
                // file, or Back showed nothing selected.
                root = newRoot
                showsUpEntry = newRoot.parent != nil
                shown = [newRoot: listing(newRoot)]
                browser.loadColumnZero()
                trail = ColumnTrail.columns(root: newRoot, path: model.snapshot.path, selection: model.snapshot.selection)
            }
            // Reloading a column makes it the last one and drops its selection, so a change to any
            // column but the last (a move out of the parent folder, say) left the location's column
            // gone and nothing selected while the model still stood in it. From the first reloaded
            // column on, each column takes its selection back from the model's trail, which brings
            // back the column after it.
            //
            // The last column is read again on every pass. Asking the browser about a column it no
            // longer has throws an Objective-C exception inside SwiftUI's update; AppKit catches it,
            // but the unwinding leaves the main thread's observation tracking dangling, and the next
            // observable read crashes.
            var loaded: Set<RemotePath> = []
            var column = 0
            while column <= max(browser.lastColumn, 0) {
                let path = self.path(forColumn: column) ?? newRoot
                let current = listing(path)
                if shown[path] != current {
                    shown[path] = current
                    browser.reloadColumn(column)
                    // Every later column is then rebuilt below from listings read in this pass,
                    // so the rows selected in it are rows it has.
                    if browser.lastColumn > column { browser.lastColumn = column }
                    if trail == nil {
                        trail = ColumnTrail.columns(root: newRoot, path: model.snapshot.path, selection: model.snapshot.selection)
                    }
                }
                loaded.insert(path)
                if let trail { restoreSelection(browser, column: column, folder: path, items: current, trail: trail) }
                column += 1
            }
            // A folder whose column closed is read from the model afresh when it opens again.
            shown = shown.filter { loaded.contains($0.key) }
        }

        /// Selects in `column` what the trail selects there, when the column still shows the
        /// trail's folder. A single folder selected gets its column after this one.
        private func restoreSelection(_ browser: NSBrowser, column: Int, folder: RemotePath, items: [RemoteItem], trail: [ColumnTrail.Column]) {
            guard column <= browser.lastColumn, column < trail.count, trail[column].folder == folder else { return }
            let wanted = trail[column].selected
            let offset = hasUpEntry(folder) ? 1 : 0
            let indexes = items.indices.filter { wanted.contains(items[$0].path) }
            let rows = IndexSet(indexes.map { $0 + offset })
            if browser.selectedRowIndexes(inColumn: column) != rows {
                browser.selectRowIndexes(rows, inColumn: column)
            }
            let opens = indexes.count == 1 && items[indexes[0]].kind == .directory
            if opens {
                if browser.lastColumn == column { browser.addColumn() }
            } else if browser.lastColumn > column {
                browser.lastColumn = column
            }
        }

        /// The folder `column` shows, or nil for a column the browser does not have. Column −1,
        /// which AppKit proposes for the area beyond the columns, is no column.
        private func path(forColumn column: Int) -> RemotePath? {
            guard let browser, column >= 0 else { return nil }
            if column == 0 { return root }
            guard column <= browser.lastColumn else { return nil }
            guard let parent = browser.parentForItems(inColumn: column) as? RemoteItem else { return nil }
            return parent.path
        }

        // MARK: Items

        func rootItem(for browser: NSBrowser) -> Any? {
            root ?? model.snapshot.path
        }

        /// The `..` row at the top of the first column, shown whenever the folder has a parent.
        /// `showsUpEntry` is a plain flag set during sync: AppKit asks for row heights inside its
        /// layout pass, and touching observable model state there is not safe.
        private let upEntry = UpEntry()
        private var showsUpEntry = false

        private func hasUpEntry(_ path: RemotePath) -> Bool {
            showsUpEntry && path == root
        }

        /// What `child:ofItem:` answers for an index the folder does not have. AppKit asks about
        /// row −1 while a drop is proposed between rows (measured); the answer is never drawn.
        private static let noItem = RemoteItem(path: RemotePath(string: "/"), kind: .other)

        /// A folder's rows as its column was loaded. The browser opens a clicked folder's column
        /// before the model hears of the click, so a folder not shown yet is read once from the model.
        private func entries(_ path: RemotePath) -> [RemoteItem] {
            if let list = shown[path] { return list }
            let list = listing(path)
            shown[path] = list
            return list
        }

        /// The rows of `column`, or nil for a column the browser does not have. Every index AppKit
        /// hands a callback is checked here, before the browser is asked anything about it:
        /// `item(atRow:inColumn:)` throws for column −1 and for a column past `lastColumn`, and
        /// forwards row −1 to `child:ofItem:`.
        private func rows(ofColumn column: Int) -> (up: Bool, items: [RemoteItem])? {
            guard let browser, column >= 0, column <= browser.lastColumn, let folder = path(forColumn: column) else { return nil }
            return (hasUpEntry(folder), entries(folder))
        }

        /// The `..` entry, a `RemoteItem`, or nil for a row or column that is not there.
        private func entry(row: Int, column: Int) -> Any? {
            guard row >= 0, let (up, items) = rows(ofColumn: column) else { return nil }
            let index = up ? row - 1 : row
            if index < 0 { return upEntry }
            return index < items.count ? items[index] : nil
        }

        func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
            let path = path(of: item)
            return entries(path).count + (hasUpEntry(path) ? 1 : 0)
        }

        func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
            let path = path(of: item)
            var index = index
            if hasUpEntry(path) {
                if index == 0 { return upEntry }
                index -= 1
            }
            let list = entries(path)
            return list.indices.contains(index) ? list[index] : Self.noItem
        }

        func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
            guard let item = item as? RemoteItem else { return true }
            return item.kind != .directory
        }

        func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
            if item is UpEntry { return ".." }
            return (item as? RemoteItem)?.name ?? ""
        }

        func browser(_ browser: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
            guard let cell = cell as? NSBrowserCell else { return }
            let entry = entry(row: row, column: column)
            cell.image = entry is UpEntry ? ItemIcon.upImage : (entry as? RemoteItem).map(ItemIcon.image(for:))
        }

        /// The `..` row is as tall as the list view's column header, so the rows beneath it sit
        /// on the same lines as in list view and switching views does not shift them.
        func browser(_ browser: NSBrowser, heightOfRow row: Int, inColumn columnIndex: Int) -> CGFloat {
            row == 0 && columnIndex == 0 && showsUpEntry ? 28 : 22
        }

        func browser(_ browser: NSBrowser, shouldEditItem item: Any?) -> Bool { false }

        private func path(of item: Any?) -> RemotePath {
            if let remote = item as? RemoteItem { return remote.path }
            if let remote = item as? RemotePath { return remote }
            return root ?? model.snapshot.path
        }

        /// The model's listing of a folder in column order. Read only by `sync` and for a folder
        /// not shown yet, never per row.
        private func listing(_ path: RemotePath) -> [RemoteItem] {
            if let cached = model.columnItems(path) { return cached }
            // Called from inside SwiftUI's update pass; the listing starts on the next turn.
            let model = model
            Task { @MainActor in model.loadColumn(path) }
            return []
        }

        /// A column added, removed, or resized changes the stack's width; the stack re-places it.
        func browser(_ browser: NSBrowser, didChangeLastColumn oldLastColumn: Int, toColumn column: Int) {
            stack?.needsLayout = true
        }

        func browserColumnConfigurationDidChange(_ notification: Notification) {
            stack?.needsLayout = true
        }

        // MARK: Selection

        @objc func selectionChanged(_ sender: Any?) {
            guard !syncing, let browser else { return }
            let column = browser.selectedColumn
            guard let (up, list) = rows(ofColumn: column) else { return }
            let selected = browser.selectedRowIndexes(inColumn: column) ?? IndexSet()
            if up, selected.contains(0) {
                let model = model
                Task { await model.goParent() }
                return
            }
            let offset = up ? 1 : 0
            let items = selected.compactMap { list.indices.contains($0 - offset) ? list[$0 - offset] : nil }
            let parent = path(forColumn: column) ?? model.snapshot.path
            model.selectInColumns(items, parent: parent)
        }

        // MARK: Context menu

        /// The right-clicked row joins the selection first, as a click would select it, so every
        /// entry acts on what the menu was opened over. The `..` row and the empty area below the
        /// rows get the folder's menu.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let browser else { return }
            let column = browser.clickedColumn
            let row = browser.clickedRow
            var clicked: RemoteItem?
            if let item = entry(row: row, column: column) as? RemoteItem {
                clicked = item
                if !model.snapshot.selection.contains(item.path) {
                    if browser.lastColumn > column { browser.lastColumn = column }
                    browser.selectRowIndexes(IndexSet(integer: row), inColumn: column)
                    if item.kind == .directory { browser.addColumn() }
                    selectionChanged(nil)
                }
            }
            ItemMenu.fill(menu, item: clicked, model: model)
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let browser else { return }
            let column = browser.selectedColumn
            guard column >= 0, column <= browser.lastColumn,
                  let item = entry(row: browser.selectedRow(inColumn: column), column: column) as? RemoteItem
            else { return }
            let model = model
            Task { await model.open(item) }
        }

        // MARK: Drag out

        func browser(_ browser: NSBrowser, canDragRowsWith rowIndexes: IndexSet, inColumn column: Int, with event: NSEvent) -> Bool {
            return model.session != nil
        }

        func browser(_ browser: NSBrowser, pasteboardWriterForRow row: Int, column: Int) -> (any NSPasteboardWriting)? {
            guard let session = model.session, let item = entry(row: row, column: column) as? RemoteItem else { return nil }
            return RemoteItemPromise.provider(for: item, among: model.dragItems(including: item), session: session, prompts: model.operationPrompts())
        }

        // MARK: Drop in

        func browser(
            _ browser: NSBrowser,
            validateDrop info: any NSDraggingInfo,
            proposedRow row: UnsafeMutablePointer<Int>,
            column: UnsafeMutablePointer<Int>,
            dropOperation: UnsafeMutablePointer<NSBrowser.DropOperation>
        ) -> NSDragOperation {
            // The browser's own empty area, outside every column, is no target for its own drag:
            // answering it with an operation makes NSBrowser cancel a drag that crosses it on the
            // way out to Finder. Files arriving from elsewhere still drop there, into this folder.
            if column.pointee < 0, RemoteDragPayload.read(from: info.draggingPasteboard) != nil { return [] }
            guard let connection = model.snapshot.connectionID else { return [] }
            // A folder row is the target only for a drop on it; between rows means the column's folder.
            if let target = entry(row: row.pointee, column: column.pointee) as? RemoteItem, target.kind == .directory {
                dropOperation.pointee = .on
            } else {
                row.pointee = -1
                dropOperation.pointee = .on
            }
            guard let folder = dropFolder(row: row.pointee, column: column.pointee) else { return [] }
            return dropAction(from: info.draggingPasteboard, onto: folder, connection: connection)?.operation ?? []
        }

        func browser(_ browser: NSBrowser, acceptDrop info: any NSDraggingInfo, atRow row: Int, column: Int, dropOperation: NSBrowser.DropOperation) -> Bool {
            guard let connection = model.snapshot.connectionID,
                  let folder = dropFolder(row: row, column: column),
                  let action = dropAction(from: info.draggingPasteboard, onto: folder, connection: connection) else { return false }
            let model = model
            Task { await model.perform(action) }
            return true
        }

        private func dropFolder(row: Int, column: Int) -> RemotePath? {
            if let item = entry(row: row, column: column) as? RemoteItem, item.kind == .directory {
                return item.path
            }
            return column >= 0 ? path(forColumn: column) : root
        }
    }
}

/// The `..` row's item in the column view.
final class UpEntry: NSObject {}

/// Places the browser so its right edge sits on this view's right edge and its width is never
/// less than its columns, so the browser itself never scrolls sideways. When the columns are wider
/// than this view, the stack begins left of it, under the floating sidebar, which the split view
/// draws on top. This view's bounds are the visible region, the content pane's safe area, so each
/// frame of the inspector or sidebar animation arrives as a new width and the whole stack moves
/// as one piece: still while the columns fit, then abutting the inspector once they do not.
///
/// Columns left of the visible region are reached by panning the whole stack to the right, with
/// Shift and a mouse wheel or a sideways swipe (`ColumnPan`), as far as the first column's left
/// edge. A column that appears or resizes slides the stack back to rest.
final class ColumnStack: NSView {
    let browser: TiledBrowser
    private var lastWidth: CGFloat = 0
    private var lastColumns: CGFloat = 0
    /// How far right of its resting place the stack sits: 0 keeps the last column on this view's
    /// right edge.
    private var pan: CGFloat = 0

    init(browser: TiledBrowser) {
        self.browser = browser
        super.init(frame: .zero)
        clipsToBounds = false
        browser.translatesAutoresizingMaskIntoConstraints = true
        browser.autoresizingMask = []
        addSubview(browser)
        ColumnPan.install()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The width of every loaded column, measured from the browser's own tiling so a column the
    /// user has resized counts at its real width. A column the browser has not tiled yet counts
    /// at the default width, and `measured` is false so the caller asks again after tiling.
    private var columnsWidth: (width: CGFloat, measured: Bool) {
        let last = browser.lastColumn
        guard last >= 0 else { return (0, true) }
        let end = browser.frame(ofColumn: last)
        guard end.width > 0 else { return (CGFloat(last + 1) * TiledBrowser.columnWidth, false) }
        return (end.maxX - browser.frame(ofColumn: 0).minX, true)
    }

    override func layout() {
        super.layout()
        let visible = bounds.width
        let (columns, measured) = columnsWidth
        if !measured { DispatchQueue.main.async { [weak self] in self?.needsLayout = true } }
        let width = max(columns, visible)
        // A column that appears or resizes while the pane is at rest slides the stack, as Finder
        // does. While the pane itself is animating, each frame is placed directly and the split
        // view's timing rules.
        let slide = visible == lastWidth && columns != lastColumns && lastColumns > 0 && window != nil
        if columns != lastColumns { pan = 0 }
        pan = min(pan, width - visible)
        lastWidth = visible
        lastColumns = columns
        let target = NSRect(x: visible - width + pan, y: 0, width: width, height: bounds.height)
        if browser.frame != target {
            if slide {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    browser.animator().frame = target
                }
            } else {
                browser.frame = target
            }
        }
        if browser.firstVisibleColumn > 0 { browser.scrollColumnToVisible(0) }
    }

    /// Pans by `delta` points, positive toward the first column. False when every column already
    /// fits, so the scroll goes on to the column under the pointer.
    func panSideways(by delta: CGFloat) -> Bool {
        let spare = max(columnsWidth.width, bounds.width) - bounds.width
        guard spare > 0 else { return false }
        let moved = min(max(pan + delta, 0), spare)
        if moved != pan {
            pan = moved
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        return true
    }
}

/// Sideways scrolling over the column view: Shift with a mouse wheel, or a swipe on a trackpad or
/// Magic Mouse whose sideways motion outweighs its vertical. Each column is its own vertical
/// scroll view and the browser never scrolls sideways, so nothing else would take these. One
/// monitor for the app, as `OpenShortcut` is; vertical scrolling goes on to the columns.
@MainActor
enum ColumnPan {
    private static var monitor: Any?
    /// A mouse wheel reports lines, not points: one row of the column view per line.
    private static let lineWidth: CGFloat = 22

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { takes(event) } ? nil : event
        }
    }

    private static func takes(_ event: NSEvent) -> Bool {
        var sideways = event.scrollingDeltaX
        let vertical = event.scrollingDeltaY
        // macOS turns Shift and a wheel into a sideways scroll itself; should it not, the wheel's
        // vertical motion is the sideways one.
        if sideways == 0, event.modifierFlags.contains(.shift) { sideways = vertical }
        else if abs(sideways) <= abs(vertical) { return false }
        guard sideways != 0, let stack = stack(under: event) else { return false }
        return stack.panSideways(by: event.hasPreciseScrollingDeltas ? sideways : sideways * lineWidth)
    }

    /// The column stack under the pointer, if the pointer is over one. The sidebar and inspector
    /// float above the stack, so a scroll over them finds their own views instead.
    private static func stack(under event: NSEvent) -> ColumnStack? {
        guard let frame = event.window?.contentView?.superview else { return nil }
        var view = frame.hitTest(frame.convert(event.locationInWindow, from: nil))
        while let current = view, !(current is ColumnStack) { view = current.superview }
        return view as? ColumnStack
    }
}

/// The column browser: fixed-width columns. Space opens Quick Look, as in Finder.
final class TiledBrowser: NSBrowser {
    /// Columns start at this width and never reflow to fit the pane. `ColumnStack` moves the whole
    /// set instead. Re-tiling to fit made every column visibly resize during the inspector toggle,
    /// which read as an overlay rather than a slide.
    static let columnWidth: CGFloat = 260
    weak var model: TransferModel?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            model?.togglePreview()
            return
        }
        super.keyDown(with: event)
    }
}


/// Icons at 16 points, cached by kind and extension: every row of every view asks for one.
@MainActor
enum ItemIcon {
    private static var cache: [String: NSImage] = [:]

    /// The folder icon with an up arrow is not a system image; the arrow alone reads clearly.
    static let upImage: NSImage = {
        let image = NSImage(systemSymbolName: "arrow.up.circle", accessibilityDescription: "Parent folder")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) ?? NSImage()
        image.size = NSSize(width: 16, height: 16)
        return image
    }()

    static func image(for item: RemoteItem) -> NSImage {
        let key: String
        switch item.kind {
        case .directory: key = "/dir"
        case .symlink: key = "/link"
        case .other: key = "/other"
        case .file: key = (item.name as NSString).pathExtension.lowercased()
        }
        if let cached = cache[key] { return cached }
        let type: UTType
        switch item.kind {
        case .directory: type = .folder
        case .symlink: type = .symbolicLink
        case .other: type = .item
        case .file: type = UTType(filenameExtension: key) ?? .data
        }
        let icon = NSWorkspace.shared.icon(for: type)
        icon.size = NSSize(width: 16, height: 16)
        cache[key] = icon
        return icon
    }
}

/// Draws the icon and title itself, centered on the row's midline. `NSBrowserCell`'s own title
/// drawing sits low in a 22-point row. The browser still draws the highlight and the branch chevron.
final class CenteredBrowserCell: NSBrowserCell {
    private static let attributes = titleAttributes(color: .labelColor)
    private static let emphasizedAttributes = titleAttributes(color: .alternateSelectedControlTextColor)

    private static func titleAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        return [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: color, .paragraphStyle: paragraph]
    }

    static let iconSize: CGFloat = 16
    static let iconInset: CGFloat = 3
    static let gap: CGFloat = 5
    static let chevronInset: CGFloat = 8

    /// The `..` row's content draws 5 points high so its arrow and text land where list view's
    /// header puts the same arrow and "Name": the column view's rows start 5 points lower than
    /// the list's header does.
    static let upRowLift: CGFloat = 5

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let emphasized = backgroundStyle == .emphasized
        var cellFrame = cellFrame
        if image === ItemIcon.upImage { cellFrame.origin.y -= Self.upRowLift }
        var x = cellFrame.minX + Self.iconInset
        if let image {
            let rect = NSRect(x: x, y: cellFrame.midY - Self.iconSize / 2, width: Self.iconSize, height: Self.iconSize)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += Self.iconSize + Self.gap
        }
        // The browser draws the branch chevron itself; the title only needs to stop short of it.
        let right = cellFrame.maxX - (isLeaf ? Self.gap : Self.chevronInset + 12)
        let title = NSAttributedString(string: stringValue, attributes: emphasized ? Self.emphasizedAttributes : Self.attributes)
        let height = ceil(title.size().height)
        let rect = NSRect(x: x, y: cellFrame.midY - height / 2, width: max(right - x, 0), height: height)
        title.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
