import Foundation
import TransferCore
@testable import TransferUI

/// A server in memory: folders of items, a login that can hang until cancelled, and a record of
/// what the window asked of it.
final class FakeSession: RemoteSession, @unchecked Sendable {
    let connection: SavedConnection
    let home: RemotePath
    let folders: Locked<[RemotePath: [RemoteItem]]>
    /// How long a login takes: a long one waits until cancelled, as one at a password sheet does.
    let loginTime: Locked<Duration?>
    /// How long a listing takes before its items arrive.
    let listTime = Locked<Duration?>(nil)
    let connects = Locked(0)
    let loggedIn = Locked(false)
    let calls = Locked<[String]>([])
    let live = Locked<[LiveFile]>([])
    let starred = Locked<[RemotePath]>([])
    /// Discards refused as unsynced unless forced.
    let refusesDiscard = Locked(false)
    /// Asks for a password during login; no answer cancels it.
    let asksPassword = Locked(false)
    /// Extensions that open Live, so the inspector shows their text.
    let liveExtensions = Locked<Set<String>>([])
    /// The local copies the inspector gets, by remote path; any other path fails.
    let inspectorCopies = Locked<[RemotePath: URL]>([:])
    /// How long an inspector copy takes to arrive.
    let inspectorTime = Locked<Duration?>(nil)
    private let eventStream: AsyncStream<SessionEvent>
    let send: AsyncStream<SessionEvent>.Continuation

    init(_ connection: SavedConnection, home: String = "/home", folders: [RemotePath: [RemoteItem]] = [:], hangs: Bool = false) {
        self.connection = connection
        self.home = RemotePath(string: home)
        self.folders = Locked(folders)
        loginTime = Locked(hangs ? .seconds(60) : nil)
        (eventStream, send) = AsyncStream.makeStream()
    }

    func record(_ call: String) { calls.withLock { $0.append(call) } }

    var isConnected: Bool { get async { loggedIn.value } }

    func connect(prompts: any PromptSink) async throws -> RemotePath {
        connects.withLock { $0 += 1 }
        if let time = loginTime.value { try await Task.sleep(for: time) }
        if asksPassword.value, await prompts.answer(PromptRequest(text: "pw:", offerKeychain: false)).text == nil { throw CancellationError() }
        loggedIn.value = true
        return home
    }

    func list(_ path: RemotePath) -> AsyncThrowingStream<RemoteItem, Error> {
        let items = folders.value[path] ?? []
        let time = listTime.value
        return AsyncThrowingStream { continuation in
            Task {
                if let time { try? await Task.sleep(for: time) }
                for item in items { continuation.yield(item) }
                continuation.finish()
            }
        }
    }

    func item(_ path: RemotePath) throws -> RemoteItem {
        if folders.value[path] != nil || path == home { return RemoteItem(path: path, kind: .directory) }
        if let item = folders.value[path.parent ?? home]?.first(where: { $0.path == path }) { return item }
        throw TransferError.noSuchFile(path.display)
    }

    func stat(_ path: RemotePath) async throws -> RemoteItem { try item(path) }
    func readlink(_ path: RemotePath) async throws -> String { "" }
    func resolve(_ path: RemotePath) async throws -> RemoteItem { try item(path) }
    func mkdir(_ path: RemotePath) async throws { record("mkdir \(path.display)") }
    func rename(_ source: RemotePath, to destination: RemotePath) async throws {}
    func remove(_ path: RemotePath, force: Bool) async throws { record("remove \(path.display)") }
    /// Each download's progress callback, for a test to drive; a download then waits until
    /// `downloadsEnd`, which is true unless a test holds it.
    let downloadReports = Locked<[@Sendable (TransferProgress) -> Void]>([])
    let downloadsEnd = Locked(true)
    /// What `walkTree` yields under a folder, by its path.
    let trees = Locked<[RemotePath: [(TreeKey, TreeEntry)]]>([:])

    func download(_ path: RemotePath, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        record("download \(path.display)")
        downloadReports.withLock { $0.append(progress) }
        while !downloadsEnd.value { try await Task.sleep(for: .milliseconds(5)) }
    }
    func openKind(fileName: String) async -> OpenKind {
        EditableFile.openKind(fileName: fileName, extensions: liveExtensions.value) == .live && !liveExtensions.value.isEmpty ? .live : .view
    }
    func prepareLiveFile(_ path: RemotePath) async throws -> URL { throw TransferError.notConnected }
    func prepareViewFile(_ path: RemotePath) async throws -> URL { throw TransferError.notConnected }
    /// How long a Quick Look fetch takes; it never yields a copy, so no test opens the panel.
    let previewTime = Locked<Duration?>(nil)
    func preparePreview(_ path: RemotePath) async throws -> URL {
        record("preview \(path.display)")
        do { if let time = previewTime.value { try await Task.sleep(for: time) } } catch {
            record("preview cancelled \(path.display)")
            throw error
        }
        throw TransferError.notConnected
    }
    func prepareInspectorPreview(_ path: RemotePath) async throws -> URL {
        record("inspector \(path.display)")
        if let time = inspectorTime.value { try await Task.sleep(for: time) }
        guard let url = inspectorCopies.value[path] else { throw TransferError.notConnected }
        return url
    }
    func discardLiveFile(_ path: RemotePath, force: Bool) async throws {
        if refusesDiscard.value, !force { throw TransferError.liveUnsynced(1) }
        record("discard \(path.display)")
    }
    func setLivePaused(_ path: RemotePath, paused: Bool) async { record("paused \(paused) \(path.display)") }
    func liveFiles() async -> [LiveFile] { live.value }
    func events() -> AsyncStream<SessionEvent> { eventStream }
    func stars() async -> [RemotePath] { starred.value }
    func star(_ path: RemotePath, on: Bool) async {}
    func copy(_ source: RemotePath, to destination: RemotePath, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {}
    func walkTree(_ root: RemotePath) -> AsyncThrowingStream<(TreeKey, TreeEntry), Error> {
        let entries = [(TreeKey(bytes: []), TreeEntry.directory)] + (trees.value[root] ?? [])
        return AsyncThrowingStream { continuation in
            for entry in entries { continuation.yield(entry) }
            continuation.finish()
        }
    }
    func resolveLive(_ path: RemotePath, choice: LiveConflictChoice) async throws {}
    func terminalCommand(directory: RemotePath) async -> String? { nil }
}

/// A library of fake servers. `replace` swaps a server's session, as the hub does after an edit.
final class FakeProvider: SessionProvider, @unchecked Sendable {
    let sessions: Locked<[ConnectionID: FakeSession]>
    let saved: Locked<[SavedConnection]>

