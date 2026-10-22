import AppKit
import SwiftUI
import TransferCore

/// The toolbar's Live badge: what it says and what VoiceOver reads, for `count` Live files in
/// the library. Hidden at zero.
enum LiveBadge {
    static func title(count: Int) -> String { count > 1 ? "Live \(count)" : "Live" }
    static func accessibilityLabel(count: Int) -> String { "Live files: \(count)" }
    static let help = "Files open Live: every save uploads. Click to see them or stop editing them Live."
}

/// The badge itself: bold white text on a red capsule, drawn here so it reads the same in every
/// appearance. A click, or VoiceOver's press, sends its action.
final class LiveBadgeView: NSControl {
    static let font = NSFont.boldSystemFont(ofSize: 12)
    static let height: CGFloat = 22
    private var pressed = false {
        didSet { needsDisplay = true }
    }

    var count = 0 {
        didSet {
            guard count != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
            setAccessibilityLabel(LiveBadge.accessibilityLabel(count: count))
        }
    }

    var title: String { LiveBadge.title(count: count) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(LiveBadge.accessibilityLabel(count: count))
        toolTip = LiveBadge.help
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var attributedTitle: NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: NSColor.white])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributedTitle.size().width) + 20, height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let capsule = NSRect(x: 0, y: (bounds.height - Self.height) / 2, width: bounds.width, height: Self.height)
        (pressed ? NSColor.systemRed.blended(withFraction: 0.25, of: .black) ?? .systemRed : .systemRed).setFill()
        NSBezierPath(roundedRect: capsule, xRadius: Self.height / 2, yRadius: Self.height / 2).fill()
        let text = attributedTitle
        let size = text.size()
        text.draw(at: NSPoint(x: capsule.midX - size.width / 2, y: capsule.midY - size.height / 2))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { sendAction(action, to: target) }
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
    }
}

/// The small capsule the inspector's header shows for a Live file, in the badge's colors: "Live",
/// or "Conflict" for one waiting for an answer.
struct LiveCapsule: View {
    let text: String
    static let height: CGFloat = 14

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(height: Self.height)
            .background(Capsule().fill(Color(nsColor: .systemRed)))
            .fixedSize()
    }
}

/// The marker on a Live item's icon in the icon, list, and column views: a red dot at the icon's
/// lower right, with an exclamation mark for a conflict.
enum LiveMark: Equatable {
    case live, conflict

    init(_ file: LiveFile) {
        self = file.conflict ? .conflict : .live
    }

    var accessibilityLabel: String {
        switch self {
        case .live: "Live"
        case .conflict: "Live, conflict"
        }
    }

    /// The marker's square at the lower right of an icon drawn in `icon`.
    static func rect(on icon: NSRect, size: CGFloat, flipped: Bool) -> NSRect {
        NSRect(x: icon.maxX - size + 1, y: flipped ? icon.maxY - size + 1 : icon.minY - 1, width: size, height: size)
    }

    /// Draws the marker filling `rect`, ringed in the window's background so it stands off the icon.
    func draw(in rect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.systemRed.setFill()
        let dot = rect.insetBy(dx: max(1, rect.width / 10), dy: max(1, rect.height / 10))
        NSBezierPath(ovalIn: dot).fill()
        guard self == .conflict else { return }
        let mark = NSAttributedString(string: "!", attributes: [
            .font: NSFont.boldSystemFont(ofSize: dot.height * 0.85),
            .foregroundColor: NSColor.white,
        ])
        let size = mark.size()
        mark.draw(at: NSPoint(x: dot.midX - size.width / 2, y: dot.midY - size.height / 2))
    }
}

/// `LiveMark` as a view, laid over an icon. Hidden while its item is not Live.
final class LiveMarkView: NSView {
    var mark: LiveMark? {
        didSet {
            guard mark != oldValue else { return }
            isHidden = mark == nil
            setAccessibilityElement(mark != nil)
            setAccessibilityLabel(mark?.accessibilityLabel)
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        setAccessibilityRole(.image)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Clicks, drags, and drops go to the cell under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        mark?.draw(in: bounds)
    }
}

/// The toolbar badge's popover: every Live file in the library, with its server and state, each
/// with Stop, and Stop All, plus Stop Selected while the window has Live files selected.
struct LiveFilesList: View {
    let model: TransferModel
    @Environment(\.liveListSlots) private var slots
    nonisolated static let space = "liveList"
    static let width: CGFloat = 380
    static let rowHeight: CGFloat = 38
    static let rowsShown = 8

    var body: some View {
        let files = model.libraryLive
        let selected = model.selectedLiveFiles
        VStack(alignment: .leading, spacing: 0) {
            Text("Live Files")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            Divider()
            if files.isEmpty {
                Text("No files are open Live.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
            } else if files.count > Self.rowsShown {
                ScrollView { rows(files) }
                    .frame(height: Self.rowHeight * CGFloat(Self.rowsShown))
            } else {
                rows(files)
            }
            Divider()
            HStack {
                if !selected.isEmpty {
                    Button("Stop Selected (\(selected.count))") { Task { await model.stopSelectedLive() } }
                        .help("Stop editing the selected files Live")
                        .slot("stop selected", slots, in: Self.space)
                }
                Spacer()
                Button("Stop All") { Task { await model.stopAllLive() } }
                    .disabled(files.isEmpty)
                    .help("Stop editing every file Live, on every server")
                    .slot("stop all", slots, in: Self.space)
            }
            .padding(10)
        }
        .frame(width: Self.width)
        .coordinateSpace(.named(Self.space))
    }

    /// A row's second line: the server, then what the file is doing.
    static func caption(_ file: LibraryLiveFile) -> String {
        "\(file.server) · \(file.file.status.listLabel)"
    }

    private func rows(_ files: [LibraryLiveFile]) -> some View {
        VStack(spacing: 0) {
            ForEach(files) { file in
                LiveFileRow(file: file, slots: slots) { Task { await model.stopLive([file.id]) } }
                    .frame(height: Self.rowHeight)
            }
        }
    }
}

/// One Live file in the list: icon, name, then server and state, and its Stop button.
private struct LiveFileRow: View {
    let file: LibraryLiveFile
    let slots: InspectorSlots?
    let stop: () -> Void

    var body: some View {
        let status = file.file.status
        HStack(spacing: 8) {
            Image(nsImage: ItemIcon.image(for: RemoteItem(path: file.file.path, kind: .file)))
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.file.path.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(LiveFilesList.caption(file))
                    .font(.caption)
                    .foregroundStyle(status == .conflict ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(file.file.path.display)
            .accessibilityElement(children: .combine)
            .slot("row \(file.file.path.name)", slots, in: LiveFilesList.space)
            Spacer(minLength: 8)
            Button("Stop", action: stop)
                .controlSize(.small)
                .help("Stop editing “\(file.file.path.name)” Live")
                .accessibilityLabel("Stop \(file.file.path.name)")
                .slot("stop \(file.file.path.name)", slots, in: LiveFilesList.space)
        }
        .padding(.horizontal, 12)
    }
}

/// Stop Live Editing's warning.
enum StopLiveSheet {
    /// Names shown before "and N more".
    static let namesShown = 8

    static func detail(_ count: Int) -> String {
        count == 1
            ? "1 file has edits the server doesn’t have; they will be discarded."
            : "\(count) files have edits the server doesn’t have; they will be discarded."
    }
}
