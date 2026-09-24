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
    private var frames = SFTPWire.Frames()
    private var nextID: UInt32 = 1
    /// Requests sent and not yet answered or abandoned. A reply that arrives before anyone waits
    /// for it is kept in `early`, so a transfer can have many requests out and await them in turn.
    private var pending: Set<UInt32> = []
    private var early: [UInt32: SFTPMessage] = [:]
    private var waiters: [UInt32: CheckedContinuation<SFTPMessage, Error>] = [:]
    /// What a request still out when the channel closed fails with.
    private var closedWith = TransferError.connectionLost("SSH channel closed")
    private var versionWaiter: CheckedContinuation<UInt32, Error>?
    /// Whether the server's VERSION has arrived. Anything else before it is not SFTP.
    private var greeted = false
    /// The extensions the server named in its VERSION reply, such as `copy-data`.
    private(set) var extensions: Set<String> = []
    private var reader: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private(set) var isOpen = true

    /// A server silent this long while requests wait has hung: the channel closes and its requests
    /// fail with a timeout, which a transfer retries on a new channel.
    private let stallLimit: Duration
    /// How long the server has to answer INIT.
    private let handshakeLimit: Duration
    private var lastHeard = ContinuousClock.now
    private var handshakeStarted: ContinuousClock.Instant?
    /// Requests the server may rightly take minutes over, such as `copy-data`, which answers when
    /// the whole file is written. While one is out, silence is not a stall.
    private var longCalls: Set<UInt32> = []

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

    /// Sends INIT and waits for VERSION, at most `handshakeLimit`; cancelling closes the channel.
    func handshake() async throws {
        handshakeStarted = .now
        transmit(SFTPWire.packet(type: SFTPCode.initialize) { $0.appendU32(3) })
        let version: UInt32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if isOpen {
                    versionWaiter = continuation
                } else {
                    continuation.resume(throwing: TransferError.connectionLost("SSH channel closed"))
                }
            }
        } onCancel: {
            Task { await self.closeLink() }
        }
        guard version >= 3 else { throw TransferError.failed("Server SFTP version \(version) is too old") }
    }

    func realpath(_ path: RemotePath) async throws -> RemotePath {
        guard let first = try names(in: await call(SFTPCode.realpath) { $0.appendPath(path) }).first else { throw TransferError.failed("Empty realpath") }
        return RemotePath(bytes: Array(first.filename))
    }

    func lstat(_ path: RemotePath) async throws -> RemoteItem {
        try item(path: path, message: await call(SFTPCode.lstat) { $0.appendPath(path) })
    }

    /// The size and time of the file `handle` has open, which its path may no longer name.
    private func fstat(_ handle: Data) async throws -> Fingerprint? {
        Fingerprint(item: try item(path: RemotePath(string: "/"), message: await call(SFTPCode.fstat) { $0.appendBlob(handle) }))
    }

    /// Keeps several READDIR requests in flight. OpenSSH answers each with at most a hundred names,
    /// so a large folder does not pay a round trip per page. A listing its reader abandons stops at
    /// once and still closes its handle on the server.
    func list(_ path: RemotePath) -> AsyncThrowingStream<RemoteItem, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let handle = try self.handle(in: await call(SFTPCode.opendir) { $0.appendPath(path) })
                    var inFlight: [Task<[RemoteItem]?, Error>] = []
                    defer {
                        for page in inFlight { page.cancel() }
                        closeSoon([handle])
                    }
                    var finished = false
                    var pages = 0
                    while !finished || !inFlight.isEmpty {
                        // Four pages at first, so a small folder asks for at most three pages
                        // past its end; sixteen once four have come, so a large one pays about
                        // one round trip per 1,600 names.
                        while !finished, inFlight.count < (pages < 4 ? 4 : 16) {
                            inFlight.append(Task { try await self.readDirectory(handle, parent: path) })
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
                        pages += 1
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

    /// Renames a finished temp file onto `placed`: replacing what is there, or refusing when
    /// anything is, so an item that appeared after the name was found free is never overwritten
    /// unasked. A file never replaces a folder, so plain RENAME is safe for a temp.
    func place(_ temp: RemotePath, onto placed: RemotePath, replacing: Bool) async throws {
        if replacing { return try await replace(temp, onto: placed) }
        try await plainRename(temp, to: placed)
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
        guard let first = try names(in: await call(SFTPCode.readlink) { $0.appendPath(path) }).first else { throw TransferError.failed("Empty readlink") }
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

    /// Copies a file on the server with OpenSSH's `copy-data` extension, which callers check for
    /// first. Two round trips: both OPENs, then `copy-data`, `stamp` on the new file's handle, and
    /// both CLOSEs, which the server carries out in order. The written file's CLOSE is awaited,
    /// since it can report a failed last write; a `stamp` that did not take is not an error.
    func copyData(_ source: RemotePath, to destination: RemotePath, stamp: SFTPAttrs? = nil) async throws {
        try Task.checkCancellation()
        let opens = try [
            send(SFTPCode.open) { $0.openFields(source, flags: SFTPCode.fxRead) },
            send(SFTPCode.open) { $0.openFields(destination, flags: SFTPCode.fxWrite | SFTPCode.fxCreat | SFTPCode.fxTrunc) },
        ]
        let handles = try await handles(opening: opens)
        let (from, to) = (handles[0], handles[1])
        var finishing: [UInt32] = []
        defer { for id in finishing { abandon(id) } }
        do {
            finishing.append(try send(SFTPCode.extended, long: true) {
                $0.appendString("copy-data")
                $0.appendBlob(from)
                $0.appendU64(0)
                // A length of zero copies to the end of the file.
                $0.appendU64(0)
                $0.appendBlob(to)
                $0.appendU64(0)
            })
            if let stamp { finishing.append(try setstatRequest(handle: to, stamp)) }
            finishing.append(try send(SFTPCode.close) { $0.appendBlob(to) })
        } catch {
            closeSoon([from, to])
            throw error
        }
        closeSoon([from])
        _ = try await reply(finishing[0])
        if stamp != nil { _ = try? await reply(finishing[1]) }
        _ = try await reply(finishing[finishing.count - 1])
    }

    /// The handles OPEN requests already sent return, in order. The replies are awaited even when
    /// the caller is cancelled: an OPEN may create a temp, whose removal, sent on another channel
    /// once the cancel lands, must not reach the server first and leave the temp behind. When any
    /// fails, or the caller was cancelled, those that opened are closed and it throws.
    private func handles(opening ids: [UInt32]) async throws -> [Data] {
        var handles: [Data] = []
        var failure: (any Error)?
        for id in ids {
            do {
                handles.append(try await Task { try await self.handle(in: self.reply(id)) }.value)
            } catch {
                failure = failure ?? error
            }
        }
        if Task.isCancelled { failure = failure ?? TransferError.cancelled }
        if let failure {
            closeSoon(handles)
            throw failure
        }
        return handles
    }

    func setstat(_ path: RemotePath, _ stamp: SFTPAttrs) async throws {
        _ = try await call(SFTPCode.setstat) {
            $0.appendPath(path)
            $0.append(stamp.encoded())
        }
    }

    /// FSETSTAT, sent now: `stamp` set on the file `handle` has open.
    private func setstatRequest(handle: Data, _ stamp: SFTPAttrs) throws -> UInt32 {
        try send(SFTPCode.fsetstat) {
            $0.appendBlob(handle)
            $0.append(stamp.encoded())
        }
    }

    /// Downloads `path` into `destination` over this channel alone.
    func download(_ path: RemotePath, to destination: URL, size: UInt64?, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let parts = try DownloadParts(destination, size: size, progress: progress)
        try await receive(path, into: parts)
        try parts.finish()
    }

    /// Reads what `parts` hands out of the file at `path`, keeping 2 MB in flight, until nothing is
    /// left to ask for. With `matching`, a second channel helps only if the file it opened is still
    /// the one listed, so a file replaced meanwhile is never read in pieces from two versions.
    func receive(_ path: RemotePath, into parts: DownloadParts, matching print: Fingerprint? = nil) async throws {
        let handle = try await openFile(path, flags: SFTPCode.fxRead)
        defer { closeSoon([handle]) }
        if let print, try await fstat(handle) != print { return }
        var inFlight: [(offset: UInt64, length: UInt32, id: UInt32)] = []
        defer { for read in inFlight { abandon(read.id) } }
        while true {
            try Task.checkCancellation()
            while inFlight.count < 32, let request = parts.nextRequest() {
                let id = try send(SFTPCode.read) {
                    $0.appendBlob(handle)
                    $0.appendU64(request.offset)
                    $0.appendU32(request.length)
                }
                inFlight.append((request.offset, request.length, id))
            }
            guard !inFlight.isEmpty else { break }
            let read = inFlight.removeFirst()
            do {
                let message = try await reply(read.id)
                guard message.type == SFTPCode.data else { throw TransferError.failed("Expected data") }
                var reader = ByteReader(message.rest)
                let chunk = try reader.blob()
                try parts.write(chunk, offset: read.offset, length: read.length)
            } catch is EndOfFile {
                parts.endOfFile()
            }
        }
    }

    /// Uploads `source` to `path` over this channel alone, `stamp` set after the last write.
    func upload(
        _ source: URL,
        to path: RemotePath,
        stamp: SFTPAttrs? = nil,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let parts = try UploadParts(source, progress: progress)
        try await send(parts, to: try await create(path), stamp: stamp)
        parts.finish()
    }

    /// Opens `path` for writing, creating it or cutting it to nothing.
    func create(_ path: RemotePath) async throws -> Data {
        try Task.checkCancellation()
        return try await handles(opening: [send(SFTPCode.open) { $0.openFields(path, flags: SFTPCode.fxWrite | SFTPCode.fxCreat | SFTPCode.fxTrunc) }])[0]
    }

    /// Writes what `parts` hands out into `path`, which another channel created.
    func send(_ parts: UploadParts, into path: RemotePath) async throws {
        try await send(parts, to: try await openFile(path, flags: SFTPCode.fxWrite))
    }

    /// Writes what `parts` hands out to `handle`, keeping 2 MB in flight, then closes it, awaiting
    /// the close: a server may report a failed last write only there. `stamp` and the close go out
    /// right behind the last write, costing no round trip; the server carries out a file's
    /// requests in order, so no write lands after the stamp. A stamp that did not take is no error.
    func send(_ parts: UploadParts, to handle: Data, stamp: SFTPAttrs? = nil) async throws {
        var writes: [(id: UInt32, count: UInt64)] = []
        var finishing: [UInt32] = []
        defer {
            for id in writes.map(\.id) + finishing { abandon(id) }
            if finishing.isEmpty { closeSoon([handle]) }
        }
        var exhausted = false
        while !exhausted || !writes.isEmpty {
            try Task.checkCancellation()
            if !exhausted, writes.count < 32 {
                if let chunk = try parts.next() {
                    let id = try send(SFTPCode.write, capacity: chunk.data.count + 64) {
                        $0.appendBlob(handle)
                        $0.appendU64(chunk.offset)
                        $0.appendBlob(chunk.data)
                    }
                    writes.append((id, UInt64(chunk.data.count)))
                } else {
                    exhausted = true
                    if let stamp { finishing.append(try setstatRequest(handle: handle, stamp)) }
                    finishing.append(try send(SFTPCode.close) { $0.appendBlob(handle) })
                }
                continue
            }
            let oldest = writes.removeFirst()
            _ = try await reply(oldest.id)
            parts.acknowledge(oldest.count)
        }
        if stamp != nil { _ = try? await reply(finishing[0]) }
        _ = try await reply(finishing[finishing.count - 1])
    }

    /// Closes the channel for good: ends ssh, and fails the handshake and every waiting request
    /// with `reason`. A master that died passes a lost connection, which a transfer retries, where
    /// a disconnect the user asked for cancels.
    func closeLink(reason: TransferError = .cancelled) {
        guard isOpen else { return }
        isOpen = false
        process?.terminate()
        reader?.cancel()
        watchdog?.cancel()
        chunkSink.finish()
        versionWaiter?.resume(throwing: reason)
        versionWaiter = nil
        closedWith = reason
        for waiter in waiters.values { waiter.resume(throwing: reason) }
        waiters.removeAll()
        pending.removeAll()
        early.removeAll()
        longCalls.removeAll()
    }

    /// Ends a handshake past `handshakeLimit`, and a channel whose server has said nothing for
    /// `stallLimit` while requests wait.
    private func watch() async {
        while isOpen {
            try? await Task.sleep(for: (greeted ? stallLimit : min(stallLimit, handshakeLimit)) / 5)
            let now = ContinuousClock.now
            if versionWaiter != nil, let handshakeStarted, now - handshakeStarted > handshakeLimit {
                closeLink(reason: .timeout("The server did not start SFTP"))
            } else if !pending.isEmpty, longCalls.isEmpty, now - lastHeard > stallLimit {
                closeLink(reason: .timeout("The server stopped answering"))
            }
        }
    }

    /// One page of `parent`'s entries, nil at the end. A name the server sends is used as a path
    /// component, so anything that is not exactly one is dropped: `.` and `..`, an empty name, and
    /// a name with a slash or NUL, which a hostile server could send to reach outside the folder.
    private func readDirectory(_ handle: Data, parent: RemotePath) async throws -> [RemoteItem]? {
        let message: SFTPMessage
        do {
            message = try await call(SFTPCode.readdir) { $0.appendBlob(handle) }
        } catch is EndOfFile {
            return nil
        }
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
        try handle(in: await call(SFTPCode.open) { $0.openFields(path, flags: flags) })
    }

    /// Sends CLOSE for each handle and forgets the replies. Cleanup after a cancellation must
    /// still reach the server, so this sends even in a cancelled task.
    private func closeSoon(_ handles: [Data]) {
        for handle in handles {
            guard let id = try? send(SFTPCode.close, { $0.appendBlob(handle) }) else { return }
            abandon(id)
        }
    }

    /// Sends one request and waits for the reply. A failure status throws, EOF as `EndOfFile`.
    private func call(
        _ type: UInt8,
        capacity: Int = 64,
        long: Bool = false,
        _ fields: (inout Data) -> Void
    ) async throws -> SFTPMessage {
        try Task.checkCancellation()
        return try await reply(send(type, capacity: capacity, long: long, fields))
    }

    /// Sends one request now and returns its id for `reply`. Requests reach the server in the order
    /// they are sent, so a caller may send many before awaiting any; each is awaited or abandoned.
    private func send(
        _ type: UInt8,
        capacity: Int = 64,
        long: Bool = false,
        _ fields: (inout Data) -> Void
    ) throws -> UInt32 {
        guard isOpen else { throw TransferError.connectionLost("SSH channel closed") }
        let id = nextID
        nextID &+= 1
        // An idle channel's silence was not a stall; the clock starts with the first request.
        if pending.isEmpty { lastHeard = .now }
        pending.insert(id)
        if long { longCalls.insert(id) }
        transmit(SFTPWire.packet(type: type, capacity: capacity) { packet in
            packet.appendU32(id)
            fields(&packet)
        })
        return id
    }

    /// The reply to request `id`, waiting for it if it has not come. The waiter is registered in
    /// the actor turn that finds no reply, so none can slip past it, and a cancellation, which
    /// runs on the actor after it, always finds it or finds it answered.
    private func reply(_ id: UInt32) async throws -> SFTPMessage {
        let message: SFTPMessage
        if let arrived = early.removeValue(forKey: id) {
            message = arrived
        } else {
            guard pending.contains(id) else { throw isOpen ? TransferError.cancelled : closedWith }
            message = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters[id] = continuation
                }
            } onCancel: {
                Task { await self.abandon(id) }
            }
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

    /// Stops waiting for request `id`: its reply, when it comes, is dropped.
    private func abandon(_ id: UInt32) {
        pending.remove(id)
        longCalls.remove(id)
        early.removeValue(forKey: id)
        waiters.removeValue(forKey: id)?.resume(throwing: TransferError.cancelled)
    }

    /// Queues `packet` for ssh's stdin, in order. A failed write means ssh is gone.
    private func transmit(_ packet: Data) {
        writer.async { [input] in
            do {
                try input.write(contentsOf: packet)
            } catch {
                Task { await self.closeLink(reason: .connectionLost("Broken SSH channel")) }
            }
        }
    }

    private func readLoop() async {
        for await chunk in chunks {
            lastHeard = .now
            frames.append(chunk)
            do {
                while let packet = try frames.next() {
                    try receive(packet)
                }
            } catch {
                closeLink(reason: greeted
                    ? .connectionLost("The server sent a malformed SFTP packet")
                    : .failed(SFTPWire.notSFTP(frames.unread)))
                return
            }
        }
        closeLink(reason: .connectionLost("SSH channel closed"))
    }

    /// The server's VERSION first, then replies, each matched to its request by id. A reply to a
    /// request nobody waits for yet is kept for `reply`; one to an abandoned request is dropped.
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
        guard pending.remove(id) != nil else { return }
        longCalls.remove(id)
        let message = SFTPMessage(type: packet.type, rest: packet.rest.dropFirst(4))
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(returning: message)
        } else {
            early[id] = message
        }
    }

    private func handle(in message: SFTPMessage) throws -> Data {
        guard message.type == SFTPCode.handle else { throw TransferError.failed("Expected a handle") }
        var reader = ByteReader(message.rest)
        // A copy: a handle lives as long as its file is open, and a slice would keep the whole
        // read it arrived in.
        return Data(try reader.blob())
    }

    private func names(in message: SFTPMessage) throws -> [(filename: Data, attrs: SFTPAttrs)] {
        guard message.type == SFTPCode.name else { throw TransferError.failed("Expected names") }
        var reader = ByteReader(message.rest)
        return try (0..<reader.u32()).map { _ in
            let filename = try reader.blob()
            // The `ls -l` style long name is not used.
            _ = try reader.blob()
            return (filename, try reader.attrs())
        }
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

/// Lets progress through at most ten times a second, and always the last value: each report is a
/// hop to the main actor, and a fast transfer finishes a 64 KB request every few microseconds.
struct ProgressPacer {
    private var last: ContinuousClock.Instant?
    private var held: TransferProgress?

    /// `progress` when a report is due, else nil, holding it for `finish`.
    mutating func due(_ progress: TransferProgress) -> TransferProgress? {
        let now = ContinuousClock.now
        if let last, now - last < .milliseconds(100) {
            held = progress
            return nil
        }
        last = now
        held = nil
        return progress
    }

    /// The last progress held back, if any.
    mutating func finish() -> TransferProgress? {
        defer { held = nil }
        return held
    }
}

/// One download's shared state: what is left to ask for (`ReadPlan`), the local file each reply
/// is written into at its offset, and progress. Several channels may read into one download at
/// once, each through its own handle (PERF-07). A file with no listed size is read until EOF.
final class DownloadParts: Sendable {
    private let size: UInt64?
    private let descriptor: Int32
    private let state: Locked<(plan: ReadPlan, pacer: ProgressPacer)>
    private let report: @Sendable (TransferProgress) -> Void

    /// Creates `file`, or cuts it to nothing, to write the download into.
    init(_ file: URL, size: UInt64?, progress: @escaping @Sendable (TransferProgress) -> Void) throws {
        descriptor = open(file.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else { throw TransferError.failed("Could not write the download: \(String(cString: strerror(errno)))") }
        self.size = size
        state = Locked((ReadPlan(size: size ?? .max), ProgressPacer()))
        report = progress
    }

    deinit {
        close(descriptor)
    }

    func nextRequest() -> (offset: UInt64, length: UInt32)? {
        state.withLock { $0.plan.nextRequest() }
    }

    /// The reply `chunk` to a READ of `length` at `offset`: written in place, then counted.
    func write(_ chunk: Data, offset: UInt64, length: UInt32) throws {
        guard chunk.count <= Int(length) else { throw TransferError.failed("The server sent more than was asked for") }
        try chunk.withUnsafeBytes { bytes in
            var done = 0
            while done < bytes.count {
                let count = pwrite(descriptor, bytes.baseAddress! + done, bytes.count - done, off_t(offset) + off_t(done))
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw TransferError.failed("Could not write the download: \(String(cString: strerror(errno)))") }
                done += count
            }
        }
        let due = state.withLock { state in
            state.plan.record(offset: offset, length: length, count: UInt32(chunk.count))
            return state.pacer.due(TransferProgress(completed: state.plan.received, total: size))
        }
        if let due { report(due) }
    }

    /// The server answered EOF: the file is shorter than its listed size.
    func endOfFile() {
        state.withLock { $0.plan.endOfFile() }
    }

    /// Reports the last progress, and throws unless every byte of the file arrived with no gap.
    func finish() throws {
        let (complete, last) = state.withLock { ($0.plan.isComplete, $0.pacer.finish()) }
        if let last { report(last) }
        guard complete else { throw TransferError.failed("The file changed on the server while it downloaded") }
    }
}

/// One upload's shared state: the local file, read in order 64 KB at a time for whichever channel
/// asks next, up to the end it has when it gets there, and progress (PERF-07).
final class UploadParts: Sendable {
    let total: UInt64?
    private let descriptor: Int32
    private let state = Locked((next: UInt64(0), ended: false, acknowledged: UInt64(0), pacer: ProgressPacer()))
    private let report: @Sendable (TransferProgress) -> Void

    init(_ source: URL, progress: @escaping @Sendable (TransferProgress) -> Void) throws {
        descriptor = open(source.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let reason = String(cString: strerror(errno))
            throw errno == ENOENT ? TransferError.noSuchFile(source.path) : TransferError.failed("Could not read \(source.lastPathComponent): \(reason)")
        }
        var info = stat()
        total = fstat(descriptor, &info) == 0 ? UInt64(info.st_size) : nil
        report = progress
    }

    deinit {
        close(descriptor)
    }

    /// The next 64 KB of the file and where it goes; nil once the file has ended.
    func next() throws -> (offset: UInt64, data: Data)? {
        try state.withLock { state in
            guard !state.ended else { return nil }
            var data = Data(count: 65_536)
            var count = -1
            while count < 0 {
                count = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, off_t(state.next)) }
                if count < 0, errno != EINTR { throw TransferError.failed("Could not read the file: \(String(cString: strerror(errno)))") }
            }
            guard count > 0 else {
                state.ended = true
                return nil
            }
            data.count = count
            defer { state.next += UInt64(count) }
            return (state.next, data)
        }
    }

    /// The server took `count` more bytes.
    func acknowledge(_ count: UInt64) {
        let due = state.withLock { state in
            state.acknowledged += count
            return state.pacer.due(TransferProgress(completed: state.acknowledged, total: total))
        }
        if let due { report(due) }
    }

    /// Reports the last progress held back.
    func finish() {
        if let last = state.withLock({ $0.pacer.finish() }) { report(last) }
    }
}
