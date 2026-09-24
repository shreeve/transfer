import AppKit
import Observation
import TransferCore

/// The app's one clipboard, shared by every window and tab. It mirrors the general pasteboard:
/// items copied in Transfer, or files copied in Finder. Each window shows it in its clipboard bar
/// until it is pasted with a move, replaced, or cleared with Escape.
///
/// Finder pastes only real file URLs. It ignores a file promise on the general pasteboard, and a
/// lazily provided URL does not help: the system reads every new pasteboard at once (Spotlight's
/// clipboard history), not at paste time. So items copied here are downloaded to a staging
/// folder right after the copy, and their URLs join the pasteboard when they are complete.
@MainActor
@Observable
public final class Clipboard {
    public static let shared = Clipboard()

    public enum Source: Equatable {
        /// Items on a saved server. `place` is where they were copied from, for the bar.
        case remote(connection: ConnectionID, place: String, paths: [RemotePath])
        case finder([URL])
    }

    /// Whether Finder can paste a clip copied in Transfer.
    public enum FinderCopy: Equatable {
        /// The clip came from Finder.
        case notNeeded
        /// Waiting for the count, then for the download to the staging folder.
        case preparing(Double)
        case ready
        case tooLarge
        case failed(String)
    }

    public struct Clip: Equatable {
        public let id: UUID
        public var source: Source
        /// The item's name when exactly one item was copied.
        public var name: String?
        public var tally: ClipTally
        public var finder: FinderCopy
    }

    public private(set) var clip: Clip?

    /// Copies larger than this are not downloaded for Finder; the bar says so.
    static let finderLimit: UInt64 = 1 << 30

    @ObservationIgnored private var seenChangeCount = -1
    @ObservationIgnored private var written: (payload: Data, text: String)?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var poller: Timer?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var escapeMonitor: Any?

