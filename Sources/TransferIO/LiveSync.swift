import CryptoKit
import Foundation
import TransferCore

/// What the server must hold just before a save's rename. Anything else makes it a conflict.
enum ServerExpectation: Sendable, Equatable {
    case file(Fingerprint)
    case absent
}

struct LiveRemoteChanged: Error {}

/// What Live sync needs from a server. `SSHConnection` conforms; tests use a fake.
protocol LiveServer: AnyObject, Sendable {
    /// The item at `path`, or nil when there is none. Any other failure throws: a dropped
    /// connection is not evidence that the file was removed.
    func liveLookup(_ path: RemotePath) async throws -> RemoteItem?
    /// Downloads `item` over `local` in one rename. `interactive` uses the lane the user waits on.
    func liveFetch(_ item: RemoteItem, to local: URL, interactive: Bool) async throws
    /// Uploads `snapshot` to `path` with temp-and-rename on the interactive lane. Just before the
    /// rename the server must match `expecting` (or hold this save's own bytes, if the lane ran
    /// it again), else it throws `LiveRemoteChanged`. Returns the server file's new fingerprint.
    func liveSave(_ snapshot: URL, to path: RemotePath, expecting: ServerExpectation, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> Fingerprint
    func liveNames(in folder: RemotePath) async throws -> Set<String>
    func liveEmit(_ event: SessionEvent)
}

/// Everything about Live files, in one place: the records and their storage, one watcher over
/// the Live folder, and one worker per server that runs every pass and every command for that
/// server's files in turn. Only the worker changes a file's sync state, so nothing races and
/// nothing needs a lock. A pass does what `LiveDecision` answers from the facts it gathers: the
/// copy's stamp, a digest when the stamp moved, and the server's file. One per app, owned by the
/// hub, so the one watcher and the records outlive any connection.
actor LiveSync {
    /// How long a working copy must hold still before a pass acts on it.
    static let settle: Duration = .milliseconds(350)
    /// How long a missing working copy is given to reappear, as an editor may be mid-save.
    static let missingGrace: Duration = .seconds(1)
    /// A synced mapping untouched for this long is forgotten at launch.
    static let expiry: TimeInterval = 24 * 60 * 60

    private struct Entry {
        let id: LiveFileID
        let connection: ConnectionID
        var path: RemotePath
        var local: URL
        var state: LiveState
        var conflict: LiveConflictKind?
        var uploading = false
        var missingSeen = false
        /// The stamp when this file was last looked at, and whether it has been: a pass acts only
        /// on a working copy whose stamp has not moved since then.
        var looked = false
        var observed: LiveStamp?
        var attempts = 0
        /// The state of this file's row on the shelf, as last reported.
        var shown: OperationState?

        var name: String { path.name }
        var folder: URL { local.deletingLastPathComponent() }
        var serverCopy: URL { folder.appendingPathComponent("\(name) (server)") }
    }

    private struct Command {
        let run: @Sendable () async -> Void
        let cancel: @Sendable () -> Void
    }

    private struct Worker {
        var due: [LiveFileID: ContinuousClock.Instant] = [:]
        var waitingForServer: Set<LiveFileID> = []
        var commands: [Command] = []
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

    /// Records from their rows. A copy edited while Transfer was closed, or before its server
    /// logged in, is dirty at once, so Quit and Remove Server count it. A synced copy untouched for
    /// a day expires; its last activity is the later of its and its folder's mtime, since a
    /// download gives the file the server's older time.
    private static func load(_ rows: [LiveRow], store: Store) -> ([LiveFileID: Entry], [ConnectionID: [String]]) {
        var loaded: [LiveFileID: Entry] = [:]
        var gone: [ConnectionID: [String]] = [:]
        for row in rows {
            let local = URL(fileURLWithPath: row.localPath)
            guard let stamp = stamp(local) else {
                if row.dirty { gone[row.connection, default: []].append("The Live copy of \(row.path.display) is gone; its edits were not uploaded") }
                store.deleteLive(row.id)
                continue
            }
            var entry = entry(from: row, local: local)
            let change = localChange(entry.state, local, stamp)
            if change == .changed, !entry.state.dirty {
                entry.state.dirty = true
                store.saveLive(Self.row(entry))
            }
            let folderTime = (try? FileManager.default.attributesOfItem(atPath: entry.folder.path)[.modificationDate] as? Date) ?? .distantPast
            if !entry.state.dirty, entry.conflict == nil, Date().timeIntervalSince(max(stamp.mtime, folderTime)) > expiry {
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
        for entry in entries.values where entry.connection == connection { look(entry.id) }
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

    /// Stops everything: the watcher and every worker. For a `LiveSync` owned by one connection.
    func closeAll() {
        for connection in Set(workers.keys).union(servers.keys) { close(connection) }
        watching?.cancel()
        watcher?.stop()
        watcher = nil
    }

    // MARK: The public Live API, per connection

    func files(on connection: ConnectionID) -> [LiveFile] {
        entries.values.filter { $0.connection == connection }
            .map { LiveFile(id: $0.id, path: $0.path, dirty: $0.state.dirty, paused: $0.state.paused, conflict: $0.state.conflict, uploading: $0.uploading) }
            .sorted { $0.path.display < $1.path.display }
    }

    /// Files with edits the server lacks, even ones no pass has seen yet. Nil counts every server's.
    func unsyncedCount(on connection: ConnectionID? = nil) -> Int {
        entries.values.filter { entry in
            guard connection == nil || entry.connection == connection else { return false }
            return entry.state.dirty || Self.stamp(entry.local).map { Self.localChange(entry.state, entry.local, $0) == .changed } == true
        }.count
    }

    /// The working copy for `path`: downloaded, or refreshed if the server moved on and it is untouched.
    func open(_ path: RemotePath, on connection: ConnectionID) async throws -> URL {
        try await perform(on: connection) { try await self.openNow(path, on: connection) }
    }

    func setPaused(_ path: RemotePath, on connection: ConnectionID, paused: Bool) {
        guard let id = find(path, on: connection), let entry = update(id, { $0.state.paused = paused }) else { return }
        // Resume and Retry: the row goes, and a pass shows what is left to do.
        report(entry, paused ? .paused : .succeeded)
        if !paused { localChanged(id) }
        emit(entry, .liveChanged)
    }

    func resolve(_ path: RemotePath, on connection: ConnectionID, choice: LiveConflictChoice) async throws {
        if choice == .compare { return try await compare(path, on: connection) }
        try await perform(on: connection) { try await self.resolveNow(path, on: connection, choice: choice) }
    }

    func discard(_ path: RemotePath, on connection: ConnectionID, force: Bool) async throws {
        try await perform(on: connection) {
            if let id = await self.find(path, on: connection) { try await self.discardNow(id, force: force) }
        }
    }

    /// A rename on the server of `source`, run by `perform`. Live records under it follow it.
    func rename(_ source: RemotePath, to destination: RemotePath, on connection: ConnectionID, perform rename: @escaping @Sendable () async throws -> Void) async throws {
        try await barrier(under: source, on: connection, rename) { await self.moved(source, to: destination, on: connection) }
    }

    /// A removal on the server of `path`, run by `perform`. Live files under it are forgotten.
    func remove(_ path: RemotePath, on connection: ConnectionID, perform remove: @escaping @Sendable () async throws -> Void) async throws {
        try await barrier(under: path, on: connection, remove) { await self.removed(path, on: connection) }
    }

    /// Runs `body` at once, or, when Live files lie under `path`, between their passes and then
    /// `after`, so no save of theirs lands on the old path.
    private func barrier(under path: RemotePath, on connection: ConnectionID, _ body: @escaping @Sendable () async throws -> Void, then after: @escaping @Sendable () async -> Void) async throws {
        guard entries.values.contains(where: { $0.connection == connection && $0.path.isInside(path) }) else { return try await body() }
        try await perform(on: connection) {
            try await body()
            await after()
        }
    }

    /// A change the watcher saw, or Retry. Tests call it directly.
    func localChanged(_ id: LiveFileID) {
        entries[id]?.attempts = 0
        look(id)
    }

    // MARK: Watching

    private func startWatching() {
        guard watches, watcher == nil, let watcher = LiveWatcher(root: root) else { return }
        self.watcher = watcher
        watching = Task { [weak self] in
            for await signal in watcher.signals { await self?.handle(signal, from: watcher) }
        }
    }

    /// Only the working copy's own path counts, not editor swap files, our temps, or the "(server)" copy.
    private func handle(_ signal: LiveWatcher.Signal, from watcher: LiveWatcher) {
        switch signal {
        case .rescan:
            for id in entries.keys { localChanged(id) }
        case .changed(let paths):
            for path in paths {
                guard let parts = watcher.components(of: path), parts.count >= 2, let uuid = UUID(uuidString: parts[1]),
                      let entry = entries[LiveFileID(rawValue: uuid)], parts.count == 2 || parts[2] == entry.local.lastPathComponent else { continue }
                localChanged(entry.id)
            }
        }
    }

    /// Records the working copy's stamp and schedules a pass once it has held still.
    private func look(_ id: LiveFileID) {
        guard let entry = entries[id] else { return }
        let stamp = Self.stamp(entry.local)
        entries[id]?.looked = true
        entries[id]?.observed = stamp
        if stamp != nil { entries[id]?.missingSeen = false }
        schedule(id, after: Self.settle)
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
                await command.run()
            } else if let next = worker.due.filter({ $0.value <= now }).min(by: { $0.value < $1.value })?.key {
                workers[connection]?.due[next] = nil
                await pass(next)
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
            guard first.looked, first.observed == stamp else { return look(id) }
            if first.missingSeen { entries[id]?.missingSeen = false }
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
                entries[id]?.missingSeen = true
                return schedule(id, after: Self.missingGrace)
            case .failMissing:
                return report(entry, .failed, "The working copy disappeared before its edits were uploaded")
            case .forget: return drop(entry)
            case .needDigest:
                // Unreadable bytes cannot be shown unchanged: treat them as an edit, which the
                // upload then reports if they stay unreadable.
                digest = Self.digest(of: entry.local) ?? "unreadable"
            case .needServer:
                if !entry.state.dirty { change(id) { $0.state.dirty = true } }
                guard let found = await lookup(id) else { return }
                (item, server) = found
            case .adopt(let print):
                // Only if nothing was saved during the lookup: those bytes would go unsent.
                guard Self.stamp(entry.local) == stamp else { return look(id) }
                return change(id) {
                    $0.state.base = print
                    $0.state.synced = stamp
                    $0.state.syncedDigest = Self.digest(of: $0.local)
                    $0.state.dirty = false
                }
            case .failRetryable(let reason): return retry(id, reason: reason)
            case .conflict(let kind): return await raiseConflict(id, kind: kind, item: item)
            case .upload(let base):
                guard let saver = liveServer(for: entry.connection) else { return park(id) }
                switch await save(id, expecting: .file(base), via: saver) {
                case .done, .unstable, .failed: return
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
        guard let entry = entries[id], ready.contains(entry.connection), let server = liveServer(for: entry.connection) else {
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
        entries[id]?.attempts += 1
        schedule(id, after: .seconds(delay))
    }

    private enum SaveOutcome { case done, unstable, serverChanged, retry(String), failed }

    /// One upload of the working copy as it is now. The copy must not change while it is read;
    /// the new base is what the server reports for our own bytes.
    private func save(_ id: LiveFileID, expecting: ServerExpectation, via server: any LiveServer) async -> SaveOutcome {
        guard let entry = entries[id], let before = Self.stamp(entry.local) else { return .unstable }
        func failed(_ message: String) -> SaveOutcome {
            report(entry, .failed, message)
            return .failed
        }
        change(id) { $0.uploading = true }
        defer { change(id) { $0.uploading = false } }
        let snapshot: URL
        do { snapshot = try Self.snapshot(of: entry.local) } catch { return failed(error.localizedDescription) }
        defer { try? FileManager.default.removeItem(at: snapshot) }
        guard Self.stamp(entry.local) == before else {
            look(id)
            return .unstable
        }
        guard let digest = Self.digest(of: snapshot) else { return failed("Could not read \(entry.name)") }
        do {
            let print = try await server.liveSave(snapshot, to: entry.path, expecting: expecting) { [entry] progress in
                server.liveEmit(.operation(Self.operation(entry, state: .active, progress: progress)))
            }
            guard let saved = update(id, {
                $0.state.base = print
                $0.state.synced = before
                $0.state.syncedDigest = digest
                $0.state.dirty = Self.stamp($0.local) != before
                $0.attempts = 0
            }) else { return .done }
            // Paused during this upload: it finished, but the file stays paused, and says so.
            report(saved, saved.state.paused ? .paused : .succeeded)
            emit(saved, .liveChanged)
            if let parent = saved.path.parent { emit(saved, .directoryChanged(parent)) }
            if saved.state.dirty { look(id) }
            return .done
        } catch is LiveRemoteChanged {
            return .serverChanged
        } catch {
            if RetryPolicy.isRetryable(error) || (error as? TransferError) == .notConnected { return .retry(error.localizedDescription) }
            return failed(error.localizedDescription)
        }
    }

    /// Writes the "(server)" copy first, then marks the conflict and announces it together.
    private func raiseConflict(_ id: LiveFileID, kind: LiveConflictKind, item: RemoteItem?) async {
        guard let entry = entries[id] else { return }
        if case .changed = kind, let item, let server = liveServer(for: entry.connection) {
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
        var comparable = false
        if case .changed = kind {
            let hasCopy = FileManager.default.fileExists(atPath: conflicted.serverCopy.path)
            comparable = FileManager.default.isExecutableFile(atPath: "/usr/bin/opendiff")
                && Self.isUTF8(conflicted.local) && (!hasCopy || Self.isUTF8(conflicted.serverCopy))
        }
        report(conflicted, .failed, message)
        emit(conflicted, .conflict(conflicted.path, comparable: comparable))
        emit(conflicted, .liveChanged)
    }

    // MARK: Commands

    private func openNow(_ path: RemotePath, on connection: ConnectionID) async throws -> URL {
        guard ready.contains(connection), let server = liveServer(for: connection) else { throw TransferError.notConnected }
        guard let item = try await server.liveLookup(path) else { throw TransferError.noSuchFile(path.display) }
        guard item.kind == .file, let print = Fingerprint(item: item) else { throw TransferError.typeMismatch(path.display) }
        if let id = find(path, on: connection), let entry = entries[id] {
            if let stamp = Self.stamp(entry.local) {
                let decide = { (digest: String?) in LiveDecision.decide(entry.state, local: .present(stamp, digest: digest), server: .file(print), intent: .open) }
                var action = decide(nil)
                if action == .needDigest { action = decide(Self.digest(of: entry.local)) }
                if case .refreshLocal = action {
                    // Download beside the copy and swap only if no editor saved it meanwhile.
                    let fresh = entry.folder.appendingPathComponent(".\(entry.name).transfer-refresh")
                    defer { try? FileManager.default.removeItem(at: fresh) }
                    try await server.liveFetch(item, to: fresh, interactive: true)
                    if Self.stamp(entry.local) == stamp, Darwin.rename(fresh.path, entry.local.path) == 0 {
                        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: entry.local.path)
                        adopt(id, server: print)
                        if let refreshed = entries[id] { emit(refreshed, .liveChanged) }
                    } else {
                        look(id)
                    }
                } else if Self.localChange(entry.state, entry.local, stamp) == .changed {
                    look(id)
                }
                return entry.local
            }
            forget(id)
        }
        let id = LiveFileID()
        let folder = root.appendingPathComponent("\(connection.rawValue.uuidString)/\(id.rawValue.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let file = folder.appendingPathComponent(item.name)
        do {
            try await server.liveFetch(item, to: file, interactive: true)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        entries[id] = Entry(id: id, connection: connection, path: path, local: file, state: LiveState(base: print))
        adopt(id, server: print)
        server.liveEmit(.liveChanged)
        return file
    }

    /// The working copy now holds the server's `print`: record it as synced.
    private func adopt(_ id: LiveFileID, server print: Fingerprint) {
        update(id) {
            $0.state.base = print
            $0.state.synced = Self.stamp($0.local)
            $0.state.syncedDigest = Self.digest(of: $0.local)
            $0.state.dirty = false
            $0.state.conflict = false
            $0.conflict = nil
            $0.missingSeen = false
        }
    }

    private func resolveNow(_ path: RemotePath, on connection: ConnectionID, choice: LiveConflictChoice) async throws {
        guard let id = find(path, on: connection), let entry = entries[id] else { throw TransferError.noSuchFile(path.display) }
        guard ready.contains(connection), let server = liveServer(for: connection) else { throw TransferError.notConnected }
        switch choice {
        case .compare: return
        case .keepLocal:
            // Expect the server file seen when the conflict was raised, so a later edit there is not overwritten.
            let expecting: ServerExpectation = switch entry.conflict {
            case .changed(let print): .file(print)
            case .removed: .absent
            case .notAFile: throw TransferError.typeMismatch(path.display)
            case nil: entry.state.base.map(ServerExpectation.file) ?? .absent
            }
            switch await save(id, expecting: expecting, via: server) {
            case .done:
                update(id) {
                    $0.conflict = nil
                    $0.state.conflict = false
                }
            case .serverChanged:
                // Changed again since the conflict was raised: show the new server copy instead.
                if let (item, fact) = await lookup(id), let kind = Self.conflictKind(fact) {
                    try? FileManager.default.removeItem(at: entry.serverCopy)
                    await raiseConflict(id, kind: kind, item: item)
                }
                throw TransferError.failed("\(entry.name) changed on the server again")
            case .unstable: throw TransferError.failed("\(entry.name) is still being written")
            case .retry(let reason): throw TransferError.failed(reason)
            case .failed: throw TransferError.failed("Could not upload \(entry.name)")
            }
        case .keepRemote: try await takeServerCopy(id, via: server)
        case .keepBoth:
            let parent = entry.path.parent ?? RemotePath(string: "/")
            let names = try await server.liveNames(in: parent)
            var n = 1
            var name: String { n == 1 ? "\(entry.name) (from this Mac)" : "\(entry.name) (from this Mac \(n))" }
            while names.contains(name) { n += 1 }
            let snapshot = try Self.snapshot(of: entry.local)
            defer { try? FileManager.default.removeItem(at: snapshot) }
            _ = try await server.liveSave(snapshot, to: parent.appending(name: Array(name.utf8)), expecting: .absent) { _ in }
            try await takeServerCopy(id, via: server)
        }
        guard let resolved = entries[id] else { return }
        try? FileManager.default.removeItem(at: resolved.serverCopy)
        report(resolved, .succeeded)
        emit(resolved, .liveChanged)
        if let parent = resolved.path.parent { emit(resolved, .directoryChanged(parent)) }
        if resolved.state.dirty { look(id) }
    }

    /// Keep Remote: the server's file replaces the working copy, or the mapping goes when there is none.
    private func takeServerCopy(_ id: LiveFileID, via server: any LiveServer) async throws {
        guard let entry = entries[id] else { return }
        guard let item = try await server.liveLookup(entry.path), item.kind == .file, let print = Fingerprint(item: item) else { return drop(entry) }
        try await server.liveFetch(item, to: entry.local, interactive: false)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: entry.local.path)
        adopt(id, server: print)
    }

    private func compare(_ path: RemotePath, on connection: ConnectionID) async throws {
        guard let id = find(path, on: connection), let entry = entries[id] else { throw TransferError.noSuchFile(path.display) }
        if !FileManager.default.fileExists(atPath: entry.serverCopy.path) {
            guard let server = liveServer(for: connection), let item = try await server.liveLookup(entry.path), item.kind == .file else { throw TransferError.noSuchFile(path.display) }
            try await server.liveFetch(item, to: entry.serverCopy, interactive: true)
        }
        try Process.run(URL(fileURLWithPath: "/usr/bin/opendiff"), arguments: [entry.local.path, entry.serverCopy.path])
    }

    private func discardNow(_ id: LiveFileID, force: Bool) throws {
        guard let entry = entries[id] else { return }
        if !force, entry.state.dirty { throw TransferError.liveUnsynced(1) }
        drop(entry)
    }

    private func moved(_ source: RemotePath, to destination: RemotePath, on connection: ConnectionID) {
        for entry in entries.values where entry.connection == connection {
            guard let path = entry.path.replacing(prefix: source, with: destination) else { continue }
            let local = entry.folder.appendingPathComponent(path.name)
            let renamed = local == entry.local || (try? FileManager.default.moveItem(at: entry.local, to: local)) != nil
            update(entry.id) {
                $0.path = path
                if renamed { $0.local = local }
            }
            emit(entry, .liveChanged)
        }
    }

    private func removed(_ path: RemotePath, on connection: ConnectionID) {
        for entry in entries.values where entry.connection == connection && entry.path.isInside(path) { drop(entry) }
    }

    // MARK: Records

    private func find(_ path: RemotePath, on connection: ConnectionID) -> LiveFileID? {
        entries.values.first { $0.connection == connection && $0.path == path }?.id
    }

    private func liveServer(for connection: ConnectionID) -> (any LiveServer)? {
        servers[connection]?.server
    }

    /// Changes a record and stores it. Nil, and no change, when it is gone.
    @discardableResult
    private func update(_ id: LiveFileID, _ body: (inout Entry) -> Void) -> Entry? {
        guard var entry = entries[id] else { return nil }
        body(&entry)
        entries[id] = entry
        store.saveLive(Self.row(entry))
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

    private static func conflictKind(_ fact: LiveServerFact) -> LiveConflictKind? {
        switch fact {
        case .file(let print): .changed(print)
        case .missing: .removed
        case .notFile: .notAFile
        case .notChecked, .unreachable: nil
        }
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
        return Fingerprint(kind: .file, size: size, mtime: mtime)
    }

    // MARK: Files

    /// Size and full-precision mtime, read through FileManager: `URL.resourceValues` caches.
    static func stamp(_ url: URL) -> LiveStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let mtime = attributes[.modificationDate] as? Date else { return nil }
        return LiveStamp(size: size, mtime: mtime)
    }

    /// How the working copy compares with the last sync, reading its bytes only when the stamp
    /// alone cannot tell. Unreadable bytes count as an edit, which the upload then reports.
    private static func localChange(_ state: LiveState, _ url: URL, _ stamp: LiveStamp) -> LiveLocalChange {
        let change = LiveDecision.localChange(state, stamp, digest: nil)
        return change == .needDigest ? LiveDecision.localChange(state, stamp, digest: digest(of: url) ?? "unreadable") : change
    }

    static func digest(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
