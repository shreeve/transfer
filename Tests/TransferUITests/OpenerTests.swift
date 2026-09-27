import Testing
@testable import TransferUI

/// D2 (SEC2-01, UIV-01): a server's file never opens in an app that runs it.
struct OpenerTests {
    @Test(arguments: ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "org.python.PythonLauncher", "com.apple.JavaLauncher"])
    func aRunnerGivesWayToThePlainTextEditor(runner: String) {
        #expect(FileOpener.editor(replacing: runner, plainText: "com.barebones.bbedit") == "com.barebones.bbedit")
        #expect(FileOpener.editor(replacing: runner, plainText: nil) == "com.apple.TextEdit")
        #expect(FileOpener.editor(replacing: runner, plainText: "com.apple.Terminal") == "com.apple.TextEdit")
    }

    /// FR-11: a runner picked in the chooser is not made the type's default.
    @Test func onlyARunnerRunsWhatItOpens() {
        #expect(FileOpener.runs("com.apple.Terminal"))
        #expect(FileOpener.runs("com.apple.JavaLauncher"))
        #expect(!FileOpener.runs("com.apple.TextEdit"))
        #expect(!FileOpener.runs(nil))
    }

    @Test func anyOtherDefaultAppIsKept() {
        #expect(FileOpener.editor(replacing: "com.apple.dt.Xcode", plainText: "com.apple.TextEdit") == nil)
        #expect(FileOpener.editor(replacing: "com.apple.Preview", plainText: nil) == nil)
        #expect(FileOpener.editor(replacing: nil, plainText: "com.apple.TextEdit") == nil)
    }
}
