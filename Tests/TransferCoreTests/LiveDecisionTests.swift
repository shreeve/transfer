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
    #expect(LiveDecision.decide(state(), local: present(), server: .file(other), intent: .open) == .refreshLocal(other))
    #expect(LiveDecision.decide(state(), local: present(), server: .notChecked, intent: .open) == .needServer)
    #expect(LiveDecision.decide(state(), local: present(), server: .file(base), intent: .open) == .none)
    #expect(LiveDecision.decide(state(), local: present(), server: .missing, intent: .open) == .none)
    #expect(LiveDecision.decide(state(conflict: true), local: present(), server: .file(other), intent: .open) == .none)
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

@Test func aTouchIsRestampedWhateverTheFlagsAndIntent() {
    let touched = present(at: t0.addingTimeInterval(30), digest: "d0")
    for flags in [state(dirty: true), state(conflict: true), state(paused: true)] {
        #expect(LiveDecision.decide(flags, local: touched, server: .notChecked) == .restamp)
    }
    #expect(LiveDecision.decide(state(), local: touched, server: .file(other), intent: .open) == .restamp)
}

@Test func withoutASyncedDigestAnyNewMtimeIsAChange() {
    let noDigest = LiveState(base: base, synced: synced, syncedDigest: nil)
    #expect(LiveDecision.localChange(noDigest, LiveStamp(size: 10, mtime: t0.addingTimeInterval(30)), digest: nil) == .changed)
    #expect(LiveDecision.decide(noDigest, local: present(at: t0.addingTimeInterval(30)), server: .notChecked) == .needServer)
}

@Test func anUnchangedCopyAcrossFlagsAndIntents() {
    #expect(LiveDecision.decide(state(conflict: true), local: present(), server: .notChecked) == .none)
    #expect(LiveDecision.decide(state(dirty: true), local: present(), server: .file(base), intent: .open) == .markClean)
    // Refreshing wins over marking clean: the bytes are the synced ones either way.
    #expect(LiveDecision.decide(state(dirty: true), local: present(), server: .file(other), intent: .open) == .refreshLocal(other))
    #expect(LiveDecision.decide(state(), local: present(), server: .unreachable("down"), intent: .open) == .none)
    #expect(LiveDecision.decide(state(), local: present(), server: .notFile(.directory), intent: .open) == .none)
    #expect(LiveDecision.decide(state(paused: true), local: present(), server: .file(other), intent: .open) == .refreshLocal(other))
}

@Test func aChangedCopyAcrossFlagsAndIntents() {
    let edited = present(size: 11)
    #expect(LiveDecision.decide(state(paused: true, conflict: true), local: edited, server: .notChecked) == .markDirty)
    #expect(LiveDecision.decide(state(dirty: true, paused: true, conflict: true), local: edited, server: .file(base)) == .none)
    #expect(LiveDecision.decide(state(), local: edited, server: .notChecked, intent: .open) == .needServer)
    #expect(LiveDecision.decide(state(), local: edited, server: .file(base), intent: .open) == .upload(expecting: base))
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
