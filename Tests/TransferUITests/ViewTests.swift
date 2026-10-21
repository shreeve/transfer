import AppKit
import SwiftUI
import Testing
import TransferCore
@testable import TransferUI

/// The real views, hosted in a window that is never shown.
@MainActor
struct ViewTests {
    let a = SavedConnection(name: "A", host: "a")
    let b = SavedConnection(name: "B", host: "b")

    func host(_ view: some View) async -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 960, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        await pause()
        return window
    }

    func pause() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
    }

    /// UIV-02: a sidebar row is a command, and the selection going back to the server shown is
    /// not a click on it, so it never stops a login the window is making to another server.
    @Test func aStarClickKeepsALoginToAnotherServerGoing() async throws {
        let star = RemotePath(string: "/home/proj")
        let sessionA = FakeSession(a, folders: [star: []])
        sessionA.starred.value = [star]
        let model = TransferModel(provider: FakeProvider([sessionA, FakeSession(b, hangs: true)]))
        let window = await host(ContentView(model: model))
        defer { window.close() }
        await model.connect(a)
        let login = Task { await model.connect(b) }
        defer { login.cancel() }
        // Waits for what it checks, not a fixed pause: under a full parallel run B's login, the
        // sidebar's star row, and the star's listing can each take longer than one turn.
        #expect(await eventually { model.connectingTo?.id == b.id })
        // Servers, A, B, Add Server, Starred, and the star: a click on the star.
        let sidebarRows = { tables(in: window.contentView!).first { $0.numberOfRows == 6 } }
        #expect(await eventually { sidebarRows() != nil })
        let sidebar = try #require(sidebarRows())
        sidebar.selectRowIndexes([5], byExtendingSelection: false)
        #expect(await eventually { model.snapshot.path == star })
        #expect(model.connectingTo?.id == b.id)
    }

    /// A folder's menu offered Open Live and Quick Look, which do nothing for a folder (E2E P3).
    @Test func aFolderMenuOffersNeitherOpenLiveNorQuickLook() {
        let model = TransferModel(provider: FakeProvider([]))
        func titles(_ kind: ItemKind) -> [String] {
            ItemMenu.fill(item: RemoteItem(path: RemotePath(string: "/home/x"), kind: kind), model: model).items.map(\.title)
        }
        #expect(!titles(.directory).contains("Open Live"))
        #expect(!titles(.directory).contains("Quick Look"))
        #expect(titles(.directory).contains("Open"))
        #expect(titles(.file).contains("Open Live"))
        #expect(titles(.file).contains("Quick Look"))
    }

    /// The rename bar selected the whole name; Finder selects a file's name up to its extension (E2E P4).
    @Test func renameSelectsTheNameBeforeTheExtension() {
        func stem(_ name: String, folder: Bool = false) -> String {
            String(String(name.utf16.prefix(TransferModel.renameStem(of: name, folder: folder)))!)
        }
        #expect(stem("notes.txt") == "notes")
        #expect(stem("a.tar.gz") == "a.tar")
        #expect(stem("Résumé 📄.pdf") == "Résumé 📄")
        #expect(stem("Photos.v2", folder: true) == "Photos.v2")
        #expect(stem(".env") == ".env")
        #expect(stem("Makefile") == "Makefile")
        #expect(stem("notes.") == "notes.")
    }

    /// A click or drag in a background window only brought it forward (E2E P5): an icon cell, over
    /// its glyph and name too, and a list row's icon and empty end take the first click, as the
    /// list table and the column browser's tables already do.
    @Test func aBackgroundWindowTakesTheFirstClickOnAnItem() {
        _ = NSApplication.shared
        let cell = IconItemView(frame: NSRect(origin: .zero, size: IconItemView.size))
        cell.apply(item: RemoteItem(path: RemotePath(string: "/home/a.txt"), kind: .file), model: TransferModel(provider: FakeProvider([])))
        cell.layoutSubtreeIfNeeded()
        for point in [NSPoint(x: 54, y: 70), NSPoint(x: 54, y: 20), NSPoint(x: 3, y: 3)] {
            #expect(cell.hitTest(point) === cell)
        }
        #expect(cell.acceptsFirstMouse(for: nil))
        let coordinator = ListTable.Coordinator(model: TransferModel(provider: FakeProvider([])))
        #expect(coordinator.tableView(NSTableView(), rowViewForRow: 0)?.acceptsFirstMouse(for: nil) == true)
    }

    /// FR-9: going back to a filter that still holds text keeps Space and Return with it.
    @Test func refocusingTheFilterKeepsThePlainKeysWithIt() async throws {
        _ = NSApplication.shared
        let model = TransferModel(provider: FakeProvider([]))
        let coordinator = WindowChrome<EmptyView, EmptyView, EmptyView>.Coordinator(model: model)
        let item = try #require(coordinator.toolbar(NSToolbar(), itemForItemIdentifier: ChromeItem.search, willBeInsertedIntoToolbar: true))
        let view = try #require(item.view as? SearchToolbarView)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        coordinator.beginSearch(nil)
        #expect(model.textEditing)
        view.field.stringValue = "notes"
        model.filter = "notes"
        window.makeFirstResponder(nil)
        #expect(!model.textEditing)
        #expect(window.makeFirstResponder(view.field))
        #expect(model.textEditing)
        #expect(!model.plainKeysAvailable)
    }

    /// FR-12: each question gets fresh fields, so a password typed into one that was withdrawn
    /// is not in the next one, which SwiftUI shows in the same sheet window.
    @Test func aWithdrawnPasswordIsNotInTheNextSheet() async throws {
        _ = NSApplication.shared
        let model = TransferModel(provider: FakeProvider([]))
        // A sheet presents only on a window that is ordered in; this one and its sheets stay clear.
        let window = OffscreenWindow(contentRect: NSRect(x: -5000, y: -5000, width: 960, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.orderFrontRegardless()
        defer { window.close() }
        await pause()
        func field(in view: NSView) -> NSSecureTextField? {
            (view as? NSSecureTextField) ?? view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        func shownField() -> NSSecureTextField? { window.attachedSheet?.contentView.flatMap(field) }
        let loginA = model.prompts.login(a), loginB = model.prompts.login(b)
        let askA = Task { await loginA.answer(PromptRequest(text: "a's password:", offerKeychain: true)) }
        #expect(await eventually { shownField() != nil })
        let typed = try #require(shownField())
        typed.stringValue = "secret for A"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: typed)
        // B waits behind A, so withdrawing A shows B in the same pass.
        let askB = Task { await loginB.answer(PromptRequest(text: "b's password:", offerKeychain: true)) }
        await pause()
        loginA.retire()
        #expect(await askA.value.text == nil)
        #expect(await eventually { if case .prompt(_, "B"?, _)? = model.sheet { true } else { false } })
        await pause()
        #expect(shownField()?.stringValue == "")
        model.sheet = nil
        #expect(await askB.value.text == nil)
    }

    /// UIV-03: an Extensions edit made just before the tab goes away is saved, not dropped with
    /// the pause that waits for typing to stop.
    @Test func anExtensionsEditIsSavedWhenTheTabGoes() async throws {
        let provider = FakeProvider([])
        let shown = Shown()
        let window = await host(ExtensionsHost(provider: provider, shown: shown))
        defer { window.close() }
        func editor(in view: NSView) -> NSTextView? {
            (view as? NSTextView) ?? view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let text = try #require(editor(in: window.contentView!))
        #expect(await eventually { text.string == "md" })
        text.insertText(" txt", replacementRange: NSRange(location: 2, length: 0))
        try? await Task.sleep(for: .milliseconds(50))
        shown.on = false
        #expect(await eventually { provider.extensions.value == ["md", "txt"] })
    }
}

/// A window whose sheets are never seen: AppKit keeps a window that is ordered in partly on a
/// screen, and a sheet on it with it.
///
/// It never animates: closing an ordered-in window that does runs an `NSAnimation` on a worker
/// thread, which ends by stopping the main run loop. It also starts `MainLoopGuard`.
final class OffscreenWindow: NSWindow {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        MainLoopGuard.install()
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        animationBehavior = .none
    }

    override func beginSheet(_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        sheetWindow.alphaValue = 0
        sheetWindow.ignoresMouseEvents = true
        super.beginSheet(sheetWindow, completionHandler: handler)
    }
}

@MainActor @Observable
final class Shown {
    var on = true
}

/// Settings' Extensions tab, until another tab replaces it.
struct ExtensionsHost: View {
    let provider: FakeProvider
    let shown: Shown

    var body: some View {
        if shown.on { ExtensionSettings(provider: provider) } else { Text("General") }
    }
}

/// Keeps the test process's main run loop from ending while tests remain. The runner spins the
/// main thread in one `CFRunLoopRun`; once that returns, the process exits with status 0 and
/// prints no summary, whatever tests had not run. AppKit stops the main run loop on its own:
/// `postEvent` at once and from a block, a closing window's animation as it ends, and, once
/// anything has asked for the next event (`ClickTests`), HIToolbox for every window-server event
/// it queues (`PushToCGEventQueue`), at any later time. Measured with breakpoints on
/// `CFRunLoopStop` and `CFRunLoopPerformBlock`: `--filter TransferUITests` ended after about half
/// its tests. So the first window starts a run of its own on the main loop that never ends: a
/// stop ends one pass and the next begins, all main-actor work runs inside it, and the runner's
/// exit, called from that work once every test is done, ends the process.
///
/// It starts from a timer, not a block: blocks queued in the same pass as one that never returns
/// are never run, and SwiftUI queues its updates as blocks, so windows stopped updating. And it
/// starts only from the runner's own loop, never from a run nested in it, such as
/// `ClickTests.inOwnRun`, which must end.
@MainActor
enum MainLoopGuard {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        start(after: 0)
    }

    private static func start(after delay: TimeInterval) {
        let timer = Timer(fire: Date.now.addingTimeInterval(delay), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard Thread.callStackSymbols.count(where: { $0.contains(" __CFRunLoopRun ") }) == 1 else { return start(after: 0.05) }
                while true { CFRunLoopRunInMode(.defaultMode, 60, false) }
            }
        }
        RunLoop.main.add(timer, forMode: .default)
    }
}
