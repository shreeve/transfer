import AppKit
import SwiftUI
import TransferCore
import UniformTypeIdentifiers

/// The list view: an AppKit table with 22-point rows, alternating backgrounds, header sorting,
/// per-connection column autosave, drag out, drop onto folders, and the row context menu.
/// It reads the model's items and selection and never owns them.
struct ListTable: NSViewRepresentable {
    static let rowHeight: CGFloat = 22
    var model: TransferModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = RowMenuTableView()
        table.coordinator = context.coordinator
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 3, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.autosaveTableColumns = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.registerForDraggedTypes([.fileURL, remoteDragType])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        for spec in Coordinator.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.minWidth
            column.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: true)
            if spec.id == "name" {
                // The header's icon slot holds an up arrow; "Name" sits over the file names.
                let cell = NameHeaderCell(textCell: spec.title)
                column.headerCell = cell
                context.coordinator.nameHeader = cell
            }
            if spec.id == "size" { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        let header = ListHeaderView()
        header.onUp = { [weak coordinator = context.coordinator] in
            guard let model = coordinator?.model else { return }
            Task { await model.goParent() }
        }
        table.headerView = header
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        // Narrower than its columns, the table scrolls sideways as Finder's does, never clips.
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        context.coordinator.sync()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.sync()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        struct ColumnSpec {
            var id: String
            var title: String
            var width: CGFloat
            var minWidth: CGFloat
        }

        static let columns = [
            ColumnSpec(id: "name", title: "Name", width: 280, minWidth: 120),
            ColumnSpec(id: "mtime", title: "Date Modified", width: 170, minWidth: 120),
            ColumnSpec(id: "size", title: "Size", width: 80, minWidth: 60),
            ColumnSpec(id: "kind", title: "Kind", width: 120, minWidth: 80),
        ]

        var model: TransferModel
        weak var table: NSTableView?
        weak var nameHeader: NameHeaderCell?
        private(set) var items: [RemoteItem] = []
        private var syncing = false
        private var autosaveConnection: ConnectionID?
        private let drag = RowDrag()

        init(model: TransferModel) { self.model = model }

        /// Pushes model state into the table: rows, selection, sort indicator, and autosave name.
        func sync() {
            guard let table else { return }
            syncing = true
            defer { syncing = false }
            if autosaveConnection != model.snapshot.connectionID {
                autosaveConnection = model.snapshot.connectionID
                table.autosaveName = model.snapshot.connectionID.map { "transfer.list.\($0.rawValue.uuidString)" }
                // An order saved before Name was kept first may have moved it.
                if let name = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }), name > 0 {
                    table.moveColumn(name, toColumn: 0)
                }
            }
            let hasParent = model.snapshot.path.parent != nil
            if nameHeader?.showsUp != hasParent {
                nameHeader?.showsUp = hasParent
                table.headerView?.needsDisplay = true
            }
            let sort = model.snapshot.sort
            let descriptor = NSSortDescriptor(key: sort.column, ascending: sort.ascending)
            if table.sortDescriptors.first?.key != descriptor.key || table.sortDescriptors.first?.ascending != descriptor.ascending {
                table.sortDescriptors = [descriptor]
            }
            let fresh = model.displayedItems
            if fresh != items {
                items = fresh
                table.reloadData()
            }
            let wanted = IndexSet(items.indices.filter { model.snapshot.selection.contains(items[$0].path) })
            if wanted != table.selectedRowIndexes {
                table.selectRowIndexes(wanted, byExtendingSelection: false)
            }
        }

        // MARK: Rows

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, items.indices.contains(row) else { return nil }
            let item = items[row]
            let id = tableColumn.identifier
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeCell(id)
            switch id.rawValue {
            case "name":
                cell.imageView?.image = ItemIcon.image(for: item)
                cell.textField?.stringValue = item.name
            case "mtime":
                cell.textField?.stringValue = item.mtime.map(Format.date) ?? ""
            case "size":
                cell.textField?.stringValue = item.kind == .file ? Format.si(item.size) : ""
            default:
                cell.textField?.stringValue = item.kindLabel
            }
            return cell
        }

        private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.font = .systemFont(ofSize: NSFont.systemFontSize)
            text.textColor = .labelColor
            if id.rawValue == "size" {
                // Three digits, a prefix, and the unit line up down the column.
                text.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                text.alignment = .right
            }
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            if id.rawValue == "name" {
                let image = NSImageView()
                image.imageScaling = .scaleProportionallyDown
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                ])
            } else {
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            items.indices.contains(row) ? items[row].name : nil
        }

        // MARK: Selection, sort, open

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let table else { return }
            model.snapshot.selection = Set(table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].path : nil })
        }

        /// Name stays the first column, as in Finder: the fitting in `RowMenuTableView.layout`,
        /// the header's up arrow, and the row inset all measure column 0, and the first-column
        /// autoresizing style gives the spare width to whichever column is first. AppKit asks with
        /// a new index of -1 as a drag begins.
        func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
            columnIndex != 0 && newColumnIndex != 0
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !syncing, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            model.setSort(column: key, ascending: descriptor.ascending)
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, items.indices.contains(table.clickedRow) else { return }
            let item = items[table.clickedRow]
            let model = model
            Task { await model.open(item) }
        }

        // MARK: Drag and drop

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard items.indices.contains(row) else { return nil }
            return drag.writer(for: items[row], model: model)
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            let folder = dropFolder(row: row, operation: operation)
            if folder == model.snapshot.path { tableView.setDropRow(-1, dropOperation: .on) }
            return dropAction(for: info, onto: folder, model: model)?.operation ?? []
        }

        /// A drop on a folder row goes into that folder; anywhere else goes into the current one.
        private func dropFolder(row: Int, operation: NSTableView.DropOperation) -> RemotePath {
            if operation == .on, items.indices.contains(row), items[row].kind == .directory { return items[row].path }
            return model.snapshot.path
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let action = dropAction(for: info, onto: dropFolder(row: row, operation: dropOperation), model: model) else { return false }
            let model = model
            Task { await model.perform(action) }
            return true
        }

        // MARK: Context menu

        /// A right-clicked row joins the selection first, as a click would select it. The empty
        /// area below the rows clears the selection, as a click there does, so the folder's menu
        /// (Copy Remote URL included) acts on the folder rather than on rows it does not name.
        func menu(forRow row: Int) -> NSMenu? {
            guard let table else { return nil }
            let clicked = items.indices.contains(row) ? items[row] : nil
            if clicked == nil {
                table.deselectAll(nil)
            } else if !table.selectedRowIndexes.contains(row) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let menu = NSMenu()
            ItemMenu.fill(menu, item: clicked, model: model)
            return menu
        }
    }
}

