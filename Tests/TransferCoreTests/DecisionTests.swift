import Foundation
import Testing
@testable import TransferCore

/// The saved inspector column is rewritten to the preference's state before the split reads it.
@Test func splitFramesAlignToThePreference() {
    let sidebar = "0.000000, 0.000000, 150.000000, 640.000000, NO, NO"
    let content = "150.000000, 0.000000, 410.000000, 640.000000, NO, NO"
    let open = [sidebar, content, "560.000000, 0.000000, 400.000000, 640.000000, NO, NO"]
    let closed = [sidebar, content, "560.000000, 0.000000, 400.000000, 640.000000, YES, NO"]
    #expect(SplitFrames.aligned(open, inspectorShown: true, inspectorMinimum: 240) == nil)
    #expect(SplitFrames.aligned(open, inspectorShown: false, inspectorMinimum: 240) == closed)
    #expect(SplitFrames.aligned(closed, inspectorShown: false, inspectorMinimum: 240) == nil)
    #expect(SplitFrames.aligned(closed, inspectorShown: true, inspectorMinimum: 240) == open)
    let zero = [sidebar, content, "960.000000, 0.000000, 0.000000, 640.000000, NO, NO"]
    // Saved open at width 0 by a window closed mid-collapse.
    #expect(SplitFrames.aligned(zero, inspectorShown: true, inspectorMinimum: 240)?[2] == "960.000000, 0.000000, 240.000000, 640.000000, NO, NO")
    #expect(SplitFrames.aligned(zero, inspectorShown: false, inspectorMinimum: 240)?[2] == "960.000000, 0.000000, 240.000000, 640.000000, YES, NO")
    #expect(SplitFrames.aligned([sidebar, content], inspectorShown: true, inspectorMinimum: 240) == nil)
    #expect(SplitFrames.aligned([sidebar, content, "960, 0, 0"], inspectorShown: true, inspectorMinimum: 240) == nil)
}

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

