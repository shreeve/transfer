import Foundation
import TransferCore

/// The library and one `SSHConnection` per saved server, shared by every window and tab.
public actor TransferHub: SessionProvider {
    private let store: Store
    private var config: TransferConfig
    private var sessions: [ConnectionID: SSHConnection] = [:]
    /// Every Live file, for every server. One per app: a connection that is replaced keeps its
    /// files, and one watcher covers them all.
    private let live: LiveSync
    /// Held for the hub's life: one copy of Transfer per library. The launch sweeps, the temps,
    /// and the ssh control sockets all assume no other process is using this library.
    private let libraryLock: Int32

    /// `root` defaults to `TRANSFER_LIBRARY` (`LibraryOverride`) when that is set, else to
    /// `~/Library/Application Support/Transfer`. Throws when another copy of Transfer has the
    /// library open.
    public init(root: URL? = nil) throws {
        let root = root ?? LibraryOverride.root ?? Store.standardRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        libraryLock = try Self.lockLibrary(root)
        store = try Store(root: root)
        SSHConnection.removeLoginScratch(in: store.root)
        config = ConfigLoader.load(root: store.root)
        live = LiveSync(store: store)
        for temp in store.localTemps() {
            try? FileManager.default.removeItem(at: temp)
            store.forgetTemp(local: temp)
        }
    }

    deinit { close(libraryLock) }

    private static func lockLibrary(_ root: URL) throws -> Int32 {
        let fd = open(root.appendingPathComponent("transfer.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TransferError.failed("Transfer could not open its library at \(root.path)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw TransferError.failed("Another copy of Transfer is already open. Quit it, then open Transfer again.")
        }
        return fd
    }

    public func savedConnections() async throws -> [SavedConnection] {
        store.connections()
    }

    public func save(_ connection: SavedConnection) async throws {
        store.save(connection)
        // A session that is not logged in, perhaps mid-login with the old settings, is dropped and
        // stopped, so no orphaned master finishes that login.
        guard let existing = sessions[connection.id], !(await existing.isConnected), sessions[connection.id] === existing else { return }
        sessions[connection.id] = nil
        await existing.disconnect()
    }

    public func removeConnection(_ id: ConnectionID) async throws {
        // Live checks and closes in one call, and the folder goes before anything else awaits,
        // so no edit can land between the check and the removal.
        try await live.closeIfSynced(id)
        try? FileManager.default.removeItem(at: store.root.appendingPathComponent("Live/\(id.rawValue.uuidString)", isDirectory: true))
        let session = sessions.removeValue(forKey: id)
        await session?.disconnect()
        store.remove(id)
        KeychainStore.delete(account: id.rawValue.uuidString)
    }

    public func session(for id: ConnectionID) async throws -> any RemoteSession {
        try await sshSession(for: id)
    }

    public func transfer(_ request: TransferRequest, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let destination = try await sshSession(for: request.connection)
        var source: SSHConnection?
        if case .server(let id, _) = request.sources, id != request.connection { source = try await sshSession(for: id) }
        try await TransferEngine(request: request, destination: destination, progress: progress).run(from: source)
    }

    private func sshSession(for id: ConnectionID) async throws -> SSHConnection {
        guard let saved = store.connection(id) else { throw TransferError.noSuchFile("saved server") }
        guard let existing = sessions[id] else { return makeSession(saved) }
        if existing.connection == saved { return existing }
        let connected = await existing.isConnected
        // Another caller may have replaced it meanwhile; theirs is the one to share.
        if let current = sessions[id], current !== existing { return current }
        if connected { return existing }
        let session = makeSession(saved)
        await existing.disconnect()
        return session
    }

    private func makeSession(_ saved: SavedConnection) -> SSHConnection {
        let session = SSHConnection(connection: saved, store: store, editableExtensions: config.extensionSet, live: live)
        sessions[saved.id] = session
        return session
    }

    public func connection(matching link: SFTPURL) async -> SavedConnection? {
        let saved = store.connections()
        // An address in the link is compared with each server's resolved addresses; a name is not.
        let byAddress = SSHResolver.isAddress(link.host)
        let candidates = await withTaskGroup(of: SFTPURL.Match.Candidate?.self) { group in
            // Four `ssh -G` at a time, however many servers are saved.
            var pending = saved[...]
            func next() {
                guard let connection = pending.popFirst() else { return }
                group.addTask {
                    guard let output = await SSHResolver.config(for: connection),
                          var candidate = SFTPURL.Match.Candidate(connection: connection, sshConfigOutput: output) else { return nil }
                    if byAddress { candidate.addresses = await SSHResolver.addresses(of: candidate.hostName) }
                    return candidate
                }
            }
            for _ in 0..<4 { next() }
            var found: [SavedConnection.ID: SFTPURL.Match.Candidate] = [:]
            for await candidate in group {
                if let candidate { found[candidate.connection.id] = candidate }
                next()
            }
            // In library order, so the first saved server wins a tie.
            return saved.compactMap { found[$0.id] }
        }
        return SFTPURL.Match.best(link, among: candidates)
    }

    public var unsyncedLiveCount: Int { get async { await live.unsyncedCount() } }

    public func disconnectAll() async {
        await withTaskGroup(of: Void.self) { group in
            for session in sessions.values { group.addTask { await session.disconnect() } }
        }
    }

    public func editableExtensions() async -> [String] {
        config.editableExtensions
    }

    public func setEditableExtensions(_ extensions: [String]) async throws {
        let cleaned = extensions
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
        var seen: Set<String> = []
        config = TransferConfig(editableExtensions: cleaned.filter { seen.insert($0).inserted })
        try ConfigLoader.save(config, root: store.root)
        for session in sessions.values { await session.setEditableExtensions(config.extensionSet) }
    }
}
