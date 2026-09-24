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
        Fingerprint(kind: .file, size: size, mtime: SFTPTime.seconds(mtime))
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

    public init(base: Fingerprint?, synced: LiveStamp? = nil, syncedDigest: String? = nil, dirty: Bool = false, paused: Bool = false, conflict: Bool = false) {
        self.base = base
        self.synced = synced
        self.syncedDigest = syncedDigest
        self.dirty = dirty
        self.paused = paused
        self.conflict = conflict
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
    /// The server already holds these bytes, as when a save landed but its reply was lost:
    /// take its fingerprint as the base, upload nothing.
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

/// The Live sync rules as one pure function. Every pass of the Live worker asks this what to do,
/// feeding it more facts (a digest, the server's file) until it stops asking.
public enum LiveDecision {
    public static func localChange(_ state: LiveState, _ stamp: LiveStamp, digest: String?) -> LiveLocalChange {
        if let synced = state.synced {
            if stamp == synced { return .same }
            if stamp.size != synced.size { return .changed }
            guard let known = state.syncedDigest else { return .changed }
            guard let digest else { return .needDigest }
            return digest == known ? .touched : .changed
        }
        // After a relaunch without an exact stamp: the whole-second view against the server's.
        guard let base = state.base else { return .changed }
        return stamp.fingerprint == Fingerprint(kind: .file, size: base.size, mtime: base.mtime) ? .same : .changed
    }

    public static func decide(_ state: LiveState, local: LiveLocal, server: LiveServerFact, intent: LiveIntent = .sync) -> LiveAction {
        let stamp: LiveStamp
        let digest: String?
        switch local {
        case .missing(again: false):
            return .recheckMissing
        case .missing(again: true):
            return state.dirty || state.conflict ? .failMissing : .forget
        case .present(let found, let foundDigest):
            stamp = found
            digest = foundDigest
        }
        let change = localChange(state, stamp, digest: digest)
        switch change {
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
            switch server {
            case .notChecked:
                return .needServer
            case .unreachable(let reason):
                return .failRetryable(reason)
            case .missing:
                return .conflict(.removed)
            case .notFile:
                return .conflict(.notAFile)
            case .file(let now):
                if let base = state.base, now == base { return .upload(expecting: base) }
                if now == stamp.fingerprint { return .adopt(now) }
                return .conflict(.changed(now))
            }
        }
    }
}
