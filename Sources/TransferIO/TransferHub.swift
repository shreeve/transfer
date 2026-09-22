import Foundation
import TransferCore

/// The library and one `SSHConnection` per saved server, shared by every window and tab.
public actor TransferHub: SessionProvider {
    private let store: Store
    private let editableExtensions: Set<String>
    private var sessions: [ConnectionID: SSHConnection] = [:]

    /// `root` defaults to `~/Library/Application Support/Transfer`.
    public init(root: URL? = nil) throws {
        store = try Store(root: root)
        editableExtensions = ConfigLoader.load(root: store.root).extensionSet
        for path in store.localTemps() {
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
            store.forgetTemp(path)
        }
    }

    public func savedConnections() async throws -> [SavedConnection] {
        store.connections()
    }

    public func save(_ connection: SavedConnection) async throws {
        store.save(connection)
        if let existing = sessions[connection.id], !(await existing.isConnected) {
            sessions[connection.id] = nil
        }
    }

    public func removeConnection(_ id: ConnectionID) async throws {
        let unsynced = store.dirtyLiveCount(connection: id)
        if unsynced > 0 { throw TransferError.liveUnsynced(unsynced) }
        await sessions[id]?.disconnect()
        sessions[id] = nil
        store.remove(id)
        KeychainStore.delete(account: id.rawValue.uuidString)
        let live = store.root.appendingPathComponent("Live/\(id.rawValue.uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: live)
    }

    public func session(for id: ConnectionID) async throws -> any RemoteSession {
        guard let saved = store.connection(id) else { throw TransferError.noSuchFile("saved server") }
        if let existing = sessions[id] {
            if await existing.isConnected || existing.connection == saved { return existing }
        }
        let session = SSHConnection(connection: saved, store: store, editableExtensions: editableExtensions)
        sessions[id] = session
        return session
    }

    public var unsyncedLiveCount: Int { store.dirtyLiveCount() }

    public func unsyncedLiveCount(for id: ConnectionID) async -> Int {
        store.dirtyLiveCount(connection: id)
    }

    public func disconnectAll() async {
        for session in sessions.values { await session.disconnect() }
    }
}
