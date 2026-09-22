import SwiftUI
import TransferIO
import TransferUI

@main
struct TransferApp: App {
    private let model: TransferModel?

    init() {
        if let session = try? SSHConnection() {
            model = TransferModel(session: session)
        } else {
            model = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                ContentView(model: model)
            } else {
                ContentUnavailableView("Transfer could not open its library", systemImage: "externaldrive.badge.xmark")
            }
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            if let model {
                CommandGroup(replacing: .newItem) {
                    Button("New Connection") { model.sheet = .connection }
                        .keyboardShortcut("k")
                    Button("New Folder") { Task { await model.mkdir() } }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                    Button("Download Copy") { Task { await model.downloadCopy() } }
                    Button("Duplicate") { Task { await model.duplicateSelection() } }
                        .keyboardShortcut("d")
                    Button("Rename") { model.beginRename() }
                        .keyboardShortcut(.return, modifiers: [])
                }
                CommandGroup(after: .pasteboard) {
                    Button("Copy Remote URL") { model.copyRemoteURL() }
                        .keyboardShortcut("c")
                    Button("Delete") { model.sheet = .delete }
                        .keyboardShortcut(.delete, modifiers: .command)
                }
                CommandGroup(after: .newItem) {
                    Button("Open") { Task { await model.openSelection() } }
                        .keyboardShortcut("o")
                    Button("Open Live") { Task { await model.openLiveSelection() } }
                        .keyboardShortcut("o", modifiers: [.command, .option])
                }
                CommandMenu("Go") {
                    Button("Back") { Task { await model.goBack() } }
                        .keyboardShortcut("[")
                    Button("Forward") { Task { await model.goForward() } }
                        .keyboardShortcut("]")
                    Button("Parent") { Task { await model.goParent() } }
                        .keyboardShortcut(.upArrow, modifiers: .command)
                    Button("Remote Home") { Task { await model.goHome() } }
                        .keyboardShortcut("h", modifiers: [.command, .shift])
                    Button("Go to Remote Folder") { model.sheet = .goToFolder }
                        .keyboardShortcut("l")
                    Button("Open in Terminal") { model.openTerminal() }
                    Button("Refresh") { Task { await model.refresh() } }
                        .keyboardShortcut("r")
                }
                CommandMenu("View") {
                    Button("Icon") { model.setViewMode(.icon) }.keyboardShortcut("1")
                    Button("List") { model.setViewMode(.list) }.keyboardShortcut("2")
                    Button("Columns") { model.setViewMode(.columns) }.keyboardShortcut("3")
                    Button(model.snapshot.showsHidden ? "Hide Hidden Files" : "Show Hidden Files") {
                        Task { await model.toggleHidden() }
                    }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    Button("Inspector") { model.showsInspector.toggle() }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                    Button("Quick Look") { Task { await model.preview() } }
                        .keyboardShortcut(.space, modifiers: [])
                    Button("Clear Preview Cache") { Task { await model.clearPreviewCache() } }
                    Button("Pin This Folder") { Task { await model.pinCurrent() } }
                    Button("Discard Live File") { Task { await model.discardSelectedLive() } }
                }
                CommandGroup(replacing: .appTermination) {
                    Button("Quit Transfer") { Task { await model.requestQuit() } }
                        .keyboardShortcut("q")
                }
            }
        }
    }
}
