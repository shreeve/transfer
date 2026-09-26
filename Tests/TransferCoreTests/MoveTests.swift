import Foundation
import Testing
@testable import TransferCore

/// A lookalike the user replaced is the move's own copy; one the user skipped never is (D9). A
/// lookalike that reached the destination during the copy, after a snapshot of it, passed for the
/// copy when skipped, and the original was removed (XFR-01): only what the move wrote counts (D6).
@Test func moveCheckCountsOnlyWhatTheMoveWrote() {
    let file: [TreeKey: TreeEntry] = ["": .file(size: 4, mtime: 9)]
    #expect(MoveCheck.verdict(source: file, after: file, written: []) == .alreadyThere([""]))
    #expect(MoveCheck.verdict(source: file, after: file, written: [""]) == .remove)
    // Replaced, but the copy is not the original's.
    #expect(MoveCheck.verdict(source: file, after: ["": .file(size: 4, mtime: 8)], written: [""]) == .incomplete([""]))
    // A folder merged into counts without being written; what it holds does not.
    let tree: [TreeKey: TreeEntry] = ["": .directory, "a": .link, "b": .file(size: 1, mtime: 1)]
    #expect(MoveCheck.verdict(source: tree, after: tree, written: ["b"]) == .alreadyThere(["a"]))
    #expect(MoveCheck.verdict(source: tree, after: tree, written: ["a", "b"]) == .remove)
    #expect(MoveCheck.verdict(source: tree, after: ["": .file(size: 1, mtime: 1)], written: ["", "a", "b"]) == .incomplete(["", "a", "b"]))
}

/// A server name in two Unicode forms, or two names that are not UTF-8, once made one String key,
/// so the one copy on this Mac's disk passed for both and a move removed both originals (CLIP-06).
@Test func treeKeysKeepEveryServerNameApart() {
    let composed = TreeKey(bytes: Array("caf\u{E9}".utf8))
    let decomposed = TreeKey(bytes: Array("cafe\u{301}".utf8))
    #expect(composed != decomposed)
    #expect(TreeKey(bytes: [0x61, 0xFF]) != TreeKey(bytes: [0x61, 0xFE]))
    let source: [TreeKey: TreeEntry] = ["": .directory, composed: .file(size: 1, mtime: 1), decomposed: .file(size: 1, mtime: 1)]
    let copy: [TreeKey: TreeEntry] = ["": .directory, composed: .file(size: 1, mtime: 1)]
    #expect(MoveCheck.verdict(source: source, after: copy, written: Set(copy.keys)) == .incomplete([decomposed]))
    #expect(TreeKey("a/b").components == [Array("a".utf8), Array("b".utf8)])
    #expect(TreeKey("").appending(Array("a".utf8)).appending(Array("b".utf8)) == "a/b")
}

/// A source whose server gives no time proves nothing, even where the sizes match.
@Test func moveCheckNeedsTheSourceTimeToo() {
    let source: [TreeKey: TreeEntry] = ["": .file(size: 4)]
    #expect(MoveCheck.verdict(source: source, after: ["": .file(size: 4, mtime: 9)], written: [""]) == .incomplete([""]))
    #expect(MoveCheck.verdict(source: source, after: ["": .file(size: 4)], written: [""]) == .incomplete([""]))
}

@Test func nameClashFindsNamesThisMacCannotHoldApart() {
    var cased = NameClash(ignoringCase: true)
    for key: TreeKey in ["README", "docs", "docs/a", "readme"] { cased.add(key) }
    #expect(cased.found.map { [$0.0, $0.1] } == ["README", "readme"])

    var exact = NameClash(ignoringCase: false)
    exact.add("README")
    exact.add("readme")
    #expect(exact.found == nil)
    exact.add(TreeKey(bytes: Array("caf\u{E9}".utf8)))
    exact.add(TreeKey(bytes: Array("cafe\u{301}".utf8)))
    #expect(exact.found != nil)

    // APFS folds case fully: these pairs are one name on a case-insensitive disk (R-C1).
    for (first, second) in [("Straße", "STRASSE"), ("ΑΣ", "ας"), ("ﬁle", "FILE")] {
        var folding = NameClash(ignoringCase: true)
        folding.add(TreeKey(stringLiteral: first))
        folding.add(TreeKey(stringLiteral: second))
        #expect(folding.found != nil)
    }

    var undecodable = NameClash(ignoringCase: false)
    undecodable.add(TreeKey(bytes: [0x61, 0xFF]))
    undecodable.add(TreeKey(bytes: [0x61, 0xFE]))
    #expect(undecodable.found != nil)
}

@Test func keptItemsAreNamedOnceForEachReason() {
    let kept = TransferKept([.init("a", .incomplete), .init("b", .incomplete), .init("c", .live(2))], moving: true, place: "on this Mac")
    #expect(kept.localizedDescription == "Kept “a” and “b” on this Mac: the copy is not complete. Kept “c” on this Mac: 2 Live files have unsynced edits.")
    #expect(TransferKept([.init("d", .changed)], moving: true, place: "on the other server").localizedDescription
        == "“d” changed during the move, and what changed was kept on the other server.")
    #expect(TransferKept([.init("a", .failed("No such file")), .init("b", .alreadyThere)], moving: false, place: "on this Mac").localizedDescription
        == "Could not copy “a”: No such file. Kept “b” on this Mac: something with that name was already at the destination and was not replaced, so this move cannot tell its own copy from it.")
    #expect(TransferKept.Reason(.remove) == nil)
    #expect(TransferKept.Reason(.alreadyThere(["x"])) == .alreadyThere)
}

/// Sizes are a server's numbers: two that add past 2^64 trapped Copy (SEC2-04).
@Test func sizesFromAServerSaturate() {
    var tally = ClipTally()
    tally.add(root: .file(size: .max - 1))
    tally.add(root: .file(size: 2))
    #expect(tally.bytes == .max)
    #expect(UInt64(3).saturatingAdd(4) == 7)
}

/// A paste whose items could not be copied is a failure the user must see, not a grey "Kept".
@Test func keptWithAFailedItemIsAFailure() {
    #expect(!TransferKept([.init("a", .alreadyThere), .init("b", .live(1))], moving: true, place: "on this Mac").hasFailures)
    #expect(TransferKept([.init("a", .failed("No such file")), .init("b", .alreadyThere)], moving: false, place: "on this Mac").hasFailures)
}
