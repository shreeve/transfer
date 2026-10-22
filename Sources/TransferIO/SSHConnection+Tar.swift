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
    /// these flags, `--no-recursion` and `--null` before the `-T` they apply to. `-P` keeps each
    /// name as sent, so neither prints its warning about leading slashes: standard error carries
    /// nothing but the startup output the probe saw, and a read error.
    static let tarCommandLine = "echo TRANSFER-TAR-1; exec env COPYFILE_DISABLE=1 tar -cf - -P --no-recursion --null -T -"
    static let tarMarker = Array("TRANSFER-TAR-1\n".utf8)

    /// One file of a batch: the listing's item and the name the walk settled for it.
    struct TarJob: Sendable {
        let item: RemoteItem
        let destination: URL
        let replacing: Bool
    }

    /// What the probe learned: whether tar streams as asked, and what the server writes to
    /// standard error for a command that goes right (a shell's startup files may), which a stream
    /// may write too.
    struct TarProbe: Sendable {
        var works: Bool
        var baseline: [UInt8]
    }

    /// Runs `command` with no names. It works when it prints the marker, then an empty archive
    /// (zero blocks only), and exits 0: tar is there, takes the flags, and no startup output gets
    /// in the way. At most 64 KB of its output and 4 KB of its standard error are read, and it
    /// gets 15 s.
    static func probeTar(_ arguments: [String]) async -> TarProbe {
        let failed = TarProbe(works: false, baseline: [])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        let output = Pipe()
        let errors = OutputTail(limit: 4097)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors.pipe
        let exited = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { exited.continuation.yield($0.terminationStatus) }
        do {
            try process.run()
        } catch {
            return failed
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
        await errors.waitForEnd()
        let baseline = errors.bytes
        guard status == 0, bytes.starts(with: tarMarker), baseline.count <= 4096 else { return failed }
        let archive = bytes.dropFirst(tarMarker.count)
        let works = archive.count >= 2 * TarFormat.block && archive.count % TarFormat.block == 0 && archive.allSatisfy { $0 == 0 }
        return TarProbe(works: works, baseline: baseline)
    }

    /// A stream for a download's batches, in a place free now or the next to come free; nil when
    /// tar is off or missing here, or every stream runs already. Its place is given back when its
    /// process ends.
    func startTarFeed() async -> TarFeed? {
        guard let command = tarCommand, let probe = await tarProbeResult(), probe.works,
              let slot = try? await takeTarSlot(waiting: true) else { return nil }
        let feed = TarFeed.start(tarArguments(command), baseline: probe.baseline, stallLimit: tarStallLimit) { [weak self] in
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
    /// still lists it as it was, so tar read it unchanged, and when its stream has said nothing on
    /// standard error. Cancelled, it removes every temp.
    func landTarBatch(_ jobs: [TarJob], temps: [URL], written: Set<Int>, from feed: TarFeed) async throws -> [TarOutcome] {
        let store = store
        var fresh: [Int: Fingerprint] = [:]
        // A read error on the server comes only on standard error, its bytes as zeros.
        let written = feed.isFaulted ? [] : written
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
        guard !feed.isFaulted else { return await Self.landBatch(jobs, temps: temps, written: [], fresh: [:], store: store) }
        let outcomes = await Self.landBatch(jobs, temps: temps, written: written, fresh: fresh, store: store)
        feed.landed(zip(jobs, outcomes).compactMap { job, outcome in
            if case .landed = outcome { return job }
            return nil
        })
        return outcomes
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
        /// Streams that ended or were retired: what they placed is checked once they close.
        var retired: [TarFeed] = []
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
        for _ in 0..<TarBatching.streams { Task { await self.startOne() } }
    }

    /// One stream, counted in `starting` already, once `after` has ended and given back its place.
    private func startOne(after retired: TarFeed? = nil) async {
        await retired?.closed()
        let feed = await session.startTarFeed()
        let (waiting, late) = state.withLock { state -> ([CheckedContinuation<Void, Never>], Bool) in
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
                state.retired += state.feeds.filter { !$0.isOpen }
                state.feeds.removeAll { !$0.isOpen }
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
            guard let range = feed.send(jobs, temps: temps) else { continue }
            // A stream keeps what it placed until it has ended clean, so it ends after so many
            // files and another takes its place.
            if range.upperBound >= TarBatching.streamFiles { retire(feed) }
            return TarTicket(feed: feed, range: range, temps: temps)
        }
        store.forgetTemps(local: temps)
        return nil
    }

    /// `feed` takes no more batches; another stream starts once it has ended.
    private func retire(_ feed: TarFeed) {
        feed.finish()
        let replace = state.withLock { state in
            guard !state.closed, !state.finishing else { return false }
            state.starting += 1
            return true
        }
        if replace { Task { await self.startOne(after: feed) } }
    }

    /// Once every stream has ended: the files placed by a stream that then wrote to standard
    /// error, which may hold a read error's zeros and go again over SFTP.
    func placedByFaultedStreams() async -> [SSHConnection.TarJob] {
        var all: [TarFeed] = []
        while true {
            let (feeds, starting) = state.withLock { ($0.retired + $0.feeds, $0.starting) }
            all = feeds
            if starting == 0 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        var jobs: [SSHConnection.TarJob] = []
        for feed in all {
            await feed.closed()
            jobs += feed.placedIfFaulted
        }
        return jobs
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
    /// Bytes came, so the stream is alive.
    func heard()
}

extension TarJudge {
    func heard() {}
}

/// One `ssh … tar` passenger fed batch after batch: names go to its standard input on a queue of
/// their own, and a reader thread writes each entry its plan takes into that file's temp. Its
/// standard error is watched: anything past the probe's baseline (tar reports a read error only
/// there, padding the file with zeros) faults the stream, which then lands nothing more, and what
/// it placed goes again over SFTP. A stream silent for `stallLimit` while a batch waits on it is
/// stopped, and the batch's files not yet written go over SFTP.
final class TarFeed: TarJudge {
    private struct State {
        var plan = TarBatchPlan(skipLimit: TarBatching.batchBytes)
        /// Temps and sizes of the files from `plan.base` on, as the plan keeps them.
        var temps: [URL] = []
        var sizes: [UInt64] = []
        var written: Set<Int> = []
        /// Every file before this one has been judged and, if taken, written whole.
        var settled = 0
        var waiting: [(range: Range<Int>, continuation: CheckedContinuation<Set<Int>, Never>)] = []
        var ended = false
        var finished = false
        var inputClosed = false
        var faulted = false
        /// Bytes sent and not yet judged, to pick the least loaded stream.
        var load: UInt64 = 0
        var lastHeard = ContinuousClock.now
        /// What the stream's standard error has said, and whether it has closed.
        var errors: [UInt8] = []
        var errorsEnded = false
        var closers: [CheckedContinuation<Void, Never>] = []
        var placed: [SSHConnection.TarJob] = []
    }

    private let process: Process
    private let writer: FileHandle
    private let baseline: [UInt8]
    private let names = DispatchQueue(label: "TarFeed.names", qos: .userInitiated)
    private let state = Locked(State())

    private init(process: Process, writer: FileHandle, baseline: [UInt8]) {
        self.process = process
        self.writer = writer
        self.baseline = baseline
    }

    /// Starts `ssh` with `arguments`, its reader, its standard error's watcher, and its stall
    /// watchdog; `ended` runs once the stream is over.
    static func start(_ arguments: [String], baseline: [UInt8], stallLimit: Duration, ended: @escaping @Sendable () -> Void) -> TarFeed? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A server that stops reading must not end the app with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let feed = TarFeed(process: process, writer: input.fileHandleForWriting, baseline: baseline)
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                feed.errorsEnded()
                return
            }
            feed.said(chunk)
        }
        do {
            try process.run()
        } catch {
            errors.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        let reader = output.fileHandleForReading
        Thread.detachNewThread {
            var receiver = TarReceiver(reader.fileDescriptor)
            receiver.receive(feed)
            try? reader.close()
            feed.end()
            ended()
        }
        Task { await feed.watch(stallLimit) }
        return feed
    }

    var isEnded: Bool { state.value.ended }
    /// Running, and not yet told that no more names come.
    var isOpen: Bool { state.withLock { !$0.ended && !$0.finished } }
    var isFaulted: Bool { state.value.faulted }
    var load: UInt64 { state.value.load }

    /// Queues `jobs`, whose `temps` are recorded: their names go to tar after every name before
    /// them. Nil once the stream has ended or been told no more come.
    func send(_ jobs: [SSHConnection.TarJob], temps: [URL]) -> Range<Int>? {
        state.withLock { state in
            guard !state.ended, !state.finished else { return nil }
            let range = state.plan.end..<(state.plan.end + jobs.count)
            state.plan.append(jobs.map { TarBatchPlan.Expected(path: $0.item.path.bytes, size: $0.item.size ?? 0, mtime: $0.item.mtime ?? 0) })
            state.temps += temps
            state.sizes += jobs.map { $0.item.size ?? 0 }
            state.load += jobs.reduce(0) { $0 + ($1.item.size ?? 0) }
            // Silence is counted from the first batch waiting, not from before it was sent.
            if state.waiting.isEmpty { state.lastHeard = .now }
            // Queued inside the lock, so names go out in the order the plan expects them.
            let bytes = Data(jobs.flatMap { $0.item.path.bytes + [0] })
            let writer = writer
            names.async { try? writer.write(contentsOf: bytes) }
            return range
        }
    }

    /// The files of `range` written whole, by their place in it; none once the stream faulted.
    func written(_ range: Range<Int>) async -> Set<Int> {
        await withCheckedContinuation { continuation in
            let now: Set<Int>? = state.withLock { state in
                guard state.ended || state.settled >= range.upperBound else {
                    state.waiting.append((range, continuation))
                    return nil
                }
                return Self.take(range, from: &state)
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

    /// Returns once the stream has ended and its standard error has closed, or a second after,
    /// which counts as a fault: what it would still say is not known.
    func closed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state in
                guard !(state.ended && state.errorsEnded) else { return true }
                state.closers.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Files a batch of this stream placed: kept until the stream has closed clean.
    func landed(_ jobs: [SSHConnection.TarJob]) {
        state.withLock { state in
            guard state.faulted || !(state.ended && state.errorsEnded) else { return }
            state.placed += jobs
        }
    }

    /// What this stream placed, once it has closed, when it faulted.
    var placedIfFaulted: [SSHConnection.TarJob] {
        state.withLock { $0.faulted ? $0.placed : [] }
    }

    // MARK: Standard error and silence

    private func said(_ chunk: Data) {
        let fault = state.withLock { state -> Bool in
            state.errors += chunk.prefix(8192 - min(state.errors.count, 8192))
            guard !state.faulted, !baseline.starts(with: state.errors) else { return false }
            state.faulted = true
            return true
        }
        if fault { cancel() }
    }

    private func errorsEnded() {
        let closers = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.errorsEnded = true
            guard state.ended else { return [] }
            defer { state.closers = [] }
            return state.closers
        }
        for closer in closers { closer.resume() }
    }

    func heard() {
        state.withLock { $0.lastHeard = .now }
    }

    /// Stops a stream that sends nothing for `limit` while a batch waits on it.
    private func watch(_ limit: Duration) async {
        let tick = min(limit / 4, .seconds(1))
        while true {
            try? await Task.sleep(for: tick)
            let (ended, stalled) = state.withLock { state in
                (state.ended, !state.waiting.isEmpty && ContinuousClock.now - state.lastHeard > limit)
            }
            if ended { return }
            if stalled {
                cancel()
                return
            }
        }
    }

    // MARK: The reader's side

    /// What the next entry is, and the temp to write a taken one into.
    func judge(_ entry: TarBatchPlan.Entry) -> (verdict: TarBatchPlan.Verdict, temp: URL?) {
        state.withLock { state in
            let base = state.plan.base
            let before = state.plan.next
            let verdict = state.plan.judge(entry)
            for index in before..<min(state.plan.next, base + state.sizes.count) { state.load -= state.sizes[index - base] }
            if case .take(let index) = verdict { return (verdict, state.temps[index - base]) }
            return (verdict, nil)
        }
    }

    /// The entry judged last is done with. Batches whose files have all been settled are told,
    /// and what the plan has judged is forgotten.
    func wrote(_ index: Int?) {
        let ready = state.withLock { state in
            if let index { state.written.insert(index) }
            state.settled = state.plan.next
            let settled = state.settled
            let ready = state.waiting.filter { $0.range.upperBound <= settled }
            state.waiting.removeAll { $0.range.upperBound <= settled }
            let results = ready.map { ($0.continuation, Self.take($0.range, from: &state)) }
            let judged = state.plan.next - state.plan.base
            if judged >= 1024 {
                state.plan.forgetJudged()
                state.temps.removeFirst(judged)
                state.sizes.removeFirst(judged)
            }
            return results
        }
        for (continuation, written) in ready { continuation.resume(returning: written) }
    }

    /// The stream is over: every batch still waiting has what it got. ssh is left a second to
    /// exit, so what tar writes to standard error as it ends still comes.
    private func end() {
        let (ready, closers) = state.withLock { state in
            state.ended = true
            defer { state.waiting.removeAll() }
            let ready = state.waiting.map { ($0.continuation, Self.take($0.range, from: &state)) }
            guard state.errorsEnded else { return (ready, [CheckedContinuation<Void, Never>]()) }
            defer { state.closers = [] }
            return (ready, state.closers)
        }
        for (continuation, written) in ready { continuation.resume(returning: written) }
        for closer in closers { closer.resume() }
        closeInput()
        // A standard error that has not closed a second after the stream counts as a fault, and
        // ssh is stopped.
        Task {
            try? await Task.sleep(for: .seconds(1))
            let late = state.withLock { state -> Bool in
                guard !state.errorsEnded else { return false }
                state.faulted = true
                return true
            }
            cancel()
            if late { errorsEnded() }
        }
    }

    /// The files of `range` written whole, by their place in it, no longer kept; none after a
    /// fault.
    private static func take(_ range: Range<Int>, from state: inout State) -> Set<Int> {
        var taken: Set<Int> = []
        for index in range where state.written.remove(index) != nil { taken.insert(index - range.lowerBound) }
        return state.faulted ? [] : taken
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
    private var heard: (() -> Void)?

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    mutating func receive(_ feed: some TarJudge) {
        heard = { feed.heard() }
        defer { heard = nil }
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
            heard?()
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
