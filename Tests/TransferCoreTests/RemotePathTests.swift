import Foundation
import Testing
import TransferCore

struct RemotePathTests {
    /// A trailing slash once made `name` the whole path, which is how a hostile READDIR name such
    /// as `../../../Documents/` became a local path outside the download folder (SFC-1, SFC-11).
    @Test func aTrailingSlashIsDroppedWhenThePathIsMade() {
        let site = RemotePath(string: "/srv/site/")
        #expect(site == RemotePath(string: "/srv/site"))
        #expect(site.nameBytes == Array("site".utf8))
        #expect(site.name == "site")
        #expect(site.parent == RemotePath(string: "/srv"))
        #expect(site.appending("a").display == "/srv/site/a")
        #expect(RemotePath(string: "/srv/site///").display == "/srv/site")
        #expect(RemotePath(string: "a/b/").nameBytes == Array("b".utf8))
        #expect(RemotePath(bytes: Array("/dir/../../../Documents/".utf8)).name == "Documents")
        #expect(RemotePath(string: "//").isRoot)
    }

    /// Go to Remote Folder joined anything not starting with `/` onto the location as one name, so
    /// `~` and `~/x` looked for a folder named `~`, and `..` stayed in the path (UIM-32).
    /// Rename and every local placement take a name only when it names one entry.
    @Test func aSingleNameCannotReachAnotherEntry() {
        for name in ["notes.txt", ".hidden", "...", "a b", "café"] { #expect(RemotePath.isSingleName(name)) }
        for name in ["", ".", "..", "a/b", "/", "../x", "a\0b"] { #expect(!RemotePath.isSingleName(name)) }
    }

    @Test func aTypedFolderIsAbsoluteHomeOrRelative() {
        let current = RemotePath(string: "/srv/site")
        let home = RemotePath(string: "/home/ann")
        func go(_ text: String) -> String? { RemotePath.typed(text, from: current, home: home)?.display }
        #expect(go("/etc/nginx/") == "/etc/nginx")
        #expect(go("  /tmp \n") == "/tmp")
        #expect(go("~") == "/home/ann")
        #expect(go("~/") == "/home/ann")
        #expect(go("~/logs/today") == "/home/ann/logs/today")
        #expect(go("~/../bob") == "/home/bob")
        #expect(go("~bob") == "/srv/site/~bob")
        #expect(go("public/css") == "/srv/site/public/css")
        #expect(go("..") == "/srv")
        #expect(go("../other/./x") == "/srv/other/x")
        #expect(go("../../../..") == "/")
        #expect(go(".") == "/srv/site")
        #expect(go("/a//b/../c") == "/a/c")
        #expect(go("") == nil)
        #expect(go("   ") == nil)
    }

    /// A pasted NUL reached the server, whose SFTP server exits on one, ending the channel (COR-2).
    @Test func aTypedPathWithAControlCharacterGoesNowhere() {
        let current = RemotePath(string: "/srv/site")
        for text in ["/tmp/a\0b", "a\0", "~/x\ny", "/a\tb", "/a\u{7F}", "/a\u{85}b"] {
            #expect(RemotePath.typed(text, from: current, home: current) == nil, "\(text.debugDescription)")
        }
        #expect(RemotePath.typed("/tmp/a b\n", from: current, home: current)?.display == "/tmp/a b")
    }

    @Test func appendingNeverMakesADoubleSlash() {
        let root = RemotePath(string: "/")
        #expect(root.appending("etc").display == "/etc")
        #expect(RemotePath(string: "/srv/").appending(name: Array("a".utf8)).display == "/srv/a")
        #expect(RemotePath(string: "/srv").appending("/a").display == "/srv/a")
        #expect(root.appending("//a").display == "/a")
        #expect(RemotePath(string: "/srv").appending("sub/").display == "/srv/sub")
        #expect(RemotePath(string: "/srv").appending("café") == RemotePath(string: "/srv").appending(name: Array("café".utf8)))
    }

    @Test func rootAndRelativePathsHaveNoParentOrName() {
        let root = RemotePath(string: "/")
        #expect(root.parent == nil)
        #expect(root.nameBytes.isEmpty)
        #expect(root.name == "")
        #expect(RemotePath(string: "/a").parent == root)
        #expect(RemotePath(string: "notes").parent == nil)
        #expect(RemotePath(string: "notes").name == "notes")
        #expect(RemotePath(string: "work/notes").parent == RemotePath(string: "work"))
        #expect(RemotePath(string: "").nameBytes.isEmpty)
        #expect(RemotePath(string: "").parent == nil)
        // Appending to an empty path stays relative; it never reaches the server's root.
        #expect(RemotePath(string: "").appending("etc") == RemotePath(string: "etc"))
    }

    /// Names are bytes; one that is not UTF-8 keeps its bytes through every step.
    @Test func nonUTF8NamesKeepTheirBytes() {
        let name: [UInt8] = [0x63, 0x61, 0x66, 0xE9]
        let path = RemotePath(string: "/srv").appending(name: name)
        #expect(path.nameBytes == name)
        #expect(path.parent == RemotePath(string: "/srv"))
        #expect(path.name == "caf\u{FFFD}")
    }

    @Test func insideIsByWholeComponents() {
        let site = RemotePath(string: "/srv/site")
        #expect(site.isInside(site))
        #expect(RemotePath(string: "/srv/site/a/b").isInside(site))
        #expect(RemotePath(string: "/srv/site/").isInside(site))
        #expect(site.isInside(RemotePath(string: "/srv/site/")))
        #expect(!RemotePath(string: "/srv/site2").isInside(site))
        #expect(!RemotePath(string: "/srv").isInside(site))
        #expect(site.isInside(RemotePath(string: "/")))
    }

    @Test func normalizingFoldsDotsAndEmptyComponents() {
        func normal(_ path: String) -> String { RemotePath(string: path).normalized.display }
        #expect(normal("/srv/x/../site/sub") == "/srv/site/sub")
        #expect(normal("/srv/./site//sub/.") == "/srv/site/sub")
        #expect(normal("/../../etc") == "/etc")
        #expect(normal("/srv/..") == "/")
        #expect(normal("/") == "/")
        #expect(normal("a/../../b") == "../b")
        #expect(normal("a/..") == ".")
        #expect(normal("./a/b/../c") == "a/c")
        #expect(normal("/srv/..hidden/.x") == "/srv/..hidden/.x")
    }

    @Test func replacingAPrefixMovesThePathAndItsContents() {
        func moved(_ path: String, _ prefix: String, _ replacement: String) -> String? {
            RemotePath(string: path).replacing(prefix: RemotePath(string: prefix), with: RemotePath(string: replacement))?.display
        }
        #expect(moved("/srv/a", "/srv/a", "/dst/b") == "/dst/b")
        #expect(moved("/srv/a/x/y.txt", "/srv/a", "/dst/b") == "/dst/b/x/y.txt")
        #expect(moved("/srv/ab", "/srv/a", "/dst/b") == nil)
        #expect(moved("/srv", "/srv/a", "/dst/b") == nil)
        // The root on either side never makes a `//`.
        #expect(moved("/srv/a/x", "/srv/a", "/") == "/x")
        #expect(moved("/srv/a", "/srv/a", "/") == "/")
        #expect(moved("/x/y", "/", "/dst") == "/dst/x/y")
        #expect(moved("/", "/", "/dst") == "/dst")
        let latin1 = RemotePath(bytes: Array("/srv/a/".utf8) + [0xE9])
        #expect(latin1.replacing(prefix: RemotePath(string: "/srv/a"), with: RemotePath(string: "/dst"))?.bytes == Array("/dst/".utf8) + [0xE9])
    }

    /// Seeded random paths of slashes, dots, and bytes that are not UTF-8.
    @Test func pathRulesHoldForAnyBytes() {
        var random = SeededRandom(state: 1)
        let pieces: [[UInt8]] = [[0x2F], [0x2F], [0x2E], [0x2E, 0x2E], Array("a".utf8), Array("b".utf8), [0xE9], [0xFF], [0x20], [0x00]]
        func path(absolute: Bool = true) -> RemotePath {
            var bytes: [UInt8] = absolute ? [0x2F] : []
            for _ in 0..<random.next() % 8 { bytes += pieces[Int(random.next() % UInt64(pieces.count))] }
            return RemotePath(bytes: bytes)
        }
        for _ in 0..<20_000 {
            let absolute = random.next() % 4 != 0
            let raw = path(absolute: absolute)
            let normal = raw.normalized
            #expect(normal.normalized == normal, "\(raw.bytes)")
            guard absolute else { continue }
            #expect(normal.bytes.first == 0x2F && !normal.bytes.split(separator: 0x2F).contains { $0 == [0x2E] || $0 == [0x2E, 0x2E] }, "\(raw.bytes)")
            if let parent = normal.parent {
                #expect(normal.isInside(parent))
                #expect(parent.appending(name: normal.nameBytes) == normal, "\(normal.bytes)")
            }
            let prefix = path().normalized
            guard normal.isInside(prefix) else { continue }
            let destination = path().normalized
            #expect(normal.replacing(prefix: prefix, with: prefix) == normal)
            #expect(normal.replacing(prefix: prefix, with: destination)?.replacing(prefix: destination, with: prefix) == normal, "\(normal.bytes) \(prefix.bytes) \(destination.bytes)")
        }
    }

    @Test func anItemsNameIsItsPathsName() {
        let item = RemoteItem(path: RemotePath(string: "/srv/.env/"), kind: .file)
        #expect(item.name == ".env")
        #expect(item.isHidden)
    }
}

/// SplitMix64, so a property test's inputs are the same on every run.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
