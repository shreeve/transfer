import Darwin
import Foundation
import TransferCore

/// A folder download's small files, streamed by the server's own `tar` over the master instead of
/// a few SFTP round trips each. The walk lists and settles every name over SFTP as before; only
/// the bytes of the files it chose come down a stream, each into a temp beside the name the walk
/// settled and renamed into place as SFTP's are. A download keeps up to `TarBatching.streams`
/// streams and sends each batch's names to the least loaded, so a stream's start is paid once.
/// The stream is untrusted (`TarBatchPlan`), and any file it does not deliver whole and unchanged
/// goes over SFTP.
extension SSHConnection {
    /// The one command a stream runs: constant, with the names NUL-separated on its standard
    /// input, so no name is ever read by the server's shell. The marker comes first, so output a
    /// startup file prints is never read as the archive. `env` sets the variable in any shell, and
    /// keeps a Mac server's tar from adding `._` AppleDouble entries. GNU tar and bsdtar both take
    /// these flags, `--no-recursion` and `--null` before the `-T` they apply to.
    static let tarCommandLine = "echo TRANSFER-TAR-1; exec env COPYFILE_DISABLE=1 tar -cf - --no-recursion --null -T -"
    static let tarMarker = Array("TRANSFER-TAR-1\n".utf8)

    /// One file of a batch: the listing's item and the name the walk settled for it.
    struct TarJob: Sendable {
        let item: RemoteItem
        let destination: URL
        let replacing: Bool
    }

    /// Runs `command` with no names. It works when it prints the marker, then an empty archive
    /// (zero blocks only), and exits 0: tar is there, takes the flags, and no startup output gets
    /// in the way. At most 64 KB of its output is read, and it gets 15 s.
    static func probeTar(_ arguments: [String]) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { exited.continuation.yield($0.terminationStatus) }
        do {
            try process.run()
        } catch {
            return false
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { if process.isRunning { process.terminate() } }
        let reader = output.fileHandleForReading
        let bytes = await withCheckedContinuation { (done: CheckedContinuation<[UInt8], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var bytes: [UInt8] = []
                while bytes.count <= 64 << 10, let chunk = try? reader.read(upToCount: 16 << 10), !chunk.isEmpty { bytes += chunk }
                done.resume(returning: bytes)
            }
        }
        if process.isRunning { process.terminate() }
        try? reader.close()
        var status: Int32 = -1
        for await code in exited.stream {
            status = code
            break
        }
        guard status == 0, bytes.starts(with: tarMarker) else { return false }
        let archive = bytes.dropFirst(tarMarker.count)
        return archive.count >= 2 * TarFormat.block && archive.count % TarFormat.block == 0 && archive.allSatisfy { $0 == 0 }
    }

    /// A stream for a download's batches, in a place free now or the next to come free; nil when
    /// tar is off or missing here, or every stream runs already. Its place is given back when its
    /// process ends.
    func startTarFeed() async -> TarFeed? {
        guard let command = tarCommand, await tarReady(), let slot = try? await takeTarSlot(waiting: true) else { return nil }
        let feed = TarFeed.start(tarArguments(command)) { [weak self] in
            Task { await self?.giveBackTarSlot(slot) }
        }
        if feed == nil { giveBackTarSlot(slot) }
        return feed
    }

    /// What became of one file of a batch.
    enum TarOutcome: Sendable {
        case landed
        /// The stream did not deliver it whole and unchanged: it goes over SFTP.
        case sftp
        /// It came whole, but could not take its name: the copy's failure, as over SFTP.
        case failed(any Error)
    }

    /// After a batch's entries: each file written whole lands only when a fresh look at the server
    /// still lists it as it was, so tar read it unchanged. Cancelled, it removes every temp.
    func landTarBatch(_ jobs: [TarJob], temps: [URL], written: Set<Int>) async throws -> [TarOutcome] {
        let store = store
        var fresh: [Int: Fingerprint] = [:]
        do {
            try Task.checkCancellation()
            if !written.isEmpty {
                let link = try await walkerLink()
                fresh = try await withThrowingTaskGroup(of: (Int, Fingerprint?).self) { group in
                    for index in written {
                        let path = jobs[index].item.path
                        group.addTask { (index, (try await link.lookup(path)).flatMap(Fingerprint.init(item:))) }
                    }
                    var found: [Int: Fingerprint] = [:]
                    for try await (index, print) in group { found[index] = print }
                    return found
                }
            }
        } catch {
            Self.discard(temps, store: store)
            throw error
        }
        return await Self.landBatch(jobs, temps: temps, written: written, fresh: fresh, store: store)
    }

