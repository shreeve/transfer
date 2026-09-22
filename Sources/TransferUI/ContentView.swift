import AppKit
import SwiftUI
import TransferCore
import UniformTypeIdentifiers

public struct ContentView: View {
    let model: TransferModel

    public init(model: TransferModel) {
        self.model = model
    }

    public var body: some View {
        WindowChrome(
            model: model,
            title: model.status,
            subtitle: model.snapshot.connectionID == nil ? "" : model.snapshot.path.display,
            viewMode: model.snapshot.viewMode,
            sidebarCollapsed: model.sidebarCollapsed,
            inspectorShown: model.showsInspector,
            searchTick: model.filterFocusTick,
            sidebar: SidebarColumn(model: model),
            detail: DetailColumn(model: model),
            inspector: InspectorColumn(model: model)
        )
        .ignoresSafeArea()
        .focusedSceneValue(\.transferModel, model)
        .onChange(of: model.snapshot.selection) { model.selectionChanged() }
        .onChange(of: model.sidebarSelection) { _, item in Task { await model.sidebarSelected(item) } }
        .frame(minWidth: 640, idealWidth: 960, minHeight: 400, idealHeight: 640)
    }
}

/// The sidebar column. It observes the model itself, so the chrome never re-hosts it.
struct SidebarColumn: View {
    @Bindable var model: TransferModel

