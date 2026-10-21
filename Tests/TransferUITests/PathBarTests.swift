import AppKit
import SwiftUI
import Testing
import TransferCore
@testable import TransferUI

/// The path bar: its trail for a location and a selection, where a click goes, its remembered
/// switch, and its place among the bars at the foot of the browser, in windows never seen.
@MainActor @Suite(.serialized)
struct PathBarTests {
    let server = SavedConnection(name: "myserver", host: "a")
    let home = RemotePath(string: "/home/shreeve/mvts")
    /// A folder whose name is not UTF-8.
    var odd: RemotePath { home.appending(name: [0x6F, 0xFF, 0x64]) }

    func path(_ name: String) -> RemotePath { home.appending(name: Array(name.utf8)) }

    /// Preferences of the test's own, never the user's or the test runner's domain.
    final class Defaults {
        let name = "transfer-tests-\(UUID().uuidString)"
        let store: UserDefaults
        init() { store = UserDefaults(suiteName: name)! }
        deinit { store.removePersistentDomain(forName: name) }
    }

    /// Logged in at `/home/shreeve/mvts`, holding a folder, a file, and a folder named in bytes
    /// that are not UTF-8, which holds a file.
    func connected(_ defaults: Defaults = Defaults()) async -> TransferModel {
        let tree: [RemotePath: [RemoteItem]] = [
            home: [RemoteItem(path: path("docs"), kind: .directory), RemoteItem(path: path("a.txt"), kind: .file, size: 1),
                   RemoteItem(path: odd, kind: .directory)],
            path("docs"): [],
            odd: [RemoteItem(path: odd.appending("inner.txt"), kind: .file, size: 1)],
        ]
        let model = TransferModel(provider: FakeProvider([FakeSession(server, home: home.display, folders: tree)]), defaults: defaults.store)
        await model.connect(server)
        _ = await eventually { model.items.count == 3 }
        return model
    }

    /// Offscreen, transparent, and ignoring the pointer, as in `ClickTests`.
    func window(_ view: some View, width: CGFloat = 960, height: CGFloat = 640) async -> NSWindow {
        _ = NSApplication.shared
        let window = OffscreenWindow(contentRect: NSRect(x: -5000, y: -5000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(300))
        return window
    }

    func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        (view as? T) ?? view.subviews.lazy.compactMap { first(type, in: $0) }.first
    }

    /// The server's name, then each folder down to the location; one selected item ends it,
    /// several do not; only the folders above the location are places to go.
    @Test func theTrailNamesTheServerEachFolderAndTheOneSelectedItem() async throws {
        let model = await connected()
        #expect(model.pathBar.map(\.title) == ["myserver", "home", "shreeve", "mvts"])
        #expect(model.pathBar.map(\.step.navigable) == [true, true, true, false])
        #expect(model.pathBar.first?.path == RemotePath(string: "/"))

        model.snapshot.selection = [path("a.txt")]
        #expect(model.pathBar.map(\.title) == ["myserver", "home", "shreeve", "mvts", "a.txt"])
        let last = try #require(model.pathBar.last)
        #expect(last.step.isSelection && !last.step.navigable)
        #expect(last.item?.kind == .file)
        #expect(!last.takesDrops)

        model.snapshot.selection = [path("docs")]
        #expect(model.pathBar.last?.takesDrops == true)

        model.snapshot.selection = [path("a.txt"), path("docs")]
        #expect(model.pathBar.map(\.title) == ["myserver", "home", "shreeve", "mvts"])

        // Column view: a selected folder is the location, which ends the trail once.
        model.setViewMode(.columns)
        model.selectInColumns([RemoteItem(path: path("docs"), kind: .directory)], parent: home)
        #expect(model.pathBar.map(\.title) == ["myserver", "home", "shreeve", "mvts", "docs"])
        #expect(model.pathBar.map(\.step.navigable) == [true, true, true, true, false])
        #expect(model.pathBar.last?.step.isSelection == false)
    }

    /// A name that is not UTF-8 shows replacement characters, and a click on it goes to its
    /// real bytes.
    @Test func aNameThatIsNotUTF8ShowsReplacementsAndGoesByItsBytes() async throws {
        let model = await connected()
        await model.navigate(odd.appending("inner"))
        let entry = try #require(model.pathBar.first { $0.path == odd })
        #expect(entry.title == "o\u{FFFD}d")
        #expect(entry.path.bytes.suffix(3) == [0x6F, 0xFF, 0x64])
        await model.goToPathBarFolder(entry.path)
        #expect(model.snapshot.path == odd)
        #expect(await eventually { model.items.map(\.name) == ["inner.txt"] })
    }

