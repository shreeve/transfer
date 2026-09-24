import Foundation

/// A path inside a walked tree, relative to its root and joined with `/`, as the exact bytes of
/// its names; the root is the empty key. Two names that read alike, such as the two Unicode forms
/// of `café` or two that are not UTF-8, stay two keys, so a move never takes one for the other.
public struct TreeKey: Hashable, Comparable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public init(stringLiteral value: String) {
        bytes = Array(value.utf8)
    }

    public var description: String { String(decoding: bytes, as: UTF8.self) }

    /// The key of `name` inside this one.
    public func appending(_ name: [UInt8]) -> TreeKey {
        TreeKey(bytes: bytes.isEmpty ? name : bytes + [0x2F] + name)
    }

    /// The names from the root down; none for the root.
    public var components: [[UInt8]] { bytes.split(separator: 0x2F).map(Array.init) }

    public static func < (left: TreeKey, right: TreeKey) -> Bool {
        left.bytes.lexicographicallyPrecedes(right.bytes)
    }
}

/// One entry of a walked tree, under its `TreeKey`. A file's `mtime` is whole seconds, as SFTP
/// keeps it, or nil where it is not known.
public enum TreeEntry: Hashable, Sendable {
    case directory
    case file(size: UInt64, mtime: UInt32? = nil)
    case link
    /// A FIFO, socket, or device. No copy holds one, so a move never removes it.
    case other
}

public extension TreeEntry {
    init(_ item: RemoteItem) {
        switch item.kind {
        case .directory: self = .directory
        case .symlink: self = .link
        case .file: self = .file(size: item.size ?? 0, mtime: item.mtime)
        case .other: self = .other
        }
    }

    /// An entry on this Mac, from its attributes read without following a link (`lstat`).
    init(_ attributes: [FileAttributeKey: Any]) {
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory: self = .directory
        case .typeSymbolicLink: self = .link
        case .typeRegular: self = .file(size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0, mtime: (attributes[.modificationDate] as? Date).map(SFTPTime.seconds))
        default: self = .other
        }
    }
}

/// What the clipboard holds: the roots that were copied, and every file inside their folders.
public struct ClipTally: Hashable, Sendable {
    /// Copied files, links, and special files, counted at the top level only.
    public var files = 0
    /// Copied folders, counted at the top level only.
    public var folders = 0
    /// Every file, link, and special file, at the top level and inside the copied folders.
    public var allFiles = 0
    public var bytes: UInt64 = 0
    /// False until every copied folder has been walked.
    public var complete = false

    public init() {}

    /// A copied item.
    public mutating func add(root entry: TreeEntry) {
        if entry == .directory { folders += 1 } else { files += 1 }
        add(inside: entry)
    }

    /// Something inside a copied folder. Folders inside are not counted.
    public mutating func add(inside entry: TreeEntry) {
        switch entry {
        case .directory:
            break
        case .file(let size, _):
            allFiles += 1
            bytes += size
        case .link, .other:
            allFiles += 1
        }
    }
}

/// The words on the clipboard bar.
public enum ClipText {
    /// "“notes.txt” (2.1 kB)", "3 files (12 MB)", "3 files and 1 folder (31 files in all, 12 MB)".
    /// `name` is the item's name when exactly one item was copied.
    public static func summary(_ tally: ClipTally, name: String?) -> String {
        let roots = tally.files + tally.folders
        let subject: String
        if roots == 1, let name {
            subject = "“\(name)”"
        } else if tally.folders == 0 {
            subject = count(tally.files, "file")
        } else if tally.files == 0 {
            subject = count(tally.folders, "folder")
        } else {
            subject = "\(count(tally.files, "file")) and \(count(tally.folders, "folder"))"
        }
        return "\(subject) (\(detail(tally)))"
    }

    private static func detail(_ tally: ClipTally) -> String {
        let size = Units.bytes(tally.bytes).trimmingCharacters(in: .whitespaces)
        guard tally.folders > 0 else { return tally.complete ? size : "counting…" }
        guard tally.complete else { return "counting… \(count(tally.allFiles, "file")) so far" }
        if tally.allFiles == 0 { return "no files" }
        let inAll = tally.files > 0 ? " in all" : ""
        return "\(count(tally.allFiles, "file"))\(inAll), \(size)"
    }

