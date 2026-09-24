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

    @Test func anItemsNameIsItsPathsName() {
        let item = RemoteItem(path: RemotePath(string: "/srv/.env/"), kind: .file)
        #expect(item.name == ".env")
        #expect(item.isHidden)
    }
}
