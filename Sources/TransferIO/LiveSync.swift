import CryptoKit
import Foundation
import TransferCore

struct LiveRemoteChanged: Error {}

/// What Live sync needs from a server. `SSHConnection` conforms; tests use a fake.
protocol LiveServer: AnyObject, Sendable {
    /// The item at `path`, or nil when there is none. Any other failure throws: a dropped
    /// connection is not evidence that the file was removed.
    func liveLookup(_ path: RemotePath) async throws -> RemoteItem?
    /// Downloads `item` over `local` in one rename. `interactive` uses the lane the user waits on.
    func liveFetch(_ item: RemoteItem, to local: URL, interactive: Bool) async throws
    /// Uploads `snapshot` to `path` with temp-and-rename on the interactive lane. Just before the
    /// rename the server must match `expecting`, or hold a file with this save's size and
    /// whole-second time (the lane ran it again after it landed), else it throws
    /// `LiveRemoteChanged`. Returns the server file's new fingerprint.
    func liveSave(_ snapshot: URL, to path: RemotePath, expecting: ServerExpectation, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> Fingerprint
    func liveNames(in folder: RemotePath) async throws -> Set<String>
    func liveEmit(_ event: SessionEvent)
}

/// Everything about Live files: the records and their storage, one watcher over the Live folder,
/// and one worker per server running every pass and command for its files in turn. Only the worker
/// changes a file's sync state, so nothing races and nothing needs a lock; the exception is the
/// paused flag, which Pause sets at once and the next pass reads. A pass does what `LiveDecision`
/// answers from the facts it gathers: the copy's stamp, a digest when the stamp moved, and the
/// server's file. One per app, owned by the hub, so the watcher and records outlive any connection.
actor LiveSync {
    /// How long a working copy must hold still before a pass acts on it.
    static let settle: Duration = .milliseconds(350)
    /// How long a missing working copy is given to reappear, as an editor may be mid-save.
    static let missingGrace: Duration = .seconds(1)
    /// A synced mapping untouched for this long is forgotten at launch.
    static let expiry: TimeInterval = 24 * 60 * 60
    /// How often every working copy is stamped when FSEvents cannot watch the Live folder.
    static let pollInterval: Duration = .seconds(2)
    /// The digest of bytes that cannot be read: never equal to a real one, so they count as an edit.
    private static let unreadable = "unreadable"

    private struct Entry {
        let id: LiveFileID
        let connection: ConnectionID
        var path: RemotePath
        let local: URL
        var state: LiveState
        var conflict: LiveConflictKind?
        var uploading = false
        var missingSeen = false
        /// The working copy's stamp when it was last looked at, nil when it was missing. A pass
        /// acts only on a copy whose stamp has not moved since; a watcher event that finds it
        /// unmoved only echoes something already seen, such as an upload reading its snapshot.
        var observed: LiveStamp?
        /// The digest of the bytes `state.pending` stamps, so adopting that upload never rereads
        /// a copy an editor may have saved since.
        var pendingDigest: String?
        /// The working copy's digest at a stamp, so the Live list and counts, which every window
        /// asks for often, read a large copy once per save rather than on every ask.
        var measured: (stamp: LiveStamp, digest: String)?
        var attempts = 0
        /// The state of this file's row on the shelf, as last reported.
        var shown: OperationState?

        var name: String { path.name }
        var folder: URL { local.deletingLastPathComponent() }

        /// The working copy with `stamp` and `digest` holds what the server holds as `print`.
        mutating func recordSync(_ print: Fingerprint, _ stamp: LiveStamp?, _ digest: String?) {
            state.base = print
            state.synced = stamp
            state.syncedDigest = digest
            state.pending = nil
            pendingDigest = nil
            state.dirty = false
        }
        /// Named after the working copy, which keeps its name when the remote file is renamed.
        var serverCopy: URL { folder.appendingPathComponent(LiveDecision.siblingName(of: local.lastPathComponent, suffix: " (server)")) }
    }

    private struct Command {
        let run: @Sendable () async -> Void
        let cancel: @Sendable () -> Void
    }

    private struct Worker {
        var due: [LiveFileID: ContinuousClock.Instant] = [:]
        var waitingForServer: Set<LiveFileID> = []
        var commands: [Command] = []
        var running = false
        var wake: CheckedContinuation<Void, Never>?
        var timer: Task<Void, Never>?
        var loop: Task<Void, Never>?
    }

    private final class ServerRef {
        weak var server: (any LiveServer)?
        init(_ server: any LiveServer) { self.server = server }
    }

    private let store: Store
    private let root: URL
    private let watches: Bool
    private var entries: [LiveFileID: Entry] = [:]
    private var servers: [ConnectionID: ServerRef] = [:]
    private var ready: Set<ConnectionID> = []
    private var workers: [ConnectionID: Worker] = [:]
    private var notices: [ConnectionID: [String]] = [:]
    /// Live opens queued or running on a worker, whose records do not exist yet.
    private var opening: [UUID: (connection: ConnectionID, path: RemotePath)] = [:]
    private var watcher: LiveWatcher?
    private var watching: Task<Void, Never>?

    /// `watches` is false only in tests, which report changes through `localChanged`.
    init(store: Store, watches: Bool = true) {
        self.store = store
        self.watches = watches
        root = store.root.appendingPathComponent("Live", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        (entries, notices) = Self.load(store.liveFiles(), store: store)
    }

    /// Records from their rows, reading only stamps; whether a copy holds edits is worked out when
    /// asked. A gone copy takes its record, and its folder unless edits were known (the user hears
    /// of those). A copy idle for a day expires unless it holds edits; its last activity is the
    /// later of its and its folder's mtime, as a download gives the file the server's older time.
    private static func load(_ rows: [LiveRow], store: Store) -> ([LiveFileID: Entry], [ConnectionID: [String]]) {
        var loaded: [LiveFileID: Entry] = [:]
        var gone: [ConnectionID: [String]] = [:]
        for row in rows {
            var entry = entry(from: row, local: URL(fileURLWithPath: row.localPath))
            guard let stamp = stamp(entry.local) else {
                if LiveDecision.isUnsynced(entry.state, nil) {
                    gone[row.connection, default: []].append("The Live copy of \(row.path.display) is gone; its edits were not uploaded")
                } else {
                    try? FileManager.default.removeItem(at: entry.folder)
                }
                store.deleteLive(row.id)
                continue
            }
            entry.observed = stamp
            let folderTime = (try? FileManager.default.attributesOfItem(atPath: entry.folder.path)[.modificationDate] as? Date) ?? .distantPast
            if Date().timeIntervalSince(max(stamp.mtime, folderTime)) > expiry,
               !LiveDecision.isUnsynced(entry.state, localChange(entry.state, entry.local, stamp)) {
                store.deleteLive(row.id)
                try? FileManager.default.removeItem(at: entry.folder)
                continue
            }
            loaded[row.id] = entry
        }
        return (loaded, gone)
    }

    // MARK: Connections

    /// A connection logged in: its files are looked at again, and passes waiting for the server run.
    func connected(_ connection: ConnectionID, server: any LiveServer) {
        if !entries.values.contains(where: { $0.connection == connection }) {
            let (loaded, gone) = Self.load(store.liveFiles(connection: connection), store: store)
            entries.merge(loaded) { current, _ in current }
            notices.merge(gone) { current, _ in current }
        }
        servers[connection] = ServerRef(server)
        ready.insert(connection)
        startWatching()
        for notice in notices.removeValue(forKey: connection) ?? [] { server.liveEmit(.notice(notice)) }
        for entry in entries.values where entry.connection == connection { lookAgain(entry.id) }
        poke(connection)
        server.liveEmit(.liveChanged)
    }

    /// The connection went away. Nothing is cancelled: passes that need the server wait for it.
    /// Only the current object counts; the hub may have replaced an older one that still disconnects.
    func disconnected(_ connection: ConnectionID, server: any LiveServer) {
        if servers[connection]?.server === server { ready.remove(connection) }
    }

    /// Stops a connection's worker and forgets its files in memory, as when the server is removed.
    func close(_ connection: ConnectionID) {
        ready.remove(connection)
        servers[connection] = nil
        if let worker = workers.removeValue(forKey: connection) {
            worker.loop?.cancel()
            worker.timer?.cancel()
            worker.wake?.resume()
            for command in worker.commands { command.cancel() }
        }
        entries = entries.filter { $0.value.connection != connection }
    }

    /// Remove Server: `close`, and the connection's Live folder goes, but it refuses with
    /// `liveUnsynced`, changing nothing, while one of its files holds bytes the server lacks.
    /// Reading digests awaits, and meanwhile an editor may save or an open may finish, so the
    /// last check reads no bytes: it runs in the same turn as the close and the delete, and when
    /// a copy moved since its digest was read, everything is measured again.
    func closeIfSynced(_ connection: ConnectionID) async throws {
        while true {
            if opening.values.contains(where: { $0.connection == connection }) { try await perform(on: connection) {} }
            let unsynced = await unsyncedCount(on: connection)
            if unsynced > 0 { throw TransferError.liveUnsynced(unsynced) }
            guard !opening.values.contains(where: { $0.connection == connection }), let now = unsyncedNow(on: connection) else { continue }
            if now > 0 { throw TransferError.liveUnsynced(now) }
            break
        }
        close(connection)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(connection.rawValue.uuidString, isDirectory: true))
    }

    /// Stops everything: the watcher and every worker. Tests end their `LiveSync` with it.
    func closeAll() {
        for connection in Set(workers.keys).union(servers.keys) { close(connection) }
        watching?.cancel()
        watching = nil
        watcher?.stop()
        watcher = nil
    }

    // MARK: The public Live API, per connection

    /// `dirty` is `isUnsynced`: an edit no pass has seen yet counts, so every warning sees it.
    func files(on connection: ConnectionID) async -> [LiveFile] {
        var files: [LiveFile] = []
        for entry in entries.values where entry.connection == connection {
            let unsynced = await isUnsynced(entry)
            files.append(LiveFile(id: entry.id, path: entry.path, dirty: unsynced, paused: entry.state.paused, conflict: entry.state.conflict, uploading: entry.uploading))
        }
        return files.sorted { $0.path.display < $1.path.display }
    }

    /// Files with bytes the server lacks, even edits no pass has seen yet. Nil counts every server's.
    func unsyncedCount(on connection: ConnectionID? = nil) async -> Int {
        var count = 0
        for entry in entries.values where connection == nil || entry.connection == connection {
            if await isUnsynced(entry) { count += 1 }
        }
        return count
    }

    /// The working copy for `path`: downloaded, or refreshed if the server moved on and it is untouched.
    func open(_ path: RemotePath, on connection: ConnectionID) async throws -> URL {
        let token = UUID()
        opening[token] = (connection, path)
        defer { opening[token] = nil }
        return try await perform(on: connection) { try await self.openNow(path, on: connection) }
    }

    func setPaused(_ path: RemotePath, on connection: ConnectionID, paused: Bool) {
        guard let id = find(path, on: connection), let entry = update(id, { $0.state.paused = paused }) else { return }
        // Resume and Retry: the row goes, and a pass shows what is left to do.
        report(entry, paused ? .paused : .succeeded)
        if !paused { lookAgain(id) }
        emit(entry, .liveChanged)
    }

    func resolve(_ path: RemotePath, on connection: ConnectionID, choice: LiveConflictChoice) async throws {
        try await perform(on: connection) { try await self.resolveNow(path, on: connection, choice: choice) }
    }

    /// Refuses with `liveUnsynced` while the copy holds bytes the server lacks, unless `force`.
    func discard(_ path: RemotePath, on connection: ConnectionID, force: Bool) async throws {
        try await perform(on: connection) {
            if let id = await self.find(path, on: connection) { try await self.discardNow(id, force: force) }
        }
    }

    /// A rename on the server of `source`, run by `perform`. Live records under it follow it.
    func rename(_ source: RemotePath, to destination: RemotePath, on connection: ConnectionID, perform rename: @escaping @Sendable () async throws -> Void) async throws {
        try await barrier(under: source, on: connection, rename) { await self.moved(source, to: destination, on: connection) }
    }

    /// A removal on the server of `path`, run by `perform`. While a Live file under it holds bytes
    /// the server lacks, it refuses with `liveUnsynced` and nothing is removed, unless `force`
    /// (the user chose to discard those edits). The Live files under it are then forgotten.
    func remove(_ path: RemotePath, on connection: ConnectionID, force: Bool = false, perform remove: @escaping @Sendable () async throws -> Void) async throws {
        try await barrier(under: path, on: connection, remove, first: {
            if !force { try await self.refuseUnsynced(under: path, on: connection) }
        }, then: { await self.removed(path, on: connection, force: force) })
    }

    /// Runs `body` at once, or, when Live files lie under `path` or are being opened there, between
    /// their passes, after `first` and before `after`, so no save of theirs lands on the old path.
    /// An open still queued or downloading has no record yet; waiting for it lets `first` and
    /// `after` see the record it makes.
    private func barrier(under path: RemotePath, on connection: ConnectionID, _ body: @escaping @Sendable () async throws -> Void,
                         first: @escaping @Sendable () async throws -> Void = {}, then after: @escaping @Sendable () async -> Void) async throws {
        let live = entries.values.contains { $0.connection == connection && $0.path.isInside(path) }
            || opening.values.contains { $0.connection == connection && $0.path.isInside(path) }
        guard live else { return try await body() }
        try await perform(on: connection) {
            try await first()
            try await body()
            await after()
        }
    }

    /// A change the watcher saw; tests call it directly. A copy whose stamp has not moved since it
    /// was last looked at needs nothing: that event is the echo of an upload reading its snapshot,
    /// or a late one for a delete already seen, and must not restart retries or a grace.
    func localChanged(_ id: LiveFileID) {
        guard let entry = entries[id], Self.stamp(entry.local) != entry.observed else { return }
        lookAgain(id)
    }

    // MARK: Watching

    private func startWatching() {
        guard watches, watching == nil else { return }
        guard let watcher = LiveWatcher(root: root) else {
            for ref in servers.values { ref.server?.liveEmit(.notice("The Live folder cannot be watched, so Live files are checked every 2 seconds")) }
            return startPolling(every: Self.pollInterval)
        }
        self.watcher = watcher
        watching = Task { [weak self] in
            for await signal in watcher.signals { await self?.handle(signal, from: watcher) }
        }
    }

    /// Stamps every working copy on a timer, for when FSEvents fails. Tests start it directly.
    func startPolling(every interval: Duration) {
        watching?.cancel()
        watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.lookAtAll()
            }
        }
    }

    private func lookAtAll() {
        for id in entries.keys { localChanged(id) }
    }

    /// Only the working copy's own path counts, not editor swap files, our temps, or the "(server)" copy.
    private func handle(_ signal: LiveWatcher.Signal, from watcher: LiveWatcher) {
        switch signal {
        case .rescan:
            lookAtAll()
        case .changed(let paths):
            for path in paths {
                guard let parts = watcher.components(of: path), parts.count >= 2, let uuid = UUID(uuidString: parts[1]),
                      let entry = entries[LiveFileID(rawValue: uuid)], parts.count == 2 || parts[2] == entry.local.lastPathComponent else { continue }
                localChanged(entry.id)
            }
        }
    }

    /// Login, Resume, or Retry: a fresh round of retries, and a pass even if nothing moved.
    private func lookAgain(_ id: LiveFileID) {
        entries[id]?.attempts = 0
        look(id)
    }

    /// Records the working copy's stamp and schedules a pass once it has held still.
    private func look(_ id: LiveFileID) {
        guard let entry = entries[id] else { return }
        let stamp = Self.stamp(entry.local)
        entries[id]?.observed = stamp
        if stamp != nil { entries[id]?.missingSeen = false }
        // Already seen missing: a Retry or login must not cut the grace short.
        schedule(id, after: stamp == nil && entry.missingSeen ? Self.missingGrace : Self.settle)
    }

    // MARK: The worker

    private func schedule(_ id: LiveFileID, after delay: Duration = .zero) {
        guard let connection = entries[id]?.connection else { return }
        startWorker(connection)
        workers[connection]?.waitingForServer.remove(id)
        workers[connection]?.due[id] = .now + delay
        poke(connection)
    }

    private func park(_ id: LiveFileID) {
        guard let entry = entries[id] else { return }
        workers[entry.connection]?.due[id] = nil
        workers[entry.connection]?.waitingForServer.insert(id)
        report(entry, .queued, "Waiting for the server")
    }

    private func startWorker(_ connection: ConnectionID) {
        guard workers[connection]?.loop == nil else { return }
        workers[connection, default: Worker()].loop = Task { await self.run(connection) }
    }

    /// Commands first, in order; then the earliest pass that is due; else sleep until one is.
    private func run(_ connection: ConnectionID) async {
        while !Task.isCancelled, let worker = workers[connection] {
            let now = ContinuousClock.now
            if let command = worker.commands.first {
                workers[connection]?.commands.removeFirst()
                workers[connection]?.running = true
                await command.run()
                workers[connection]?.running = false
            } else if let next = worker.due.filter({ $0.value <= now }).min(by: { $0.value < $1.value })?.key {
                workers[connection]?.due[next] = nil
                workers[connection]?.running = true
                await pass(next)
                workers[connection]?.running = false
                // A pass that neither waited again nor reported clears a "Waiting for the server" row.
                if let entry = entries[next], entry.shown == .queued, workers[connection]?.waitingForServer.contains(next) != true {
                    report(entry, .succeeded)
                }
            } else {
                await idle(connection)
            }
        }
    }

    private func idle(_ connection: ConnectionID) async {
        await withCheckedContinuation { (wake: CheckedContinuation<Void, Never>) in
            guard workers[connection] != nil else { return wake.resume() }
            workers[connection]?.wake = wake
            if let next = workers[connection]?.due.values.min() {
                workers[connection]?.timer = Task { [weak self] in
                    try? await Task.sleep(until: next, clock: .continuous)
                    await self?.poke(connection)
                }
            }
        }
        workers[connection]?.timer.take()?.cancel()
    }

    private func poke(_ connection: ConnectionID) {
        workers[connection]?.wake.take()?.resume()
    }

    /// What the connection's worker has queued, due, or running. Tests wait for zero before a check
    /// that something did not happen, rather than for a time.
    func workCount(on connection: ConnectionID) -> Int {
        guard let worker = workers[connection] else { return 0 }
        return (worker.running ? 1 : 0) + worker.commands.count + worker.due.count
    }

    /// Whether the last pass found the working copy missing, and it now has its grace to reappear.
    func isMissing(_ id: LiveFileID) -> Bool {
        entries[id]?.missingSeen == true
    }

    /// Runs `body` on the connection's worker, between passes, and returns its result.
    private func perform<T: Sendable>(on connection: ConnectionID, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<T, Error>) in
            startWorker(connection)
            workers[connection]?.commands.append(Command(
                run: { do { done.resume(returning: try await body()) } catch { done.resume(throwing: error) } },
                cancel: { done.resume(throwing: TransferError.cancelled) }
            ))
            poke(connection)
        }
    }

    // MARK: A pass

    private func pass(_ id: LiveFileID) async {
        guard let first = entries[id] else { return }
        let stamp = Self.stamp(first.local)
        if let stamp {
            // Act only on a working copy that has held still since it was last looked at.
            guard first.observed == stamp else { return look(id) }
            if first.missingSeen { mark(id) { $0.missingSeen = false } }
        }
        var digest: String?
        var server = LiveServerFact.notChecked
        var item: RemoteItem?
        while let entry = entries[id] {
            let local: LiveLocal = stamp.map { .present($0, digest: digest) } ?? .missing(again: entry.missingSeen)
            switch LiveDecision.decide(entry.state, local: local, server: server) {
            case .none, .refreshLocal: return
            case .markClean: return change(id) { $0.state.dirty = false }
            case .markDirty: return change(id) { $0.state.dirty = true }
            case .restamp:
                update(id) {
                    $0.state.synced = stamp
                    if !$0.state.conflict { $0.state.dirty = false }
                }
                return
            case .recheckMissing:
                // A late event for this delete finds nothing new; only the grace decides.
                mark(id) {
                    $0.missingSeen = true
                    $0.observed = nil
                }
                return schedule(id, after: Self.missingGrace)
            case .failMissing:
                return report(entry, .failed, "The working copy disappeared before its edits were uploaded")
            case .forget: return drop(entry)
            case .needDigest:
                // Deleted since its stamp was read: look again, as a missing file.
                guard let read = await Self.readDigest(entry.local) else {
                    if Self.stamp(entry.local) == nil { return look(id) }
                    digest = Self.unreadable
                    continue
                }
                digest = read
            case .needServer:
                if !entry.state.dirty { change(id) { $0.state.dirty = true } }
                guard let found = await lookup(id) else { return }
                (item, server) = found
            case .adopt(let print):
                // Only if nothing was saved during the lookup: those bytes would go unsent.
                guard Self.stamp(entry.local) == stamp else { return look(id) }
                return change(id) { $0.recordSync(print, stamp, $0.pendingDigest) }
            case .failRetryable(let reason): return retry(id, reason: reason)
            case .conflict(let kind): return await raiseConflict(id, kind: kind, item: item)
            case .upload(let base):
                guard let saver = servers[entry.connection]?.server else { return park(id) }
                switch await save(id, expecting: .file(base), settled: stamp, via: saver) {
                case .done, .unstable, .missing, .failed: return
                case .retry(let reason): return retry(id, reason: reason)
                case .serverChanged:
                    guard let found = await lookup(id) else { return }
                    (item, server) = found
                }
            }
        }
    }

    /// The server's file for `id`, or nil after parking the pass until the server is back.
    private func lookup(_ id: LiveFileID) async -> (RemoteItem?, LiveServerFact)? {
        guard let entry = entries[id], ready.contains(entry.connection), let server = servers[entry.connection]?.server else {
            park(id)
            return nil
        }
        do {
            guard let item = try await server.liveLookup(entry.path) else { return (nil, .missing) }
            guard item.kind == .file, let print = Fingerprint(item: item) else { return (item, .notFile(item.kind)) }
            return (item, .file(print))
        } catch {
            return (nil, .unreachable(error.localizedDescription))
        }
    }

    /// A dropped connection waits for the server; anything else retries at 1, 2, and 4 s, then
    /// is reported and waits for the next change, login, or Retry.
    private func retry(_ id: LiveFileID, reason: String) {
        guard let entry = entries[id], ready.contains(entry.connection) else { return park(id) }
        guard let delay = RetryPolicy.delay(afterAttempt: entry.attempts) else { return report(entry, .failed, reason) }
        mark(id) { $0.attempts += 1 }
        schedule(id, after: .seconds(delay))
    }

    private enum SaveOutcome { case done, unstable, missing, serverChanged, retry(String), failed }

    /// One upload of the working copy as it is now. A pass passes the stamp that held still: bytes
    /// written since, as during its lookup, have not, and wait for another look. The copy must not
    /// change while it is read; the new base is what the server reports for our own bytes.
    private func save(_ id: LiveFileID, expecting: ServerExpectation, settled: LiveStamp?, via server: any LiveServer) async -> SaveOutcome {
        guard let entry = entries[id] else { return .done }
        guard let before = Self.stamp(entry.local) else { return .missing }
        guard settled == nil || before == settled else {
            look(id)
            return .unstable
        }
        let snapshot: URL
        do { snapshot = try Self.snapshot(of: entry.local) } catch {
            report(entry, .failed, error.localizedDescription)
            return .failed
        }
        defer { try? FileManager.default.removeItem(at: snapshot) }
        guard Self.stamp(entry.local) == before else {
            look(id)
            return .unstable
        }
        guard let digest = await Self.readDigest(snapshot) else {
            report(entry, .failed, "Could not read \(entry.name)")
            return .failed
        }
        mark(id) {
            $0.uploading = true
            $0.state.pending = before
            $0.pendingDigest = digest
        }
        emit(entry, .liveChanged)
        do {
            let print = try await server.liveSave(snapshot, to: entry.path, expecting: expecting) { [entry] progress in
                server.liveEmit(.operation(Self.operation(entry, state: .active, progress: progress)))
            }
            saves += 1
            lastSave[id] = saves
            guard let saved = update(id, {
                $0.uploading = false
                $0.recordSync(print, before, digest)
                $0.state.dirty = Self.stamp($0.local) != before
                $0.attempts = 0
            }) else { return .done }
            // Paused during this upload: it finished, but the file stays paused, and says so.
            report(saved, saved.state.paused ? .paused : .succeeded)
            emit(saved, .liveChanged)
            if let parent = saved.path.parent { emit(saved, .directoryChanged(parent)) }
            if saved.state.dirty { look(id) }
            return .done
        } catch {
            mark(id) { $0.uploading = false }
            emit(entry, .liveChanged)
            if error is LiveRemoteChanged { return .serverChanged }
            if RetryPolicy.isRetryable(error) || (error as? TransferError) == .notConnected { return .retry(error.localizedDescription) }
            report(entry, .failed, error.localizedDescription)
            return .failed
        }
    }

    /// Writes the "(server)" copy first, then marks the conflict and announces it together. An
    /// older "(server)" copy goes first, so a failed fetch never leaves outdated bytes looking
    /// current, unless `keepingServerCopy`: the server's file is gone, and that copy is all that
    /// is left of it.
    private func raiseConflict(_ id: LiveFileID, kind: LiveConflictKind, item: RemoteItem?, keepingServerCopy: Bool = false) async {
        guard let entry = entries[id] else { return }
        if !keepingServerCopy { try? FileManager.default.removeItem(at: entry.serverCopy) }
        if case .changed = kind, let item, let server = servers[entry.connection]?.server {
            try? await server.liveFetch(item, to: entry.serverCopy, interactive: false)
        }
        guard let conflicted = update(id, {
            $0.conflict = kind
            $0.state.conflict = true
            $0.state.dirty = true
        }) else {
            // Discarded while the copy downloaded: only what that download made goes.
            try? FileManager.default.removeItem(at: entry.serverCopy)
            return
        }
        let message = switch kind {
        case .changed: "Changed on the server"
        case .removed: "Removed from the server"
        case .notAFile: "Replaced on the server by something that is not a file"
        }
        let hasCopy = FileManager.default.fileExists(atPath: conflicted.serverCopy.path)
        let comparable = kind.server != nil && FileManager.default.isExecutableFile(atPath: "/usr/bin/opendiff")
            && Self.isUTF8(conflicted.local) && (!hasCopy || Self.isUTF8(conflicted.serverCopy))
        report(conflicted, .failed, message)
        emit(conflicted, .conflict(conflicted.path, comparable: comparable))
        emit(conflicted, .liveChanged)
    }

    // MARK: Commands

    private func openNow(_ path: RemotePath, on connection: ConnectionID) async throws -> URL {
        let server = try loggedIn(connection)
        guard let item = try await server.liveLookup(path) else { throw TransferError.noSuchFile(path.display) }
        guard item.kind == .file, let print = Fingerprint(item: item) else { throw TransferError.typeMismatch(path.display) }
        if let id = find(path, on: connection), let entry = entries[id] {
            if let stamp = Self.stamp(entry.local) {
                let digest = await Self.digestIfNeeded(entry.state, entry.local, stamp)
                let action = LiveDecision.decide(entry.state, local: .present(stamp, digest: digest), server: .file(print), intent: .open)
                if case .refreshLocal = action {
                    if try await placeServerBytes(item, print, for: id, ifStill: stamp, via: server, interactive: true), let refreshed = entries[id] {
                        emit(refreshed, .liveChanged)
                    } else {
                        look(id)
                    }
                } else if LiveDecision.localChange(entry.state, stamp, digest: digest) == .changed {
                    look(id)
                }
                return entry.local
            }
            // The copy is gone. Its folder goes too, unless it held edits an editor's backup may keep.
            if LiveDecision.isUnsynced(entry.state, nil) { forget(id) } else { drop(entry) }
        }
        let id = LiveFileID()
        let folder = root.appendingPathComponent("\(connection.rawValue.uuidString)/\(id.rawValue.uuidString)", isDirectory: true)
        let file = try LocalPlacement.child(folder, name: item.name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        do {
            try await server.liveFetch(item, to: file, interactive: true)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        // No editor knows this path until it is returned, so reading it now reads what was fetched.
        let stamp = Self.stamp(file)
        let digest = await Self.readDigest(file)
        entries[id] = Entry(id: id, connection: connection, path: path, local: file, state: LiveState(base: print))
        adopt(id, server: print, stamp: stamp, digest: digest)
        server.liveEmit(.liveChanged)
        return file
    }

    /// The working copy now holds the server's `print`, with this stamp and digest: record it as synced.
    private func adopt(_ id: LiveFileID, server print: Fingerprint, stamp: LiveStamp?, digest: String?) {
        update(id) {
            $0.recordSync(print, stamp, digest)
            $0.state.conflict = false
            $0.conflict = nil
            $0.missingSeen = false
            $0.observed = stamp
        }
    }

    /// Replaces the working copy with the server's bytes, only if it still has the stamp `expected`
    /// (nil: still missing), so an editor's save is never overwritten. The bytes are downloaded
    /// beside it and measured there, then renamed over it in a coordinated write, which tells an
    /// NSDocument editor that has it open. Returns false, changing nothing, when the copy moved.
    private func placeServerBytes(_ item: RemoteItem, _ print: Fingerprint, for id: LiveFileID, ifStill expected: LiveStamp?,
                                  via server: any LiveServer, interactive: Bool) async throws -> Bool {
        guard let entry = entries[id] else { return false }
        let fresh = entry.folder.appendingPathComponent(LiveDecision.siblingName(of: entry.local.lastPathComponent, prefix: ".", suffix: ".transfer-refresh"))
        defer { try? FileManager.default.removeItem(at: fresh) }
        try await server.liveFetch(item, to: fresh, interactive: interactive)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fresh.path)
        // A rename keeps both, and an editor saving just after it cannot slip its bytes into the record.
        let stamp = Self.stamp(fresh)
        let digest = await Self.readDigest(fresh)
        var placed = false
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: entry.local, options: .forReplacing, error: &coordinatorError) { url in
            guard Self.stamp(url) == expected else { return }
            placed = Darwin.rename(fresh.path, url.path) == 0
        }
        guard placed else { return false }
        adopt(id, server: print, stamp: stamp, digest: digest)
        return true
    }

    private func resolveNow(_ path: RemotePath, on connection: ConnectionID, choice: LiveConflictChoice) async throws {
        guard let id = find(path, on: connection), let entry = entries[id] else { throw TransferError.noSuchFile(path.display) }
        let before = Self.stamp(entry.local)
        switch choice {
        case .compare:
            return try await compare(entry)
        case .keepLocal:
            let server = try loggedIn(connection)
            guard let expecting = LiveDecision.keepLocalExpectation(entry.state, conflict: entry.conflict) else {
                throw TransferError.typeMismatch(path.display)
            }
            switch await save(id, expecting: expecting, settled: try await stillStamp(entry), via: server) {
            case .done:
                update(id) {
                    $0.conflict = nil
                    $0.state.conflict = false
                }
            case .serverChanged:
                // Changed again since the conflict was raised: show the new server copy instead.
                if let (item, fact) = await lookup(id), let kind = LiveDecision.conflictKind(for: fact) {
                    await raiseConflict(id, kind: kind, item: item)
                }
                throw TransferError.failed("\(entry.name) changed on the server again")
            case .unstable: throw TransferError.failed("\(entry.name) is still being written")
            case .missing: throw TransferError.failed("The working copy of \(entry.name) is missing")
            case .retry(let reason): throw TransferError.failed(reason)
            case .failed: throw TransferError.failed("Could not upload \(entry.name)")
            }
        case .keepRemote:
            try await takeServerCopy(id, ifStill: before, via: try loggedIn(connection))
        case .keepBoth:
            let server = try loggedIn(connection)
            guard let before = try await stillStamp(entry) else { throw TransferError.failed("The working copy of \(entry.name) is missing") }
            let snapshot = try Self.snapshot(of: entry.local)
            defer { try? FileManager.default.removeItem(at: snapshot) }
            guard Self.stamp(entry.local) == before else { throw TransferError.failed("\(entry.name) is still being written") }
            let parent = entry.path.parent ?? RemotePath(string: "/")
            let name = KeepBothName.fromThisMac(existing: try await server.liveNames(in: parent), original: entry.name)
            do {
                _ = try await server.liveSave(snapshot, to: parent.appending(name: Array(name.utf8)), expecting: .absent) { _ in }
            } catch is LiveRemoteChanged {
                throw TransferError.failed("Something named “\(name)” appeared on the server; try Keep Both again")
            }
            try await takeServerCopy(id, ifStill: before, via: server, uploaded: true)
        }
        guard let resolved = entries[id] else { return }
        try? FileManager.default.removeItem(at: resolved.serverCopy)
        if resolved.shown != .succeeded { report(resolved, .succeeded) }
        emit(resolved, .liveChanged)
        if let parent = resolved.path.parent { emit(resolved, .directoryChanged(parent)) }
        if resolved.state.dirty { look(id) }
    }

    /// Keep Remote, and the end of Keep Both (`uploaded`): the server's file replaces the working
    /// copy, only while the copy still has the stamp the choice was made on; a save since then
    /// stays, and so does the conflict. When the server holds no file the record goes only if the
    /// working copy is safe elsewhere (Keep Both uploaded it) or the conflict the user answered
    /// already showed no file (`LiveDecision.keepRemoteForgets`). A file that vanished since the
    /// choice leaves nothing to take: the conflict is raised again, both copies kept.
    private func takeServerCopy(_ id: LiveFileID, ifStill expected: LiveStamp?, via server: any LiveServer, uploaded: Bool = false) async throws {
        guard let entry = entries[id] else { return }
        let item = try await server.liveLookup(entry.path)
        if let item, item.kind == .file, let print = Fingerprint(item: item) {
            if try await placeServerBytes(item, print, for: id, ifStill: expected, via: server, interactive: false) { return }
        } else if !uploaded, !LiveDecision.keepRemoteForgets(entry.conflict, server: item.map { .notFile($0.kind) } ?? .missing) {
            await raiseConflict(id, kind: item == nil ? .removed : .notAFile, item: nil, keepingServerCopy: true)
            throw TransferError.failed("\(entry.name) is no longer on the server as it was when you chose; its conflict stays")
        } else if Self.stamp(entry.local) == expected {
            return drop(entry)
        }
        throw TransferError.failed("\(entry.name) was saved again meanwhile; its conflict stays")
    }

    /// The working copy's stamp once it has held still for `settle`, as a pass requires of a copy
    /// it uploads; nil when it is missing. Throws while it is still being written.
    private func stillStamp(_ entry: Entry) async throws -> LiveStamp? {
        guard let before = Self.stamp(entry.local) else { return nil }
        let age = Duration.seconds(max(Date().timeIntervalSince(before.mtime), 0))
        if age < Self.settle { try await Task.sleep(for: Self.settle - age) }
        guard Self.stamp(entry.local) == before else { throw TransferError.failed("\(entry.name) is still being written") }
        return before
    }

    private func compare(_ entry: Entry) async throws {
        if !FileManager.default.fileExists(atPath: entry.serverCopy.path) {
            guard let server = servers[entry.connection]?.server, let item = try await server.liveLookup(entry.path), item.kind == .file else {
                throw TransferError.noSuchFile(entry.path.display)
            }
            try await server.liveFetch(item, to: entry.serverCopy, interactive: true)
        }
        try Process.run(URL(fileURLWithPath: "/usr/bin/opendiff"), arguments: [entry.local.path, entry.serverCopy.path])
    }

    private func discardNow(_ id: LiveFileID, force: Bool) async throws {
        guard let entry = entries[id] else { return }
        if !force, await isUnsynced(entry) { throw TransferError.liveUnsynced(1) }
        drop(entry)
    }

    /// Only the remote path follows a rename. The working copy keeps its name and place: an editor
    /// that has it open goes on saving there, and the watcher knows the copy only by that name.
    private func moved(_ source: RemotePath, to destination: RemotePath, on connection: ConnectionID) {
        for entry in entries.values where entry.connection == connection {
            guard let path = entry.path.replacing(prefix: source, with: destination) else { continue }
            update(entry.id) { $0.path = path }
            emit(entry, .liveChanged)
        }
    }

    private func under(_ path: RemotePath, on connection: ConnectionID) -> [Entry] {
        entries.values.filter { $0.connection == connection && $0.path.isInside(path) }
    }

    private func refuseUnsynced(under path: RemotePath, on connection: ConnectionID) async throws {
        var unsynced = 0
        for entry in under(path, on: connection) where await isUnsynced(entry) { unsynced += 1 }
        if unsynced > 0 { throw TransferError.liveUnsynced(unsynced) }
    }

    /// After the removal: a copy saved while it ran is kept as removed from the server, so Keep
    /// Local can put it back.
    private func removed(_ path: RemotePath, on connection: ConnectionID, force: Bool) async {
        for entry in under(path, on: connection) where entries[entry.id] != nil {
            let change = await localChange(of: entry)
            switch LiveDecision.afterRemoval(entry.state, change, force: force) {
            case .conflict(let kind): await raiseConflict(entry.id, kind: kind, item: nil)
            default: drop(entry)
            }
        }
    }

    // MARK: Saves a move looks for

    /// Live saves landed so far, and the count at each file's last one: a move's original is
    /// verified by walking it, and a save that lands after the walk is not in the copy (R-L2).
    private var saves: UInt64 = 0
    private var lastSave: [LiveFileID: UInt64] = [:]

    /// A mark to pass to `saved(under:on:since:)`, read before the walk.
    func saveMark() -> UInt64 {
        lastSave = lastSave.filter { entries[$0.key] != nil }
        return saves
    }

    /// Whether a Live file under `path` on `connection` was saved to the server since `mark`.
    func saved(under path: RemotePath, on connection: ConnectionID, since mark: UInt64) -> Bool {
        under(path, on: connection).contains { lastSave[$0.id, default: 0] > mark }
    }

    // MARK: Records

    private func find(_ path: RemotePath, on connection: ConnectionID) -> LiveFileID? {
        entries.values.first { $0.connection == connection && $0.path == path }?.id
    }

    private func loggedIn(_ connection: ConnectionID) throws -> any LiveServer {
        guard ready.contains(connection), let server = servers[connection]?.server else { throw TransferError.notConnected }
        return server
    }

    /// Changes a record and stores it. Nil, and no change, when it is gone.
    @discardableResult
    private func update(_ id: LiveFileID, _ body: (inout Entry) -> Void) -> Entry? {
        guard let entry = mark(id, body) else { return nil }
        store.saveLive(Self.row(entry))
        return entry
    }

    /// Changes what only memory keeps (upload, retry, and missing bookkeeping); nothing is stored.
    @discardableResult
    private func mark(_ id: LiveFileID, _ body: (inout Entry) -> Void) -> Entry? {
        guard var entry = entries[id] else { return nil }
        body(&entry)
        entries[id] = entry
        return entry
    }

    private func change(_ id: LiveFileID, _ body: (inout Entry) -> Void) {
        if let entry = update(id, body) { emit(entry, .liveChanged) }
    }

    private func drop(_ entry: Entry) {
        forget(entry.id)
        try? FileManager.default.removeItem(at: entry.folder)
        emit(entry, .liveChanged)
    }

    private func forget(_ id: LiveFileID) {
        guard let connection = entries.removeValue(forKey: id)?.connection else { return }
        workers[connection]?.due[id] = nil
        workers[connection]?.waitingForServer.remove(id)
        store.deleteLive(id)
    }

    private func emit(_ entry: Entry, _ event: SessionEvent) {
        servers[entry.connection]?.server?.liveEmit(event)
    }

    /// The file's row on the shelf.
    private func report(_ entry: Entry, _ state: OperationState, _ message: String? = nil) {
        entries[entry.id]?.shown = state
        emit(entry, .operation(Self.operation(entry, state: state, message: message)))
    }

    private static func operation(_ entry: Entry, state: OperationState, message: String? = nil, progress: TransferProgress = TransferProgress(completed: 0)) -> TransferOperation {
        TransferOperation(id: entry.id.rawValue.uuidString, title: entry.name, state: state, progress: progress, message: message, livePath: entry.path)
    }

    private static func entry(from row: LiveRow, local: URL) -> Entry {
        let synced = row.syncedSize.flatMap { size in row.syncedMtime.map { LiveStamp(size: size, mtime: Date(timeIntervalSinceReferenceDate: $0)) } }
        let conflict = LiveConflictKind(code: row.conflict, server: fingerprint(row.conflictSize, row.conflictMtime))
        let state = LiveState(base: fingerprint(row.baseSize, row.baseMtime), synced: synced, syncedDigest: row.syncedDigest,
                              dirty: row.dirty, paused: row.paused, conflict: conflict != nil)
        return Entry(id: row.id, connection: row.connection, path: row.path, local: local, state: state, conflict: conflict)
    }

    private static func row(_ entry: Entry) -> LiveRow {
        LiveRow(
            id: entry.id, connection: entry.connection, path: entry.path,
            baseSize: entry.state.base?.size, baseMtime: entry.state.base?.mtime,
            localPath: entry.local.path, dirty: entry.state.dirty, paused: entry.state.paused,
            conflict: entry.conflict?.code, conflictSize: entry.conflict?.server?.size, conflictMtime: entry.conflict?.server?.mtime,
            syncedSize: entry.state.synced?.size, syncedMtime: entry.state.synced?.mtime.timeIntervalSinceReferenceDate, syncedDigest: entry.state.syncedDigest
        )
    }

    private static func fingerprint(_ size: UInt64?, _ mtime: UInt32?) -> Fingerprint? {
        guard let size, let mtime else { return nil }
        return Fingerprint(size: size, mtime: mtime)
    }

    // MARK: Files

    /// The one test for "this copy holds bytes the server lacks", edits no pass has seen included.
    private func isUnsynced(_ entry: Entry) async -> Bool {
        LiveDecision.isUnsynced(entry.state, await localChange(of: entry))
    }

    /// How the copy compares with the last sync, nil when it is missing; bytes are read off the
    /// actor, only when the stamp alone cannot tell, and once per stamp (`measured`).
    private func localChange(of entry: Entry) async -> LiveLocalChange? {
        guard let stamp = Self.stamp(entry.local) else { return nil }
        let change = LiveDecision.localChange(entry.state, stamp, digest: nil)
        guard change == .needDigest else { return change }
        if let measured = entries[entry.id]?.measured, measured.stamp == stamp {
            return LiveDecision.localChange(entry.state, stamp, digest: measured.digest)
        }
        let digest = await Self.readDigest(entry.local) ?? Self.unreadable
        // Bytes saved during the read are not the bytes of `stamp`.
        if Self.stamp(entry.local) == stamp { mark(entry.id) { $0.measured = (stamp, digest) } }
        return LiveDecision.localChange(entry.state, stamp, digest: digest)
    }

    /// `unsyncedCount` from what is known now, reading no bytes: nil when a copy's stamp has no
    /// digest read for it yet.
    private func unsyncedNow(on connection: ConnectionID) -> Int? {
        var count = 0
        for entry in entries.values where entry.connection == connection {
            var change = Self.stamp(entry.local).map { LiveDecision.localChange(entry.state, $0, digest: nil) }
            if change == .needDigest {
                guard let measured = entry.measured, measured.stamp == Self.stamp(entry.local) else { return nil }
                change = LiveDecision.localChange(entry.state, measured.stamp, digest: measured.digest)
            }
            if LiveDecision.isUnsynced(entry.state, change) { count += 1 }
        }
        return count
    }

    /// Size and full-precision mtime, read through FileManager: `URL.resourceValues` caches.
    static func stamp(_ url: URL) -> LiveStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let mtime = attributes[.modificationDate] as? Date else { return nil }
        return LiveStamp(size: size, mtime: mtime)
    }

    /// `localChange`, for launch, where the actor does not exist yet.
    private static func localChange(_ state: LiveState, _ url: URL, _ stamp: LiveStamp) -> LiveLocalChange {
        let change = LiveDecision.localChange(state, stamp, digest: nil)
        return change == .needDigest ? LiveDecision.localChange(state, stamp, digest: digest(of: url) ?? unreadable) : change
    }

    /// The copy's digest when the stamp alone cannot tell whether it changed, else nil. Bytes that
    /// cannot be read count as an edit, which the upload then reports.
    private static func digestIfNeeded(_ state: LiveState, _ url: URL, _ stamp: LiveStamp) async -> String? {
        guard LiveDecision.localChange(state, stamp, digest: nil) == .needDigest else { return nil }
        return await readDigest(url) ?? unreadable
    }

    static func digest(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `digest(of:)` off the actor: hashing a large file must not stall every server's Live work.
    private static func readDigest(_ url: URL) async -> String? {
        await Task.detached(priority: .utility) { digest(of: url) }.value
    }

    private static func isUTF8(_ url: URL) -> Bool {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } != nil
    }

    /// A copy of the working file taken under an `NSFileCoordinator` read, with the same mtime.
    private static func snapshot(of file: URL) throws -> URL {
        let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: file, options: [], error: &coordinatorError) { url in
            do {
                try FileManager.default.copyItem(at: url, to: snapshot)
                if let date = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date {
                    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: snapshot.path)
                }
            } catch { copyError = error }
        }
        if let error = coordinatorError ?? copyError { throw TransferError.failed(error.localizedDescription) }
        return snapshot
    }
}

/// How a conflict is stored: a code, and the server file's fingerprint for "changed".
private extension LiveConflictKind {
    var code: String {
        switch self {
        case .changed: "changed"
        case .removed: "removed"
        case .notAFile: "notAFile"
        }
    }

    var server: Fingerprint? {
        if case .changed(let print) = self { print } else { nil }
    }

    init?(code: String?, server: Fingerprint?) {
        switch (code, server) {
        case ("changed", let server?): self = .changed(server)
        case ("removed", _): self = .removed
        case ("notAFile", _): self = .notAFile
        default: return nil
        }
    }
}
