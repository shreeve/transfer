import AppKit
import SwiftUI
import Testing
import TransferCore
@testable import TransferUI

/// Live is obvious and easy to turn off: the toolbar's badge and its list, Stop Live Editing and
/// its one warning, the inspector's capsule, and the marker on a Live item's icon in every view.
@MainActor @Suite(.serialized)
struct LiveBadgeTests {
    let a = SavedConnection(name: "A", host: "a")
    let b = SavedConnection(name: "B", host: "b")
    let home = RemotePath(string: "/home")

    func path(_ name: String) -> RemotePath { home.appending(name: Array(name.utf8)) }

    func live(_ name: String, dirty: Bool = false, conflict: Bool = false) -> LiveFile {
        LiveFile(id: LiveFileID(), path: path(name), dirty: dirty, paused: false, conflict: conflict, uploading: false)
    }

    /// Preferences of the test's own, never the user's or the runner's.
    final class Defaults {
        let name = "transfer-tests-\(UUID().uuidString)"
        let store: UserDefaults
        init() { store = UserDefaults(suiteName: name)! }
        deinit { store.removePersistentDomain(forName: name) }
    }

    /// Offscreen, transparent, and ignoring the pointer, as in `InspectorTests`.
    func window(_ view: some View, width: CGFloat = 960, height: CGFloat = 640, style: NSWindow.StyleMask = [.borderless]) async -> NSWindow {
        _ = NSApplication.shared
        let window = OffscreenWindow(contentRect: NSRect(x: -5000, y: -5000, width: width, height: height), styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        // The chrome prefers tabs: a window of another suite ordered in meanwhile must never try
        // to join this one, which a borderless window cannot.
        window.tabbingIdentifier = "LiveBadgeTests-\(UUID().uuidString)"
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(300))
        return window
    }

