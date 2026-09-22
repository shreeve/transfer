import Foundation

public struct ConnectionID: Hashable, Sendable, Codable, RawRepresentable {
    public var rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }

    /// A short stable file name for this connection's control socket. Unix socket paths are
    /// limited to 104 bytes on macOS, and ssh appends a 17-byte suffix while it binds.
    public var socketName: String {
        String(rawValue.uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }
}

public struct LiveFileID: Hashable, Sendable, Codable, RawRepresentable {
    public var rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
}

public struct RemotePath: Hashable, Sendable, Codable {
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public init(string: String) {
        self.bytes = Array(string.utf8)
    }

    public var display: String {
        String(decoding: bytes, as: UTF8.self)
    }

    public var isRoot: Bool { bytes == [0x2F] }

    public func appending(name: [UInt8]) -> RemotePath {
        if bytes == [0x2F] {
            return RemotePath(bytes: [0x2F] + name)
        }
        return RemotePath(bytes: bytes + [0x2F] + name)
    }

    public var parent: RemotePath? {
        guard bytes.count > 1 else { return nil }
        let slash = bytes.lastIndex(of: 0x2F) ?? 0
        if slash == 0 { return RemotePath(bytes: [0x2F]) }
        return RemotePath(bytes: Array(bytes[..<slash]))
    }

    public var nameBytes: [UInt8] {
        guard let slash = bytes.lastIndex(of: 0x2F), slash + 1 < bytes.count else {
            return bytes == [0x2F] ? [] : bytes
        }
        return Array(bytes[(slash + 1)...])
    }
}

public enum ItemKind: String, Hashable, Sendable, Codable {
    case file
    case directory
    case symlink
    case other
}

public struct RemoteItem: Hashable, Sendable, Codable, Identifiable {
    public var path: RemotePath
    public var kind: ItemKind
    public var size: UInt64?
    public var mtime: UInt32?
    public var mode: UInt32?
    public var owner: String?
    public var group: String?
    public var linkTarget: String?

    public var id: RemotePath { path }

    public init(
        path: RemotePath,
        kind: ItemKind,
        size: UInt64? = nil,
        mtime: UInt32? = nil,
        mode: UInt32? = nil,
        owner: String? = nil,
        group: String? = nil,
        linkTarget: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.mtime = mtime
        self.mode = mode
        self.owner = owner
        self.group = group
        self.linkTarget = linkTarget
    }

    public var name: String { String(decoding: path.nameBytes, as: UTF8.self) }
    public var isHidden: Bool { name.hasPrefix(".") && name != "." && name != ".." }
    public var isDotEntry: Bool { name == "." || name == ".." }
}

public struct Fingerprint: Hashable, Sendable, Codable {
    public var kind: ItemKind
    public var size: UInt64
    public var mtime: UInt32

    public init(kind: ItemKind, size: UInt64, mtime: UInt32) {
        self.kind = kind
        self.size = size
        self.mtime = mtime
    }

    public init?(item: RemoteItem) {
        guard item.kind == .file, let size = item.size, let mtime = item.mtime else { return nil }
        self.kind = item.kind
        self.size = size
        self.mtime = mtime
    }
}

public struct SavedConnection: Hashable, Sendable, Codable, Identifiable {
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
