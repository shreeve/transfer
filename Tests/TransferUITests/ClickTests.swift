import AppKit
import SwiftUI
import Testing
import TransferCore
@testable import TransferUI

/// The column, list, and icon views under Command- and Shift-clicks sent through their window as
/// AppKit sends them, in a window that is never seen and takes no clicks from the user.
@MainActor @Suite(.serialized)
struct ClickTests {
    let server = SavedConnection(name: "A", host: "a")
    let home = RemotePath(string: "/home")
    /// Column 0's rows: `..`, then the folders, then the files.
    let names = ["..", "a", "b", "c", "x", "y"]

    func path(_ name: String) -> RemotePath { home.appending(name: Array(name.utf8)) }

    /// Connected to a root holding folders a, b, c and files x, y.
    func connected(_ mode: ViewMode) async -> TransferModel {
        let folders = ["a", "b", "c"].map { RemoteItem(path: path($0), kind: .directory) }
        let files = ["x", "y"].map { RemoteItem(path: path($0), kind: .file, size: 1) }
        var tree: [RemotePath: [RemoteItem]] = [home: folders + files]
        for folder in folders { tree[folder.path] = [] }
        let model = TransferModel(provider: FakeProvider([FakeSession(server, folders: tree)]))
        await model.connect(server)
        model.setViewMode(mode)
        return model
    }

    /// Offscreen, transparent, and ignoring the pointer.
    func window(showing view: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 960, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }

