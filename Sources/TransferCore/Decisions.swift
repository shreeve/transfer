import Foundation
import UniformTypeIdentifiers

public enum OpenKind: String, Sendable, Codable {
    case live
    case view
}

public struct TransferConfig: Codable, Equatable, Sendable {
    public var editableExtensions: [String]

    public init(editableExtensions: [String]) {
        self.editableExtensions = editableExtensions
    }

    public var extensionSet: Set<String> {
        Set(editableExtensions.map { $0.lowercased() })
    }

    public static let builtIn = TransferConfig(editableExtensions: [
        "rip", "txt", "json", "ts", "rs", "c", "md", "swift", "py",
        "js", "jsx", "tsx", "html", "css", "yaml", "yml", "toml", "sh",
    ])
}

public enum EditableFile {
    public static let extensions = TransferConfig.builtIn.extensionSet

    public static func openKind(fileName: String, extensions: Set<String> = EditableFile.extensions) -> OpenKind {
        let ext = fileName.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        if extensions.contains(ext) { return .live }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .plainText) || type.conforms(to: .sourceCode) {
                return .live
            }
        }
        return .view
    }
}

public enum NameCollisionChoice: String, Sendable, Codable {
    case skip
    case keepBoth
    case replace
}

public enum LiveConflictChoice: String, Sendable, Codable {
    case compare
    case keepLocal
    case keepRemote
    case keepBoth
}

public enum KeepBothName {
    public static func next(existing: Set<String>, original: String) -> String {
        let split = splitExtension(original)
        var n = 2
        while true {
            let candidate = "\(split.base) \(n)\(split.ext)"
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }

    public static func duplicate(existing: Set<String>, original: String) -> String {
        let split = splitExtension(original)
        let first = "\(split.base) copy\(split.ext)"
        if !existing.contains(first) { return first }
        var n = 2
        while true {
            let candidate = "\(split.base) copy \(n)\(split.ext)"
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }

    private static func splitExtension(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return (name, "")
        }
        return (String(name[..<dot]), String(name[dot...]))
    }
}

public enum CopyDisposition: Equatable, Sendable {
    case skip
    case collide
    case typeMismatch
    case write(tempName: String)
}

public enum CopyRules {
    public static func fileDisposition(
        source: RemoteItem,
        destination: RemoteItem?,
        transferID: String,
        liveSave: Bool
    ) -> CopyDisposition {
        let temp = tempName(for: source.name, transferID: transferID)
        guard let destination else { return .write(tempName: temp) }
        if source.kind != destination.kind { return .typeMismatch }
        if source.kind != .file { return .typeMismatch }
        if !liveSave,
           let left = Fingerprint(item: source),
           let right = Fingerprint(item: destination),
           left.size == right.size,
           left.mtime == right.mtime {
            return .skip
        }
        return .collide
    }

    public static func tempName(for basename: String, transferID: String) -> String {
        ".\(basename).transfer-\(transferID)"
    }
}

public struct ProbeResult: Equatable, Sendable {
    public var enabled: Bool
    public var versionLine: String?

    public init(exitCode: Int32, stdout: String) {
        let trimmed = stdout.hasSuffix("\n") ? String(stdout.dropLast()) : stdout
        let oneLine = !trimmed.isEmpty && !trimmed.contains("\n")
        if exitCode == 0 && oneLine {
            enabled = true
            versionLine = trimmed
        } else {
            enabled = false
            versionLine = nil
        }
    }
}

public enum SftpURL {
    public static func string(connection: SavedConnection, path: RemotePath) -> String {
        var host = connection.host
        if !connection.port.isEmpty { host += ":\(connection.port)" }
        let user = connection.user.trimmingCharacters(in: .whitespaces)
        let authority = user.isEmpty ? host : "\(percent(user))@\(host)"
        let encoded = path.display.split(separator: "/", omittingEmptySubsequences: false).map {
            percent(String($0))
        }.joined(separator: "/")
        let suffix = encoded.hasPrefix("/") ? encoded : "/" + encoded
        return "sftp://\(authority)\(suffix)"
    }