    // MARK: Sidebar

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Section("Servers") {
                ForEach(model.connections) { connection in
                    Label(connection.displayName, systemImage: "server.rack")
                        .tag(SidebarItem.server(connection.id))
                        .contextMenu {
                            Button("Connect") { Task { await model.connect(connection) } }
                            Button("Edit…") { model.editConnection(connection) }
                            Divider()
                            Button("Remove…") { model.askToRemove(connection) }
                        }
                }
                Button("Add Server…") { model.newConnection() }
                    .buttonStyle(.link)
            }
            if !model.pins.isEmpty {
                Section("Starred") {
                    ForEach(model.pins, id: \.self) { path in
                        Label(folderName(path), systemImage: model.starredIsFolder(path) ? "star" : "star.fill")
                            .help(path.display)
                            .tag(SidebarItem.pin(path))
                            // A double-click opens the item the way the browser would: Live or view for a
                            // file, after revealing it, and its listing for a folder.
                            .onTapGesture(count: 2) { Task { await model.openStarred(path) } }
                            .contextMenu {
                                Button("Open") { Task { await model.openStarred(path) } }
                                Button("Unstar") { Task { await model.setStarred(path, false) } }
                            }
                    }
                }
            }
            if !model.activeLiveFiles.isEmpty {
                Section("Live Files") {
                    ForEach(model.activeLiveFiles) { live in
                        Label {
                            Text(live.path.name)
                        } icon: {
                            Image(systemName: liveSymbol(live))
                        }
                        .help(liveHelp(live))
                        .tag(SidebarItem.live(live.path))
                        .contextMenu {
                            Button("Discard Live File") { Task { await model.discardLive(live.path) } }
                                .disabled(live.uploading)
                            Button("Forget All Synced Live Files") { Task { await model.forgetSyncedLive() } }
                                .disabled(!model.liveFiles.contains { !$0.dirty && !$0.uploading && !$0.conflict })
                        }
                    }
                }
            }
            if !model.conflicts.isEmpty {
                Section("Conflicts") {
                    ForEach(model.conflicts, id: \.self) { path in
                        Label(path.name, systemImage: "exclamationmark.triangle")
                            .help(path.display)
                            .tag(SidebarItem.conflict(path))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollEdgeEffectHidden(true, for: .top)
    }

    private func folderName(_ path: RemotePath) -> String {
        path.isRoot ? "/" : path.name
    }

    private func liveSymbol(_ live: LiveFile) -> String {
        if live.conflict { return "exclamationmark.triangle.fill" }
        if live.uploading { return "arrow.up.circle.fill" }
        if live.paused { return "pause.circle" }
        return live.dirty ? "pencil.circle.fill" : "checkmark.circle"
    }

    private func liveHelp(_ live: LiveFile) -> String {
        let state: String
        if live.conflict { state = "Changed on the server; needs a decision" }
        else if live.uploading { state = "Uploading" }
        else if live.paused { state = "Paused" }
        else if live.dirty { state = "Edited here, not yet uploaded" }
        else { state = "Synced; saves in the editor upload" }
        return "\(live.path.display)\n\(state)"
    }
}

/// The content column: browser, rename bar, shelf, and every sheet.
struct DetailColumn: View {
    @Bindable var model: TransferModel

    var body: some View {
        VStack(spacing: 0) {
            if model.renaming { RenameBar(model: model) }
            browser
            if model.showsShelf { shelf }
        }
        .sheet(item: $model.sheet) { sheet in sheetView(sheet) }
        .scrollEdgeEffectHidden(true, for: .top)
    }

    // MARK: Browser

    @ViewBuilder private var browser: some View {
        if model.snapshot.connectionID == nil {
            ContentUnavailableView {
                Label("No Server", systemImage: "server.rack")
            } description: {
                Text("Choose a server in the sidebar or add one.")
            } actions: {
                Button("Add Server…") { model.newConnection() }
            }
        } else {
            switch model.snapshot.viewMode {
            case .icon: iconView
            case .list: ListTable(model: model)
            case .columns: ColumnBrowser(model: model)
            }
        }
    }

    private var iconView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 16) {
                ForEach(model.displayedItems) { item in
                    VStack(spacing: 4) {
                        Image(nsImage: ItemIcon.image(for: item))
                            .resizable()
                            .frame(width: 48, height: 48)
                        FilePromiseLabel(item: item, model: model)
                            .frame(height: 18)
                    }
                    .frame(width: 96)
                    .padding(6)
                    .background(model.snapshot.selection.contains(item.path) ? Color.accentColor.opacity(0.2) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { Task { await model.open(item) } }
                    .onTapGesture { model.snapshot.selection = [item.path] }
                    .contextMenu { rowMenu(item) }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.snapshot.selection = [] }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in dropFiles(providers) }
    }

    private func dropFiles(_ providers: [NSItemProvider]) -> Bool {
        let collector = URLCollector(count: providers.count) { urls in
            Task { await model.upload(urls: urls) }
        }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in collector.add(url) }
        }
        return !providers.isEmpty
    }

    @ViewBuilder private func rowMenu(_ item: RemoteItem) -> some View {
        Button("Open") { Task { await model.open(item) } }
        if item.kind == .file {
            Button("Open Live") {
                model.snapshot.selection = [item.path]
                Task { await model.openLiveSelection() }
            }
        }
        Button("Quick Look") {
            model.snapshot.selection = [item.path]
            model.showPreview()
        }
        Divider()
        Button("Download Copy…") {
            if !model.snapshot.selection.contains(item.path) { model.snapshot.selection = [item.path] }
            Task { await model.downloadCopy() }
        }
        if item.kind == .file {
            Button("Duplicate") {
                model.snapshot.selection = [item.path]
                Task { await model.duplicateSelection() }
            }
        }
        Button("Rename") {
            model.snapshot.selection = [item.path]
            model.beginRename()
        }
        Button(model.isStarred(item.path) ? "Unstar" : "Star") { Task { await model.setStarred(item.path, !model.isStarred(item.path)) } }
        Button("Copy Remote URL") {
            model.snapshot.selection = [item.path]
            model.copyRemoteURL()
        }
        Divider()
        Button("Delete…") {
            if !model.snapshot.selection.contains(item.path) { model.snapshot.selection = [item.path] }
            model.askToDelete()
        }
    }


    // MARK: Shelf

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.operations) { operation in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(operation.title).lineLimit(1)
                        if let message = operation.message, operation.state != .active {
                            Text(message).font(.caption).foregroundStyle(operation.state == .failed ? .red : .secondary)
                        }
                    }
                    Spacer()
                    if operation.state == .active || operation.state == .paused {
                        if let total = operation.progress.total, total > 0 {
                            ProgressView(value: Double(operation.progress.completed), total: Double(total))
                                .frame(width: 140)
                        } else {
                            Text(progressText(operation.progress)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(operation.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                    switch operation.state {
                    case .active, .queued:
                        Button("Pause") { Task { await model.pause(operation) } }
                    case .paused:
                        Button("Resume") { Task { await model.resume(operation) } }
                    case .failed:
                        Button("Retry") { Task { await model.resume(operation) } }
                        Button("Remove") { model.remove(operation) }
                    case .succeeded, .canceled:
                        EmptyView()
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(.bar)
    }

    private func progressText(_ progress: TransferProgress) -> String {
        var parts: [String] = []
        if progress.completed > 0 { parts.append(Format.bytes(progress.completed)) }
        if progress.itemsCompleted > 0 { parts.append("\(progress.itemsCompleted) items") }
        return parts.joined(separator: ", ")
    }

    // MARK: Sheets

    @ViewBuilder private func sheetView(_ sheet: AppSheet) -> some View {
        switch sheet {
        case .connection:
            ConnectionForm(model: model)
        case .prompt(let request):
            VStack(alignment: .leading, spacing: 12) {
                Text(model.currentConnection?.displayName ?? model.draft.displayName).font(.headline)
                Text(request.text)
                SecureField("Password", text: $model.promptSecure)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.finishPrompt(PromptReply(text: model.promptSecure, saveInKeychain: model.saveSecret)) }
                if request.offerKeychain {
                    Toggle("Save in Keychain", isOn: $model.saveSecret)
                }
                HStack {
                    Button("Cancel") { model.finishPrompt(PromptReply(text: nil)) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Continue") {
                        model.finishPrompt(PromptReply(text: model.promptSecure, saveInKeychain: model.saveSecret))
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 380)
            .onExitCommand { model.finishPrompt(PromptReply(text: nil)) }
        case .hostKey(let event):
            VStack(alignment: .leading, spacing: 12) {
                Text(event.situation == .changed ? "The host key changed" : "First time connecting to this server")
                    .font(.headline)
                Text(event.situation == .changed
                     ? "The server now presents a different key. Someone could be intercepting the connection."
                     : "Check this fingerprint against one you got from the server's owner.")
                    .foregroundStyle(.secondary)
                LabeledContent("Key type", value: event.keyType)
                LabeledContent("SHA256", value: event.fingerprint)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                HStack {
                    Button("Cancel") { model.finishHost(.cancel) }
                        .keyboardShortcut(.defaultAction)
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
            .frame(width: 460)
            .onExitCommand { model.finishHost(.cancel) }
        case .delete:
            let count = model.snapshot.selection.count
            let unsynced = model.unsyncedInSelection
            VStack(alignment: .leading, spacing: 12) {
                Text("Delete \(count) item\(count == 1 ? "" : "s")?").font(.headline)
                Text("The delete is permanent. There is no trash on the server.")
                    .foregroundStyle(.secondary)
                if unsynced > 0 {
                    Text("\(unsynced) Live file\(unsynced == 1 ? " has" : "s have") unsynced edits that will be discarded.")
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Cancel") { model.sheet = nil }.keyboardShortcut(.defaultAction)
                    Spacer()
                    Button("Delete") {
                        model.sheet = nil
                        Task { await model.deleteSelection() }
                    }
                }
            }
            .padding()
            .frame(width: 400)
            .onExitCommand { model.sheet = nil }
        case .collision(let name):
            VStack(alignment: .leading, spacing: 12) {
                Text("“\(name)” already exists").font(.headline)
                Text("Keep Both saves the new file with a number before its extension.")
                    .foregroundStyle(.secondary)
                Toggle("Apply to all in this operation", isOn: $model.applyCollisionToAll)
                HStack {
                    Button("Skip") { model.finishCollision(.skip, applyToAll: model.applyCollisionToAll) }
                        .keyboardShortcut(.defaultAction)
                    Spacer()
                    Button("Keep Both") { model.finishCollision(.keepBoth, applyToAll: model.applyCollisionToAll) }
                    Button("Replace") { model.finishCollision(.replace, applyToAll: model.applyCollisionToAll) }
                }
            }
            .padding()
            .frame(width: 400)
            .onExitCommand { model.finishCollision(.skip, applyToAll: model.applyCollisionToAll) }
        case .conflict:
            conflictSheet
        case .goToFolder:
            VStack(alignment: .leading, spacing: 12) {
                Text("Go to Remote Folder").font(.headline)
                TextField("Remote path", text: $model.folderText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { goToFolder() }
                HStack {
                    Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Go") { goToFolder() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 420)
            .onExitCommand { model.sheet = nil }
        case .removeServer(let connection):
            VStack(alignment: .leading, spacing: 12) {
                Text("Remove “\(connection.displayName)”?").font(.headline)
                Text("Only the saved connection is removed. Nothing on the server changes.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { model.sheet = nil }.keyboardShortcut(.defaultAction)
                    Spacer()
                    Button("Remove") { Task { await model.removeServer(connection) } }
                }
            }
            .padding()
            .frame(width: 400)
            .onExitCommand { model.sheet = nil }
        case .discardLive(let path):
            VStack(alignment: .leading, spacing: 12) {
                Text("Discard unsynced edits to “\(path.name)”?").font(.headline)
                Text("The working copy has changes that were not uploaded.").foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { model.sheet = nil }.keyboardShortcut(.defaultAction)
                    Spacer()
                    Button("Discard") {
                        model.sheet = nil
                        Task { await model.discardLive(path, force: true) }
                    }
                }
            }
            .padding()
            .frame(width: 420)
            .onExitCommand { model.sheet = nil }
        }
    }

    private var conflictSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(model.conflictPath?.name ?? "")” changed on the server")
                .font(.headline)
            Text("Neither version has been overwritten.").foregroundStyle(.secondary)
            if let confirm = model.conflictConfirm {
                Text(confirm == .keepLocal
                     ? "Keep Local overwrites the server copy with this Mac's edits. Press again to confirm."
                     : "Keep Remote replaces this Mac's edits with the server copy. Press again to confirm.")
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Compare") { Task { await model.chooseConflict(.compare) } }
                    .disabled(!model.conflictComparable)
                Spacer()
                Button(model.conflictConfirm == .keepLocal ? "Confirm Keep Local" : "Keep Local") {
                    Task { await model.chooseConflict(.keepLocal) }
                }
                Button(model.conflictConfirm == .keepRemote ? "Confirm Keep Remote" : "Keep Remote") {
                    Task { await model.chooseConflict(.keepRemote) }
                }
                Button("Keep Both") { Task { await model.chooseConflict(.keepBoth) } }
            }
            HStack {
                Button("Later") { model.sheet = nil; model.conflictConfirm = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
        .padding()
        .frame(width: 520)
        .onExitCommand { model.sheet = nil; model.conflictConfirm = nil }
    }

    private func goToFolder() {
        let text = model.folderText
        model.sheet = nil
        Task { await model.goToFolder(text) }
    }


}

/// The inspector column.
struct InspectorColumn: View {
    let model: TransferModel

    // MARK: Inspector

    var body: some View {
        let selected = model.selectedItems
        return Form {
            if selected.count > 1 {
                Text("\(selected.count) items selected").foregroundStyle(.secondary)
            } else if let item = selected.first {
                HStack {
                    Image(nsImage: ItemIcon.image(for: item)).resizable().frame(width: 32, height: 32)
                    Text(item.name).font(.headline)
                }
                LabeledContent("Path", value: item.path.display)
                LabeledContent("Kind", value: item.kindLabel)
                if item.kind == .file { LabeledContent("Size", value: Format.bytes(item.size)) }
                LabeledContent("Modified", value: item.mtime.map { Format.date($0) } ?? "")
                if let mode = item.mode { LabeledContent("Permissions", value: permissions(mode)) }
                if let owner = item.owner { LabeledContent("Owner", value: owner) }
                if let group = item.group { LabeledContent("Group", value: group) }
                if item.kind == .symlink { LabeledContent("Target", value: model.inspectorLinkTarget ?? "…") }
                if model.liveFile(for: item.path) != nil { LabeledContent("Live", value: model.statusText(for: item.path)) }
                if let operation = model.operation(for: item.path) {
                    LabeledContent("Transfer", value: operation.message ?? operation.state.rawValue.capitalized)
                }
                Section {
                    Button("Open") { Task { await model.open(item) } }
                    Button("Open Live") { Task { await model.openLiveSelection() } }
                        .disabled(item.kind != .file)
                    Button("Download Copy…") { Task { await model.downloadCopy() } }
                    Button("Copy Remote URL") { model.copyRemoteURL() }
                }
            } else {
                LabeledContent("Folder", value: model.snapshot.path.display)
                LabeledContent("Items", value: "\(model.items.count)")
                Button("Copy Remote URL") { model.copyRemoteURL() }
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectHidden(true, for: .top)
    }

    private func permissions(_ mode: UInt32) -> String {
        let bits = mode & 0o777
        let letters = ["---", "--x", "-w-", "-wx", "r--", "r-x", "rw-", "rwx"]
        return letters[Int(bits >> 6 & 7)] + letters[Int(bits >> 3 & 7)] + letters[Int(bits & 7)]
    }
}



/// Gathers the URLs of one drop before starting uploads, so one operation row appears per file in order.
private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var remaining: Int
    private let finish: @MainActor ([URL]) -> Void

    init(count: Int, finish: @escaping @MainActor ([URL]) -> Void) {
        remaining = count
        self.finish = finish
    }

    func add(_ url: URL?) {
        lock.lock()
        if let url { urls.append(url) }
        remaining -= 1
        let done = remaining == 0
        let collected = urls
        lock.unlock()
        if done {
            Task { @MainActor in self.finish(collected) }
        }
    }
}

struct ConnectionForm: View {
    @Bindable var model: TransferModel

    var body: some View {
        Form {
            TextField("Name", text: $model.draft.name, prompt: Text("Same as host"))
            TextField("Host", text: $model.draft.host)
            TextField("User", text: $model.draft.user, prompt: Text("From ssh config"))
            TextField("Port", text: $model.draft.port, prompt: Text("From ssh config"))
            TextField("Identity file", text: $model.draft.identityFile, prompt: Text("From ssh config or the agent"))
            TextField("Remote path", text: $model.draft.remotePath, prompt: Text("Remote home"))
        }
        .padding()
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.sheet = nil } }
            ToolbarItem(placement: .confirmationAction) {
                Button(model.draftIsEdit ? "Save" : "Connect") { Task { await model.saveDraft() } }
                    .disabled(model.draft.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// The rename field. Focus state has to live inside the hosted detail subtree, so this is its own view.
private struct RenameBar: View {
    @Bindable var model: TransferModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            TextField("Name", text: $model.renameText)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { Task { await model.renameSelection(to: model.renameText) } }
                .onExitCommand { model.renaming = false }
            Button("Rename") { Task { await model.renameSelection(to: model.renameText) } }
                .keyboardShortcut(.defaultAction)
            Button("Cancel") { model.renaming = false }
        }
        .padding(8)
        .onAppear { focused = true }
        .onChange(of: focused) { model.textEditing = focused }
        .onDisappear { model.textEditing = false }
    }
}
