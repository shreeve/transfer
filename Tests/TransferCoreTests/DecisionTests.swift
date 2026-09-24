import Foundation
import Testing
import TransferCore

@Test func columnTrailSelectsTheWayDownToASelectedFolder() {
    let root = RemotePath(string: "/home/u")
    let folder = RemotePath(string: "/home/u/work/movedir")
    let trail = ColumnTrail.columns(root: root, path: folder, selection: [folder])
    #expect(trail == [
        ColumnTrail.Column(folder: root, selected: [RemotePath(string: "/home/u/work")]),
        ColumnTrail.Column(folder: RemotePath(string: "/home/u/work"), selected: [folder]),
        ColumnTrail.Column(folder: folder, selected: []),
    ])
}

@Test func columnTrailSelectsFilesInTheLocationsColumn() {
    let root = RemotePath(string: "/")
    let folder = RemotePath(string: "/srv")
    let files: Set<RemotePath> = [RemotePath(string: "/srv/a.txt"), RemotePath(string: "/srv/b.txt")]
    let trail = ColumnTrail.columns(root: root, path: folder, selection: files)
    #expect(trail == [
        ColumnTrail.Column(folder: root, selected: [folder]),
        ColumnTrail.Column(folder: folder, selected: files),
    ])
}

@Test func columnTrailAtTheRootIgnoresSelectionElsewhere() {
    let root = RemotePath(string: "/home/u")
    let stray = RemotePath(string: "/tmp/x")
    let file = RemotePath(string: "/home/u/notes.txt")
    #expect(ColumnTrail.columns(root: root, path: root, selection: [file, stray, root]) == [
        ColumnTrail.Column(folder: root, selected: [file]),
    ])
}

@Test func columnTrailOutsideTheRootShowsOnlyTheRoot() {
    let root = RemotePath(string: "/home/u")
    let trail = ColumnTrail.columns(root: root, path: RemotePath(string: "/home/other"), selection: [RemotePath(string: "/home/other/x")])
    #expect(trail == [ColumnTrail.Column(folder: root, selected: [])])
}

@Test func editableExtensionsOpenLive() {
    for name in ["notes.txt", "app.swift", "main.rs", "page.tsx", "config.json", "clip.rip"] {
        #expect(EditableFile.openKind(fileName: name, extensions: TransferConfig.builtIn.extensionSet) == .live)
    }
}

@Test func documentsOpenForViewing() {
    for name in ["photo.jpg", "scan.png", "book.pdf", "movie.mp4", "archive.zip"] {
        #expect(EditableFile.openKind(fileName: name, extensions: TransferConfig.builtIn.extensionSet) == .view)
    }
}

@Test func keepBothInsertsANumberBeforeTheExtension() {
    let name = KeepBothName.next(existing: ["report.pdf", "report 2.pdf"], original: "report.pdf")
    #expect(name == "report 3.pdf")
}

@Test func duplicateUsesCopySuffix() {
    let name = KeepBothName.duplicate(existing: ["notes.txt"], original: "notes.txt")
    #expect(name == "notes copy.txt")
    #expect(KeepBothName.duplicate(existing: ["notes copy.txt", "notes copy 2.txt"], original: "notes.txt") == "notes copy 3.txt")
    #expect(KeepBothName.duplicate(existing: [], original: ".env") == ".env copy")
    #expect(KeepBothName.next(existing: [], original: "Makefile") == "Makefile 2")
}

/// New Folder and a Live conflict's Keep Both named files with their own loops, outside Core.
@Test func everyMadeUpNameIsTheFirstFreeOne() {
    #expect(KeepBothName.untitledFolder(existing: []) == "untitled folder")
    #expect(KeepBothName.untitledFolder(existing: ["untitled folder", "untitled folder 2"]) == "untitled folder 3")
    #expect(KeepBothName.fromThisMac(existing: ["note.txt"], original: "note.txt") == "note.txt (from this Mac)")
    #expect(KeepBothName.fromThisMac(existing: ["note.txt (from this Mac)"], original: "note.txt") == "note.txt (from this Mac 2)")
    #expect(KeepBothName.firstFree(existing: ["a0", "a1"], from: 0) { "a\($0)" } == "a2")
}

@Test func matchingSizeAndTimeSkipsTheCopy() {
    let source = RemoteItem(path: RemotePath(string: "/a"), kind: .file, size: 4, mtime: 10)
    let destination = RemoteItem(path: RemotePath(string: "/b"), kind: .file, size: 4, mtime: 10)
    let decision = CopyRules.fileDisposition(source: source, destination: destination)
    #expect(decision == .skip)
}

