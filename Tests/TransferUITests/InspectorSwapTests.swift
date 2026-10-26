import AppKit
import Quartz
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
        #expect(await eventually(seconds: 10) { view.swap.shown == alpha })
        let first = view.front
        #expect(first.alphaValue == 1)
        #expect(await pageText(first).contains("alpha"))

        view.show(beta)
        // Until the load behind finishes, the front is the old view and still shows the old page.
        #expect(view.front === first && view.swap.shown == alpha)
        #expect(await pageText(first).contains("alpha"))
        var waits = 0
        while view.swap.shown != beta, waits < 2000 {
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
        // A clock that moves only when told: the web view may take longer than the icon's 500 ms
        // to load on a loaded machine, and this test is about the view kept, not that deadline.
        let time = ManualClock()
        model.previewClock = time.clock
        let window = await window(InspectorColumn(model: model).frame(width: 320, height: 640), width: 320)
        defer { window.close() }
        await model.connect(server)
        #expect(await eventually { model.items.count == 2 })

        time.advance(to: time.now + .seconds(1))
        model.snapshot.selection = [path("one.txt")]
        model.selectionChanged()
        #expect(await eventually(seconds: 10) { sourcePreview(in: window.contentView)?.swap.shown?.text == "let one = 1\n" })
        let view = try #require(sourcePreview(in: window.contentView))
        let buffers = view.buffers.map(ObjectIdentifier.init)

        time.advance(to: time.now + .seconds(1))
        model.snapshot.selection = [path("two.txt")]
        model.selectionChanged()
        var waits = 0
        while view.swap.shown?.text != "let two = 2\n", waits < 2000 {
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
    /// preview up until `PreviewTiming.icon`, then the icon, and the spinner at
    /// `PreviewTiming.spinner`; a held key cannot keep a stale preview up longer. A folder shows
    /// its icon at once. Time is a `ManualClock`, so each boundary is checked to the millisecond.
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
        let time = ManualClock()
        model.previewClock = time.clock
        await model.connect(server)
        #expect(await eventually { model.items.count == items.count })
        /// A second after the last move, so no move reads as a held key.
        func select(_ name: String) {
            time.advance(to: time.now + .seconds(1))
            model.snapshot.selection = [path(name)]
            model.selectionChanged()
        }
        /// Lets every task the clock woke run its course.
        func settle() async {
            for _ in 0..<10 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(30))
        }
        func phase() -> PreviewPhase { PreviewPhase(preview: model.inspectorPreview, wait: model.inspectorWait) }
        let a = PreviewPhase(preview: .text("a\n")), b = PreviewPhase(preview: .text("b\n"))
        let icon = PreviewPhase(preview: nil, wait: .icon), spinner = PreviewPhase(preview: nil, wait: .spinner)

        select("a.txt")
        #expect(await eventually { phase() == a })
        // The clock stands still, so the area holds a's preview until b's lands: never the icon.
        select("b.txt")
        var looks = 0
        while phase() != b, looks < 2000 {
            #expect(phase() == a)
            try? await Task.sleep(for: .milliseconds(2))
            looks += 1
        }
        #expect(phase() == b)

        // A slow fetch: b's preview until the instant `icon` is due, then the icon, then the spinner.
        session.inspectorTime.value = .seconds(30)
        select("c.txt")
        let moved = time.now
        await settle()
        #expect(phase() == b)
        time.advance(to: moved + PreviewTiming.icon - .milliseconds(1))
        await settle()
        #expect(phase() == b)
        time.advance(to: moved + PreviewTiming.icon)
        #expect(await eventually { phase() == icon })
        time.advance(to: moved + PreviewTiming.spinner - .milliseconds(1))
        await settle()
        #expect(phase() == icon)
        time.advance(to: moved + PreviewTiming.spinner)
        #expect(await eventually { phase() == spinner })

        // A second move while the first is still loading starts no new wait for the old preview:
        // it goes at `icon` after the first move, not after the second.
        session.inspectorTime.value = nil
        select("a.txt")
        #expect(await eventually { phase() == a })
        session.inspectorTime.value = .seconds(30)
        select("c.txt")
        let stale = time.now
        time.advance(to: stale + .milliseconds(400))
        model.snapshot.selection = [path("d.txt")]
        model.selectionChanged()
        time.advance(to: stale + PreviewTiming.icon - .milliseconds(1))
        await settle()
        #expect(phase() == a)
        time.advance(to: stale + PreviewTiming.icon)
        #expect(await eventually { phase() == icon })

        // A folder has no preview to wait for: its icon, at once.
        session.inspectorTime.value = nil
        select("b.txt")
        #expect(await eventually { phase() == b })
        select("docs")
        #expect(phase() == icon)
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
        // Time moves only between selections, so however slowly a page loads on a busy machine,
        // the old preview's 500 ms never runs out under it.
        let time = ManualClock()
        model.previewClock = time.clock
        let slots = InspectorSlots()
        let window = await window(InspectorColumn(model: model).environment(\.inspectorSlots, slots).frame(width: 320, height: 640), width: 320)
        defer { window.close() }
        await model.connect(server)
        #expect(await eventually { model.items.count == items.count })
        func select(_ name: String) {
            time.advance(to: time.now + .seconds(1))
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
            for _ in 0..<5000 where slots.screens.last != "text" {
                #expect(slots.screens.last == before)
                // The document background comes with the page, never ahead of it.
                #expect(slots.surface == "gray")
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
    /// A navigation ends before its page is on screen, so the page goes to the front only once
    /// it has been presented (held here), and a load superseded meanwhile changes nothing and
    /// leaves the newer one's end to swap.
    @Test func aPageComesToTheFrontOnlyOnceItIsPresented() async throws {
        let view = SourcePreviewView()
        view.frame = NSRect(x: 0, y: 0, width: 288, height: 400)
        let window = await window(EmptyView(), width: 288, height: 400)
        defer { window.close() }
        window.contentView?.addSubview(view)
        var held: [(WKWebView, @MainActor () -> Void)] = []
        view.afterPresentation = { held.append(($0, $1)) }
        let alpha = SourcePage(text: "let alpha = 1", wraps: false)
        let beta = SourcePage(text: "let beta = 2", wraps: false)
        let gamma = SourcePage(text: "let gamma = 3", wraps: false)

        view.show(alpha)
        #expect(await eventually(seconds: 10) { held.count == 1 })
        // Loaded, not yet presented: nothing is on show.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(view.swap.shown == nil)
        held[0].1()
        #expect(view.swap.shown == alpha)
        let first = view.front
        #expect(first.alphaValue == 1)

        view.show(beta)
        #expect(await eventually(seconds: 10) { held.count == 2 })
        #expect(held[1].0 !== first)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(view.swap.shown == alpha && view.front === first && first.alphaValue == 1)
        // Superseded before it is presented: its presentation changes nothing.
        view.show(gamma)
        held[1].1()
        #expect(view.swap.shown == alpha && view.front === first)
        #expect(await eventually(seconds: 10) { held.count == 3 })
        held[2].1()
        #expect(view.swap.shown == gamma && view.front !== first)
    }

    /// The real presentation wait ends, through the snapshot or its limit, so a page always
    /// comes in.
    @Test func thePresentationWaitEnds() async throws {
        let view = SourcePreviewView()
        view.frame = NSRect(x: 0, y: 0, width: 288, height: 400)
        let window = await window(EmptyView(), width: 288, height: 400)
        defer { window.close() }
        window.contentView?.addSubview(view)
        let alpha = SourcePage(text: "let alpha = 1", wraps: false)
        view.show(alpha)
        #expect(await eventually(seconds: 10) { view.swap.shown == alpha })
    }

    /// The Quick Look view in `view`, if one is there.
    func quickLookView(in view: NSView?) -> QLPreviewView? {
        guard let view else { return nil }
        return (view as? QLPreviewView) ?? view.subviews.lazy.compactMap { quickLookView(in: $0) }.first
    }

    /// Quick Look arriving over a picture, text, or the icon loads hidden: what was on screen
    /// stays until the Quick Look view has drawn (its remote view is in) or its wait is up, then
    /// that same view replaces it in one step. It used to go up at once, an empty gray box until
    /// Quick Look drew.
    @Test func aPictureStaysUntilTheQuickLookReplacingItHasDrawn() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TransferUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = try picture(in: folder)
        let pdf = folder.appending(path: "paper.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let page = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        page.beginPDFPage(nil)
        page.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        page.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
        page.endPDFPage()
        page.closePDF()
        let size = UInt64(try #require(try FileManager.default.attributesOfItem(atPath: pdf.path)[.size] as? Int))
        let items = [
            RemoteItem(path: path("docs"), kind: .directory),
            RemoteItem(path: path("photo.png"), kind: .file, size: 1000),
            RemoteItem(path: path("paper.pdf"), kind: .file, size: size),
            RemoteItem(path: path("notes.txt"), kind: .file, size: 14),
        ]
        let notes = folder.appending(path: "notes.txt")
        try Data("let notes = 1\n".utf8).write(to: notes)
        let session = FakeSession(server, folders: [home: items, path("docs"): []])
        session.liveExtensions.value = ["txt"]
        session.inspectorCopies.value = [path("photo.png"): png, path("paper.pdf"): pdf, path("notes.txt"): notes]
        let defaults = Defaults()
        defaults.store.set(true, forKey: Preferences.showsInspector)
        let model = TransferModel(provider: FakeProvider([session]), defaults: defaults.store)
        // Time moves only between selections, so the old preview's 500 ms never runs out.
        let time = ManualClock()
        model.previewClock = time.clock
        let slots = InspectorSlots()
        let window = await window(InspectorColumn(model: model).environment(\.inspectorSlots, slots).frame(width: 320, height: 640), width: 320)
        defer { window.close() }
        await model.connect(server)
        #expect(await eventually { model.items.count == items.count })
        func select(_ name: String) {
            time.advance(to: time.now + .seconds(1))
            model.snapshot.selection = [path(name)]
            model.selectionChanged()
        }
        func replace(_ before: String) async {
            let mark = slots.screens.count
            var hidden: QLPreviewView?
            var since: ContinuousClock.Instant?
            select("paper.pdf")
            for _ in 0..<5000 where slots.screens.last != "quickLook" {
                #expect(slots.screens.last == before)
                // Text on screen keeps its page up meanwhile.
                if before == "text" { #expect(sourcePreview(in: window.contentView)?.swap.shown?.text == "let notes = 1\n") }
                if hidden == nil, let view = quickLookView(in: window.contentView) {
                    hidden = view
                    since = .now
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
            #expect(Array(slots.screens[mark...]) == ["quickLook"])
            // The view that drew hidden is the one on screen, and it had drawn or had its wait.
            let shown = quickLookView(in: window.contentView)
            #expect(hidden != nil && shown === hidden)
            if let shown, let since {
                #expect(QuickLookPreview.hasContent(shown) || since.duration(to: .now) >= PreviewTiming.quickLookDraw - .milliseconds(20))
            }
        }

        select("photo.png")
        #expect(await eventually { slots.screens.last == "picture" })
        await replace("picture")

        select("docs")
        #expect(await eventually { slots.screens.last == "icon" })
        #expect(await eventually { quickLookView(in: window.contentView) == nil })
        await replace("icon")

        select("notes.txt")
        #expect(await eventually(seconds: 10) { slots.screens.last == "text" })
        #expect(await eventually { quickLookView(in: window.contentView) == nil })
        await replace("text")
        #expect(await eventually { sourcePreview(in: window.contentView) == nil })
    }
}
