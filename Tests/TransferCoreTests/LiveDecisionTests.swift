import Foundation
import Testing
import TransferCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000.25)
private let synced = LiveStamp(size: 10, mtime: t0)
private let base = Fingerprint(size: 10, mtime: 1_700_000_000)
private let other = Fingerprint(size: 12, mtime: 1_700_000_500)

private func state(dirty: Bool = false, paused: Bool = false, conflict: Bool = false, exact: Bool = true) -> LiveState {
    LiveState(base: base, synced: exact ? synced : nil, syncedDigest: exact ? "d0" : nil, dirty: dirty, paused: paused, conflict: conflict)
}

private func present(size: UInt64 = 10, at date: Date = t0, digest: String? = nil) -> LiveLocal {
    .present(LiveStamp(size: size, mtime: date), digest: digest)
}

// Missing working copy

@Test func missingOnceIsCheckedAgain() {
    #expect(LiveDecision.decide(state(), local: .missing(again: false), server: .notChecked) == .recheckMissing)
}

@Test func missingTwiceKeepsEditsAndForgetsCleanCopies() {
    #expect(LiveDecision.decide(state(dirty: true), local: .missing(again: true), server: .notChecked) == .failMissing)
    #expect(LiveDecision.decide(state(conflict: true), local: .missing(again: true), server: .notChecked) == .failMissing)
    #expect(LiveDecision.decide(state(), local: .missing(again: true), server: .notChecked) == .forget)
}

// What counts as a local change

@Test func sameStampIsUnchangedWithoutReadingBytes() {
    #expect(LiveDecision.decide(state(), local: present(), server: .notChecked) == .none)
    #expect(LiveDecision.decide(state(dirty: true), local: present(), server: .notChecked) == .markClean)
}

@Test func touchedFileIsRestampedNotUploaded() {
    let later = t0.addingTimeInterval(30)
    #expect(LiveDecision.decide(state(), local: present(at: later), server: .notChecked) == .needDigest)
    #expect(LiveDecision.decide(state(), local: present(at: later, digest: "d0"), server: .notChecked) == .restamp)
    // Even with the server changed, same bytes are no conflict.
    #expect(LiveDecision.decide(state(), local: present(at: later, digest: "d0"), server: .file(other)) == .restamp)
}

@Test func sameSizeSameSecondNewBytesIsAChange() {
    let sameSecond = t0.addingTimeInterval(0.5)
    #expect(LiveDecision.decide(state(), local: present(at: sameSecond, digest: "d1"), server: .notChecked) == .needServer)
}

@Test func differentSizeIsAChangeWithoutADigest() {
    #expect(LiveDecision.decide(state(), local: present(size: 11), server: .notChecked) == .needServer)
}

@Test func withoutAnExactStampWholeSecondsDecide() {
    // A relaunched record whose working copy still has the server's whole-second time.
    #expect(LiveDecision.decide(state(exact: false), local: present(at: Date(timeIntervalSince1970: 1_700_000_000)), server: .notChecked) == .none)
    #expect(LiveDecision.decide(state(exact: false), local: present(size: 9), server: .notChecked) == .needServer)
    let noBase = LiveState(base: nil)
    #expect(LiveDecision.decide(noBase, local: present(), server: .notChecked) == .needServer)
}

// A changed working copy against the server

@Test func changedUploadsOnlyWhenTheServerStillMatches() {
    let edited = present(size: 11)
    #expect(LiveDecision.decide(state(), local: edited, server: .notChecked) == .needServer)
    #expect(LiveDecision.decide(state(), local: edited, server: .file(base)) == .upload(expecting: base))
}

@Test func changedAgainstAChangedServerIsAConflict() {
    let edited = present(size: 11)
    #expect(LiveDecision.decide(state(), local: edited, server: .file(other)) == .conflict(.changed(other)))
    #expect(LiveDecision.decide(state(), local: edited, server: .missing) == .conflict(.removed))
    #expect(LiveDecision.decide(state(), local: edited, server: .notFile(.directory)) == .conflict(.notAFile))
    #expect(LiveDecision.decide(state(), local: edited, server: .notFile(.symlink)) == .conflict(.notAFile))
    #expect(LiveDecision.decide(LiveState(base: nil), local: edited, server: .file(base)) == .conflict(.changed(base)))
}

@Test func anUnreachableServerIsARetryNotAConflict() {
    #expect(LiveDecision.decide(state(), local: present(size: 11), server: .unreachable("timed out")) == .failRetryable("timed out"))
}

