import Foundation

public struct ConnectionID: Hashable, Sendable, RawRepresentable {
    public var rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }

    /// A short stable file name for this connection's control socket. Unix socket paths are
    /// limited to 104 bytes on macOS, and ssh appends a 17-byte suffix while it binds.
    public var socketName: String {
        String(rawValue.uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }
}

public struct LiveFileID: Hashable, Sendable, RawRepresentable {
    public var rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
}

/// A path on a server, as bytes: a server's names need not be UTF-8, and the bytes are what go
/// back on the wire. Trailing slashes are dropped when the path is made, so `/srv/site/` and
/// `/srv/site` are one path, its name is `site`, and appending to it never makes a `//`.
public struct RemotePath: Hashable, Sendable {
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) {
        var bytes = bytes
        while bytes.count > 1, bytes.last == 0x2F { bytes.removeLast() }
        self.bytes = bytes
    }

    public init(string: String) {
        self.init(bytes: Array(string.utf8))
    }

    public var display: String {
        String(decoding: bytes, as: UTF8.self)
    }

    public var isRoot: Bool { bytes == [0x2F] }

    /// `name` as the last component. Leading slashes in `name` are ignored.
    public func appending(name: [UInt8]) -> RemotePath {
        let name = name.drop { $0 == 0x2F }
        return RemotePath(bytes: isRoot ? bytes + name : bytes + [0x2F] + name)
    }

    public func appending(_ name: String) -> RemotePath {
        appending(name: Array(name.utf8))
    }

    /// Nil for the root and for a relative path of one component.
    public var parent: RemotePath? {
        guard !isRoot, let slash = bytes.lastIndex(of: 0x2F) else { return nil }
        return RemotePath(bytes: slash == 0 ? [0x2F] : Array(bytes[..<slash]))
    }

    /// The last path component, decoded for display.
    public var name: String { String(decoding: nameBytes, as: UTF8.self) }

    public var nameBytes: [UInt8] {
        if isRoot { return [] }
        guard let slash = bytes.lastIndex(of: 0x2F) else { return bytes }
        return Array(bytes[(slash + 1)...])
    }

    /// True when this path is `ancestor` or lies under it. A lexical test: `..` is a name here,
    /// so compare `normalized` paths when either side may hold one.
    public func isInside(_ ancestor: RemotePath) -> Bool {
        if bytes == ancestor.bytes { return true }
        let head = ancestor.isRoot ? ancestor.bytes : ancestor.bytes + [0x2F]
        return bytes.count > head.count && bytes.starts(with: head)
    }

    /// The path with empty and `.` components dropped and each `..` taking away the one before
    /// it, as far as the root. Lexical only: a symlinked folder's `..` is where the server says,
    /// which only the server knows.
    public var normalized: RemotePath {
        let absolute = bytes.first == 0x2F
        var kept: [ArraySlice<UInt8>] = []
        for part in bytes.split(separator: 0x2F) {
            switch part {
            case [0x2E]: continue
            case [0x2E, 0x2E] where kept.last.map({ $0 != [0x2E, 0x2E] }) ?? absolute:
                if !kept.isEmpty { kept.removeLast() }
            default: kept.append(part)
            }
        }
        let joined = Array(kept.joined(separator: [0x2F]))
        if absolute { return RemotePath(bytes: [0x2F] + joined) }
        return RemotePath(bytes: joined.isEmpty ? [0x2E] : joined)
    }
}

public enum ItemKind: String, Hashable, Sendable {
    case file
    case directory
    case symlink
    case other
}

public struct RemoteItem: Hashable, Sendable, Identifiable {
    public var path: RemotePath
    public var kind: ItemKind
    public var size: UInt64?
    public var mtime: UInt32?
    public var mode: UInt32?
    public var owner: String?
    public var group: String?

    public var id: RemotePath { path }

    public init(
        path: RemotePath,
        kind: ItemKind,
        size: UInt64? = nil,
        mtime: UInt32? = nil,
        mode: UInt32? = nil,
        owner: String? = nil,
        group: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.mtime = mtime
        self.mode = mode
        self.owner = owner
        self.group = group
    }

    public var name: String { path.name }
    public var isHidden: Bool { name.hasPrefix(".") && name != "." && name != ".." }
    public var isDotEntry: Bool { name == "." || name == ".." }
}

/// SFTP v3 keeps times as unsigned 32-bit seconds since 1970.
public enum SFTPTime {
    /// A date's whole seconds, clamped to what SFTP can hold: a date before 1970 is 0 and one after
    /// February 2106 is the last second. `UInt32(_:)` would trap on either.
    public static func seconds(_ date: Date) -> UInt32 {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        if seconds.isNaN || seconds <= 0 { return 0 }
        return seconds >= Double(UInt32.max) ? .max : UInt32(seconds)
    }
}

/// A file as SFTP describes it: size and whole-second mtime.
public struct Fingerprint: Hashable, Sendable {
    public var size: UInt64
    public var mtime: UInt32

    public init(size: UInt64, mtime: UInt32) {
        self.size = size
        self.mtime = mtime
    }

    public init?(item: RemoteItem) {
        guard item.kind == .file, let size = item.size, let mtime = item.mtime else { return nil }
        self.size = size
        self.mtime = mtime
    }
}

public struct SavedConnection: Hashable, Sendable, Identifiable {
    public var id: ConnectionID
    public var name: String
    public var host: String
    public var user: String
    public var port: String
    public var identityFile: String
    public var remotePath: String

    public init(
        id: ConnectionID = ConnectionID(),
        name: String,
        host: String,
        user: String = "",
        port: String = "",
        identityFile: String = "",
        remotePath: String = ""
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.remotePath = remotePath
    }

    public var displayName: String { name.isEmpty ? host : name }

    public var destination: String {
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        if trimmedUser.isEmpty { return host }
        return "\(trimmedUser)@\(host)"
    }
}
