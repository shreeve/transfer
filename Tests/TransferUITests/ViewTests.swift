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
        await pause()
        #expect(model.connectingTo?.id == b.id)
        // Servers, A, B, Add Server, Starred, and the star: a click on the star.
        let sidebar = try #require(tables(in: window.contentView!).first { $0.numberOfRows == 6 })
        sidebar.selectRowIndexes([5], byExtendingSelection: false)
        await pause()
        #expect(model.snapshot.path == star)
        #expect(model.connectingTo?.id == b.id)
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
