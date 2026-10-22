import Testing
import TransferCore

/// Builds tar archives the way GNU tar and bsdtar write them, and the hostile ones they never do.
struct TarBuilder {
    var bytes: [UInt8] = []

    /// A header block. `gnu` uses GNU's magic, whose bytes past the name are not a prefix.
    static func header(_ name: String, size: Int, mtime: Int = 1_700_000_000, type: Character = "0", gnu: Bool = false, prefix: String = "") -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ field: [UInt8], at offset: Int) { for (index, byte) in field.enumerated() { block[offset + index] = byte } }
        func octal(_ value: Int, _ width: Int) -> [UInt8] {
            let digits = String(value, radix: 8)
            return Array((String(repeating: "0", count: max(width - 1 - digits.count, 0)) + digits).utf8) + [0]
        }
        put(Array(name.utf8.prefix(100)), at: 0)
        put(octal(0o644, 8), at: 100)
        put(octal(501, 8), at: 108)
        put(octal(20, 8), at: 116)
        put(octal(size, 12), at: 124)
        put(octal(mtime, 12), at: 136)
        put(Array(repeating: 0x20, count: 8), at: 148)
        block[156] = type.asciiValue!
        put(gnu ? Array("ustar  \0".utf8) : Array("ustar\0".utf8) + Array("00".utf8), at: 257)
        if !gnu { put(Array(prefix.utf8.prefix(155)), at: 345) }
        let sum = block.reduce(0) { $0 + Int($1) }
        put(Array(String(format: "%06o", sum).utf8) + [0, 0x20], at: 148)
        return block
    }

    static func padded(_ data: [UInt8]) -> [UInt8] {
        data + [UInt8](repeating: 0, count: (512 - data.count % 512) % 512)
    }

    mutating func file(_ name: String, _ data: [UInt8], mtime: Int = 1_700_000_000, type: Character = "0", gnu: Bool = false, prefix: String = "") {
        bytes += Self.header(name, size: data.count, mtime: mtime, type: type, gnu: gnu, prefix: prefix) + Self.padded(data)
    }

    /// GNU's long name: a `././@LongLink` entry of type `L` holding the name and a NUL.
    mutating func longName(_ name: String) {
        let data = Array(name.utf8) + [0]
        bytes += Self.header("././@LongLink", size: data.count, type: "L", gnu: true) + Self.padded(data)
    }

    /// A pax extended header for the next entry.
    mutating func pax(_ records: [(String, String)]) {
        var data: [UInt8] = []
        for (key, value) in records {
            let body = " \(key)=\(value)\n"
            var length = body.utf8.count + 1
            while String(length).count + body.utf8.count != length { length += 1 }
            data += Array("\(length)\(body)".utf8)
        }
        bytes += Self.header("PaxHeader/x", size: data.count, type: "x") + Self.padded(data)
    }

    mutating func end() {
        bytes += [UInt8](repeating: 0, count: 1024)
    }
}

private func header(_ block: [UInt8]) -> TarFormat.Header? {
    if case .header(let header)? = TarFormat.parse(block) { return header }
    return nil
}

private func file(_ path: String, size: UInt64 = 5, mtime: UInt32 = 1_700_000_000) -> TarBatchPlan.Expected {
    TarBatchPlan.Expected(path: Array(path.utf8), size: size, mtime: mtime)
}

private func entry(_ name: String, size: UInt64 = 5, mtime: UInt64? = 1_700_000_000, isFile: Bool = true) -> TarBatchPlan.Entry {
    TarBatchPlan.Entry(name: Array(name.utf8), size: size, mtime: mtime, isFile: isFile)
}

