import Foundation
import TransferCore

/// The SFTP version 3 codec: message codes, attributes, packet framing, and a reader that checks
/// every length against the bytes it has. The server's bytes are untrusted; `SFTPChannel` speaks
/// the protocol with these pieces.
enum SFTPCode {
    static let initialize: UInt8 = 1
    static let version: UInt8 = 2
    static let open: UInt8 = 3
    static let close: UInt8 = 4
    static let read: UInt8 = 5
    static let write: UInt8 = 6
    static let lstat: UInt8 = 7
    static let setstat: UInt8 = 9
    static let fsetstat: UInt8 = 10
    static let opendir: UInt8 = 11
    static let readdir: UInt8 = 12
    static let remove: UInt8 = 13
    static let mkdir: UInt8 = 14
    static let rmdir: UInt8 = 15
    static let realpath: UInt8 = 16
    static let rename: UInt8 = 18
    static let readlink: UInt8 = 19
    static let symlink: UInt8 = 20
    static let status: UInt8 = 101
    static let handle: UInt8 = 102
    static let data: UInt8 = 103
    static let name: UInt8 = 104
    static let attrs: UInt8 = 105
    static let extended: UInt8 = 200

    static let ok: UInt32 = 0
    static let eof: UInt32 = 1
    static let noSuchFile: UInt32 = 2
    static let permission: UInt32 = 3
    static let failure: UInt32 = 4

    static let attrSize: UInt32 = 0x1
    static let attrUID: UInt32 = 0x2
    static let attrPerms: UInt32 = 0x4
    static let attrTime: UInt32 = 0x8

    static let fxRead: UInt32 = 0x1
    static let fxWrite: UInt32 = 0x2
    static let fxCreat: UInt32 = 0x8
    static let fxTrunc: UInt32 = 0x10
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
        var flags: UInt32 = 0
        var body = Data()
        if let size {
            flags |= SFTPCode.attrSize
            body.appendU64(size)
        }
        if let uid, let gid {
            flags |= SFTPCode.attrUID
            body.appendU32(uid)
            body.appendU32(gid)
        }
        if let permissions {
            flags |= SFTPCode.attrPerms
            body.appendU32(permissions)
        }
        if let atime, let mtime {
            flags |= SFTPCode.attrTime
            body.appendU32(atime)
            body.appendU32(mtime)
        }
        var out = Data()
        out.appendU32(flags)
        out.append(body)
        return out
    }
}

struct SFTPName: Equatable {
    var filename: Data
    var attrs: SFTPAttrs
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
        let firstLine = String(decoding: bytes.prefix(200), as: UTF8.self)
            .split(whereSeparator: \.isNewline).first ?? ""
        let printable = String(String.UnicodeScalarView(firstLine.unicodeScalars.filter {
            $0.properties.generalCategory != .control
        })).trimmingCharacters(in: .whitespaces)
        guard bytes.first != 0, !printable.isEmpty else { return "The server did not answer in SFTP" }
        let shown = printable.count > 60 ? printable.prefix(60) + "…" : printable
        return "The server printed “\(shown)” before SFTP started. Remove that output from the shell startup files on the server, such as .bashrc."
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

    mutating func u32() throws -> UInt32 {
        guard index + 4 <= data.count else { throw TransferError.failed("Short SFTP packet") }
        defer { index += 4 }
        return data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: index, as: UInt32.self)) }
    }

    mutating func u64() throws -> UInt64 {
        guard index + 8 <= data.count else { throw TransferError.failed("Short SFTP packet") }
        defer { index += 8 }
        return data.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: index, as: UInt64.self)) }
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
        if flags & 0x8000_0000 != 0 {
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
        append(contentsOf: [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    mutating func appendU64(_ value: UInt64) {
        appendU32(UInt32((value >> 32) & 0xffff_ffff))
        appendU32(UInt32(value & 0xffff_ffff))
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
        append(SFTPAttrs().encoded())
    }
}
