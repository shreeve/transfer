import Foundation
import Testing
import TransferCore
@testable import TransferUI

/// UIM2-03: after an edit replaces a server's session, or a removal drops it, nothing keeps using
/// the old object, which would log in again with the old settings beside the new one.
@MainActor
struct SessionTests {
    let a = SavedConnection(name: "A", host: "a")

    func same(_ lhs: (any RemoteSession)?, _ rhs: FakeSession) -> Bool {
        lhs.map { $0 as AnyObject === rhs } ?? false
    }

    @Test func aTransferRunsOnTheSessionTheLibraryHasNow() async {
        let old = FakeSession(a)
        let provider = FakeProvider([old])
        let model = TransferModel(provider: provider)
        await model.connect(a)
        let edited = FakeSession(SavedConnection(id: a.id, name: "A edited", host: "a"))
        provider.replace(edited)
        let used = Locked<[String]>([])
        model.enqueue(title: "Download x", path: RemotePath(string: "/home/x")) { session, _ in
            used.withLock { $0.append(session.connection.name) }
        }
        #expect(await eventually { model.operations.isEmpty })
        #expect(used.value == ["A edited"])
        #expect(edited.connects.value == 1)
        #expect(old.connects.value == 1)
    }

    @Test func aTransferForARemovedServerFailsSayingSo() async throws {
        let provider = FakeProvider([FakeSession(a)])
        let model = TransferModel(provider: provider)
        await model.connect(a)
        try await provider.removeConnection(a.id)
        model.enqueue(title: "Download x", path: RemotePath(string: "/home/x")) { _, _ in }
        #expect(await eventually { model.operations.first?.state == .failed })
        #expect(model.operations.first?.message == "“A” is no longer in the library.")
    }

    @Test func homeAfterAnEditMovesTheWindowToTheNewSession() async {
        let provider = FakeProvider([FakeSession(a)])
        let model = TransferModel(provider: provider)
        await model.connect(a)
        let edited = FakeSession(SavedConnection(id: a.id, name: "A", host: "a"))
        provider.replace(edited)
        await model.goHome()
        #expect(same(model.session, edited))
        #expect(model.snapshot.connectionID == a.id)
    }

    @Test func reloadingAnEditedServerMovesTheWindowToTheNewSession() async {
        let provider = FakeProvider([FakeSession(a, folders: files(2, in: "/home/work"))])
        let model = TransferModel(provider: provider)
        await model.connect(a)
        await model.navigate(RemotePath(string: "/home/work"))
        let edited = FakeSession(SavedConnection(id: a.id, name: "A2", host: "a2"), folders: files(2, in: "/home/work"))
        provider.replace(edited)
        await model.reloadConnections()
        #expect(await eventually { same(model.session, edited) && model.connectingTo == nil })
        #expect(model.snapshot.path == RemotePath(string: "/home/work"))
        #expect(model.title == "A2")
    }

    /// FR-8: Save closes the form before the edit's new login starts, so that login can ask.
    @Test func savingAnEditOfTheShownServerLetsItsNewLoginAsk() async {
        let old = FakeSession(a)
        let provider = FakeProvider([old])
        let model = TransferModel(provider: provider)
        await model.connect(a)
        model.editConnection(a)
        let edited = FakeSession(SavedConnection(id: a.id, name: "A", host: "a2"))
        edited.asksPassword.value = true
        provider.replace(edited)
        model.draft = edited.connection
        let save = Task { await model.saveDraft() }
        #expect(await eventually { if case .prompt? = model.sheet { true } else { false } })
        model.sheet = nil
        save.cancel()
        await save.value
        #expect(await eventually { model.connectingTo == nil })
        #expect(same(model.session, old))
    }

    /// FR-8: an edit that kept the session is taken by the window, so a later change to the
    /// library does not log in again with settings the window already has.
    @Test func anEditThatKeptTheSessionIsNotLoggedInAgainLater() async {
        let old = FakeSession(a)
        let provider = FakeProvider([old])
        let model = TransferModel(provider: provider)
        await model.connect(a)
        provider.saved.withLock { $0 = [SavedConnection(id: a.id, name: "A renamed", host: "a")] }
        await model.reloadConnections()
        #expect(same(model.session, old))
        let fresh = FakeSession(SavedConnection(id: a.id, name: "A renamed", host: "a"))
        fresh.asksPassword.value = true
        provider.replace(fresh)
        let reload = Task { await model.reloadConnections() }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.sheet == nil)
        #expect(fresh.connects.value == 0)
        reload.cancel()
        await reload.value
    }
}
