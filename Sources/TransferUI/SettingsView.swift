import SwiftUI
import TransferCore

/// The General tab: global browsing preferences. Open windows follow changes at once.
public struct GeneralSettings: View {
    @AppStorage(Preferences.caseInsensitiveSort) private var caseInsensitive = false
    @AppStorage(Preferences.foldersFirst) private var foldersFirst = true
    @AppStorage(Preferences.showsHidden) private var showsHidden = false
    @AppStorage(Preferences.viewMode) private var viewMode = ViewMode.list.rawValue
    @AppStorage(Preferences.showsAppIcon) private var showsAppIcon = true

    public init() {}

    public var body: some View {
        Form {
            Section("Sorting") {
                Toggle("Sort names case-insensitively", isOn: $caseInsensitive)
                Toggle("Keep folders above files", isOn: $foldersFirst)
            }
            Section("Browsing") {
                Toggle("Show hidden files", isOn: $showsHidden)
                Picker("View", selection: $viewMode) {
                    Text("Icons").tag(ViewMode.icon.rawValue)
                    Text("List").tag(ViewMode.list.rawValue)
                    Text("Columns").tag(ViewMode.columns.rawValue)
                }
            }
            Section("Window") {
                Toggle("Show the Transfer icon in the toolbar", isOn: $showsAppIcon)
            }
        }
        .formStyle(.grouped)
    }
}

/// The Extensions tab: which extensions open Live. Saved to the user's config file through the provider.
public struct ExtensionSettings: View {
    let provider: any SessionProvider
    @State private var text = ""
    @State private var loaded = false
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
                    .onChange(of: text) { if loaded { save() } }
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
            text = await provider.editableExtensions().joined(separator: "\n")
            loaded = true
        }
    }

    private func save() {
        let list = text
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
        Task {
            do {
                try await provider.setEditableExtensions(list)
                message = ""
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