    /// Off the actor: places each file the stream wrote that the server still lists as it was,
    /// removes the rest, and forgets every temp that is gone.
    private nonisolated static func landBatch(_ jobs: [TarJob], temps: [URL], written: Set<Int>, fresh: [Int: Fingerprint], store: Store) async -> [TarOutcome] {
        var outcomes: [TarOutcome] = []
        var gone: [URL] = []
        for (index, job) in jobs.enumerated() {
            let temp = temps[index]
            guard written.contains(index), fresh[index] == Fingerprint(item: job.item) else {
                // A file written whole whose entry the stream then cut short is there too.
                if unlink(temp.path) == 0 || errno == ENOENT { gone.append(temp) }
                outcomes.append(.sftp)
                continue
            }
            do {
                try land(temp, as: job.destination, info: job.item, replacing: job.replacing)
                gone.append(temp)
                outcomes.append(.landed)
            } catch {
                if unlink(temp.path) == 0 || errno == ENOENT { gone.append(temp) }
                outcomes.append(.failed(error))
            }
        }
        store.forgetTemps(local: gone)
        return outcomes
    }

    /// Removes `temps` (those never written are not there) and forgets those gone.
    nonisolated static func discard(_ temps: [URL], store: Store) {
        store.forgetTemps(local: temps.filter { unlink($0.path) == 0 || errno == ENOENT })
    }
}

/// One folder download's tar streams, started as its batches need them.
final class TarFeeds: Sendable {
    private struct State {
        var feeds: [TarFeed] = []
        /// Streams still starting, perhaps waiting for a place.
        var starting = 0
        var started = false
        var closed = false
        /// Places were kept for the streams (`SSHConnection.keepTarPlaces`).
        var kept = false
        /// Batches waiting for the first stream to start.
        var waiting: [CheckedContinuation<Void, Never>] = []
        /// Batches handed over (`expect`) and not yet sent, and whether the streams are to be
        /// told no more come once they are.
        var submitting = 0
        var finishing = false
    }

    private let session: SSHConnection
    private let state = Locked(State())

    init(_ session: SSHConnection) {
        self.session = session
    }

    /// Starts the streams, `TarBatching.streams` of them, each in the next place to come free;
    /// the data pool keeps their places meanwhile. Once only.
    func start() {
        let first = state.withLock { state in
            defer { state.started = true }
            guard !state.started, !state.closed else { return false }
            state.starting = TarBatching.streams
            return true
        }
        guard first else { return }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<TarBatching.streams {
                    group.addTask {
                        let feed = await self.session.startTarFeed()
                        let (waiting, late) = self.state.withLock { state -> ([CheckedContinuation<Void, Never>], Bool) in
                            state.starting -= 1
                            if let feed, !state.closed { state.feeds.append(feed) }
                            guard feed != nil || state.starting == 0 else { return ([], state.closed) }
                            defer { state.waiting = [] }
                            return (state.waiting, state.closed)
                        }
                        // A stream that started after the download ended is told so at once.
                        if late { feed?.finish() }
                        for continuation in waiting { continuation.resume() }
                    }
                }
            }
        }
    }

    /// A batch is on its way to `submit`, which may run after `finish`: the streams wait for it.
    func expect() {
        state.withLock { $0.submitting += 1 }
    }

    /// Sends `jobs`' names down the least loaded stream, once one has started, after `expect`.
    /// Their temps are recorded first, in one commit. Nil when no stream can take them: they go
    /// over SFTP.
    func submit(_ jobs: [SSHConnection.TarJob], store: Store) async -> TarTicket? {
        defer {
            let last = state.withLock { state in
                state.submitting -= 1
                return state.finishing && state.submitting == 0
            }
            if last { finish() }
        }
        start()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state in
                state.feeds.removeAll { $0.isEnded }
                guard state.feeds.isEmpty, state.starting > 0 else { return true }
                state.waiting.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
        let running = state.withLock { $0.feeds }
        guard !running.isEmpty else {
            // Every stream ended or none could start: the pool may use their places.
            release()
            return nil
        }
        let temps = jobs.map { $0.destination.deletingLastPathComponent().appendingPathComponent(KeepBothName.temp(for: $0.destination.lastPathComponent)) }
        store.rememberTemps(local: temps)
        for feed in running.sorted(by: { $0.load < $1.load }) {
            if let range = feed.send(jobs, temps: temps) { return TarTicket(feed: feed, range: range, temps: temps) }
        }
        store.forgetTemps(local: temps)
        return nil
    }

    /// No more batches: each stream ends once tar has sent what it was asked for, and the pool
    /// may use the places again. Until then tar may hold the last names, and the end of its
    /// archive (bsdtar reads its list with `fread`), so only a caller that goes on sending, as a
    /// walk does, may wait for a batch.
    func finish() {
        let now = state.withLock { state in
            state.finishing = true
            return state.submitting == 0
        }
        if now { for feed in close() { feed.finish() } }
    }

    func cancel() {
        for feed in close() { feed.cancel() }
    }

    private func close() -> [TarFeed] {
        let feeds = state.withLock { state in
            defer { state.closed = true }
            return state.feeds
        }
        release()
        return feeds
    }

    private func release() {
        Task { await session.releaseTarPlaces(self) }
    }

    /// Whether places are to be kept now: the first time asked, before the streams close.
    func markKept() -> Bool {
        state.withLock { state in
            guard !state.kept, !state.closed else { return false }
            state.kept = true
            return true
        }
    }
}

