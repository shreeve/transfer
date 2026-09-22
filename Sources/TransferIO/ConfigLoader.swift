import Foundation
import TransferCore

enum ConfigLoader {
    static func load(root: URL) -> TransferConfig {
        let userFile = root.appendingPathComponent("config.json")
        if let config = read(userFile) { return config }
        if let bundled = defaultFile() {
            try? FileManager.default.copyItem(at: bundled, to: userFile)
            if let config = read(userFile) { return config }
            if let config = read(bundled) { return config }
        }
        return .builtIn
    }

    static func save(_ config: TransferConfig, root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: root.appendingPathComponent("config.json"), options: .atomic)
    }

    private static func read(_ url: URL) -> TransferConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TransferConfig.self, from: data)
    }

    private static func defaultFile() -> URL? {
        if let bundled = Bundle.main.url(forResource: "config", withExtension: "json") {
            return bundled
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Support/config.json")
        if FileManager.default.fileExists(atPath: cwd.path) { return cwd }
        return nil
    }
}
