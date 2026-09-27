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

    static func save(_ config: TransferConfig, root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: root.appendingPathComponent("config.json"), options: .atomic)
    }
}