/// A batch sent down a stream: `range` of its expected files.
struct TarTicket: Sendable {
    let feed: TarFeed
    let range: Range<Int>
    let temps: [URL]

    /// The batch's files written whole, by their place in the batch, once the stream has judged
    /// every one of them or ended.
    func written() async -> Set<Int> {
        await feed.written(range)
    }
}

/// What a `TarReceiver` asks about each entry it reads: `TarFeed`'s plan, or a test's.
protocol TarJudge: AnyObject, Sendable {
    /// What the entry is, and the temp to write a taken one into.
    func judge(_ entry: TarBatchPlan.Entry) -> (verdict: TarBatchPlan.Verdict, temp: URL?)
    /// The entry judged last is done with: `index` when it was taken and written whole.
    func wrote(_ index: Int?)
}

/// One `ssh … tar` passenger fed batch after batch: names go to its standard input on a queue of
/// their own, and a reader thread writes each entry its plan takes into that file's temp.
final class TarFeed: TarJudge {
    private struct State {
        var plan = TarBatchPlan(skipLimit: TarBatching.batchBytes)
        var temps: [URL] = []
        var written: Set<Int> = []
        var waiting: [(range: Range<Int>, continuation: CheckedContinuation<Set<Int>, Never>)] = []
        var ended = false
        var finished = false
        var inputClosed = false
        /// Bytes sent and not yet judged, to pick the least loaded stream.
        var sizes: [UInt64] = []
        var load: UInt64 = 0
    }

    private let process: Process
    private let writer: FileHandle
    private let names = DispatchQueue(label: "TarFeed.names", qos: .userInitiated)
    private let state = Locked(State())

    private init(process: Process, writer: FileHandle) {
        self.process = process
        self.writer = writer
    }

