import AppKit
import SwiftUI
import TransferCore
import UniformTypeIdentifiers

/// The pasteboard type for a drag that starts inside Transfer. Its payload is `RemoteDragPayload` as JSON.
let remoteDragType = NSPasteboard.PasteboardType("com.example.transfer.remote-items")

struct RemoteDragPayload: Codable {
    var connection: UUID
    var paths: [[UInt8]]

    var remotePaths: [RemotePath] { paths.map(RemotePath.init(bytes:)) }

    static func read(from pasteboard: NSPasteboard) -> RemoteDragPayload? {
        guard let data = pasteboard.data(forType: remoteDragType) else { return nil }
        return try? JSONDecoder().decode(RemoteDragPayload.self, from: data)
    }
}

/// One promise per dragged root. Finder receives a real file or folder. Transfer receives the remote paths.
final class RemoteItemPromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let item: RemoteItem
    private let session: any RemoteSession
    private let payload: Data

    init(item: RemoteItem, session: any RemoteSession, payload: Data) {
        self.item = item
        self.session = session
        self.payload = payload
        let ext = (item.name as NSString).pathExtension
        let type: UTType
        if item.kind == .directory {
            type = .folder
        } else {
            type = UTType(filenameExtension: ext) ?? .data
        }
        super.init()
        fileType = type.identifier
        delegate = self
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [remoteDragType]
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type == remoteDragType { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == remoteDragType { return payload }
        return super.pasteboardPropertyList(forType: type)
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        item.name
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let path = item.path
        let session = session
        let finish = PromiseFinish(completionHandler)
        Task {
            do {
                try await session.download(path, to: url) { _ in }
                finish.call(nil)
            } catch {
                finish.call(error)
            }
        }
    }

    static func providers(for items: [RemoteItem], session: any RemoteSession) -> [RemoteItemPromise] {
        let payload = RemoteDragPayload(connection: session.connection.id.rawValue, paths: items.map(\.path.bytes))
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return items.map { RemoteItemPromise(item: $0, session: session, payload: data) }
    }
}

private final class PromiseFinish: @unchecked Sendable {
    let call: (Error?) -> Void
    init(_ call: @escaping (Error?) -> Void) { self.call = call }
}

/// What a drop landed on and what it carried.
enum DropAction {
    case uploadFiles([URL], into: RemotePath)
    case moveRemote([RemotePath], into: RemotePath)
}

/// Decides a drop onto `folder` from the pasteboard. Nil when nothing usable is there.
@MainActor
func dropAction(from pasteboard: NSPasteboard, onto folder: RemotePath, connection: ConnectionID) -> DropAction? {
    if let payload = RemoteDragPayload.read(from: pasteboard) {
        guard payload.connection == connection.rawValue else { return nil }
        let paths = payload.remotePaths.filter { path in
            path != folder && path.parent != folder && !folder.isInside(path)
        }
        return paths.isEmpty ? nil : .moveRemote(paths, into: folder)
    }
    let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    return urls.isEmpty ? nil : .uploadFiles(urls, into: folder)
}

extension RemotePath {
    /// True when this path is `ancestor` or lies under it.
    func isInside(_ ancestor: RemotePath) -> Bool {
        if bytes == ancestor.bytes { return true }
        let head = ancestor.isRoot ? ancestor.bytes : ancestor.bytes + [0x2F]
        return bytes.count > head.count && Array(bytes[..<head.count]) == head
    }
}

/// The name cell of a row in icon and list view. It starts drags out and takes drops onto folder rows.
struct FilePromiseLabel: NSViewRepresentable {
    var item: RemoteItem
    var model: TransferModel
    /// Centered under an icon; leading in a table row.
    var centered = false

    func makeNSView(context: Context) -> PromiseText {
        let view = PromiseText()
        view.apply(item: item, model: model, centered: centered)
        return view
    }

    func updateNSView(_ view: PromiseText, context: Context) {
        view.apply(item: item, model: model, centered: centered)
    }
}

final class PromiseText: NSTextField, NSDraggingSource {
    private var item = RemoteItem(path: RemotePath(string: "/"), kind: .other)
    private weak var model: TransferModel?
    private var down: NSPoint = .zero

    override var acceptsFirstResponder: Bool { false }

    /// The list table keeps AppKit's default 2-point row spacing, which SwiftUI does not expose.
    /// Zeroing it brings the row pitch to 22, matching the column view.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard alignment != .center else { return }
        var view: NSView? = superview
        while let current = view, !(current is NSTableView) { view = current.superview }
        if let table = view as? NSTableView {
            if table.intercellSpacing.height != 0 {
                table.intercellSpacing = NSSize(width: table.intercellSpacing.width, height: 0)
            }
            if table.rowHeight != 22 { table.rowHeight = 22 }
        }
    }

    func apply(item: RemoteItem, model: TransferModel, centered: Bool) {
        stringValue = item.name
        self.item = item
        self.model = model
        alignment = centered ? .center : .natural
        isBordered = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        lineBreakMode = .byTruncatingMiddle
        font = .systemFont(ofSize: NSFont.systemFontSize)
        textColor = .labelColor
        if item.kind == .directory {
            registerForDraggedTypes([.fileURL, remoteDragType])
        } else {
            unregisterDraggedTypes()
        }
    }

    override func mouseDown(with event: NSEvent) {
        down = event.locationInWindow
        guard let model else { return }
        if event.modifierFlags.contains(.command) {
            if model.snapshot.selection.contains(item.path) {
                model.snapshot.selection.remove(item.path)
            } else {
                model.snapshot.selection.insert(item.path)
            }
        } else if !model.snapshot.selection.contains(item.path) {
            model.snapshot.selection = [item.path]
        }
        if event.clickCount == 2 {
            let item = item
            Task { await model.open(item) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let moved = hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y)
        guard moved > 4, let model, let session = model.session else { return }
        let roots = model.dragItems(including: item)
        let providers = RemoteItemPromise.providers(for: roots, session: session)
        let dragging = providers.enumerated().map { index, provider in
            let draggingItem = NSDraggingItem(pasteboardWriter: provider)
            let frame = index == 0 ? bounds : NSRect(x: bounds.minX, y: bounds.minY - CGFloat(index) * 4, width: bounds.width, height: bounds.height)
            draggingItem.setDraggingFrame(frame, contents: index == 0 ? stringValue : nil)
            return draggingItem
        }
        beginDraggingSession(with: dragging, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : [.copy, .move]
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard item.kind == .directory, let model, let connection = model.snapshot.connectionID else { return [] }
        switch dropAction(from: sender.draggingPasteboard, onto: item.path, connection: connection) {
        case .uploadFiles: return .copy
        case .moveRemote: return .move
        case nil: return []
        }
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard item.kind == .directory, let model, let connection = model.snapshot.connectionID,
              let action = dropAction(from: sender.draggingPasteboard, onto: item.path, connection: connection) else { return false }
        Task { await model.perform(action) }
        return true
    }
}
