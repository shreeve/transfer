import Foundation

/// Test library roots live under `~/Library/Caches/TransferTests`. Each test removes its own
/// folder; one left behind by a run that crashed or was killed is removed by a later run once it is
/// an hour old. Younger folders may belong to a suite running now, in this process or another.
enum TestCaches {
    static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TransferTests", isDirectory: true)

    /// A fresh path, `<name>-<8 hex>`, not yet created. The first call in a process sweeps stale siblings.
    static func fresh(_ name: String) -> URL {
        _ = swept
        return folder.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    private static let swept: Void = removeStale(olderThan: 3600)

    static func removeStale(olderThan age: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-age)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names {
            let url = folder.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
            let dates = [attributes[.creationDate], attributes[.modificationDate]].compactMap { $0 as? Date }
            guard let newest = dates.max(), newest < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
