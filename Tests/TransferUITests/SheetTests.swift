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

    /// UIM2-04: a second Discard sheet waits for the first instead of replacing it.
    @Test func eachRefusedDiscardAsksInTurn() async {
        let session = FakeSession(a)
        session.refusesDiscard.value = true
        let model = TransferModel(provider: FakeProvider([session]))
        await model.connect(a)
        let one = RemotePath(string: "/home/one.txt"), two = RemotePath(string: "/home/two.txt")
        await model.discardLive(one)
        await model.discardLive(two)
        #expect(model.sheet?.id == AppSheet.discardLive(one, a.id).id)
        model.sheet = nil
        #expect(model.sheet?.id == AppSheet.discardLive(two, a.id).id)
    }
}