@Test func aHeaderIsReadOnlyWithItsChecksumAndMagic() {
    let block = TarBuilder.header("srv/a.txt", size: 1234, mtime: 1_700_000_123)
    let read = header(block)
    #expect(read == TarFormat.Header(name: Array("srv/a.txt".utf8), size: 1234, mtime: 1_700_000_123, type: UInt8(ascii: "0")))
    #expect(read?.isFile == true)
    #expect(TarFormat.parse([UInt8](repeating: 0, count: 512)) == .end)
    var flipped = block
    flipped[3] ^= 0x01
    #expect(TarFormat.parse(flipped) == nil)
    var noMagic = block
    for index in 257..<265 { noMagic[index] = 0 }
    noMagic.replaceSubrange(148..<156, with: Array(repeating: 0x20, count: 8))
    noMagic.replaceSubrange(148..<156, with: Array(String(format: "%06o", noMagic.reduce(0) { $0 + Int($1) }).utf8) + [0, 0x20])
    #expect(TarFormat.parse(noMagic) == nil)
    #expect(TarFormat.parse(Array(block.prefix(511))) == nil)
}

@Test func aPOSIXPrefixIsPartOfTheNameButNotInAGNUHeader() {
    #expect(header(TarBuilder.header("file.txt", size: 1, prefix: "srv/deep"))?.name == Array("srv/deep/file.txt".utf8))
    var gnu = TarBuilder.header("file.txt", size: 1, gnu: true)
    // GNU keeps access and change times where POSIX keeps the prefix.
    gnu.replaceSubrange(345..<357, with: Array("14563425671\0".utf8))
    gnu.replaceSubrange(148..<156, with: Array(repeating: 0x20, count: 8))
    gnu.replaceSubrange(148..<156, with: Array(String(format: "%06o", gnu.reduce(0) { $0 + Int($1) }).utf8) + [0, 0x20])
    #expect(header(gnu)?.name == Array("file.txt".utf8))
}

/// GNU writes a size over 8 GB in base 256; no file of a batch is that large.
@Test func aSizeThatIsNotOctalIsRefused() {
    var block = TarBuilder.header("big", size: 0)
    block.replaceSubrange(124..<136, with: [0x80] + [UInt8](repeating: 0, count: 10) + [0x01])
    block.replaceSubrange(148..<156, with: Array(repeating: 0x20, count: 8))
    block.replaceSubrange(148..<156, with: Array(String(format: "%06o", block.reduce(0) { $0 + Int($1) }).utf8) + [0, 0x20])
    #expect(TarFormat.parse(block) == nil)
}

@Test func paxRecordsAreReadOnlyWhenEachIsWellFormed() {
    let records = TarFormat.pax(Array("16 path=a/b/c.d\n11 size=42\n".utf8))
    #expect(records?.map(\.key) == ["path", "size"])
    #expect(records?.first?.value == Array("a/b/c.d".utf8))
    #expect(TarFormat.pax(Array("99 path=a\n".utf8)) == nil)
    #expect(TarFormat.pax(Array("10 path=ab".utf8)) == nil)
    #expect(TarFormat.pax(Array("x path=a\n".utf8)) == nil)
    #expect(TarFormat.pax(Array("9 patha\n\n".utf8)) == nil)
}

@Test func anEntryTakesItsLongNameAndPaxRecords() throws {
    let block = try #require(header(TarBuilder.header("short", size: 5)))
    #expect(TarBatchPlan.Entry(block, longName: Array("a/very/long/name\0".utf8), pax: [])?.name == Array("a/very/long/name".utf8))
    let pax = try #require(TarFormat.pax(Array("12 path=p/q\n10 size=7\n23 mtime=1700000001.75\n".utf8)))
    let amended = TarBatchPlan.Entry(block, longName: Array("ignored".utf8), pax: pax)
    #expect(amended == TarBatchPlan.Entry(name: Array("p/q".utf8), size: 7, mtime: 1_700_000_001, isFile: true))
    #expect(TarBatchPlan.Entry(block, longName: nil, pax: [("GNU.sparse.map", Array("0,5".utf8))])?.unreadable == true)
    #expect(TarBatchPlan.Entry(block, longName: nil, pax: [("size", Array("-1".utf8))]) == nil)
}

