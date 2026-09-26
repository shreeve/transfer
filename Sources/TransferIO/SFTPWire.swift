import Foundation
import TransferCore

/// The SFTP version 3 codec: message codes, attributes, packet framing, and a reader that checks
/// every length against the bytes it has. The server's bytes are untrusted; `SFTPChannel` speaks
/// the protocol with these pieces.
enum SFTPCode {
    // Requests, and VERSION.
    static let initialize: UInt8 = 1, version: UInt8 = 2, open: UInt8 = 3, close: UInt8 = 4, read: UInt8 = 5
    static let write: UInt8 = 6, lstat: UInt8 = 7, fstat: UInt8 = 8, setstat: UInt8 = 9, fsetstat: UInt8 = 10
    static let opendir: UInt8 = 11, readdir: UInt8 = 12, remove: UInt8 = 13, mkdir: UInt8 = 14, rmdir: UInt8 = 15
    static let realpath: UInt8 = 16, rename: UInt8 = 18, readlink: UInt8 = 19, symlink: UInt8 = 20, extended: UInt8 = 200
    // Replies.
    static let status: UInt8 = 101, handle: UInt8 = 102, data: UInt8 = 103, name: UInt8 = 104, attrs: UInt8 = 105
    // STATUS codes.
    static let ok: UInt32 = 0, eof: UInt32 = 1, noSuchFile: UInt32 = 2, permission: UInt32 = 3, failure: UInt32 = 4
    // ATTRS flags, and OPEN's.
    static let attrSize: UInt32 = 0x1, attrUID: UInt32 = 0x2, attrPerms: UInt32 = 0x4, attrTime: UInt32 = 0x8
    static let attrExtended: UInt32 = 0x8000_0000
    static let fxRead: UInt32 = 0x1, fxWrite: UInt32 = 0x2, fxCreat: UInt32 = 0x8, fxTrunc: UInt32 = 0x10
}

struct SFTPAttrs: Equatable {
    var size: UInt64?
    var uid: UInt32?
    var gid: UInt32?
    var permissions: UInt32?
    var atime: UInt32?
    var mtime: UInt32?

    var kind: ItemKind {
        guard let permissions else { return .file }
        switch permissions & 0o170000 {
        case 0o040000: return .directory
        case 0o120000: return .symlink
        case 0o100000: return .file
        default: return .other
        }
    }

    /// What a copy sets on the file it wrote: a mode, and a time for both access and change.
    static func stamp(mode: UInt32?, mtime: UInt32?) -> SFTPAttrs {
        SFTPAttrs(permissions: mode, atime: mtime, mtime: mtime)
    }

    func encoded() -> Data {
        var out = Data()
        out.appendAttrs(self)
        return out
    }
}

struct SFTPMessage {
    var type: UInt8
    var rest: Data
}

enum SFTPWire {
    /// One packet: its length, `type`, and the fields `build` appends, built in one buffer so a
    /// 64 KB WRITE's bytes are copied once. `capacity` is a hint for the whole packet.
    static func packet(type: UInt8, capacity: Int = 64, _ build: (inout Data) -> Void) -> Data {
        var packet = Data(capacity: capacity)
        packet.append(contentsOf: [0, 0, 0, 0, type])
        build(&packet)
        let length = UInt32(packet.count - 4).bigEndian
        withUnsafeBytes(of: length) { packet.replaceSubrange(0..<4, with: $0) }
        return packet
    }

    /// The longest packet accepted, as in OpenSSH's own client (SFTP_MAX_MSG_LENGTH). The largest
    /// reply this app asks for is a 64 KB READ; a longer length is garbage or hostile, and waiting
    /// for that many bytes would buffer without bound.
    static let maxPacket = 256 * 1024

    /// A frame that cannot be SFTP: a length of zero or over `maxPacket`, a reply too short to
    /// hold its id, or anything but VERSION first.
    struct BadFrame: Error {}

    /// Cuts the server's byte stream into packets. A packet that arrives whole within one read is
    /// a slice of that read, not a copy; only a packet split across reads is copied, once, as it
    /// is put together. A length of zero or over `maxPacket` throws `BadFrame`.
    struct Frames {
        /// A packet that has begun to arrive; empty between packets.
        private var partial = Data()
        /// The latest read, taken from `offset` on.
        private var read = Data()
        private var offset = 0

        /// Adds the next read. Call `next` until it returns nil before adding another.
        mutating func append(_ bytes: Data) {
            read = bytes
            offset = bytes.startIndex
        }

        /// What has arrived and not been taken, for an error message.
        var unread: Data { partial + read[offset...] }

        /// The next whole packet, or nil until more has arrived.
        mutating func next() throws -> SFTPMessage? {
            if partial.isEmpty {
                let available = read.endIndex - offset
                guard available > 0 else { return nil }
                if available >= 4 {
                    let total = try Self.total(read[offset..<offset + 4])
                    if available >= total {
                        defer { offset += total }
                        return Self.message(read[offset..<offset + total])
                    }
                    partial.reserveCapacity(total)
                }
                take(available)
                return nil
            }
            if partial.count < 4 {
                take(min(4 - partial.count, read.endIndex - offset))
                if partial.count < 4 { return nil }
            }
            let total = try Self.total(partial.prefix(4))
            take(min(total - partial.count, read.endIndex - offset))
            guard partial.count == total else { return nil }
            defer { partial = Data() }
            return Self.message(partial)
        }

