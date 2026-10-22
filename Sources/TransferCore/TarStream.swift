/// The tar archive a folder download streams its small files in (`SSHConnection+Tar.swift`). The
/// server and its `tar` are untrusted, so these rules decide what of the stream may land: only a
/// regular file whose name, size, and time are exactly those of the next files the walk asked
/// for, in the order it asked. Everything else is skipped (that file goes over SFTP) or ends the
/// stream (every file not yet landed goes over SFTP). Names from the stream never choose where a
/// file lands: the walk placed each file before its name was sent.
public enum TarFormat {
    public static let block = 512
    /// The largest long name or pax header read. A path is at most a few KB on any server.
    public static let metadataLimit = 64 << 10

    /// One header block, with its name as the block gives it: a long name or pax `path` before it
    /// replaces that (`TarBatchPlan.Entry`).
    public struct Header: Equatable, Sendable {
        public var name: [UInt8]
        public var size: UInt64
        public var mtime: UInt64?
        public var type: UInt8

        public init(name: [UInt8], size: UInt64, mtime: UInt64?, type: UInt8) {
            self.name = name
            self.size = size
            self.mtime = mtime
            self.type = type
        }

        /// A regular file: `0`, or NUL in archives older than POSIX.
        public var isFile: Bool { type == UInt8(ascii: "0") || type == 0 }
        /// A header that describes the next one: a pax extended header (`x`), a pax global one
        /// (`g`), or GNU's long name (`L`) or long link target (`K`).
        public var isMetadata: Bool { [UInt8(ascii: "x"), UInt8(ascii: "g"), UInt8(ascii: "L"), UInt8(ascii: "K")].contains(type) }
    }

    public enum Block: Equatable, Sendable {
        /// A block of zeros: the archive ends.
        case end
        case header(Header)
    }

    /// The block's header, `.end` for a zero block, or nil for anything that is not a valid
    /// ustar or GNU header: a wrong checksum or magic, or a size or time not in octal.
    public static func parse(_ block: [UInt8]) -> Block? {
        guard block.count == Self.block else { return nil }
        if block.allSatisfy({ $0 == 0 }) { return .end }
        guard let sum = octal(block[148..<156]) else { return nil }
        var unsigned = 0
        var signed = 0
        for (index, byte) in block.enumerated() {
            let value = (148..<156).contains(index) ? 0x20 : byte
            unsigned += Int(value)
            signed += Int(Int8(bitPattern: value))
        }
        guard sum == UInt64(unsigned) || Int(sum) == signed else { return nil }
        let magic = Array(block[257..<263])
        let posix = magic == Array("ustar\0".utf8)
        let gnu = magic == Array("ustar ".utf8) && block[263] == 0x20 && block[264] == 0
        guard posix || gnu else { return nil }
        guard let size = octal(block[124..<136]) else { return nil }
        var name = field(block[0..<100])
        if posix {
            let prefix = field(block[345..<500])
            if !prefix.isEmpty { name = prefix + [UInt8(ascii: "/")] + name }
        }
        return .header(Header(name: name, size: size, mtime: octal(block[136..<148]), type: block[156]))
    }

    /// Bytes `size` takes in the archive, whole blocks.
    public static func padded(_ size: UInt64) -> UInt64 {
        (size + UInt64(block) - 1) / UInt64(block) * UInt64(block)
    }

    /// A pax extended header's records, `length key=value\n` each, or nil when any is malformed.
    public static func pax(_ data: [UInt8]) -> [(key: String, value: [UInt8])]? {
        var records: [(key: String, value: [UInt8])] = []
        var at = 0
        while at < data.count {
            guard let space = data[at...].firstIndex(of: 0x20), space > at, space - at <= 8 else { return nil }
            guard let digits = String(validating: data[at..<space], as: UTF8.self), let length = Int(digits),
                  length > space - at + 1, at + length <= data.count, data[at + length - 1] == 0x0A else { return nil }
            let record = data[(space + 1)..<(at + length - 1)]
            guard let equals = record.firstIndex(of: UInt8(ascii: "=")),
                  let key = String(validating: record[record.startIndex..<equals], as: UTF8.self) else { return nil }
            records.append((key, Array(record[(equals + 1)...])))
            at += length
        }
        return records
    }

    /// A NUL-terminated field.
    private static func field(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        Array(bytes.prefix { $0 != 0 })
    }

