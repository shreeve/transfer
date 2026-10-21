import AppKit
import SwiftUI
import Testing
import TransferCore
import WebKit
@testable import TransferUI

/// Moving between files never empties the preview area: the previous preview stays until the
/// next is ready, and a text preview's web view is kept and loads behind the page on show.
extension InspectorTests {
    /// The web view a hosted `SourcePreview` made, if one is in `view`.
    func sourcePreview(in view: NSView?) -> SourcePreviewView? {
        guard let view else { return nil }
        return (view as? SourcePreviewView) ?? view.subviews.lazy.compactMap { sourcePreview(in: $0) }.first
    }

    /// The text a web view is showing, read from its page.
    func pageText(_ view: WKWebView) async -> String {
        (try? await view.evaluateJavaScript("document.body.innerText") as? String) ?? ""
    }

    /// A page loads behind the one on show and takes its place only when it finishes; a newer
    /// request supersedes one in flight, and asking for the page on show abandons it.
    @Test func aPageSwapsInOnlyOnceItsLoadFinishes() throws {
        var swap = PageSwap<String>()
        func request(_ page: String) -> (buffer: Int, load: Int)? { swap.request(page) }
        func finished(_ load: Int) -> Bool { swap.finished(load) }

        let first = try #require(request("a"))
        #expect(first.buffer == 1 && swap.front == 0 && swap.shown == nil)
        #expect(request("a") == nil)
        #expect(finished(first.load))
        #expect(swap.front == 1 && swap.shown == "a" && swap.pending == nil)

        let b = try #require(request("b"))
        #expect(b.buffer == 0 && swap.shown == "a")
        let c = try #require(request("c"))
        #expect(c.buffer == 0)
        // The superseded load's end changes nothing; the newer one's swaps.
        #expect(!finished(b.load))
        #expect(swap.front == 1 && swap.shown == "a")
        #expect(finished(c.load))
        #expect(swap.front == 0 && swap.shown == "c")

        // Back to the page on show before the next one lands: the load in flight is dropped.
        let d = try #require(request("d"))
        #expect(request("c") == nil)
        #expect(swap.pending == nil)
        #expect(!finished(d.load))
        #expect(swap.front == 0 && swap.shown == "c")
    }

    /// Real web views, offscreen: the next file's page loads in the web view behind, and the
    /// page on show stays the old one until that load finishes. Neither view is replaced.
    @Test func theOldPageStaysUpUntilTheNewOneHasLoaded() async throws {
        let view = SourcePreviewView()
        view.frame = NSRect(x: 0, y: 0, width: 288, height: 400)
        let window = await window(EmptyView(), width: 288, height: 400)
        defer { window.close() }
        window.contentView?.addSubview(view)
        let buffers = view.buffers.map(ObjectIdentifier.init)
        let alpha = SourcePage(text: "let alpha = 1", wraps: false)
        let beta = SourcePage(text: "let beta = 2", wraps: false)

        view.show(alpha)
        #expect(await eventually { view.swap.shown == alpha })
        let first = view.front
        #expect(first.alphaValue == 1)
        #expect(await pageText(first).contains("alpha"))

        view.show(beta)
        // Until the load behind finishes, the front is the old view and still shows the old page.
        #expect(view.front === first && view.swap.shown == alpha)
        #expect(await pageText(first).contains("alpha"))
        var waits = 0
        while view.swap.shown != beta, waits < 400 {
            #expect(view.front === first && first.alphaValue == 1)
            try? await Task.sleep(for: .milliseconds(5))
            waits += 1
        }
        #expect(view.swap.shown == beta)
        let second = view.front
        #expect(second !== first && !second.isLoading)
        #expect(second.alphaValue == 1 && first.alphaValue == 0)
        #expect(await pageText(second).contains("beta"))
        #expect(view.buffers.map(ObjectIdentifier.init) == buffers)
        // The mouse reaches the page on show, never the one behind.
        let hit = view.hitTest(NSPoint(x: 100, y: 100))
        #expect(hit === second || hit?.isDescendant(of: second) == true)
    }

