import AppKit
import SwiftUI
import TransferCore

/// Gives the hosting window a frame autosave name so its frame persists.
struct WindowFrameSaver: NSViewRepresentable {
    var name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setFrameAutosaveName(name)
            window.tabbingMode = .preferred
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct TransferModelKey: FocusedValueKey {
    typealias Value = TransferModel
}

public extension FocusedValues {
    /// The model of the key window, for menu commands.
    var transferModel: TransferModel? {
        get { self[TransferModelKey.self] }
        set { self[TransferModelKey.self] = newValue }
    }
}

public enum QuitGuard {
    /// Asks Cancel (default) or Quit Anyway when Live work is unsynced.
    @MainActor
    public static func mayQuit(unsynced: Int) -> Bool {
        guard unsynced > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = "\(unsynced) Live file\(unsynced == 1 ? " has" : "s have") unsynced edits"
        alert.informativeText = "Uploads run only while Transfer is open. Quitting now leaves those edits on this Mac until the next launch."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
