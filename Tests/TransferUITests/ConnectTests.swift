import Foundation
import Testing
import TransferCore
@testable import TransferUI

@MainActor
struct ConnectTests {
    let a = SavedConnection(name: "A", host: "a")
    let b = SavedConnection(name: "B", host: "b")

    /// UIM2-06: once the login lands the title names the server, however long its first listing.
    @Test func theTitleNamesTheServerWhileItsFirstListingArrives() async {
        let session = FakeSession(a)
        session.listTime.value = .milliseconds(500)
        let model = TransferModel(provider: FakeProvider([session]))
        let connecting = Task { await model.connect(a) }
        #expect(await eventually { model.snapshot.connectionID == a.id })
        #expect(model.title == "A")
        #expect(model.connectingTo == nil)
        await connecting.value
    }

    /// UIM2-09: a second connect to the server a connect is logging in to waits on the same
    /// login, so leaving stops it all.
    @Test func aSecondConnectSharesTheLoginUnderWay() async {
        let session = FakeSession(b, hangs: true)
        let model = TransferModel(provider: FakeProvider([FakeSession(a), session]))
        await model.reloadConnections()
        await model.connect(a)
        let first = Task { await model.connect(b) }
        #expect(await eventually { session.connects.value == 1 })
        let second = Task { await model.connect(b) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(session.connects.value == 1)
        await model.sidebarSelected(.server(a.id))
        await first.value
        await second.value
        #expect(model.connectingTo == nil)
        #expect(model.title == "A")
    }

    /// FR-13: a connect to a server whose session an edit replaced logs in to the new session,
    /// not by waiting on the old one's login.
    @Test func aConnectAfterAnEditDoesNotWaitOnTheOldSessionsLogin() async {
        let old = FakeSession(b, hangs: true)
        let provider = FakeProvider([FakeSession(a), old])
        let model = TransferModel(provider: provider)
        await model.connect(a)
        let first = Task { await model.connect(b) }
        #expect(await eventually { old.connects.value == 1 })
        let edited = FakeSession(SavedConnection(id: b.id, name: "B", host: "b2"))
        provider.replace(edited)
        let second = Task { await model.connect(edited.connection) }
        #expect(await eventually { model.session.map { $0 as AnyObject === edited } ?? false })
        #expect(edited.connects.value == 1)
        first.cancel()
        second.cancel()
        await first.value
        await second.value
    }

    /// UIM2-12: a Live conflict found while the login lands, as Live sync resumes, still asks.
    @Test func aConflictDuringTheLoginIsAskedOnceItLands() async {
        let session = FakeSession(a)
        session.loginTime.value = .milliseconds(200)
        let model = TransferModel(provider: FakeProvider([session]))
        let connecting = Task { await model.connect(a) }
        #expect(await eventually { session.connects.value == 1 })
        let path = RemotePath(string: "/home/notes.txt")
        session.send.yield(.conflict(path, comparable: true))
        await connecting.value
        #expect(await eventually {
            if case .conflict(path, comparable: true)? = model.sheet { true } else { false }
        })
    }

    /// SEC2-11: Open in Terminal says why it did nothing.
    @Test func openInTerminalSaysWhyItRefused() async {
        let model = TransferModel(provider: FakeProvider([FakeSession(a)]))
        await model.connect(a)
        await model.openTerminal()
        #expect(model.status?.contains("control character") == true)
    }
}