@Test func pausedChangesAreOnlyMarked() {
    #expect(LiveDecision.decide(state(paused: true), local: present(size: 11), server: .notChecked) == .markDirty)
    #expect(LiveDecision.decide(state(dirty: true, paused: true), local: present(size: 11), server: .file(base)) == .none)
}

@Test func aConflictNeverUploadsUntilResolved() {
    #expect(LiveDecision.decide(state(conflict: true), local: present(size: 11), server: .file(base)) == .markDirty)
    #expect(LiveDecision.decide(state(dirty: true, conflict: true), local: present(size: 11), server: .file(base)) == .none)
    #expect(LiveDecision.decide(state(dirty: true, conflict: true), local: present(), server: .notChecked) == .markClean)
}

// An unchanged working copy

@Test func anUnchangedCopyIsRefreshedOnlyOnOpen() {
    #expect(LiveDecision.decide(state(), local: present(), server: .file(other)) == .none)
    #expect(LiveDecision.refreshesOnOpen(state(), .same, server: other))
    #expect(!LiveDecision.refreshesOnOpen(state(), .same, server: base))
    #expect(!LiveDecision.refreshesOnOpen(state(conflict: true), .same, server: other))
    #expect(!LiveDecision.refreshesOnOpen(state(), .changed, server: other))
    #expect(!LiveDecision.refreshesOnOpen(state(), .needDigest, server: other))
    #expect(!LiveDecision.refreshesOnOpen(state(), nil, server: other))
    // Refreshing wins over marking clean or paused: the bytes are the synced ones either way.
    #expect(LiveDecision.refreshesOnOpen(state(dirty: true), .same, server: other))
    #expect(LiveDecision.refreshesOnOpen(state(paused: true), .same, server: other))
}

/// LIV2-08: a copy an editor re-saved unchanged (new mtime, same bytes) was never refreshed on
/// reopen, so the user edited stale bytes and met a conflict.
@Test func aTouchedCopyIsRefreshedOnOpenToo() {
    #expect(LiveDecision.refreshesOnOpen(state(), .touched, server: other))
    #expect(!LiveDecision.refreshesOnOpen(state(), .touched, server: base))
    #expect(!LiveDecision.refreshesOnOpen(state(conflict: true), .touched, server: other))
}

/// LIVE-09: only our own unconfirmed upload is adopted. Another writer's file of the same size and
/// second used to be taken as ours, and the local edit never uploaded.
@Test func onlyOurOwnLostUploadIsAdopted() {
    let edited = LiveStamp(size: 11, mtime: Date(timeIntervalSince1970: 1_700_000_300.4))
    var sent = state()
    sent.pending = edited
    // A save that landed but whose reply was lost: the server holds that very copy's fingerprint.
    #expect(LiveDecision.decide(sent, local: .present(edited, digest: nil), server: .file(edited.fingerprint)) == .adopt(edited.fingerprint))
    // Nothing was sent: the same fingerprint is someone else's file.
    #expect(LiveDecision.decide(state(), local: .present(edited, digest: nil), server: .file(edited.fingerprint)) == .conflict(.changed(edited.fingerprint)))
    #expect(LiveDecision.decide(sent, local: .present(edited, digest: nil), server: .file(other)) == .conflict(.changed(other)))
    // Saved again since the lost upload: that upload is now what the next one replaces.
    let later = LiveStamp(size: 11, mtime: Date(timeIntervalSince1970: 1_700_000_300.9))
    #expect(LiveDecision.decide(sent, local: .present(later, digest: nil), server: .file(edited.fingerprint)) == .upload(expecting: edited.fingerprint))
    // The server still at the base: the upload never landed, so the base is still expected.
    #expect(LiveDecision.decide(sent, local: .present(edited, digest: nil), server: .file(base)) == .upload(expecting: base))
}

// The cells the audit found uncovered (LIVE-23)

@Test func missingOnceIsCheckedAgainWhateverTheFlags() {
    for flags in [state(dirty: true), state(conflict: true), state(paused: true), state(dirty: true, paused: true, conflict: true)] {
        #expect(LiveDecision.decide(flags, local: .missing(again: false), server: .notChecked) == .recheckMissing)
    }
    #expect(LiveDecision.decide(state(paused: true), local: .missing(again: true), server: .notChecked) == .forget)
}

@Test func aTouchIsRestampedWhateverTheFlags() {
    let touched = present(at: t0.addingTimeInterval(30), digest: "d0")
    for flags in [state(dirty: true), state(conflict: true), state(paused: true)] {
        #expect(LiveDecision.decide(flags, local: touched, server: .notChecked) == .restamp)
    }
}