    public static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

/// Decisions for pasting items that live on the destination's own server.
public enum PasteRules {
    /// Why the paste cannot go ahead, or nil: a folder pasted into itself or below would walk into
    /// its own output. Paths are normalized, so `/srv/x/../site/sub` is inside `/srv/site`.
    public static func refusal(sources: [RemotePath], into folder: RemotePath) -> String? {
        let folder = folder.normalized
        return sources.first { folder.isInside($0.normalized) }.map { "“\($0.name)” cannot be pasted into itself." }
    }

    /// What a drop of `paths`, dragged from a window on `source`, does in `folder` on `destination`,
    /// or nil to refuse it. As in Finder, a drag within one server moves when it may (copies with
    /// Option); from another server it copies. A folder never goes into itself, and a move into an
    /// item's own folder does nothing, but a copy there makes "name copy" beside it.
    public static func drop(_ paths: [RemotePath], from source: ConnectionID, onto folder: RemotePath, on destination: ConnectionID,
                            canCopy: Bool, canMove: Bool) -> (paths: [RemotePath], moving: Bool)? {
        guard source == destination else { return canCopy ? (paths, false) : nil }
        guard canMove || canCopy else { return nil }
        let kept = paths.filter { !folder.isInside($0) && !(canMove && $0.parent == folder) }
        return kept.isEmpty ? nil : (kept, canMove)
    }
}

/// Whether a move may remove its original: only when this move wrote a complete copy.
public enum MoveCheck {
    public enum Verdict: Equatable, Sendable {
        case remove
        /// Files or links, by key, that the destination held before the move began and the move
        /// did not replace. Their copy cannot be told from what was there: a lookalike the user
        /// chose to skip, or the original itself reached through a second saved server.
        case alreadyThere([TreeKey])
        /// Entries, by key, that the copy lacks or holds differently.
        case incomplete([TreeKey])
    }

    /// `source` is the original's tree walked after the copy, so anything added meanwhile is
    /// missing from the copy and keeps it. `before` is the destination before the move reached it
    /// (empty if none), `after` the destination now, `written` the keys the move itself wrote over
    /// what was there when the user chose Replace. A folder already there may be merged into; a
    /// file or link already there counts only when replaced. A file counts only with an equal size
    /// and a known, equal time: every copy keeps the time; an unknown one proves nothing.
    public static func verdict(
        source: [TreeKey: TreeEntry],
        before: [TreeKey: TreeEntry],
        after: [TreeKey: TreeEntry],
        written: Set<TreeKey> = []
    ) -> Verdict {
        guard !source.isEmpty else { return .incomplete([""]) }
        var there: [TreeKey] = []
        var missing: [TreeKey] = []
        for (key, entry) in source {
            if let old = before[key], !(entry == .directory && old == .directory), !written.contains(key) {
                there.append(key)
            } else if let copy = after[key], proven(entry, copy) {
                continue
            } else {
                missing.append(key)
            }
        }
        if !there.isEmpty { return .alreadyThere(there.sorted()) }
        if !missing.isEmpty { return .incomplete(missing.sorted()) }
        return .remove
    }

    private static func proven(_ source: TreeEntry, _ copy: TreeEntry) -> Bool {
        switch (source, copy) {
        case let (.file(size, time?), .file(copySize, copyTime?)): size == copySize && time == copyTime
        case (.file, _), (.other, _): false
        default: source == copy
        }
    }
}

/// Finds two names that one folder on this Mac cannot hold apart: `README` and `readme` on a
/// case-insensitive disk, the two Unicode spellings of `café` (APFS ignores that too), or two
/// invalid UTF-8 names that decode alike. Fed each key once; a key folding like an earlier one
/// clashes.
public struct NameClash: Sendable {
    public let ignoringCase: Bool
    private var seen: [String: TreeKey] = [:]
    /// The first two keys found to clash.
    public private(set) var found: (TreeKey, TreeKey)?

    public init(ignoringCase: Bool) {
        self.ignoringCase = ignoringCase
    }

