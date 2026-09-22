import Testing
import TransferCore

@Test func editableExtensionsOpenLive() {
    for name in ["notes.txt", "app.swift", "main.rs", "page.tsx", "config.json", "clip.rip"] {
        #expect(EditableFile.openKind(fileName: name) == .live)
    }
}

@Test func documentsOpenForViewing() {
    for name in ["photo.jpg", "scan.png", "book.pdf", "movie.mp4", "archive.zip"] {
        #expect(EditableFile.openKind(fileName: name) == .view)
    }
}

@Test func keepBothInsertsANumberBeforeTheExtension() {
    let name = KeepBothName.next(existing: ["report.pdf", "report 2.pdf"], original: "report.pdf")
    #expect(name == "report 3.pdf")
}

@Test func duplicateUsesCopySuffix() {
    let name = KeepBothName.duplicate(existing: ["notes.txt"], original: "notes.txt")
    #expect(name == "notes copy.txt")
}

@Test func matchingSizeAndTimeSkipsTheCopy() {
    let source = RemoteItem(path: RemotePath(string: "/a"), kind: .file, size: 4, mtime: 10)
    let destination = RemoteItem(path: RemotePath(string: "/b"), kind: .file, size: 4, mtime: 10)
    let decision = CopyRules.fileDisposition(source: source, destination: destination, transferID: "1", liveSave: false)
    #expect(decision == .skip)
}

@Test func probeRequiresASingleVersionLine() {
    #expect(ProbeResult(exitCode: 0, stdout: "performance-version 1\n").enabled)
    #expect(!ProbeResult(exitCode: 2, stdout: "performance-version 0\n").enabled)
    #expect(!ProbeResult(exitCode: 0, stdout: "one\ntwo\n").enabled)
}

@Test func channelRolesAreOneDataRole() {
    #expect(ChannelRole.allCases == [.browse, .interactive, .walker, .data])
}

@Test func sftpURLOmitsThePassword() {
    let connection = SavedConnection(name: "Box", host: "example.com", user: "ada", port: "22")
    let url = SftpURL.string(connection: connection, path: RemotePath(string: "/work/a b.txt"))
    #expect(url == "sftp://ada@example.com:22/work/a%20b.txt")
}
