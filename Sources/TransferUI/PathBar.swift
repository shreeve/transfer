import AppKit
import SwiftUI
import TransferCore

/// One place on the path bar: a step of `PathTrail` and what the bar shows for it.
public struct PathBarEntry: Hashable {
    public var step: PathTrail.Step
    /// The server's name for the root, else the name, with replacement characters where it is
    /// not UTF-8; `step.path` keeps the real bytes.
    public var title: String
    /// The selected item as its folder's listing has it, for its icon.
    public var item: RemoteItem?

    public var path: RemotePath { step.path }

    /// Every folder on the bar takes a drop; the selected item only when it is one.
    var takesDrops: Bool { !step.isSelection || item?.kind == .directory }
}

/// View > Show Path Bar, as Finder's: a thin strip at the foot of the browser, above the clipboard
/// bar and the shelf, naming the server (with its icon) and each folder down to the location, and
/// the selected item when there is exactly one. A click on a folder above the location goes there,
/// as Go to Folder does; a long path drops the middle names to icons first. It is an
/// `NSPathControl` of items with no URLs: it draws Finder's own path bar, and the paths, which are
/// remote, live only in the entries it was loaded with.
struct PathBar: View {
    static let height: CGFloat = 24
    let model: TransferModel

    var body: some View {
        PathBarControlView(entries: model.pathBar, model: model)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
            .padding(.horizontal, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
    }
}

struct PathBarControlView: NSViewRepresentable {
    var entries: [PathBarEntry]
    var model: TransferModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> PathBarControl {
        let control = PathBarControl()
        control.pathStyle = .standard
        control.controlSize = .small
        control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        control.backgroundColor = .clear
        control.isEditable = false
        // A click goes somewhere but never takes the keyboard from the browser, as in Finder, so
        // Space and Command-Down keep working.
        control.refusesFirstResponder = true
        control.focusRingType = .none
        control.delegate = context.coordinator
        control.target = context.coordinator
        control.action = #selector(Coordinator.clicked(_:))
        control.coordinator = context.coordinator
        // After `isEditable`, which sets the control's own drag types.
        control.registerForDraggedTypes([.fileURL, remoteDragType])
        context.coordinator.show(entries, in: control)
        return control
    }

    func updateNSView(_ control: PathBarControl, context: Context) {
        context.coordinator.model = model
        context.coordinator.show(entries, in: control)
    }

    /// As wide as offered, so a long path truncates instead of widening the pane.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PathBarControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: PathBar.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSPathControlDelegate {
        var model: TransferModel
        /// The entries the control was loaded with. Every index a callback brings is checked
        /// against them before use.
        private(set) var shown: [PathBarEntry] = []

        init(model: TransferModel) { self.model = model }

        func show(_ entries: [PathBarEntry], in control: NSPathControl) {
            guard entries != shown else { return }
            shown = entries
            control.pathItems = entries.map(Self.item)
        }

        func entry(at index: Int) -> PathBarEntry? {
            shown.indices.contains(index) ? shown[index] : nil
        }

        private static func item(_ entry: PathBarEntry) -> NSPathControlItem {
            let item = NSPathControlItem()
            item.title = entry.title
            let icon: NSImage
            if entry.path.isRoot {
                icon = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil) ?? NSImage()
            } else {
                icon = ItemIcon.image(for: entry.item ?? RemoteItem(path: entry.path, kind: entry.step.isSelection ? .other : .directory))
            }
            // The icons are shared with the browser; the control may size its own.
            let image = icon.copy() as? NSImage ?? icon
            image.size = NSSize(width: 16, height: 16)
            item.image = image
            return item
        }

        @objc func clicked(_ control: PathBarControl) {
            guard let index = control.clickedIndex else { return }
            go(to: index)
        }

        /// A folder above the location opens; the location and the selected item stay as they are.
        func go(to index: Int) {
            guard let entry = entry(at: index), entry.step.navigable else { return }
            let model = model
            Task { await model.goToPathBarFolder(entry.path) }
        }

        /// The components have no URLs to drag, and none may be dragged.
        func pathControl(_ pathControl: NSPathControl, shouldDrag pathItem: NSPathControlItem, with pasteboard: NSPasteboard) -> Bool {
            false
        }
    }
}

/// The path bar's control. A drop onto a folder lands in that folder, through `dropAction` as in
/// every other view, so remote paths count only from a drag this app began. The control's own
/// drop handling, which would set its URL, never runs.
final class PathBarControl: NSPathControl {
    weak var coordinator: PathBarControlView.Coordinator?

    /// The component a click landed on, as an index into the entries the control was loaded with.
    var clickedIndex: Int? {
        guard let cell = cell as? NSPathCell, let clicked = cell.clickedPathComponentCell else { return nil }
        return cell.pathComponentCells.firstIndex { $0 === clicked }
    }

    /// The component under `point`, in this view's coordinates.
    func index(at point: NSPoint) -> Int? {
        guard let cell = cell as? NSPathCell, let component = cell.pathComponentCell(at: point, withFrame: bounds, in: self) else { return nil }
        return cell.pathComponentCells.firstIndex { $0 === component }
    }

    private func drop(_ sender: any NSDraggingInfo) -> (folder: RemotePath, model: TransferModel)? {
        guard let coordinator, let index = index(at: convert(sender.draggingLocation, from: nil)),
              let entry = coordinator.entry(at: index), entry.takesDrops else { return nil }
        return (entry.path, coordinator.model)
    }

    private func operation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let (folder, model) = drop(sender) else { return [] }
        return dropAction(for: sender, onto: folder, model: model)?.operation ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {}
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { drop(sender) != nil }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let (folder, model) = drop(sender) else { return false }
        return performDrop(sender, onto: folder, model: model)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {}
}