@Test func pathTrailRunsFromTheRootToTheLocationThenTheOneSelectedItem() {
    let location = RemotePath(string: "/home/shreeve/mvts")
    func step(_ path: String, _ navigable: Bool, selection: Bool = false) -> PathTrail.Step {
        PathTrail.Step(path: RemotePath(string: path), navigable: navigable, isSelection: selection)
    }
    let folders = [step("/", true), step("/home", true), step("/home/shreeve", true), step("/home/shreeve/mvts", false)]
    #expect(PathTrail.steps(location: location, selection: []) == folders)
    let file = RemotePath(string: "/home/shreeve/mvts/a.txt")
    #expect(PathTrail.steps(location: location, selection: [file]) == folders + [step("/home/shreeve/mvts/a.txt", false, selection: true)])
    // Several items, the location itself (a folder selected in column view), or an item elsewhere end at the location.
    #expect(PathTrail.steps(location: location, selection: [file, RemotePath(string: "/home/shreeve/mvts/b.txt")]) == folders)
    #expect(PathTrail.steps(location: location, selection: [location]) == folders)
    #expect(PathTrail.steps(location: location, selection: [RemotePath(string: "/tmp/x")]) == folders)
    #expect(PathTrail.steps(location: RemotePath(string: "/"), selection: []) == [step("/", false)])
    // A name that is not UTF-8 keeps its bytes.
    let odd = RemotePath(bytes: Array("/srv/".utf8) + [0xFF, 0x41])
    #expect(PathTrail.steps(location: odd.appending("x"), selection: [])[2].path == odd)
    // Only a folder above the location goes anywhere.
    #expect(PathTrail.goes(to: RemotePath(string: "/home"), from: location))
    #expect(!PathTrail.goes(to: location, from: location))
    #expect(!PathTrail.goes(to: file, from: location))
    #expect(!PathTrail.goes(to: RemotePath(string: "/home/sh"), from: location))
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

/// Gatekeeper refuses to open a quarantined `.command` or `.tool` in any app, so a Live copy of one
/// could not be edited (E2E): only those Live copies go unquarantined; a `.sh` stays quarantined.
@Test func onlyTerminalScriptLiveCopiesGoUnquarantined() {
    for name in ["run.command", "RUN.COMMAND", "build.tool", "a.sh.command"] {
        #expect(!EditableFile.quarantinesLiveCopy(fileName: name), "\(name)")
    }
    for name in ["run.sh", "run.zsh", "tool.py", "notes.txt", "Makefile", "command", "run.command.txt", "run.", "App.app"] {
        #expect(EditableFile.quarantinesLiveCopy(fileName: name), "\(name)")
    }
}

/// Only what follows the last dot is the extension (COR-1), and a trailing dot leaves none. A name
/// with no dot matches the list by its whole name, so a user's "makefile" entry opens Makefile
/// Live (FR-2); the built-in list holds no such name, and an empty entry matches nothing.
@Test func anExtensionIsWhatFollowsTheLastDot() {
    func kind(_ name: String, _ extensions: Set<String>) -> OpenKind { EditableFile.openKind(fileName: name, extensions: extensions) }
    // Names whose outcome cannot depend on the apps installed: none of these has a type the system
    // could know (`.bashrc` does once an app such as Syntax Highlight declares one, so it is checked
    // against a list of its own below).
    for name in ["README", "Makefile", "LICENSE", "notes.", "..", "a.tar.gz"] {
        #expect(kind(name, TransferConfig.builtIn.extensionSet) == .view, "\(name)")
    }
    #expect(kind(".bashrc", ["bashrc"]) == .live)
    #expect(kind("README", ["readme"]) == .live)
    #expect(kind("Makefile", ["makefile"]) == .live)
    #expect(kind("Makefile", ["make"]) == .view)
    #expect(kind("notes.", ["notes"]) == .view)
    #expect(kind("Notes", [""]) == .view)
    #expect(kind(".env", ["env"]) == .live)
    #expect(kind("a.tar.gz", ["gz"]) == .live)
    #expect(kind("a.tar.gz", ["tar"]) == .view)
    #expect(kind("NOTES.TXT", TransferConfig.builtIn.extensionSet) == .live)
}

@Test func keepBothInsertsANumberBeforeTheExtension() {
    let name = KeepBothName.next(existing: ["report.pdf", "report 2.pdf"], original: "report.pdf")
    #expect(name == "report 3.pdf")
    // Compared as the disk folds names, in one pass.
    #expect(KeepBothName.next(existing: ["report.pdf", "report 2.pdf"], original: "Report.pdf", key: { $0.lowercased() }) == "Report 3.pdf")
}

@Test func duplicateUsesCopySuffix() {
    let name = KeepBothName.duplicate(existing: ["notes.txt"], original: "notes.txt")
    #expect(name == "notes copy.txt")
    #expect(KeepBothName.duplicate(existing: ["notes copy.txt", "notes copy 2.txt"], original: "notes.txt") == "notes copy 3.txt")
    #expect(KeepBothName.duplicate(existing: [], original: ".env") == ".env copy")
    #expect(KeepBothName.next(existing: [], original: "Makefile") == "Makefile 2")
}

/// A temp added 47 bytes to its file's name, past the 255 a name may have when the name took more
/// than 208 (R-T5). The name in it is cut to fit, never inside a character.
@Test func aTempNameFitsTheNameLimit() {
    let id = UUID().uuidString
    #expect(KeepBothName.temp(for: "notes.txt", id: id) == ".notes.txt.transfer-\(id)")
    for name in [String(repeating: "a", count: 255), String(repeating: "é", count: 127), String(repeating: "😀", count: 63)] {
        let temp = KeepBothName.temp(for: name, id: id)
        #expect(temp.utf8.count <= 255 && temp.utf8.count > 250)
        #expect(temp.hasSuffix(".transfer-\(id)"))
        #expect(name.hasPrefix(temp.dropFirst().dropLast(".transfer-\(id)".count)))
    }
}

/// A folder has no extension: "v1.2" duplicated was "v1 copy.2", and kept both "v1 2.2" (R-C3).
@Test func aFolderNameIsNotSplitAtItsLastDot() {
    #expect(KeepBothName.duplicate(existing: ["v1.2"], original: "v1.2", isFolder: true) == "v1.2 copy")
    #expect(KeepBothName.duplicate(existing: ["v1.2", "v1.2 copy"], original: "v1.2", isFolder: true) == "v1.2 copy 2")
    #expect(KeepBothName.next(existing: ["site.d"], original: "site.d", isFolder: true) == "site.d 2")
    #expect(KeepBothName.next(existing: ["site.d"], original: "site.d") == "site 2.d")
}

/// New Folder and a Live conflict's Keep Both named files with their own loops, outside Core.
@Test func everyMadeUpNameIsTheFirstFreeOne() {
    #expect(KeepBothName.untitledFolder(existing: []) == "untitled folder")
    #expect(KeepBothName.untitledFolder(existing: ["untitled folder", "untitled folder 2"]) == "untitled folder 3")
    // The extension stays last, so the sibling opens in the same editor as the file.
    #expect(KeepBothName.fromThisMac(existing: ["note.txt"], original: "note.txt") == "note (from this Mac).txt")
    #expect(KeepBothName.fromThisMac(existing: ["note (from this Mac).txt"], original: "note.txt") == "note (from this Mac 2).txt")
    #expect(KeepBothName.fromThisMac(existing: [], original: "Makefile") == "Makefile (from this Mac)")
    #expect(KeepBothName.firstFree(existing: ["a0", "a1"], from: 0) { "a\($0)" } == "a2")
}

/// A server's own message already says what went wrong; the label is not said twice, as
/// "Permission denied: Permission denied" was.
@Test func aServersMessageIsNotLabeledTwice() {
    #expect(TransferError.permissionDenied("Permission denied").localizedDescription == "Permission denied")
    #expect(TransferError.permissionDenied("").localizedDescription == "Permission denied")
    #expect(TransferError.permissionDenied("notes.txt: Operation not permitted").localizedDescription == "Permission denied: notes.txt: Operation not permitted")
    #expect(TransferError.noSuchFile("No such file").localizedDescription == "No such file")
    #expect(TransferError.noSuchFile("/srv/gone").localizedDescription == "No such file: /srv/gone")
}

@Test func retriesOnlyDroppedConnectionsTimeoutsAndFilesThatChanged() {
    #expect(RetryPolicy.isRetryable(TransferError.connectionLost("closed")))
    #expect(RetryPolicy.isRetryable(TransferError.timeout("stat")))
    #expect(RetryPolicy.isRetryable(TransferError.changedOnServer("grows.bin")))
    #expect(!RetryPolicy.isRetryable(TransferError.authenticationFailed("no")))
    #expect(!RetryPolicy.isRetryable(TransferError.permissionDenied("no")))
    #expect(!RetryPolicy.isRetryable(TransferError.hostKeyRejected))
    #expect(RetryPolicy.delay(afterAttempt: 0) == 1)
    #expect(RetryPolicy.delay(afterAttempt: 2) == 4)
    #expect(RetryPolicy.delay(afterAttempt: 3) == nil)
}

@Test func cacheEvictionDropsTheOldestFirst() {
    let entries: [(id: String, size: UInt64, lastUsed: Date)] = [
        ("new", 40, Date(timeIntervalSince1970: 300)),
        ("old", 40, Date(timeIntervalSince1970: 100)),
        ("mid", 40, Date(timeIntervalSince1970: 200)),
    ]
    #expect(CacheEviction.victims(entries, limit: 100) == ["old"])
    #expect(CacheEviction.victims(entries, limit: 50) == ["old", "mid"])
    #expect(CacheEviction.victims(entries, limit: 200).isEmpty)
}

/// The line a host-key probe reads back: hosts, key type, and key. A marker is skipped; a
/// comment or a short line is no key.
@Test func aKnownHostsLineReadsHostsTypeAndKey() {
    let line = HostKeyLine(line: "  [box.example]:2200,10.0.0.9 ssh-ed25519  AAAAC3Nz comment ")
    #expect(line == HostKeyLine(host: "[box.example]:2200,10.0.0.9", keyType: "ssh-ed25519", key: "AAAAC3Nz"))
    #expect(line?.text == "[box.example]:2200,10.0.0.9 ssh-ed25519 AAAAC3Nz")
    #expect(HostKeyLine(line: "@revoked box ssh-rsa AAAA")?.host == "box")
    #expect(HostKeyLine(line: "# box ssh-rsa AAAA") == nil)
    #expect(HostKeyLine(line: "box ssh-rsa") == nil)
    #expect(HostKeyLine(line: " ") == nil)
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
    let html = SyntaxPreview.html(text: "const a = 'x' // note\nlet b = \"k\"")
    #expect(html.contains("<span class=\"k\">const</span> a = <span class=\"s\">'x'</span> <span class=\"c\">// note</span>"))
    #expect(html.contains("<span class=\"k\">let</span> b = <span class=\"s\">\"k\"</span>"))
    #expect(html.components(separatedBy: "<span").count == 6)
}

/// The inspector's page is transparent over the document background, and in dark mode its
/// colors are the dark ones: the dark rules come after the light rules they override.
@Test func theInspectorsPageFollowsTheAppearance() {
    let html = SyntaxPreview.html(text: "let a = 1", compact: true)
    #expect(html.contains("background:transparent"))
    let light = try! #require(html.range(of: ".k{color:#0b4f9c"))
    let dark = try! #require(html.range(of: "@media(prefers-color-scheme:dark)"))
    #expect(light.lowerBound < dark.lowerBound)
    #expect(html.contains(".k{color:#6cb3ff}"))
}

@Test func syntaxPreviewEscapesAndLeavesStringsWhole() {
    let html = SyntaxPreview.html(text: "if (a < b) { return \"// not a comment\" }")
    #expect(html.contains("(a &lt; b)"))
    // No title: it held the name's extension, a server's text, unescaped (SEC2-12).
    #expect(!html.contains("<title>"))
    #expect(html.contains("<span class=\"s\">\"// not a comment\"</span>"))
    #expect(!html.contains("class=\"c\""))
}

/// A narrow row drops its optional columns last first, keeping the name its floor.
@Test func columnsGiveWayLastFirst() {
    let optional: [Double] = [40, 30, 20]
    // 50 floor + 60 required + 3 spacing of 10 each for the three columns shown.
    #expect(ColumnFit.kept(optional, required: [60], spacing: 10, floor: 50, in: 1000) == 3)
    #expect(ColumnFit.kept(optional, required: [60], spacing: 10, floor: 50, in: 240) == 3)
    #expect(ColumnFit.kept(optional, required: [60], spacing: 10, floor: 50, in: 239) == 2)
    #expect(ColumnFit.kept(optional, required: [60], spacing: 10, floor: 50, in: 210) == 2)
    #expect(ColumnFit.kept(optional, required: [60], spacing: 10, floor: 50, in: 209) == 1)
    #expect(ColumnFit.kept(optional, required: [60], spacing: 10, floor: 50, in: 169) == 0)
    #expect(ColumnFit.kept(optional, required: [60], spacing: 10, floor: 50, in: 120) == 0)
    #expect(ColumnFit.kept([], required: [60], spacing: 10, floor: 50, in: 0) == 0)
}

/// The owner's examples, exactly.
@Test func unitsReadCompactly() {
    #expect(Units.scale(22, unit: "B") == " 22 B")
    #expect(Units.scale(6100, unit: "B") == "6.1kB")
    #expect(Units.scale(78e6, unit: "B") == " 78MB")
    #expect(Units.scale(1.2e9, unit: "B") == "1.2GB")
    #expect(Units.scale(1e6, unit: "B") == "1.0MB")
    #expect(Units.scale(0.821, unit: "s") == "821ms")
    #expect(Units.scale(0.074, unit: "s") == " 74ms")
    #expect(Units.scale(1, unit: "s") == "  1 s")
    #expect(Units.scale(1200, unit: "s") == "1.2ks")
    #expect(Units.scale(0.0074, unit: "s") == "7.4ms")
    #expect(Units.scale(0.000_000_5, unit: "s") == "500ns")
    #expect(Units.scale(3e-6, unit: "s") == "3.0µs")
    #expect(Units.bytes(0) == "  0 B")
    #expect(Units.bytes(5) == "  5 B")
    #expect(Units.bytes(959) == "959 B")
    #expect(Units.bytes(1000) == "1.0kB")
    #expect(Units.bytes(14336) == " 14kB")
    #expect(Units.bytes(77_933_067) == " 78MB")
    #expect(Units.bytes(999_499_999_999_999) == "999TB")
    #expect(Units.bytes(10_000_000_000_000_000) == "??? B")
    #expect(Units.bytes(.max) == "??? B")
    #expect(Units.scale(-1, unit: "B") == "??? B")
    #expect(Units.scale(.nan, unit: "B") == "??? B")
    #expect(Units.scale(.infinity, unit: "B") == "??? B")
    #expect(Units.scale(1e-13, unit: "s") == "??? s")
}

/// Where the rounding turns over: 999.5 goes up a prefix, 9.95 loses its decimal, and 0.995 is
/// still one of the unit.
@Test func unitsRoundAtTheirBoundaries() {
    #expect(Units.scale(999.4, unit: "B") == "999 B")
    #expect(Units.scale(999.5, unit: "B") == "1.0kB")
    #expect(Units.bytes(999_499) == "999kB")
    #expect(Units.bytes(999_500) == "1.0MB")
    #expect(Units.bytes(9_949) == "9.9kB")
    #expect(Units.bytes(9_950) == " 10kB")
    #expect(Units.bytes(9_950_000) == " 10MB")
    #expect(Units.scale(9.95, unit: "s") == " 10 s")
    #expect(Units.scale(0.995, unit: "s") == "  1 s")
    #expect(Units.scale(0.9949, unit: "s") == "995ms")
    #expect(Units.scale(0.000_995, unit: "s") == "1.0ms")
    #expect(Units.scale(999_500e12, unit: "B") == "??? B")
}

/// Every size, and every measure of another unit, is as wide as every other, and close to its value.
@Test func everyMeasureHasOneWidthAndReadsWithinSixPercent() {
    var random = SeededRandom(state: 3)
    let scales: [Character: Double] = ["p": 1e-12, "n": 1e-9, "µ": 1e-6, "m": 1e-3, " ": 1, "k": 1e3, "M": 1e6, "G": 1e9, "T": 1e12]
    for _ in 0..<20_000 {
        let size = random.next() >> (random.next() % 64)
        let text = Units.bytes(size)
        #expect(text.count == 5, "\(size) \(text)")
        #expect(text.hasSuffix("B"))
        guard !text.hasPrefix("???") else {
            #expect(Double(size) >= 999.5e12, "\(size)")
            continue
        }
        let number = Double(text.prefix(3).trimmingCharacters(in: .whitespaces))
        guard let number, let scale = scales[text.dropFirst(3).first!] else {
            Issue.record("\(size) reads \(text)")
            continue
        }
        #expect(abs(number * scale - Double(size)) <= 0.06 * max(1, Double(size)), "\(size) \(text)")
    }
    for exponent in stride(from: -13.0, through: 16, by: 0.01) {
        let value = pow(10, exponent)
        for unit in ["s", "B/s"] {
            #expect(Units.scale(value, unit: unit).count == 4 + unit.count, "\(value)")
        }
    }
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


@Test func moveCheckFindsWhatAMoveWouldLose() {
    let source: [TreeKey: TreeEntry] = ["": .directory, "a.txt": .file(size: 4, mtime: 9), "sub": .directory, "sub/b": .link]
    let written: Set<TreeKey> = ["a.txt", "sub/b"]
    #expect(MoveCheck.verdict(source: source, after: source, written: written) == .remove)
    var partial = source
    partial["a.txt"] = .file(size: 3, mtime: 9)
    partial["sub/b"] = nil
    partial["extra"] = .file(size: 1)
    #expect(MoveCheck.verdict(source: source, after: partial, written: written) == .incomplete(["a.txt", "sub/b"]))
    #expect(MoveCheck.verdict(source: [:], after: [:], written: []) == .incomplete([""]))
}

/// A FIFO, socket, or device walked as a plain empty file once let a move pass the check with
/// an empty file at its name, and remove the original.
@Test func moveCheckNeverCountsASpecialFileAsCopied() {
    #expect(TreeEntry(RemoteItem(path: RemotePath(string: "/srv/fifo"), kind: .other, size: 0, mtime: 1)) == .other)
    let source: [TreeKey: TreeEntry] = ["": .directory, "a.txt": .file(size: 4, mtime: 9), "fifo": .other]
    #expect(MoveCheck.verdict(source: source, after: source, written: Set(source.keys)) == .incomplete(["fifo"]))
    #expect(MoveCheck.verdict(source: source, after: ["": .directory, "a.txt": .file(size: 4, mtime: 9), "fifo": .file(size: 0)], written: ["a.txt", "fifo"]) == .incomplete(["fifo"]))
    #expect(MoveCheck.verdict(source: ["": .other], after: ["": .other], written: []) == .incomplete([""]))
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
@Test func moveCheckTellsAFileAlreadyThereFromTheCopy() {
    let source: [TreeKey: TreeEntry] = ["": .file(size: 4, mtime: 1_700_000_000)]
    let copy: [TreeKey: TreeEntry] = ["": .file(size: 4, mtime: 1_700_000_000)]
    #expect(MoveCheck.verdict(source: source, after: copy, written: [""]) == .remove)
    #expect(MoveCheck.verdict(source: source, after: copy, written: []) == .alreadyThere([""]))
    #expect(MoveCheck.verdict(source: source, after: ["": .file(size: 4, mtime: 1_600_000_000)], written: [""]) == .incomplete([""]))
    #expect(MoveCheck.verdict(source: source, after: ["": .file(size: 4)], written: [""]) == .incomplete([""]))
    #expect(MoveCheck.verdict(source: source, after: ["": .file(size: 5, mtime: 1_700_000_000)], written: [""]) == .incomplete([""]))
    // A folder that was already there may be merged into; a file inside it that was there may not.
    let tree: [TreeKey: TreeEntry] = ["": .directory, "a": .file(size: 1, mtime: 2)]
    #expect(MoveCheck.verdict(source: tree, after: tree, written: ["a"]) == .remove)
    #expect(MoveCheck.verdict(source: tree, after: tree, written: []) == .alreadyThere(["a"]))
}

/// Quit asks whenever it could lose something, including when the Live count never arrived.
@Test func quitAsksOnlyWhenSomethingCouldBeLost() {
    #expect(QuitQuestion(unsynced: 0, running: 0) == nil)
    let unknown = QuitQuestion(unsynced: nil, running: 0)
    #expect(unknown?.message == "Transfer could not check its Live files")
    let edits = QuitQuestion(unsynced: 2, running: 1)
    #expect(edits?.message == "2 Live files have unsynced edits")
    #expect(edits?.detail.hasSuffix("1 transfer not yet finished will stop; a move keeps each original until its copy is complete.") == true)
    #expect(QuitQuestion(unsynced: 0, running: 3)?.message == "3 transfers have not finished")
    #expect(QuitQuestion(unsynced: 0, running: 1)?.message == "A transfer has not finished")
}

/// On one server a drag moves, or copies with Option; from another server it only copies. A
/// folder never goes into itself, and moving an item into its own folder does nothing.
@Test func aDropMovesOnOneServerAndCopiesFromAnother() {
    let here = ConnectionID()
    let there = ConnectionID()
    let folder = RemotePath(string: "/srv/dest")
    let file = RemotePath(string: "/srv/src/a.txt")
    let beside = RemotePath(string: "/srv/dest/b.txt")
    let above = RemotePath(string: "/srv")
    func drop(_ paths: [RemotePath], from source: ConnectionID, copy: Bool, move: Bool) -> [RemotePath]? {
        PasteRules.drop(paths, from: source, onto: folder, on: here, canCopy: copy, canMove: move).map(\.paths)
    }
    #expect(PasteRules.drop([file], from: here, onto: folder, on: here, canCopy: true, canMove: true)?.moving == true)
    #expect(PasteRules.drop([file], from: here, onto: folder, on: here, canCopy: true, canMove: false)?.moving == false)
    #expect(drop([file, beside, above, folder], from: here, copy: true, move: true) == [file])
    #expect(drop([file, beside, above], from: here, copy: true, move: false) == [file, beside])
    #expect(drop([beside], from: here, copy: true, move: true) == nil)
    #expect(drop([file], from: here, copy: false, move: false) == nil)
    #expect(drop([file, above], from: there, copy: true, move: true) == [file, above])
    #expect(PasteRules.drop([file], from: there, onto: folder, on: here, canCopy: true, canMove: true)?.moving == false)
    #expect(drop([file], from: there, copy: false, move: true) == nil)
}

/// The inspector fetches a picture or other previewable file up to 10 MB and a text file's head at
/// any size; anything it could only show as an icon, or that is too large or listed without a
/// size, is never fetched.
@Test func theInspectorFetchesOnlyWhatItCanShow() {
    let limit = InspectorPreviewPlan.limit
    #expect(limit == 10 << 20)
    func plan(_ name: String, _ size: UInt64?, text: Bool = false) -> InspectorPreviewPlan {
        InspectorPreviewPlan.plan(fileName: name, size: size, isText: text)
    }
    #expect(plan("photo.png", limit) == .picture)
    #expect(plan("photo.JPG", 1) == .picture)
    #expect(plan("photo.png", limit + 1) == .icon)
    #expect(plan("photo.png", nil) == .icon)
    #expect(plan("notes.txt", 1 << 30, text: true) == .text)
    #expect(plan("notes.txt", nil, text: true) == .text)
    for name in ["paper.pdf", "clip.mov", "song.mp3", "deck.key", "sheet.xlsx", "letter.docx", "table.csv"] {
        #expect(plan(name, 1000) == .quickLook, "\(name)")
    }
    #expect(plan("paper.pdf", limit + 1) == .icon)
    for name in ["blob.xyz", "archive.zip", "a.tar.gz", "lib.dylib", "notes."] {
        #expect(plan(name, 1000) == .icon, "\(name)")
    }
    for name in ["README", "LICENSE", "Makefile"] {
        #expect(plan(name, 1000) == .quickLook, "\(name)")
    }
    #expect(plan("README", limit + 1) == .icon)
}

@Test func quickLookFetchesFilesUpTo256MBAndNothingElse() {
    #expect(QuickLookPlan.plan(kind: .file, size: 0) == .fetch)
    #expect(QuickLookPlan.plan(kind: .file, size: nil) == .fetch)
    #expect(QuickLookPlan.plan(kind: .file, size: 256 << 20) == .fetch)
    #expect(QuickLookPlan.plan(kind: .file, size: (256 << 20) + 1) == .tooLarge)
    #expect(QuickLookPlan.plan(kind: .directory, size: 4096) == .nothing)
    #expect(QuickLookPlan.plan(kind: .directory, size: nil) == .nothing)
}


@Suite struct InspectorWidthTests {
    @Test func sixtyPercentOfTheSplitWithinTheContentMinimum() {
        #expect(InspectorWidth.maximum(splitWidth: 1200, sidebar: 200) == 720)
        #expect(InspectorWidth.maximum(splitWidth: 1200, sidebar: 0) == 720)
        #expect(InspectorWidth.maximum(splitWidth: 2400, sidebar: 200) == 1440)
        #expect(InspectorWidth.maximum(splitWidth: 1600, sidebar: 200) == 960)
    }

    @Test func theContentMinimumWinsOverTheShareButNotOverTheInspectorMinimum() {
        // 600 wide: 60% is 360, but the content keeps 260 first; a sidebar can squeeze it to the 240 floor.
        #expect(InspectorWidth.maximum(splitWidth: 600, sidebar: 0) == 340)
        #expect(InspectorWidth.maximum(splitWidth: 600, sidebar: 150) == 240)
        #expect(InspectorWidth.maximum(splitWidth: 600, sidebar: 320) == 240)
        #expect(InspectorWidth.maximum(splitWidth: 300, sidebar: 0) == 240)
    }
}