    private static func percent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/@:?#[]")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

public enum OperationState: String, Hashable, Sendable, Codable {
    case queued
    case active
    case paused
    case succeeded
    case failed
    case canceled
}

public struct TransferProgress: Hashable, Sendable {
    public var completed: UInt64
    public var total: UInt64?
    public var itemsCompleted: Int
    public var itemsTotal: Int?

    public init(completed: UInt64, total: UInt64? = nil, itemsCompleted: Int = 0, itemsTotal: Int? = nil) {
        self.completed = completed
        self.total = total
        self.itemsCompleted = itemsCompleted
        self.itemsTotal = itemsTotal
    }
}

public enum HostKeySituation: String, Sendable, Codable {
    case unchanged
    case firstSeen
    case changed
}

public struct HostKeyEvent: Hashable, Sendable {
    public var situation: HostKeySituation
    public var keyType: String
    public var fingerprint: String
    public var line: String

    public init(situation: HostKeySituation, keyType: String, fingerprint: String, line: String) {
        self.situation = situation
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.line = line
    }
}

public enum HostKeyDecision: Sendable {
    case cancel
    case trustOnce
    case alwaysTrust
    case replace
}

public enum ViewMode: String, Hashable, Sendable, Codable, CaseIterable {
    case icon
    case list
    case columns
}

public struct SortConfiguration: Hashable, Sendable, Codable {
    public var column: String
    public var ascending: Bool
    /// Fold case when comparing names. Off means raw bytes.
    public var caseInsensitive: Bool
    /// Keep directories above files whatever the column or direction.
    public var foldersFirst: Bool

    public init(column: String = "name", ascending: Bool = true, caseInsensitive: Bool = false, foldersFirst: Bool = true) {
        self.column = column
        self.ascending = ascending
        self.caseInsensitive = caseInsensitive
        self.foldersFirst = foldersFirst
    }

    private enum CodingKeys: String, CodingKey { case column, ascending, caseInsensitive, foldersFirst }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        column = try container.decodeIfPresent(String.self, forKey: .column) ?? "name"
        ascending = try container.decodeIfPresent(Bool.self, forKey: .ascending) ?? true
        caseInsensitive = try container.decodeIfPresent(Bool.self, forKey: .caseInsensitive) ?? false
        foldersFirst = try container.decodeIfPresent(Bool.self, forKey: .foldersFirst) ?? true
    }
}

public struct BrowserSnapshot: Hashable, Sendable {
    public var connectionID: ConnectionID?
    public var path: RemotePath
    public var selection: Set<RemotePath>
    public var viewMode: ViewMode
    public var sort: SortConfiguration
    public var showsHidden: Bool

    public init(
        connectionID: ConnectionID? = nil,
        path: RemotePath = RemotePath(bytes: [0x2F]),
        selection: Set<RemotePath> = [],
        viewMode: ViewMode = .list,
        sort: SortConfiguration = SortConfiguration(),
        showsHidden: Bool = false
    ) {
        self.connectionID = connectionID
        self.path = path
        self.selection = selection
        self.viewMode = viewMode
        self.sort = sort
        self.showsHidden = showsHidden
    }
}

/// What the column view shows for a location: one column per folder from the root down to the
/// location, each with its selection. Every column above the location selects the next folder on
/// the way down; the location's own column selects the items of `selection` it holds. A selected
/// folder that is itself the location is therefore selected in its parent's column, and its own
/// column shows with nothing selected, as it does after a click.
public enum ColumnTrail {
    public struct Column: Hashable, Sendable {
        public var folder: RemotePath
        public var selected: Set<RemotePath>

        public init(folder: RemotePath, selected: Set<RemotePath>) {
            self.folder = folder
            self.selected = selected
        }
    }

