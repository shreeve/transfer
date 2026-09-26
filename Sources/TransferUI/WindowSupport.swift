import AppKit
import SwiftUI
import TransferCore
import UniformTypeIdentifiers

public extension FocusedValues {
    /// The model of the key window, for menu commands.
    @Entry var transferModel: TransferModel?
}

/// Opens a downloaded file in its default app. When the extension has no default, asks once and
/// records the choice with Launch Services, so Transfer and Finder both remember it.
@MainActor
enum FileOpener {
    /// Apps that run the file they open rather than show it.
    nonisolated static let runners = Set(TerminalLauncher.apps.map(\.bundle) + ["org.python.PythonLauncher", "com.apple.JavaLauncher"])

    /// The app, by bundle identifier, that opens a server's file in place of `defaultApp`, or nil
    /// to keep it. The user opens a file to read or edit it, so one whose default app would run
    /// it, as Terminal runs a `.command`, opens in the plain-text editor, or TextEdit when that
    /// runs files too.
    nonisolated static func editor(replacing defaultApp: String?, plainText: String?) -> String? {
        guard let defaultApp, runners.contains(defaultApp) else { return nil }
        if let plainText, !runners.contains(plainText) { return plainText }
        return "com.apple.TextEdit"
    }

    /// Throws when no app opened the file, so the window can say so.
    static func open(_ url: URL) async throws {
        let workspace = NSWorkspace.shared
        let ext = url.pathExtension
        let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        var app = workspace.urlForApplication(toOpen: url)
        if let type, workspace.urlForApplication(toOpen: type) == nil {
            guard let chosen = chooseApplication(for: ext) else { return }
            // The same thing Finder's "Always Open With" does: the default for this extension.
            try? await workspace.setDefaultApplication(at: chosen, toOpen: type)
            app = chosen
        }
        func bundle(_ app: URL?) -> String? { app.flatMap { Bundle(url: $0)?.bundleIdentifier } }
        if let editor = editor(replacing: bundle(app), plainText: bundle(workspace.urlForApplication(toOpen: .plainText))) {
            app = workspace.urlForApplication(withBundleIdentifier: editor)
        }
        guard let app else { throw TransferError.failed("No app could open “\(url.lastPathComponent)”.") }
        _ = try await workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func chooseApplication(for ext: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.message = "Choose the application that opens “.\(ext)” files. Transfer and Finder will remember it."
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