/// The promises of one row drag. A table or browser asks for a writer per dragged row, all in one
/// turn of the run loop, so the drag's roots, payload, and prompts are worked out once for the
/// whole drag rather than once for each row.
@MainActor
final class RowDrag {
    private var promises: [RemotePath: RemoteItemPromise] = [:]

    func writer(for item: RemoteItem, model: TransferModel) -> RemoteItemPromise? {
        if let promise = promises[item.path] { return promise }
        guard let session = model.session else { return nil }
        if promises.isEmpty { DispatchQueue.main.async { [weak self] in self?.promises = [:] } }
        // The payload names every root, so a drop inside Transfer moves all of them.
        let roots = model.dragItems(including: item)
        for (root, promise) in zip(roots, RemoteItemPromise.providers(for: roots, session: session, prompts: model.operationPrompts())) {
            promises[root.path] = promise
        }
        return promises[item.path]
    }
}

/// Serves the coordinator's context menu for the row under the mouse.
final class RowMenuTableView: NSTableView {
    weak var coordinator: ListTable.Coordinator?
    private var fittedWidth: CGFloat = 0

    /// The Name column takes whatever width the others leave, down to its minimum, so the table
    /// reflows with the window and the inspector. Autoresizing alone only tracks changes, and
    /// misses a restored column set that is already wider than the view.
    override func layout() {
        super.layout()
        guard let clip = enclosingScrollView?.contentView, let name = tableColumns.first else { return }
        let available = clip.bounds.width
        guard available > 0, abs(available - fittedWidth) > 0.5 else { return }
        fittedWidth = available
        let others = tableColumns.dropFirst().filter { !$0.isHidden }.reduce(0) { $0 + $1.width }
        let spacing = intercellSpacing.width * CGFloat(tableColumns.count)
        let width = max(name.minWidth, available - others - spacing)
        if abs(name.width - width) > 0.5 { name.width = width }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return coordinator?.menu(forRow: row(at: point))
    }
}