@Test func aPlanTakesTheExpectedFilesInOrderAndPassesOverOnesTarSkipped() {
    var plan = TarBatchPlan([file("/srv/a"), file("/srv/b"), file("/srv/c")], skipLimit: 1 << 20)
    #expect(plan.judge(entry("srv/a")) == .take(0))
    // tar could not read b: c comes next, and b goes over SFTP.
    #expect(plan.judge(entry("srv/c")) == .take(2))
    #expect(plan.isDone)
    // Nothing comes back around.
    var again = TarBatchPlan([file("/srv/a"), file("/srv/b")], skipLimit: 1 << 20)
    #expect(again.judge(entry("srv/b")) == .take(1))
    #expect(again.judge(entry("srv/a")) == .stop)
}

@Test func aPlanTakesOnlyARegularFileOfTheListedSizeAndTime() {
    var plan = TarBatchPlan([file("/a"), file("/b"), file("/c"), file("/d"), file("/e")], skipLimit: 100)
    #expect(plan.judge(entry("a", size: 6)) == .pass(0))
    #expect(plan.judge(entry("b", mtime: 1_700_000_001)) == .pass(1))
    #expect(plan.judge(entry("c", size: 0, isFile: false)) == .pass(2))
    #expect(plan.judge(TarBatchPlan.Entry(name: Array("d".utf8), size: 5, mtime: 1_700_000_000, isFile: true, unreadable: true)) == .pass(3))
    // More bytes than any batch asks for is not a tar of these files.
    #expect(plan.judge(entry("e", size: 101)) == .stop)
}

/// The stream's names only say which expected file an entry is; one that is not exactly an
/// expected member name, as tar stores it, ends the stream.
@Test func aPlanStopsAtAnyNameNotExpected() {
    for hostile in ["/srv/a", "../srv/a", "srv/a/", "srv//a", "srv/./a", "SRV/a", "srv/a\0x", "elsewhere"] {
        var plan = TarBatchPlan([file("/srv/a")], skipLimit: 1 << 20)
        #expect(plan.judge(entry(hostile)) == .stop, "\(hostile)")
    }
    var plan = TarBatchPlan([file("//srv/a")], skipLimit: 1 << 20)
    #expect(plan.judge(entry("srv/a")) == .take(0))
}

@Test func aPlanGrowsBatchByBatch() {
    var plan = TarBatchPlan(skipLimit: 1 << 20)
    plan.append([file("/a")])
    #expect(plan.judge(entry("a")) == .take(0))
    #expect(plan.isDone)
    plan.append([file("/b"), file("/c")])
    #expect(!plan.isDone)
    #expect(plan.judge(entry("c")) == .take(2))
    #expect(plan.next == 3)
}

@Test func aDownloadsFirstSmallFilesGoOverSFTPThenFillBatches() {
    var fill = TarBatchFill()
    for _ in 0..<TarBatching.sftpFirst { #expect(fill.add(size: 100) == .sftp) }
    for _ in 1..<TarBatching.batchFiles { #expect(fill.add(size: 100) == .held) }
    #expect(!fill.sent)
    #expect(fill.add(size: 100) == .full)
    #expect(fill.sent)
    // A batch also closes on its bytes.
    #expect(fill.add(size: TarBatching.batchBytes - 1) == .held)
    #expect(fill.add(size: 1) == .full)
}

@Test func onlySmallFilesOfAKnownSizeAndTimeAreBatched() {
    #expect(TarBatching.takes(size: 0, mtime: 1))
    #expect(TarBatching.takes(size: TarBatching.fileLimit, mtime: 1))
    #expect(!TarBatching.takes(size: TarBatching.fileLimit + 1, mtime: 1))
    #expect(!TarBatching.takes(size: nil, mtime: 1))
    #expect(!TarBatching.takes(size: 10, mtime: nil))
}

@Test func paddingIsWholeBlocks() {
    #expect(TarFormat.padded(0) == 0)
    #expect(TarFormat.padded(1) == 512)
    #expect(TarFormat.padded(512) == 512)
    #expect(TarFormat.padded(513) == 1024)
}