@Test func retriesOnlyDroppedConnectionsAndTimeouts() {
    #expect(RetryPolicy.isRetryable(TransferError.connectionLost("closed")))
    #expect(RetryPolicy.isRetryable(TransferError.timeout("stat")))
    #expect(!RetryPolicy.isRetryable(TransferError.authenticationFailed("no")))
    #expect(!RetryPolicy.isRetryable(TransferError.permissionDenied("no")))
    #expect(!RetryPolicy.isRetryable(TransferError.hostKeyRejected))
    #expect(RetryPolicy.delay(afterAttempt: 0) == 1)
    #expect(RetryPolicy.delay(afterAttempt: 2) == 4)
    #expect(RetryPolicy.delay(afterAttempt: 3) == nil)
}

@Test func cacheEvictionDropsTheOldestFirst() {
    let entries = [
        CacheEntry(id: "new", size: 40, lastUsed: Date(timeIntervalSince1970: 300)),
        CacheEntry(id: "old", size: 40, lastUsed: Date(timeIntervalSince1970: 100)),
        CacheEntry(id: "mid", size: 40, lastUsed: Date(timeIntervalSince1970: 200)),
    ]
    #expect(CacheEviction.victims(entries, limit: 100) == ["old"])
    #expect(CacheEviction.victims(entries, limit: 50) == ["old", "mid"])
    #expect(CacheEviction.victims(entries, limit: 200).isEmpty)
}

@Test func knownHostsFilesComeFromSSHConfig() {
    let output = """
    user ada
    userknownhostsfile /Users/ada/.ssh/known_hosts /Users/ada/.ssh/known_hosts2
    globalknownhostsfile /etc/ssh/ssh_known_hosts
    """
    #expect(KnownHosts.files(sshConfigOutput: output) == [
        "/Users/ada/.ssh/known_hosts", "/Users/ada/.ssh/known_hosts2", "/etc/ssh/ssh_known_hosts",
    ])
}

@Test func hostKeySituationComparesTypeAndKey() {
    let stored = KnownHosts.entries(keygenOutput: """
    # Host box found: line 3
    box ssh-ed25519 AAAAold
    # Host box found: line 9
    @cert-authority box ssh-rsa AAAArsa
    """)
    #expect(stored.count == 2)
    #expect(KnownHosts.situation(offered: HostKeyLine(host: "box", keyType: "ssh-ed25519", key: "AAAAold"), stored: stored) == .unchanged)
    #expect(KnownHosts.situation(offered: HostKeyLine(host: "box", keyType: "ssh-ed25519", key: "AAAAnew"), stored: stored) == .changed)
    #expect(KnownHosts.situation(offered: HostKeyLine(host: "box", keyType: "ecdsa-sha2-nistp256", key: "AAAAec"), stored: stored) == .firstSeen)
    #expect(KnownHosts.situation(offered: HostKeyLine(host: "box", keyType: "ssh-ed25519", key: "x"), stored: []) == .firstSeen)
}

@Test func socketNameIsShortAndStable() {
    let id = ConnectionID(rawValue: UUID(uuidString: "F10955FD-A0B1-44DA-B362-C9ED14BA0668")!)
    #expect(id.socketName == "f10955fda0b1")
    #expect(id.socketName.count == 12)
}

/// A file dated before 1970 or after 2106 once crashed an upload and a Live stamp.
@Test func sftpTimesClampInsteadOfTrapping() {
    #expect(SFTPTime.seconds(Date(timeIntervalSince1970: 1_700_000_000.9)) == 1_700_000_000)
    #expect(SFTPTime.seconds(Date(timeIntervalSince1970: -86_400)) == 0)
    #expect(SFTPTime.seconds(Date.distantPast) == 0)
    #expect(SFTPTime.seconds(Date.distantFuture) == UInt32.max)
    #expect(LiveStamp(size: 1, mtime: Date(timeIntervalSince1970: -1)).fingerprint.mtime == 0)
}

