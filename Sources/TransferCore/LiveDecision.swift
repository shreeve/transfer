import Foundation

/// A local file's size and full-precision modification time. SFTP keeps whole seconds; the Mac
/// keeps nanoseconds, which tell two saves of one size within one second apart.
public struct LiveStamp: Hashable, Sendable {
    public var size: UInt64
    public var mtime: Date

    public init(size: UInt64, mtime: Date) {
        self.size = size
        self.mtime = mtime
    }

    /// The whole-second view the server would record for these bytes.
    public var fingerprint: Fingerprint {
        Fingerprint(size: size, mtime: SFTPTime.seconds(mtime))
    }
}

/// What a Live file is known to be, between passes.
public struct LiveState: Hashable, Sendable {
    /// The server file at the last sync: size and whole-second mtime.
    public var base: Fingerprint?
    /// The working copy at the last sync, and a digest of its bytes.
    public var synced: LiveStamp?
    public var syncedDigest: String?
    public var dirty = false
    public var paused = false
    public var conflict = false
    /// The working copy's stamp at an upload that was sent but never confirmed. A server that
    /// holds its fingerprint afterwards holds our own bytes: the reply was lost, not the save.
    /// Kept in memory only: after a relaunch such a server reads as a conflict, which is safe.
    public var pending: LiveStamp?

    public init(base: Fingerprint?, synced: LiveStamp? = nil, syncedDigest: String? = nil, dirty: Bool = false,
                paused: Bool = false, conflict: Bool = false, pending: LiveStamp? = nil) {
        self.base = base
        self.synced = synced
        self.syncedDigest = syncedDigest
        self.dirty = dirty
        self.paused = paused
        self.conflict = conflict
        self.pending = pending
    }
}

/// The working copy, as a pass finds it.
public enum LiveLocal: Hashable, Sendable {
    /// `digest` is filled in only when the decision asks for it.
    case present(LiveStamp, digest: String?)
    /// `again` is true when the previous pass found it missing too.
    case missing(again: Bool)
}

/// The server file, as a pass finds it. A failed lookup is `unreachable`, never `missing`.
public enum LiveServerFact: Hashable, Sendable {
    case notChecked
    case file(Fingerprint)
    case missing
    case notFile(ItemKind)
    case unreachable(String)
}

/// Why a pass is running: a change, a login, or Retry; or the user opening the file again.
public enum LiveIntent: Hashable, Sendable {
    case sync
    case open
}

/// What the server holds when a conflict is raised.
public enum LiveConflictKind: Hashable, Sendable {
    case changed(Fingerprint)
    case removed
    case notAFile
}

/// What the server must hold just before a Live save's rename. Anything else makes it a conflict.
public enum ServerExpectation: Hashable, Sendable {
    case file(Fingerprint)
    case absent
}

/// What a pass does next. The worker gathers facts until the decision stops asking for them.
public enum LiveAction: Hashable, Sendable {
    case none
    case markClean
    case markDirty
    /// The mtime moved but the bytes did not: record the new stamp, upload nothing.
    case restamp
    /// Missing once: look again shortly, as an editor may be between delete and write.
    case recheckMissing
    /// Missing twice with edits or a conflict: keep the record and say so.
    case failMissing
    /// Missing twice and clean: drop the record.
    case forget
    case needDigest
    case needServer
    case upload(expecting: Fingerprint)
    /// The server holds our own last upload of exactly this copy, whose reply was lost: take its
    /// fingerprint as the base, upload nothing.
    case adopt(Fingerprint)
    case refreshLocal(Fingerprint)
    case conflict(LiveConflictKind)
    case failRetryable(String)
}

/// How the working copy compares with the last sync.
public enum LiveLocalChange: Hashable, Sendable {
    case same
    case touched
    case changed
    case needDigest
}

/// The Live sync rules as pure functions. Every pass of the Live worker asks `decide` what to do,
/// feeding it more facts (a digest, the server's file) until it stops asking. The commands that
/// run between passes (Keep Local, a removal, Discard, Remove Server, Quit) ask the helpers.
public enum LiveDecision {
    /// Without an exact stamp (a record older than stamps), the whole-second view is compared with
    /// the server's, so a same-size edit within the base's second reads as unchanged.
    public static func localChange(_ state: LiveState, _ stamp: LiveStamp, digest: String?) -> LiveLocalChange {
        if let synced = state.synced {
            if stamp == synced { return .same }
            if stamp.size != synced.size { return .changed }
            guard let known = state.syncedDigest else { return .changed }
            guard let digest else { return .needDigest }
            return digest == known ? .touched : .changed
        }
        guard let base = state.base else { return .changed }
        return stamp.fingerprint == base ? .same : .changed
    }