    /// An octal field: optional leading spaces, digits, then NUL or spaces. Base-256 (GNU's for
    /// large values) and anything else is nil.
    static func octal(_ bytes: ArraySlice<UInt8>) -> UInt64? {
        var digits = bytes.drop { $0 == 0x20 }
        if let end = digits.firstIndex(where: { $0 == 0 || $0 == 0x20 }) {
            guard digits[end...].allSatisfy({ $0 == 0 || $0 == 0x20 }) else { return nil }
            digits = digits[..<end]
        }
        guard !digits.isEmpty, digits.count <= 21 else { return nil }
        var value: UInt64 = 0
        for digit in digits {
            guard (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { return nil }
            value = value << 3 | UInt64(digit - UInt8(ascii: "0"))
        }
        return value
    }
}

/// One batch of a download's tar stream: the files whose names were sent, in that order, and
/// what each entry of the stream means for them.
public struct TarBatchPlan: Sendable {
    public struct Expected: Equatable, Sendable {
        /// The server path as sent, an absolute path.
        public var path: [UInt8]
        public var size: UInt64
        public var mtime: UInt32

        public init(path: [UInt8], size: UInt64, mtime: UInt32) {
            self.path = path
            self.size = size
            self.mtime = mtime
        }

        /// The member name tar gives the path: the path itself, as both tars store it with
        /// `-P`, which also keeps them from warning on standard error that they stripped it.
        var member: [UInt8] { path }
    }

    /// An entry with what its metadata headers said: a pax `path` or `size`, or a GNU long name.
    public struct Entry: Equatable, Sendable {
        public var name: [UInt8]
        public var size: UInt64
        public var mtime: UInt64?
        public var isFile: Bool
        /// A pax header said something this plan cannot check, such as a sparse map: the bytes in
        /// the stream would not be the file's.
        public var unreadable: Bool

        public init(name: [UInt8], size: UInt64, mtime: UInt64?, isFile: Bool, unreadable: Bool = false) {
            self.name = name
            self.size = size
            self.mtime = mtime
            self.isFile = isFile
            self.unreadable = unreadable
        }

        /// `header` as its metadata headers amend it: a GNU long name (`L`), and pax records,
        /// which win. Nil when a record that matters is malformed.
        public init?(_ header: TarFormat.Header, longName: [UInt8]?, pax: [(key: String, value: [UInt8])]) {
            var entry = Entry(name: longName.map { Array($0.prefix { $0 != 0 }) } ?? header.name, size: header.size, mtime: header.mtime, isFile: header.isFile)
            for (key, value) in pax {
                switch key {
                case "path":
                    entry.name = value
                case "size":
                    guard let text = String(validating: value, as: UTF8.self), let size = UInt64(text) else { return nil }
                    entry.size = size
                case "mtime":
                    // Seconds, perhaps with a fraction: the listing has whole seconds.
                    guard let text = String(validating: value, as: UTF8.self),
                          let seconds = UInt64(text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") else { return nil }
                    entry.mtime = seconds
                default:
                    if key.hasPrefix("GNU.sparse") { entry.unreadable = true }
                }
            }
            self = entry
        }
    }

    public enum Verdict: Equatable, Sendable {
        /// Write the entry's bytes as expected file `index`.
        case take(Int)
        /// Skip the entry's bytes; it names expected file `index`, which goes over SFTP.
        case pass(Int)
        /// Stop reading: the stream is not what was asked for.
        case stop
    }

    /// The files whose names were sent and are not yet judged, in order, from `base`: a stream
    /// takes batch after batch, and forgets each file once it is judged (`forgetJudged`).
    public private(set) var expected: [Expected]
    /// The index of `expected`'s first file among all the files sent.
    public private(set) var base = 0
    /// The next expected file the stream may still send, by its index among all sent. Those
    /// before it that it never sent (tar could not read them, or they went away) go over SFTP.
    public private(set) var next = 0
    /// One past the last file sent, by index.
    public var end: Int { base + expected.count }
    /// The most a skipped entry may hold: more than any batch asks for is not a tar of these files.
    public let skipLimit: UInt64

    public init(_ expected: [Expected] = [], skipLimit: UInt64) {
        self.expected = expected
        self.skipLimit = skipLimit
    }

    /// Files whose names are sent next, after those already expected.
    public mutating func append(_ more: [Expected]) {
        expected += more
    }

    /// Every expected file has had its entry, or been passed over.
    public var isDone: Bool { next >= end }

    /// Forgets the files already judged, so a stream of a million files keeps only those to come.
    public mutating func forgetJudged() {
        expected.removeFirst(next - base)
        base = next
    }