        private mutating func take(_ count: Int) {
            partial.append(read[offset..<offset + count])
            offset += count
        }

        private static func total(_ header: Data) throws -> Int {
            let length = Int(header.loadU32())
            guard length > 0, length <= maxPacket else { throw BadFrame() }
            return 4 + length
        }

        private static func message(_ packet: Data) -> SFTPMessage {
            let type = packet.startIndex + 4
            return SFTPMessage(type: packet[type], rest: packet[(type + 1)...])
        }
    }

    /// Why a channel's first bytes were not SFTP, for the person connecting. Usually the server's
    /// shell printed text as it started (an `echo` in .bashrc), and its first four characters read
    /// as a length of hundreds of megabytes. A real frame's first byte is zero.
    static func notSFTP(_ bytes: Data) -> String {
        let firstLine = String(decoding: bytes.prefix(200), as: UTF8.self).split(whereSeparator: \.isNewline).first ?? ""
        let shown = printable(firstLine, limit: 60)
        guard bytes.first != 0, !shown.isEmpty else { return "The server did not answer in SFTP" }
        return "The server printed “\(shown)” before SFTP started. Remove that output from the shell startup files on the server, such as .bashrc."
    }

    /// A server's `text` fit to show: without control or format characters (line breaks, bidi
    /// overrides), trimmed, and cut to `limit` characters.
    static func printable(_ text: some StringProtocol, limit: Int) -> String {
        let kept = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            ![.control, .format].contains($0.properties.generalCategory)
        })).trimmingCharacters(in: .whitespaces)
        return kept.count > limit ? kept.prefix(limit) + "…" : kept
    }
}

/// Reads big-endian fields from a packet, checking each length against what is there. Strings are
/// slices of the packet, not copies.
struct ByteReader {
    var data: Data
    var index: Int

    init(_ data: Data) {
        self.data = data
        self.index = 0
    }

    mutating func u32() throws -> UInt32 { try integer() }
    mutating func u64() throws -> UInt64 { try integer() }

    private mutating func integer<T: FixedWidthInteger>() throws -> T {
        guard index + MemoryLayout<T>.size <= data.count else { throw TransferError.failed("Short SFTP packet") }
        defer { index += MemoryLayout<T>.size }
        return data.withUnsafeBytes { T(bigEndian: $0.loadUnaligned(fromByteOffset: index, as: T.self)) }
    }

    mutating func blob() throws -> Data {
        let length = Int(try u32())
        guard index + length <= data.count else { throw TransferError.failed("Short SFTP string") }
        let start = data.startIndex + index
        index += length
        return data[start..<(start + length)]
    }

    mutating func utf8() throws -> String {
        String(decoding: try blob(), as: UTF8.self)
    }

    mutating func attrs() throws -> SFTPAttrs {
        let flags = try u32()
        var value = SFTPAttrs()
        if flags & SFTPCode.attrSize != 0 { value.size = try u64() }
        if flags & SFTPCode.attrUID != 0 {
            value.uid = try u32()
            value.gid = try u32()
        }
        if flags & SFTPCode.attrPerms != 0 { value.permissions = try u32() }
        if flags & SFTPCode.attrTime != 0 {
            value.atime = try u32()
            value.mtime = try u32()
        }
        if flags & SFTPCode.attrExtended != 0 {
            let count = Int(try u32())
            for _ in 0..<count {
                _ = try blob()
                _ = try blob()
            }
        }
        return value
    }
}

extension Data {
    func loadU32() -> UInt32 {
        var value: UInt32 = 0
        for byte in prefix(4) { value = (value << 8) | UInt32(byte) }
        return value
    }

    mutating func appendU32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendU64(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBlob(_ data: Data) {
        appendU32(UInt32(data.count))
        append(data)
    }

    mutating func appendPath(_ path: RemotePath) {
        appendU32(UInt32(path.bytes.count))
        append(contentsOf: path.bytes)
    }

    mutating func appendString(_ string: String) {
        appendBlob(Data(string.utf8))
    }

    /// OPEN's fields: the path, the flags, and no attributes.
    mutating func openFields(_ path: RemotePath, flags: UInt32) {
        appendPath(path)
        appendU32(flags)
        appendAttrs(SFTPAttrs())
    }

    /// ATTRS: a flags word naming the fields that follow, in the draft's order. The owner and the
    /// times go only as pairs.
    mutating func appendAttrs(_ attrs: SFTPAttrs) {
        let owner = attrs.uid.flatMap { uid in attrs.gid.map { [uid, $0] } } ?? []
        let permissions = attrs.permissions.map { [$0] } ?? []
        let times = attrs.atime.flatMap { atime in attrs.mtime.map { [atime, $0] } } ?? []
        appendU32((attrs.size == nil ? 0 : SFTPCode.attrSize) | (owner.isEmpty ? 0 : SFTPCode.attrUID)
            | (permissions.isEmpty ? 0 : SFTPCode.attrPerms) | (times.isEmpty ? 0 : SFTPCode.attrTime))
        if let size = attrs.size { appendU64(size) }
        for word in owner + permissions + times { appendU32(word) }
    }
}