/// The right-click menu of the list and column views: for the clicked item, which the view has
/// already made part of the selection, or with no item, for the current folder, which the view
/// has made the location with nothing selected.
@MainActor
enum ItemMenu {
    static func fill(_ menu: NSMenu, item: RemoteItem?, model: TransferModel) {
        func add(_ title: String, enabled: Bool = true, _ action: @escaping @MainActor () -> Void) {
            let entry = ClosureMenuItem(title: title, action: action)
            entry.isEnabled = enabled
            menu.addItem(entry)
        }
        guard let item else {
            add("New Folder") { Task { await model.mkdir() } }
            add("Upload…") { Task { await model.uploadFromPanel() } }
            add("Paste", enabled: model.canPaste) { Task { await model.paste(moving: false) } }
            add("Copy Remote URL") { model.copyRemoteURL() }
            return
        }
        add("Open") { Task { await model.open(item) } }
        add("Open Live", enabled: item.kind == .file) { Task { await model.open(item, forceLive: true) } }
        add("Quick Look") { model.showPreview() }
        menu.addItem(.separator())
        add("Download Copy…") { Task { await model.downloadCopy() } }
        add("Duplicate") { Task { await model.duplicateSelection() } }
        add("Rename") { model.beginRename() }
        let targets = model.dragItems(including: item).map(\.path)
        add(model.starTitle(targets)) { Task { await model.toggleStar(targets) } }
        add("Copy") { model.copySelection() }
        add("Copy Remote URL") { model.copyRemoteURL() }
        menu.addItem(.separator())
        add("Delete…") { model.askToDelete() }
    }
}

@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let closure: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        closure = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { closure() }
}

enum Format {
    /// `959 B`, `1.2kB`, ` 14kB`: see `Units`.
    static func si(_ size: UInt64?) -> String {
        size.map(Units.bytes) ?? ""
    }

    static func date(_ mtime: UInt32) -> String {
        Date(timeIntervalSince1970: TimeInterval(mtime)).formatted(date: .abbreviated, time: .shortened)
    }

    /// The inspector's date, `2026-08-31`, and its time, `2:44:07 PM`.
    static func day(_ mtime: UInt32) -> String {
        dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(mtime)))
    }

    static func clock(_ mtime: UInt32) -> String {
        clockFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(mtime)))
    }

    private static let dayFormatter = fixed("yyyy-MM-dd")
    private static let clockFormatter = fixed("h:mm:ss a")

    private static func fixed(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}

/// The Name column's header: an up arrow in the icon slot and the title over the names, on the
/// same offsets the rows use.
final class NameHeaderCell: NSTableHeaderCell {
    static let iconInset: CGFloat = 3
    static let textInset: CGFloat = 24
    var showsUp = false
    /// How far the table insets row cells from the column edge; the header view measures it.
    var rowInset: CGFloat = 0

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let cellFrame = NSRect(x: cellFrame.minX + rowInset, y: cellFrame.minY, width: cellFrame.width - rowInset, height: cellFrame.height)
        if showsUp {
            let rect = NSRect(x: cellFrame.minX + Self.iconInset, y: cellFrame.midY - 8, width: 16, height: 16)
            ItemIcon.upImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.headerTextColor,
        ]
        let title = NSAttributedString(string: stringValue, attributes: attributes)
        let size = title.size()
        let rect = NSRect(x: cellFrame.minX + Self.textInset, y: cellFrame.midY - size.height / 2, width: max(cellFrame.width - Self.textInset - 20, 0), height: size.height)
        title.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// Routes a click on the Name header's arrow to the parent folder; everything else sorts as usual.
final class ListHeaderView: NSTableHeaderView {
    var onUp: (() -> Void)?

    private var nameCell: NameHeaderCell? {
        tableView?.tableColumns.first?.headerCell as? NameHeaderCell
    }

    /// The inset the table applies to row cells, so the header's arrow and title sit over them.
    private func measureRowInset() {
        guard let table = tableView, let cell = nameCell, table.numberOfRows > 0 else { return }
        let inset = table.frameOfCell(atColumn: 0, row: 0).minX - headerRect(ofColumn: 0).minX
        if abs(cell.rowInset - inset) > 0.5 { cell.rowInset = max(inset, 0) }
    }

    override func draw(_ dirtyRect: NSRect) {
        measureRowInset()
        super.draw(dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if column(at: point) == 0, let cell = nameCell, cell.showsUp {
            let x = point.x - headerRect(ofColumn: 0).minX - cell.rowInset
            if x >= 0, x < NameHeaderCell.textInset {
                onUp?()
                return
            }
        }
        super.mouseDown(with: event)
    }
}
