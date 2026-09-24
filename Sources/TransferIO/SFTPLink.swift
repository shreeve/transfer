import Foundation
import TransferCore

final class ChunkPipe: @unchecked Sendable {
    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    init() {
        var continuation: AsyncStream<Data>.Continuation!
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func yield(_ data: Data) { continuation.yield(data) }
    func finish() { continuation.finish() }
}

actor SFTPLink {
    let role: ChannelRole
    private let process: Process
    private let input: FileHandle
    private let chunks: ChunkPipe
    private var buffer = Data()
    private var nextID: UInt32 = 1
    private var waiters: [UInt32: CheckedContinuation<SFTPMessage, Error>] = [:]
    private var versionWaiter: CheckedContinuation<UInt32, Error>?
    /// The extensions the server named in its VERSION reply, such as `copy-data`.
    private(set) var extensions: Set<String> = []
    private var reader: Task<Void, Never>?
    private(set) var isOpen = true

    init(role: ChannelRole, process: Process, input: FileHandle, output: FileHandle, chunks: ChunkPipe) {
        self.role = role
        self.process = process
        self.input = input
        self.chunks = chunks
        reader = nil
        output.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                // At end of file the handler would otherwise keep firing with nothing to read.
                handle.readabilityHandler = nil
                chunks.finish()
            } else {
                chunks.yield(data)
            }
        }
    }

    func start() {
        reader = Task { await self.readLoop() }
    }

    func handshake() async throws {
        var body = Data()
        body.appendU32(3)
        try write(SFTPWire.packet(type: SFTPCode.initialize, body: body))
        let version: UInt32 = try await withCheckedThrowingContinuation { continuation in
            versionWaiter = continuation
        }
        if version < 3 {
            throw TransferError.failed("Server SFTP version \(version) is too old")
        }
    }

    func realpath(_ path: RemotePath) async throws -> RemotePath {
        var body = Data()
        body.appendBlob(Data(path.bytes))
        let message = try await call(SFTPCode.realpath, body: body)
        let names = try names(in: message)
        guard let first = names.first else { throw TransferError.failed("Empty realpath") }
        return RemotePath(bytes: Array(first.filename))
    }

    func lstat(_ path: RemotePath) async throws -> RemoteItem {
        var body = Data()
        body.appendBlob(Data(path.bytes))
        let message = try await call(SFTPCode.lstat, body: body)
        return try item(path: path, message: message)
    }

    /// Keeps several READDIR requests in flight. OpenSSH answers each with about a hundred names,
    /// so a large folder no longer pays one round trip per page.
    func list(_ path: RemotePath) -> AsyncThrowingStream<RemoteItem, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let handle = try await openDirectory(path)
                    do {
                        var inFlight: [Task<[RemoteItem]?, Error>] = []
                        var finished = false
                        while !finished || !inFlight.isEmpty {
                            while !finished, inFlight.count < 4 {
                                inFlight.append(Task { try await self.readDirectoryPage(handle, parent: path) })
                            }
                            let next = inFlight.removeFirst()
                            guard let page = try await next.value else {
                                finished = true
                                continue
                            }
                            if page.isEmpty { finished = true }
                            for item in page where !item.isDotEntry {
                                continuation.yield(item)
                            }
                            try Task.checkCancellation()
                        }
                        try? await self.close(handle)
                    } catch {
                        try? await self.close(handle)
                        throw error
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
        } catch TransferError.failed(let text) where text == "EOF" {
            return nil
        }
    }

    func mkdir(_ path: RemotePath) async throws {
        var body = Data()
        body.appendBlob(Data(path.bytes))
        body.append(SFTPAttrs().encoded())
        _ = try await call(SFTPCode.mkdir, body: body)
    }

    /// A rename or move the user asked for. It never replaces what is already at `destination`:
    /// `posix-rename` would, and plain RENAME refuses a file there but on OpenSSH replaces an empty
    /// folder, so the destination is looked up first. A change of case alone within one folder
    /// skips the lookup, which on a case-insensitive disk finds the source itself.
    func rename(_ source: RemotePath, to destination: RemotePath) async throws {
        let caseOnly = source.parent == destination.parent && source != destination
            && source.name.lowercased() == destination.name.lowercased()
        if caseOnly {
            if await posixRename(source, to: destination) { return }
            try await plainRename(source, to: destination)
            return
        }
        if (try? await lstat(destination)) != nil {
            throw TransferError.failed("“\(destination.name)” already exists there")
        }
        try await plainRename(source, to: destination)
    }

    /// `posix-rename@openssh.com` replaces the destination. False when the server lacks it.
    func posixRename(_ source: RemotePath, to destination: RemotePath) async -> Bool {
        var body = Data()
        body.appendString("posix-rename@openssh.com")
        body.appendBlob(Data(source.bytes))
        body.appendBlob(Data(destination.bytes))
        do {
            _ = try await call(SFTPCode.extended, body: body)
            return true
        } catch {
            return false
        }
    }

    /// Puts `temp` in place of `placed`. With `posix-rename@openssh.com` the swap is atomic and a
    /// failure leaves `placed` untouched. Without it, SFTP v3 rename will not replace a file, so
    /// `placed` is removed first.
    func replace(_ temp: RemotePath, onto placed: RemotePath) async throws {
        if extensions.contains("posix-rename@openssh.com") {
            var body = Data()
            body.appendString("posix-rename@openssh.com")
            body.appendBlob(Data(temp.bytes))
            body.appendBlob(Data(placed.bytes))
            _ = try await call(SFTPCode.extended, body: body)
            return
        }
        try? await removeFile(placed)
        try await plainRename(temp, to: placed)
    }

    func plainRename(_ source: RemotePath, to destination: RemotePath) async throws {
        var body = Data()
        body.appendBlob(Data(source.bytes))
        body.appendBlob(Data(destination.bytes))
        _ = try await call(SFTPCode.rename, body: body)
    }

    func removeFile(_ path: RemotePath) async throws {
        var body = Data()
        body.appendBlob(Data(path.bytes))
        _ = try await call(SFTPCode.remove, body: body)
    }

    func removeDirectory(_ path: RemotePath) async throws {
        var body = Data()
        body.appendBlob(Data(path.bytes))
        _ = try await call(SFTPCode.rmdir, body: body)
    }

    func readlink(_ path: RemotePath) async throws -> String {
        var body = Data()
        body.appendBlob(Data(path.bytes))
        let message = try await call(SFTPCode.readlink, body: body)
        let names = try names(in: message)
        guard let first = names.first else { throw TransferError.failed("Empty readlink") }
        return String(decoding: first.filename, as: UTF8.self)
    }

    /// OpenSSH's sftp-server reads SYMLINK as (target, link), the reverse of the draft. Every
    /// version-3 server in use follows OpenSSH here.
    func symlink(target: String, link: RemotePath) async throws {
        var body = Data()
        body.appendString(target)
        body.appendBlob(Data(link.bytes))
        _ = try await call(SFTPCode.symlink, body: body)
    }

    /// Copies a file on the server with OpenSSH's `copy-data` extension; no bytes cross the
    /// network. The reply comes when the whole file is written. Callers check `extensions` first.
    func copyData(_ source: RemotePath, to destination: RemotePath) async throws {
        let from = try await openFile(source, flags: SFTPCode.fxRead)
        do {
            let to = try await openFile(destination, flags: SFTPCode.fxWrite | SFTPCode.fxCreat | SFTPCode.fxTrunc)
            do {
                var body = Data()
                body.appendString("copy-data")
                body.appendBlob(from)
                body.appendU64(0)
                // A length of zero copies to the end of the file.
                body.appendU64(0)
                body.appendBlob(to)
                body.appendU64(0)
                _ = try await call(SFTPCode.extended, body: body)
            } catch {
                try? await close(to)
                throw error
            }
            try await close(to)
        } catch {
            try? await close(from)
            throw error
        }
        try? await close(from)
    }

    func setstat(_ path: RemotePath, mode: UInt32?, mtime: UInt32?) async throws {
        var attrs = SFTPAttrs()
        attrs.permissions = mode
        if let mtime {
            attrs.atime = mtime
            attrs.mtime = mtime
        }
        var body = Data()
        body.appendBlob(Data(path.bytes))
        body.append(attrs.encoded())
        _ = try await call(SFTPCode.setstat, body: body)
    }

    func download(
        _ path: RemotePath,
        to destination: URL,
        size: UInt64?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let handle = try await openFile(path, flags: SFTPCode.fxRead)
        defer { Task { try? await self.close(handle) } }
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
            } catch TransferError.failed(let text) where text == "EOF" {
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
            } catch TransferError.failed(let text) where text == "EOF" {
                break
            }
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            offset += UInt64(chunk.count)
            progress(TransferProgress(completed: offset))
        }
    }

    private func readChunk(_ handle: Data, offset: UInt64, length: UInt32) async throws -> Data {
        var body = Data()
        body.appendBlob(handle)
        body.appendU64(offset)
        body.appendU32(length)
        let message = try await call(SFTPCode.read, body: body)
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
        defer { Task { try? await self.close(handle) } }
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
        var body = Data()
        body.appendBlob(handle)
        body.appendU64(offset)
        body.appendBlob(data)
        _ = try await call(SFTPCode.write, body: body)
    }

    func closeLink() {
        isOpen = false
        process.terminate()
        reader?.cancel()
        chunks.finish()
        for waiter in waiters.values {
            waiter.resume(throwing: TransferError.cancelled)
        }
        waiters.removeAll()
        versionWaiter?.resume(throwing: TransferError.cancelled)
        versionWaiter = nil
    }

    private func openDirectory(_ path: RemotePath) async throws -> Data {
        var body = Data()
        body.appendBlob(Data(path.bytes))
        let message = try await call(SFTPCode.opendir, body: body)
        return try handle(in: message)
    }

    private func readDirectory(_ handle: Data, parent: RemotePath) async throws -> [RemoteItem] {
        var body = Data()
        body.appendBlob(handle)
        let message = try await call(SFTPCode.readdir, body: body)
        return try names(in: message).map { name in
            let path = parent.appending(name: Array(name.filename))
            return item(path: path, attrs: name.attrs)
        }
    }

    private func openFile(_ path: RemotePath, flags: UInt32) async throws -> Data {
        var body = Data()
        body.appendBlob(Data(path.bytes))
        body.appendU32(flags)
        body.append(SFTPAttrs().encoded())
        let message = try await call(SFTPCode.open, body: body)
        return try handle(in: message)
    }

    private func close(_ handle: Data) async throws {
        var body = Data()
        body.appendBlob(handle)
        _ = try await call(SFTPCode.close, body: body)
    }

    private var cancelledIDs: Set<UInt32> = []

    private func call(_ type: UInt8, body: Data) async throws -> SFTPMessage {
        try Task.checkCancellation()
        guard isOpen else { throw TransferError.connectionLost("SSH channel closed") }
        let id = nextID
        nextID += 1
        var framed = Data()
        framed.appendU32(id)
        framed.append(body)
        try write(SFTPWire.packet(type: type, body: framed))
        let message: SFTPMessage = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancelledIDs.remove(id) != nil {
                    continuation.resume(throwing: TransferError.cancelled)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
        if message.type == SFTPCode.status {
            var reader = ByteReader(message.rest)
            let code = (try? reader.u32()) ?? SFTPCode.failure
            let text = (try? reader.utf8()) ?? "SFTP error \(code)"
            if code == SFTPCode.ok { return message }
            if code == SFTPCode.eof { throw TransferError.failed("EOF") }
            if code == SFTPCode.noSuchFile { throw TransferError.noSuchFile(text) }
            if code == SFTPCode.permission { throw TransferError.permissionDenied(text) }
            throw TransferError.failed(text)
        }
        return message
    }

    private func cancelRequest(_ id: UInt32) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(throwing: TransferError.cancelled)
        } else {
            cancelledIDs.insert(id)
        }
    }

    private func write(_ packet: Data) throws {
        do {
            try input.write(contentsOf: packet)
        } catch {
            throw TransferError.connectionLost("Broken SSH channel")
        }
    }

    private func readLoop() async {
        for await chunk in chunks.stream {
            buffer.append(chunk)
            while let packet = SFTPWire.popPacket(from: &buffer) {
                if packet.type == SFTPCode.version {
                    let version = packet.rest.prefix(4).loadU32()
                    var reader = ByteReader(Data(packet.rest.dropFirst(4)))
                    while let name = try? reader.utf8(), (try? reader.blob()) != nil {
                        extensions.insert(name)
                    }
                    versionWaiter?.resume(returning: version)
                    versionWaiter = nil
                    continue
                }
                guard packet.rest.count >= 4 else { continue }
                let id = packet.rest.prefix(4).loadU32()
                let rest = packet.rest.dropFirst(4)
                let message = SFTPMessage(type: packet.type, requestID: id, rest: Data(rest))
                waiters.removeValue(forKey: id)?.resume(returning: message)
            }
        }
        isOpen = false
        let error = TransferError.connectionLost("SSH channel closed")
        versionWaiter?.resume(throwing: error)
        versionWaiter = nil
        for waiter in waiters.values { waiter.resume(throwing: error) }
        waiters.removeAll()
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
            let longname = try reader.utf8()
            let attrs = try reader.attrs()
            values.append(SFTPName(filename: filename, longname: longname, attrs: attrs))
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