    /// Arrowing from one text file to the next keeps the inspector's web views: the same
    /// objects show both files, and the area never goes empty between them.
    @Test func theWebViewIsKeptFromOneTextFileToTheNext() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TransferUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let one = folder.appending(path: "one.txt"), two = folder.appending(path: "two.txt")
        try Data("let one = 1\n".utf8).write(to: one)
        try Data("let two = 2\n".utf8).write(to: two)
        let items = [RemoteItem(path: path("one.txt"), kind: .file, size: 12), RemoteItem(path: path("two.txt"), kind: .file, size: 12)]
        let session = FakeSession(server, folders: [home: items])
        session.liveExtensions.value = ["txt"]
        session.inspectorCopies.value = [path("one.txt"): one, path("two.txt"): two]
        let defaults = Defaults()
        defaults.store.set(true, forKey: Preferences.showsInspector)
        let model = TransferModel(provider: FakeProvider([session]), defaults: defaults.store)
        let window = await window(InspectorColumn(model: model).frame(width: 320, height: 640), width: 320)
        defer { window.close() }
        await model.connect(server)
        #expect(await eventually { model.items.count == 2 })

        model.snapshot.selection = [path("one.txt")]
        model.selectionChanged()
        #expect(await eventually { sourcePreview(in: window.contentView)?.swap.shown?.text == "let one = 1\n" })
        let view = try #require(sourcePreview(in: window.contentView))
        let buffers = view.buffers.map(ObjectIdentifier.init)

