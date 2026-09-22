import Foundation

public enum TransferError: Error, Equatable, Sendable {
    case notConnected
    case cancelled
    case hostKeyRejected
    case authenticationFailed(String)
    case permissionDenied(String)
    case noSuchFile(String)
    case failed(String)
    case typeMismatch(String)
    case performanceUnavailable
}

public struct PromptRequest: Sendable {
    public var text: String
    public var offerKeychain: Bool
    public init(text: String, offerKeychain: Bool) {
        self.text = text
        self.offerKeychain = offerKeychain
    }
}

public struct PromptReply: Sendable {
    public var text: String?
    public var saveInKeychain: Bool
    public init(text: String?, saveInKeychain: Bool = false) {
        self.text = text
        self.saveInKeychain = saveInKeychain
    }
}

public protocol PromptSink: Sendable {
    func answer(_ request: PromptRequest) async -> PromptReply
    func decideHostKey(_ event: HostKeyEvent) async -> HostKeyDecision
    func resolveCollision(fileName: String) async -> NameCollisionChoice
}

public struct TransferOperation: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var state: OperationState
    public var progress: TransferProgress
    public var message: String?

    public init(id: String, title: String, state: OperationState, progress: TransferProgress = TransferProgress(completed: 0), message: String? = nil) {
        self.id = id
        self.title = title
        self.state = state
        self.progress = progress
        self.message = message
    }
}

public protocol RemoteSession: Sendable {
    func savedConnections() async throws -> [SavedConnection]
    func save(_ connection: SavedConnection) async throws
    func removeConnection(_ id: ConnectionID) async throws
    func connect(_ connection: SavedConnection, prompts: any PromptSink) async throws -> RemotePath
    func disconnect() async
    var performanceModeEnabled: Bool { get async }
    func list(_ path: RemotePath) -> AsyncThrowingStream<RemoteItem, Error>
    func stat(_ path: RemotePath) async throws -> RemoteItem
    func readlink(_ path: RemotePath) async throws -> String
    func mkdir(_ path: RemotePath) async throws
    func rename(_ source: RemotePath, to destination: RemotePath) async throws
    func remove(_ path: RemotePath) async throws
    func download(_ path: RemotePath, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws
    func upload(_ source: URL, to destination: RemotePath, progress: @escaping @Sendable (TransferProgress) -> Void) async throws
    func copyDirectory(from remote: RemotePath, to local: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws
    func copyDirectory(fromLocal local: URL, to remote: RemotePath, progress: @escaping @Sendable (TransferProgress) -> Void) async throws
    func openKind(fileName: String) async -> OpenKind
    func prepareLiveFile(_ path: RemotePath) async throws -> URL
    func prepareViewFile(_ path: RemotePath) async throws -> URL
    func preparePreview(_ path: RemotePath) async throws -> URL
    func discardLiveFile(_ path: RemotePath, force: Bool) async throws
    var livePaths: Set<RemotePath> { get async }
    func events() -> AsyncStream<SessionEvent>
    func recents() async -> [RemotePath]
    func remember(_ path: RemotePath) async
    func pins() async -> [RemotePath]
    func pin(_ path: RemotePath) async
    func unpin(_ path: RemotePath) async
    func duplicate(_ path: RemotePath) async throws
    func resolveLive(_ path: RemotePath, choice: LiveConflictChoice) async throws -> URL?
    var unsyncedLiveCount: Int { get async }
}

public enum SessionEvent: Sendable {
    case operation(TransferOperation)
    case notice(String)
    case conflict(RemotePath)
}

public extension RemoteSession {
    func performanceFlag() async -> Bool { await performanceModeEnabled }
}
