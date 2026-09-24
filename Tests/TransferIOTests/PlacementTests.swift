import Darwin
import Foundation
import Testing
import TransferCore
@testable import TransferIO

/// `LocalPlacement` and `Placement` with no server: a hostile server's names and the local items
/// that must never be followed or removed.
struct PlacementTests {
    private func scratch(_ name: String) throws -> URL {
        let base = TestCaches.fresh(name)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// A READDIR name ending in `/` made the whole path the item's name, so a folder download
    /// wrote wherever it pointed (SES-02).
    @Test func aNameMustBeOneComponent() throws {
        let base = try scratch("names")
        defer { try? FileManager.default.removeItem(at: base) }
        // Two layers: RemotePath now drops the trailing slash, so the item's name is its last
        // component; and the raw name, should one reach placement, is refused.
        let hostile = RemoteItem(path: RemotePath(string: "/srv/dir/../../../../Users/u/Library/LaunchAgents/x.plist/"), kind: .file)
        #expect(hostile.name == "x.plist")
        for name in ["", ".", "..", "a/b", "../escaped", "/etc/passwd", "x\0y", "../../../../Users/u/Library/LaunchAgents/x.plist/"] {
            #expect(throws: TransferError.self) { try LocalPlacement.child(base, name: name) }
        }
        for name in ["notes.txt", ".hidden", "..x", "a b", "…"] {
            #expect(try LocalPlacement.child(base, name: name) == base.appendingPathComponent(name))
        }
    }

    @Test func occupantNeverFollowsALink() throws {
        let base = try scratch("occupant")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("file")
        try Data("12345".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: folder.path)
        let fifo = base.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)

        #expect(try LocalPlacement.occupant(base.appendingPathComponent("missing")) == nil)
        #expect(try LocalPlacement.occupant(folder) == .folder)
        #expect(try LocalPlacement.occupant(file) == .file(Fingerprint(size: 5, mtime: 1_700_000_000)))
        #expect(try LocalPlacement.occupant(link) == .link(folder.path))
        #expect(try LocalPlacement.occupant(fifo) == .other)
    }

    @Test func settlementRules() {
        let print = Fingerprint(size: 1, mtime: 2)
        let other = Fingerprint(size: 1, mtime: 3)
        #expect(Placement.settle(.file(print), onto: nil) == .write)
        #expect(Placement.settle(.file(print), onto: .file(print)) == .skip)
        #expect(Placement.settle(.file(print), onto: .file(other)) == .collide)
        #expect(Placement.settle(.file(nil), onto: .file(nil)) == .collide)
        #expect(Placement.settle(.file(print), onto: .link("x")) == .collide)
        #expect(Placement.settle(.file(print), onto: .folder) == .typeMismatch)
        #expect(Placement.settle(.folder, onto: .folder) == .merge)
        // A link in the way is never gone through: a folder that would merge into it collides.
        #expect(Placement.settle(.folder, onto: .link("/elsewhere")) == .collide)
        #expect(Placement.settle(.folder, onto: .file(print)) == .typeMismatch)
        #expect(Placement.settle(.link("a"), onto: .link("a")) == .skip)
        // A link of the same name but another target is not the copy (CLIP-16).
        #expect(Placement.settle(.link("a"), onto: .link("b")) == .collide)
        #expect(Placement.settle(.link("a"), onto: .file(print)) == .collide)
        // A folder never gives way to a link (SEC-4).
        #expect(Placement.settle(.link("a"), onto: .folder) == .typeMismatch)
        #expect(Placement.settle(.other, onto: .other) == .typeMismatch)
    }

    /// A server listed `d` as a link out of the download folder, then as a folder: the folder's
    /// contents were written through the link (SEC-2). The link now collides, and replacing it
    /// removes only the link.
    @Test func aFolderNeverMergesThroughALink() throws {
        let base = try scratch("through")
        defer { try? FileManager.default.removeItem(at: base) }
        let victim = base.appendingPathComponent("victim")
        let downloads = base.appendingPathComponent("Downloads")
        for folder in [victim, downloads] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("keep".utf8).write(to: victim.appendingPathComponent("kept.txt"))

        let d = try LocalPlacement.child(downloads, name: "d")
        try LocalPlacement.makeLink(d, target: victim.path, replacing: false)
        #expect(Placement.settle(.folder, onto: try LocalPlacement.occupant(d)) == .collide)
        #expect(throws: TransferError.self) { try LocalPlacement.makeFolder(d, replacing: false) }

        try LocalPlacement.makeFolder(d, replacing: true)
        #expect(try LocalPlacement.occupant(d) == .folder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: victim.path) == ["kept.txt"])
    }

