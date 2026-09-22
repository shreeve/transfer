import Foundation
import Testing
import TransferCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000.25)
private let synced = LiveStamp(size: 10, mtime: t0)
private let base = Fingerprint(kind: .file, size: 10, mtime: 1_700_000_000)
private let other = Fingerprint(kind: .file, size: 12, mtime: 1_700_000_500)

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

@Test func aServerHoldingTheLocalBytesIsAdoptedNotAConflict() {
    // A save that landed but whose reply was lost: the server has the working copy's size and second.
    let edited = LiveStamp(size: 11, mtime: Date(timeIntervalSince1970: 1_700_000_300.4))
    #expect(LiveDecision.decide(state(), local: .present(edited, digest: nil), server: .file(edited.fingerprint)) == .adopt(edited.fingerprint))
    #expect(LiveDecision.decide(state(), local: .present(edited, digest: nil), server: .file(other)) == .conflict(.changed(other)))
}
