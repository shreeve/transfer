import AppKit
import QuickLookUI
import WebKit
import SwiftUI
import TransferCore
import UniformTypeIdentifiers

/// A browser window's SwiftUI content: sidebar, detail, and inspector columns. `WindowChrome` hosts
/// each once and each observes the model itself (HANDOFF.md, Window chrome).
public struct ContentView: View {
    let model: TransferModel

    public init(model: TransferModel) {
        self.model = model
    }

    public var body: some View {
        WindowChrome(
            model: model,
            title: model.title,
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
        .task { model.start() }
        .frame(minWidth: 640, idealWidth: 960, minHeight: 400, idealHeight: 640)
    }
}

/// The sidebar column. It observes the model itself, so the chrome never re-hosts it.
struct SidebarColumn: View {
    @Bindable var model: TransferModel

    // MARK: Sidebar

    var body: some View {
        // Only a click acts: the model setting the selection back to the server shown is not a
        // click on that server, which would stop a login to another.
        List(selection: Binding(get: { model.sidebarSelection }, set: { item in
            model.sidebarSelection = item
            Task { await model.sidebarSelected(item) }
        })) {
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
            if !model.stars.isEmpty {
                Section("Starred") {
                    ForEach(model.stars, id: \.self) { path in
                        Label(path.isRoot ? "/" : path.name, systemImage: model.starredIsFolder(path) ? "star" : "star.fill")
                            .help(path.display)
                            .tag(SidebarItem.star(path))
                            // A double-click opens the item the way the browser would: Live or view for a
                            // file, after revealing it, and its listing for a folder.
                            .onTapGesture(count: 2) { Task { await model.openStarred(path) } }
                            .contextMenu {
                                Button("Open") { Task { await model.openStarred(path) } }
                                Button("Remove from Starred") { Task { await model.setStarred([path], false) } }
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
                            Image(systemName: live.status.symbolName)
                        }
                        .help(live.sidebarHelp)
                        .accessibilityValue(live.label)
                        .tag(SidebarItem.live(live.path))
                        .contextMenu {
                            if live.paused {
                                Button("Resume Syncing") { Task { await model.resumeLive(live.path) } }
                            }
                            Button(TransferModel.stopLiveTitle([live])) { Task { await model.stopLive([live.id]) } }
                            Button("Forget Synced Live Files") { Task { await model.forgetSyncedLive() } }
                                .disabled(!model.liveFiles.contains(where: \.isSynced))
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
}

/// The content column: browser, rename bar, shelf, and every sheet. The icon grid, clipboard bar,
/// and shelf are views of their own, so a progress tick or a clip's count redraws only its bar
/// and never re-diffs the grid.
struct DetailColumn: View {
    @Bindable var model: TransferModel
    @Environment(\.detailSlots) private var slots

    var body: some View {
        VStack(spacing: 0) {
            if let status = model.status { MessageBar(text: status) { model.status = nil } }
            if model.renaming { RenameBar(model: model) }
            browser.slot("browser", slots, in: DetailSlots.space)
            // Finder's order at the foot: the path bar under the browser, then the window's bars.
            if model.snapshot.connectionID != nil, model.showsPathBar { PathBar(model: model).slot("pathBar", slots, in: DetailSlots.space) }
            if model.snapshot.connectionID != nil { ClipSlot().slot("clipBar", slots, in: DetailSlots.space) }
            if model.showsShelf { Shelf(model: model).slot("shelf", slots, in: DetailSlots.space) }
        }
        .coordinateSpace(.named(DetailSlots.space))
        // A question that replaces another in the same sheet starts with fresh fields.
        .sheet(item: $model.sheet) { sheet in sheetView(sheet).id(sheet.id) }
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
            case .icon: IconGrid(model: model)
            case .list: ListTable(model: model)
            case .columns: ColumnBrowser(model: model)
            }
        }
    }

    // MARK: Sheets

    @ViewBuilder private func sheetView(_ sheet: AppSheet) -> some View {
        switch sheet {
        case .connection:
            ConnectionForm(model: model)
        case .prompt(let request, let server, _):
            PasswordSheet(request: request, server: server) { model.prompts.finish(.login($0)) }
        case .hostKey(let event, let server, _):
            SheetForm(
                title: event.situation == .changed ? "The host key changed" : "First time connecting to this server",
                detail: event.situation == .changed
                    ? "The server now presents a different key. Someone could be intercepting the connection."
                    : "Check this fingerprint against one you got from the server's owner.",
                width: 520,
                onCancel: { model.prompts.finish(.hostKey(.cancel)) }
            ) {
                LabeledContent("Server", value: hostKeyServer(server, event))
                LabeledContent("Key type", value: event.keyType)
                // A SHA-256 fingerprint is always 43 characters of base64: one line at this size.
                LabeledContent("Fingerprint", value: event.fingerprint)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .textSelection(.enabled)
            } actions: {
                if event.situation == .firstSeen {
                    Button("Trust Once") { model.prompts.finish(.hostKey(.trustOnce)) }
                    Button("Always Trust") { model.prompts.finish(.hostKey(.alwaysTrust)) }
                } else {
                    Button("Replace Trusted Key") { model.prompts.finish(.hostKey(.replace)) }
                }
            }
        case .delete:
            // What this sheet warns about is all the delete may discard.
            let unsynced = model.unsyncedInSelection
            SheetForm(title: deleteTitle, detail: "The delete is permanent. There is no trash on the server.", onCancel: { model.sheet = nil }) {
                if !unsynced.isEmpty {
                    Text("\(unsynced.count) Live file\(unsynced.count == 1 ? " has" : "s have") unsynced edits that will be discarded.")
                        .foregroundStyle(.red)
                }
            } actions: {
                Button("Delete") {
                    model.sheet = nil
                    Task { await model.deleteSelection(warned: unsynced) }
                }
            }
        case .collision(let name, _):
            CollisionSheet(name: name) { model.prompts.finish(.collision($0, toAll: $1)) }
        case .conflict(let path, let comparable):
            conflictSheet(path, comparable: comparable)
        case .goToFolder:
            SheetForm(title: "Go to Remote Folder", width: 420, cancelKey: .cancelAction, onCancel: { model.sheet = nil }) {
                TextField("Remote path", text: $model.folderText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { goToFolder() }
            } actions: {
                Button("Go") { goToFolder() }.keyboardShortcut(.defaultAction)
            }
        case .removeServer(let connection):
            SheetForm(title: "Remove “\(connection.displayName)”?", detail: "Only the saved connection is removed. Nothing on the server changes.", onCancel: { model.sheet = nil }) {
                EmptyView()
            } actions: {
                Button("Remove") { Task { await model.removeServer(connection) } }
            }
        case .stopLive(let batch, let unsynced):
            // Cancel is the default button: stopping discards these edits for good.
            SheetForm(title: "Stop Live editing?", detail: StopLiveSheet.detail(unsynced.count), width: 440, onCancel: { model.sheet = nil }) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(unsynced.prefix(StopLiveSheet.namesShown)) { file in
                        Text("“\(file.file.path.name)” on \(file.server)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(file.file.path.display)
                    }
                    if unsynced.count > StopLiveSheet.namesShown {
                        Text("and \(unsynced.count - StopLiveSheet.namesShown) more").foregroundStyle(.secondary)
                    }
                }
            } actions: {
                Button("Stop and Discard Edits") {
                    model.sheet = nil
                    Task { await model.stopLive(batch, warned: Set(unsynced.map(\.id))) }
                }
            }
        }
    }

    /// The server's name, and the host its key line names when that says more.
    private func hostKeyServer(_ server: String?, _ event: HostKeyEvent) -> String {
        let host = HostKeyLine(line: event.line)?.host
        guard let server else { return host ?? "Unknown" }
        guard let host, host != server else { return server }
        return "\(server) (\(host))"
    }

    /// "Delete “notes.txt”?" for one item, "Delete 3 items?" for more, so the sheet says what
    /// goes, including a folder selected in column view.
    private var deleteTitle: String {
        let selection = model.snapshot.selection
        if selection.count == 1, let path = selection.first { return "Delete “\(path.name)”?" }
        return "Delete \(selection.count) items?"
    }

    private func conflictSheet(_ path: RemotePath, comparable: Bool) -> some View {
        let later = { model.putOffConflict() }
        return SheetForm(title: "“\(path.name)” changed on the server", detail: "Neither version has been overwritten.", width: 520,
                         cancel: "Later", cancelKey: .cancelAction, onCancel: later) {
            if let confirm = model.conflictConfirm {
                Text(confirm == .keepLocal
                     ? "Keep Local overwrites the server copy with this Mac's edits. Press again to confirm."
                     : "Keep Remote replaces this Mac's edits with the server copy. Press again to confirm.")
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Compare") { Task { await model.chooseConflict(.compare) } }
                    .disabled(!comparable)
                Spacer()
                Button(model.conflictConfirm == .keepLocal ? "Confirm Keep Local" : "Keep Local") {
                    Task { await model.chooseConflict(.keepLocal) }
                }
                Button(model.conflictConfirm == .keepRemote ? "Confirm Keep Remote" : "Keep Remote") {
                    Task { await model.chooseConflict(.keepRemote) }
                }
                Button("Keep Both") { Task { await model.chooseConflict(.keepBoth) } }
            }
        } actions: {}
    }

    private func goToFolder() {
        let text = model.folderText
        model.sheet = nil
        Task { await model.goToFolder(text) }
    }
}

/// A login question. What is typed lives in this sheet alone, so nothing typed for one server can
/// fill in the next sheet, which may be another server's.
private struct PasswordSheet: View {
    let request: PromptRequest
    let server: String?
    let finish: (PromptReply) -> Void
    @State private var secret = ""
    @State private var save = false

    var body: some View {
        // Keychain saving applies only where the sheet offered it: a later question in the same
        // login, such as a one-time code, never replaces the saved password.
        let reply = { finish(PromptReply(text: secret, saveInKeychain: save && request.offerKeychain)) }
        SheetForm(title: server ?? "Log In", width: 380, cancelKey: .cancelAction, onCancel: { finish(PromptReply(text: nil)) }) {
            Text(request.text)
                .lineLimit(8)
                .textSelection(.enabled)
            SecureField("Password", text: $secret)
                .textFieldStyle(.roundedBorder)
                .onSubmit(reply)
            if request.offerKeychain {
                Toggle("Save in Keychain", isOn: $save)
            }
        } actions: {
            Button("Continue", action: reply)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// A name already taken. Apply to All starts off for each question and holds for its operation.
private struct CollisionSheet: View {
    let name: String
    let finish: (NameCollisionChoice, Bool) -> Void
    @State private var toAll = false

    var body: some View {
        SheetForm(title: "“\(name)” already exists", detail: "Keep Both keeps both, naming the new one with the next free number.",
                  cancel: "Skip", onCancel: { finish(.skip, toAll) }) {
            Toggle("Apply to all in this operation", isOn: $toAll)
        } actions: {
            Button("Keep Both") { finish(.keepBoth, toAll) }
            Button("Replace") { finish(.replace, toAll) }
        }
    }
}

/// The icon view. Each cell is an AppKit view the size of its whole highlight, and under the grid,
/// as tall as the pane at least, lies an AppKit view for the empty area; both take their own
/// clicks, menus, and drops, so every drop goes through `dropAction` as in the other views.
private struct IconGrid: View {
    let model: TransferModel

    var body: some View {
        GeometryReader { pane in
            ScrollView {
                // Fixed-width columns packed left, not stretched: as the pane narrows, items hold
                // still and only the column count steps, as in Finder's icon view.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 108), spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach(model.displayedItems) { item in
                        FilePromiseLabel(item: item, mark: model.liveMark(for: item.path), model: model)
                            .frame(width: IconItemView.size.width, height: IconItemView.size.height)
                            .background(model.snapshot.selection.contains(item.path) ? Color.accentColor.opacity(0.2) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, minHeight: pane.size.height, alignment: .topLeading)
                .background(IconGridBackground(model: model))
            }
        }
    }
}

/// The transfers, in a list that grows to about five rows and then scrolls, so a large drop never
/// pushes the browser out of the window.
private struct Shelf: View {
    let model: TransferModel
    @Environment(\.detailSlots) private var slots
    /// The rows at their natural height, which the scroll view grows to before scrolling.
    @State private var height: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.operations.count > 1 {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.operations) { operation in row(operation).slot("shelfRow \(operation.id)", slots, in: DetailSlots.space) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .frame(height: min(height, 160))
        }
        .padding(8)
        .background(.bar)
    }

    private func row(_ operation: TransferOperation) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.title).lineLimit(1).truncationMode(.middle)
                if let detail = detail(operation) {
                    Text(detail).font(.caption).foregroundStyle(operation.state == .failed && !model.isKept(operation) ? .red : .secondary).lineLimit(2)
                }
            }
            Spacer()
            if operation.state == .active, operation.livePath == nil {
                RateText(model: model, operation: operation).slot("shelfRate \(operation.id)", slots, in: DetailSlots.space)
            }
            if operation.state == .active || operation.state == .paused {
                if let total = operation.progress.total, total > 0 {
                    ProgressView(value: Double(operation.progress.completed), total: Double(total))
                        .frame(width: 140)
                        .accessibilityLabel(operation.title)
                } else {
                    Text(progressText(operation.progress)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let label = model.stateLabel(operation) {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            // A Live file's sync pauses and resumes. A transfer can only stop: it restarts from its
            // first byte, since a stopped transfer's temp is removed.
            let live = operation.livePath != nil
            switch operation.state {
            case .active, .queued:
                Button(live ? "Pause" : "Stop") { Task { await model.pause(operation) } }
                if operation.state == .queued, !live { Button("Remove") { model.remove(operation) } }
            case .paused:
                Button(live ? "Resume" : "Restart") { Task { await model.resume(operation) } }
                if !live { Button("Remove") { model.remove(operation) } }
            case .failed:
                Button("Retry") { Task { await model.resume(operation) } }
                Button("Remove") { model.remove(operation) }
            case .succeeded:
                EmptyView()
            }
        }
        .controlSize(.small)
    }

    /// "12 transfers, 3 failed".
    private var summary: String {
        let failed = model.operations.filter { $0.state == .failed && !model.isKept($0) }.count
        let count = ClipText.count(model.operations.count, "transfer")
        return failed == 0 ? count : "\(count), \(failed) failed"
    }

    /// The row's message, and the server it runs on when that is not the window's.
    private func detail(_ operation: TransferOperation) -> String? {
        var parts: [String] = []
        if let message = operation.message, operation.state != .active { parts.append(message) }
        if let server = model.otherServerName(for: operation) { parts.append("on \(server)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func progressText(_ progress: TransferProgress) -> String {
        var parts: [String] = []
        if progress.completed > 0 { parts.append(Format.si(progress.completed).trimmingCharacters(in: .whitespaces)) }
        if progress.itemsCompleted > 0 { parts.append(ClipText.count(progress.itemsCompleted, "item")) }
        return parts.joined(separator: ", ")
    }
}

/// A running transfer's speed and time left beside its progress bar, in a slot as wide as the
/// widest it can read (less in a window too narrow for that) and one caption line tall, shorter
/// than the row's title, so the row neither moves nor grows as the numbers change. It reads the
/// rate every second as well as on each report, since a stalled transfer reports nothing.
private struct RateText: View {
    let model: TransferModel
    let operation: TransferOperation

    var body: some View {
        ZStack(alignment: .trailing) {
            ForEach(TransferRate.widestTexts, id: \.self) { Text($0).hidden() }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let text = model.rateText(for: operation) { Text(Format.figures(text)) }
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// The clipboard bar while there is a clip. Its own view, since staging updates the clip often.
private struct ClipSlot: View {
    @Environment(\.shownClip) private var shownClip

    var body: some View {
        if let clip = shownClip ?? Clipboard.shared.clip { ClipBar(clip: clip) }
    }
}

/// The frame the small sheets share: a headline, an optional line under it, the content, and a
/// row of buttons: first `cancel`, which Escape presses too, then `actions` at the far end.
private struct SheetForm<Content: View, Actions: View>: View {
    let title: String
    var detail: String?
    var width: CGFloat = 400
    var cancel: LocalizedStringKey = "Cancel"
    var cancelKey: KeyboardShortcut = .defaultAction
    let onCancel: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if let detail { Text(detail).foregroundStyle(.secondary) }
            content
            HStack {
                Button(cancel, action: onCancel).keyboardShortcut(cancelKey)
                Spacer()
                actions
            }
        }
        .padding()
        .frame(width: width)
        .onExitCommand(perform: onCancel)
    }
}

/// The inspector: one header line at the top, then the preview filling the rest of the panel down
/// to its foot, the same for every selection, so nothing moves as the selection does. The area
/// shows the file once a copy has arrived, else its icon: while it loads, when it cannot be shown,
/// and for a folder; several items show as a list. A missing fact reads "—".
struct InspectorColumn: View {
    let model: TransferModel
    @AppStorage(Preferences.wrapsPreview) private var wrapsPreview = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.inspectorSlots) private var slots
    @Environment(\.displayScale) private var displayScale
    /// The model's phase, the one coming in.
    @State private var shown = PreviewPhase()
    /// What the area draws. It follows `shown` at once, with each change's own animation, except
    /// that incoming text waits for its page (`pageShown`): a web view is empty until it loads.
    @State private var onScreen = PreviewPhase()
    /// That wait, which puts the icon up when the old preview's time (`PreviewTiming.icon`) is up
    /// at `waitEnd`.
    @State private var pageWait: Task<Void, Never>?
    @State private var waitEnd: ContinuousClock.Instant?

    static let iconSize: CGFloat = 128
    static let pictureMargin: CGFloat = 8
    /// The one header line: icon, name, details, and the state symbols.
    nonisolated static let headerHeight: CGFloat = 20
    static let headerGap: CGFloat = 10
    /// The strip at the foot that holds Wrap lines for text; kept for every selection, so the
    /// preview area ends in the same place whether or not the toggle shows.
    static let footHeight: CGFloat = 20
    static let footGap: CGFloat = 8
    static let bottomMargin: CGFloat = 12

    // MARK: Inspector

    var body: some View {
        let facts = InspectorFacts(model: model)
        let phase = PreviewPhase(preview: model.inspectorPreview, wait: model.inspectorWait)
        // A plain stack, not a scroll view: hosted scroll views reach up under the toolbar.
        return VStack(alignment: .leading, spacing: 0) {
            header(facts)
            area(facts).padding(.top, Self.headerGap)
            foot(facts).padding(.top, Self.footGap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, Self.bottomMargin)
        .coordinateSpace(.named(InspectorSlots.space))
        .onChange(of: phase, initial: true) { _, new in arrive(new) }
    }

    /// A new phase from the model. Text arriving over anything but text loads hidden while what
    /// is on screen, a preview of another kind, the icon, or nothing, stays; the page then takes
    /// its place in one step, or, if it is still loading when the old preview's time is up, the
    /// icon does until it lands. Everything else goes on screen at once.
    private func arrive(_ new: PreviewPhase) {
        pageWait?.cancel()
        pageWait = nil
        guard case .text = new.preview, !onScreen.isText else {
            waitEnd = nil
            withAnimation(animation(from: onScreen, to: new)) {
                shown = new
                put(new)
            }
            return
        }
        shown = new
        // A wait already running keeps its end: what is on screen went stale when it began.
        let due = model.inspectorMovedAt + PreviewTiming.icon
        let end = waitEnd.map { min($0, due) } ?? due
        waitEnd = end
        let clock = model.previewClock
        pageWait = Task { @MainActor in
            try? await clock.sleep(end)
            guard !Task.isCancelled, !onScreen.isText else { return }
            let icon = PreviewPhase(preview: nil, wait: .icon)
            withAnimation(animation(from: onScreen, to: icon)) { put(icon) }
        }
    }

    /// The hidden web view has loaded `text`: if it is still the one coming in, it goes on
    /// screen in one step.
    private func pageShown(_ text: String) {
        guard case .text(text)? = shown.preview, !onScreen.isText else { return }
        pageWait?.cancel()
        pageWait = nil
        waitEnd = nil
        put(shown)
    }

    private func put(_ phase: PreviewPhase) {
        guard phase != onScreen else { return }
        onScreen = phase
        slots?.screens.append(phase.label)
    }

    /// The preview area, everything between the facts and the foot: one file's preview once it is
    /// here, else an icon centered in it. Only the wait for one file leaves it empty, until
    /// `PreviewTiming.icon`. The content keeps its identity while the kind of preview does, so
    /// moving from one text file to the next reuses the web view, and Quick Look and pictures
    /// change in place, instead of building a view that draws blank until it loads. Incoming text
    /// loads under what is on screen, transparent, until its page is in.
    private func area(_ facts: InspectorFacts) -> some View {
        let document = facts.file != nil && onScreen.isText || facts.several != nil
        return ZStack {
            // Text and the list of several items draw on the document background, as a page
            // does; everything else on the panel's quiet gray.
            RoundedRectangle(cornerRadius: 8)
                .fill(document ? AnyShapeStyle(Color(nsColor: .textBackgroundColor)) : AnyShapeStyle(.quinary))
            if let several = facts.several {
                SelectionList(rows: several)
            }
            if facts.file != nil, case .text(let text)? = shown.preview {
                SourcePreview(text: text, wraps: wrapsPreview, shown: pageShown)
                    .opacity(onScreen.isText ? 1 : 0)
                    .allowsHitTesting(onScreen.isText)
                    .transition(.opacity)
            }
            if !onScreen.isText {
                if facts.file != nil, let preview = onScreen.preview {
                    content(preview).transition(.opacity)
                } else if facts.several == nil, facts.file == nil || onScreen.wait != .nothing {
                    Image(nsImage: facts.icon)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: Self.iconSize, maxHeight: Self.iconSize)
                        .padding(16)
                        .accessibilityLabel(facts.kind)
                        .transition(.opacity)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if facts.file != nil, onScreen.preview == nil, onScreen.wait == .spinner {
                ProgressView().controlSize(.small).accessibilityLabel("Loading preview").padding(.bottom, 16).transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            if document {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1 / displayScale)
                    .allowsHitTesting(false)
            }
        }
        .slot("preview", slots)
        .onChange(of: document, initial: true) { _, document in slots?.surface = document ? "document" : "gray" }
        // A picture is drawn at the size it shows: the area less its margin (`content`).
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            model.inspectorPictureBox = PictureBox(size: CGSize(width: size.width - 2 * Self.pictureMargin, height: size.height - 2 * Self.pictureMargin), scale: displayScale)
        }
    }

    /// Wrap lines, for text only, in a strip that is there for everything.
    private func foot(_ facts: InspectorFacts) -> some View {
        ZStack(alignment: .trailing) {
            if facts.file != nil, onScreen.isText {
                Toggle("Wrap lines", isOn: $wrapsPreview)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: Self.footHeight)
        .slot("foot", slots)
    }

    /// No animation for one preview replacing another (it reads as instant) or content landing in
    /// an empty area. Old content fades out, the icon and spinner fade in, and a picture over the icon
    /// crossfades. Web and Quick Look views draw late, so fading them shows an empty area.
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

    /// A picture scales to fit and centers in the area; Quick Look fills it and scrolls inside it.
    /// Text has its own layer in `area`.
    @ViewBuilder private func content(_ preview: InspectorPreview) -> some View {
        switch preview {
        case .picture(let picture):
            Image(decorative: picture, scale: 1).resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(Self.pictureMargin)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .file(let url):
            QuickLookPreview(url: url)
        case .text:
            EmptyView()
        }
    }

    /// The one header line. One item: its small icon, the name in bold, then size, date, time,
    /// and permissions, which give way from the right when the panel is narrow (the size never
    /// does), and a symbol at the end for a link, a Live file, or a transfer. Several: their
    /// count on the left and their total at the right. The rest goes in the tooltip. Actions live
    /// in the context menu and on double-click, as in the browser.
    @ViewBuilder private func header(_ facts: InspectorFacts) -> some View {
        if let item = facts.file, let operation = model.operation(for: item.path) {
            // Again every second, as on the shelf, so a stall shows without a report.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                headerLine(facts, transfer: model.inspectorStatus(operation))
            }
        } else {
            headerLine(facts, transfer: nil)
        }
    }

    private func headerLine(_ facts: InspectorFacts, transfer: String?) -> some View {
        let live = facts.file.flatMap { model.liveFile(for: $0.path) }
        let link = facts.file?.kind == .symlink ? (model.inspectorLinkTarget ?? "…") : nil
        let tooltip = facts.tooltip(link: link, live: live?.label, transfer: transfer)
        return HeaderLine(trailing: facts.several != nil) {
            if facts.several == nil {
                Image(nsImage: facts.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(facts.kind)
                    .layoutValue(key: HeaderRole.self, value: .icon)
            }
            Text(facts.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(facts.several == nil ? .middle : .tail)
                .slot("nameText", slots)
                .layoutValue(key: HeaderRole.self, value: .name)
            details(facts)
                .layoutValue(key: HeaderRole.self, value: .details)
            HStack(spacing: 4) {
                if link != nil {
                    Image(systemName: "arrow.turn.up.right").accessibilityLabel("Alias")
                }
                if let live {
                    // Live stops the file; Conflict opens its sheet.
                    Button { Task { await model.liveCapsuleClicked(live) } } label: {
                        LiveCapsule(text: LiveCapsule.title(conflict: live.conflict))
                    }
                    .buttonStyle(.plain)
                    .help(live.conflict ? "Resolve the conflict" : "Stop editing Live")
                    .accessibilityLabel(live.conflict ? "Resolve Conflict" : "Stop Live Editing")
                    .accessibilityValue(live.label)
                    .slot("live capsule", slots)
                }
                if transfer != nil {
                    Image(systemName: "arrow.up.arrow.down").accessibilityLabel("Transferring")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .slot("symbols", slots)
            .layoutValue(key: HeaderRole.self, value: .symbols)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.headerHeight)
        .contentShape(Rectangle())
        .help(tooltip)
        .slot("header", slots)
    }

    /// One item's details, as many as fit, or several items' total, exact bytes first to go.
    @ViewBuilder private func details(_ facts: InspectorFacts) -> some View {
        if facts.several != nil {
            ViewThatFits(in: .horizontal) {
                detailLine([("total", facts.total.map(Format.sized) ?? InspectorFacts.missing)])
                detailLine([("compact total", facts.total.map(Units.bytes) ?? InspectorFacts.missing)])
            }
        } else {
            let parts = [("size", facts.size), ("day", facts.day), ("time", facts.time), ("permissions", facts.permissions)]
            ViewThatFits(in: .horizontal) {
                detailLine(parts)
                detailLine(Array(parts.prefix(3)))
                detailLine(Array(parts.prefix(2)))
                detailLine(Array(parts.prefix(1)))
            }
        }
    }

    private func detailLine(_ parts: [(key: String, text: String)]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Text((index == 0 ? "" : " · ") + Format.figures(part.text))
                    .slot("detail \(part.key)", slots)
            }
        }
        .font(.subheadline)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }
}

/// What each part of the inspector's header line is, for `HeaderLine`.
enum HeaderRole: LayoutValueKey {
    case icon, name, details, symbols, none
    static let defaultValue = HeaderRole.none
}

/// The inspector's header: one line, never wrapping. The icon leads and the symbols end it; the
/// name takes its own width, but no more than leaves the details their room once it has
/// `nameFloor`; the details (a `ViewThatFits`, so as many as fit the room they are offered)
/// follow the name, or, for several items, sit at the right edge.
struct HeaderLine: Layout {
    var trailing = false
    var spacing: CGFloat = 6
    static let nameFloor: CGFloat = 96

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 320, height: proposal.height ?? InspectorColumn.headerHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        func part(_ role: HeaderRole) -> LayoutSubview? { subviews.first { $0[HeaderRole.self] == role } }
        var left = bounds.minX, right = bounds.maxX
        if let icon = part(.icon) {
            let size = icon.sizeThatFits(.unspecified)
            icon.place(at: CGPoint(x: left, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
            left += size.width + spacing
        }
        if let symbols = part(.symbols) {
            let size = symbols.sizeThatFits(.unspecified)
            symbols.place(at: CGPoint(x: right, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(size))
            if size.width > 0 { right -= size.width + spacing }
        }
        let room = max(0, right - left)
        let name = part(.name), details = part(.details)
        let nameIdeal = name?.sizeThatFits(.unspecified).width ?? 0
        let offered = max(0, room - min(nameIdeal, Self.nameFloor) - spacing)
        let detailWidth = min(details?.sizeThatFits(ProposedViewSize(width: offered, height: bounds.height)).width ?? 0, room)
        let nameWidth = max(0, min(nameIdeal, room - detailWidth - spacing))
        name?.place(at: CGPoint(x: left, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: nameWidth, height: bounds.height))
        let detailX = trailing ? right - detailWidth : left + nameWidth + spacing
        details?.place(at: CGPoint(x: detailX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: offered, height: bounds.height))
    }
}

/// Several selected items, one read-only row each in the browser's order: name, size, permissions,
/// owner and group, date, and time (to the minute). Sizes and dates are monospaced digits, right-aligned, so they
/// line up. Columns too wide for the panel give way: time, then owner, then permissions, then the
/// exact size, leaving name, compact size, and date.
struct SelectionList: View {
    let rows: [InspectorFacts.Row]
    @Environment(\.inspectorSlots) private var slots
    @State private var width: CGFloat = 0

    static let spacing: CGFloat = 6
    static let inset: CGFloat = 6
    static let nameFloor: CGFloat = 60
    static let rowHeight: CGFloat = 18
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    enum Column: String, CaseIterable { case exact, permissions, owner, time }

    /// The widest text of each column.
    private struct Widths {
        var exact: CGFloat, compact: CGFloat, permissions: CGFloat, owner: CGFloat, day: CGFloat, time: CGFloat
    }

    private static func width(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
    }

    /// Any compact size: three digits' width, the widest prefix, and the unit.
    private static let compactWidth: CGFloat = ["(888 B)", "(888kB)", "(888MB)", "(888GB)", "(888TB)"].map { width($0) }.max() ?? 0

    /// Digits are all one width here, so for the exact sizes the longest text is the widest; the
    /// other columns hold few distinct texts, each measured.
    private func measure() -> Widths {
        func widest(_ texts: some Sequence<String>) -> CGFloat { Set(texts).map { Self.width($0) }.max() ?? 0 }
        let longest = rows.compactMap { $0.size.map(Format.exact) }.max { $0.count < $1.count }
        return Widths(exact: max(longest.map(Self.width) ?? 0, Self.width("Folder") - Self.compactWidth - 4),
                      compact: Self.compactWidth,
                      permissions: widest(rows.lazy.map(\.permissions)),
                      owner: widest(rows.lazy.map(\.owner)),
                      day: widest(rows.lazy.map(\.day)),
                      time: widest(rows.lazy.map(\.time)))
    }

    var body: some View {
        let widths = measure()
        let optional = [widths.exact, widths.permissions, widths.owner, widths.time]
        let kept = ColumnFit.kept(optional.map(Double.init), required: [widths.compact, widths.day].map(Double.init),
                                  spacing: Self.spacing, floor: Self.nameFloor, in: Double(width - 2 * Self.inset))
        let shown = Set(Column.allCases.prefix(kept))
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    line(row, index: index, widths: widths, shown: shown)
                }
            }
            .padding(.horizontal, Self.inset)
            .padding(.vertical, 6)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func line(_ row: InspectorFacts.Row, index: Int, widths: Widths, shown: Set<Column>) -> some View {
        HStack(spacing: Self.spacing) {
            Text(row.name)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .help(row.name)
                .slot("row \(index) name", slots)
            Group {
                if let size = row.size {
                    HStack(spacing: 4) {
                        if shown.contains(.exact) {
                            Text(Format.exact(size)).frame(width: widths.exact, alignment: .trailing)
                        }
                        Text("(\(Format.figures(Units.bytes(size))))").frame(width: widths.compact, alignment: .trailing)
                    }
                } else {
                    Text(row.folder ? "Folder" : InspectorFacts.missing)
                        .frame(width: (shown.contains(.exact) ? widths.exact + 4 : 0) + widths.compact, alignment: .trailing)
                }
            }
            .slot("row \(index) size", slots)
            if shown.contains(.permissions) {
                Text(row.permissions).frame(width: widths.permissions, alignment: .leading).slot("row \(index) permissions", slots)
            }
            if shown.contains(.owner) {
                Text(row.owner).lineLimit(1).frame(width: widths.owner, alignment: .leading).slot("row \(index) owner", slots)
            }
            Text(row.day).frame(width: widths.day, alignment: .leading).slot("row \(index) day", slots)
            if shown.contains(.time) {
                Text(row.time).frame(width: widths.time, alignment: .trailing).slot("row \(index) time", slots)
            }
        }
        .font(Font(Self.font))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(height: Self.rowHeight)
    }
}

/// What the inspector says about the selection: one item, several, or the location when nothing
/// is selected. A fact that is not known reads "—".
struct InspectorFacts {
    static let missing = "—"

    var name: String
    /// The kind's name, for the tooltip and the icon's label.
    var kind: String
    /// The compact size, a folder's item count, or "—".
    var size: String
    var day: String
    var time: String
    var permissions: String
    /// `owner:group`, for the tooltip; nil when unknown.
    var owner: String?
    var icon: NSImage
    /// The one file or link selected, whose preview may fill the area; nil for anything else.
    var file: RemoteItem?
    /// One row per item when several are selected, in the browser's order.
    var several: [Row]?
    /// Several items' files' bytes; nil when a file's size is unknown or there are no files.
    var total: UInt64?
    /// The exact bytes of one file, for the tooltip.
    var bytes: UInt64?

    /// One item of several, as the inspector's list shows it.
    struct Row: Equatable {
        var name: String
        /// Bytes for a file; nil for a folder and for what has no size.
        var size: UInt64?
        var folder: Bool
        var permissions: String
        var owner: String
        var day: String
        var time: String
    }

    @MainActor init(model: TransferModel) {
        let selected = model.selectedItems
        if selected.count > 1 {
            let folders = selected.count(where: { $0.kind == .directory })
            let files = selected.filter { $0.kind == .file }
            let sizes = files.compactMap(\.size)
            name = "\(selected.count) items selected" + (folders > 0 ? " · \(ClipText.count(folders, "folder"))" : "")
            kind = Self.missing
            size = Self.missing
            day = Self.missing
            time = Self.missing
            permissions = Self.missing
            total = files.isEmpty || sizes.count < files.count ? nil : sizes.reduce(0, +)
            several = selected.map { item in
                Row(name: item.name, size: item.kind == .file ? item.size : nil, folder: item.kind == .directory,
                    permissions: item.mode.map(Self.permissions) ?? Self.missing,
                    owner: Self.owner(item) ?? Self.missing,
                    day: item.mtime.map(Format.day) ?? Self.missing,
                    time: item.mtime.map(Format.shortClock) ?? Self.missing)
            }
            icon = NSImage(named: NSImage.multipleDocumentsName) ?? NSImage()
            return
        }
        let item: RemoteItem
        if let one = selected.first {
            item = one
        } else if model.snapshot.connectionID != nil {
            item = model.locationItem ?? RemoteItem(path: model.snapshot.path, kind: .directory)
        } else {
            name = "No Server"
            kind = Self.missing
            size = Self.missing
            day = Self.missing
            time = Self.missing
            permissions = Self.missing
            icon = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil) ?? NSImage()
            return
        }
        name = item.path.isRoot ? "/" : item.name
        kind = item.kindLabel
        size = switch item.kind {
        case .directory: model.itemCount(of: item.path).map { ClipText.count($0, "item") } ?? Self.missing
        case .file: item.size.map(Units.bytes) ?? Self.missing
        case .symlink, .other: Self.missing
        }
        bytes = item.kind == .file ? item.size : nil
        day = item.mtime.map(Format.day) ?? Self.missing
        time = item.mtime.map(Format.clock) ?? Self.missing
        permissions = item.mode.map(Self.permissions) ?? Self.missing
        owner = Self.owner(item)
        icon = ItemIcon.image(for: item)
        file = selected.first.flatMap { $0.kind == .file || $0.kind == .symlink ? $0 : nil }
    }

    /// Everything the header line leaves out or cuts short, one fact a line.
    func tooltip(link: String?, live: String?, transfer: String?) -> String {
        if let several {
            return ([name] + (total.map { ["\(Format.sized($0)) in \(ClipText.count(several.count(where: { $0.size != nil }), "file"))"] } ?? [])).joined(separator: "\n")
        }
        var lines = [name, kind]
        lines.append(bytes.map { "\(Format.exact($0)) bytes (\(Units.bytes($0).trimmingCharacters(in: .whitespaces)))" } ?? size)
        if day != Self.missing { lines.append("Modified \(day) \(time)") }
        if permissions != Self.missing || owner != nil {
            lines.append([permissions == Self.missing ? nil : permissions, owner].compactMap(\.self).joined(separator: " "))
        }
        if let link { lines.append("→ \(link)") }
        if let live { lines.append(live) }
        if let transfer { lines.append(transfer) }
        return lines.joined(separator: "\n")
    }

    static func owner(_ item: RemoteItem) -> String? {
        item.owner.map { owner in item.group.map { "\(owner):\($0)" } ?? owner }
    }

    static func permissions(_ mode: UInt32) -> String {
        let bits = mode & 0o777
        let letters = ["---", "--x", "-w-", "-wx", "r--", "r-x", "rw-", "rwx"]
        return letters[Int(bits >> 6 & 7)] + letters[Int(bits >> 3 & 7)] + letters[Int(bits & 7)]
    }
}

/// Where each part of the inspector landed, in its own coordinates, for the tests that hold the
/// preview area and every row still across selections. Nil, as in the app, records nothing.
@MainActor
final class InspectorSlots {
    nonisolated static let space = "inspector"
    var frames: [String: CGRect] = [:]
    /// What the preview area is drawn on: "document" or "gray".
    var surface: String?
    /// Each phase the preview area put on screen, in order (`PreviewPhase.label`).
    var screens: [String] = []
}

/// The same for the detail column's browser and the bars at its foot, which must never overlap.
enum DetailSlots {
    nonisolated static let space = "detail"
}

extension EnvironmentValues {
    @Entry var inspectorSlots: InspectorSlots?
    @Entry var detailSlots: InspectorSlots?
    /// The same for the toolbar's Live list (`LiveFilesList.space`).
    @Entry var liveListSlots: InspectorSlots?
    /// A clip for the clipboard bar to show instead of the clipboard's, so the tests that measure
    /// the bars never write the Mac's pasteboard. Nil, as in the app, shows the clipboard's.
    @Entry var shownClip: Clipboard.Clip?
}

extension View {
    func slot(_ key: String, _ slots: InspectorSlots?, in space: String = InspectorSlots.space) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { slots?.frames[key] = $0 }
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
            closeButton(help: "Clear the clipboard (Escape)", label: "Clear Clipboard") { Clipboard.shared.clear() }
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

/// The window's message, such as a failure, until dismissed or replaced by the next one.
private struct MessageBar: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            closeButton(help: "Dismiss", label: "Dismiss", action: dismiss)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The close button at the end of a bar.
@MainActor
private func closeButton(help: LocalizedStringKey, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: "xmark.circle.fill") }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(label)
}

/// The rename field. Focus state has to live inside the hosted detail subtree, so this is its own view.
///
/// With Full Keyboard Access on, SwiftUI gave the bar's focus to the default button, not the
/// field, so typing went nowhere (measured on macOS 27). The buttons take no focus, the field is
/// the bar's default focus, and it is focused once more a turn after the bar appears.
private struct RenameBar: View {
    @Bindable var model: TransferModel
    @FocusState private var focused: Bool
    @State private var stemSelected = false

    var body: some View {
        HStack {
            TextField("Name", text: $model.renameText)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { Task { await model.renameSelection(to: model.renameText) } }
                .onExitCommand { model.renaming = false }
            Button("Rename") { Task { await model.renameSelection(to: model.renameText) } }
                .keyboardShortcut(.defaultAction)
                .focusable(false)
            Button("Cancel") { model.renaming = false }
                .focusable(false)
        }
        .padding(8)
        .defaultFocus($focused, true)
        .onAppear {
            focused = true
            DispatchQueue.main.async { focused = true }
        }
        // Command-F takes the keyboard from this field to the search field, which edits text too.
        .onChange(of: focused) {
            model.textEditing = focused || NSApp.keyWindow?.firstResponder is NSText
            // The field selects all of the name as it takes focus; Finder leaves the extension out.
            guard focused, !stemSelected else { return }
            stemSelected = true
            let (name, stem) = (model.renameText, model.renameStem)
            DispatchQueue.main.async {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.string == name else { return }
                editor.setSelectedRange(NSRange(location: 0, length: stem))
            }
        }
        .onDisappear {
            model.textEditing = false
            // Escape or Return leaves the keyboard with the window itself; it goes back to the
            // list, column, or icon view the rename started from, once the field has let go.
            let model = model
            DispatchQueue.main.async { ChromeController.refocusBrowser(of: model) }
        }
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

    /// A view that does not close with its window must be closed by hand, or each preview the
    /// inspector drops keeps its Quick Look resources.
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

/// Highlighted source in a web view, scrollable, with the pane's own background. The page is
/// built only when the text or wrapping changes, never on every redraw of the pane, and the view
/// keeps showing the previous page until the next one has loaded (`SourcePreviewView`).
struct SourcePreview: NSViewRepresentable {
    let text: String
    let wraps: Bool
    /// Told each time a page is on show, with its text.
    var shown: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> SourcePreviewView {
        let view = SourcePreviewView()
        view.onShow = { shown($0.text) }
        view.show(SourcePage(text: text, wraps: wraps))
        return view
    }

    func updateNSView(_ view: SourcePreviewView, context: Context) {
        view.onShow = { shown($0.text) }
        view.show(SourcePage(text: text, wraps: wraps))
    }
}

/// One page of highlighted source.
struct SourcePage: Equatable {
    var text: String
    var wraps: Bool
}

/// Which of two buffers is on show and which load may replace it. A page loads in the buffer
/// behind, and the two change places only when that load finishes, so the front never shows a
/// page still loading. A newer request supersedes one in flight, whose finish is then ignored.
struct PageSwap<Page: Equatable> {
    /// The buffer on show, 0 or 1.
    private(set) var front = 0
    /// The page in front, once one has loaded.
    private(set) var shown: Page?
    /// The page loading behind it, and that load's number.
    private(set) var pending: Page?
    private(set) var pendingLoad: Int?
    private var loads = 0

    /// Where to load `page`, and the load's number; nil when it is on show or already loading.
    /// Asking again for the page on show abandons a load in flight.
    mutating func request(_ page: Page) -> (buffer: Int, load: Int)? {
        if page == pending { return nil }
        if page == shown {
            (pending, pendingLoad) = (nil, nil)
            return nil
        }
        loads &+= 1
        (pending, pendingLoad) = (page, loads)
        return (1 - front, loads)
    }

    /// The load numbered `load` has ended; true when its buffer is now the one in front.
    mutating func finished(_ load: Int) -> Bool {
        guard load == pendingLoad else { return false }
        front = 1 - front
        (shown, pending, pendingLoad) = (pending, nil, nil)
        return true
    }
}

/// Two web views in one place, taking turns (`PageSwap`): the next page loads in the one behind,
/// transparent, and they trade places when its navigation ends, so moving between text files
/// keeps the last page up instead of a web view that is empty until it loads. Only the one in
/// front takes the mouse.
final class SourcePreviewView: NSView, WKNavigationDelegate {
    private(set) var buffers: [WKWebView] = []
    private(set) var swap = PageSwap<SourcePage>()
    private var navigation: (step: WKNavigation, load: Int)?
    /// Told each time a page comes to the front, never from inside `show`.
    var onShow: (SourcePage) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        let configuration = WKWebViewConfiguration()
        // The text is escaped; with scripts off, nothing from the server runs even if some slipped through.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        for _ in 0..<2 {
            let view = WKWebView(frame: bounds, configuration: configuration)
            view.setValue(false, forKey: "drawsBackground")
            view.autoresizingMask = [.width, .height]
            view.navigationDelegate = self
            addSubview(view)
            buffers.append(view)
        }
        showFront()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The web view on show.
    var front: WKWebView { buffers[swap.front] }

    func show(_ page: SourcePage) {
        guard let next = swap.request(page) else {
            if swap.pending == nil { navigation = nil }
            return
        }
        let html = SyntaxPreview.html(text: page.text, compact: true, wraps: page.wraps)
        if let step = buffers[next.buffer].loadHTMLString(html, baseURL: nil) {
            navigation = (step, next.load)
        } else {
            // Never synchronously: `show` runs inside a SwiftUI update.
            DispatchQueue.main.async { [weak self] in self?.finish(next.load) }
        }
    }

    private func finish(_ load: Int) {
        navigation = nil
        guard swap.finished(load) else { return }
        showFront()
        if let page = swap.shown { onShow(page) }
    }

    private func showFront() {
        for (index, view) in buffers.enumerated() { view.alphaValue = index == swap.front ? 1 : 0 }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return front.hitTest(convert(point, from: superview)) ?? self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ended(navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        ended(navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        ended(navigation)
    }

    /// A superseded load's end is ignored. A failed one still swaps, so the last file's page never
    /// stays up under the next file's name.
    private func ended(_ step: WKNavigation?) {
        guard let navigation, navigation.step === step else { return }
        finish(navigation.load)
    }
}

/// What the inspector's box shows: content, or a wait state while none is up.
struct PreviewPhase: Equatable {
    var preview: InspectorPreview?
    var wait: InspectorWait = .nothing

    var isText: Bool {
        if case .text? = preview { true } else { false }
    }

    /// The phase in a word, for `InspectorSlots.screens`.
    var label: String {
        switch preview {
        case .text?: "text"
        case .picture?: "picture"
        case .file?: "quickLook"
        case nil: wait == .nothing ? "empty" : wait == .icon ? "icon" : "spinner"
        }
    }
}