    public static func columns(root: RemotePath, path: RemotePath, selection: Set<RemotePath>) -> [Column] {
        var folders = [path]
        if path.isInside(root) {
            while let last = folders.last, last != root, let parent = last.parent { folders.append(parent) }
            folders.reverse()
        } else {
            folders = [root]
        }
        var columns: [Column] = []
        for (index, folder) in folders.enumerated() {
            let selected: Set<RemotePath> = index + 1 < folders.count
                ? [folders[index + 1]]
                : selection.filter { $0.parent == folder }
            columns.append(Column(folder: folder, selected: selected))
        }
        return columns
    }
}

public enum ListingSort {
    /// With `foldersFirst`, directories come first in every column and direction. Within each
    /// group the chosen column applies, with raw-byte name order breaking ties.
    public static func apply(_ items: [RemoteItem], sort: SortConfiguration) -> [RemoteItem] {
        items.sorted { lhs, rhs in
            if sort.foldersFirst, (lhs.kind == .directory) != (rhs.kind == .directory) {
                return lhs.kind == .directory
            }
            let order: ComparisonResult
            switch sort.column {
            case "size":
                order = (lhs.size ?? 0) < (rhs.size ?? 0) ? .orderedAscending : (lhs.size == rhs.size ? .orderedSame : .orderedDescending)
            case "mtime":
                order = (lhs.mtime ?? 0) < (rhs.mtime ?? 0) ? .orderedAscending : (lhs.mtime == rhs.mtime ? .orderedSame : .orderedDescending)
            case "kind":
                order = lhs.kind.rawValue.compare(rhs.kind.rawValue, options: .literal)
            default:
                order = compareNames(lhs, rhs, caseInsensitive: sort.caseInsensitive)
            }
            if order == .orderedSame {
                return compareNames(lhs, rhs, caseInsensitive: sort.caseInsensitive) == .orderedAscending
            }
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compareNames(_ lhs: RemoteItem, _ rhs: RemoteItem, caseInsensitive: Bool) -> ComparisonResult {
        if caseInsensitive {
            let folded = lhs.name.lowercased().compare(rhs.name.lowercased(), options: .literal)
            if folded != .orderedSame { return folded }
        }
        return compareBytes(lhs.path.nameBytes, rhs.path.nameBytes)
    }

    private static func compareBytes(_ left: [UInt8], _ right: [UInt8]) -> ComparisonResult {
        let count = min(left.count, right.count)
        for index in 0..<count {
            if left[index] < right[index] { return .orderedAscending }
            if left[index] > right[index] { return .orderedDescending }
        }
        if left.count < right.count { return .orderedAscending }
        if left.count > right.count { return .orderedDescending }
        return .orderedSame
    }
}

public enum SyntaxPreview {
    /// A page for Quick Look, or when `compact`, a small unwrapped listing that follows the
    /// system appearance for the inspector pane.
    public static func html(text: String, fileName: String, compact: Bool = false, wraps: Bool = false) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let colored = color(escaped)
        let ext = fileName.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        let body = compact
            ? "body{margin:6px 8px;font:11px/1.35 ui-monospace,Menlo,monospace;white-space:\(wraps ? "pre-wrap" : "pre");overflow-wrap:anywhere;color:#1d1d1f;background:transparent;-webkit-user-select:text}"
                + "@media(prefers-color-scheme:dark){body{color:#e5e5e7}.k{color:#6cb3ff}.s{color:#7ed49a}.c{color:#98989d}}"
            : "body{margin:24px;font:13px ui-monospace,Menlo,monospace;white-space:pre-wrap;color:#1d1d1f;background:#fff}"
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(ext)</title>
        <style>
        \(body)
        .k{color:#0b4f9c;font-weight:600}.s{color:#0b6b3a}.c{color:#6e6e73}
        </style>
        </head><body>\(colored)</body></html>
        """
    }

    /// One pass over the text: a comment, a string, or a keyword, whichever starts first, so a
    /// later rule never re-matches the markup an earlier one inserted.
    private static func color(_ text: String) -> String {
        let keywords = "func|let|var|class|struct|enum|import|export|return|if|else|for|while|fn|pub|def|const|public|private|async|await"
        let pattern = #"(//[^\n]*|(?m:^[ \t]*#[^\n]*))|("(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\.)*`)|\b("# + keywords + #")\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            out += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let token = source.substring(with: match.range)
            let cls = match.range(at: 1).location != NSNotFound ? "c" : match.range(at: 2).location != NSNotFound ? "s" : "k"
            out += "<span class=\"\(cls)\">\(token)</span>"
            cursor = match.range.location + match.range.length
        }
        out += source.substring(from: cursor)
        return out
    }
}

/// Values with units in three characters and an SI prefix: `959 B`, `1.2kB`, ` 14kB`, `2.5ms`.
/// Sizes, rates, and times read the same way everywhere.
public enum Units {
    public static func scale(_ value: Double, unit: String) -> String {
        if value > 0, value.isFinite {
            let span = ["T", "G", "M", "k", " ", "m", "µ", "n", "p"]
            var value = value
            var slot = 4
            while value < 0.995, slot < 8 {
                value *= 1000
                slot += 1
            }
            while value >= 999.5, slot > 0 {
                value /= 1000
                slot -= 1
            }
            if value < 999.5 {
                let tenth = (value * 10).rounded() / 10
                let digits = tenth >= 10 ? String(Int(value.rounded())) : String(format: "%.1f", tenth)
                return String(repeating: " ", count: max(0, 3 - digits.count)) + digits + span[slot] + unit
            }
        }
        return value == 0 ? "  0 \(unit)" : "??? \(unit)"
    }

    public static func bytes(_ size: UInt64) -> String {
        scale(Double(size), unit: "B")
    }
}

public enum RetryPolicy {
    public static let delays: [Double] = [1, 2, 4]

    public static func isRetryable(_ error: Error) -> Bool {
        guard let error = error as? TransferError else { return false }
        switch error {
        case .connectionLost, .timeout: return true
        default: return false
        }
    }

    /// The delay before attempt `attempt` (zero-based), or nil when retries are exhausted.
    public static func delay(afterAttempt attempt: Int) -> Double? {
        attempt < delays.count ? delays[attempt] : nil
    }
}

public struct CacheEntry: Hashable, Sendable {
    public var id: String
    public var size: UInt64
    public var lastUsed: Date

    public init(id: String, size: UInt64, lastUsed: Date) {
        self.id = id
        self.size = size
        self.lastUsed = lastUsed
    }
}

public enum CacheEviction {
    public static let previewLimit: UInt64 = 1_073_741_824

    /// Oldest entries first, until the rest fit under `limit`.
    public static func victims(_ entries: [CacheEntry], limit: UInt64) -> [String] {
        var total = entries.reduce(UInt64(0)) { $0 + $1.size }
        guard total > limit else { return [] }
        var removed: [String] = []
        for entry in entries.sorted(by: { $0.lastUsed < $1.lastUsed }) {
            guard total > limit else { break }
            total -= entry.size
            removed.append(entry.id)
        }
        return removed
    }
}

public struct HostKeyLine: Hashable, Sendable {
    public var host: String
    public var keyType: String
    public var key: String

    public init(host: String, keyType: String, key: String) {
        self.host = host
        self.keyType = keyType
        self.key = key
    }

    public init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        var parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if let first = parts.first, first.hasPrefix("@") { parts.removeFirst() }
        guard parts.count >= 3 else { return nil }
        self.init(host: parts[0], keyType: parts[1], key: parts[2])
    }

    public var text: String { "\(host) \(keyType) \(key)" }
}

public enum KnownHosts {
    /// The known-hosts files `ssh -G` reports, user files first.
    public static func files(sshConfigOutput: String) -> [String] {
        var user: [String] = []
        var global: [String] = []
        for line in sshConfigOutput.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count > 1 else { continue }
            switch parts[0].lowercased() {
            case "userknownhostsfile": user += parts.dropFirst()
            case "globalknownhostsfile": global += parts.dropFirst()
            default: continue
            }
        }
        return user + global
    }

    /// The entries `ssh-keygen -F` printed.
    public static func entries(keygenOutput: String) -> [HostKeyLine] {
        keygenOutput.split(separator: "\n").compactMap { HostKeyLine(line: String($0)) }
    }

    public static func situation(offered: HostKeyLine, stored: [HostKeyLine]) -> HostKeySituation {
        if stored.contains(where: { $0.keyType == offered.keyType && $0.key == offered.key }) {
            return .unchanged
        }
        if stored.contains(where: { $0.keyType == offered.keyType }) {
            return .changed
        }
        return .firstSeen
    }
}