    private init() {
        // Leftovers from a run that did not quit cleanly.
        try? FileManager.default.removeItem(at: Self.stagingRoot)
        try? FileManager.default.removeItem(at: Self.cacheRoot.appendingPathComponent("Paste", isDirectory: true))
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Clipboard.shared.poll() }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Clipboard.shared.leave() }
        })
        // The pasteboard posts no change notification; its change count is cheap to read.
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                if NSApp.isActive { Clipboard.shared.poll() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        poller = timer
        // Escape reaches no single responder: a toolbar button or the window itself may hold the
        // focus, and neither turns Escape into cancelOperation. So it is watched here, and left
        // alone for text fields, sheets, and any window that is not a browser.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { Clipboard.shared.takesEscape(event) } ? nil : event
        }
        poll()
    }

    private func takesEscape(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty, clip != nil,
              let window = event.window, window.isKeyWindow, window.attachedSheet == nil,
              ChromeController.keyWindowController != nil, !(window.firstResponder is NSText) else { return false }
        clear()
        return true
    }

    // MARK: Copy and clear

    /// Puts `items` on the pasteboard, counts what they hold, and makes them ready for Finder.
    /// `prompts` answers for the staging download, the copy's own operation.
    public func copy(_ items: [RemoteItem], session: any RemoteSession, place: String, prompts: any PromptSink) {
        guard !items.isEmpty else { return }
        reset()
        let payload = (try? JSONEncoder().encode(RemoteDragPayload(connection: session.connection.id.rawValue, paths: items.map(\.path.bytes)))) ?? Data()
        let text = items.map(\.path.display).joined(separator: "\n")
        written = (payload, text)
        write(files: [])
        var tally = ClipTally()
        for item in items { tally.add(root: TreeEntry(item)) }
        tally.complete = !items.contains { $0.kind == .directory }
        let id = UUID()
        clip = Clip(
            id: id,
            source: .remote(connection: session.connection.id, place: place, paths: items.map(\.path)),
            name: items.count == 1 ? items[0].name : nil,
            tally: tally,
            finder: .preparing(0)
        )
        work = Task { [weak self] in
            await OperationPrompts.$current.withValue(prompts) {
                await self?.countRemote(items, session: session, id: id)
                await self?.stageForFinder(items, session: session, id: id)
            }
        }
    }

    /// Escape and the bar's close button. Also after a move, whose sources are gone.
    public func clear() {
        guard clip != nil else { return }
        reset()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        seenChangeCount = pasteboard.changeCount
    }

    private func reset() {
        work?.cancel()
        work = nil
        written = nil
        if let clip { try? FileManager.default.removeItem(at: Self.stagingRoot.appendingPathComponent(clip.id.uuidString)) }
        clip = nil
    }

    /// Quitting leaves no URLs behind that point into the staging folder it removes.
    private func leave() {
        if written != nil, NSPasteboard.general.changeCount == seenChangeCount { NSPasteboard.general.clearContents() }
        work?.cancel()
        try? FileManager.default.removeItem(at: Self.stagingRoot)
    }

    /// The first item carries the remote paths for a paste inside Transfer and as text; once
    /// staged, every item also carries a file URL for Finder.
    private func write(files: [URL]) {
        guard let written else { return }
        let first = NSPasteboardItem()
        first.setData(written.payload, forType: remoteDragType)
        first.setString(written.text, forType: .string)
        var items = [first]
        for (index, url) in files.enumerated() {
            let item = index == 0 ? first : NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if index > 0 { items.append(item) }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        seenChangeCount = pasteboard.changeCount
    }

    // MARK: Watching the pasteboard

    /// Another app, or Finder, changed the pasteboard: files from Finder become the clip, and
    /// anything else clears it.
    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != seenChangeCount else { return }
        seenChangeCount = pasteboard.changeCount
        reset()
        // Remote paths written by another copy of Transfer are not ours to reach.
        guard pasteboard.data(forType: remoteDragType) == nil else { return }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        let id = UUID()
        clip = Clip(id: id, source: .finder(urls), name: urls.count == 1 ? urls[0].lastPathComponent : nil, tally: ClipTally(), finder: .notNeeded)
        let box = Locked(ClipTally())
        work = Task { [weak self] in
            await self?.publishing(box, to: id) {
                await Task.detached {
                    for url in urls {
                        guard !Task.isCancelled else { return }
                        LocalTree.walk(url) { key, entry in
                            if key.isEmpty { box.withLock { $0.add(root: entry) } } else { box.withLock { $0.add(inside: entry) } }
                        }
                    }
                }.value
            }
            self?.update(id) { $0.tally.complete = true }
        }
    }

    // MARK: Counting and staging

    /// Counts what the copied folders hold, showing the count at most every 0.2 s as it grows.
    private func countRemote(_ items: [RemoteItem], session: any RemoteSession, id: UUID) async {
        let folders = items.filter { $0.kind == .directory }
        guard !folders.isEmpty, var tally = clip?.tally else { return }
        var shown = ContinuousClock.now
        for folder in folders {
            do {
                for try await (key, entry) in session.walkTree(folder.path) where !key.isEmpty {
                    tally.add(inside: entry)
                    if shown.duration(to: .now) >= .milliseconds(200) {
                        update(id) { $0.tally = tally }
                        shown = .now
                    }
                }
            } catch {
                // A folder that cannot be walked adds what was seen before the error.
            }
        }
        update(id) {
            $0.tally = tally
            $0.tally.complete = true
        }
    }

    /// Downloads the clip into its own staging folder, then adds the file URLs to the pasteboard,
    /// unless something else has been copied in the meantime.
    private func stageForFinder(_ items: [RemoteItem], session: any RemoteSession, id: UUID) async {
        guard let clip, clip.id == id, !Task.isCancelled else { return }
        guard clip.tally.bytes <= Self.finderLimit else {
            update(id) { $0.finder = .tooLarge }
            return
        }
        let folder = Self.stagingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        let total = max(clip.tally.bytes, 1)
        let done = Locked<UInt64>(0)
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                let fraction = min(Double(done.value) / Double(total), 0.99)
                self?.update(id) { $0.finder = .preparing(fraction) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { ticker.cancel() }
        var urls: [URL] = []
        do {
            for item in items {
                try Task.checkCancellation()
                let url = folder.appendingPathComponent(item.name)
                let base = done.value
                try await session.download(item.path, to: url) { progress in done.value = base + progress.completed }
                urls.append(url)
            }
        } catch {
            if !Task.isCancelled { update(id) { $0.finder = .failed(error.localizedDescription) } }
            return
        }
        ticker.cancel()
        guard self.clip?.id == id, NSPasteboard.general.changeCount == seenChangeCount else { return }
        write(files: urls)
        update(id) { $0.finder = .ready }
    }

    /// Runs `body` while copying the box's tally into the clip every 0.2 s, and once at the end.
    private func publishing(_ box: Locked<ClipTally>, to id: UUID, _ body: () async -> Void) async {
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                let tally = box.value
                self?.update(id) { $0.tally = tally }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        await body()
        ticker.cancel()
        let tally = box.value
        update(id) { $0.tally = tally }
    }

    private func update(_ id: UUID, _ change: (inout Clip) -> Void) {
        guard var current = clip, current.id == id else { return }
        change(&current)
        if current != clip { clip = current }
    }

    // MARK: Folders

    nonisolated private static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Transfer", isDirectory: true)
    }

    static var stagingRoot: URL { cacheRoot.appendingPathComponent("Clipboard", isDirectory: true) }

    /// A fresh folder for a paste between servers, which travels through this Mac.
    nonisolated static func scratchFolder() -> URL {
        cacheRoot.appendingPathComponent("Paste/\(UUID().uuidString)", isDirectory: true)
    }
}

/// Walks a local file or folder the way `RemoteSession.walkTree` walks a remote one, so the
/// two can be compared before a move removes the original.
enum LocalTree {
    static func walk(_ root: URL, visit: (String, TreeEntry) -> Void) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let rootEntry = entry(root, keys: keys) else { return }
        visit("", rootEntry)
        guard rootEntry == .directory,
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else { return }
        let prefix = root.standardizedFileURL.path.count + 1
        for case let url as URL in enumerator {
            guard let found = entry(url, keys: keys) else { continue }
            visit(String(url.standardizedFileURL.path.dropFirst(prefix)), found)
        }
    }

    static func entries(_ root: URL) -> [String: TreeEntry] {
        var all: [String: TreeEntry] = [:]
        walk(root) { all[$0] = $1 }
        return all
    }

    private static func entry(_ url: URL, keys: [URLResourceKey]) -> TreeEntry? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        if values.isSymbolicLink == true { return .link }
        if values.isDirectory == true { return .directory }
        return .file(size: UInt64(values.fileSize ?? 0), mtime: values.contentModificationDate.map(SFTPTime.seconds))
    }
}
