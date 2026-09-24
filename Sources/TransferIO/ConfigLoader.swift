import Foundation
import TransferCore

/// The user's `config.json` under the library root, copied from the bundled default on first use.
enum ConfigLoader {
    static func load(root: URL) -> TransferConfig {
        let userFile = root.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: userFile.path) {
            if let config = read(userFile) { return config }
            // The next Settings save rewrites the file, so the unreadable one is kept aside first.
            let backup = root.appendingPathComponent("config.json.bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: userFile, to: backup)
            NSLog("Transfer: %@ could not be read and was copied to %@; using the default settings", userFile.path, backup.path)
            return defaultFile().flatMap(read) ?? .builtIn
        }
        if let bundled = defaultFile() {
            try? FileManager.default.copyItem(at: bundled, to: userFile)
            if let config = read(userFile) ?? read(bundled) { return config }
        }
        return .builtIn
    }

    static func save(_ config: TransferConfig, root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: root.appendingPathComponent("config.json"), options: .atomic)
    }

    private static func read(_ url: URL) -> TransferConfig? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(TransferConfig.self, from: $0) }
    }

    private static func defaultFile() -> URL? {
        if let bundled = Bundle.main.url(forResource: "config", withExtension: "json") { return bundled }
        #if DEBUG
        // `swift run` and `swift test` have no bundle; the repo's copy stands in.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Support/config.json")
        if FileManager.default.fileExists(atPath: cwd.path) { return cwd }
        #endif
        return nil
    }
}
