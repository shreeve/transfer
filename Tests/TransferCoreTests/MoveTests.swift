import Foundation
import Testing
@testable import TransferCore

/// A lookalike the user replaced is the move's own copy; one the user skipped never is (D9).
@Test func moveCheckCountsOnlyWhatTheMoveWrote() {
    let file: [TreeKey: TreeEntry] = ["": .file(size: 4, mtime: 9)]
    #expect(MoveCheck.verdict(source: file, before: file, after: file) == .alreadyThere([""]))
    #expect(MoveCheck.verdict(source: file, before: file, after: file, written: [""]) == .remove)
    // Replaced, but the copy is not the original's.
    #expect(MoveCheck.verdict(source: file, before: file, after: ["": .file(size: 4, mtime: 8)], written: [""]) == .incomplete([""]))
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
    #expect(MoveCheck.verdict(source: source, before: [:], after: copy) == .incomplete([decomposed]))
    #expect(TreeKey("a/b").components == [Array("a".utf8), Array("b".utf8)])
    #expect(TreeKey("").appending(Array("a".utf8)).appending(Array("b".utf8)) == "a/b")
}

/// A source whose server gives no time proves nothing, even where the sizes match.
@Test func moveCheckNeedsTheSourceTimeToo() {
    let source: [TreeKey: TreeEntry] = ["": .file(size: 4)]
    #expect(MoveCheck.verdict(source: source, before: [:], after: ["": .file(size: 4, mtime: 9)]) == .incomplete([""]))
    #expect(MoveCheck.verdict(source: source, before: [:], after: ["": .file(size: 4)]) == .incomplete([""]))
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

    var undecodable = NameClash(ignoringCase: false)
    undecodable.add(TreeKey(bytes: [0x61, 0xFF]))
    undecodable.add(TreeKey(bytes: [0x61, 0xFE]))
    #expect(undecodable.found != nil)
}

@Test func keptItemsAreNamedOnceForEachReason() {
    let kept = TransferKept([.init("a", .incomplete), .init("b", .incomplete), .init("c", .live(2))], moving: true, place: "on this Mac")
    #expect(kept.localizedDescription == "Kept “a” and “b” on this Mac: the copy is not complete. Kept “c” on this Mac: 2 Live files have unsynced edits.")
    #expect(TransferKept.Reason(.remove) == nil)
    #expect(TransferKept.Reason(.alreadyThere(["x"])) == .alreadyThere)
}
