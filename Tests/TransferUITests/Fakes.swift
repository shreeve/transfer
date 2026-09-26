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
        loggedIn.value = true
        return home
    }

    func disconnect() async { loggedIn.value = false }

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
    func download(_ path: RemotePath, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        record("download \(path.display)")
    }
    func upload(_ source: URL, to destination: RemotePath, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {}
    func openKind(fileName: String) async -> OpenKind { .view }
    func prepareLiveFile(_ path: RemotePath) async throws -> URL { throw TransferError.notConnected }
    func prepareViewFile(_ path: RemotePath) async throws -> URL { throw TransferError.notConnected }
    func preparePreview(_ path: RemotePath) async throws -> URL { throw TransferError.notConnected }
    func prepareInspectorPreview(_ path: RemotePath) async throws -> URL { throw TransferError.notConnected }
    func clearPreviewCache() async {}
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
    func walkTree(_ root: RemotePath) -> AsyncThrowingStream<(TreeKey, TreeEntry), Error> { AsyncThrowingStream { $0.finish() } }
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
}

func files(_ count: Int, in folder: String) -> [RemotePath: [RemoteItem]] {
    let path = RemotePath(string: folder)
    return [path: (0..<count).map { RemoteItem(path: path.appending(name: Array("file-\($0).txt".utf8)), kind: .file, size: 10) }]
}

/// Waits, letting the main actor run, until `done` holds or about two seconds pass.
@MainActor
func eventually(_ done: () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if done() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return done()
}
