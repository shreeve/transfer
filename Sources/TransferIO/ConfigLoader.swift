import Foundation
import TransferCore

/// The user's `config.json` under the library root, written with the built-in defaults on first use.
enum ConfigLoader {
    static func load(root: URL) -> TransferConfig {
        let userFile = root.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: userFile.path) else {
            try? save(.builtIn, root: root)
            return .builtIn
        }
        if let config = (try? Data(contentsOf: userFile)).flatMap({ try? JSONDecoder().decode(TransferConfig.self, from: $0) }) { return config }
        // The next Settings save rewrites the file, so the unreadable one is kept aside first.
        let backup = root.appendingPathComponent("config.json.bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: userFile, to: backup)
        NSLog("Transfer: %@ could not be read and was copied to %@; using the default settings", userFile.path, backup.path)
        return .builtIn
    }

    /// Gives the user's list each of `entries` it lacks, appended after the user's own, which keep
    /// their order (`TransferConfig.adding`). A library migration calls it once (`Store` schema 4),
    /// so an entry the user removes afterwards stays removed. With no `config.json` there is
    /// nothing to do (the first `load` writes the built-in list, which has them all), and an
    /// unreadable one is left for `load` to keep aside. A failed write is logged, not thrown: the
    /// library still opens with the list as it was.
    static func add(_ entries: [String], root: URL) {
        let userFile = root.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: userFile), let config = try? JSONDecoder().decode(TransferConfig.self, from: data) else { return }
        let added = config.adding(entries)
        guard added != config else { return }
        do { try save(added, root: root) } catch {
            NSLog("Transfer: could not add the new editable extensions to %@: %@", userFile.path, error.localizedDescription)
        }
    }

    static func save(_ config: TransferConfig, root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: root.appendingPathComponent("config.json"), options: .atomic)
    }
}
