import AppKit
import ImageIO
import SwiftUI
import Testing
import TransferCore
import UniformTypeIdentifiers
@testable import TransferUI

/// The inspector hosted for real in a window that is never seen, against a fake server whose
/// copies are local files, and the toolbar's inspector toggle in a real window chrome.
@MainActor @Suite(.serialized)
struct InspectorTests {
    let server = SavedConnection(name: "A", host: "a")
    let home = RemotePath(string: "/home")
    let longName = "a-photo-whose-name-is-far-too-long-to-fit-on-one-line-of-the-inspector-panel-at-any-width.png"

    func path(_ name: String) -> RemotePath { home.appending(name: Array(name.utf8)) }

    /// Preferences of the test's own, never the user's or the test runner's domain.
    final class Defaults {
        let name = "transfer-tests-\(UUID().uuidString)"
        let store: UserDefaults
        init() { store = UserDefaults(suiteName: name)! }
        deinit { store.removePersistentDomain(forName: name) }
    }

    /// Offscreen, transparent, and ignoring the pointer, as in `ClickTests`.
    func window(_ view: some View, width: CGFloat = 960, height: CGFloat = 640, style: NSWindow.StyleMask = [.borderless]) async -> NSWindow {
        _ = NSApplication.shared
        let window = OffscreenWindow(contentRect: NSRect(x: -5000, y: -5000, width: width, height: height), styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(300))
        return window
    }

