import AppKit
import SwiftUI
import TransferCore
import UniformTypeIdentifiers

/// The column view. It reads `BrowserModel` state through `TransferModel` and owns none of it.
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
    final class Coordinator: NSObject, NSBrowserDelegate {
        var model: TransferModel
        weak var browser: NSBrowser?
        weak var stack: ColumnStack?
        private var root: RemotePath?
        private var shown: [RemotePath: [RemoteItem]] = [:]
        private var syncing = false

        init(model: TransferModel) { self.model = model }

        /// Reloads only the columns whose listing changed.
        func sync(_ browser: NSBrowser) {
            let newRoot = model.columnRoot ?? model.snapshot.path
            syncing = true
            defer { syncing = false }
            if root != newRoot {
                root = newRoot
                showsUpEntry = newRoot.parent != nil
                shown.removeAll()
                browser.loadColumnZero()
                return
            }
            for column in 0...max(browser.lastColumn, 0) {
                let path = self.path(forColumn: column) ?? newRoot
                let current = children(path)
                if shown[path] != current {
                    shown[path] = current
                    browser.reloadColumn(column)
                }
            }
        }

        private func path(forColumn column: Int) -> RemotePath? {
            guard let browser else { return nil }
            if column == 0 { return root }
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

        func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
            let path = path(of: item)
            return children(path).count + (hasUpEntry(path) ? 1 : 0)
        }

        func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
            let path = path(of: item)
            var index = index
            if hasUpEntry(path) {
                if index == 0 { return upEntry }
                index -= 1
            }
            let list = children(path)
            return index < list.count ? list[index] : RemoteItem(path: RemotePath(string: "/"), kind: .other)
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
            if browser.item(atRow: row, inColumn: column) is UpEntry {
                cell.image = ItemIcon.upImage
                return
            }
            guard let item = browser.item(atRow: row, inColumn: column) as? RemoteItem else { return }
            cell.image = ItemIcon.image(for: item)
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

        private func children(_ path: RemotePath) -> [RemoteItem] {
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
            guard column >= 0 else { return }
            let selected = browser.selectedRowIndexes(inColumn: column) ?? IndexSet()
            if selected.contains(where: { browser.item(atRow: $0, inColumn: column) is UpEntry }) {
                let model = model
                Task { await model.goParent() }
                return
            }
            let items = selected.compactMap { browser.item(atRow: $0, inColumn: column) as? RemoteItem }
            let parent = path(forColumn: column) ?? model.snapshot.path
            model.selectInColumns(items, parent: parent)
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let browser, browser.selectedColumn >= 0,
                  let item = browser.item(atRow: browser.selectedRow(inColumn: browser.selectedColumn), inColumn: browser.selectedColumn) as? RemoteItem
            else { return }
            let model = model
            Task { await model.open(item) }
        }

        // MARK: Drag out

        func browser(_ browser: NSBrowser, canDragRowsWith rowIndexes: IndexSet, inColumn column: Int, with event: NSEvent) -> Bool {
            return model.session != nil
        }

        func browser(_ browser: NSBrowser, pasteboardWriterForRow row: Int, column: Int) -> (any NSPasteboardWriting)? {
            guard let session = model.session, let item = browser.item(atRow: row, inColumn: column) as? RemoteItem else { return nil }
            return RemoteItemPromise.provider(for: item, among: model.dragItems(including: item), session: session)
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
            if let target = browser.item(atRow: row.pointee, inColumn: column.pointee) as? RemoteItem, target.kind == .directory {
                dropOperation.pointee = .on
            } else {
                row.pointee = -1
                dropOperation.pointee = .on
            }
            guard let folder = dropFolder(browser, row: row.pointee, column: column.pointee) else { return [] }
            return dropAction(from: info.draggingPasteboard, onto: folder, connection: connection)?.operation ?? []
        }

        func browser(_ browser: NSBrowser, acceptDrop info: any NSDraggingInfo, atRow row: Int, column: Int, dropOperation: NSBrowser.DropOperation) -> Bool {
            guard let connection = model.snapshot.connectionID,
                  let folder = dropFolder(browser, row: row, column: column),
                  let action = dropAction(from: info.draggingPasteboard, onto: folder, connection: connection) else { return false }
            let model = model
            Task { await model.perform(action) }
            return true
        }

        private func dropFolder(_ browser: NSBrowser, row: Int, column: Int) -> RemotePath? {
            if row >= 0, let item = browser.item(atRow: row, inColumn: column) as? RemoteItem, item.kind == .directory {
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
final class ColumnStack: NSView {
    let browser: TiledBrowser
    private var lastWidth: CGFloat = 0
    private var lastColumns: CGFloat = 0

    init(browser: TiledBrowser) {
        self.browser = browser
        super.init(frame: .zero)
        clipsToBounds = false
        browser.translatesAutoresizingMaskIntoConstraints = true
        browser.autoresizingMask = []
        addSubview(browser)
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
        let target = NSRect(x: visible - width, y: 0, width: width, height: bounds.height)
        // A column that appears or resizes while the pane is at rest slides the stack, as Finder
        // does. While the pane itself is animating, each frame is placed directly and the split
        // view's timing rules.
        let slide = visible == lastWidth && columns != lastColumns && lastColumns > 0 && window != nil
        lastWidth = visible
        lastColumns = columns
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