    /// Starts `ssh` with `arguments`, and its reader; `ended` runs once the stream is over.
    static func start(_ arguments: [String], ended: @escaping @Sendable () -> Void) -> TarFeed? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // A server that stops reading must not end the app with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let feed = TarFeed(process: process, writer: input.fileHandleForWriting)
        let reader = output.fileHandleForReading
        Thread.detachNewThread {
            var receiver = TarReceiver(reader.fileDescriptor)
            receiver.receive(feed)
            try? reader.close()
            feed.end()
            ended()
        }
        return feed
    }

    var isEnded: Bool { state.value.ended }
    var load: UInt64 { state.value.load }

    /// Queues `jobs`, whose `temps` are recorded: their names go to tar after every name before
    /// them. Nil once the stream has ended or been told no more come.
    func send(_ jobs: [SSHConnection.TarJob], temps: [URL]) -> Range<Int>? {
        state.withLock { state in
            guard !state.ended, !state.finished else { return nil }
            let range = state.plan.expected.count..<(state.plan.expected.count + jobs.count)
            state.plan.append(jobs.map { TarBatchPlan.Expected(path: $0.item.path.bytes, size: $0.item.size ?? 0, mtime: $0.item.mtime ?? 0) })
            state.temps += temps
            state.sizes += jobs.map { $0.item.size ?? 0 }
            state.load += jobs.reduce(0) { $0 + ($1.item.size ?? 0) }
            // Queued inside the lock, so names go out in the order the plan expects them.
            let bytes = Data(jobs.flatMap { $0.item.path.bytes + [0] })
            let writer = writer
            names.async { try? writer.write(contentsOf: bytes) }
            return range
        }
    }

    /// The files of `range` written whole, by their place in it.
    func written(_ range: Range<Int>) async -> Set<Int> {
        await withCheckedContinuation { continuation in
            let now: Set<Int>? = state.withLock { state in
                guard state.ended || state.plan.next >= range.upperBound else {
                    state.waiting.append((range, continuation))
                    return nil
                }
                return Self.take(range, from: &state.written)
            }
            if let now { continuation.resume(returning: now) }
        }
    }

    /// No more names: tar ends its archive once it has sent the last.
    func finish() {
        let first = state.withLock { state in
            defer { state.finished = true }
            return !state.finished
        }
        guard first else { return }
        closeInput()
    }

    /// Closes tar's input once, after the names queued before.
    private func closeInput() {
        let first = state.withLock { state in
            defer { state.inputClosed = true }
            return !state.inputClosed
        }
        guard first else { return }
        let writer = writer
        names.async { try? writer.close() }
    }

    func cancel() {
        if process.isRunning { process.terminate() }
    }

    // MARK: The reader's side

    /// What the next entry is, and the temp to write a taken one into.
    func judge(_ entry: TarBatchPlan.Entry) -> (verdict: TarBatchPlan.Verdict, temp: URL?) {
        state.withLock { state in
            let before = state.plan.next
            let verdict = state.plan.judge(entry)
            for index in before..<min(state.plan.next, state.sizes.count) { state.load -= state.sizes[index] }
            if case .take(let index) = verdict { return (verdict, state.temps[index]) }
            return (verdict, nil)
        }
    }

    /// Entry `index` is written whole. Batches whose files have all been judged are told.
    func wrote(_ index: Int?) {
        let ready = state.withLock { state in
            if let index { state.written.insert(index) }
            let next = state.plan.next
            let ready = state.waiting.filter { $0.range.upperBound <= next }
            state.waiting.removeAll { $0.range.upperBound <= next }
            return ready.map { ($0.continuation, Self.take($0.range, from: &state.written)) }
        }
        for (continuation, written) in ready { continuation.resume(returning: written) }
    }

    /// The stream is over: every batch still waiting has what it got.
    private func end() {
        if process.isRunning { process.terminate() }
        let ready = state.withLock { state in
            state.ended = true
            defer { state.waiting.removeAll() }
            return state.waiting.map { ($0.continuation, Self.take($0.range, from: &state.written)) }
        }
        for (continuation, written) in ready { continuation.resume(returning: written) }
        closeInput()
    }

    /// The files of `range` in `written`, by their place in it, no longer kept there.
    private static func take(_ range: Range<Int>, from written: inout Set<Int>) -> Set<Int> {
        var taken: Set<Int> = []
        for index in range where written.remove(index) != nil { taken.insert(index - range.lowerBound) }
        return taken
    }
}

/// Reads a stream from a descriptor: the marker, then tar entries as the feed judges them, until
/// the archive ends, the stream does, or anything is wrong. A file is written only into the temp
/// the feed names for it, created here and never through a link; one cut short is removed.
struct TarReceiver {
    private let descriptor: Int32
    private var buffer = [UInt8](repeating: 0, count: 256 << 10)
    private var start = 0
    private var end = 0

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    mutating func receive(_ feed: some TarJudge) {
        guard read(SSHConnection.tarMarker.count) == SSHConnection.tarMarker else { return }
        var longName: [UInt8]?
        var pax: [(key: String, value: [UInt8])] = []
        var metadata = 0
        while true {
            guard let block = read(TarFormat.block), case .header(let header)? = TarFormat.parse(block) else { return }
            if header.isMetadata {
                metadata += 1
                guard metadata <= 8, header.size <= UInt64(TarFormat.metadataLimit),
                      let data = read(Int(TarFormat.padded(header.size))).map({ Array($0.prefix(Int(header.size))) }) else { return }
                switch header.type {
                case UInt8(ascii: "L"): longName = data
                case UInt8(ascii: "x"):
                    guard let records = TarFormat.pax(data) else { return }
                    pax += records
                default: break
                }
                continue
            }
            guard let entry = TarBatchPlan.Entry(header, longName: longName, pax: pax) else { return }
            longName = nil
            pax = []
            metadata = 0
            let (verdict, temp) = feed.judge(entry)
            switch verdict {
            case .stop:
                return
            case .pass:
                guard skip(TarFormat.padded(entry.size)) else { return }
                feed.wrote(nil)
            case .take(let index):
                guard let temp, copy(entry.size, into: temp), skip(TarFormat.padded(entry.size) - entry.size) else { return }
                feed.wrote(index)
            }
        }
    }

