import Darwin
import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// `TarReceiver` with no server: streams this Mac's own tar writes, and the ones a hostile or
/// broken server could send instead. Only an entry its plan takes is written, only into the temp
/// named for it, and a file cut short is removed.
struct TarReceiverTests {
    /// A plan over `paths`, each with its own temp in `folder`.
    final class Judge: TarJudge, @unchecked Sendable {
        let temps: [URL]
        private let plan: Locked<TarBatchPlan>
        let written = Locked<[Int]>([])

        init(_ expected: [TarBatchPlan.Expected], in folder: URL) {
            plan = Locked(TarBatchPlan(expected, skipLimit: 1 << 20))
            temps = expected.indices.map { folder.appendingPathComponent(".temp-\($0)") }
        }

        func judge(_ entry: TarBatchPlan.Entry) -> (verdict: TarBatchPlan.Verdict, temp: URL?) {
            let verdict = plan.withLock { $0.judge(entry) }
            if case .take(let index) = verdict { return (verdict, temps[index]) }
            return (verdict, nil)
        }

        func wrote(_ index: Int?) {
            if let index { written.withLock { $0.append(index) } }
        }
    }

    private func scratch(_ name: String) throws -> URL {
        let base = TestCaches.fresh(name)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Runs a receiver over `stream`, written to a pipe as a server's would arrive.
    private func receive(_ stream: [UInt8], _ judge: Judge) {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global().async {
            try? writer.write(contentsOf: Data(stream))
            try? writer.close()
        }
        var receiver = TarReceiver(pipe.fileHandleForReading.fileDescriptor)
        receiver.receive(judge)
        try? pipe.fileHandleForReading.close()
    }

    private static let marker = SSHConnection.tarMarker
    private static let time = 1_700_000_000

    private func expected(_ path: String, _ size: Int) -> TarBatchPlan.Expected {
        TarBatchPlan.Expected(path: Array(path.utf8), size: UInt64(size), mtime: UInt32(Self.time))
    }

    /// bsdtar, as a Mac or FreeBSD server runs it, with names long enough for a pax header.
    @Test func aStreamFromThisMacsTarLandsEveryFile() throws {
        let base = try scratch("tarlocal")
        defer { try? FileManager.default.removeItem(at: base) }
        let deep = base.appendingPathComponent(String(repeating: "deep-folder-name/", count: 8), isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let files = [base.appendingPathComponent("a.txt"), deep.appendingPathComponent(String(repeating: "long", count: 40) + ".txt"), base.appendingPathComponent("empty")]
        let contents = [Data("alpha".utf8), Data((0..<5000).map { UInt8($0 % 251) }), Data()]
        for (url, data) in zip(files, contents) {
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(Self.time))], ofItemAtPath: url.path)
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", "-", "-P", "--no-recursion", "--null", "-T", "-"]
        tar.environment = ["COPYFILE_DISABLE": "1"]
        let input = Pipe()
        let output = Pipe()
        tar.standardInput = input
        tar.standardOutput = output
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        try input.fileHandleForWriting.write(contentsOf: Data(files.flatMap { Array($0.path.utf8) + [0] }))
        try input.fileHandleForWriting.close()
        let archive = try output.fileHandleForReading.readToEnd() ?? Data()
        tar.waitUntilExit()

        let judge = Judge(zip(files, contents).map { expected($0.path, $1.count) }, in: base)
        receive(Self.marker + Array(archive), judge)
        #expect(judge.written.value == [0, 1, 2])
        for (temp, data) in zip(judge.temps, contents) { #expect(try Data(contentsOf: temp) == data) }
    }

    @Test func GNULongNamesAndPaxPathsAreRead() throws {
        let base = try scratch("targnu")
        defer { try? FileManager.default.removeItem(at: base) }
        let long = "/srv/" + String(repeating: "x", count: 150)
        var stream = TarStreamBytes()
        stream.longName(long)
        stream.file("././@LongLink", Array("one".utf8), gnu: true)
        stream.pax([("path", "/srv/second")])
        stream.file("PaxHeader-ignored", Array("two".utf8))
        stream.end()
        let judge = Judge([expected(long, 3), expected("/srv/second", 3)], in: base)
        receive(Self.marker + stream.bytes, judge)
        #expect(judge.written.value == [0, 1])
        #expect(try Data(contentsOf: judge.temps[1]) == Data("two".utf8))
    }

    /// A shell startup file that prints is never read as the archive.
    @Test func outputBeforeTheMarkerIsNeverRead() throws {
        let base = try scratch("tarbanner")
        defer { try? FileManager.default.removeItem(at: base) }
        var stream = TarStreamBytes()
        stream.file("/srv/a", Array("alpha".utf8))
        stream.end()
        let judge = Judge([expected("/srv/a", 5)], in: base)
        receive(Array("Welcome!\n".utf8) + Self.marker + stream.bytes, judge)
        #expect(judge.written.value.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: judge.temps[0].path))
    }

    @Test func anEntryCutShortIsRemoved() throws {
        let base = try scratch("tarshort")
        defer { try? FileManager.default.removeItem(at: base) }
        var stream = TarStreamBytes()
        stream.file("/srv/a", Array("alpha".utf8))
        stream.bytes += TarStreamBytes.header("/srv/b", size: 4000) + [UInt8](repeating: 7, count: 1000)
        let judge = Judge([expected("/srv/a", 5), expected("/srv/b", 4000)], in: base)
        receive(Self.marker + stream.bytes, judge)
        #expect(judge.written.value == [0])
        #expect(!FileManager.default.fileExists(atPath: judge.temps[1].path))
    }

    /// A link, a hard link, or a device named as an expected file is never written; the files
    /// after it still are.
    @Test func anEntryThatIsNotARegularFileIsPassedOver() throws {
        let base = try scratch("tarlink")
        defer { try? FileManager.default.removeItem(at: base) }
        var stream = TarStreamBytes()
        stream.file("/srv/a", [], type: "2")
        stream.file("/srv/b", [], type: "1")
        stream.file("/srv/c", [], type: "3")
        stream.file("/srv/d", Array("delta".utf8))
        stream.end()
        let judge = Judge([expected("/srv/a", 0), expected("/srv/b", 0), expected("/srv/c", 0), expected("/srv/d", 5)], in: base)
        receive(Self.marker + stream.bytes, judge)
        #expect(judge.written.value == [3])
        for temp in judge.temps.prefix(3) { #expect(!FileManager.default.fileExists(atPath: temp.path)) }
    }

    /// Names that would reach outside, or that were never asked for, end the stream: nothing
    /// after them is written, not even an expected file.
    @Test func anUnexpectedNameEndsTheStream() throws {
        let base = try scratch("tarname")
        defer { try? FileManager.default.removeItem(at: base) }
        for hostile in ["../../Library/LaunchAgents/evil.plist", "srv/a", "/srv/other"] {
            var stream = TarStreamBytes()
            stream.file(hostile, Array("evil!".utf8))
            stream.file("/srv/a", Array("alpha".utf8))
            stream.end()
            let judge = Judge([expected("/srv/a", 5)], in: base)
            receive(Self.marker + stream.bytes, judge)
            #expect(judge.written.value.isEmpty, "\(hostile)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
        }
    }

    @Test func aGarbledOrBoundlessHeaderEndsTheStream() throws {
        let base = try scratch("targarbled")
        defer { try? FileManager.default.removeItem(at: base) }
        var bad = TarStreamBytes.header("/srv/a", size: 5)
        bad[0] ^= 0x01
        var huge = TarStreamBytes.header("PaxHeader/x", size: 1 << 20, type: "x")
        huge += [UInt8](repeating: 0x41, count: 4096)
        var random = [UInt8](repeating: 0, count: 4096)
        arc4random_buf(&random, random.count)
        for stream in [bad + TarStreamBytes.padded(Array("alpha".utf8)), huge, random] {
            let judge = Judge([expected("/srv/a", 5)], in: base)
            receive(Self.marker + stream, judge)
            #expect(judge.written.value.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
        }
    }

    /// Something already at a temp's name is left alone, and the stream ends.
    @Test func aTempNameAlreadyTakenIsNeitherFollowedNorRemoved() throws {
        let base = try scratch("tartaken")
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        let judge = Judge([expected("/srv/a", 5)], in: base)
        try FileManager.default.createSymbolicLink(atPath: judge.temps[0].path, withDestinationPath: target.path)
        var stream = TarStreamBytes()
        stream.file("/srv/a", Array("alpha".utf8))
        stream.end()
        receive(Self.marker + stream.bytes, judge)
        #expect(judge.written.value.isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: judge.temps[0].path) == target.path)
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
    }
}

/// The tar blocks GNU tar and bsdtar write, and broken ones (as `TarBuilder` in the Core tests).
struct TarStreamBytes {
    var bytes: [UInt8] = []

    static func header(_ name: String, size: Int, mtime: Int = 1_700_000_000, type: Character = "0", gnu: Bool = false) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ field: [UInt8], at offset: Int) { for (index, byte) in field.enumerated() { block[offset + index] = byte } }
        func octal(_ value: Int, _ width: Int) -> [UInt8] {
            let digits = String(value, radix: 8)
            return Array((String(repeating: "0", count: max(width - 1 - digits.count, 0)) + digits).utf8) + [0]
        }
        put(Array(name.utf8.prefix(100)), at: 0)
        put(octal(0o644, 8), at: 100)
        put(octal(size, 12), at: 124)
        put(octal(mtime, 12), at: 136)
        put(Array(repeating: 0x20, count: 8), at: 148)
        block[156] = type.asciiValue!
        put(gnu ? Array("ustar  \0".utf8) : Array("ustar\0".utf8) + Array("00".utf8), at: 257)
        let sum = block.reduce(0) { $0 + Int($1) }
        put(Array(String(format: "%06o", sum).utf8) + [0, 0x20], at: 148)
        return block
    }

    static func padded(_ data: [UInt8]) -> [UInt8] {
        data + [UInt8](repeating: 0, count: (512 - data.count % 512) % 512)
    }

    mutating func file(_ name: String, _ data: [UInt8], type: Character = "0", gnu: Bool = false) {
        bytes += Self.header(name, size: data.count, type: type, gnu: gnu) + Self.padded(data)
    }

    mutating func longName(_ name: String) {
        let data = Array(name.utf8) + [0]
        bytes += Self.header("././@LongLink", size: data.count, type: "L", gnu: true) + Self.padded(data)
    }

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
