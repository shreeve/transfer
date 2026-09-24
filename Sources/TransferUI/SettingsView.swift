import SwiftUI
import TransferCore

/// The General tab: global browsing preferences. Open windows follow changes at once.
public struct GeneralSettings: View {
    @AppStorage(Preferences.caseInsensitiveSort) private var caseInsensitive = false
    @AppStorage(Preferences.foldersFirst) private var foldersFirst = true
    @AppStorage(Preferences.showsHidden) private var showsHidden = false
    @AppStorage(Preferences.viewMode) private var viewMode = ViewMode.list.rawValue

    public init() {}

    public var body: some View {
        Form {
            Section("Sorting") {
                Toggle("Sort names case-insensitively", isOn: $caseInsensitive)
                Toggle("Keep folders above files", isOn: $foldersFirst)
            }
            Section("Browsing") {
                Toggle("Show hidden files", isOn: $showsHidden)
                // Chosen here, the view mode changes every open window; chosen in a window, it
                // is only the default for the next one.
                Picker("View", selection: Binding(get: { viewMode }, set: { mode in
                    viewMode = mode
                    NotificationCenter.default.post(name: Preferences.viewModeChosen, object: nil)
                })) {
                    ForEach(ViewMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
            }

        }
        .formStyle(.grouped)
    }
}

/// The Extensions tab: which extensions open Live. Saved to the user's config file through the provider.
public struct ExtensionSettings: View {
    let provider: any SessionProvider
    @State private var text = ""
    /// What the file held when the tab opened, or last saved; only a change from it is saved.
    @State private var saved: String?
    @State private var message = ""

    public init(provider: any SessionProvider) {
        self.provider = provider
    }

    public var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .frame(minHeight: 160)
                    .task(id: text) {
                        // Saved once typing pauses, so keystrokes never race each other to the file.
                        guard let saved, text != saved else { return }
                        try? await Task.sleep(for: .milliseconds(400))
                        if !Task.isCancelled { save() }
                    }
            } header: {
                Text("Editable extensions")
            } footer: {
                Text("One extension per line, or separated by spaces or commas. Files with these extensions open Live, and so does anything whose type is plain text or source code. Everything else opens for viewing.")
                    .foregroundStyle(.secondary)
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .task {
            let loaded = await provider.editableExtensions().joined(separator: "\n")
            saved = loaded
            text = loaded
        }
    }

    private func save() {
        let written = text
        let list = written
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
        Task {
            do {
                try await provider.setEditableExtensions(list)
                saved = written
                message = ""
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