    /// Whether the working copy may hold bytes the server lacks: an edit a pass has seen, an
    /// unresolved conflict, or an edit no pass has seen yet. `change` is nil for a missing copy;
    /// `.needDigest` counts, since nothing has shown the bytes unchanged.
    public static func isUnsynced(_ state: LiveState, _ change: LiveLocalChange?) -> Bool {
        state.dirty || state.conflict || change == .changed || change == .needDigest
    }

    /// The conflict an edited copy meets when the server holds `server`, or nil when that is
    /// unknown or still the base.
    public static func conflictKind(for server: LiveServerFact) -> LiveConflictKind? {
        switch server {
        case .file(let print): .changed(print)
        case .missing: .removed
        case .notFile: .notAFile
        case .notChecked, .unreachable: nil
        }
    }

    /// What Keep Local expects the server to hold: the file seen when the conflict was raised, so
    /// an edit made there since is not overwritten. Nil when that was not a file.
    public static func keepLocalExpectation(_ state: LiveState, conflict: LiveConflictKind?) -> ServerExpectation? {
        switch conflict {
        case .changed(let print): .file(print)
        case .removed: .absent
        case .notAFile: nil
        case nil: state.base.map(ServerExpectation.file) ?? .absent
        }
    }

    /// Keep Remote when the server holds no file: the record is forgotten only when the conflict
    /// the user answered already showed that (removed, or replaced by something not a file). A
    /// server file that vanished after the user chose it leaves nothing to take, so the working
    /// copy stays and the conflict is asked again.
    public static func keepRemoteForgets(_ conflict: LiveConflictKind?, server: LiveServerFact) -> Bool {
        switch (conflict, server) {
        case (.removed, .missing), (.notAFile, .notFile): true
        default: false
        }
    }

    /// The name of a file kept beside a working copy named `name` (its "(server)" copy, a refresh
    /// download): `prefix`, the name, `suffix`. The name is cut, on a Unicode scalar boundary, so
    /// the whole fits the Mac's 255-byte limit, and further when the cut would give back `name`
    /// itself, which writing the sibling would then overwrite.
    public static func siblingName(of name: String, prefix: String = "", suffix: String) -> String {
        var kept = name.unicodeScalars[...]
        while true {
            let candidate = prefix + String(String.UnicodeScalarView(kept)) + suffix
            if candidate.utf8.count <= 255, candidate != name { return candidate }
            guard !kept.isEmpty else { return candidate }
            kept.removeLast()
        }
    }

    /// A Live file whose remote path was just removed: forgotten when its copy held nothing the
    /// server lacked, or the user chose to discard it; else kept, as removed from the server.
    public static func afterRemoval(_ state: LiveState, _ change: LiveLocalChange?, force: Bool) -> LiveAction {
        force || !isUnsynced(state, change) ? .forget : .conflict(.removed)
    }

    public static func decide(_ state: LiveState, local: LiveLocal, server: LiveServerFact, intent: LiveIntent = .sync) -> LiveAction {
        guard case .present(let stamp, let digest) = local else {
            if local == .missing(again: false) { return .recheckMissing }
            return state.dirty || state.conflict ? .failMissing : .forget
        }
        switch localChange(state, stamp, digest: digest) {
        case .needDigest:
            return .needDigest
        case .touched:
            return .restamp
        case .same:
            if state.conflict { return state.dirty ? .markClean : .none }
            if intent == .open, case .file(let now) = server, now != state.base { return .refreshLocal(now) }
            if intent == .open, server == .notChecked { return .needServer }
            return state.dirty ? .markClean : .none
        case .changed:
            if state.conflict || state.paused { return state.dirty ? .none : .markDirty }
            if case .unreachable(let reason) = server { return .failRetryable(reason) }
            if case .file(let now) = server {
                // The base first: two saves within one second share a fingerprint, and both upload.
                if let base = state.base, now == base { return .upload(expecting: base) }
                // Our own unconfirmed upload landed: adopted when it was this very copy, else it
                // is what the next upload replaces.
                if let pending = state.pending, now == pending.fingerprint {
                    return stamp == pending ? .adopt(now) : .upload(expecting: now)
                }
            }
            return conflictKind(for: server).map(LiveAction.conflict) ?? .needServer
        }
    }
}
