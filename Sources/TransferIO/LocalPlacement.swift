import Darwin
import Foundation
import TransferCore

/// A file, folder, or link as the placement rules see it: an item arriving, or what already
/// holds its name, on either side.
enum PlacedItem: Equatable, Sendable {
    case file(Fingerprint?)
    case folder
    case link(String)
    case other
}

/// What a copy does with an item whose name is held, or not, at its destination. Downloads,
/// uploads, and server copies share these rules, so links and folders settle alike.
enum Placement: Equatable {
    /// Nothing holds the name.
    case write
    /// A folder onto a folder: copy into it.
    case merge
    /// The same file, or a link to the same target, is already there.
    case skip
    /// Something else holds the name: the operation's prompt decides.
    case collide
    /// A folder would replace a file or the reverse. Nothing is removed to make room.
    case typeMismatch

    /// In a move, the same file or link already there is asked about too: skipped, it would pass
    /// for the move's copy, and the original would be removed for a lookalike.
    static func settle(_ incoming: PlacedItem, onto found: PlacedItem?, moving: Bool = false) -> Placement {
        guard let found else { return .write }
        switch (incoming, found) {
        case (.folder, .folder):
            return .merge
        case (.file(let arriving?), .file(let there?)) where arriving == there && !moving:
            return .skip
        case (.link(let arriving), .link(let there)) where arriving == there && !moving:
            return .skip
        // A link or a special file gives way only when the user says so, and removing one never
        // touches what a link points to. A folder never gives way.
        case (.file, .file), (.file, .link), (.file, .other),
             (.link, .file), (.link, .link), (.link, .other),
             (.folder, .link), (.folder, .other):
            return .collide
        default:
            return .typeMismatch
        }
    }

    /// A name as a disk that ignores case and Unicode form sees it: two names that fold the same
    /// may be one item there.
    static func fold(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Keep Both's name for `name`: the next that no name in `names` folds to.
    static func keepBoth(_ name: String, among names: Set<String>) -> String {
        let folded = Set(names.map(fold))
        var taken = names
        while true {
            let next = KeepBothName.next(existing: taken, original: name)
            if !folded.contains(fold(next)) { return next }
            taken.insert(next)
        }
    }
}

/// The one place a name from a server becomes a path on this Mac. A server is untrusted: its
/// names must never make Transfer write, remove, or follow anything outside the folder the user
/// chose. So a name must be a single path component, and what already holds it is read with
/// `lstat`, never through a link: a download goes down only into folders it found or made, never
/// into a link, and nothing already there is removed without a collision prompt.
enum LocalPlacement {
    /// `name` as one entry of `folder`. Throws when the name could reach anything else: empty,
    /// `.`, `..`, or holding `/` or NUL.
    static func child(_ folder: URL, name: String) throws -> URL {
        guard RemotePath.isSingleName(name) else {
            let shown = name.replacingOccurrences(of: "\0", with: "\\0")
            throw TransferError.failed("The server sent a name that is not a single file name: “\(shown)”")
        }
        return folder.appendingPathComponent(name, isDirectory: false)
    }

    /// What holds `url` now, read without following a link, or nil when nothing does. A failure
    /// other than "no such file" is thrown: it is not evidence that the name is free.
    static func occupant(_ url: URL) throws -> PlacedItem? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            let failure = posixError(url)
            if failure.code == ENOENT { return nil }
            throw failure.error
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            let seconds = info.st_mtimespec.tv_sec
            let mtime = seconds <= 0 ? 0 : UInt32(clamping: seconds)
            return .file(Fingerprint(size: UInt64(info.st_size), mtime: mtime))
        case S_IFDIR:
            return .folder
        case S_IFLNK:
            return .link(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        default:
            return .other
        }
    }

    /// A free name beside `url` for Keep Both. The name is checked on disk too, since this Mac's
    /// disk may treat two names the listing tells apart as one.
    static func keepBoth(_ url: URL) throws -> URL {
        let folder = url.deletingLastPathComponent()
        var taken = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        while true {
            let name = Placement.keepBoth(url.lastPathComponent, among: taken)
            let candidate = try child(folder, name: name)
            if try occupant(candidate) == nil { return candidate }
            taken.insert(name)
        }
    }

    /// Makes the folder `url`, or accepts a real folder already there. Never follows a link: one
    /// in the way is removed only when `replacing` says the user chose Replace.
    static func makeFolder(_ url: URL, replacing: Bool) throws {
        if replacing, unlink(url.path) != 0 {
            let failure = posixError(url)
            if failure.code != ENOENT { throw failure.error }
        }
        if mkdir(url.path, 0o777) == 0 { return }
        let failure = posixError(url)
        guard failure.code == EEXIST, try occupant(url) == .folder else { throw failure.error }
    }

    /// Makes a link at `url` pointing at `target`, in place of any file or link there. The link is
    /// made beside it and renamed over it, which never removes a folder.
    static func makeLink(_ url: URL, target: String) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(CopyRules.tempName(for: url.lastPathComponent, transferID: UUID().uuidString))
        guard symlink(target, temp.path) == 0 else { throw posixError(url).error }
        guard rename(temp.path, url.path) == 0 else {
            let failure = posixError(url)
            unlink(temp.path)
            throw failure.error
        }
    }

    /// Marks a downloaded file or folder as coming from another computer, so Gatekeeper checks an
    /// app or script before it first runs, as it does for a browser's downloads.
    static func quarantine(_ url: URL) {
        let value = String(format: "0081;%08x;Transfer;", UInt32(clamping: Int(Date().timeIntervalSince1970)))
        _ = value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, XATTR_NOFOLLOW) }
    }

    /// The error for the call that just failed, with `errno` as it was.
    private static func posixError(_ url: URL) -> (code: Int32, error: TransferError) {
        let code = errno
        let reason = String(cString: strerror(code))
        if code == EACCES || code == EPERM { return (code, .permissionDenied("\(url.lastPathComponent): \(reason)")) }
        return (code, .failed("Could not place \(url.lastPathComponent): \(reason)"))
    }
}
