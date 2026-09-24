import Foundation

/// One entry of a walked tree. Trees are keyed by the path relative to the root, joined with
/// `/`; the root itself is the empty key. A file's `mtime` is whole seconds, as SFTP keeps it,
/// or nil where it is not known.
public enum TreeEntry: Hashable, Sendable {
    case directory
    case file(size: UInt64, mtime: UInt32? = nil)
    case link
}

public extension TreeEntry {
    init(_ item: RemoteItem) {
        switch item.kind {
        case .directory: self = .directory
        case .symlink: self = .link
        case .file, .other: self = .file(size: item.size ?? 0, mtime: item.mtime)
        }
    }
}

/// What the clipboard holds: the roots that were copied, and every file inside their folders.
public struct ClipTally: Hashable, Sendable {
    /// Copied files and links, counted at the top level only.
    public var files = 0
    /// Copied folders, counted at the top level only.
    public var folders = 0
    /// Every file and link, at the top level and inside the copied folders.
    public var allFiles = 0
    public var bytes: UInt64 = 0
    /// False until every copied folder has been walked.
    public var complete = false

    public init() {}

    /// A copied item.
    public mutating func add(root entry: TreeEntry) {
        switch entry {
        case .directory:
            folders += 1
        case .file(let size, _):
            files += 1
            allFiles += 1
            bytes += size
        case .link:
            files += 1
            allFiles += 1
        }
    }

    /// Something inside a copied folder. Folders inside are not counted.
    public mutating func add(inside entry: TreeEntry) {
        switch entry {
        case .directory:
            break
        case .file(let size, _):
            allFiles += 1
            bytes += size
        case .link:
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
    /// Why the paste cannot go ahead, or nil. A folder cannot be pasted into itself or anything
    /// inside it; the copy would walk into its own output.
    public static func refusal(sources: [RemotePath], into folder: RemotePath) -> String? {
        for source in sources where folder.isInside(source) {
            return "“\(source.name)” cannot be pasted into itself."
        }
        return nil
    }

    /// Pasting into the folder the item came from makes a copy beside it, as Finder does.
    /// Anywhere else the item keeps its name, and collisions are settled file by file.
    public static func destinationName(for source: RemotePath, into folder: RemotePath, existing: Set<String>) -> String {
        source.parent == folder ? KeepBothName.duplicate(existing: existing, original: source.name) : source.name
    }
}

/// Whether a copy holds everything its source did, before a move removes the source.
public enum TreeCheck {
    /// The source entries that are missing from the destination or differ in kind, size, or
    /// modification time. Every copy keeps a file's time, so a file of the same name and size
    /// that was already there, left by a Skip or beside a Keep Both, does not pass for the copy.
    /// A time either side does not know is not compared.
    public static func missing(source: [String: TreeEntry], destination: [String: TreeEntry]) -> [String] {
        source.compactMap { key, entry in
            destination[key].map { holds(entry, $0) } == true ? nil : key
        }
        .sorted()
    }

    private static func holds(_ source: TreeEntry, _ copy: TreeEntry) -> Bool {
        switch (source, copy) {
        case let (.file(size, time), .file(copySize, copyTime)):
            size == copySize && (time == nil || copyTime == nil || time == copyTime)
        default:
            source == copy
        }
    }
}
