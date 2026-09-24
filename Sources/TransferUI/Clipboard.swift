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
        // Makes this process's folder, and removes those of processes that have ended.
        _ = Self.processFolder
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
        let payload = RemoteDragPayload.data(for: items, session: session)
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
        work = Task {
            await OperationPrompts.$current.withValue(prompts) {
                await countRemote(items, session: session, id: id)
                await stageForFinder(items, session: session, id: id)
            }
        }
    }

    /// Escape and the bar's close button. Also after a move, whose sources are gone. Files copied
    /// in Finder stay on the general pasteboard, which is the user's own; only the bar goes.
    public func clear() {
        guard let clip else { return }
        reset()
        let pasteboard = NSPasteboard.general
        guard case .remote = clip.source, pasteboard.changeCount == seenChangeCount else { return }
        pasteboard.clearContents()
        seenChangeCount = pasteboard.changeCount
    }

    /// Clears the clip a finished move was made from, unless something else has been copied since.
    public func clear(ifStill id: UUID) {
        if clip?.id == id { clear() }
    }

    /// Finder pastes asynchronously and may still be reading a clip's staged files when the clip
    /// is replaced or cleared, so they are removed only after a while. Nothing can start a new
    /// paste from them: their URLs have already left the pasteboard.
    private func reset() {
        work?.cancel()
        work = nil
        written = nil
        if let clip, case .remote = clip.source {
            let folder = Self.stagingFolder(clip.id)
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(600))
                try? FileManager.default.removeItem(at: folder)
            }
        }
        clip = nil
    }

    /// Quitting removes this process's folder, so the pasteboard keeps only the copied paths as
    /// text, for a terminal, and no file URL into it.
    private func leave() {
        work?.cancel()
        let pasteboard = NSPasteboard.general
        if let written, pasteboard.changeCount == seenChangeCount {
            pasteboard.clearContents()
            pasteboard.setString(written.text, forType: .string)
        }
        try? FileManager.default.removeItem(at: Self.processFolder)
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
        let urls = pasteboard.fileURLs
        guard !urls.isEmpty else { return }
        let id = UUID()
        clip = Clip(id: id, source: .finder(urls), name: urls.count == 1 ? urls[0].lastPathComponent : nil, tally: ClipTally(), finder: .notNeeded)
        let box = Locked(ClipTally())
        work = Task {
            await publishing(box, to: id) {
                // Off the main thread, and stopped when the clip is: copying a whole disk in
                // Finder must not leave a walk running after the next copy replaces it.
                let walk = Task.detached {
                    for url in urls {
                        LocalTree.walk(url, stop: { Task.isCancelled }) { key, entry in
                            if key.isEmpty { box.withLock { $0.add(root: entry) } } else { box.withLock { $0.add(inside: entry) } }
                        }
                    }
                }
                await withTaskCancellationHandler { await walk.value } onCancel: { walk.cancel() }
            }
            if !Task.isCancelled { update(id) { $0.tally.complete = true } }
        }
    }

    // MARK: Counting and staging

    /// Counts what the copied folders hold, showing the count at most every 0.2 s as it grows.
    /// A folder that cannot be walked leaves the count incomplete and Finder without a copy: the
    /// 1 GB limit and the paste's progress need the whole count. Names the Mac's disk cannot hold
    /// apart also keep Finder without a copy, since one would stand in for the other.
    private func countRemote(_ items: [RemoteItem], session: any RemoteSession, id: UUID) async {
        guard var tally = clip?.tally else { return }
        var clash = NameClash(ignoringCase: Self.diskIgnoresCase)
        var shown = ContinuousClock.now
        for item in items {
            clash.add(item.name)
            guard item.kind == .directory else { continue }
            do {
                for try await (key, entry) in session.walkTree(item.path) where !key.isEmpty {
                    tally.add(inside: entry)
                    clash.add("\(item.name)/\(key)")
                    if shown.duration(to: .now) >= .milliseconds(200) {
                        update(id) { $0.tally = tally }
                        shown = .now
                    }
                }
            } catch {
                if !Task.isCancelled {
                    update(id) {
                        $0.tally = tally
                        $0.finder = .failed("could not count “\(item.name)”: \(error.localizedDescription)")
                    }
                }
                return
            }
        }
        update(id) {
            $0.tally = tally
            $0.tally.complete = true
            if let (first, second) = clash.found {
                $0.finder = .failed("“\(first)” and “\(second)” differ only in case or accents, and this Mac's disk cannot hold both")
            }
        }
    }

    /// Downloads the clip into its own staging folder, then adds the file URLs to the pasteboard,
    /// unless something else has been copied in the meantime.
    private func stageForFinder(_ items: [RemoteItem], session: any RemoteSession, id: UUID) async {
        guard let clip, clip.id == id, case .preparing = clip.finder, clip.tally.complete, !Task.isCancelled else { return }
        guard clip.tally.bytes <= Self.finderLimit else {
            update(id) { $0.finder = .tooLarge }
            return
        }
        let folder = Self.stagingFolder(id)
        let total = max(clip.tally.bytes, 1)
        let done = Locked<UInt64>(0)
        let ticker = Task {
            while !Task.isCancelled {
                let fraction = min(Double(done.value) / Double(total), 0.99)
                update(id) { $0.finder = .preparing(fraction) }
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
        let ticker = Task {
            while !Task.isCancelled {
                let tally = box.value
                update(id) { $0.tally = tally }
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

    /// `~/Library/Caches/<bundle id>`, or `Caches` under the library root `TRANSFER_LIBRARY`
    /// names, so a development build leaves the installed app's folders alone.
    nonisolated private static var cacheRoot: URL {
        if let root = LibraryOverride.root { return root.appendingPathComponent("Caches", isDirectory: true) }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Transfer", isDirectory: true)
    }

    /// This process's own folder under `Staging`: its clips' staging folders and its pastes'
    /// scratch folders. Two copies of Transfer can run at once (`open -n`, or a development build
    /// beside the installed app), so neither may remove what the other is using. Each holds an
    /// exclusive lock on `<its folder>.lock` while it runs, which the kernel drops when the
    /// process ends, crash or not; a launch removes only the folders whose lock it can take.
    nonisolated static let processFolder: URL = {
        let manager = FileManager.default
        // What 0.1.7 and earlier left at the top level.
        for old in ["Clipboard", "Paste"] { try? manager.removeItem(at: cacheRoot.appendingPathComponent(old, isDirectory: true)) }
        let root = cacheRoot.appendingPathComponent("Staging", isDirectory: true)
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)
        let names = Set((try? manager.contentsOfDirectory(atPath: root.path)) ?? [])
        for name in names where !name.hasSuffix(".lock") && !names.contains(name + ".lock") {
            try? manager.removeItem(at: root.appendingPathComponent(name))
        }
        for lock in names where lock.hasSuffix(".lock") {
            let path = root.appendingPathComponent(lock).path
            let held = open(path, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_CLOEXEC)
            guard held >= 0 else { continue }
            try? manager.removeItem(at: root.appendingPathComponent(String(lock.dropLast(5))))
            unlink(path)
            close(held)
        }
        let id = UUID().uuidString
        // Kept open, and so locked, for the life of the process.
        _ = open(root.appendingPathComponent("\(id).lock").path, O_CREAT | O_RDONLY | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, 0o600)
        return root.appendingPathComponent(id, isDirectory: true)
    }()

    private static func stagingFolder(_ id: UUID) -> URL {
        processFolder.appendingPathComponent("clip-\(id.uuidString)", isDirectory: true)
    }

    /// A fresh folder for a paste between servers, which travels through this Mac.
    nonisolated static func scratchFolder() -> URL {
        processFolder.appendingPathComponent("paste-\(UUID().uuidString)", isDirectory: true)
    }

    /// Whether the disk that staging and scratch folders live on treats `README` and `readme` as
    /// one name, as a Mac's disk does unless formatted case-sensitive. When it cannot be told, yes.
    nonisolated static var diskIgnoresCase: Bool {
        let values = try? processFolder.deletingLastPathComponent().resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames != true
    }
}

/// Finds two names in a remote tree that one folder on this Mac cannot hold apart: `README` and
/// `readme` on a disk that ignores case, the two Unicode spellings of `café` (APFS ignores that
/// difference too), or two names that are not valid UTF-8 and decode alike. Fed each entry's key
/// once, as `walkTree` yields it, so any key seen a second time was a second name.
struct NameClash {
    let ignoringCase: Bool
    private var seen: [String: String] = [:]
    /// The first two keys found to clash.
    private(set) var found: (String, String)?

    init(ignoringCase: Bool) {
        self.ignoringCase = ignoringCase
    }

    /// Swift compares strings by canonical equivalence, so keys that differ only in Unicode
    /// normalization already meet in `seen`.
    mutating func add(_ key: String) {
        guard found == nil else { return }
        let folded = ignoringCase ? key.lowercased() : key
        if let other = seen[folded] { found = (other, key) } else { seen[folded] = key }
    }
}

/// Walks a local file or folder the way `RemoteSession.walkTree` walks a remote one, so the
/// two can be compared before a move removes the original. Reads each entry with `lstat` through
/// FileManager's attributes: `URL.resourceValues` caches per URL instance and can return the
/// size and time from an earlier walk.
enum LocalTree {
    /// `stop` is asked before each entry, so a walk of a whole disk can be abandoned.
    static func walk(_ root: URL, stop: () -> Bool = { false }, visit: (String, TreeEntry) -> Void) {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: root.path) else { return }
        let rootEntry = entry(attributes)
        visit("", rootEntry)
        guard rootEntry == .directory, let enumerator = manager.enumerator(atPath: root.path) else { return }
        while !stop(), let key = enumerator.nextObject() as? String {
            guard let attributes = enumerator.fileAttributes else { continue }
            visit(key, entry(attributes))
        }
    }

    static func entries(_ root: URL) -> [String: TreeEntry] {
        var all: [String: TreeEntry] = [:]
        walk(root) { all[$0] = $1 }
        return all
    }

    /// A FIFO, socket, or device has no bytes to copy and no time a move could check, so it is a
    /// file whose copy never proves complete: a move keeps its folder.
    private static func entry(_ attributes: [FileAttributeKey: Any]) -> TreeEntry {
        let type = attributes[.type] as? FileAttributeType
        if type == .typeDirectory { return .directory }
        if type == .typeSymbolicLink { return .link }
        guard type == .typeRegular else { return .file(size: 0, mtime: nil) }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return .file(size: size, mtime: (attributes[.modificationDate] as? Date).map(SFTPTime.seconds))
    }
}
