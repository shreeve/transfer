import AppKit
import QuickLookUI
import SwiftUI
import TransferCore

public struct ContentView: View {
    @Bindable var model: TransferModel

    public init(model: TransferModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if model.renaming {
                    HStack {
                        TextField("Name", text: $model.renameText)
                            .onSubmit { Task { await model.renameSelection(to: model.renameText); model.renaming = false } }
                        Button("Rename") { Task { await model.renameSelection(to: model.renameText); model.renaming = false } }
                        Button("Cancel") { model.renaming = false }
                    }
                    .padding(8)
                }
                browser
                if model.showsShelf { shelf }
            }
        }
        .navigationTitle(model.status)
        .toolbar { toolbar }
        .inspector(isPresented: $model.showsInspector) { inspector }
        .sheet(item: $model.sheet) { sheet in
            sheetView(sheet)
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var sidebar: some View {
        List(selection: $model.snapshot.connectionID) {
            Section("Servers") {
                ForEach(model.connections) { connection in
                    Text(connection.displayName)
                        .tag(connection.id as ConnectionID?)
                        .onTapGesture { Task { await model.connect(connection) } }
                }
            }
            if !model.pins.isEmpty {
                Section("Saved Locations") {
                    ForEach(model.pins, id: \.self) { path in
                        Text(path.display).onTapGesture { Task { await model.navigate(path) } }
                    }
                }
            }
            if !model.recents.isEmpty {
                Section("Recents") {
                    ForEach(model.recents, id: \.self) { path in
                        Text(path.display).onTapGesture { Task { await model.navigate(path) } }
                    }
                }
            }
            if !model.livePaths.isEmpty {
                Section("Live Files") {
                    ForEach(model.livePaths, id: \.self) { path in
                        Text(String(decoding: path.nameBytes, as: UTF8.self))
                            .onTapGesture { model.snapshot.selection = [path] }
                    }
                }
            }
            if !model.conflicts.isEmpty {
                Section("Conflicts") {
                    ForEach(model.conflicts, id: \.self) { path in
                        Text(String(decoding: path.nameBytes, as: UTF8.self))
                            .onTapGesture {
                                model.conflictPath = path
                                model.sheet = .conflict
                            }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }

    @ViewBuilder private var browser: some View {
        switch model.snapshot.viewMode {
        case .icon:
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 16) {
                    ForEach(model.displayedItems) { item in
                        VStack {
                            Image(systemName: symbol(item)).font(.largeTitle)
                            FilePromiseLabel(item: item, session: model.session) {
                                model.snapshot.selection = [item.path]
                            } onOpen: {
                                Task { await model.open(item) }
                            }
                            .frame(height: 18)
                        }
                        .frame(width: 96)
                        .padding(6)
                        .background(model.snapshot.selection.contains(item.path) ? Color.accentColor.opacity(0.2) : Color.clear)
                    }
                }
                .padding()
            }
        case .list:
            Table(model.displayedItems, selection: listSelection) {
                TableColumn("Name") { item in
                    FilePromiseLabel(item: item, session: model.session) {
                        model.snapshot.selection = [item.path]
                    } onOpen: {
                        Task { await model.open(item) }
                    }
                    .frame(height: 18)
                }
                TableColumn("Status") { item in
                    Text(model.livePaths.contains(item.path) ? "Live" : "")
                }
                TableColumn("Date Modified") { Text($0.mtime.map { date($0) } ?? "") }
                TableColumn("Size") { Text($0.kind == .file ? byteCount($0.size) : "") }
                TableColumn("Kind") { Text($0.kind.rawValue) }
            }
            .contextMenu { Button("Open") { Task { await openSelection() } } }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { await model.upload(urls: [url]) }
                    }
                }
                return true
            }
        case .columns:
            ColumnBrowser(model: model)
        }
    }

    private var listSelection: Binding<Set<RemotePath>> {
        Binding(
            get: { model.snapshot.selection },
            set: { model.snapshot.selection = $0 }
        )
    }

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.operations) { operation in
                HStack {
                    Text(operation.title)
                    Spacer()
                    Text(operation.state.rawValue).foregroundStyle(.secondary)
                    if let message = operation.message { Text(message).foregroundStyle(.red) }
                    if operation.state == .failed {
                        Button("Remove") { model.operations.removeAll { $0.id == operation.id } }
                    }
                }
            }
        }
        .padding(8)
        .background(.bar)
    }

    private var inspector: some View {
        let item = model.items.first { model.snapshot.selection.contains($0.path) }
        return Form {
            if let item {
                LabeledContent("Name", value: item.name)
                LabeledContent("Path", value: item.path.display)
                LabeledContent("Kind", value: item.kind.rawValue)
                LabeledContent("Size", value: byteCount(item.size))
                LabeledContent("Modified", value: item.mtime.map { date($0) } ?? "")
                if let mode = item.mode { LabeledContent("Permissions", value: String(mode, radix: 8)) }
                Button("Open") { Task { await model.open(item) } }
                Button("Download Copy") { Task { await model.downloadCopy() } }
                Button("Copy Remote URL") { model.copyRemoteURL() }
            } else {
                Text(model.snapshot.path.display).foregroundStyle(.secondary)
            }
        }
        .padding()
        .inspectorColumnWidth(min: 220, ideal: 260)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { Task { await model.goBack() } } label: { Image(systemName: "chevron.backward") }
            Button { Task { await model.goForward() } } label: { Image(systemName: "chevron.forward") }
            Text(model.snapshot.path.display).lineLimit(1)
            TextField("Filter", text: $model.filter).frame(width: 160)
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
            Picker("View", selection: $model.snapshot.viewMode) {
                Image(systemName: "square.grid.2x2").tag(ViewMode.icon)
                Image(systemName: "list.bullet").tag(ViewMode.list)
                Image(systemName: "rectangle.split.3x1").tag(ViewMode.columns)
            }
            .pickerStyle(.segmented)
            Button { model.showsInspector.toggle() } label: { Image(systemName: "info.circle") }
            Button { model.showsShelf.toggle() } label: { Image(systemName: "arrow.up.arrow.down") }
        }
    }

    @ViewBuilder private func sheetView(_ sheet: AppSheet) -> some View {
        switch sheet {
        case .connection:
            ConnectionForm(model: model)
        case .prompt(let request):
            VStack(alignment: .leading, spacing: 12) {
                Text(request.text)
                SecureField("Password", text: $model.promptSecure)
                if request.offerKeychain {
                    Toggle("Save in Keychain", isOn: $model.saveSecret)
                }
                HStack {
                    Button("Cancel") { model.finishPrompt(PromptReply(text: nil)) }
                    Spacer()
                    Button("Continue") {
                        model.finishPrompt(PromptReply(text: model.promptSecure, saveInKeychain: model.saveSecret))
                        model.promptSecure = ""
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 360)
        case .hostKey(let event):
            VStack(alignment: .leading, spacing: 12) {
                Text(event.situation == .changed ? "The host key changed" : "First time connecting")
                    .font(.headline)
                Text("\(event.keyType) \(event.fingerprint)")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                HStack {
                    Button("Cancel") { model.finishHost(.cancel) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if event.situation == .firstSeen {
                        Button("Trust Once") { model.finishHost(.trustOnce) }
                        Button("Always Trust") { model.finishHost(.alwaysTrust) }
                    } else {
                        Button("Replace Trusted Key") { model.finishHost(.replace) }
                    }
                }
            }
            .padding()
            .frame(width: 420)
        case .delete:
            VStack(alignment: .leading, spacing: 12) {
                Text("Delete \(model.snapshot.selection.count) items permanently?")
                Text("This cannot be undone. Unsynced Live edits in the selection are discarded.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Delete") {
                        model.sheet = nil
                        Task { await model.deleteSelection() }
                    }
                }
            }
            .padding()
            .frame(width: 380)
        case .collision(let name):
            VStack(alignment: .leading, spacing: 12) {
                Text("“\(name)” already exists")
                Toggle("Apply to all", isOn: $model.applyCollisionToAll)
                HStack {
                    Button("Skip") { model.finishCollision(.skip, applyToAll: model.applyCollisionToAll) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Keep Both") { model.finishCollision(.keepBoth, applyToAll: model.applyCollisionToAll) }
                    Button("Replace") { model.finishCollision(.replace, applyToAll: model.applyCollisionToAll) }
                }
            }
            .padding()
            .frame(width: 380)
        case .conflict:
            VStack(alignment: .leading, spacing: 12) {
                Text("This Live file changed on the server")
                    .font(.headline)
                Text("Neither version has been overwritten.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Compare") { Task { await model.resolveConflict(.compare) } }
                    Button("Keep Local") { Task { await model.resolveConflict(.keepLocal) } }
                    Button("Keep Remote") { Task { await model.resolveConflict(.keepRemote) } }
                    Button("Keep Both") { Task { await model.resolveConflict(.keepBoth) } }
                }
            }
            .padding()
            .frame(width: 460)
        case .goToFolder:
            VStack(alignment: .leading, spacing: 12) {
                Text("Go to Remote Folder")
                TextField("Remote path", text: $model.folderText)
                HStack {
                    Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Go") {
                        let text = model.folderText
                        model.sheet = nil
                        Task { await model.goToFolder(text) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 420)
        case .quit(let count):
            VStack(alignment: .leading, spacing: 12) {
                Text("\(count) Live file\(count == 1 ? "" : "s") still have unsynced edits.")
                HStack {
                    Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Quit Anyway") { NSApp.terminate(nil) }
                }
            }
            .padding()
            .frame(width: 380)
        }
    }

    private func go(_ path: RemotePath) async {
        model.snapshot.path = path
        await model.refresh()
    }

    private func back() async {
        guard let parent = model.snapshot.path.parent else { return }
        model.snapshot.path = parent
        await model.refresh()
    }

    private func openSelection() async {
        guard let item = model.items.first(where: { model.snapshot.selection.contains($0.path) }) else { return }
        await model.open(item)
    }

    private func symbol(_ item: RemoteItem) -> String {
        switch item.kind {
        case .directory: "folder"
        case .symlink: "link"
        case .file: "doc"
        case .other: "questionmark.square"
        }
    }

    private func byteCount(_ size: UInt64?) -> String {
        guard let size else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private func date(_ mtime: UInt32) -> String {
        Date(timeIntervalSince1970: TimeInterval(mtime)).formatted(date: .abbreviated, time: .shortened)
    }
}

struct ConnectionForm: View {
    @Bindable var model: TransferModel

    var body: some View {
        Form {
            TextField("Name", text: $model.draft.name)
            TextField("Host", text: $model.draft.host)
            TextField("User", text: $model.draft.user)
            TextField("Port", text: $model.draft.port)
            TextField("Identity file", text: $model.draft.identityFile)
            TextField("Remote path", text: $model.draft.remotePath)
        }
        .padding()
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.sheet = nil } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Connect") { Task { await model.saveDraft() } }
                    .disabled(model.draft.host.isEmpty)
            }
        }
    }
}

enum TerminalLauncher {
    static func open(connection: SavedConnection, command: String) {
        let apps = ["Terminal", "iTerm2", "Ghostty"]
        let running = NSWorkspace.shared.runningApplications.compactMap(\.localizedName)
        let choice = apps.first { running.contains($0) } ?? apps.first { appExists($0) }
        guard let choice else { return }
        let destination = connection.destination
        let port = connection.port.isEmpty ? "" : " -p \(connection.port)"
        let ssh = "ssh\(port) -t \(destination) \(shellQuote(command))"
        let script: String
        if choice == "Terminal" {
            script = "tell application \"Terminal\" to do script \(shellQuote(ssh))"
        } else {
            script = "tell application \(shellQuote(choice)) to activate"
        }
        if choice == "Terminal" {
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", choice, "--args", "-e", ssh]
            try? process.run()
        }
    }

    private static func appExists(_ name: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle(name)) != nil
            || FileManager.default.fileExists(atPath: "/Applications/\(name).app")
    }

    private static func bundle(_ name: String) -> String {
        switch name {
        case "iTerm2": "com.googlecode.iterm2"
        case "Ghostty": "com.mitchellh.ghostty"
        default: "com.apple.Terminal"
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

final class PreviewPanel: NSObject, QLPreviewPanelDataSource, @unchecked Sendable {
    static let shared = PreviewPanel()
    private let lock = NSLock()
    private var url: URL?

    @MainActor
    func show(_ url: URL) {
        lock.lock()
        self.url = url
        lock.unlock()
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        lock.lock()
        defer { lock.unlock() }
        return (url ?? URL(fileURLWithPath: "/")) as NSURL
    }
}
