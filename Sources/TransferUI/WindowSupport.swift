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
    /// Throws when no app opened the file, so the window can say so.
    static func open(_ url: URL) async throws {
        let ext = url.pathExtension
        let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        if let type, NSWorkspace.shared.urlForApplication(toOpen: type) == nil {
            guard let app = chooseApplication(for: ext) else { return }
            // The same thing Finder's "Always Open With" does: the default for this extension.
            try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        guard NSWorkspace.shared.open(url) else {
            throw TransferError.failed("No app could open “\(url.lastPathComponent)”.")
        }
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