    /// Runs `body`, then the main run loop for `seconds`, in runs of its own: posting an event
    /// stops the running loop, which from the test itself would end the process (`ClickTests`).
    func inOwnRun(for seconds: TimeInterval = 0.5, _ body: @escaping () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue, body)
        let end = Date.now.addingTimeInterval(seconds)
        while Date.now < end {
            CFRunLoopRunInMode(.defaultMode, end.timeIntervalSinceNow, false)
        }
    }

    /// A plain click, sent through `window` as AppKit sends one, at the middle of `frame`, a
    /// slot's frame in the hosting view's own (top-left) coordinates.
    func click(_ frame: CGRect, in window: NSWindow) {
        let view = window.contentView!
        let point = view.convert(NSPoint(x: frame.midX, y: view.isFlipped ? frame.midY : view.bounds.height - frame.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        let down = event(.leftMouseDown), up = event(.leftMouseUp)
        inOwnRun {
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
            if let left = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
                window.sendEvent(left)
            }
        }
    }

    // MARK: The toolbar badge

    /// The badge is hidden while no Live file exists, reads "Live" for one and "Live 4" for four,
    /// counting every server's, and VoiceOver reads the count. It sits left of the view switcher.
    @Test func theBadgeCountsEveryServersLiveFilesAndHidesAtZero() async throws {
        let sessionA = FakeSession(a), sessionB = FakeSession(b)
        let provider = FakeProvider([sessionA, sessionB])
        let model = TransferModel(provider: provider, defaults: Defaults().store)
        let window = await window(ContentView(model: model), style: [.titled, .resizable])
        defer { window.close() }
        let identifiers = window.toolbar?.items.map(\.itemIdentifier) ?? []
        #expect(identifiers.firstIndex(of: ChromeItem.live).map { $0 + 1 } == identifiers.firstIndex(of: ChromeItem.viewMode))
        /// The window's badge as it stands, read afresh from its toolbar each time.
        func badge() -> (hidden: Bool, title: String, label: String?)? {
            guard let item = window.toolbar?.items.first(where: { $0.itemIdentifier == ChromeItem.live }),
                  let view = item.view as? LiveBadgeView else { return nil }
            return (item.isHidden, view.title, view.accessibilityLabel())
        }
        #expect(await eventually { badge()?.hidden == true })

        sessionA.live.value = [live("one.txt")]
        provider.liveDidChange()
        #expect(await eventually { badge().map { !$0.hidden && $0.title == "Live" && $0.label == "Live files: 1" } == true },
                "\(model.libraryLive.count) \(String(describing: badge()))")
        let view = try #require(window.toolbar?.items.first { $0.itemIdentifier == ChromeItem.live }?.view as? LiveBadgeView)
        #expect(view.accessibilityRole() == .button)
        #expect(view.intrinsicContentSize.height == LiveBadgeView.height)

        sessionA.live.value += [live("two.txt", dirty: true)]
        sessionB.live.value = [live("three.txt"), live("four.txt", conflict: true)]
        provider.liveDidChange()
        #expect(await eventually { badge().map { !$0.hidden && $0.title == "Live 4" && $0.label == "Live files: 4" } == true })

        sessionA.live.value = []
        sessionB.live.value = []
        provider.liveDidChange()
        #expect(await eventually { badge()?.hidden == true })
    }

    /// The badge draws its words in bold white on red, in both appearances.
    @Test func theBadgeIsWhiteOnRed() throws {
        _ = NSApplication.shared
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let badge = LiveBadgeView()
            badge.appearance = NSAppearance(named: name)
            badge.count = 4
            badge.frame = NSRect(origin: .zero, size: badge.intrinsicContentSize)
            let rep = try #require(badge.bitmapImageRepForCachingDisplay(in: badge.bounds))
            badge.cacheDisplay(in: badge.bounds, to: rep)
            var red = 0, white = 0
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9 else { continue }
                    if color.redComponent > 0.8, color.greenComponent < 0.4, color.blueComponent < 0.4 { red += 1 }
                    if color.redComponent > 0.95, color.greenComponent > 0.95, color.blueComponent > 0.95 { white += 1 }
                }
            }
            #expect(red > white && white > 20, "\(name.rawValue): \(red) red, \(white) white")
        }
    }

    /// Clicking the badge opens the list of every Live file; VoiceOver's press does the same.
    @Test func theBadgeOpensTheList() async throws {
        let session = FakeSession(a)
        session.live.value = [live("one.txt")]
        let model = TransferModel(provider: FakeProvider([session]), defaults: Defaults().store)
        let window = await window(ContentView(model: model), style: [.titled, .resizable])
        defer { window.close() }
        let item = try #require(window.toolbar?.items.first { $0.itemIdentifier == ChromeItem.live })
        let badge = try #require(item.view as? LiveBadgeView)
        #expect(await eventually { badge.title == "Live" })
        #expect(badge.accessibilityPerformPress())
        let coordinator = try #require(badge.target as? WindowChrome<SidebarColumn, DetailColumn, InspectorColumn>.Coordinator)
        #expect(coordinator.livePopover?.contentViewController is NSHostingController<LiveFilesList>)
        coordinator.livePopover?.close()
    }

    // MARK: The list

    /// Each row names the file, its server, and its state, with a Stop of its own; the footer has
    /// Stop All, and Stop Selected only while Live files are selected in the window. A click on a
    /// synced file's Stop stops it, asking nothing.
    @Test func theListShowsEachFileWithItsServerStateAndStop() async throws {
        let one = live("one.txt"), two = live("two.txt", dirty: true), three = live("three.txt", conflict: true)
        let sessionA = FakeSession(a, folders: [home: [RemoteItem(path: one.path, kind: .file), RemoteItem(path: two.path, kind: .file)]])
        sessionA.live.value = [one, two]
        let sessionB = FakeSession(b)
        sessionB.live.value = [three]
        let model = TransferModel(provider: FakeProvider([sessionA, sessionB]), defaults: Defaults().store)
        await model.connect(a)
        await model.reloadLibraryLive()
        #expect(model.libraryLive.map(\.file.path.name) == ["one.txt", "two.txt", "three.txt"])
        #expect(model.libraryLive.map(LiveFilesList.caption) == ["A · Synced", "A · Edited, not uploaded yet", "B · Conflict"])
        let slots = InspectorSlots()
        let window = await window(LiveFilesList(model: model).environment(\.liveListSlots, slots), width: LiveFilesList.width, height: 300)
        defer { inOwnRun { window.close() } }
        for name in ["one.txt", "two.txt", "three.txt"] {
            #expect(slots.frames["row \(name)"] != nil, "\(name)")
            #expect(slots.frames["stop \(name)"].map { $0.width > 0 } == true, "\(name)")
        }
        #expect(slots.frames["stop all"] != nil)
        #expect(slots.frames["stop selected"] == nil)

        model.snapshot.selection = [one.path, two.path]
        #expect(model.selectedLiveFiles.count == 2)
        #expect(await eventually { slots.frames["stop selected"] != nil })

        click(try #require(slots.frames["stop one.txt"]), in: window)
        #expect(await eventually { sessionA.calls.value.contains("stop /home/one.txt") })
        #expect(await eventually { model.libraryLive.count == 2 })
        #expect(model.sheet == nil)
        #expect(await eventually { model.selectedLiveFiles.count == 1 })

        // Stop All asks about the unsynced file and the conflict, stopping nothing yet.
        click(try #require(slots.frames["stop all"]), in: window)
        #expect(await eventually { if case .stopLive(_, let unsynced)? = model.sheet { unsynced.count == 2 } else { false } })
        #expect(model.libraryLive.count == 2)
    }

    // MARK: Stop

    /// Stop on a synced file stops it at once: no sheet, gone from the badge and the sidebar.
    @Test func stoppingASyncedFileAsksNothing() async {
        let one = live("one.txt")
        let session = FakeSession(a)
        session.live.value = [one]
        let model = TransferModel(provider: FakeProvider([session]), defaults: Defaults().store)
        await model.connect(a)
        await model.reloadLibraryLive()
        #expect(await eventually { model.libraryLive.count == 1 && model.liveFiles.count == 1 })
        await model.stopLive([one.id])
        #expect(model.sheet == nil)
        #expect(session.calls.value.contains("stop /home/one.txt"))
        #expect(model.libraryLive.isEmpty && model.liveFiles.isEmpty)
    }

    /// Stop All with one unsynced file asks once, naming that file and its server; Cancel keeps
    /// every file, synced ones too. Confirmed, the whole batch stops.
    @Test func stopAllWithOneUnsyncedAsksAndCancelKeepsAll() async throws {
        let one = live("one.txt"), two = live("two.txt", dirty: true), three = live("three.txt")
        let sessionA = FakeSession(a), sessionB = FakeSession(b)
        sessionA.live.value = [one, two]
        sessionB.live.value = [three]
        let model = TransferModel(provider: FakeProvider([sessionA, sessionB]), defaults: Defaults().store)
        await model.connect(a)
        await model.reloadLibraryLive()
        await model.stopAllLive()
        guard case .stopLive(let batch, let unsynced)? = model.sheet else {
            Issue.record("no Stop sheet: \(String(describing: model.sheet))")
            return
        }
        #expect(Set(batch) == [one.id, two.id, three.id])
        #expect(unsynced.map(\.file.path.name) == ["two.txt"] && unsynced.map(\.server) == ["A"])
        #expect(StopLiveSheet.detail(unsynced.count) == "1 file has edits the server doesn’t have; they will be discarded.")
        #expect(StopLiveSheet.detail(2) == "2 files have edits the server doesn’t have; they will be discarded.")
        #expect(!(sessionA.calls.value + sessionB.calls.value).contains { $0.hasPrefix("stop ") })

        model.sheet = nil
        #expect(model.libraryLive.count == 3)
        #expect(sessionA.live.value.count == 2 && sessionB.live.value.count == 1)

        await model.stopAllLive()
        guard case .stopLive(let again, let named)? = model.sheet else {
            Issue.record("no Stop sheet the second time")
            return
        }
        model.sheet = nil
        await model.stopLive(again, warned: Set(named.map(\.id)))
        #expect(model.sheet == nil)
        #expect(model.libraryLive.isEmpty)
        #expect(sessionA.calls.value.filter { $0.hasPrefix("stop ") }.sorted() == ["stop /home/one.txt", "stop /home/two.txt"])
        #expect(sessionB.calls.value.contains("stop /home/three.txt"))
    }

    /// File → Stop Live Editing and the sidebar's item read "…" when stopping would ask first.
    @Test func theMenuItemAsksOnlyForUnsyncedEdits() {
        #expect(TransferModel.stopLiveTitle([live("one.txt")]) == "Stop Live Editing")
        #expect(TransferModel.stopLiveTitle([live("one.txt"), live("two.txt", dirty: true)]) == "Stop Live Editing…")
        #expect(TransferModel.stopLiveTitle([live("c.txt", conflict: true)]) == "Stop Live Editing…")
    }

    // MARK: The inspector's capsule

    /// The header's capsule reads Live and stops the file when clicked; a conflict's reads
    /// Conflict and opens the conflict sheet. The header stays one line, the capsule inside it.
    @Test func theInspectorCapsuleStopsOrResolves() async throws {
        let one = live("one.txt"), clash = live("clash.txt", conflict: true)
        let items = [RemoteItem(path: one.path, kind: .file, size: 10), RemoteItem(path: clash.path, kind: .file, size: 10)]
        let session = FakeSession(a, folders: [home: items])
        session.live.value = [one, clash]
        let defaults = Defaults()
        defaults.store.set(true, forKey: Preferences.showsInspector)
        let model = TransferModel(provider: FakeProvider([session]), defaults: defaults.store)
        let slots = InspectorSlots()
        let window = await window(InspectorColumn(model: model).environment(\.inspectorSlots, slots).frame(width: 320, height: 640), width: 320)
        defer { inOwnRun { window.close() } }
        await model.connect(a)
        #expect(await eventually { model.items.count == 2 && model.liveFiles.count == 2 })
        model.snapshot.selection = [clash.path]
        model.selectionChanged()
        #expect(await eventually { slots.frames["live capsule"] != nil })
        window.contentView?.layoutSubtreeIfNeeded()
        let header = try #require(slots.frames["header"]), capsule = try #require(slots.frames["live capsule"])
        #expect(header.height == InspectorColumn.headerHeight)
        #expect(header.contains(capsule) && capsule.height == LiveCapsule.height)
        click(capsule, in: window)
        #expect(await eventually { if case .conflict(clash.path, _)? = model.sheet { true } else { false } })
        #expect(!session.calls.value.contains { $0.hasPrefix("stop ") })
        model.putOffConflict()

        model.snapshot.selection = [one.path]
        model.selectionChanged()
        try? await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
        let synced = try #require(slots.frames["live capsule"])
        #expect(header.contains(synced) && synced.height == LiveCapsule.height)
        #expect(try #require(slots.frames["header"]) == header)
        click(synced, in: window)
        #expect(await eventually { session.calls.value.contains("stop /home/one.txt") })
        #expect(await eventually { model.liveFiles.map(\.path) == [clash.path] })
        #expect(model.sheet == nil)
    }

    // MARK: Icon markers

    /// A Live item's icon carries the marker in icon, list, and column view, a conflict's its own
    /// kind; an item that is not Live has none. A stop takes the marker away.
    @Test func iconMarkersShowOnlyOnLiveItems() async throws {
        let one = live("one.txt"), clash = live("clash.txt", conflict: true)
        let items = [RemoteItem(path: one.path, kind: .file), RemoteItem(path: clash.path, kind: .file), RemoteItem(path: path("plain.txt"), kind: .file)]
        let session = FakeSession(a, folders: [home: items])
        session.live.value = [one, clash]
        let model = TransferModel(provider: FakeProvider([session]), defaults: Defaults().store)
        let window = await window(ContentView(model: model))
        defer { window.close() }
        await model.connect(a)
        #expect(await eventually { model.items.count == 3 && model.liveFiles.count == 2 })
        let expected: [String: LiveMark?] = ["one.txt": .live, "clash.txt": .conflict, "plain.txt": nil]

        func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
        }

        model.setViewMode(.icon)
        #expect(await eventually { views(IconItemView.self, in: window.contentView!).count == 3 })
        let icons = Dictionary(views(IconItemView.self, in: window.contentView!).map { ($0.item.name, $0.liveMark) }, uniquingKeysWith: { a, _ in a })
        #expect(icons == expected)

        model.setViewMode(.list)
        func listMarks() -> [String: LiveMark?] {
            Dictionary(views(NameCellView.self, in: window.contentView!).map { ($0.textField?.stringValue ?? "", $0.markView.mark) },
                       uniquingKeysWith: { a, _ in a })
        }
        #expect(await eventually { listMarks().count == 3 })
        #expect(listMarks() == expected)
        #expect(views(NameCellView.self, in: window.contentView!).allSatisfy { $0.markView.isHidden == ($0.markView.mark == nil) })

        model.setViewMode(.columns)
        #expect(await eventually { !views(TiledBrowser.self, in: window.contentView!).isEmpty })
        let browser = try #require(views(TiledBrowser.self, in: window.contentView!).first)
        let coordinator = try #require(browser.delegate as? ColumnBrowser.Coordinator)
        func columnMarks() -> [String: LiveMark?] {
            var marks: [String: LiveMark?] = [:]
            for row in 0..<coordinator.browser(browser, numberOfChildrenOfItem: nil) {
                let cell = CenteredBrowserCell()
                coordinator.browser(browser, willDisplayCell: cell, atRow: row, column: 0)
                if let item = coordinator.browser(browser, child: row, ofItem: nil) as? RemoteItem { marks[item.name] = cell.liveMark }
            }
            // Rows and columns AppKit may propose that are not there carry no marker.
            for (row, column) in [(-1, 0), (0, -1), (99, 0), (0, 5)] {
                let cell = CenteredBrowserCell()
                coordinator.browser(browser, willDisplayCell: cell, atRow: row, column: column)
                #expect(cell.liveMark == nil)
            }
            return marks
        }
        #expect(await eventually { columnMarks().count == 3 })
        #expect(columnMarks() == expected)

        // Stopping takes the marker away in the view on screen.
        await model.stopLive([one.id])
        #expect(await eventually { coordinator.marks[one.path] == nil })
        #expect(columnMarks()["one.txt"] == .some(nil))
    }
}
