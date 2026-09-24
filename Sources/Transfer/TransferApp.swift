import AppKit
import Sparkle
import SwiftUI
import TransferCore
import TransferIO
import TransferUI

/// The scenes, menus, and delegate (library, Sparkle, `sftp://` links, the Quit guard). The only
/// target that sees both UI and IO; windows reach the library only through `SessionProvider`.
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
                ContentUnavailableView(
                    "Transfer could not open its library",
                    systemImage: "externaldrive.badge.xmark",
                    description: Text(delegate.libraryError ?? "")
                )
            }
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            let primary = model?.primaryItem
            let connected = model?.snapshot.connectionID != nil
            let plainKeys = model?.plainKeysAvailable == true
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(state: delegate.updates)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Connection…") { model?.newConnection() }
                    .keyboardShortcut("k")
                    .disabled(model == nil)
                Button("New Window") { openWindow(id: "browser") }
                    .keyboardShortcut("n")
                Button("New Tab") {
                    NewTab.request()
                    openWindow(id: "browser")
                }
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
                    .disabled(primary == nil)
                Button("Rename") { model?.beginRename() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(primary == nil || !plainKeys)
                Button("Forget Synced Live Files") { Task { await model?.forgetSyncedLive() } }
                    .disabled(model?.liveFiles.contains(where: \.isSynced) != true)
                Button("Discard Live File") { Task { await model?.discardSelectedLive() } }
                    .disabled(model.map { m in m.liveFiles.contains { m.snapshot.selection.contains($0.path) } } != true)
            }
            // The standard Copy and Paste serve text fields, and with no text field focused they
            // reach the window's ChromeController, which copies and pastes files.
            CommandGroup(after: .pasteboard) {
                Divider()
                Button(model?.moveTitle ?? "Move Item Here") { Task { await model?.paste(moving: true) } }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                    .disabled(model?.canPaste != true || !plainKeys)
                Button("Copy Remote URL") { model?.copyRemoteURL() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
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
            // Replaces SwiftUI's own View menu rather than sitting beside it.
            CommandGroup(replacing: .toolbar) {
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
                    .disabled(primary == nil || !plainKeys)
                Divider()
                // Command-B as in VS Code and Cursor; Command-I is Finder's Get Info, which the
                // inspector shows.
                Button(model?.sidebarCollapsed == true ? "Show Sidebar" : "Hide Sidebar") { model?.sidebarCollapsed.toggle() }
                    .keyboardShortcut("b")
                Button(model?.showsInspector == true ? "Hide Inspector" : "Show Inspector") { model?.showsInspector.toggle() }
                    .keyboardShortcut("i")
                Button("Transfers") { model?.showsShelf.toggle() }
                Divider()
                // Finder's Add to Sidebar key.
                Button(model.map { $0.starTitle($0.starTargets) } ?? "Add to Starred") {
                    Task { await model?.toggleStar(model?.starTargets ?? []) }
                }
                .keyboardShortcut("t", modifiers: [.command, .control])
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
    @Environment(\.openWindow) private var openWindow

    init(provider: any SessionProvider) {
        _model = State(initialValue: TransferModel(provider: provider))
    }

    var body: some View {
        ContentView(model: model)
            .onAppear { LinkInbox.openWindow = { openWindow(id: "browser") } }
            // An open window takes each `sftp://` link, so SwiftUI opens a window for one only
            // when none is open. The app delegate decides where the link goes.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }
}

struct CheckForUpdatesButton: View {
    let state: UpdaterState

    var body: some View {
        Button("Check for Updates…") { state.updater.checkForUpdates() }
            .disabled(!state.canCheck)
    }
}

/// Whether Sparkle can check now. One for the app, owned by the delegate: the menu's body runs
/// on every focus change, and each run would otherwise start another observation.
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
    /// Why the library could not be opened, such as one written by a newer Transfer.
    let libraryError: String?
    /// Reads SUFeedURL and SUPublicEDKey from Info.plist and checks on its own schedule. Off until
    /// the plist has a public key, so a development build never shows the "not configured" alert.
    let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    let updates: UpdaterState

    override init() {
        do {
            provider = try TransferHub()
            libraryError = nil
        } catch {
            provider = nil
            libraryError = error.localizedDescription
        }
        updates = UpdaterState(updater: updater.updater)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowFrames.launchFinished()
        if let libraryError {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Transfer could not open its library"
            alert.informativeText = libraryError
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        if !key.isEmpty { updater.startUpdater() }
    }

    /// `sftp://` links, such as a Command-click on one a terminal shows.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.compactMap(SFTPURL.init(url:)).forEach(LinkInbox.deliver)
    }

    /// Asks before quitting abandons unsynced Live edits or running transfers. The hub's actor may
    /// be busy (say, hashing a large working copy), so the Live count gets a time limit off the
    /// main thread, and a late count asks too. Every master disconnects before the reply.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let provider else { return .terminateNow }
        let running = TransferModel.unfinishedOperations
        Task {
            let unsynced = await Self.within(.seconds(3)) { await provider.unsyncedLiveCount }
            if let question = QuitQuestion(unsynced: unsynced, running: running), !Self.ask(question) {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            _ = await Self.within(.seconds(5)) { await provider.disconnectAll() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private static func ask(_ question: QuitQuestion) -> Bool {
        let alert = NSAlert()
        alert.messageText = question.message
        alert.informativeText = question.detail
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// `work`'s result, or nil once `limit` passes first. The work is not waited for after that.
    private static func within<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { continuation in
            let pending = Locked<CheckedContinuation<T?, Never>?>(continuation)
            let finish: @Sendable (T?) -> Void = { value in
                pending.withLock { waiting in
                    waiting?.resume(returning: value)
                    waiting = nil
                }
            }
            Task { finish(await work()) }
            Task {
                try? await Task.sleep(for: limit)
                finish(nil)
            }
        }
    }

    // Last in the responder chain: Copy and Paste for a window whose content holds no focus.
    @objc func copy(_ sender: Any?) { KeyWindowEdit.copy() }
    @objc func paste(_ sender: Any?) { KeyWindowEdit.paste() }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): KeyWindowEdit.canCopy()
        case #selector(paste(_:)): KeyWindowEdit.canPaste()
        default: true
        }
    }
}