    func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        (view as? T) ?? view.subviews.lazy.compactMap { first(type, in: $0) }.first
    }

    /// The column view of that root.
    func browsing() async throws -> (TransferModel, NSWindow, NSBrowser) {
        let model = await connected(.columns)
        let window = window(showing: NSHostingView(rootView: ColumnBrowser(model: model).frame(width: 960, height: 640)))
        var found: NSBrowser?
        #expect(await eventually {
            found = first(NSBrowser.self, in: window.contentView!)
            return found.map { $0.lastColumn == 0 && $0.frame(ofRow: names.count - 1, inColumn: 0).height > 0 } ?? false
        })
        return (model, window, try #require(found))
    }

    /// Clicks `name`'s row in column 0.
    func click(_ name: String, in browser: NSBrowser, modifiers: NSEvent.ModifierFlags) {
        let rect = browser.frame(ofRow: names.firstIndex(of: name)!, inColumn: 0)
        click(browser.convert(NSPoint(x: rect.minX + 40, y: rect.midY), to: nil), in: browser.window!, modifiers: modifiers)
    }

    /// Clicks at `point` in `window` through the window, then runs the main loop long enough for
    /// SwiftUI's update and for the next click not to make a double click.
    func click(_ point: NSPoint, in window: NSWindow, modifiers: NSEvent.ModifierFlags) {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            )!
        }
        deliver(down: event(.leftMouseDown), up: event(.leftMouseUp), to: window)
    }

    /// The mouse-up waits in the queue, where the table's tracking reads it; one the table's tap
    /// recognizer left there is then sent too.
    private func deliver(down: NSEvent, up: NSEvent, to window: NSWindow) {
        inOwnRun {
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
            if let left = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
                window.sendEvent(left)
            }
        }
    }

    /// Runs `body`, then the main run loop for `seconds`, in runs of its own. Posting an event
    /// stops the run loop that is running, at once and again from a block it leaves for later
    /// (measured): from the test itself that is the process's main loop, and the test process exits.
    func inOwnRun(for seconds: TimeInterval = 0.5, _ body: @escaping () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue, body)
        let end = Date.now.addingTimeInterval(seconds)
        while Date.now < end {
            CFRunLoopRunInMode(.defaultMode, end.timeIntervalSinceNow, false)
        }
    }

    func rows(_ browser: NSBrowser) -> Set<String> {
        Set((browser.selectedRowIndexes(inColumn: 0) ?? IndexSet()).map { names[$0] })
    }

    func paths(_ names: String...) -> Set<RemotePath> { Set(names.map(path)) }

    /// Command-clicking a second folder in a column did nothing: only the first stayed selected,
    /// so several folders could not be copied. As in Finder, both are selected, no column follows,
    /// and Copy takes both; one folder left selected opens its column again.
    ///
    /// A plain click synthesized this way selects nothing (measured), so the first row is
    /// Command-clicked, which from no selection selects that row alone, as a click does.
    @Test func commandAndShiftClicksSelectSeveralFolders() async throws {
        let (model, window, browser) = try await browsing()
        defer { inOwnRun { window.close() } }
        click("a", in: browser, modifiers: .command)
        #expect(rows(browser) == ["a"])
        #expect(model.snapshot.path == path("a"))
        #expect(browser.lastColumn == 1)

        click("b", in: browser, modifiers: .command)
        #expect(rows(browser) == ["a", "b"])
        #expect(model.snapshot.selection == paths("a", "b"))
        #expect(model.snapshot.path == home)
        #expect(browser.lastColumn == 0)
        #expect(Set(model.selectedItems.map(\.path)) == paths("a", "b"))

        click("b", in: browser, modifiers: .command)
        #expect(rows(browser) == ["a"])
        #expect(model.snapshot.path == path("a"))
        #expect(browser.lastColumn == 1)

        click("c", in: browser, modifiers: .shift)
        #expect(rows(browser) == ["a", "b", "c"])
        #expect(model.snapshot.selection == paths("a", "b", "c"))
        #expect(model.snapshot.path == home)
        #expect(browser.lastColumn == 0)
        #expect(Set(model.selectedItems.map(\.path)) == paths("a", "b", "c"))
    }

    /// Files already extended; they still do.
    @Test func commandClickSelectsSeveralFiles() async throws {
        let (model, window, browser) = try await browsing()
        defer { inOwnRun { window.close() } }
        click("x", in: browser, modifiers: .command)
        click("y", in: browser, modifiers: .command)
        #expect(rows(browser) == ["x", "y"])
        #expect(model.snapshot.selection == paths("x", "y"))
        #expect(Set(model.selectedItems.map(\.path)) == paths("x", "y"))
        #expect(browser.lastColumn == 0)
    }

    /// List view extends a selection with folders too.
    @Test func commandClickSelectsSeveralFoldersInTheList() async throws {
        let model = await connected(.list)
        let window = window(showing: NSHostingView(rootView: ListTable(model: model).frame(width: 960, height: 640)))
        defer { inOwnRun { window.close() } }
        var table: NSTableView?
        #expect(await eventually {
            table = first(RowMenuTableView.self, in: window.contentView!)
            return table.map { $0.numberOfRows == 5 && $0.rect(ofRow: 4).height > 0 } ?? false
        })
        let list = try #require(table)
        func row(_ name: String) -> NSPoint {
            let rect = list.rect(ofRow: model.displayedItems.firstIndex { $0.path == path(name) }!)
            return list.convert(NSPoint(x: rect.minX + 40, y: rect.midY), to: nil)
        }
        click(row("a"), in: window, modifiers: .command)
        click(row("b"), in: window, modifiers: .command)
        #expect(model.snapshot.selection == paths("a", "b"))
        #expect(Set(model.selectedItems.map(\.path)) == paths("a", "b"))
    }

    /// Icon view extends a selection with folders too.
    @Test func commandClickSelectsSeveralFoldersInIcons() async throws {
        let model = await connected(.icon)
        let cells = ["a", "b"].enumerated().map { index, name in
            let cell = IconItemView(frame: NSRect(origin: NSPoint(x: CGFloat(index) * IconItemView.size.width, y: 0), size: IconItemView.size))
            cell.apply(item: RemoteItem(path: path(name), kind: .directory), model: model)
            return cell
        }
        let grid = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        cells.forEach(grid.addSubview)
        let window = window(showing: grid)
        defer { inOwnRun { window.close() } }
        func center(_ cell: NSView) -> NSPoint { cell.convert(NSPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: nil) }
        click(center(cells[0]), in: window, modifiers: [])
        click(center(cells[1]), in: window, modifiers: .command)
        #expect(model.snapshot.selection == paths("a", "b"))
        #expect(Set(model.selectedItems.map(\.path)) == paths("a", "b"))
    }
}
