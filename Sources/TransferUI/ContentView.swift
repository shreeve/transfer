import AppKit
import QuickLookUI
import WebKit
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
                            if live.paused {
                                Button("Resume Syncing") { Task { await model.resumeLive(live.path) } }
                            }
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
            if model.snapshot.connectionID != nil, let clip = Clipboard.shared.clip { ClipBar(clip: clip) }
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
            // Fixed-width columns packed from the left, not stretched to fill: as the inspector
            // narrows the pane, items hold their positions and only the column count steps, so the
            // grid never shimmies. Finder's icon view reflows the same way.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 108), spacing: 16)], alignment: .leading, spacing: 16) {
                ForEach(model.displayedItems) { item in
                    FilePromiseLabel(item: item, model: model)
                        .frame(width: 96, height: 88)
                        .padding(6)
                        .background(model.snapshot.selection.contains(item.path) ? Color.accentColor.opacity(0.2) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contextMenu { rowMenu(item) }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        // The grid's tap also sees clicks on an item, after the item has selected itself on mouse
        // down; only a click on the background clears the selection.
        .onTapGesture {
            if ProcessInfo.processInfo.systemUptime - model.itemClickTime > 0.5 { model.snapshot.selection = [] }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in dropFiles(providers) }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            model.togglePreview()
            return .handled
        }
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
        Button("Copy") {
            if !model.snapshot.selection.contains(item.path) { model.snapshot.selection = [item.path] }
            model.copySelection()
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
        if progress.completed > 0 { parts.append(Format.si(progress.completed)) }
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
    @AppStorage(Preferences.wrapsPreview) private var wrapsPreview = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The view's copy of the model's phase, so each change can pick its own animation.
    @State private var shown = PreviewPhase()
    @State private var previewID = 0

    // MARK: Inspector

    var body: some View {
        let selected = model.selectedItems
        // A plain stack, not a scroll view: hosted scroll views reach up under the toolbar.
        return VStack(alignment: .leading, spacing: 12) {
            if selected.count > 1 {
                Text("\(selected.count) items selected").foregroundStyle(.secondary)
            } else if let item = selected.first {
                facts(item)
                preview(item)
            } else {
                Text(model.snapshot.path.name.isEmpty ? "/" : model.snapshot.path.name).font(.headline)
                Text("\(model.items.count) items").font(.subheadline).foregroundStyle(.secondary)
                line(model.snapshot.path.display).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    /// The file itself when a copy has arrived, else its icon, directly under the facts. Only
    /// source gets a frame, as in Finder; pictures and icons stand on their own.
    private func preview(_ item: RemoteItem) -> some View {
        let phase = PreviewPhase(preview: model.inspectorPreview, wait: model.inspectorWait)
        return ZStack(alignment: .top) {
            if let preview = shown.preview {
                content(preview, item).id(previewID).transition(.opacity)
            } else if shown.wait != .nothing {
                VStack(spacing: 12) {
                    Image(nsImage: ItemIcon.image(for: item)).resizable().frame(width: 96, height: 96)
                    if shown.wait == .spinner { ProgressView().controlSize(.small).transition(.opacity) }
                }
                .padding(.top, 24)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: phase, initial: true) { old, new in
            if new.preview != old.preview { previewID &+= 1 }
            withAnimation(animation(from: old, to: new)) { shown = new }
        }
    }

    /// A swap inside the hold reads as instant, so it gets no animation, and so does content
    /// landing in an empty pane. Old content fades out, the icon and spinner fade in, and a
    /// picture arriving over the icon crossfades. Web and Quick Look views draw late, so a fade
    /// on them would only show an empty box.
    private func animation(from old: PreviewPhase, to new: PreviewPhase) -> Animation? {
        guard !reduceMotion else { return nil }
        if let preview = new.preview {
            guard old.preview == nil, old.wait != .nothing, case .picture = preview else { return nil }
            return .easeOut(duration: PreviewTiming.reveal)
        }
        if old.preview != nil { return .easeOut(duration: PreviewTiming.swap) }
        if new.wait != old.wait { return .easeIn(duration: PreviewTiming.reveal) }
        return nil
    }

    @ViewBuilder private func content(_ preview: InspectorPreview, _ item: RemoteItem) -> some View {
        switch preview {
        case .picture(let picture):
            Image(decorative: picture, scale: 1).resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: .top)
        case .file(let url):
            QuickLookPreview(url: url)
        case .text(let text):
            VStack(alignment: .trailing, spacing: 4) {
                SourcePreview(html: SyntaxPreview.html(text: text, fileName: item.name, compact: true, wraps: wrapsPreview))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                Toggle("Wrap lines", isOn: $wrapsPreview)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            }
        }
    }


    /// Name, then kind against size, then the `ls -l` facts; the folder is already in the title
    /// bar. Actions live in the context menu and on double-click, as in the browser.
    private func facts(_ item: RemoteItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
            HStack {
                Text(item.kindLabel)
                Spacer()
                if item.kind == .file { Text(Format.si(item.size)).monospacedDigit() }
            }
            Divider().padding(.vertical, 4)
            if let mtime = item.mtime {
                HStack {
                    Text(Format.day(mtime))
                    Spacer()
                    Text(Format.clock(mtime)).monospacedDigit()
                }
            }
            HStack {
                if let mode = item.mode { Text(permissions(mode)).monospaced() }
                Spacer()
                if let owner = item.owner { Text(item.group.map { "\(owner):\($0)" } ?? owner) }
            }
            if item.kind == .symlink { line("→ \(model.inspectorLinkTarget ?? "…")") }
            if model.liveFile(for: item.path) != nil { line(model.statusText(for: item.path)) }
            if let operation = model.operation(for: item.path) {
                line(operation.message ?? operation.state.rawValue.capitalized)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(text)
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
/// What the clipboard holds, over the shelf in every window until it is cleared, replaced, or
/// pasted with a move. Items copied in Transfer are made ready for Finder in the background.
private struct ClipBar: View {
    let clip: Clipboard.Clip

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text("Copied \(ClipText.summary(clip.tally, name: clip.name))")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                Clipboard.shared.clear()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Clear the clipboard (Escape)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.14))
        .overlay(alignment: .leading) { Rectangle().fill(Color.yellow).frame(width: 3) }
        .overlay(alignment: .top) { Divider() }
    }

    private var detail: String {
        var parts: [String] = []
        switch clip.source {
        case .remote(_, let place, _): parts.append("from \(place)")
        case .finder: parts.append("from Finder")
        }
        parts.append("⌘V pastes, ⌥⌘V moves, Esc clears")
        switch clip.finder {
        case .notNeeded: break
        case .preparing(let fraction): parts.append("getting ready for Finder \(Int(fraction * 100))%")
        case .ready: parts.append("Finder can paste it too")
        case .tooLarge: parts.append("too large to paste in Finder")
        case .failed(let text): parts.append("Finder cannot paste it: \(text)")
        }
        return parts.joined(separator: " · ")
    }
}

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

/// Quick Look's preview of a local file, inline.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
}

/// Highlighted source in a web view, scrollable, with the pane's own background.
struct SourcePreview: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(html, baseURL: nil)
        context.coordinator.html = html
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        view.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var html = ""
    }
}

/// What the inspector's preview area shows: content, or a wait state while none is up.
struct PreviewPhase: Equatable {
    var preview: InspectorPreview?
    var wait: InspectorWait = .nothing
}
