import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// One test's library and served folder against the local sshd that `Scripts/local-sshd.sh`
/// starts. Export what it prints (TRANSFER_TEST_PORT and TRANSFER_TEST_IDENTITY) to run the
/// server suites; without them they are skipped, and with TRANSFER_REQUIRE_SERVER=1 a missing
/// server fails every test instead.
///
/// Hermetic: ssh reads a config file written here (`-F`), never the developer's `~/.ssh/config`,
/// known hosts, or agent, and host keys are trusted once, so nothing under `~/.ssh` is written.
struct ServerHarness {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }
    private static var port: String? { environment["TRANSFER_TEST_PORT"] }
    private static var identity: String? { environment["TRANSFER_TEST_IDENTITY"] }

    /// Whether the server suites run: a server is configured, or one is required.
    static var available: Bool { (port != nil && identity != nil) || environment["TRANSFER_REQUIRE_SERVER"] == "1" }

    let session: SSHConnection
    /// The session's Live files, as the hub's one `LiveSync` in the app; closed by `cleanUp`.
    let live: LiveSync
    /// Holds the library, the served folder, and a staging folder; removed by `cleanUp`.
    let base: URL
    let root: URL
    let remote: URL
    let staging: URL
    let configFile: URL
    let prompts = TestPrompts()
    let events: EventRecorder
    private let logger: Task<Void, Never>

    var remotePath: RemotePath { RemotePath(string: remote.path) }

    init(_ name: String) throws {
        guard let port = Self.port, let identity = Self.identity else {
            throw TransferError.failed("TRANSFER_REQUIRE_SERVER is set, but TRANSFER_TEST_PORT and TRANSFER_TEST_IDENTITY are not: start Scripts/local-sshd.sh")
        }
        // Short on purpose: the control socket lives under this root and socket paths are capped at 104 bytes.
        base = TestCaches.fresh(name)
        root = base.appendingPathComponent("library", isDirectory: true)
        remote = base.appendingPathComponent("remote", isDirectory: true)
        staging = base.appendingPathComponent("staging", isDirectory: true)
        configFile = base.appendingPathComponent("ssh_config")
        let store: Store
        do {
            for folder in [root, remote, staging] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            let config = """
            Host *
              UserKnownHostsFile "\(base.appendingPathComponent("known_hosts").path)"
              GlobalKnownHostsFile /dev/null
              IdentityAgent none

            """
            try config.write(to: configFile, atomically: true, encoding: .utf8)
            store = try Store(root: root)
        } catch {
            try? FileManager.default.removeItem(at: base)
            throw error
        }
        let saved = SavedConnection(name: name, host: "127.0.0.1", user: NSUserName(), port: port, identityFile: identity, remotePath: remote.path)
        live = LiveSync(store: store)
        let session = SSHConnection(connection: saved, store: store, editableExtensions: TransferConfig.builtIn.extensionSet, live: live, sshConfigFile: configFile.path)
        let events = EventRecorder()
        let stream = session.events()
        self.session = session
        self.events = events
        logger = Task { for await event in stream { events.record(event) } }
    }

    /// Another connection to the same server on the same library, as after a relaunch: the first
    /// one's Live stops, and the second has its own. `body` always has it disconnected and its
    /// Live closed, when it throws too.
    func withSecondSession(_ body: (SSHConnection) async throws -> Void) async throws {
        await live.closeAll()
        let store = try Store(root: root)
        let liveAgain = LiveSync(store: store)
        let again = SSHConnection(connection: session.connection, store: store, editableExtensions: TransferConfig.builtIn.extensionSet, live: liveAgain, sshConfigFile: configFile.path)
        do {
            try await body(again)
        } catch {
            await again.disconnect()
            await liveAgain.closeAll()
            throw error
        }
        await again.disconnect()
        await liveAgain.closeAll()
    }

    /// Puts the local sshd's key in this harness's known_hosts, so a login is one connection to
    /// sshd where a first contact takes three (refused, probe, master); many suites at once would
    /// otherwise crowd its MaxStartups.
    func trustHostKey() throws {
        try "[127.0.0.1]:\(session.connection.port) \(try Self.hostKey())\n".write(to: base.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
    }

    /// The public host key `local-sshd.sh` keeps beside the client key.
    static func hostKeyFile() throws -> URL {
        guard let identity else { throw TransferError.failed("TRANSFER_TEST_IDENTITY is not set") }
        return URL(fileURLWithPath: identity).deletingLastPathComponent().appendingPathComponent("host_key.pub")
    }

    /// The local sshd's host key, as `type base64`.
    static func hostKey() throws -> String {
        try String(contentsOf: hostKeyFile(), encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
    }

    func cleanUp() async {
        logger.cancel()
        await session.disconnect()
        await live.closeAll()
        try? FileManager.default.removeItem(at: base)
    }
}

/// Runs `body` with a fresh harness, logged in first when `connected` (with the server's key
/// already known), and always awaits its cleanup, when it throws too. Its prompts answer for
/// every operation, as a window's do.
func withHarness(_ name: String, connected: Bool = false, _ body: (ServerHarness) async throws -> Void) async throws {
    let h = try ServerHarness(name)
    do {
        if connected {
            try h.trustHostKey()
            _ = try await h.session.connect(prompts: h.prompts)
        }
        try await OperationPrompts.$current.withValue(h.prompts) { try await body(h) }
    } catch {
        await h.cleanUp()
        throw error
    }
    await h.cleanUp()
}

/// Trusts host keys once unless told otherwise, answers no password, and replaces on every
/// collision, counting them.
final class TestPrompts: PromptSink {
    private let state = Locked((hostDecision: HostKeyDecision.trustOnce, collisions: 0))

    var hostDecision: HostKeyDecision {
        get { state.value.hostDecision }
        set { state.withLock { $0.hostDecision = newValue } }
    }

    var collisions: Int { state.value.collisions }

    func answer(_ request: PromptRequest) async -> PromptReply { PromptReply(text: nil) }
    func decideHostKey(_ event: HostKeyEvent) async -> HostKeyDecision { hostDecision }
    func resolveCollision(fileName: String) async -> NameCollisionChoice? {
        state.withLock { $0.collisions += 1 }
        return .replace
    }
}

/// Every event a session sent, in order.
final class EventRecorder: Sendable {
    private let events = Locked<[SessionEvent]>([])

    func record(_ event: SessionEvent) { events.withLock { $0.append(event) } }

    func conflicts(_ path: RemotePath) -> Int {
        events.value.filter { if case .conflict(let p, _) = $0 { p == path } else { false } }.count
    }

    /// Operations on the Live file at `path` that reached the shelf as succeeded.
    func succeeded(_ path: RemotePath) -> Int {
        events.value.filter { if case .operation(let op) = $0 { op.livePath == path && op.state == .succeeded } else { false } }.count
    }
}

/// Polls `condition` every 50 ms until it holds or `seconds` pass.
func waitUntil(_ seconds: Double = 8, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return await condition()
}
