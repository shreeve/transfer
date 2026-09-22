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

    func list(_ path: RemotePath) -> AsyncThrowingStream<RemoteItem, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let handle = try await openDirectory(path)
                    do {
                    while true {
                        do {
                            let page = try await readDirectory(handle, parent: path)
                            if page.isEmpty { break }
                            for item in page where !item.isDotEntry {
                                continuation.yield(item)
                            }
                        } catch TransferError.failed(let text) where text == "EOF" {
                            break
                        }
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

    func mkdir(_ path: RemotePath) async throws {
        var body = Data()
        body.appendBlob(Data(path.bytes))
        body.append(SFTPAttrs().encoded())
        _ = try await call(SFTPCode.mkdir, body: body)
    }

    func rename(_ source: RemotePath, to destination: RemotePath) async throws {
        if await extendedRename(source, to: destination) { return }
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

    func symlink(target: String, link: RemotePath) async throws {
        var body = Data()
        body.appendBlob(Data(link.bytes))
        body.appendString(target)
        _ = try await call(SFTPCode.symlink, body: body)
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
        var next: UInt64 = 0
        var received: UInt64 = 0
        var inFlight: [(offset: UInt64, task: Task<Data, Error>)] = []
        while received < limit || !inFlight.isEmpty {
            while inFlight.count < 32, next < limit {
                let offset = next
                let ask = UInt32(min(65_536, limit - next))
                next += UInt64(ask)
                let request = Task { try await self.readChunk(handle, offset: offset, length: ask) }
                inFlight.append((offset, request))
            }
            let nextRead = inFlight.removeFirst()
            let chunk: Data
            do {
                chunk = try await nextRead.task.value
            } catch TransferError.failed(let text) where text == "EOF" {
                break
            }
            if chunk.isEmpty { break }
            try output.seek(toOffset: nextRead.offset)
            try output.write(contentsOf: chunk)
            received += UInt64(chunk.count)
            progress(TransferProgress(completed: received, total: limit))
            if chunk.count < 65_536, nextRead.offset + UInt64(chunk.count) >= limit { break }
        }
    }

    private func downloadSequential(handle: Data, output: FileHandle, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        var offset: UInt64 = 0
        while true {
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
            if chunk.count < 65_536 { break }
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
        while true {
            let chunk = try input.read(upToCount: 65_536) ?? Data()
            if chunk.isEmpty { break }
            var body = Data()
            body.appendBlob(handle)
            body.appendU64(offset)
            body.appendBlob(chunk)
            _ = try await call(SFTPCode.write, body: body)
            offset += UInt64(chunk.count)
            progress(TransferProgress(completed: offset, total: total))
        }
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

    private func extendedRename(_ source: RemotePath, to destination: RemotePath) async -> Bool {
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

    private func call(_ type: UInt8, body: Data) async throws -> SFTPMessage {
        let id = nextID
        nextID += 1
        var framed = Data()
        framed.appendU32(id)
        framed.append(body)
        try write(SFTPWire.packet(type: type, body: framed))
        let message: SFTPMessage = try await withCheckedThrowingContinuation { continuation in
            waiters[id] = continuation
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

    private func write(_ packet: Data) throws {
        do {
            try input.write(contentsOf: packet)
        } catch {
            throw TransferError.failed("Broken SSH channel")
        }
    }

    private func readLoop() async {
        for await chunk in chunks.stream {
            buffer.append(chunk)
            while let packet = SFTPWire.popPacket(from: &buffer) {
                if packet.type == SFTPCode.version {
                    let version = packet.rest.prefix(4).loadU32()
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
        let error = TransferError.failed("SSH channel closed")
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