    init(_ sessions: [FakeSession]) {
        self.sessions = Locked(Dictionary(uniqueKeysWithValues: sessions.map { ($0.connection.id, $0) }))
        saved = Locked(sessions.map(\.connection))
    }

    func replace(_ session: FakeSession) {
        sessions.withLock { $0[session.connection.id] = session }
        saved.withLock { list in list = list.map { $0.id == session.connection.id ? session.connection : $0 } }
    }

    func savedConnections() async throws -> [SavedConnection] { saved.value }
    func save(_ connection: SavedConnection) async throws {}
    func removeConnection(_ id: ConnectionID) async throws {
        sessions.withLock { $0[id] = nil }
        saved.withLock { $0.removeAll { $0.id == id } }
    }
    func session(for id: ConnectionID) async throws -> any RemoteSession {
        guard let session = sessions.value[id] else { throw TransferError.noSuchFile("saved server") }
        return session
    }
    func connection(matching link: SFTPURL) async -> SavedConnection? { nil }
    var unsyncedLiveCount: Int { get async { 0 } }
    func disconnectAll() async {}
    let extensions = Locked(["md"])
    func editableExtensions() async -> [String] { extensions.value }
    func setEditableExtensions(_ extensions: [String]) async throws { self.extensions.value = extensions }
    func transfer(_ request: TransferRequest, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {}
    func clearPreviewCache() async {}

    // Live files across the library: every session's `live`, in library order.
    private let observers = Locked<[AsyncStream<Void>.Continuation]>([])

    /// Tells every window's Live badge that some session's `live` changed.
    func liveDidChange() {
        for observer in observers.value { observer.yield() }
    }

    func libraryLiveFiles() async -> [LibraryLiveFile] { libraryLive() }

    private func libraryLive() -> [LibraryLiveFile] {
        let sessions = sessions.value
        return saved.value.flatMap { connection in
            (sessions[connection.id]?.live.value ?? []).map { LibraryLiveFile(connection: connection.id, server: connection.displayName, file: $0) }
        }
    }

    func liveChanges() async -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers.withLock { $0.append(continuation) }
        return stream
    }

    /// As the hub: the batch's unsynced files come back, and nothing stops, unless all were warned.
    func stopLive(_ files: [LiveFileID], warned: Set<LiveFileID>) async -> [LibraryLiveFile] {
        let all = libraryLive()
        let batch = all.filter { files.contains($0.id) }
        let unsynced = batch.filter { !$0.file.isSynced }.map(\.id)
        if case .ask(let names) = LiveDecision.stopPlan(unsynced: unsynced, warned: warned) {
            return all.filter { names.contains($0.id) }
        }
        for file in batch {
            guard let session = sessions.value[file.connection] else { continue }
            session.live.withLock { $0.removeAll { $0.id == file.id } }
            session.record("stop \(file.file.path.display)")
        }
        liveDidChange()
        return []
    }
}

func files(_ count: Int, in folder: String) -> [RemotePath: [RemoteItem]] {
    let path = RemotePath(string: folder)
    return [path: (0..<count).map { RemoteItem(path: path.appending(name: Array("file-\($0).txt".utf8)), kind: .file, size: 10) }]
}

/// Waits, letting the main actor run, until `done` holds or about `seconds` pass.
@MainActor
func eventually(seconds: Int = 2, _ done: () -> Bool) async -> Bool {
    for _ in 0..<seconds * 200 {
        if done() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return done()
}

/// A clock for the inspector's choreography that moves only when the test says, so a step's
/// order and its boundary are checked exactly, however loaded the machine.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now
    private var sleepers: [UUID: (deadline: ContinuousClock.Instant, wake: CheckedContinuation<Void, any Error>)] = [:]

    var now: ContinuousClock.Instant { lock.withLock { current } }

    var clock: PreviewClock {
        PreviewClock(now: { self.now }, sleep: { try await self.sleep(until: $0) })
    }

    /// Moves time forward to `instant`, waking every sleeper due by then.
    func advance(to instant: ContinuousClock.Instant) {
        let due = lock.withLock {
            current = max(current, instant)
            let due = sleepers.filter { $0.value.deadline <= current }
            for id in due.keys { sleepers[id] = nil }
            return due.values.map(\.wake)
        }
        for wake in due { wake.resume() }
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (wake: CheckedContinuation<Void, any Error>) in
                let now: Bool = lock.withLock {
                    if deadline <= current || Task.isCancelled { return true }
                    sleepers[id] = (deadline, wake)
                    return false
                }
                if now { Task.isCancelled ? wake.resume(throwing: CancellationError()) : wake.resume() }
            }
        } onCancel: {
            lock.withLock { sleepers.removeValue(forKey: id)?.wake }?.resume(throwing: CancellationError())
        }
    }
}
