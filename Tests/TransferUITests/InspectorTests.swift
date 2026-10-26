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

    /// Every kind of selection keeps the header line and the preview area in one place: a
    /// picture, a text file, a file it cannot fetch (listed with no size), one over the limit,
    /// one still loading, a folder, two items, and a link. The header is one line; the area runs
    /// from under it to the Wrap lines strip at the panel's foot. Text and the list of several items draw on
    /// the document background, the rest on gray. A missing fact reads "—".
    @Test func theHeaderAndThePreviewAreaHoldStillWhateverIsSelected() async throws {
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
            // Listed with no size, time, mode, or owner: a file of a known type that is not text
            // is fetched whole, so with no size it is not fetched at all.
            RemoteItem(path: path("blob.zip"), kind: .file),
            RemoteItem(path: path("link"), kind: .symlink),
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
        let fixed = ["header", "preview", "foot"]
        var seen: [String: [String: CGRect]] = [:]
        var surfaces: [String: String] = [:]

        select(longName)
        #expect(await eventually { if case .picture? = model.inspectorPreview { true } else { false } })
        seen["picture"] = await frames()
        surfaces["picture"] = slots.surface
        let one = InspectorFacts(model: model)
        #expect(one.name == longName)
        #expect(one.kind == "PNG image")
        #expect(one.size == "1.0kB")
        #expect(one.day == Format.day(when))
        #expect(one.time == Format.clock(when))
        #expect(one.permissions == "rw-r--r--")
        #expect(one.owner == "steve:staff")
        let tip = one.tooltip(link: nil, live: nil, transfer: nil)
        #expect(tip.contains("PNG image") && tip.contains("steve:staff") && tip.contains("1,000 bytes"))

        select("notes.txt")
        #expect(await eventually { if case .text? = model.inspectorPreview { true } else { false } })
        #expect(await eventually { slots.screens.last == "text" })
        seen["text"] = await frames()
        surfaces["text"] = slots.surface

        select("blob.zip")
        #expect(await eventually { model.inspectorPreview == nil && model.inspectorWait == .icon })
        seen["unsupported"] = await frames()
        surfaces["unsupported"] = slots.surface
        let bare = InspectorFacts(model: model)
        #expect(bare.size == "—")
        #expect(bare.day == "—" && bare.time == "—")
        #expect(bare.permissions == "—" && bare.owner == nil)

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
        surfaces["folder"] = slots.surface
        let folderFacts = InspectorFacts(model: model)
        #expect(folderFacts.kind == "Folder")
        #expect(folderFacts.size == "—")
        #expect(folderFacts.file == nil)

        select("notes.txt", "docs")
        #expect(await eventually { model.inspectorWait == .icon && model.inspectorPreview == nil })
        seen["two items"] = await frames()
        surfaces["two items"] = slots.surface
        let two = InspectorFacts(model: model)
        #expect(two.name == "2 items selected · 1 folder")
        #expect(two.total == 16)
        #expect(two.several?.map(\.name) == ["docs", "notes.txt"])

        select("link")
        #expect(await eventually { model.inspectorLinkTarget != nil && model.inspectorPreview == nil && model.inspectorWait == .icon })
        seen["link"] = await frames()
        #expect(InspectorFacts(model: model).tooltip(link: model.inspectorLinkTarget, live: nil, transfer: nil).contains("→ "))
        #expect(seen["link"]?["symbols"].map { $0.width > 0 } == true)

        // Neither a server nor the inspector fetched anything it could not show.
        let fetched = session.calls.value.filter { $0.hasPrefix("inspector ") }
        #expect(!fetched.contains { $0.hasSuffix("blob.zip") || $0.hasSuffix("huge.png") })

        #expect(surfaces == ["picture": "gray", "text": "document", "unsupported": "gray", "folder": "gray", "two items": "document"])
        let reference = try #require(seen["picture"])
        for key in fixed { #expect(reference[key] != nil, "\(key)") }
        let area = try #require(reference["preview"]), header = try #require(reference["header"])
        let foot = try #require(reference["foot"])
        // One line, the panel's width less its margins; the area from under it to the foot's strip.
        #expect(header.height == InspectorColumn.headerHeight)
        #expect(header.width == window.frame.width - 32)
        #expect(area.width == window.frame.width - 32)
        #expect(area.minY == header.maxY + InspectorColumn.headerGap)
        #expect(area.maxY == 640 - InspectorColumn.bottomMargin - InspectorColumn.footHeight - InspectorColumn.footGap)
        #expect(foot.maxY == 640 - InspectorColumn.bottomMargin)
        #expect(foot.height == InspectorColumn.footHeight)
        for (state, frames) in seen {
            for key in fixed { #expect(frames[key] == reference[key], "\(state): \(key)") }
        }
        // One line however long the name: as tall as a short name, and inside the header.
        let name = try #require(reference["nameText"])
        let short = try #require(seen["two items"]?["nameText"])
        #expect(name.height == short.height)
        #expect(name.height < InspectorColumn.headerHeight + 1)
        #expect(name.minX >= header.minX && name.maxX <= header.maxX)
    }

    /// The header holds one item's facts on one line. A narrow panel drops them from the right,
    /// permissions, then time, then date, and never the size; nothing overlaps or leaves the line.
    @Test func theHeaderDropsDetailsFromTheRightWhenNarrow() async throws {
        let when: UInt32 = 1_788_000_000
        let names = ["notes.txt", longName]
        let session = FakeSession(server, folders: [home: names.map {
            RemoteItem(path: path($0), kind: .file, size: 77_933_067, mtime: when, mode: 0o100644, owner: "steve", group: "staff")
        }])
        let model = TransferModel(provider: FakeProvider([session]), defaults: Defaults().store)
        await model.connect(server)
        #expect(await eventually { model.items.count == 2 })
        let order = ["size", "day", "time", "permissions"]
        var counts: [Int] = []
        for name in names {
            model.snapshot.selection = [path(name)]
            model.selectionChanged()
            for width in [480, 360, 300, 240, 200] as [CGFloat] {
                let slots = InspectorSlots()
                let window = await window(InspectorColumn(model: model).environment(\.inspectorSlots, slots).frame(width: width, height: 400), width: width, height: 400)
                window.contentView?.layoutSubtreeIfNeeded()
                let frames = slots.frames
                window.close()
                let header = try #require(frames["header"])
                #expect(header.height == InspectorColumn.headerHeight)
                let shown = order.filter { frames["detail \($0)"].map { $0.width > 0 } ?? false }
                // What shows is the left of the order: the size always, the rest from the right.
                #expect(shown == Array(order.prefix(shown.count)), "\(name) at \(width): \(shown)")
                #expect(!shown.isEmpty, "\(name) at \(width)")
                let text = try #require(frames["nameText"])
                var left = text.maxX
                for key in shown {
                    let part = try #require(frames["detail \(key)"])
                    #expect(part.minX >= left - 0.5, "\(name) at \(width): \(key)")
                    #expect(part.maxX <= header.maxX + 0.5, "\(name) at \(width): \(key)")
                    #expect(abs(part.midY - text.midY) < 2, "\(name) at \(width): \(key)")
                    left = part.maxX
                }
                counts.append(shown.count)
            }
        }
        // The short name shows everything when wide; the long one gives way at the narrowest.
        #expect(counts.first == 4)
        #expect(counts.last.map { $0 < 4 } == true)
        // Narrower never shows more.
        for run in [counts.prefix(5), counts.suffix(5)] {
            #expect(zip(run, run.dropFirst()).allSatisfy { $0 >= $1 }, "\(counts)")
        }
    }

    /// Several items: the count on the left, the files' total at the right as exact bytes and the
    /// compact size (exact first to go), and a read-only list with one row per item in the
    /// browser's order, its columns giving way from the right when narrow.
    @Test func severalItemsListOneRowEachInBrowserOrder() async throws {
        let when: UInt32 = 1_788_000_000
        func item(_ name: String, _ kind: ItemKind, size: UInt64?) -> RemoteItem {
            RemoteItem(path: path(name), kind: kind, size: size, mtime: when, mode: 0o100644, owner: "steve", group: "staff")
        }
        let items = [item("b.bin", .file, size: 77_933_000), item("a.txt", .file, size: 67), item("src", .directory, size: nil)]
        let session = FakeSession(server, folders: [home: items, path("src"): []])
        let model = TransferModel(provider: FakeProvider([session]), defaults: Defaults().store)
        await model.connect(server)
        #expect(await eventually { model.items.count == 3 })
        model.snapshot.selection = Set(items.map(\.path))
        model.selectionChanged()
        let browser = model.displayedItems.map(\.name)
        #expect(browser == ["src", "a.txt", "b.bin"])
        let facts = InspectorFacts(model: model)
        #expect(facts.name == "3 items selected · 1 folder")
        #expect(facts.total == 77_933_067)
        #expect(Format.sized(77_933_067) == "\(Format.exact(77_933_067)) ( 78MB)")
        let rows = try #require(facts.several)
        #expect(rows.map(\.name) == browser)
        #expect(rows.map(\.size) == [nil, 67, 77_933_000])
        #expect(rows[0].folder && rows[1].permissions == "rw-r--r--" && rows[1].owner == "steve:staff")
        #expect(rows[2].day == Format.day(when) && rows[2].time == Format.shortClock(when))

        let columns = ["name", "size", "permissions", "owner", "day", "time"]
        func render(width: CGFloat) async throws -> [String: CGRect] {
            let slots = InspectorSlots()
            let window = await window(InspectorColumn(model: model).environment(\.inspectorSlots, slots).frame(width: width, height: 400), width: width, height: 400)
            defer { window.close() }
            #expect(await eventually { slots.frames["row 2 name"] != nil })
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(slots.surface == "document")
            return slots.frames
        }
        let wide = try await render(width: 480)
        for index in 0..<3 {
            for column in columns { #expect(wide["row \(index) \(column)"] != nil, "row \(index) \(column)") }
        }
        // In order down the list, one line each, and the sizes right-aligned in one column.
        let tops = (0..<3).compactMap { wide["row \($0) name"]?.minY }
        #expect(tops == tops.sorted() && Set(tops).count == 3)
        let sizes = (0..<3).compactMap { wide["row \($0) size"]?.maxX }
        #expect(Set(sizes).count == 1, "\(sizes)")
        #expect(wide["row 3 name"] == nil)
        let header = try #require(wide["header"]), total = try #require(wide["detail total"])
        #expect(abs(total.maxX - header.maxX) < 1)
        #expect(try #require(wide["nameText"]).maxX <= total.minX)

        let narrow = try await render(width: 200)
        let kept = columns.filter { narrow["row 0 \($0)"] != nil }
        #expect(kept.contains("name") && kept.contains("size") && kept.contains("day"))
        #expect(!kept.contains("time"))
        // Time gives way first, then owner, then permissions.
        if kept.contains("permissions") == false { #expect(!kept.contains("owner")) }
        #expect(narrow["detail total"] == nil && narrow["detail compact total"] != nil)
    }

    /// Text draws on the document background, in light and in dark, and a picture on the gray.
    @Test func textDrawsOnTheDocumentBackgroundInLightAndDark() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TransferUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = try picture(in: folder)
        let text = folder.appending(path: "notes.txt")
        try Data("x\n".utf8).write(to: text)
        let notes = RemoteItem(path: path("notes.txt"), kind: .file, size: 2), photo = RemoteItem(path: path("photo.png"), kind: .file, size: 1000)
        let session = FakeSession(server, folders: [home: [notes, photo]])
        session.liveExtensions.value = ["txt"]
        session.inspectorCopies.value = [notes.path: text, photo.path: png]
        let defaults = Defaults()
        defaults.store.set(true, forKey: Preferences.showsInspector)
        let model = TransferModel(provider: FakeProvider([session]), defaults: defaults.store)
        await model.connect(server)
        #expect(await eventually { model.items.count == 2 })
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            let slots = InspectorSlots()
            let window = await window(InspectorColumn(model: model).environment(\.inspectorSlots, slots).frame(width: 320, height: 400), width: 320, height: 400)
            defer { window.close() }
            window.appearance = appearance
            /// The area's color near its bottom-right corner, clear of any content.
            func corner() async throws -> NSColor {
                try? await Task.sleep(for: .milliseconds(200))
                let view = try #require(window.contentView)
                view.layoutSubtreeIfNeeded()
                let area = try #require(slots.frames["preview"])
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                // The bitmap's rows run from the top, as the slots' coordinates do.
                let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
                let color = try #require(bitmap.colorAt(x: Int((area.maxX - 4) * scale), y: Int((area.maxY - 4) * scale)))
                return try #require(color.usingColorSpace(.sRGB))
            }
            model.snapshot.selection = [notes.path]
            model.selectionChanged()
            #expect(await eventually { slots.screens.last == "text" })
            let page = try await corner()
            var document = NSColor.black
            appearance.performAsCurrentDrawingAppearance { document = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .black }
            // Opaque, and the document color (SwiftUI draws dark's a shade lighter than AppKit's 0.118).
            #expect(page.alphaComponent == 1, "\(name.rawValue): \(page)")
            #expect(abs(page.brightnessComponent - document.brightnessComponent) < 0.05, "\(name.rawValue): \(page) vs \(document)")

            model.snapshot.selection = [photo.path]
            model.selectionChanged()
            #expect(await eventually { slots.screens.last == "picture" })
            let gray = try await corner()
            // The quiet gray: a faint wash over the panel (clear in this window), not the page.
            #expect(gray.alphaComponent < 0.5, "\(name.rawValue): \(gray)")
        }
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
        #expect(facts.kind == "Folder" && facts.size == "2 items")
        #expect(facts.file == nil)
    }

    /// The toolbar's inspector toggle does what Command-I does, the split follows, and the
    /// choice is what the next window opens with.
    @Test func theToolbarToggleShowsTheInspectorAndIsRemembered() async throws {
        // The split view saves to the runner's own domain; start from no save, whatever ran before.
        UserDefaults.standard.removeObject(forKey: Self.splitFrames)
        let defaults = Defaults()
        let provider = FakeProvider([FakeSession(server)])
        let model = TransferModel(provider: provider, defaults: defaults.store)
        #expect(!model.showsInspector)
        let window = await window(ContentView(model: model), style: [.titled, .resizable])
        defer { window.close() }
        let controller = try #require(chrome(in: window))
        let inspector = controller.splitViewItems[2]
        #expect(inspector.isCollapsed)
        let side = controller.splitViewItems[0].isCollapsed ? 0 : Double(controller.splitViewItems[0].viewController.view.frame.width)
        #expect(inspector.maximumThickness == CGFloat(InspectorWidth.maximum(splitWidth: Double(controller.splitView.bounds.width), sidebar: side)))
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

    static let splitFrames = "NSSplitView Subview Frames Transfer.Split"

    /// A window closed while its inspector collapsed saves it open at width 0; the next window
    /// still opens its inspector from the toolbar. Before the fix this alone, run after itself,
    /// failed every other time.
    @Test func anInspectorSavedMidCollapseStillOpens() async throws {
        UserDefaults.standard.set(["0.000000, 0.000000, 150.000000, 640.000000, NO, NO",
                                   "150.000000, 0.000000, 810.000000, 640.000000, NO, NO",
                                   "960.000000, 0.000000, 0.000000, 640.000000, NO, NO"], forKey: Self.splitFrames)
        defer { UserDefaults.standard.removeObject(forKey: Self.splitFrames) }
        let model = TransferModel(provider: FakeProvider([FakeSession(server)]), defaults: Defaults().store)
        let window = await window(ContentView(model: model), style: [.titled, .resizable])
        defer { window.close() }
        let controller = try #require(chrome(in: window))
        let inspector = controller.splitViewItems[2]
        #expect(inspector.isCollapsed)
        let item = try #require(window.toolbar?.items.first { $0.itemIdentifier == ChromeItem.inspector })
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(await eventually { !inspector.isCollapsed })
    }

    /// The saved split and `Preferences.showsInspector` may disagree (a save from a window that
    /// closed with the inspector out, a preference set since). The preference wins at setup, and
    /// SwiftUI keeps updating the chrome: the view switcher follows the model and the toolbar
    /// toggle still moves the split.
    @Test(arguments: [true, false]) func aSplitSavedAgainstThePreferenceStillFollowsTheModel(shown: Bool) async throws {
        let open = ["0.000000, 0.000000, 150.000000, 640.000000, NO, NO",
                    "150.000000, 0.000000, 410.000000, 640.000000, NO, NO",
                    "560.000000, 0.000000, 400.000000, 640.000000, NO, NO"]
        let closed = ["0.000000, 0.000000, 150.000000, 640.000000, NO, NO",
                      "150.000000, 0.000000, 810.000000, 640.000000, NO, NO",
                      "960.000000, 0.000000, 0.000000, 640.000000, YES, NO"]
        UserDefaults.standard.set(shown ? closed : open, forKey: Self.splitFrames)
        defer { UserDefaults.standard.removeObject(forKey: Self.splitFrames) }
        let defaults = Defaults()
        defaults.store.set(shown, forKey: Preferences.showsInspector)
        let model = TransferModel(provider: FakeProvider([FakeSession(server)]), defaults: defaults.store)
        let window = await window(ContentView(model: model), style: [.titled, .resizable])
        defer { window.close() }
        let controller = try #require(chrome(in: window))
        let inspector = controller.splitViewItems[2]
        #expect(await eventually { inspector.isCollapsed == !shown })
        #expect(model.showsInspector == shown)
        let group = try #require(window.toolbar?.items.first { $0.itemIdentifier == ChromeItem.viewMode } as? NSToolbarItemGroup)
        model.setViewMode(.list)
        #expect(await eventually { group.selectedIndex == ViewMode.allCases.firstIndex(of: .list) })
        model.setViewMode(.icon)
        #expect(await eventually { group.selectedIndex == ViewMode.allCases.firstIndex(of: .icon) })
        let item = try #require(window.toolbar?.items.first { $0.itemIdentifier == ChromeItem.inspector })
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(await eventually { inspector.isCollapsed == shown })
    }

    /// The inspector grows to 60% of the split view and no further, and a narrower window pulls
    /// it in while the content pane keeps its 260.
    @Test func theInspectorStopsAtSixtyPercentAndShrinksWithTheWindow() async throws {
        UserDefaults.standard.removeObject(forKey: Self.splitFrames)
        defer { UserDefaults.standard.removeObject(forKey: Self.splitFrames) }
        let defaults = Defaults()
        defaults.store.set(true, forKey: Preferences.showsInspector)
        let model = TransferModel(provider: FakeProvider([FakeSession(server)]), defaults: defaults.store)
        let window = await window(ContentView(model: model), style: [.titled, .resizable])
        defer { window.close() }
        let controller = try #require(chrome(in: window))
        let inspector = controller.splitViewItems[2]
        let content = controller.splitViewItems[1]
        let split = controller.splitView
        func settle() async { try? await Task.sleep(for: .milliseconds(400)) }
        func resize(_ width: CGFloat) async {
            var frame = window.frame
            frame.size.width = width
            window.setFrame(frame, display: true)
            await settle()
        }
        func drag(to width: CGFloat) async {
            split.setPosition(split.bounds.width - width, ofDividerAt: 1)
            split.layoutSubtreeIfNeeded()
            await settle()
        }
        await resize(1600)
        #expect(await eventually { !inspector.isCollapsed })
        await drag(to: 2000)
        let widest = inspector.viewController.view.frame.width
        let side = controller.splitViewItems[0].viewController.view.frame.width
        let limit = CGFloat(InspectorWidth.maximum(splitWidth: Double(split.bounds.width), sidebar: Double(side)))
        #expect(inspector.maximumThickness == limit)
        #expect(abs(widest - 960) <= 20 && widest <= limit)
        await drag(to: 300)
        #expect(abs(inspector.viewController.view.frame.width - 300) <= 2)

        await drag(to: 2000)
        await resize(900)
        let narrowed = inspector.viewController.view.frame.width
        #expect(narrowed <= CGFloat(InspectorWidth.maximum(splitWidth: Double(split.bounds.width), sidebar: Double(side))))
        #expect(narrowed < widest)
        #expect(content.viewController.view.frame.width >= 260)
    }

    /// The inspector comes back at the width it last had open, after a window that closed with
    /// it hidden: the split saves a collapsed column at no useful width.
    @Test func theInspectorReopensAtItsLastWidthAfterAHiddenClose() async throws {
        UserDefaults.standard.removeObject(forKey: Self.splitFrames)
        defer { UserDefaults.standard.removeObject(forKey: Self.splitFrames) }
        let defaults = Defaults()
        defaults.store.set(true, forKey: Preferences.showsInspector)
        func settle() async { try? await Task.sleep(for: .milliseconds(400)) }
        do {
            let model = TransferModel(provider: FakeProvider([FakeSession(server)]), defaults: defaults.store)
            let window = await window(ContentView(model: model), width: 1400, style: [.titled, .resizable])
            let controller = try #require(chrome(in: window))
            let inspector = controller.splitViewItems[2]
            #expect(await eventually { !inspector.isCollapsed })
            await settle()
            let split = controller.splitView
            split.setPosition(split.bounds.width - 420, ofDividerAt: 1)
            split.layoutSubtreeIfNeeded()
            await settle()
            #expect(abs(inspector.viewController.view.frame.width - 420) <= 2)
            model.showsInspector = false
            #expect(await eventually { inspector.isCollapsed })
            await settle()
            window.close()
        }
        let model = TransferModel(provider: FakeProvider([FakeSession(server)]), defaults: defaults.store)
        #expect(!model.showsInspector)
        let window = await window(ContentView(model: model), width: 1400, style: [.titled, .resizable])
        defer { window.close() }
        let controller = try #require(chrome(in: window))
        let inspector = controller.splitViewItems[2]
        #expect(inspector.isCollapsed)
        model.showsInspector = true
        #expect(await eventually { !inspector.isCollapsed })
        await settle()
        #expect(abs(inspector.viewController.view.frame.width - 420) <= 2)
    }

    /// Back and Forward are dim until the history has somewhere to go, and follow it, also after
    /// the toolbar validates its items, as AppKit does on every window update: a subitem left to
    /// autovalidate was enabled again because its target answers the action.
    @Test func backAndForwardFollowTheHistory() async throws {
        let home = RemotePath(string: "/home")
        let docs = home.appending("docs")
        let session = FakeSession(server, home: "/home", folders: [home: [RemoteItem(path: docs, kind: .directory)], docs: []])
        let model = TransferModel(provider: FakeProvider([session]), defaults: Defaults().store)
        let window = await window(ContentView(model: model), style: [.titled, .resizable])
        defer { window.close() }
        let group = try #require(window.toolbar?.items.first { $0.itemIdentifier == ChromeItem.backForward } as? NSToolbarItemGroup)
        func state() -> [Bool] {
            window.toolbar?.validateVisibleItems()
            group.validate()
            return group.subitems.map(\.isEnabled)
        }
        // A window showing no server has no history.
        #expect(!model.canGoBack && !model.canGoForward)
        #expect(await eventually { state() == [false, false] })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(state() == [false, false])

        await model.connect(server)
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
        #expect(state() == [true, false])
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
