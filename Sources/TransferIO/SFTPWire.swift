import Foundation
import TransferCore

enum SFTPCode {
    static let initialize: UInt8 = 1
    static let version: UInt8 = 2
    static let open: UInt8 = 3
    static let close: UInt8 = 4
    static let read: UInt8 = 5
    static let write: UInt8 = 6
    static let lstat: UInt8 = 7
    static let setstat: UInt8 = 9
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
    static let unsupported: UInt32 = 8

    static let attrSize: UInt32 = 0x1
    static let attrUID: UInt32 = 0x2
    static let attrPerms: UInt32 = 0x4
    static let attrTime: UInt32 = 0x8

    static let fxRead: UInt32 = 0x1
    static let fxWrite: UInt32 = 0x2
    static let fxCreat: UInt32 = 0x8
    static let fxTrunc: UInt32 = 0x10
    static let fxExcl: UInt32 = 0x20
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
    var longname: String
    var attrs: SFTPAttrs
}

struct SFTPMessage {
    var type: UInt8
    var requestID: UInt32?
    var rest: Data
}

enum SFTPWire {
    static func packet(type: UInt8, body: Data) -> Data {
        var payload = Data([type])
        payload.append(body)
        var framed = Data()
        framed.appendU32(UInt32(payload.count))
        framed.append(payload)
        return framed
    }

    static func popPacket(from buffer: inout Data) -> SFTPMessage? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).loadU32()
        let total = 4 + Int(length)
        guard buffer.count >= total, length > 0 else { return nil }
        let payload = buffer.subdata(in: 4..<total)
        buffer.removeSubrange(0..<total)
        let type = payload[payload.startIndex]
        let rest = payload.dropFirst()
        return SFTPMessage(type: type, requestID: nil, rest: Data(rest))
    }
}

struct ByteReader {
    var data: Data
    var index: Int

    init(_ data: Data) {
        self.data = data
        self.index = 0
    }

    mutating func u8() throws -> UInt8 {
        guard index < data.count else { throw TransferError.failed("Short SFTP packet") }
        let value = data[data.startIndex + index]
        index += 1
        return value
    }

    mutating func u32() throws -> UInt32 {
        guard index + 4 <= data.count else { throw TransferError.failed("Short SFTP packet") }
        let value = data.subdata(in: (data.startIndex + index)..<(data.startIndex + index + 4)).loadU32()
        index += 4
        return value
    }

    mutating func u64() throws -> UInt64 {
        guard index + 8 <= data.count else { throw TransferError.failed("Short SFTP packet") }
        let value = data.subdata(in: (data.startIndex + index)..<(data.startIndex + index + 8)).loadU64()
        index += 8
        return value
    }

    mutating func blob() throws -> Data {
        let length = Int(try u32())
        guard index + length <= data.count else { throw TransferError.failed("Short SFTP string") }
        let start = data.startIndex + index
        let value = data.subdata(in: start..<(start + length))
        index += length
        return value
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

    func loadU64() -> UInt64 {
        var value: UInt64 = 0
        for byte in prefix(8) { value = (value << 8) | UInt64(byte) }
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

    mutating func appendString(_ string: String) {
        appendBlob(Data(string.utf8))
    }
}