    /// What `entry` means. Its name must be that of an expected file at or after `next`: tar sends
    /// names in the order it reads them and skips only one it cannot read. That file is taken only
    /// when it is a regular file of the listed size and time.
    public mutating func judge(_ entry: Entry) -> Verdict {
        guard let found = expected[(next - base)...].firstIndex(where: { $0.member == entry.name }) else { return .stop }
        let index = base + found
        next = index + 1
        let file = expected[found]
        if entry.isFile, !entry.unreadable, entry.size == file.size, entry.mtime == UInt64(file.mtime) { return .take(index) }
        return entry.size <= skipLimit ? .pass(index) : .stop
    }
}

/// Which files of a folder download go in tar batches, and how many to a batch. Measured at 20
/// and 80 ms round trip against SFTP with the bench (HANDOFF.md, "Transfers").
public enum TarBatching {
    /// Files at most this large go in batches: there a file costs SFTP round trips, not bytes
    /// (400 files of 32 KB at 20 ms: 321 ms streamed, 378 over SFTP). At 64 KB the two tie or SFTP
    /// wins (200 files: 279 and 271 ms), since a stream moves one file at a time.
    public static let fileLimit: UInt64 = 32 << 10
    /// A batch closes at this many files or `batchBytes`, whichever comes first: small enough
    /// that the walk's first files are on their way early, large enough that its one commit of
    /// temps and its burst of checks are shared by many files (64 and 1 MB beat 128 and 4 MB,
    /// and 256, at both sizes of file).
    public static let batchFiles = 64
    public static let batchBytes: UInt64 = 1 << 20
    /// Streams at once, each a session on the master in place of a data channel. Six were no
    /// faster than four.
    public static let streams = 4
    /// A stream takes no more batches after this many files, and another takes its place: it
    /// keeps what it placed until it has closed clean, in case a read error comes later.
    public static let streamFiles = 20_000
    /// A download streams only once this many small files are to come: below it, a stream's start
    /// costs about what SFTP takes for them. At 150 a stream was never slower in the bench (one
    /// folder of 150 at 20 ms: 191 ms streamed, 200 over SFTP; at 80 ms, 610 and 689) and below it
    /// no stream starts.
    public static let minimumFiles = 150
    /// A folder listed as it is walked, not read ahead, sends this many small files over SFTP as
    /// their names arrive, one round of the data pool (seven channels of 16), before the rest
    /// waits for the listing's end to be counted: holding a flat folder of 100 cost 5 to 7 ms at
    /// 20 ms, and with 112 sent at once a folder of 150 or fewer took what SFTP alone takes.
    public static let sftpFirst = 112

    /// Whether a file of the listing may go in a batch: its size and time are known, since the
    /// stream's entry is checked against both, and it is small.
    public static func takes(size: UInt64?, mtime: UInt32?) -> Bool {
        guard let size, mtime != nil else { return false }
        return size <= fileLimit
    }
}

/// One folder download's small files as the walk settles them. A folder's files are placed once
/// its whole listing is in, so the download knows how many small files are still to come: that
/// folder's, and those of the folders listed ahead of it (`foresee`, `consume`). It streams once
/// they reach `minimumFiles`, and from then on: its small files are held until a batch is full,
/// and files held at the walk's end go in a stream too. Until then each goes over SFTP at once,
/// held for nothing, so a download too small to gain never waits for a stream to start.
public struct TarBatchFill: Sendable {
    public enum Step: Equatable, Sendable {
        /// Over SFTP now.
        case sftp
        /// Held for the batch.
        case held
        /// Held, and the batch is full: send it.
        case full
    }

    /// Small files in folders listed ahead and not yet begun.
    private var pending = 0
    private var held = 0
    private var bytes: UInt64 = 0
    /// Enough small files were to come: they go in batches.
    public private(set) var streaming = false

    public init() {}

    /// A folder listed ahead holds `count` small files.
    public mutating func foresee(_ count: Int) {
        pending += count
    }

    /// The walk reached a folder listed ahead, of `count` small files: they are its own now.
    public mutating func consume(_ count: Int) {
        pending = max(pending - count, 0)
    }

    /// A folder of `count` small files is about to be placed. True when the download now streams:
    /// the streams should start.
    public mutating func begin(_ count: Int) -> Bool {
        guard !streaming, count + pending >= TarBatching.minimumFiles else { return false }
        streaming = true
        return true
    }

    /// A small file of `size` bytes, settled.
    public mutating func add(size: UInt64) -> Step {
        guard streaming else { return .sftp }
        held += 1
        bytes += size
        guard held >= TarBatching.batchFiles || bytes >= TarBatching.batchBytes else { return .held }
        held = 0
        bytes = 0
        return .full
    }
}
