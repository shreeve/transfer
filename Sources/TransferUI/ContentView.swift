import AppKit
import SwiftUI
import TransferCore
import UniformTypeIdentifiers

public struct ContentView: View {
    @Bindable var model: TransferModel
    @FocusState private var filterFocused: Bool
    @FocusState private var renameFocused: Bool

    public init(model: TransferModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if model.renaming { renameBar }
                browser
                if model.showsShelf { shelf }
            }
            .background(WindowFrameSaver(name: "Transfer.Browser"))
        }
        .navigationTitle(model.status)
        .navigationSubtitle(model.snapshot.connectionID == nil ? "" : model.snapshot.path.display)
        .toolbar { toolbar }
        .inspector(isPresented: $model.showsInspector) { inspector }
        .sheet(item: $model.sheet) { sheet in sheetView(sheet) }
        .focusedSceneValue(\.transferModel, model)
        .onChange(of: model.sortOrder) { model.applySort() }
        .onChange(of: model.columnCustomization) { model.saveColumns() }
        .onChange(of: model.snapshot.selection) { model.selectionChanged() }
        .onChange(of: model.filterFocusTick) { filterFocused = true }
        .onChange(of: filterFocused) { model.textEditing = filterFocused || renameFocused }
        .onChange(of: renameFocused) { model.textEditing = filterFocused || renameFocused }
        .onChange(of: model.renaming) { if model.renaming { renameFocused = true } }
        .onChange(of: model.sidebarSelection) { _, item in Task { await model.sidebarSelected(item) } }
        .frame(minWidth: 760, minHeight: 480)
    }

    // MARK: Sidebar

    private var sidebar: some View {
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
            if !model.recents.isEmpty {
                Section("Recents") {
                    ForEach(model.recents, id: \.self) { path in
                        Label(folderName(path), systemImage: "clock")
                            .help(path.display)
                            .tag(SidebarItem.recent(path))
                    }
                }
            }
            if !model.pins.isEmpty {
                Section("Saved Locations") {
                    ForEach(model.pins, id: \.self) { path in
                        Label(folderName(path), systemImage: "folder")
                            .help(path.display)
                            .tag(SidebarItem.pin(path))
                            .contextMenu {
                                Button("Remove from Saved Locations") { Task { await model.unpin(path) } }
                            }
                    }
                }
            }
            if !model.liveFiles.isEmpty {
                Section("Live Files") {
                    ForEach(model.liveFiles) { live in
                        Label {
                            Text(String(decoding: live.path.nameBytes, as: UTF8.self))
                        } icon: {
                            Image(systemName: liveSymbol(live))
                        }
                        .help(live.path.display)
                        .tag(SidebarItem.live(live.path))
                        .contextMenu {
                            Button("Discard Live File") { Task { await model.discardLive(live.path) } }
                                .disabled(live.uploading)
                        }
                    }
                }
            }
            if !model.conflicts.isEmpty {
                Section("Conflicts") {
                    ForEach(model.conflicts, id: \.self) { path in
                        Label(String(decoding: path.nameBytes, as: UTF8.self), systemImage: "exclamationmark.triangle")
                            .help(path.display)
                            .tag(SidebarItem.conflict(path))
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }

    private func folderName(_ path: RemotePath) -> String {
        path.isRoot ? "/" : String(decoding: path.nameBytes, as: UTF8.self)
    }

    private func liveSymbol(_ live: LiveFile) -> String {
        if live.conflict { return "exclamationmark.triangle" }
        if live.uploading { return "arrow.up.circle" }
        if live.paused { return "pause.circle" }
        return live.dirty ? "circle.fill" : "circle"
    }

    // MARK: Browser

    private var renameBar: some View {
        HStack {
            TextField("Name", text: $model.renameText)
                .textFieldStyle(.roundedBorder)
                .focused($renameFocused)
                .onSubmit { Task { await model.renameSelection(to: model.renameText) } }
                .onExitCommand { model.renaming = false }
            Button("Rename") { Task { await model.renameSelection(to: model.renameText) } }
                .keyboardShortcut(.defaultAction)
            Button("Cancel") { model.renaming = false }
        }
        .padding(8)
    }

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
            case .list: listView
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

    private var listView: some View {
        Table(
            model.displayedItems,
            selection: $model.snapshot.selection,
            sortOrder: $model.sortOrder,
            columnCustomization: $model.columnCustomization
        ) {
            TableColumn("Name", value: \RemoteItem.name) { item in
                HStack(spacing: 6) {
                    Image(nsImage: ItemIcon.image(for: item))
                        .resizable()
                        .frame(width: 16, height: 16)
                    FilePromiseLabel(item: item, model: model)
                        .frame(height: 18)
                }
            }
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Status", value: \RemoteItem.statusLabel) { item in
                Text(status(item)).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)
            .customizationID("status")
            TableColumn("Date Modified", value: \RemoteItem.sortMtime) { item in
                Text(item.mtime.map { date($0) } ?? "")
            }
            .width(min: 120, ideal: 160)
            .customizationID("modified")
            TableColumn("Size", value: \RemoteItem.sortSize) { item in
                Text(item.kind == .file ? byteCount(item.size) : "")
            }
            .width(min: 60, ideal: 80)
            .customizationID("size")
            TableColumn("Kind", value: \RemoteItem.kindLabel) { item in
                Text(item.kindLabel)
            }
            .width(min: 80, ideal: 120)
            .customizationID("kind")
        }
        .contextMenu(forSelectionType: RemotePath.self) { paths in
            if let item = model.items.first(where: { paths.contains($0.path) }) { rowMenu(item) }
        } primaryAction: { paths in
            if let item = model.items.first(where: { paths.contains($0.path) }) {
                Task { await model.open(item) }
            }
        }
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
        if item.kind == .directory {
            Button("Save Location") { Task { await model.session?.pin(item.path); await model.refresh() } }
        }
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

    private func status(_ item: RemoteItem) -> String {
        if let live = model.liveFile(for: item.path) {
            if live.conflict { return "Conflict" }
            if live.uploading { return "Uploading" }
            if live.paused { return "Paused" }
            return live.dirty ? "Live, unsynced" : "Live"
        }
        if model.operations.contains(where: { $0.state == .active && $0.title.hasSuffix(item.name) }) {
            return "Transferring"
        }
        return ""
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
        if progress.completed > 0 { parts.append(byteCount(progress.completed)) }
        if progress.itemsCompleted > 0 { parts.append("\(progress.itemsCompleted) items") }
        return parts.joined(separator: ", ")
    }

    // MARK: Inspector

    private var inspector: some View {
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
                if item.kind == .file { LabeledContent("Size", value: byteCount(item.size)) }
                LabeledContent("Modified", value: item.mtime.map { date($0) } ?? "")
                if let mode = item.mode { LabeledContent("Permissions", value: permissions(mode)) }
                if let owner = item.owner { LabeledContent("Owner", value: owner) }
                if let group = item.group { LabeledContent("Group", value: group) }
                if item.kind == .symlink { LabeledContent("Target", value: model.inspectorLinkTarget ?? "…") }
                if model.liveFile(for: item.path) != nil { LabeledContent("Live", value: status(item)) }
                if let operation = model.operations.first(where: { $0.livePath == item.path || $0.title.hasSuffix(item.name) }) {
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
        .inspectorColumnWidth(min: 240, ideal: 280)
    }

    private func permissions(_ mode: UInt32) -> String {
        let bits = mode & 0o777
        let letters = ["---", "--x", "-w-", "-wx", "r--", "r-x", "rw-", "rwx"]
        return letters[Int(bits >> 6 & 7)] + letters[Int(bits >> 3 & 7)] + letters[Int(bits & 7)]
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { Task { await model.goBack() } } label: { Image(systemName: "chevron.backward") }
                .help("Back")
            Button { Task { await model.goForward() } } label: { Image(systemName: "chevron.forward") }
                .help("Forward")
        }
        ToolbarItemGroup {
            Picker("View", selection: Binding(get: { model.snapshot.viewMode }, set: { model.setViewMode($0) })) {
                Image(systemName: "square.grid.2x2").tag(ViewMode.icon).help("Icon")
                Image(systemName: "list.bullet").tag(ViewMode.list).help("List")
                Image(systemName: "rectangle.split.3x1").tag(ViewMode.columns).help("Columns")
            }
            .pickerStyle(.segmented)
            TextField("Filter", text: $model.filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .focused($filterFocused)
            Button {
                model.showsShelf.toggle()
            } label: {
                let active = model.operations.filter { $0.state == .active }.count
                if active > 0 {
                    Label("\(active)", systemImage: "arrow.up.arrow.down.circle").labelStyle(.titleAndIcon)
                } else {
                    Label("Transfers", systemImage: "arrow.up.arrow.down.circle").labelStyle(.iconOnly)
                }
            }
            .help("Transfers")
        }
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
        case .quit(let count):
            VStack(alignment: .leading, spacing: 12) {
                Text("\(count) Live file\(count == 1 ? " has" : "s have") unsynced edits").font(.headline)
                Text("Uploads run only while Transfer is open.").foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { model.sheet = nil }.keyboardShortcut(.defaultAction)
                    Spacer()
                    Button("Quit Anyway") { NSApp.terminate(nil) }
                }
            }
            .padding()
            .frame(width: 400)
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
        case .discardLive(let path):
            VStack(alignment: .leading, spacing: 12) {
                Text("Discard unsynced edits to “\(String(decoding: path.nameBytes, as: UTF8.self))”?").font(.headline)
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
        }
    }

    private var conflictSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(model.conflictPath.map { String(decoding: $0.nameBytes, as: UTF8.self) } ?? "")” changed on the server")
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
    }

    private func goToFolder() {
        let text = model.folderText
        model.sheet = nil
        Task { await model.goToFolder(text) }
    }

    private func byteCount(_ size: UInt64?) -> String {
        guard let size else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private func date(_ mtime: UInt32) -> String {
        Date(timeIntervalSince1970: TimeInterval(mtime)).formatted(date: .abbreviated, time: .shortened)
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
