import Foundation
import Testing
import TransferCore
@testable import TransferUI

@MainActor
struct SheetTests {
    let a = SavedConnection(name: "A", host: "a")
    let b = SavedConnection(name: "B", host: "b")

    func promptServer(_ model: TransferModel) -> String?? {
        if case .prompt(_, let server, _)? = model.sheet { return server }
        return nil
    }

    /// UIM2-01: a withdrawn login sheet leaves nothing behind. The model holds no password, Save,
    /// or Apply to All; each question is a sheet of its own, whose fields start empty.
    @Test func aWithdrawnPasswordSheetLeavesNothingForTheNextServer() async {
        let model = TransferModel(provider: FakeProvider([]))
        let loginA = model.prompts.login(a)
        let askA = Task { await loginA.answer(PromptRequest(text: "a's password:", offerKeychain: true)) }
        #expect(await eventually { promptServer(model) == "A" })
        let first = model.sheet?.id
        loginA.retire()
        #expect(await askA.value.text == nil)
        #expect(model.sheet == nil)

        let loginB = model.prompts.login(b)
        let askB = Task { await loginB.answer(PromptRequest(text: "b's password:", offerKeychain: true)) }
        #expect(await eventually { promptServer(model) == "B" })
        #expect(model.sheet?.id != first)
        model.prompts.finish(.login(PromptReply(text: "typed for B")))
        let reply = await askB.value
        #expect(reply.text == "typed for B")
        #expect(!reply.saveInKeychain)
    }

    /// UIM2-04: a second Stop Live Editing sheet waits for the first instead of replacing it.
    @Test func eachRefusedStopAsksInTurn() async {
        let session = FakeSession(a)
        let one = LiveFile(id: LiveFileID(), path: RemotePath(string: "/home/one.txt"), dirty: true, paused: false, conflict: false, uploading: false)
        let two = LiveFile(id: LiveFileID(), path: RemotePath(string: "/home/two.txt"), dirty: true, paused: false, conflict: false, uploading: false)
        session.live.value = [one, two]
        let model = TransferModel(provider: FakeProvider([session]))
        await model.connect(a)
        await model.stopLive([one.id])
        await model.stopLive([two.id])
        #expect(model.sheet?.id == "stop-\(one.id.rawValue.uuidString)")
        model.sheet = nil
        #expect(model.sheet?.id == "stop-\(two.id.rawValue.uuidString)")
        #expect(!session.calls.value.contains { $0.hasPrefix("stop ") })
    }
}
