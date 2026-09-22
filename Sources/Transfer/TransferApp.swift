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
            let primary = model?.primaryItem
            let connected = model?.snapshot.connectionID != nil
            let plainKeys = model?.plainKeysAvailable == true
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
                    .disabled(primary == nil)
                Button("Open Live") { Task { await model?.openLiveSelection() } }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                    .disabled(primary?.kind != .file)
                Button("Download Copy…") { Task { await model?.downloadCopy() } }
                    .disabled(primary == nil)
                Button("Upload…") { Task { await model?.uploadFromPanel() } }
                    .disabled(!connected)
                Divider()
                Button("New Folder") { Task { await model?.mkdir() } }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!connected)
                Button("Duplicate") { Task { await model?.duplicateSelection() } }
                    .keyboardShortcut("d")
                    .disabled(primary?.kind != .file)
                Button("Rename") { model?.beginRename() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(primary == nil || !plainKeys)
                Button("Forget Synced Live Files") { Task { await model?.forgetSyncedLive() } }
                    .disabled(model?.liveFiles.contains { !$0.dirty && !$0.uploading && !$0.conflict } != true)
                Button("Discard Live File") { Task { await model?.discardSelectedLive() } }
                    .disabled(model.map { m in m.liveFiles.contains { m.snapshot.selection.contains($0.path) } } != true)
            }
            // The standard Cut, Copy, and Paste stay for text fields. With no text field focused the
            // standard Copy is disabled, so Command-C falls through to this item.
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy Remote URL") { model?.copyRemoteURL() }
                    .keyboardShortcut("c")
                    .disabled(!connected || !plainKeys)
                Button("Delete…") { model?.askToDelete() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model?.snapshot.selection.isEmpty ?? true)
                Divider()
                Button("Filter") { model?.focusFilter() }
                    .keyboardShortcut("f")
                    .disabled(!connected)
            }
            CommandMenu("Go") {
                Group {
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
                        .disabled(model?.terminalAvailable != true)
                }
                .disabled(!connected)
            }
            CommandMenu("View") {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Button("as \(mode.title)") { model?.setViewMode(mode) }
                }
                Divider()
                Button(model?.snapshot.showsHidden == true ? "Hide Hidden Files" : "Show Hidden Files") {
                    model?.toggleHidden()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Quick Look") { model?.togglePreview() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(primary == nil || !plainKeys)
                Divider()
                Button("Sidebar") { model?.sidebarCollapsed.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button("Inspector") { model?.showsInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Transfers") { model?.showsShelf.toggle() }
                Divider()
                Button(model.map { $0.isStarred($0.starTarget) } == true ? "Unstar" : "Star") {
                    Task { await model?.toggleStar() }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!connected)
                Button("Clear Preview Cache") { Task { await model?.clearPreviewCache() } }
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
