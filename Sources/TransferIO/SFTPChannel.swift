import Foundation
import TransferCore

/// One SFTP channel: an `ssh -s … sftp` passenger, or a test's pipes, spoken to with the codec in
/// SFTPWire. Every request, reply, and file transfer on a channel goes through this actor. What
/// the server sends is untrusted: malformed frames, a silent server, and names that are not one
/// path component end here (see `readLoop`, `watch`, `readDirectory`).
actor SFTPChannel {
    /// The ssh passenger, ended on close. Nil for a channel a test drives over its own pipes.
    private let process: Process?
    private let input: FileHandle
    /// Packets are written on this queue, not in the actor: uploads keep 2 MB in flight and ssh's
    /// stdin pipe holds 64 KB, and a blocked write(2) would hold the actor, its reader included,
    /// for as long as the server does not read, which for a hung server is forever.
    private let writer = DispatchQueue(label: "SFTPChannel.writer", qos: .userInitiated)
    private let chunks: AsyncStream<Data>
    private let chunkSink: AsyncStream<Data>.Continuation
    private var buffer = Data()
    private var nextID: UInt32 = 1
    private var waiters: [UInt32: CheckedContinuation<SFTPMessage, Error>] = [:]
    private var versionWaiter: CheckedContinuation<UInt32, Error>?
    /// Whether the server's VERSION has arrived. Anything else before it is not SFTP.
    private var greeted = false
    /// The extensions the server named in its VERSION reply, such as `copy-data`.
    private(set) var extensions: Set<String> = []
    private var reader: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private(set) var isOpen = true

    /// A server that answers nothing for this long while requests wait has hung; the channel
    /// closes and its requests fail with a timeout, which a transfer retries on a new channel.
    /// Replies arrive every 64 KB during a transfer, so only a dead server is this quiet.
    private let stallLimit: Duration
    /// How long the server has to answer INIT.
    private let handshakeLimit: Duration
    private var lastHeard = ContinuousClock.now
    private var handshakeStarted: ContinuousClock.Instant?
    /// Requests the server may rightly take minutes over, such as `copy-data`, which answers when
    /// the whole file is written. While one waits, silence is not a stall.
    private var longCalls = 0

    init(
        process: Process?,
        input: FileHandle,
        output: FileHandle,
        stallLimit: Duration = .seconds(60),
        handshakeLimit: Duration = .seconds(15)
    ) {
        self.process = process
        self.input = input
        self.stallLimit = stallLimit
        self.handshakeLimit = handshakeLimit
        // A write after the server has gone fails with EPIPE, which closes the channel; the default
        // SIGPIPE would end the whole app first.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        let (chunks, sink) = AsyncStream<Data>.makeStream()
        self.chunks = chunks
        chunkSink = sink
        output.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                // At end of file the handler would otherwise keep firing with nothing to read.
                handle.readabilityHandler = nil
                sink.finish()
            } else {
                sink.yield(data)
            }
        }
    }

    func start() {
        reader = Task { await self.readLoop() }
        watchdog = Task { await self.watch() }
    }

    /// Sends INIT and waits for VERSION, for at most `handshakeLimit`. Cancelling it closes the
    /// channel.
    func handshake() async throws {
        handshakeStarted = .now
        send(SFTPWire.packet(type: SFTPCode.initialize) { $0.appendU32(3) })
        let version: UInt32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if isOpen {
                    versionWaiter = continuation
                } else {
                    continuation.resume(throwing: TransferError.connectionLost("SSH channel closed"))
                }
            }
        } onCancel: {
            Task { await self.shutDown(.cancelled) }
        }
        if version < 3 {
            throw TransferError.failed("Server SFTP version \(version) is too old")
        }
    }

    func realpath(_ path: RemotePath) async throws -> RemotePath {
        let message = try await call(SFTPCode.realpath) { $0.appendPath(path) }
        let names = try names(in: message)
        guard let first = names.first else { throw TransferError.failed("Empty realpath") }
        return RemotePath(bytes: Array(first.filename))
    }

    func lstat(_ path: RemotePath) async throws -> RemoteItem {
        let message = try await call(SFTPCode.lstat) { $0.appendPath(path) }
        return try item(path: path, message: message)
    }

    /// Keeps several READDIR requests in flight. OpenSSH answers each with about a hundred names,
    /// so a large folder no longer pays one round trip per page. A listing its reader abandons
    /// stops at once and still closes its handle on the server.
    func list(_ path: RemotePath) -> AsyncThrowingStream<RemoteItem, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let handle = try await openDirectory(path)
                    var inFlight: [Task<[RemoteItem]?, Error>] = []
                    defer {
                        for page in inFlight { page.cancel() }
                        closeLater(handle)
                    }
                    var finished = false
                    while !finished || !inFlight.isEmpty {
                        while !finished, inFlight.count < 4 {
                            inFlight.append(Task { try await self.readDirectoryPage(handle, parent: path) })
                        }
                        let next = inFlight.removeFirst()
                        let page = try await withTaskCancellationHandler {
                            try await next.value
                        } onCancel: {
                            next.cancel()
                        }
                        guard let page, !page.isEmpty else {
                            finished = true
                            continue
                        }
                        for item in page { continuation.yield(item) }
                        try Task.checkCancellation()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One page, or nil at the end of the directory.
    private func readDirectoryPage(_ handle: Data, parent: RemotePath) async throws -> [RemoteItem]? {
        do {
            return try await readDirectory(handle, parent: parent)
        } catch is EndOfFile {
            return nil
        }
    }

    func mkdir(_ path: RemotePath) async throws {
        _ = try await call(SFTPCode.mkdir) {
            $0.appendPath(path)
            $0.append(SFTPAttrs().encoded())
        }
    }

    /// A rename or move the user asked for. It never replaces what is already at `destination`:
    /// `posix-rename` would, and plain RENAME refuses a file there but on OpenSSH replaces an empty
    /// folder, so the destination is looked up first. A change of case alone within one folder
    /// needs `posix-rename` on a case-insensitive disk, where the lookup finds the source itself;
    /// the folder's listing tells that apart from a second file on a case-sensitive disk.
    func rename(_ source: RemotePath, to destination: RemotePath) async throws {
        let taken: Bool
        do {
            _ = try await lstat(destination)
            taken = true
        } catch TransferError.noSuchFile {
            taken = false
        }
        if taken {
            let caseOnly = source.parent == destination.parent && source != destination
                && source.name.lowercased() == destination.name.lowercased()
            guard caseOnly, let folder = destination.parent, try await !hasEntry(named: destination.name, in: folder) else {
                throw TransferError.failed("“\(destination.name)” already exists there")
            }
            if (try? await posixRename(source, to: destination)) != nil { return }
        }
        try await plainRename(source, to: destination)
    }

    /// Whether `folder` lists an entry named `name`. Strings compare as Unicode does, so a name
    /// that differs only in normalization counts, as it does on APFS.
    private func hasEntry(named name: String, in folder: RemotePath) async throws -> Bool {
        for try await item in list(folder) where item.name == name { return true }
        return false
    }

    /// `posix-rename@openssh.com`, which replaces the destination.
    private func posixRename(_ source: RemotePath, to destination: RemotePath) async throws {
        _ = try await call(SFTPCode.extended) {
            $0.appendString("posix-rename@openssh.com")
            $0.appendPath(source)
            $0.appendPath(destination)
        }
    }

    /// Puts `temp` in place of `placed`. With `posix-rename@openssh.com` the swap is atomic and a
    /// failure leaves `placed` untouched. Without it, SFTP v3 rename will not replace a file, so
    /// `placed` steps aside under a hidden name first and comes back if `temp` cannot take its
    /// place: a failure never leaves the server with neither the old file nor the new one. A
    /// folder is never replaced, as posix-rename would refuse it.
    func replace(_ temp: RemotePath, onto placed: RemotePath) async throws {
        if extensions.contains("posix-rename@openssh.com") {
            try await posixRename(temp, to: placed)
            return
        }
        // Once the old file has stepped aside, cancelling must not stop it coming back: the steps
        // run in a task of their own, which the caller's cancellation does not reach.
        try await Task { try await self.replaceStepping(temp, onto: placed) }.value
    }

    private func replaceStepping(_ temp: RemotePath, onto placed: RemotePath) async throws {
        let existing: RemoteItem
        do {
            existing = try await lstat(placed)
        } catch TransferError.noSuchFile {
            try await plainRename(temp, to: placed)
            return
        }
        guard existing.kind != .directory, let folder = placed.parent else { throw TransferError.typeMismatch(placed.name) }
        // Short, so a long name cannot push it past the server's name limit.
        let aside = folder.appending(name: Array(".transfer-old-\(UUID().uuidString)".utf8))
        try await plainRename(placed, to: aside)
        do {
            try await plainRename(temp, to: placed)
        } catch {
            try? await plainRename(aside, to: placed)
            throw error
        }
        try? await removeFile(aside)
    }

    /// SSH_FXP_RENAME, which on OpenSSH never replaces a file but does replace an empty folder.
    private func plainRename(_ source: RemotePath, to destination: RemotePath) async throws {
        _ = try await call(SFTPCode.rename) {
            $0.appendPath(source)
            $0.appendPath(destination)
        }
    }

    func removeFile(_ path: RemotePath) async throws {
        _ = try await call(SFTPCode.remove) { $0.appendPath(path) }
    }

    func removeDirectory(_ path: RemotePath) async throws {
        _ = try await call(SFTPCode.rmdir) { $0.appendPath(path) }
    }

    func readlink(_ path: RemotePath) async throws -> String {
        let message = try await call(SFTPCode.readlink) { $0.appendPath(path) }
        let names = try names(in: message)
        guard let first = names.first else { throw TransferError.failed("Empty readlink") }
        return String(decoding: first.filename, as: UTF8.self)
    }

    /// OpenSSH's sftp-server reads SYMLINK as (target, link), the reverse of the draft. Every
    /// version-3 server in use follows OpenSSH here.
    func symlink(target: String, link: RemotePath) async throws {
        _ = try await call(SFTPCode.symlink) {
            $0.appendString(target)
            $0.appendPath(link)
        }
    }

    /// Copies a file on the server with OpenSSH's `copy-data` extension; no bytes cross the
    /// network. The reply comes when the whole file is written. Callers check `extensions` first.
    func copyData(_ source: RemotePath, to destination: RemotePath) async throws {
        let from = try await openFile(source, flags: SFTPCode.fxRead)
        defer { closeLater(from) }
        let to = try await openFile(destination, flags: SFTPCode.fxWrite | SFTPCode.fxCreat | SFTPCode.fxTrunc)
        do {
            _ = try await call(SFTPCode.extended, long: true) {
                $0.appendString("copy-data")
                $0.appendBlob(from)
                $0.appendU64(0)
                // A length of zero copies to the end of the file.
                $0.appendU64(0)
                $0.appendBlob(to)
                $0.appendU64(0)
            }
        } catch {
            closeLater(to)
            throw error
        }
        // Closing the written file can report a failed last write, so this CLOSE is awaited.
        try await close(to)
    }

    func setstat(_ path: RemotePath, mode: UInt32?, mtime: UInt32?) async throws {
        var attrs = SFTPAttrs()
        attrs.permissions = mode
        if let mtime {
            attrs.atime = mtime
            attrs.mtime = mtime
        }
        _ = try await call(SFTPCode.setstat) {
            $0.appendPath(path)
            $0.append(attrs.encoded())
        }
    }

    func download(
        _ path: RemotePath,
        to destination: URL,
        size: UInt64?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let handle = try await openFile(path, flags: SFTPCode.fxRead)
        defer { closeLater(handle) }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        guard let limit = size else {
            try await downloadSequential(handle: handle, output: output, progress: progress)
            return
        }
        // 32 requests of 64 KB keep 2 MB in flight.
        var plan = ReadPlan(size: limit)
        var inFlight: [(offset: UInt64, length: UInt32, task: Task<Data, Error>)] = []
        defer { for read in inFlight { read.task.cancel() } }
        while true {
            try Task.checkCancellation()
            while inFlight.count < 32, let request = plan.nextRequest() {
                let task = Task { try await self.readChunk(handle, offset: request.offset, length: request.length) }
                inFlight.append((request.offset, request.length, task))
            }
            guard !inFlight.isEmpty else { break }
            let read = inFlight.removeFirst()
            do {
                let chunk = try await read.task.value
                guard chunk.count <= Int(read.length) else { throw TransferError.failed("The server sent more than was asked for") }
                if !chunk.isEmpty {
                    try output.seek(toOffset: read.offset)
                    try output.write(contentsOf: chunk)
                }
                plan.record(offset: read.offset, length: read.length, count: UInt32(chunk.count))
                progress(TransferProgress(completed: plan.received, total: limit))
            } catch is EndOfFile {
                plan.endOfFile()
            }
        }
        guard plan.isComplete else { throw TransferError.failed("The file changed on the server while it downloaded") }
    }

    /// For a file with no listed size: reads in order until the server says EOF. A short reply
    /// is not the end; only EOF or a reply with no bytes is.
    private func downloadSequential(handle: Data, output: FileHandle, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        var offset: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let chunk: Data
            do {
                chunk = try await readChunk(handle, offset: offset, length: 65_536)
            } catch is EndOfFile {
                break
            }
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            offset += UInt64(chunk.count)
            progress(TransferProgress(completed: offset))
        }
    }

    private func readChunk(_ handle: Data, offset: UInt64, length: UInt32) async throws -> Data {
        let message = try await call(SFTPCode.read) {
            $0.appendBlob(handle)
            $0.appendU64(offset)
            $0.appendU32(length)
        }
        guard message.type == SFTPCode.data else { throw TransferError.failed("Expected data") }
        var reader = ByteReader(message.rest)
        return try reader.blob()
    }

    /// Keeps 2 MB of WRITE requests in flight, 64 KB each, all writes on this channel.
    func upload(
        _ source: URL,
        to path: RemotePath,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let handle = try await openFile(path, flags: SFTPCode.fxWrite | SFTPCode.fxCreat | SFTPCode.fxTrunc)
        defer { closeLater(handle) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let total = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init)
        var offset: UInt64 = 0
        var acknowledged: UInt64 = 0
        var inFlight: [Task<UInt64, Error>] = []
        do {
            while true {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: 65_536) ?? Data()
                if chunk.isEmpty { break }
                let at = offset
                let count = UInt64(chunk.count)
                offset += count
                inFlight.append(Task {
                    try await self.writeChunk(handle, offset: at, data: chunk)
                    return count
                })
                if inFlight.count >= 32 {
                    acknowledged += try await inFlight.removeFirst().value
                    progress(TransferProgress(completed: acknowledged, total: total))
                }
            }
            while !inFlight.isEmpty {
                acknowledged += try await inFlight.removeFirst().value
                progress(TransferProgress(completed: acknowledged, total: total))
            }
        } catch {
            for task in inFlight { task.cancel() }
            throw error
        }
    }

    private func writeChunk(_ handle: Data, offset: UInt64, data: Data) async throws {
        _ = try await call(SFTPCode.write, capacity: data.count + 64) {
            $0.appendBlob(handle)
            $0.appendU64(offset)
            $0.appendBlob(data)
        }
    }

    func closeLink() {
        shutDown(.cancelled)
    }

    /// Closes the channel for good: ends ssh, and fails the handshake and every waiting request
    /// with `error`. Later calls fail as a closed channel.
    private func shutDown(_ error: TransferError) {
        guard isOpen else { return }
        isOpen = false
        process?.terminate()
        reader?.cancel()
        watchdog?.cancel()
        chunkSink.finish()
        versionWaiter?.resume(throwing: error)
        versionWaiter = nil
        for waiter in waiters.values { waiter.resume(throwing: error) }
        waiters.removeAll()
    }

    /// Ends a handshake past `handshakeLimit`, and a channel whose server has said nothing for
    /// `stallLimit` while requests wait.
    private func watch() async {
        while isOpen {
            try? await Task.sleep(for: (greeted ? stallLimit : min(stallLimit, handshakeLimit)) / 5)
            let now = ContinuousClock.now
            if versionWaiter != nil, let handshakeStarted, now - handshakeStarted > handshakeLimit {
                shutDown(.timeout("The server did not start SFTP"))
            } else if !waiters.isEmpty, longCalls == 0, now - lastHeard > stallLimit {
                shutDown(.timeout("The server stopped answering"))
            }
        }
    }

    private func openDirectory(_ path: RemotePath) async throws -> Data {
        let message = try await call(SFTPCode.opendir) { $0.appendPath(path) }
        return try handle(in: message)
    }

    /// One page of `parent`'s entries. A name the server sends is used as a path component, so
    /// anything that is not exactly one is dropped: `.` and `..`, an empty name, and a name with
    /// a slash or NUL, which a hostile server could send to reach outside the folder.
    private func readDirectory(_ handle: Data, parent: RemotePath) async throws -> [RemoteItem] {
        let message = try await call(SFTPCode.readdir) { $0.appendBlob(handle) }
        return try names(in: message).compactMap { name in
            guard Self.isSingleComponent(name.filename) else { return nil }
            return item(path: parent.appending(name: Array(name.filename)), attrs: name.attrs)
        }
    }

    static func isSingleComponent(_ name: Data) -> Bool {
        !name.isEmpty && name != Data([0x2E]) && name != Data([0x2E, 0x2E])
            && !name.contains(0x2F) && !name.contains(0)
    }

    private func openFile(_ path: RemotePath, flags: UInt32) async throws -> Data {
        let message = try await call(SFTPCode.open) {
            $0.appendPath(path)
            $0.appendU32(flags)
            $0.append(SFTPAttrs().encoded())
        }
        return try handle(in: message)
    }

    /// Closes `handle` in a task of its own, unawaited. Cleanup after a cancellation must still
    /// reach the server, and `call` refuses to start in a cancelled task.
    private nonisolated func closeLater(_ handle: Data) {
        Task { try? await self.close(handle) }
    }

    private func close(_ handle: Data) async throws {
        _ = try await call(SFTPCode.close) { $0.appendBlob(handle) }
    }

    /// Sends one request, its fields appended by `fields` after the id, and waits for the reply.
    /// A failure status throws; end of file throws `EndOfFile`. The waiter is registered in the
    /// same actor turn that sends the request, so no reply can arrive before it and a
    /// cancellation, which runs on the actor after it, always finds it or finds it answered.
    private func call(
        _ type: UInt8,
        capacity: Int = 64,
        long: Bool = false,
        _ fields: (inout Data) -> Void
    ) async throws -> SFTPMessage {
        try Task.checkCancellation()
        guard isOpen else { throw TransferError.connectionLost("SSH channel closed") }
        let id = nextID
        nextID &+= 1
        // An idle channel's silence was not a stall; the clock starts with the first request.
        if waiters.isEmpty { lastHeard = .now }
        send(SFTPWire.packet(type: type, capacity: capacity) { packet in
            packet.appendU32(id)
            fields(&packet)
        })
        if long { longCalls += 1 }
        defer { if long { longCalls -= 1 } }
        let message: SFTPMessage = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
        if message.type == SFTPCode.status {
            var reader = ByteReader(message.rest)
            let code = (try? reader.u32()) ?? SFTPCode.failure
            let text = (try? reader.utf8()) ?? "SFTP error \(code)"
            if code == SFTPCode.ok { return message }
            if code == SFTPCode.eof { throw EndOfFile() }
            if code == SFTPCode.noSuchFile { throw TransferError.noSuchFile(text) }
            if code == SFTPCode.permission { throw TransferError.permissionDenied(text) }
            throw TransferError.failed(text)
        }
        return message
    }

    /// The server's EOF status: the end of a directory or a file, not a failure.
    private struct EndOfFile: Error {}

    private func cancelRequest(_ id: UInt32) {
        waiters.removeValue(forKey: id)?.resume(throwing: TransferError.cancelled)
    }

    /// Queues `packet` for ssh's stdin, in order. A failed write means ssh is gone.
    private func send(_ packet: Data) {
        writer.async { [input] in
            do {
                try input.write(contentsOf: packet)
            } catch {
                Task { await self.shutDown(.connectionLost("Broken SSH channel")) }
            }
        }
    }

    private func readLoop() async {
        for await chunk in chunks {
            lastHeard = .now
            buffer.append(chunk)
            do {
                while let packet = try SFTPWire.popPacket(from: &buffer) {
                    try receive(packet)
                }
            } catch {
                shutDown(greeted
                    ? .connectionLost("The server sent a malformed SFTP packet")
                    : .failed(SFTPWire.notSFTP(buffer)))
                return
            }
        }
        shutDown(.connectionLost("SSH channel closed"))
    }

    /// The server's VERSION first, then replies, each matched to its waiter by id. A reply
    /// nobody waits for answers a cancelled request and is dropped.
    private func receive(_ packet: SFTPMessage) throws {
        var reader = ByteReader(packet.rest)
        guard greeted else {
            guard packet.type == SFTPCode.version else { throw SFTPWire.BadFrame() }
            let version = try reader.u32()
            while let name = try? reader.utf8(), (try? reader.blob()) != nil {
                extensions.insert(name)
            }
            greeted = true
            versionWaiter?.resume(returning: version)
            versionWaiter = nil
            return
        }
        let id = try reader.u32()
        let message = SFTPMessage(type: packet.type, rest: Data(packet.rest.dropFirst(4)))
        waiters.removeValue(forKey: id)?.resume(returning: message)
    }

    private func handle(in message: SFTPMessage) throws -> Data {
        guard message.type == SFTPCode.handle else { throw TransferError.failed("Expected a handle") }
        var reader = ByteReader(message.rest)
        return try reader.blob()
    }

    private func names(in message: SFTPMessage) throws -> [SFTPName] {
        guard message.type == SFTPCode.name else { throw TransferError.failed("Expected names") }
        var reader = ByteReader(message.rest)
        let count = Int(try reader.u32())
        var values: [SFTPName] = []
        for _ in 0..<count {
            let filename = try reader.blob()
            // The `ls -l` style long name is not used.
            _ = try reader.blob()
            let attrs = try reader.attrs()
            values.append(SFTPName(filename: filename, attrs: attrs))
        }
        return values
    }

    private func item(path: RemotePath, message: SFTPMessage) throws -> RemoteItem {
        guard message.type == SFTPCode.attrs else { throw TransferError.failed("Expected attributes") }
        var reader = ByteReader(message.rest)
        return item(path: path, attrs: try reader.attrs())
    }

    private func item(path: RemotePath, attrs: SFTPAttrs) -> RemoteItem {
        RemoteItem(
            path: path,
            kind: attrs.kind,
            size: attrs.size,
            mtime: attrs.mtime,
            mode: attrs.permissions,
            owner: attrs.uid.map(String.init),
            group: attrs.gid.map(String.init)
        )
    }
}