    /// Replacing a folder with a link, or making a folder where one is, never removes it (SEC-4).
    @Test func aFolderIsNeverRemoved() throws {
        let base = try scratch("folder")
        defer { try? FileManager.default.removeItem(at: base) }
        let projects = base.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("app/src"), withIntermediateDirectories: true)
        try Data("main".utf8).write(to: projects.appendingPathComponent("app/src/main.swift"))

        #expect(throws: TransferError.self) { try LocalPlacement.makeLink(projects, target: "/elsewhere", replacing: true) }
        #expect(throws: TransferError.self) { try LocalPlacement.makeFolder(projects, replacing: true) }
        try LocalPlacement.makeFolder(projects, replacing: false)
        #expect(try Data(contentsOf: projects.appendingPathComponent("app/src/main.swift")) == Data("main".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.contains(".transfer-") }
        #expect(leftovers.isEmpty)
    }

    @Test func aLinkReplacesAFileOrLinkInOneStep() throws {
        let base = try scratch("link")
        defer { try? FileManager.default.removeItem(at: base) }
        let spot = base.appendingPathComponent("spot")
        try Data("old".utf8).write(to: spot)
        try LocalPlacement.makeLink(spot, target: "one", replacing: true)
        #expect(try LocalPlacement.occupant(spot) == .link("one"))
        try LocalPlacement.makeLink(spot, target: "two", replacing: true)
        #expect(try LocalPlacement.occupant(spot) == .link("two"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path) == ["spot"])
    }

    /// A link placed where nothing was is made at its name at once, and fails when something took
    /// the name since it was looked up: it was renamed over whatever was there (R-T7). A folder in
    /// place of a link or special file removes only that: a file that took its place since stays.
    @Test func whatTookANameSinceItWasLookedUpStays() throws {
        let base = try scratch("since")
        defer { try? FileManager.default.removeItem(at: base) }
        let spot = base.appendingPathComponent("spot")
        try Data("arrived".utf8).write(to: spot)
        #expect(throws: TransferError.self) { try LocalPlacement.makeLink(spot, target: "x", replacing: false) }
        #expect(throws: TransferError.self) { try LocalPlacement.makeFolder(spot, replacing: true) }
        #expect(try Data(contentsOf: spot) == Data("arrived".utf8))
        try FileManager.default.removeItem(at: spot)
        try LocalPlacement.makeLink(spot, target: "x", replacing: false)
        #expect(try LocalPlacement.occupant(spot) == .link("x"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path) == ["spot"])
    }

    /// Keep Both never lands on a name the disk already holds in another case.
    @Test func keepBothSkipsNamesTheDiskFolds() throws {
        let base = try scratch("keep")
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("a".utf8).write(to: base.appendingPathComponent("report.pdf"))
        try Data("b".utf8).write(to: base.appendingPathComponent("REPORT 2.pdf"))
        let next = try LocalPlacement.keepBoth(base.appendingPathComponent("report.pdf"))
        let caseSensitive = try base.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == true
        #expect(next.lastPathComponent == (caseSensitive ? "report 2.pdf" : "report 3.pdf"))
        #expect(Placement.fold("Straße.TXT") == Placement.fold("straße.txt"))
        #expect(Placement.fold("caf\u{E9}") == Placement.fold("cafe\u{301}"))
        // As APFS folds them (R-C1).
        #expect(Placement.fold("Straße") == Placement.fold("STRASSE"))
        #expect(Placement.fold("ΑΣ") == Placement.fold("ας"))
        #expect(Placement.fold("ﬁle") == Placement.fold("FILE"))
    }
}