@Test func withoutASyncedDigestAnyNewMtimeIsAChange() {
    let noDigest = LiveState(base: base, synced: synced, syncedDigest: nil)
    #expect(LiveDecision.localChange(noDigest, LiveStamp(size: 10, mtime: t0.addingTimeInterval(30)), digest: nil) == .changed)
    #expect(LiveDecision.decide(noDigest, local: present(at: t0.addingTimeInterval(30)), server: .notChecked) == .needServer)
}

@Test func anUnchangedCopyAcrossFlags() {
    #expect(LiveDecision.decide(state(conflict: true), local: present(), server: .notChecked) == .none)
    #expect(LiveDecision.decide(state(dirty: true), local: present(), server: .file(base)) == .markClean)
    #expect(LiveDecision.decide(state(), local: present(), server: .unreachable("down")) == .none)
    #expect(LiveDecision.decide(state(), local: present(), server: .notFile(.directory)) == .none)
}

@Test func aChangedCopyAcrossFlags() {
    let edited = present(size: 11)
    #expect(LiveDecision.decide(state(paused: true, conflict: true), local: edited, server: .notChecked) == .markDirty)
    #expect(LiveDecision.decide(state(dirty: true, paused: true, conflict: true), local: edited, server: .file(base)) == .none)
}

@Test func theBaseWinsOverAdoptingWhenBothMatch() {
    // A second save within the base's own second has the base's fingerprint too: it must upload.
    let sameSecond = LiveStamp(size: 10, mtime: t0.addingTimeInterval(0.5))
    var sent = state()
    sent.pending = sameSecond
    #expect(sameSecond.fingerprint == base)
    #expect(LiveDecision.decide(sent, local: .present(sameSecond, digest: "d1"), server: .file(base)) == .upload(expecting: base))
}

@Test func withoutABaseOnlyOurOwnUploadIsAdopted() {
    let edited = LiveStamp(size: 11, mtime: Date(timeIntervalSince1970: 1_700_000_300.4))
    let noBase = LiveState(base: nil)
    #expect(LiveDecision.decide(noBase, local: .present(edited, digest: nil), server: .file(edited.fingerprint)) == .conflict(.changed(edited.fingerprint)))
    #expect(LiveDecision.decide(LiveState(base: nil, pending: edited), local: .present(edited, digest: nil), server: .file(edited.fingerprint)) == .adopt(edited.fingerprint))
    #expect(LiveDecision.decide(noBase, local: .present(edited, digest: nil), server: .missing) == .conflict(.removed))
}

@Test func withoutAnExactStampASameSizeEditInTheBasesSecondIsUnseen() {
    // Records from before exact stamps were kept compare whole seconds: a known blind spot.
    let sameSecond = LiveStamp(size: 10, mtime: Date(timeIntervalSince1970: 1_700_000_000.9))
    #expect(LiveDecision.localChange(state(exact: false), sameSecond, digest: nil) == .same)
}

@Test func fingerprintsClampToWhatSFTPCanHold() {
    #expect(LiveStamp(size: 1, mtime: Date(timeIntervalSince1970: -5)).fingerprint == Fingerprint(size: 1, mtime: 0))
    #expect(LiveStamp(size: 1, mtime: Date(timeIntervalSince1970: 5e9)).fingerprint == Fingerprint(size: 1, mtime: .max))
}

// The helpers the commands ask

@Test func unsyncedMeansASeenEditAConflictOrAnUnseenEdit() {
    #expect(!LiveDecision.isUnsynced(state(), .same))
    #expect(!LiveDecision.isUnsynced(state(), .touched))
    #expect(!LiveDecision.isUnsynced(state(paused: true), .same))
    #expect(!LiveDecision.isUnsynced(state(), nil))
    #expect(LiveDecision.isUnsynced(state(), .changed))
    #expect(LiveDecision.isUnsynced(state(), .needDigest))
    #expect(LiveDecision.isUnsynced(state(dirty: true), .same))
    #expect(LiveDecision.isUnsynced(state(conflict: true), .same))
    #expect(LiveDecision.isUnsynced(state(dirty: true), nil))
}

@Test func aRemovalForgetsOnlySyncedCopiesUnlessForced() {
    #expect(LiveDecision.afterRemoval(state(), .same, force: false) == .forget)
    #expect(LiveDecision.afterRemoval(state(), nil, force: false) == .forget)
    #expect(LiveDecision.afterRemoval(state(), .changed, force: false) == .conflict(.removed))
    #expect(LiveDecision.afterRemoval(state(dirty: true), .same, force: false) == .conflict(.removed))
    #expect(LiveDecision.afterRemoval(state(conflict: true), .same, force: false) == .conflict(.removed))
    #expect(LiveDecision.afterRemoval(state(dirty: true), .changed, force: true) == .forget)
}