    /// A small PNG on this Mac, standing in for the server's picture.
    func picture(in folder: URL) throws -> URL {
        let url = folder.appending(path: "photo.png")
        let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// Every kind of selection keeps the box and each fact's row in one place: a picture, a text
    /// file, a file of a type it cannot show, one over the limit, one still loading, a folder, and
    /// two items. The name stays one line, and a missing fact reads "—".
    @Test func theBoxAndEveryRowHoldStillWhateverIsSelected() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TransferUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = try picture(in: folder)
        let text = folder.appending(path: "notes.txt")
        try Data("let answer = 42\n".utf8).write(to: text)
        let when: UInt32 = 1_788_000_000
        func file(_ name: String, size: UInt64?) -> RemoteItem {
            RemoteItem(path: path(name), kind: .file, size: size, mtime: when, mode: 0o100644, owner: "steve", group: "staff")
        }
        let docs = RemoteItem(path: path("docs"), kind: .directory, mtime: when, mode: 0o40755, owner: "steve", group: "staff")
        let items = [
            docs,
            file(longName, size: 1000),
            file("notes.txt", size: 16),
            file("slow.png", size: 1000),
            file("huge.png", size: InspectorPreviewPlan.limit + 1),
            // Listed with no size, time, mode, or owner.
            RemoteItem(path: path("blob.xyz"), kind: .file),
        ]
        let session = FakeSession(server, folders: [home: items, docs.path: []])
        session.liveExtensions.value = ["txt"]
        session.inspectorCopies.value = [path(longName): png, path("notes.txt"): text, path("slow.png"): png]
        let defaults = Defaults()
        defaults.store.set(true, forKey: Preferences.showsInspector)
        let model = TransferModel(provider: FakeProvider([session]), defaults: defaults.store)
        #expect(model.showsInspector)
        let slots = InspectorSlots()
        let window = await window(InspectorColumn(model: model).environment(\.inspectorSlots, slots).frame(width: 320, height: 640), width: 320)
        defer { window.close() }
        await model.connect(server)
        #expect(await eventually { model.items.count == items.count })

        func select(_ names: String...) {
            model.snapshot.selection = Set(names.map(path))
            model.selectionChanged()
        }
        /// The slots once the view has drawn the state.
        func frames() async -> [String: CGRect] {
            try? await Task.sleep(for: .milliseconds(150))
            window.contentView?.layoutSubtreeIfNeeded()
            return slots.frames
        }
        let fixed = ["box", "name", "kind", "modified", "access"]
        var seen: [String: [String: CGRect]] = [:]

        select(longName)
        #expect(await eventually { if case .picture? = model.inspectorPreview { true } else { false } })
        seen["picture"] = await frames()
        let one = InspectorFacts(model: model)
        #expect(one.name == longName)
        #expect(one.kindAndSize.hasSuffix(" · 1.0 kB"))
        #expect(one.modified.hasPrefix(Format.day(when) + " · "))
        #expect(one.access == "rw-r--r-- · steve:staff")

        select("notes.txt")
        #expect(await eventually { if case .text? = model.inspectorPreview { true } else { false } })
        seen["text"] = await frames()

        select("blob.xyz")
        #expect(await eventually { model.inspectorPreview == nil && model.inspectorWait == .icon })
        seen["unsupported"] = await frames()
        let bare = InspectorFacts(model: model)
        #expect(bare.kindAndSize.hasSuffix(" · —"))
        #expect(bare.modified == "—")
        #expect(bare.access == "—")

        select("huge.png")
        #expect(await eventually { model.inspectorPreview == nil && model.inspectorWait == .icon })
        seen["too large"] = await frames()

        session.inspectorTime.value = .seconds(30)
        select("slow.png")
        #expect(await eventually { model.inspectorWait == .spinner })
        #expect(model.inspectorPreview == nil)
        seen["loading"] = await frames()
        session.inspectorTime.value = nil

        select("docs")
        #expect(await eventually { model.inspectorWait == .icon })
        seen["folder"] = await frames()
        let folderFacts = InspectorFacts(model: model)
        #expect(folderFacts.kindAndSize == "Folder · —")
        #expect(folderFacts.file == nil)

        select("notes.txt", "docs")
        #expect(await eventually { model.inspectorWait == .icon && model.inspectorPreview == nil })
        seen["two items"] = await frames()
        let two = InspectorFacts(model: model)
        #expect(two.name == "2 items selected")
        #expect(two.kindAndSize == "1 file, 1 folder · 16 B")
        #expect(two.modified == "—")

        // Neither a server nor the box fetched anything it could not show.
        let fetched = session.calls.value.filter { $0.hasPrefix("inspector ") }
        #expect(!fetched.contains { $0.hasSuffix("blob.xyz") || $0.hasSuffix("huge.png") })

        let reference = try #require(seen["picture"])
        for key in fixed { #expect(reference[key] != nil, "\(key)") }
        let box = try #require(reference["box"])
        // The panel's width less its margins.
        #expect(box.width == window.frame.width - 32)
        #expect(box.height == InspectorColumn.boxHeight)
        for (state, frames) in seen {
            for key in fixed { #expect(frames[key] == reference[key], "\(state): \(key)") }
        }
        // One line however long the name: as tall as a short name, and no wider than its row.
        let name = try #require(reference["nameText"]), row = try #require(reference["name"])
        let short = try #require(seen["two items"]?["nameText"])
        #expect(name.height == short.height)
        #expect(name.height < InspectorColumn.nameHeight + 1)
        #expect(name.width <= row.width)
    }

    /// The location's facts when nothing is selected, with its item count once listed.
    @Test func nothingSelectedDescribesTheFolder() async throws {
        let session = FakeSession(server, folders: [home: [RemoteItem(path: path("a"), kind: .file, size: 1), RemoteItem(path: path("b"), kind: .file, size: 1)]])
        let defaults = Defaults()
        let model = TransferModel(provider: FakeProvider([session]), defaults: defaults.store)
        await model.connect(server)
        #expect(await eventually { model.items.count == 2 })
        let facts = InspectorFacts(model: model)
        #expect(facts.name == "home")
        #expect(facts.kindAndSize == "Folder · 2 items")
        #expect(facts.file == nil)
    }

    /// The toolbar's inspector toggle does what Command-I does, the split follows, and the
    /// choice is what the next window opens with.
    @Test func theToolbarToggleShowsTheInspectorAndIsRemembered() async throws {
        let defaults = Defaults()
        let provider = FakeProvider([FakeSession(server)])
        let model = TransferModel(provider: provider, defaults: defaults.store)
        #expect(!model.showsInspector)
        let window = await window(ContentView(model: model), style: [.titled, .resizable])
        defer { window.close() }
        let controller = try #require(chrome(in: window))
        let inspector = controller.splitViewItems[2]
        #expect(inspector.isCollapsed)
        #expect(inspector.maximumThickness == 480)
        let item = try #require(window.toolbar?.items.first { $0.itemIdentifier == ChromeItem.inspector })
        let identifiers = window.toolbar?.items.map(\.itemIdentifier) ?? []
        #expect(identifiers.firstIndex(of: ChromeItem.inspector) == identifiers.firstIndex(of: ChromeItem.transfers).map { $0 + 1 })
        let action = try #require(item.action)

        #expect(NSApp.sendAction(action, to: item.target, from: item))
        #expect(model.showsInspector)
        #expect(defaults.store.bool(forKey: Preferences.showsInspector))
        #expect(await eventually { !inspector.isCollapsed })
        #expect(TransferModel(provider: provider, defaults: defaults.store).showsInspector)

        // The split view controller's own action goes through the model too.
        controller.toggleInspector(nil)
        #expect(!model.showsInspector)
        #expect(!defaults.store.bool(forKey: Preferences.showsInspector))
        #expect(await eventually { inspector.isCollapsed })
        #expect(!TransferModel(provider: provider, defaults: defaults.store).showsInspector)
    }

    /// Back and Forward are dim until the history has somewhere to go, and follow it.
    @Test func backAndForwardFollowTheHistory() async throws {
        let home = RemotePath(string: "/home")
        let docs = home.appending("docs")
        let session = FakeSession(server, home: "/home", folders: [home: [RemoteItem(path: docs, kind: .directory)], docs: []])
        let model = TransferModel(provider: FakeProvider([session]), defaults: Defaults().store)
        let window = await window(ContentView(model: model), style: [.titled, .resizable])
        defer { window.close() }
        await model.connect(server)
        let group = try #require(window.toolbar?.items.first { $0.itemIdentifier == ChromeItem.backForward } as? NSToolbarItemGroup)
        func state() -> [Bool] { group.subitems.map(\.isEnabled) }
        #expect(!model.canGoBack && !model.canGoForward)
        #expect(await eventually { state() == [false, false] })

        await model.navigate(docs)
        #expect(model.canGoBack && !model.canGoForward)
        #expect(await eventually { state() == [true, false] })
        await model.goBack()
        #expect(!model.canGoBack && model.canGoForward)
        #expect(await eventually { state() == [false, true] })
        await model.goForward()
        #expect(await eventually { state() == [true, false] })
    }

    /// A window opens with the inspector as the last one left it, whatever the split view's
    /// autosave held, and landing does not change the saved choice.
    @Test func aNewWindowOpensWithTheRememberedInspector() async throws {
        for shown in [true, false, true] {
            let defaults = Defaults()
            defaults.store.set(shown, forKey: Preferences.showsInspector)
            let model = TransferModel(provider: FakeProvider([FakeSession(server)]), defaults: defaults.store)
            let window = await window(ContentView(model: model), style: [.titled, .resizable])
            let controller = try #require(chrome(in: window))
            try? await Task.sleep(for: .milliseconds(300))
            #expect(controller.splitViewItems[2].isCollapsed == !shown)
            #expect(model.showsInspector == shown)
            #expect(defaults.store.bool(forKey: Preferences.showsInspector) == shown)
            window.close()
        }
    }

    func chrome(in window: NSWindow) -> ChromeController? {
        func find(_ view: NSView) -> ChromeContainer? {
            (view as? ChromeContainer) ?? view.subviews.lazy.compactMap(find).first
        }
        return window.contentView.flatMap(find)?.controller
    }
}
