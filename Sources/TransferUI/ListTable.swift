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
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
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
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
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
            ColumnSpec(id: "status", title: "Status", width: 90, minWidth: 60),
            ColumnSpec(id: "mtime", title: "Date Modified", width: 170, minWidth: 120),
            ColumnSpec(id: "size", title: "Size", width: 80, minWidth: 60),
            ColumnSpec(id: "kind", title: "Kind", width: 120, minWidth: 80),
        ]

        var model: TransferModel
        weak var table: NSTableView?
        private(set) var items: [RemoteItem] = []
        private var liveStamp: [RemotePath: String] = [:]
        private var syncing = false
        private var autosaveConnection: ConnectionID?

        init(model: TransferModel) { self.model = model }

        /// Pushes model state into the table: rows, selection, sort indicator, and autosave name.
        func sync() {
            guard let table else { return }
            syncing = true
            defer { syncing = false }
            if autosaveConnection != model.snapshot.connectionID {
                autosaveConnection = model.snapshot.connectionID
                table.autosaveName = model.snapshot.connectionID.map { "transfer.list.\($0.rawValue.uuidString)" }
            }
            let sort = model.snapshot.sort
            let descriptor = NSSortDescriptor(key: sort.column, ascending: sort.ascending)
            if table.sortDescriptors.first?.key != descriptor.key || table.sortDescriptors.first?.ascending != descriptor.ascending {
                table.sortDescriptors = [descriptor]
            }
            let fresh = model.displayedItems
            let stamps = Dictionary(uniqueKeysWithValues: model.liveFiles.map { ($0.path, model.statusText(for: $0.path)) })
            if fresh != items || stamps != liveStamp {
                items = fresh
                liveStamp = stamps
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
            guard let tableColumn, row < items.count else { return nil }
            let item = items[row]
            let id = tableColumn.identifier
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeCell(id)
            switch id.rawValue {
            case "name":
                cell.imageView?.image = ItemIcon.image(for: item)
                cell.textField?.stringValue = item.name
                cell.textField?.textColor = .labelColor
            case "status":
                cell.textField?.stringValue = model.statusText(for: item.path)
                cell.textField?.textColor = .secondaryLabelColor
            case "mtime":
                cell.textField?.stringValue = item.mtime.map(Format.date) ?? ""
            case "size":
                cell.textField?.stringValue = item.kind == .file ? Format.bytes(item.size) : ""
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
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
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
            row < items.count ? items[row].name : nil
        }

        // MARK: Selection, sort, open

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let table else { return }
            model.snapshot.selection = Set(table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0].path : nil })
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !syncing, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            model.setSort(column: key, ascending: descriptor.ascending)
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0, table.clickedRow < items.count else { return }
            let item = items[table.clickedRow]
            let model = model
            Task { await model.open(item) }
        }

        // MARK: Drag and drop

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard let session = model.session, row < items.count else { return nil }
            // One promise per row, but the payload names the whole selection so an internal
            // drop moves every dragged item.
            let roots = model.dragItems(including: items[row])
            return RemoteItemPromise.providers(for: roots, session: session).first { $0.itemPath == items[row].path }
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard let connection = model.snapshot.connectionID else { return [] }
            let folder: RemotePath
            if operation == .on, row >= 0, row < items.count, items[row].kind == .directory {
                folder = items[row].path
            } else {
                tableView.setDropRow(-1, dropOperation: .on)
                folder = model.snapshot.path
            }
            switch dropAction(from: info.draggingPasteboard, onto: folder, connection: connection) {
            case .uploadFiles: return .copy
            case .moveRemote: return .move
            case nil: return []
            }
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let connection = model.snapshot.connectionID else { return false }
            let folder = (dropOperation == .on && row >= 0 && row < items.count && items[row].kind == .directory) ? items[row].path : model.snapshot.path
            guard let action = dropAction(from: info.draggingPasteboard, onto: folder, connection: connection) else { return false }
            let model = model
            Task { await model.perform(action) }
            return true
        }

        // MARK: Context menu

        func menu(forRow row: Int) -> NSMenu? {
            guard let table else { return nil }
            if row >= 0, row < items.count, !table.selectedRowIndexes.contains(row) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let menu = NSMenu()
            let model = model
            let item = row >= 0 && row < items.count ? items[row] : nil
            func add(_ title: String, enabled: Bool = true, _ action: @escaping @MainActor () -> Void) {
                let entry = ClosureMenuItem(title: title, action: action)
                entry.isEnabled = enabled
                menu.addItem(entry)
            }
            if let item {
                add("Open") { Task { await model.open(item) } }
                add("Open Live", enabled: item.kind == .file) { Task { await model.openLiveSelection() } }
                add("Quick Look") { model.showPreview() }
                menu.addItem(.separator())
                add("Download Copy…") { Task { await model.downloadCopy() } }
                add("Duplicate", enabled: item.kind == .file) { Task { await model.duplicateSelection() } }
                add("Rename") { model.beginRename() }
                if item.kind == .directory {
                    add("Save Location") { Task { await model.session?.pin(item.path); await model.refresh() } }
                }
                add("Copy Remote URL") { model.copyRemoteURL() }
                menu.addItem(.separator())
                add("Delete…") { model.askToDelete() }
            } else {
                add("New Folder") { Task { await model.mkdir() } }
                add("Upload…") { Task { await model.uploadFromPanel() } }
                add("Copy Remote URL") { model.copyRemoteURL() }
            }
            return menu
        }
    }
}

/// Serves the coordinator's context menu for the row under the mouse.
final class RowMenuTableView: NSTableView {
    weak var coordinator: ListTable.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return coordinator?.menu(forRow: row(at: point))
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
    static func bytes(_ size: UInt64?) -> String {
        guard let size else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    static func date(_ mtime: UInt32) -> String {
        Date(timeIntervalSince1970: TimeInterval(mtime)).formatted(date: .abbreviated, time: .shortened)
    }
}
