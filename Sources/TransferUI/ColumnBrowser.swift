import AppKit
import SwiftUI
import TransferCore
import UniformTypeIdentifiers

/// The column view. It reads `BrowserModel` state through `TransferModel` and owns none of it.
struct ColumnBrowser: NSViewRepresentable {
    var model: TransferModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSBrowser {
        let browser = NSBrowser()
        browser.setCellClass(CenteredBrowserCell.self)
        browser.delegate = context.coordinator
        browser.target = context.coordinator
        browser.action = #selector(Coordinator.selectionChanged(_:))
        browser.doubleAction = #selector(Coordinator.doubleClicked(_:))
        browser.sendsActionOnArrowKeys = true
        browser.allowsMultipleSelection = true
        browser.hasHorizontalScroller = true
        browser.autohidesScroller = true
        browser.minColumnWidth = 180
        browser.isTitled = false
        browser.registerForDraggedTypes([.fileURL, remoteDragType])
        browser.setDraggingSourceOperationMask(.copy, forLocal: false)
        browser.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        context.coordinator.browser = browser
        return browser
    }

    func updateNSView(_ browser: NSBrowser, context: Context) {
        context.coordinator.model = model
        context.coordinator.sync(browser)
    }

    @MainActor
    final class Coordinator: NSObject, NSBrowserDelegate {
        var model: TransferModel
        weak var browser: NSBrowser?
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

        func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
            children(path(of: item)).count
        }

        func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
            let list = children(path(of: item))
            return index < list.count ? list[index] : RemoteItem(path: RemotePath(string: "/"), kind: .other)
        }

        func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
            guard let item = item as? RemoteItem else { return false }
            return item.kind != .directory
        }

        func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
            if let item = item as? RemoteItem { return item.name }
            return (item as? RemotePath)?.display ?? ""
        }

        func browser(_ browser: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
            guard let cell = cell as? NSBrowserCell, let item = browser.item(atRow: row, inColumn: column) as? RemoteItem else { return }
            let icon = ItemIcon.image(for: item).copy() as! NSImage
            icon.size = NSSize(width: 16, height: 16)
            cell.image = icon
            cell.isLeaf = item.kind != .directory
        }

        func browser(_ browser: NSBrowser, heightOfRow row: Int, inColumn columnIndex: Int) -> CGFloat {
            22
        }

        func browser(_ browser: NSBrowser, shouldEditItem item: Any?) -> Bool { false }

        private func path(of item: Any?) -> RemotePath {
            if let remote = item as? RemoteItem { return remote.path }
            if let remote = item as? RemotePath { return remote }
            return root ?? model.snapshot.path
        }

        private func children(_ path: RemotePath) -> [RemoteItem] {
            if let cached = model.columns[path] { return model.visible(cached) }
            model.loadColumn(path)
            return []
        }

        // MARK: Selection

        @objc func selectionChanged(_ sender: Any?) {
            guard !syncing, let browser else { return }
            let column = browser.selectedColumn
            guard column >= 0 else { return }
            let selected = browser.selectedRowIndexes(inColumn: column) ?? IndexSet()
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
            model.session != nil
        }

        func browser(_ browser: NSBrowser, pasteboardWriterForRow row: Int, column: Int) -> (any NSPasteboardWriting)? {
            guard let session = model.session, let item = browser.item(atRow: row, inColumn: column) as? RemoteItem else { return nil }
            return RemoteItemPromise.providers(for: [item], session: session).first
        }

        // MARK: Drop in

        func browser(
            _ browser: NSBrowser,
            validateDrop info: any NSDraggingInfo,
            proposedRow row: UnsafeMutablePointer<Int>,
            column: UnsafeMutablePointer<Int>,
            dropOperation: UnsafeMutablePointer<NSBrowser.DropOperation>
        ) -> NSDragOperation {
            guard let connection = model.snapshot.connectionID, let folder = dropFolder(browser, row: row.pointee, column: column.pointee) else { return [] }
            if let target = browser.item(atRow: row.pointee, inColumn: column.pointee) as? RemoteItem, target.kind != .directory {
                row.pointee = -1
                dropOperation.pointee = .on
            }
            switch dropAction(from: info.draggingPasteboard, onto: folder, connection: connection) {
            case .uploadFiles: return .copy
            case .moveRemote: return .move
            case nil: return []
            }
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

enum ItemIcon {
    @MainActor
    static func image(for item: RemoteItem) -> NSImage {
        switch item.kind {
        case .directory: NSWorkspace.shared.icon(for: .folder)
        case .symlink: NSWorkspace.shared.icon(for: .symbolicLink)
        case .other: NSWorkspace.shared.icon(for: .item)
        case .file:
            NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
        }
    }
}

/// Draws the icon and title itself, centered on the row's midline. `NSBrowserCell`'s own title
/// drawing sits low in a 22-point row. The browser still draws the highlight and the branch chevron.
final class CenteredBrowserCell: NSBrowserCell {
    static let iconSize: CGFloat = 16
    static let iconInset: CGFloat = 3
    static let gap: CGFloat = 5
    static let chevronInset: CGFloat = 8

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let emphasized = backgroundStyle == .emphasized
        var x = cellFrame.minX + Self.iconInset
        if let image {
            let rect = NSRect(x: x, y: cellFrame.midY - Self.iconSize / 2, width: Self.iconSize, height: Self.iconSize)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += Self.iconSize + Self.gap
        }
        // The browser draws the branch chevron itself; the title only needs to stop short of it.
        let right = cellFrame.maxX - (isLeaf ? Self.gap : Self.chevronInset + 12)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: emphasized ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let title = NSAttributedString(string: stringValue, attributes: attributes)
        let height = ceil(title.size().height)
        let rect = NSRect(x: x, y: cellFrame.midY - height / 2, width: max(right - x, 0), height: height)
        title.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