@Test func conflictKindsFollowTheServer() {
    #expect(LiveDecision.conflictKind(for: .file(other)) == .changed(other))
    #expect(LiveDecision.conflictKind(for: .missing) == .removed)
    #expect(LiveDecision.conflictKind(for: .notFile(.symlink)) == .notAFile)
    #expect(LiveDecision.conflictKind(for: .notChecked) == nil)
    #expect(LiveDecision.conflictKind(for: .unreachable("down")) == nil)
}

@Test func keepLocalExpectsWhatTheConflictSaw() {
    #expect(LiveDecision.keepLocalExpectation(state(), conflict: .changed(other)) == .file(other))
    #expect(LiveDecision.keepLocalExpectation(state(), conflict: .removed) == .absent)
    #expect(LiveDecision.keepLocalExpectation(state(), conflict: .notAFile) == nil)
    #expect(LiveDecision.keepLocalExpectation(state(), conflict: nil) == .file(base))
    #expect(LiveDecision.keepLocalExpectation(LiveState(base: nil), conflict: nil) == .absent)
}

/// The shelf and sidebar show the most pressing status; Forget Synced Live Files takes only files
/// with nothing unsynced, paused ones included.
@Test func aLiveFilesStatusIsItsMostPressingState() {
    func file(dirty: Bool = false, paused: Bool = false, conflict: Bool = false, uploading: Bool = false) -> LiveFile {
        LiveFile(id: LiveFileID(), path: RemotePath(string: "/srv/note.txt"), dirty: dirty, paused: paused, conflict: conflict, uploading: uploading)
    }
    #expect(file(dirty: true, paused: true, conflict: true, uploading: true).status == .conflict)
    #expect(file(dirty: true, paused: true, uploading: true).status == .uploading)
    #expect(file(dirty: true, paused: true).status == .paused)
    #expect(file(dirty: true).status == .dirty)
    #expect(file().status == .synced)
    #expect(file().isSynced)
    #expect(file(paused: true).isSynced)
    #expect(!file(dirty: true, paused: true).isSynced)
    #expect(!file(uploading: true).isSynced)
    #expect(!file(conflict: true).isSynced)
}

// Files beside a working copy

@Test func aSiblingNameFitsTheMacsLimitAndNeverIsTheCopysOwnName() {
    #expect(LiveDecision.siblingName(of: "note.txt", suffix: " (server)") == "note.txt (server)")
    #expect(LiveDecision.siblingName(of: "note.txt", prefix: ".", suffix: ".transfer-refresh") == ".note.txt.transfer-refresh")
    // 250 bytes of two-byte scalars: the cut keeps whole scalars and the result fits.
    let long = String(repeating: "é", count: 125)
    let copy = LiveDecision.siblingName(of: long, suffix: " (server)")
    #expect(copy.utf8.count <= 255)
    #expect(copy.hasSuffix(" (server)"))
    #expect(long.hasPrefix(String(copy.dropLast(" (server)".count))))
    let fresh = LiveDecision.siblingName(of: long, prefix: ".", suffix: ".transfer-refresh")
    #expect(fresh.utf8.count <= 255)
    #expect(fresh.hasPrefix(".") && fresh.hasSuffix(".transfer-refresh"))
    // A 255-byte name that already ends in " (server)" would be cut back to itself.
    let clash = String(repeating: "a", count: 246) + " (server)"
    #expect(LiveDecision.siblingName(of: clash, suffix: " (server)") != clash)
    #expect(LiveDecision.siblingName(of: clash, suffix: " (server)").utf8.count <= 255)
}

// Keep Remote with no file on the server

@Test func keepRemoteForgetsOnlyWhatTheConflictShowed() {
    #expect(LiveDecision.keepRemoteForgets(.removed, server: .missing))
    #expect(LiveDecision.keepRemoteForgets(.notAFile, server: .notFile(.directory)))
    #expect(!LiveDecision.keepRemoteForgets(.changed(other), server: .missing))
    #expect(!LiveDecision.keepRemoteForgets(.changed(other), server: .notFile(.directory)))
    #expect(!LiveDecision.keepRemoteForgets(.removed, server: .notFile(.directory)))
    #expect(!LiveDecision.keepRemoteForgets(.notAFile, server: .missing))
    #expect(!LiveDecision.keepRemoteForgets(nil, server: .missing))
}