    /// A click on a folder goes there, keeping history so Back returns; the location and the
    /// selected item go nowhere and leave the selection alone. Through the coordinator, which
    /// checks the index against what the control was loaded with.
    @Test func aClickGoesUpAndBackReturnsWhileTheLocationIsInert() async throws {
        let model = await connected()
        let coordinator = PathBarControlView.Coordinator(model: model)
        let control = PathBarControl()
        model.snapshot.selection = [path("a.txt")]
        coordinator.show(model.pathBar, in: control)
        #expect(control.pathItems.count == 5)

        // The location and the selected item, then indexes the control was never loaded with.
        for index in [3, 4, 5, -1] { coordinator.go(to: index) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.snapshot.path == home)
        #expect(model.snapshot.selection == [path("a.txt")])
        await model.goBack()
        #expect(model.snapshot.path == home)

        coordinator.go(to: 1)
        #expect(await eventually { model.snapshot.path == RemotePath(string: "/home") })
        #expect(model.pathBar.map(\.title) == ["myserver", "home"])
        await model.goBack()
        #expect(model.snapshot.path == home)
        await model.goForward()
        #expect(model.snapshot.path == RemotePath(string: "/home"))
        // The server's name is the root.
        await model.navigate(home)
        coordinator.show(model.pathBar, in: control)
        coordinator.go(to: 0)
        #expect(await eventually { model.snapshot.path == RemotePath(string: "/") })
    }

    /// The control takes drops of files and of this app's own drags, finds the component under
    /// a point, and answers no point outside its components.
    @Test func theControlMapsPointsToItsComponents() async throws {
        let model = await connected()
        let window = await window(PathBar(model: model).frame(width: 900), width: 900, height: 40)
        defer { window.close() }
        let control = try #require(first(PathBarControl.self, in: window.contentView!))
        #expect(control.registeredDraggedTypes.contains(remoteDragType))
        #expect(control.registeredDraggedTypes.contains(.fileURL))
        #expect(!control.acceptsFirstResponder)
        #expect(control.pathItems.map(\.title) == ["myserver", "home", "shreeve", "mvts"])
        let cell = try #require(control.cell as? NSPathCell)
        for (index, component) in cell.pathComponentCells.enumerated() {
            let rect = cell.rect(of: component, withFrame: control.bounds, in: control)
            #expect(control.index(at: NSPoint(x: rect.midX, y: rect.midY)) == index)
        }
        #expect(control.index(at: NSPoint(x: control.bounds.maxX - 2, y: control.bounds.midY)) == nil)
    }

    /// Off by default; View > Show Path Bar shows it in the window, and the choice is what the
    /// next window opens with.
    @Test func theSwitchShowsTheBarAndIsRemembered() async throws {
        let defaults = Defaults()
        let model = await connected(defaults)
        #expect(!model.showsPathBar)
        let window = await window(ContentView(model: model))
        defer { window.close() }
        #expect(first(PathBarControl.self, in: window.contentView!) == nil)

        model.showsPathBar.toggle()
        #expect(defaults.store.bool(forKey: Preferences.showsPathBar))
        #expect(await eventually { first(PathBarControl.self, in: window.contentView!) != nil })
        #expect(TransferModel(provider: FakeProvider([]), defaults: defaults.store).showsPathBar)

        model.showsPathBar.toggle()
        #expect(!defaults.store.bool(forKey: Preferences.showsPathBar))
        #expect(await eventually { first(PathBarControl.self, in: window.contentView!) == nil })
        #expect(!TransferModel(provider: FakeProvider([]), defaults: defaults.store).showsPathBar)
    }

    /// The path bar sits between the browser and the clipboard bar, and the shelf below them,
    /// each the column's full width, with no two overlapping.
    @Test func thePathBarSitsBetweenTheBrowserAndTheClipboardBar() async throws {
        let model = await connected()
        model.showsPathBar = true
        model.operations = [TransferOperation(id: "t", title: "Copying a.txt", state: .queued)]
        model.showsShelf = true
        let clip = Clipboard.Clip(id: UUID(), source: .finder([URL(fileURLWithPath: "/tmp/x")]), name: "x", tally: ClipTally(), finder: .notNeeded)
        let slots = InspectorSlots()
        let window = await window(DetailColumn(model: model).environment(\.detailSlots, slots).environment(\.shownClip, clip).frame(width: 700, height: 500),
                                  width: 700, height: 500)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        let order = ["browser", "pathBar", "clipBar", "shelf"]
        #expect(await eventually { order.allSatisfy { slots.frames[$0].map { $0.height > 0 } ?? false } })
        let frames = order.compactMap { slots.frames[$0] }
        try #require(frames.count == order.count)
        #expect(frames[1].height == PathBar.height)
        for frame in frames { #expect(frame.width == 700) }
        for (upper, lower) in zip(frames, frames.dropFirst()) {
            #expect(upper.maxY <= lower.minY, "\(upper) over \(lower)")
            #expect(!upper.intersects(lower))
        }
        #expect(frames[0].minY >= 0 && frames[3].maxY <= 500)
    }
}
