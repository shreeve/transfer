import AppKit
import SwiftUI
import TransferCore

struct ColumnBrowser: NSViewRepresentable {
    var model: TransferModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSBrowser {
        let browser = NSBrowser()
        browser.delegate = context.coordinator
        browser.hasHorizontalScroller = true
        browser.autohidesScroller = true
        browser.minColumnWidth = 180
        return browser
    }

    func updateNSView(_ browser: NSBrowser, context: Context) {
        context.coordinator.model = model
        browser.reloadColumn(browser.lastColumn)
    }

    final class Coordinator: NSObject, NSBrowserDelegate {
        var model: TransferModel
        init(model: TransferModel) { self.model = model }

        func rootItem(for browser: NSBrowser) -> Any? {
            let path: RemotePath = MainActor.assumeIsolated { model.snapshot.path }
            return path
        }

        func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
            let path = path(of: item)
            return MainActor.assumeIsolated { children(path).count }
        }

        func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
            let path = path(of: item)
            let child: RemoteItem = MainActor.assumeIsolated { children(path)[index] }
            return child
        }

        func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
            guard let item = item as? RemoteItem else { return false }
            return item.kind != .directory
        }

        func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
            if let item = item as? RemoteItem { return item.name }
            let path = path(of: item)
            let text: String = MainActor.assumeIsolated {
                path.map(\.display) ?? model.snapshot.path.display
            }
            return text
        }

        private func path(of item: Any?) -> RemotePath? {
            if let remote = item as? RemoteItem { return remote.path }
            if let remote = item as? RemotePath { return remote }
            return nil
        }

        @MainActor
        private func children(_ path: RemotePath?) -> [RemoteItem] {
            let path = path ?? model.snapshot.path
            if model.columns[path] == nil, path == model.snapshot.path {
                return model.items
            }
            if model.columns[path] == nil {
                let target = path
                Task { await model.open(RemoteItem(path: target, kind: .directory)) }
            }
            return model.columns[path] ?? []
        }
    }
}