// A timed check of the server

/// The server holding the base clears a flag; any other file flags it; our own unconfirmed upload
/// and an answer that is not known change nothing.
@Test func aCheckFlagsAChangeButNotTheBaseOrOurOwnUpload() {
    #expect(LiveDecision.afterCheck(state(), .same, server: .file(base)) == .clear)
    #expect(LiveDecision.afterCheck(state(), .same, server: .file(other)) == .flag(.changed(other)))
    #expect(LiveDecision.afterCheck(state(), .touched, server: .file(other)) == .flag(.changed(other)))
    var uploading = state(dirty: true)
    uploading.pending = LiveStamp(size: 12, mtime: Date(timeIntervalSince1970: 1_700_000_500.5))
    #expect(LiveDecision.afterCheck(uploading, .changed, server: .file(other)) == .none)
    #expect(LiveDecision.afterCheck(state(), .same, server: .unreachable("down")) == .none)
    #expect(LiveDecision.afterCheck(state(), .same, server: .notChecked) == .none)
    #expect(LiveDecision.afterCheck(LiveState(base: nil), .same, server: .file(other)) == .none)
}

/// A file gone from the server is flagged as removed (or replaced), never forgotten: no answer of
/// the check drops a record.
@Test func aCheckFlagsARemovedFile() {
    #expect(LiveDecision.afterCheck(state(), .same, server: .missing) == .flag(.removed))
    #expect(LiveDecision.afterCheck(state(), .same, server: .notFile(.directory)) == .flag(.notAFile))
    #expect(LiveDecision.afterCheck(state(dirty: true), nil, server: .missing) == .flag(.removed))
}

/// Edits the server lacks meet the changed server as a conflict at once, uploading nothing: the
/// next save would raise it anyway. A paused file, a missing copy, and a copy whose bytes are not
/// known to differ are only flagged; a conflict already raised is left to its choice.
@Test func aCheckRaisesTheConflictAtOnceForUnsyncedEdits() {
    #expect(LiveDecision.afterCheck(state(), .changed, server: .file(other)) == .conflict(.changed(other)))
    #expect(LiveDecision.afterCheck(state(dirty: true), .changed, server: .file(other)) == .conflict(.changed(other)))
    #expect(LiveDecision.afterCheck(state(dirty: true), .changed, server: .missing) == .conflict(.removed))
    #expect(LiveDecision.afterCheck(state(dirty: true), .needDigest, server: .file(other)) == .conflict(.changed(other)))
    #expect(LiveDecision.afterCheck(state(), .needDigest, server: .file(other)) == .flag(.changed(other)))
    #expect(LiveDecision.afterCheck(state(dirty: true, paused: true), .changed, server: .file(other)) == .flag(.changed(other)))
    #expect(LiveDecision.afterCheck(state(dirty: true), .changed, server: .file(base)) == .clear)
    #expect(LiveDecision.afterCheck(state(dirty: true, conflict: true), .changed, server: .file(other)) == .none)
    #expect(LiveDecision.afterCheck(state(conflict: true), .same, server: .file(base)) == .none)
}

/// A flag shows before every status but a conflict, and leaves a file's other facts alone.
@Test func aServerChangeShowsAfterAConflictOnly() {
    func file(_ change: LiveFile.ServerChange?, conflict: Bool = false, paused: Bool = false) -> LiveFile {
        LiveFile(id: LiveFileID(), path: RemotePath(string: "/srv/note.txt"), dirty: false, paused: paused, conflict: conflict, uploading: false, serverChange: change)
    }
    #expect(file(.changed).status == .changedOnServer)
    #expect(file(.removed, paused: true).status == .removedFromServer)
    #expect(file(.changed, conflict: true).status == .conflict)
    #expect(file(nil).status == .synced)
    #expect(file(.changed).isSynced)
}

/// Stop Live Editing stops a synced batch at once; a batch holding edits nobody was warned
/// about stops nothing and names every unsynced file, so Cancel keeps them all.
@Test func stoppingAsksBeforeAnyUnwarnedEditIsLost() {
    #expect(LiveDecision.stopPlan(unsynced: [Int](), warned: []) == .stop)
    #expect(LiveDecision.stopPlan(unsynced: [1], warned: []) == .ask([1]))
    #expect(LiveDecision.stopPlan(unsynced: [1, 2], warned: [1]) == .ask([1, 2]))
    #expect(LiveDecision.stopPlan(unsynced: [1, 2], warned: [1, 2, 3]) == .stop)
}

