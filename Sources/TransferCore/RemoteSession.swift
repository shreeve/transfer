import Foundation

public enum TransferError: Error, Equatable, Sendable, LocalizedError {
    case notConnected
    case cancelled
    case hostKeyRejected
    case authenticationFailed(String)
    case permissionDenied(String)
    case noSuchFile(String)
    case failed(String)
    case typeMismatch(String)
    case connectionLost(String)
    case timeout(String)
    case liveUnsynced(Int)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected"
        case .cancelled: "Cancelled"
        case .hostKeyRejected: "The host key was not trusted"
        case .authenticationFailed(let text): text.isEmpty ? "Login failed" : text
        case .permissionDenied(let text): "Permission denied: \(text)"
        case .noSuchFile(let text): "No such file: \(text)"
        case .failed(let text): text
        case .typeMismatch(let text): "A file and a folder share the name \(text)"
        case .connectionLost(let text): "Connection lost: \(text)"
        case .timeout(let text): "Timed out: \(text)"
        case .liveUnsynced(let count): "\(count) Live file\(count == 1 ? " has" : "s have") unsynced edits"
        }
    }
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
    /// Nil when nobody can answer, as when the window has closed: the operation then fails
    /// rather than guess.
    func resolveCollision(fileName: String) async -> NameCollisionChoice?
}

/// Who answers the questions one user operation raises, such as what to do with a file that
/// already has the name. A session belongs to every window on its server, so the sink given to
/// `connect` answers only login prompts (passwords and host keys); an operation's prompts go to
/// the window that started it. The UI runs each operation's body, retries included, inside
/// `OperationPrompts.$current.withValue(sink) { … }`, and child tasks inherit it. An operation that
/// meets an existing file with no sink bound fails with a clear error: nothing is replaced or
/// skipped without someone having said so.
public enum OperationPrompts {
    @TaskLocal public static var current: (any PromptSink)?
}

public struct TransferOperation: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var state: OperationState
    public var progress: TransferProgress
    public var message: String?
    /// The remote item the operation moves, for rows and the inspector to match on.
    public var path: RemotePath?
    public var livePath: RemotePath?

    public init(
        id: String,
        title: String,
        state: OperationState,
        progress: TransferProgress = TransferProgress(completed: 0),
        message: String? = nil,
        path: RemotePath? = nil,
        livePath: RemotePath? = nil
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.progress = progress
        self.message = message
        self.path = path
        self.livePath = livePath
    }
}

public struct LiveFile: Hashable, Sendable, Identifiable {
    public var id: LiveFileID
    public var path: RemotePath
    public var dirty: Bool
    public var paused: Bool
    public var conflict: Bool
    public var uploading: Bool

    public init(id: LiveFileID, path: RemotePath, dirty: Bool, paused: Bool, conflict: Bool, uploading: Bool) {
        self.id = id
        self.path = path
        self.dirty = dirty
        self.paused = paused
        self.conflict = conflict
        self.uploading = uploading
    }
}

/// The library: saved servers and one session per saved server.
public protocol SessionProvider: Sendable {
    func savedConnections() async throws -> [SavedConnection]
    func save(_ connection: SavedConnection) async throws
    /// Refuses with `TransferError.liveUnsynced` while the connection has unsynced Live bytes.
    func removeConnection(_ id: ConnectionID) async throws
    func session(for id: ConnectionID) async throws -> any RemoteSession
    /// The saved server an `sftp://` link means, or nil when none does.
    func connection(matching link: SFTPURL) async -> SavedConnection?
    var unsyncedLiveCount: Int { get async }
    func disconnectAll() async
    /// The extensions that open Live, from the user's config file.
    func editableExtensions() async -> [String]
    /// Rewrites the config file. Open sessions pick the list up at once.
    func setEditableExtensions(_ extensions: [String]) async throws
}

/// One saved server. Views reach the server only through this protocol.
public protocol RemoteSession: Sendable {
    var connection: SavedConnection { get }
    var isConnected: Bool { get async }
    /// Logs in, or returns the start path at once when already logged in.
    func connect(prompts: any PromptSink) async throws -> RemotePath
    func disconnect() async
    func list(_ path: RemotePath) -> AsyncThrowingStream<RemoteItem, Error>
    func stat(_ path: RemotePath) async throws -> RemoteItem
    func readlink(_ path: RemotePath) async throws -> String
    func mkdir(_ path: RemotePath) async throws
    func rename(_ source: RemotePath, to destination: RemotePath) async throws
    func remove(_ path: RemotePath) async throws
    func download(_ path: RemotePath, to destination: URL, progress: @escaping @Sendable (TransferProgress) -> Void) async throws
    func upload(_ source: URL, to destination: RemotePath, progress: @escaping @Sendable (TransferProgress) -> Void) async throws
    func openKind(fileName: String) async -> OpenKind
    func prepareLiveFile(_ path: RemotePath) async throws -> URL
    func prepareViewFile(_ path: RemotePath) async throws -> URL
    func preparePreview(_ path: RemotePath) async throws -> URL
    func clearPreviewCache() async
    func discardLiveFile(_ path: RemotePath, force: Bool) async throws
    func setLivePaused(_ path: RemotePath, paused: Bool) async
    func liveFiles() async -> [LiveFile]
    func events() -> AsyncStream<SessionEvent>
    func stars() async -> [RemotePath]
    func star(_ path: RemotePath) async
    func unstar(_ path: RemotePath) async
    func duplicate(_ path: RemotePath) async throws
    /// Copies a file, link, or folder tree to `destination` on this same server. Files are copied
    /// on the server when it offers `copy-data`, else through the Mac. Folders merge into an
    /// existing folder and file collisions are settled as uploads settle them.
    func copy(_ source: RemotePath, to destination: RemotePath, progress: @escaping @Sendable (TransferProgress) -> Void) async throws
    /// Walks `root` on the walker channel and streams every entry, the root first under the
    /// empty key, the rest by their path relative to it.
    func walkTree(_ root: RemotePath) -> AsyncThrowingStream<(String, TreeEntry), Error>
    /// `.compare` opens the diff tool itself and returns nil.
    func resolveLive(_ path: RemotePath, choice: LiveConflictChoice) async throws
    /// A shell command that joins the same SSH master and starts a login shell in `directory`.
    func terminalCommand(directory: RemotePath) async -> String?
}

public enum SessionEvent: Sendable {
    case operation(TransferOperation)
    case notice(String)
    case conflict(RemotePath, comparable: Bool)
    case liveChanged
    case directoryChanged(RemotePath)
    case disconnected(String)
}

public extension RemoteSession {
    /// The whole tree `walkTree` streams, by key.
    func tree(_ root: RemotePath) async throws -> [String: TreeEntry] {
        var entries: [String: TreeEntry] = [:]
        for try await (key, entry) in walkTree(root) { entries[key] = entry }
        return entries
    }
}
