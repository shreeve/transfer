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

    public init(column: String = "name", ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
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

public enum ListingSort {
    public static func apply(_ items: [RemoteItem], sort: SortConfiguration) -> [RemoteItem] {
        items.sorted { lhs, rhs in
            let order: ComparisonResult
            switch sort.column {
            case "size":
                order = (lhs.size ?? 0) < (rhs.size ?? 0) ? .orderedAscending : (lhs.size == rhs.size ? .orderedSame : .orderedDescending)
            case "mtime":
                order = (lhs.mtime ?? 0) < (rhs.mtime ?? 0) ? .orderedAscending : (lhs.mtime == rhs.mtime ? .orderedSame : .orderedDescending)
            case "kind":
                order = lhs.kind.rawValue.compare(rhs.kind.rawValue, options: .literal)
            default:
                order = compareBytes(lhs.path.nameBytes, rhs.path.nameBytes)
            }
            if order == .orderedSame {
                return compareBytes(lhs.path.nameBytes, rhs.path.nameBytes) == .orderedAscending
            }
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
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
    public static func html(text: String, fileName: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let colored = color(escaped)
        let ext = fileName.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(ext)</title>
        <style>
        body{margin:24px;font:13px ui-monospace,Menlo,monospace;white-space:pre-wrap;color:#1d1d1f;background:#fff}
        .k{color:#0b4f9c;font-weight:600}.s{color:#0b6b3a}.c{color:#6e6e73}
        </style>
        </head><body>\(colored)</body></html>
        """
    }

    private static func color(_ text: String) -> String {
        let keywords = "func|let|var|class|struct|enum|import|return|if|else|for|while|fn|pub|def|const|public|private"
        var colored = text.replacingOccurrences(
            of: "\\b(\(keywords))\\b",
            with: "<span class=\"k\">$1</span>",
            options: .regularExpression
        )
        colored = colored.replacingOccurrences(
            of: "(&quot;.*?&quot;|\".*?\")",
            with: "<span class=\"s\">$1</span>",
            options: .regularExpression
        )
        return colored.replacingOccurrences(
            of: "(//[^<\\n]*)",
            with: "<span class=\"c\">$1</span>",
            options: .regularExpression
        )
    }
}
