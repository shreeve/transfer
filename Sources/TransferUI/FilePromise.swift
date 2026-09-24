import AppKit
import SwiftUI
import TransferCore
import UniformTypeIdentifiers

/// The pasteboard type for a drag that starts inside Transfer. Its payload is `RemoteDragPayload` as JSON.
let remoteDragType = NSPasteboard.PasteboardType("com.github.shreeve.transfer.remote-items")

struct RemoteDragPayload: Codable {
    var connection: UUID
    var paths: [[UInt8]]

    var remotePaths: [RemotePath] { paths.map(RemotePath.init(bytes:)) }

    static func read(from pasteboard: NSPasteboard) -> RemoteDragPayload? {
        guard let data = pasteboard.data(forType: remoteDragType) else { return nil }
        return try? JSONDecoder().decode(RemoteDragPayload.self, from: data)
    }

    /// The payload naming `items` on `session`'s server, for a drag or the clipboard.
    static func data(for items: [RemoteItem], session: any RemoteSession) -> Data {
        let payload = RemoteDragPayload(connection: session.connection.id.rawValue, paths: items.map(\.path.bytes))
        return (try? JSONEncoder().encode(payload)) ?? Data()
    }
}

extension NSPasteboard {
    /// The file URLs on the pasteboard, from Finder or another app.
    var fileURLs: [URL] {
        (readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

/// One promise per dragged root. Finder receives a real file or folder. Transfer receives the remote paths.
final class RemoteItemPromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let item: RemoteItem
    private let session: any RemoteSession
    private let payload: Data
    /// The drag's prompts: a file already at the drop's destination is asked about there.
    private let prompts: any PromptSink

    init(item: RemoteItem, session: any RemoteSession, payload: Data, prompts: any PromptSink) {
        self.item = item
        self.session = session
        self.payload = payload
        self.prompts = prompts
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
        let prompts = prompts
        let finish = Locked(completionHandler)
        Task {
            do {
                try await OperationPrompts.$current.withValue(prompts) {
                    try await session.download(path, to: url) { _ in }
                }
                finish.value(nil)
            } catch {
                finish.value(error)
            }
        }
    }

    static func providers(for items: [RemoteItem], session: any RemoteSession, prompts: any PromptSink) -> [RemoteItemPromise] {
        let data = RemoteDragPayload.data(for: items, session: session)
        return items.map { RemoteItemPromise(item: $0, session: session, payload: data, prompts: prompts) }
    }

    /// One provider for `item`, whose payload names every item in `roots`, for row-based drags.
    static func provider(for item: RemoteItem, among roots: [RemoteItem], session: any RemoteSession, prompts: any PromptSink) -> RemoteItemPromise {
        RemoteItemPromise(item: item, session: session, payload: RemoteDragPayload.data(for: roots, session: session), prompts: prompts)
    }
}

/// What a drop landed on and what it carried.
enum DropAction {
    case uploadFiles([URL], into: RemotePath)
    case moveRemote([RemotePath], into: RemotePath)

    /// Files from outside copy in; remote items move.
    var operation: NSDragOperation {
        if case .uploadFiles = self { return .copy }
        return .move
    }
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
    let urls = pasteboard.fileURLs
    return urls.isEmpty ? nil : .uploadFiles(urls, into: folder)
}

/// The name under an icon in icon view. It starts drags out and takes drops onto folder tiles.
struct FilePromiseLabel: NSViewRepresentable {
    var item: RemoteItem
    var model: TransferModel

    func makeNSView(context: Context) -> IconItemView {
        let view = IconItemView()
        view.apply(item: item, model: model)
        return view
    }

    func updateNSView(_ view: IconItemView, context: Context) {
        view.apply(item: item, model: model)
    }
}

/// A whole icon-grid cell: the glyph and the name, both a drag source, so a drag can start
/// anywhere on the cell as in Finder. Selection, open, and drop onto folders live here too.
final class IconItemView: NSView, NSDraggingSource {
    private var item = RemoteItem(path: RemotePath(string: "/"), kind: .other)
    private weak var model: TransferModel?
    private var down: NSPoint = .zero
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        // Finder wraps a long name to two lines, then truncates the middle so the extension stays.
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.cell?.truncatesLastVisibleLine = true
        label.preferredMaxLayoutWidth = 96
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: topAnchor),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(item: RemoteItem, model: TransferModel) {
        self.item = item
        self.model = model
        icon.image = ItemIcon.image(for: item)
        label.stringValue = item.name
        if item.kind == .directory {
            registerForDraggedTypes([.fileURL, remoteDragType])
        } else {
            unregisterDraggedTypes()
        }
    }

    /// A clicked cell holds the focus, as a table row does, so the Edit menu reaches the window
    /// through the responder chain; nothing else in the grid would take it.
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        down = event.locationInWindow
        guard let model else { return }
        model.itemClickTime = event.timestamp
        window?.makeFirstResponder(self)
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

    /// Space opens Quick Look, as the grid itself does.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            model?.togglePreview()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let moved = hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y)
        guard moved > 4, let model, let session = model.session else { return }
        let roots = model.dragItems(including: item)
        let providers = RemoteItemPromise.providers(for: roots, session: session, prompts: model.operationPrompts())
        let dragging = providers.enumerated().map { index, provider -> NSDraggingItem in
            let dragItem = NSDraggingItem(pasteboardWriter: provider)
            let frame = index == 0 ? icon.frame : NSRect(x: icon.frame.minX, y: icon.frame.minY - CGFloat(index) * 4, width: icon.frame.width, height: icon.frame.height)
            dragItem.setDraggingFrame(frame, contents: index == 0 ? ItemIcon.image(for: item) : nil)
            return dragItem
        }
        beginDraggingSession(with: dragging, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : [.copy, .move]
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard item.kind == .directory, let model, let connection = model.snapshot.connectionID else { return [] }
        return dropAction(from: sender.draggingPasteboard, onto: item.path, connection: connection)?.operation ?? []
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