    /// Writes the next `count` bytes into `file`, which it creates and must not exist. A file cut
    /// short is removed; anything already at its name is left alone.
    private mutating func copy(_ count: UInt64, into file: URL) -> Bool {
        let out = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard out >= 0 else { return false }
        var whole = false
        defer {
            close(out)
            if !whole { unlink(file.path) }
        }
        var left = count
        while left > 0 {
            guard fill() else { return false }
            let chunk = min(UInt64(end - start), left)
            let wrote = buffer.withUnsafeBytes { bytes in
                var done = 0
                while done < Int(chunk) {
                    let n = write(out, bytes.baseAddress! + start + done, Int(chunk) - done)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { return false }
                    done += n
                }
                return true
            }
            guard wrote else { return false }
            start += Int(chunk)
            left -= chunk
        }
        whole = true
        return true
    }

    private mutating func skip(_ count: UInt64) -> Bool {
        var left = count
        while left > 0 {
            guard fill() else { return false }
            let chunk = min(UInt64(end - start), left)
            start += Int(chunk)
            left -= chunk
        }
        return true
    }

    /// Exactly `count` bytes, or nil at the end of the stream.
    private mutating func read(_ count: Int) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(count)
        while out.count < count {
            guard fill() else { return nil }
            let chunk = min(end - start, count - out.count)
            out += buffer[start..<(start + chunk)]
            start += chunk
        }
        return out
    }

    /// Makes at least one byte available; false at the end of the stream or on an error.
    private mutating func fill() -> Bool {
        if start < end { return true }
        start = 0
        end = 0
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            end = n
            return true
        }
    }
}

/// A folder download's small files as the walk settles them (`TarBatchFill`), and its streams.
final class TarBatcher: Sendable {
    typealias Jobs = [SSHConnection.TarJob]
    let feeds: TarFeeds
    private let state = Locked((fill: TarBatchFill(), jobs: Jobs()))

    init(_ session: SSHConnection) {
        feeds = TarFeeds(session)
    }

    /// A folder listed ahead holds `count` small files.
    func foresee(_ count: Int) {
        state.withLock { $0.fill.foresee(count) }
    }

    /// The walk reached a folder listed ahead, of `count` small files.
    func consume(_ count: Int) {
        state.withLock { $0.fill.consume(count) }
    }

    /// The download streams its small files.
    var streaming: Bool { state.value.fill.streaming }

    /// A folder of `count` small files is about to be placed. True when that makes the download
    /// one to stream: the caller keeps the places and starts the streams.
    func begin(_ count: Int) -> Bool {
        state.withLock { $0.fill.begin(count) }
    }

    /// What to do with `job`: nil to fetch it over SFTP now, an empty batch while it is held,
    /// else the batch it closed, for the caller to `submit` (`expect` is done).
    func add(_ job: SSHConnection.TarJob) -> Jobs? {
        let batch = state.withLock { state -> Jobs? in
            switch state.fill.add(size: job.item.size ?? 0) {
            case .sftp:
                return nil
            case .held:
                state.jobs.append(job)
                return []
            case .full:
                defer { state.jobs = [] }
                return state.jobs + [job]
            }
        }
        if let batch, !batch.isEmpty { feeds.expect() }
        return batch
    }

    /// What is held once the walk ends, and whether it goes in a stream (`expect` is done).
    func drain() -> (jobs: Jobs, stream: Bool) {
        let rest = state.withLock { state in
            defer { state.jobs = [] }
            return (jobs: state.jobs, stream: state.fill.streaming)
        }
        if rest.stream, !rest.jobs.isEmpty { feeds.expect() }
        return rest
    }
}