    public mutating func add(_ key: TreeKey) {
        guard found == nil else { return }
        let text = key.description.precomposedStringWithCanonicalMapping
        let folded = ignoringCase ? text.lowercased() : text
        if let other = seen[folded] { found = (other, key) } else { seen[folded] = key }
    }
}

/// One paste or drop: items on a saved server, or files on this Mac, copied or moved into a folder
/// on a saved server. Made once per operation and passed again on every retry, so a retry skips
/// what an earlier attempt finished and reuses the names it chose.
public final class TransferRequest: Sendable {
    public enum Sources: Sendable {
        case server(ConnectionID, [RemotePath])
        case mac([URL])
    }

    public let sources: Sources
    /// The server the items go to, and the folder there.
    public let connection: ConnectionID
    public let folder: RemotePath
    public let moving: Bool
    /// What the sources hold, when known, so progress can show a total.
    public let bytes: UInt64?
    /// The engine's memory across attempts.
    package let memo = Locked(TransferMemo())

    public init(_ sources: Sources, into folder: RemotePath, on connection: ConnectionID, moving: Bool, bytes: UInt64? = nil) {
        self.sources = sources
        self.folder = folder
        self.connection = connection
        self.moving = moving
        self.bytes = bytes
    }
}

/// What the attempts of one `TransferRequest` have done so far.
package struct TransferMemo: Sendable {
    /// Sources, by index, finished: copied, or moved and removed.
    package var done: Set<Int> = []
    /// Where each source goes, once chosen, by index.
    package var targets: [Int: RemotePath] = [:]
    /// Each destination's tree just before that source's copy first reached it, by index: what
    /// an earlier item wrote there is in it, and counts as already there.
    package var before: [Int: [TreeKey: TreeEntry]] = [:]
    /// Whether the two ends of a move were proven to be different folders.
    package var checked = false
    /// The files, links, and folders each source's copy wrote on the destination, by index. Only
    /// an item's own writes are its copy: another item of the same name may land at the same path.
    package var written: [Int: Set<RemotePath>] = [:]
    /// Where each source's entries went in place of the path they were offered, after Keep Both,
    /// by index.
    package var landed: [Int: [RemotePath: RemotePath]] = [:]

    package init() {}
}

/// A paste that left some items where they were, and why; thrown once the rest are done.
public struct TransferKept: Error, Equatable, Sendable, LocalizedError {
    public enum Reason: Hashable, Sendable {
        /// Two names in the item that this Mac's disk, which it passes through, cannot hold apart.
        case clash(String, String)
        case alreadyThere
        case incomplete
        /// Live files under the original with edits not yet on the server.
        case live(Int)
        /// Something in the original changed after its copy was verified: what changed stayed.
        case changed

        public init?(_ verdict: MoveCheck.Verdict) {
            switch verdict {
            case .remove: return nil
            case .alreadyThere: self = .alreadyThere
            case .incomplete: self = .incomplete
            }
        }
    }

    public struct Item: Equatable, Sendable {
        public var name: String
        public var reason: Reason

        public init(_ name: String, _ reason: Reason) {
            self.name = name
            self.reason = reason
        }
    }

    public var items: [Item]
    public var moving: Bool
    /// Where the kept items are: "on the other server", "on this Mac".
    public var place: String

    public init(_ items: [Item], moving: Bool, place: String) {
        self.items = items
        self.moving = moving
        self.place = place
    }

    /// One sentence per reason: "Kept “a” and “b” on the other server: the copy is not complete."
    public var errorDescription: String? {
        var reasons: [Reason] = []
        for item in items where !reasons.contains(item.reason) { reasons.append(item.reason) }
        return reasons.map { reason in
            let list = ListFormatter.localizedString(byJoining: items.filter { $0.reason == reason }.map { "“\($0.name)”" })
            return switch reason {
            case .clash(let first, let second):
                "Did not \(moving ? "move" : "paste") \(list): “\(first)” and “\(second)” differ only in case or accents, and this Mac's disk, which the items pass through, cannot hold both."
            case .alreadyThere:
                "Kept \(list) \(place): something with that name was already at the destination and was not replaced, so this move cannot tell its own copy from it."
            case .incomplete:
                "Kept \(list) \(place): the copy is not complete."
            case .live(let count):
                "Kept \(list) \(place): \(TransferError.liveUnsynced(count).localizedDescription)."
            case .changed:
                "\(list) changed during the move, and what changed was kept \(place)."
            }
        }.joined(separator: " ")
    }
}