        model.snapshot.selection = [path("two.txt")]
        model.selectionChanged()
        var waits = 0
        while view.swap.shown?.text != "let two = 2\n", waits < 400 {
            #expect(model.inspectorPreview != nil)
            #expect(sourcePreview(in: window.contentView) === view)
            try? await Task.sleep(for: .milliseconds(5))
            waits += 1
        }
        #expect(view.swap.shown?.text == "let two = 2\n")
        #expect(sourcePreview(in: window.contentView) === view)
        #expect(view.buffers.map(ObjectIdentifier.init) == buffers)
    }

    /// A fast fetch replaces the previous preview with no gap. A slow one leaves the previous
    /// preview up until `PreviewTiming.icon`, then the icon; a held key cannot keep a stale
    /// preview up longer. A folder shows its icon at once.
    @Test func thePreviousPreviewStaysUntilTheNextIsReadyOrTheIconIsDue() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TransferUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var items = [RemoteItem(path: path("docs"), kind: .directory)]
        var copies: [RemotePath: URL] = [:]
        for name in ["a", "b", "c", "d"] {
            let url = folder.appending(path: "\(name).txt")
            try Data("\(name)\n".utf8).write(to: url)
            items.append(RemoteItem(path: path("\(name).txt"), kind: .file, size: 2))
            copies[path("\(name).txt")] = url
        }
        let session = FakeSession(server, folders: [home: items, path("docs"): []])
        session.liveExtensions.value = ["txt"]
        session.inspectorCopies.value = copies
        let defaults = Defaults()
        defaults.store.set(true, forKey: Preferences.showsInspector)
        let model = TransferModel(provider: FakeProvider([session]), defaults: defaults.store)
        await model.connect(server)
        #expect(await eventually { model.items.count == items.count })
        func select(_ name: String) {
            model.snapshot.selection = [path(name)]
            model.selectionChanged()
        }
        /// Polls until `done`, checking `meanwhile` on every look; the instant it came true.
        func watch(until done: () -> Bool, meanwhile: () -> Bool) async -> ContinuousClock.Instant? {
            for _ in 0..<1000 {
                if done() { return .now }
                #expect(meanwhile())
                try? await Task.sleep(for: .milliseconds(2))
            }
            return nil
        }

        select("a.txt")
        #expect(await eventually { model.inspectorPreview == .text("a\n") })
        select("b.txt")
        // The area holds a's preview until b's lands: never empty, never the icon.
        #expect(await watch(until: { model.inspectorPreview == .text("b\n") },
                            meanwhile: { model.inspectorPreview == .text("a\n") && model.inspectorWait == .nothing }) != nil)

        session.inspectorTime.value = .seconds(30)
        let start = ContinuousClock.now
        select("c.txt")
        let cleared = try #require(await watch(until: { model.inspectorPreview == nil },
                                               meanwhile: { model.inspectorPreview == .text("b\n") && model.inspectorWait == .nothing }))
        #expect(cleared - start >= PreviewTiming.icon)
        #expect(model.inspectorWait == .icon)
        #expect(await eventually { model.inspectorWait == .spinner })

        // A second move while the first is still loading starts no new 500 ms for the old preview.
        session.inspectorTime.value = nil
        select("a.txt")
        #expect(await eventually { model.inspectorPreview == .text("a\n") })
        session.inspectorTime.value = .seconds(30)
        let stale = ContinuousClock.now
        select("c.txt")
        try? await Task.sleep(until: stale + .milliseconds(400))
        let moved = ContinuousClock.now
        select("d.txt")
        let gone = try #require(await watch(until: { model.inspectorPreview == nil }, meanwhile: { model.inspectorPreview == .text("a\n") }))
        #expect(gone - stale >= PreviewTiming.icon)
        #expect(gone < moved + PreviewTiming.icon)
        #expect(model.inspectorWait == .icon)

        // A folder has no preview to wait for: its icon, at once.
        session.inspectorTime.value = nil
        select("b.txt")
        #expect(await eventually { model.inspectorPreview == .text("b\n") })
        select("docs")
        #expect(model.inspectorPreview == nil && model.inspectorWait == .icon)
    }

    /// Text arriving over a picture, or over the icon, loads hidden: what was on screen stays
    /// until the page is in, then the page replaces it in one step, never an empty area.
    @Test func aPictureStaysUntilTheTextReplacingItHasLoaded() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TransferUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = try picture(in: folder)
        let notes = folder.appending(path: "notes.txt")
        try Data("let notes = 1\n".utf8).write(to: notes)
        let items = [
            RemoteItem(path: path("docs"), kind: .directory),
            RemoteItem(path: path("photo.png"), kind: .file, size: 1000),
            RemoteItem(path: path("notes.txt"), kind: .file, size: 14),
        ]
        let session = FakeSession(server, folders: [home: items, path("docs"): []])
        session.liveExtensions.value = ["txt"]
        session.inspectorCopies.value = [path("photo.png"): png, path("notes.txt"): notes]
        let defaults = Defaults()
        defaults.store.set(true, forKey: Preferences.showsInspector)
        let model = TransferModel(provider: FakeProvider([session]), defaults: defaults.store)
        let slots = InspectorSlots()
        let window = await window(InspectorColumn(model: model).environment(\.inspectorSlots, slots).frame(width: 320, height: 640), width: 320)
        defer { window.close() }
        await model.connect(server)
        #expect(await eventually { model.items.count == items.count })
        func select(_ name: String) {
            model.snapshot.selection = [path(name)]
            model.selectionChanged()
        }
        /// Selects `name` over what is on screen, `before`, and watches until the page is on
        /// screen: `before` stays the whole time, the text waits hidden for its page at least
        /// once, and nothing else is put up on the way.
        func replace(_ before: String, with name: String) async {
            let mark = slots.screens.count
            var held = false
            select(name)
            for _ in 0..<1000 where slots.screens.last != "text" {
                #expect(slots.screens.last == before)
                if case .text? = model.inspectorPreview, sourcePreview(in: window.contentView) != nil { held = true }
                try? await Task.sleep(for: .milliseconds(2))
            }
            #expect(held)
            #expect(Array(slots.screens[mark...]) == ["text"])
            // On screen only once its page had loaded.
            #expect(sourcePreview(in: window.contentView)?.swap.shown?.text == "let notes = 1\n")
        }

        select("photo.png")
        #expect(await eventually { slots.screens.last == "picture" })
        await replace("picture", with: "notes.txt")

        select("docs")
        #expect(await eventually { slots.screens.last == "icon" })
        await replace("icon", with: "notes.txt")
    }
}
