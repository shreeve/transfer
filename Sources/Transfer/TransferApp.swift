import AppKit
import Sparkle
import SwiftUI
import TransferCore
import TransferIO
import TransferUI

@main
struct TransferApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.transferModel) private var model

    var body: some Scene {
        WindowGroup(id: "browser") {
            if let provider = delegate.provider {
                BrowserWindow(provider: provider)
            } else {
                ContentUnavailableView("Transfer could not open its library", systemImage: "externaldrive.badge.xmark")
            }
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: delegate.updater.updater)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Connection…") { model?.newConnection() }
                    .keyboardShortcut("k")
                    .disabled(model == nil)
                Button("New Window") { openWindow(id: "browser") }
                    .keyboardShortcut("n")
                Button("New Tab") { NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil) }
                    .keyboardShortcut("t")
                Divider()
                Button("Open") { Task { await model?.openSelection() } }
                    .keyboardShortcut("o")
                    .disabled(model?.primaryItem == nil)
                Button("Open Live") { Task { await model?.openLiveSelection() } }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                    .disabled(model?.primaryItem?.kind != .file)
                Button("Download Copy…") { Task { await model?.downloadCopy() } }
                    .disabled(model?.selectedItems.isEmpty ?? true)
                Button("Upload…") { Task { await model?.uploadFromPanel() } }
                    .disabled(model?.snapshot.connectionID == nil)
                Divider()
                Button("New Folder") { Task { await model?.mkdir() } }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model?.snapshot.connectionID == nil)
                Button("Duplicate") { Task { await model?.duplicateSelection() } }
                    .keyboardShortcut("d")
                    .disabled(model?.primaryItem?.kind != .file)
                Button("Rename") { model?.beginRename() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(model?.primaryItem == nil || model?.plainKeysAvailable != true)
                Button("Discard Live File") { Task { await model?.discardSelectedLive() } }
                    .disabled(model.map { m in m.selectedItems.contains { m.liveFile(for: $0.path) != nil } } != true)
            }
            // The standard Cut, Copy, and Paste stay for text fields. With no text field focused the
            // standard Copy is disabled, so Command-C falls through to this item.
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy Remote URL") { model?.copyRemoteURL() }
                    .keyboardShortcut("c")
                    .disabled(model?.snapshot.connectionID == nil || model?.plainKeysAvailable != true)
                Button("Delete…") { model?.askToDelete() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model?.snapshot.selection.isEmpty ?? true)
                Divider()
                Button("Filter") { model?.focusFilter() }
                    .keyboardShortcut("f")
                    .disabled(model?.snapshot.connectionID == nil)
            }
            CommandMenu("Go") {
                Button("Back") { Task { await model?.goBack() } }
                    .keyboardShortcut("[")
                Button("Forward") { Task { await model?.goForward() } }
                    .keyboardShortcut("]")
                Button("Parent") { Task { await model?.goParent() } }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Remote Home") { Task { await model?.goHome() } }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Go to Remote Folder…") { model?.sheet = .goToFolder }
                    .keyboardShortcut("l")
                Divider()
                Button("Refresh") { Task { await model?.refresh() } }
                    .keyboardShortcut("r")
                Button("Open in Terminal") { Task { await model?.openTerminal() } }
                    .disabled(model?.snapshot.connectionID == nil || model?.terminalAvailable != true)
            }
            CommandMenu("View") {
                Button("as Icons") { model?.setViewMode(.icon) }.keyboardShortcut("1")
                Button("as List") { model?.setViewMode(.list) }.keyboardShortcut("2")
                Button("as Columns") { model?.setViewMode(.columns) }.keyboardShortcut("3")
                Divider()
                Button(model?.snapshot.showsHidden == true ? "Hide Hidden Files" : "Show Hidden Files") {
                    model?.toggleHidden()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Quick Look") { model?.togglePreview() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(model?.primaryItem == nil || model?.plainKeysAvailable != true)
                Divider()
                Button("Sidebar") { model?.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button("Inspector") { model?.showsInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Transfers") { model?.showsShelf.toggle() }
                Divider()
                Button("Save This Location") { Task { await model?.pinCurrent() } }
                    .disabled(model?.snapshot.connectionID == nil)
                Button("Clear Preview Cache") { Task { await model?.clearPreviewCache() } }
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit Transfer") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        // Settings adds "Settings…" to the app menu with Command-Comma.
        Settings {
            TabView {
                GeneralSettings()
                    .tabItem { Label("General", systemImage: "gearshape") }
                if let provider = delegate.provider {
                    ExtensionSettings(provider: provider)
                        .tabItem { Label("Extensions", systemImage: "doc.text") }
                }
                UpdateSettings(updater: delegate.updater.updater)
                    .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
            }
            .frame(width: 480, height: 320)
        }
    }
}

/// The Updates tab: Sparkle's own schedule switch.
struct UpdateSettings: View {
    let updater: SPUUpdater
    @State private var automatic: Bool

    init(updater: SPUUpdater) {
        self.updater = updater
        _automatic = State(initialValue: updater.automaticallyChecksForUpdates)
    }

    var body: some View {
        Form {
            Toggle("Check for updates automatically", isOn: $automatic)
                .onChange(of: automatic) { updater.automaticallyChecksForUpdates = automatic }
            LabeledContent("Last checked", value: updater.lastUpdateCheckDate?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
            Button("Check Now") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        .formStyle(.grouped)
    }
}

/// One window or tab. Each has its own model; sessions are shared through the provider.
struct BrowserWindow: View {
    @State private var model: TransferModel

    init(provider: any SessionProvider) {
        _model = State(initialValue: TransferModel(provider: provider))
    }

    var body: some View {
        ContentView(model: model)
    }
}

/// "Check for Updates…" is enabled only while Sparkle can check.
struct CheckForUpdatesButton: View {
    @State private var state: UpdaterState

    init(updater: SPUUpdater) {
        _state = State(initialValue: UpdaterState(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…") { state.updater.checkForUpdates() }
            .disabled(!state.canCheck)
    }
}

@MainActor
@Observable
final class UpdaterState {
    let updater: SPUUpdater
    private(set) var canCheck = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init(updater: SPUUpdater) {
        self.updater = updater
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheck = value }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let provider: TransferHub?
    /// Sparkle reads SUFeedURL and SUPublicEDKey from Info.plist and checks on its own schedule.
    /// Until a public key is in the plist the updater stays off, so a development build never
    /// shows Sparkle's "not configured" alert at launch.
    let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    override init() {
        provider = try? TransferHub()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        if !key.isEmpty { updater.startUpdater() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let provider else { return .terminateNow }
        let semaphore = DispatchSemaphore(value: 0)
        let box = CountBox()
        Task.detached {
            box.value = await provider.unsyncedLiveCount
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
        return QuitGuard.mayQuit(unsynced: box.value) ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let provider else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await provider.disconnectAll()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
    }
}

private final class CountBox: @unchecked Sendable {
    var value = 0
}
