import Foundation
import Testing
import TransferCore
@testable import TransferUI

/// What Space does before any panel opens: a second press cancels a running fetch, a file over
/// the limit and a folder are never fetched.
@MainActor @Suite(.serialized)
struct QuickLookTests {
    let server = SavedConnection(name: "A", host: "a")
    let home = RemotePath(string: "/home")

    func connected(_ session: FakeSession) async -> TransferModel {
        let model = TransferModel(provider: FakeProvider([session]))
        await model.connect(server)
        _ = await eventually { !model.items.isEmpty }
        return model
    }

    @Test func aSecondSpaceCancelsARunningFetch() async {
        let file = home.appending("a.bin")
        let session = FakeSession(server, home: "/home", folders: [home: [RemoteItem(path: file, kind: .file, size: 10)]])
        session.previewTime.value = .seconds(60)
        let model = await connected(session)
        model.snapshot.selection = [file]

        model.togglePreview()
        #expect(await eventually { model.previewing && session.calls.value.contains("preview /home/a.bin") })
        model.togglePreview()
        #expect(!model.previewing)
        #expect(await eventually { session.calls.value.contains("preview cancelled /home/a.bin") })
        #expect(model.status == nil)
    }

    @Test func aFileOver256MBIsNotFetchedAndTheMessageBarSaysSo() async {
        let big = home.appending("big.mov")
        let session = FakeSession(server, home: "/home", folders: [home: [RemoteItem(path: big, kind: .file, size: (256 << 20) + 1)]])
        let model = await connected(session)
        model.snapshot.selection = [big]

        model.togglePreview()
        #expect(await eventually { model.status?.contains("too large to preview") == true })
        #expect(model.status?.contains("Download Copy") == true)
        #expect(!session.calls.value.contains { $0.hasPrefix("preview") })
        #expect(!model.previewing)
    }

    @Test func aFolderIsNotFetched() async {
        let docs = home.appending("docs")
        let session = FakeSession(server, home: "/home", folders: [home: [RemoteItem(path: docs, kind: .directory)], docs: []])
        let model = await connected(session)
        model.snapshot.selection = [docs]

        model.togglePreview()
        #expect(await eventually { !model.previewing })
        #expect(!session.calls.value.contains { $0.hasPrefix("preview") })
        #expect(model.status == nil)
    }
}
