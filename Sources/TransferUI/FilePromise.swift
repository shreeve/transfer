import AppKit
import SwiftUI
import TransferCore
import UniformTypeIdentifiers

struct FilePromiseLabel: NSViewRepresentable {
    var item: RemoteItem
    var session: any RemoteSession
    var onSelect: () -> Void
    var onOpen: () -> Void

    func makeNSView(context: Context) -> PromiseText {
        let view = PromiseText()
        view.onSelect = onSelect
        view.onOpen = onOpen
        view.apply(item: item, session: session)
        return view
    }

    func updateNSView(_ view: PromiseText, context: Context) {
        view.onSelect = onSelect
        view.onOpen = onOpen
        view.apply(item: item, session: session)
    }
}

final class PromiseText: NSTextField, NSDraggingSource, NSFilePromiseProviderDelegate {
    var onSelect: () -> Void = {}
    var onOpen: () -> Void = {}
    private var path = RemotePath(string: "/")
    private var session: (any RemoteSession)?
    private var down: NSPoint = .zero

    func apply(item: RemoteItem, session: any RemoteSession) {
        stringValue = item.name
        path = item.path
        self.session = session
        isBordered = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        lineBreakMode = .byTruncatingMiddle
        font = .systemFont(ofSize: NSFont.systemFontSize)
        textColor = .labelColor
    }

    override func mouseDown(with event: NSEvent) {
        down = event.locationInWindow
        onSelect()
        if event.clickCount == 2 { onOpen() }
    }

    override func mouseDragged(with event: NSEvent) {
        let moved = hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y)
        guard moved > 4, session != nil else { return }
        let type = stringValue.contains(".") ? UTType(filenameExtension: (stringValue as NSString).pathExtension)?.identifier ?? UTType.data.identifier : UTType.data.identifier
        let promise = NSFilePromiseProvider(fileType: type, delegate: self)
        let dragging = NSDraggingItem(pasteboardWriter: promise)
        dragging.setDraggingFrame(bounds, contents: stringValue)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        stringValue
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let path = path
        let session = session
        let finish = PromiseFinish(completionHandler)
        Task {
            do {
                guard let session else { throw TransferError.notConnected }
                try await session.download(path, to: url) { _ in }
                finish.call(nil)
            } catch {
                finish.call(error)
            }
        }
    }
}

private final class PromiseFinish: @unchecked Sendable {
    let call: (Error?) -> Void
    init(_ call: @escaping (Error?) -> Void) { self.call = call }
}