@Test func directoriesAlwaysSortAboveFiles() {
    let items = [
        RemoteItem(path: RemotePath(string: "/b.txt"), kind: .file, size: 5, mtime: 9),
        RemoteItem(path: RemotePath(string: "/zeta"), kind: .directory, mtime: 1),
        RemoteItem(path: RemotePath(string: "/a.txt"), kind: .file, size: 1, mtime: 2),
        RemoteItem(path: RemotePath(string: "/alpha"), kind: .directory, mtime: 8),
    ]
    let byName = ListingSort.apply(items, sort: SortConfiguration(column: "name", ascending: true)).map(\.name)
    #expect(byName == ["alpha", "zeta", "a.txt", "b.txt"])
    let byNameDescending = ListingSort.apply(items, sort: SortConfiguration(column: "name", ascending: false)).map(\.name)
    #expect(byNameDescending == ["zeta", "alpha", "b.txt", "a.txt"])
    let byTime = ListingSort.apply(items, sort: SortConfiguration(column: "mtime", ascending: true)).map(\.name)
    #expect(byTime == ["zeta", "alpha", "a.txt", "b.txt"])
    let mixed = ListingSort.apply(items, sort: SortConfiguration(foldersFirst: false)).map(\.name)
    #expect(mixed == ["a.txt", "alpha", "b.txt", "zeta"])
    let old = try? JSONDecoder().decode(SortConfiguration.self, from: Data(#"{"column":"name","ascending":true}"#.utf8))
    #expect(old?.foldersFirst == true)
}

@Test func caseInsensitiveSortFoldsNamesAndKeepsRawOrderForTies() {
    let items = ["b.txt", "A.txt", "a.txt", "B.txt"].map { RemoteItem(path: RemotePath(string: "/" + $0), kind: .file) }
    let raw = ListingSort.apply(items, sort: SortConfiguration()).map(\.name)
    #expect(raw == ["A.txt", "B.txt", "a.txt", "b.txt"])
    let folded = ListingSort.apply(items, sort: SortConfiguration(caseInsensitive: true)).map(\.name)
    #expect(folded == ["A.txt", "a.txt", "B.txt", "b.txt"])
    let decoded = try? JSONDecoder().decode(SortConfiguration.self, from: Data(#"{"column":"size","ascending":false}"#.utf8))
    #expect(decoded == SortConfiguration(column: "size", ascending: false, caseInsensitive: false))
}

@Test func syntaxPreviewKeepsItsOwnMarkupOutOfStrings() {
    let html = SyntaxPreview.html(text: "const a = 'x' // note\nlet b = \"k\"", fileName: "a.js")
    #expect(html.contains("<span class=\"k\">const</span> a = <span class=\"s\">'x'</span> <span class=\"c\">// note</span>"))
    #expect(html.contains("<span class=\"k\">let</span> b = <span class=\"s\">\"k\"</span>"))
    #expect(html.components(separatedBy: "<span").count == 6)
}

@Test func syntaxPreviewEscapesAndLeavesStringsWhole() {
    let html = SyntaxPreview.html(text: "if (a < b) { return \"// not a comment\" }", fileName: "a.js")
    #expect(html.contains("(a &lt; b)"))
    #expect(html.contains("<span class=\"s\">\"// not a comment\"</span>"))
    #expect(!html.contains("class=\"c\""))
}

@Test func unitsScaleToThreeCharacters() {
    #expect(Units.bytes(0) == "  0 B")
    #expect(Units.bytes(959) == "959 B")
    #expect(Units.bytes(1000) == "1.0kB")
    #expect(Units.bytes(14336) == " 14kB")
    #expect(Units.bytes(999_499) == "999kB")
    #expect(Units.bytes(999_500) == "1.0MB")
    #expect(Units.bytes(1_500_000_000) == "1.5GB")
    #expect(Units.scale(0.0025, unit: "s") == "2.5ms")
    #expect(Units.scale(0.000_000_4, unit: "s") == "400ns")
    #expect(Units.scale(.infinity, unit: "B") == "??? B")
    #expect(Units.scale(1e16, unit: "B") == "??? B")
}

@Test func clipTextNamesASingleItem() {
    var tally = ClipTally()
    tally.add(root: .file(size: 2100))
    tally.complete = true
    #expect(ClipText.summary(tally, name: "notes.txt") == "“notes.txt” (2.1kB)")
}

@Test func clipTextCountsFilesInsideFolders() {
    var tally = ClipTally()
    for _ in 0..<3 { tally.add(root: .file(size: 1000)) }
    tally.add(root: .directory)
    #expect(ClipText.summary(tally, name: nil) == "3 files and 1 folder (counting… 3 files so far)")
    for _ in 0..<28 { tally.add(inside: .file(size: 1000)) }
    tally.add(inside: .directory)
    tally.complete = true
    #expect(ClipText.summary(tally, name: nil) == "3 files and 1 folder (31 files in all, 31kB)")
}

@Test func clipTextForFoldersAlone() {
    var tally = ClipTally()
    tally.add(root: .directory)
    tally.add(root: .directory)
    tally.complete = true
    #expect(ClipText.summary(tally, name: nil) == "2 folders (no files)")
    tally.add(inside: .link)
    #expect(ClipText.summary(tally, name: nil) == "2 folders (1 file, 0 B)")
}

@Test func pasteRefusesAFolderIntoItself() {
    let site = RemotePath(string: "/srv/site")
    #expect(PasteRules.refusal(sources: [site], into: site) != nil)
    #expect(PasteRules.refusal(sources: [site], into: RemotePath(string: "/srv/site/assets")) != nil)
    #expect(PasteRules.refusal(sources: [site], into: RemotePath(string: "/srv/site2")) == nil)
    #expect(PasteRules.refusal(sources: [site], into: RemotePath(string: "/srv")) == nil)
}

/// A `..` in the destination once hid that it was inside the folder being pasted (SFC-13).
@Test func pasteRefusalSeesThroughDotSegments() {
    let site = RemotePath(string: "/srv/site")
    #expect(PasteRules.refusal(sources: [site], into: RemotePath(string: "/srv/x/../site/sub")) != nil)
    #expect(PasteRules.refusal(sources: [site], into: RemotePath(string: "/srv/./site")) != nil)
    #expect(PasteRules.refusal(sources: [RemotePath(string: "/srv/a/../site")], into: RemotePath(string: "/srv/site/b")) != nil)
    #expect(PasteRules.refusal(sources: [site], into: RemotePath(string: "/srv/site/../site2")) == nil)
}

@Test func pasteIntoTheSameFolderMakesACopy() {
    let file = RemotePath(string: "/srv/notes.txt")
    #expect(PasteRules.destinationName(for: file, into: RemotePath(string: "/srv"), existing: ["notes.txt"]) == "notes copy.txt")
    #expect(PasteRules.destinationName(for: file, into: RemotePath(string: "/tmp"), existing: ["notes.txt"]) == "notes.txt")
}

@Test func treeCheckFindsWhatAMoveWouldLose() {
    let source: [String: TreeEntry] = ["": .directory, "a.txt": .file(size: 4), "sub": .directory, "sub/b": .link]
    #expect(TreeCheck.missing(source: source, destination: source).isEmpty)
    var partial = source
    partial["a.txt"] = .file(size: 3)
    partial["sub/b"] = nil
    partial["extra"] = .file(size: 1)
    #expect(TreeCheck.missing(source: source, destination: partial) == ["a.txt", "sub/b"])
}

/// A FIFO, socket, or device walked as a plain empty file once let a move pass the check with
/// an empty file at its name, and remove the original.
@Test func treeCheckNeverCountsASpecialFileAsCopied() {
    #expect(TreeEntry(RemoteItem(path: RemotePath(string: "/srv/fifo"), kind: .other, size: 0, mtime: 1)) == .other)
    let source: [String: TreeEntry] = ["": .directory, "a.txt": .file(size: 4), "fifo": .other]
    #expect(TreeCheck.missing(source: source, destination: source) == ["fifo"])
    #expect(TreeCheck.missing(source: source, destination: ["": .directory, "a.txt": .file(size: 4), "fifo": .file(size: 0)]) == ["fifo"])
    #expect(TreeCheck.missing(source: ["": .other], destination: ["": .other]) == [""])
    var tally = ClipTally()
    tally.add(root: .other)
    tally.add(root: .directory)
    tally.add(inside: .other)
    #expect(tally.files == 1)
    #expect(tally.allFiles == 2)
    #expect(tally.bytes == 0)
}

/// A move whose collision was skipped once compared the source with the file already there, and
/// removed the source when name and size matched.
@Test func treeCheckTellsAFileAlreadyThereFromTheCopy() {
    let source: [String: TreeEntry] = ["": .file(size: 4, mtime: 1_700_000_000)]
    #expect(TreeCheck.missing(source: source, destination: ["": .file(size: 4, mtime: 1_700_000_000)]).isEmpty)
    #expect(TreeCheck.missing(source: source, destination: ["": .file(size: 4, mtime: 1_600_000_000)]) == [""])
    #expect(TreeCheck.missing(source: source, destination: ["": .file(size: 4)]).isEmpty)
    #expect(TreeCheck.missing(source: source, destination: ["": .file(size: 5, mtime: 1_700_000_000)]) == [""])
}
