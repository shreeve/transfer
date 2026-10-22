// Small pure rules, tested in Tests/TransferCoreTests: Live or view, made-up names, listing order,
// the column trail, units, retries, cache eviction, known-hosts lines, what Quit asks.

import Foundation
import UniformTypeIdentifiers

public enum OpenKind: String, Sendable {
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
    /// How much of a text file the inspector shows, and so all of it that is fetched.
    public static let previewHead = 64 << 10

    /// The extension is what follows the last dot: ".env"'s is "env", and "notes." has none. A
    /// name with no dot, such as "Makefile", matches the list by its whole name.
    public static func openKind(fileName: String, extensions: Set<String>) -> OpenKind {
        guard let dot = fileName.lastIndex(of: ".") else { return extensions.contains(fileName.lowercased()) ? .live : .view }
        let ext = fileName[fileName.index(after: dot)...].lowercased()
        guard !ext.isEmpty else { return .view }
        if extensions.contains(ext) { return .live }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .plainText) || type.conforms(to: .sourceCode) { return .live }
        return .view
    }

    /// Whether a Live working copy is quarantined, as every other download is. A Terminal script
    /// (`.command`, `.tool`) is not: Gatekeeper refuses to open a quarantined one in any app, an
    /// editor too, so it could never be edited Live. The copy is 0600, so nothing runs it.
    public static func quarantinesLiveCopy(fileName: String) -> Bool {
        guard let dot = fileName.lastIndex(of: "."), let script = UTType("com.apple.terminal.shell-script"),
              let type = UTType(filenameExtension: String(fileName[fileName.index(after: dot)...])) else { return true }
        return !type.conforms(to: script)
    }
}

/// What the inspector's preview box shows for a file, decided from its name and listed size before
/// anything is fetched: a file it cannot show is never downloaded, and its box shows its icon.
public enum InspectorPreviewPlan: Equatable, Sendable {
    /// The first `EditableFile.previewHead` bytes as text, whatever the file's size.
    case text
    /// The whole file, decoded as a picture.
    case picture
    /// The whole file, through Quick Look.
    case quickLook
    /// Nothing to fetch.
    case icon

    /// The largest file that is not text the inspector fetches to preview. A file listed without
    /// a size could be read without end, so it is not previewed.
    public static let limit: UInt64 = 10 << 20

    /// Types Quick Look draws as more than an icon. Anything else (archives, executables, unknown
    /// extensions) would only show its icon, so it is not fetched.
    private static let quickLookTypes: [UTType] = [
        .pdf, .audiovisualContent, .rtf, .rtfd, .text, .presentation, .spreadsheet, .compositeContent,
        .font, .threeDContent, .usdz, .epub,
    ]

    /// `isText` is the Live rule (`EditableFile.openKind`): an editable file shows its head.
    public static func plan(fileName: String, size: UInt64?, isText: Bool) -> Self {
        if isText { return .text }
        guard let size, size <= limit else { return .icon }
        // A name with no dot (README, LICENSE, Makefile) has no type to go by; Quick Look reads
        // its contents and shows text as text, as it did before the plan existed.
        guard let dot = fileName.lastIndex(of: ".") else { return .quickLook }
        guard let type = UTType(filenameExtension: String(fileName[fileName.index(after: dot)...])) else { return .icon }
        if type.conforms(to: .image) { return .picture }
        return quickLookTypes.contains(where: type.conforms) ? .quickLook : .icon
    }
}

/// What Space does for an item before anything is fetched: Quick Look downloads the whole file,
/// so a file over `limit` is not, and a folder has nothing to download.
public enum QuickLookPlan: Equatable, Sendable {
    case fetch
    /// The file is over `limit`: say so and suggest Download Copy.
    case tooLarge
    /// A folder or a special file: no fetch, no panel.
    case nothing

    /// The largest file Quick Look fetches. A file listed without a size is fetched, as it always was.
    public static let limit: UInt64 = 256 << 20

    public static func tooLargeMessage(name: String) -> String {
        "“\(name)” is too large to preview (over 256 MB). Use Download Copy instead."
    }

    /// `kind` and `size` of the item after a link is followed.
    public static func plan(kind: ItemKind, size: UInt64?) -> Self {
        switch kind {
        case .file: (size ?? 0) > limit ? .tooLarge : .fetch
        default: .nothing
        }
    }
}

public enum NameCollisionChoice: String, Sendable {
    case skip
    case keepBoth
    case replace
}

public enum LiveConflictChoice: String, Sendable {
    case compare
    case keepLocal
    case keepRemote
    case keepBoth
}

/// Every name the app makes up so as not to take an existing one.
public enum KeepBothName {
    /// The first of `candidate(first)`, `candidate(first + 1)`, … whose `key` `existing` lacks.
    public static func firstFree(existing: Set<String>, from first: Int = 1, key: (String) -> String = { $0 }, _ candidate: (Int) -> String) -> String {
        var n = first
        while existing.contains(key(candidate(n))) { n += 1 }
        return candidate(n)
    }

    /// The hidden temp beside `basename`: ".notes.txt.transfer-<id>". The name in it is cut, never
    /// inside a character, so the temp fits the 255 bytes a file name may take even when
    /// `basename` nearly does.
    public static func temp(for basename: String, id: String = UUID().uuidString) -> String {
        LiveDecision.siblingName(of: basename, prefix: ".", suffix: ".transfer-\(id)")
    }

    /// Keep Both: "report 2.pdf", "report 3.pdf", …; a folder's whole name is kept: "v1.2 2".
    /// `existing` holds names as `key` gives them.
    public static func next(existing: Set<String>, original: String, isFolder: Bool = false, key: (String) -> String = { $0 }) -> String {
        let split = splitExtension(original, isFolder: isFolder)
        return firstFree(existing: existing, from: 2, key: key) { "\(split.base) \($0)\(split.ext)" }
    }

    /// Duplicate: "notes copy.txt", "notes copy 2.txt", …; a folder's whole name is kept: "v1.2 copy".
    public static func duplicate(existing: Set<String>, original: String, isFolder: Bool = false) -> String {
        let split = splitExtension(original, isFolder: isFolder)
        return firstFree(existing: existing) { $0 == 1 ? "\(split.base) copy\(split.ext)" : "\(split.base) copy \($0)\(split.ext)" }
    }

    /// New Folder: "untitled folder", "untitled folder 2", …
    public static func untitledFolder(existing: Set<String>) -> String {
        firstFree(existing: existing) { $0 == 1 ? "untitled folder" : "untitled folder \($0)" }
    }

    /// Keep Both for a Live conflict, the Mac's copy beside the server's: "notes (from this
    /// Mac).txt", "notes (from this Mac 2).txt", …; the extension stays last, so the copy opens in
    /// the same editor.
    public static func fromThisMac(existing: Set<String>, original: String) -> String {
        let split = splitExtension(original)
        return firstFree(existing: existing) { $0 == 1 ? "\(split.base) (from this Mac)\(split.ext)" : "\(split.base) (from this Mac \($0))\(split.ext)" }
    }

    /// A folder has no extension, as in Finder: its name is all base.
    private static func splitExtension(_ name: String, isFolder: Bool = false) -> (base: String, ext: String) {
        guard !isFolder, let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return (name, "")
        }
        return (String(name[..<dot]), String(name[dot...]))
    }
}

public enum OperationState: String, Hashable, Sendable {
    case queued
    case active
    case paused
    case succeeded
    case failed
}

public struct TransferProgress: Hashable, Sendable {
    public var completed: UInt64
    public var total: UInt64?
    public var itemsCompleted: Int

    public init(completed: UInt64, total: UInt64? = nil, itemsCompleted: Int = 0) {
        self.completed = completed
        self.total = total
        self.itemsCompleted = itemsCompleted
    }
}

public enum HostKeySituation: String, Sendable {
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

public enum ViewMode: String, Hashable, Sendable, CaseIterable {
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
    public var path = RemotePath(bytes: [0x2F])
    public var selection: Set<RemotePath> = []
    public var viewMode = ViewMode.list
    public var sort = SortConfiguration()
    public var showsHidden = false

    public init() {}
}

/// What the path bar shows, as Finder's does: each folder from the server's root down to the
/// location, then the selected item when exactly one item in the location is selected. Only a
/// folder above the location is a place to go: the location is where the window already is, and
/// the selected item is shown, never opened, from the bar.
public enum PathTrail {
    public struct Step: Hashable, Sendable {
        /// The real bytes, so a name that is not UTF-8 is gone to as itself.
        public var path: RemotePath
        /// A click on it goes there.
        public var navigable: Bool
        /// The selected item that ends the trail.
        public var isSelection: Bool
    }

    public static func steps(location: RemotePath, selection: Set<RemotePath>) -> [Step] {
        var folders = [location]
        while let parent = folders.last?.parent { folders.append(parent) }
        var steps = folders.reversed().map { Step(path: $0, navigable: $0 != location, isSelection: false) }
        if selection.count == 1, let only = selection.first, only != location, only.parent == location {
            steps.append(Step(path: only, navigable: false, isSelection: true))
        }
        return steps
    }

    /// Whether a click on `path` goes anywhere from `location`: only a folder above it does.
    public static func goes(to path: RemotePath, from location: RemotePath) -> Bool {
        path != location && location.isInside(path)
    }
}

/// What the column view shows for a location: a column per folder from the root down, each with its
/// selection. Each column above the location selects the next folder down; the location's own
/// column selects the items of `selection` it holds. So a selected folder that is the location is
/// selected in its parent's column, and its own column has nothing selected, as after a click.
public enum ColumnTrail {
    public struct Column: Hashable, Sendable {
        public var folder: RemotePath
        public var selected: Set<RemotePath>
    }

    public static func columns(root: RemotePath, path: RemotePath, selection: Set<RemotePath>) -> [Column] {
        var folders = [path.isInside(root) ? path : root]
        while let last = folders.last, last != root, let parent = last.parent { folders.append(parent) }
        folders.reverse()
        return folders.enumerated().map { index, folder in
            Column(folder: folder, selected: index + 1 < folders.count ? [folders[index + 1]] : selection.filter { $0.parent == folder })
        }
    }
}

/// The order of a folder's items. Each item's sort key is computed once, not per comparison: a
/// listing is sorted again on each publish while a big folder streams in.
public enum ListingSort {
    /// With `foldersFirst`, directories come first in every column and direction. Then the column
    /// applies; ties go to name order, ascending in every direction. Names compare case-folded
    /// first when `caseInsensitive`, then by raw bytes. A missing size or time counts as 0.
    public static func apply(_ items: [RemoteItem], sort: SortConfiguration) -> [RemoteItem] {
        let order = Order(sort)
        return order.sorted(items) { index, _ in items[index] }
    }

    /// `page`, newly listed, merged into `sorted`, already in `apply`'s order for the same `sort`.
    /// The result equals `apply(sorted + page, sort:)` for the cost of sorting the page and copying
    /// the listing, so a streaming folder's publishes stop costing a full sort each.
    public static func merge(_ page: [RemoteItem], into sorted: [RemoteItem], sort: SortConfiguration) -> [RemoteItem] {
        guard !sorted.isEmpty else { return apply(page, sort: sort) }
        let order = Order(sort)
        var merged: [RemoteItem] = []
        merged.reserveCapacity(sorted.count + page.count)
        var start = sorted.startIndex
        for (index, key) in order.sorted(page, { ($0, $1) }) {
            // The first listed item that sorts after the new one. Galloping from the last
            // insertion point computes the keys of only a few listed items per new one.
            let after = { (listed: Int) in order.precedes(key, order.key(sorted[listed])) }
            var low = start
            var high = start
            var step = 1
            while high < sorted.endIndex, !after(high) {
                low = high + 1
                high = low + step
                step *= 2
            }
            high = min(high, sorted.endIndex)
            while low < high {
                let middle = (low + high) / 2
                if after(middle) { high = middle } else { low = middle + 1 }
            }
            merged += sorted[start..<low]
            merged.append(page[index])
            start = low
        }
        merged += sorted[start...]
        return merged
    }

    private struct Key {
        var folder: Bool
        var value: UInt64
        /// The lowercased name's UTF-8, when names fold. Byte order is the order of
        /// `compare(_:options: .literal)`, which the sort used before.
        var folded: ArraySlice<UInt8>
        var name: ArraySlice<UInt8>
    }

    private struct Order {
        enum Column { case name, size, mtime, kind }
        let column: Column
        let ascending: Bool
        let foldersFirst: Bool
        let caseInsensitive: Bool

        init(_ sort: SortConfiguration) {
            switch sort.column {
            case "size": column = .size
            case "mtime": column = .mtime
            case "kind": column = .kind
            default: column = .name
            }
            ascending = sort.ascending
            foldersFirst = sort.foldersFirst
            caseInsensitive = sort.caseInsensitive
        }

        /// `items` in order, as `each(index, key)`. The keys stay put while their indices are
        /// sorted, and Swift's sort is stable, so items that tie on every key keep their order.
        func sorted<T>(_ items: [RemoteItem], _ each: (Int, Key) -> T) -> [T] {
            let keys = items.map(key)
            return keys.withUnsafeBufferPointer { keys in
                keys.indices.sorted { precedes(keys[$0], keys[$1]) }.map { each($0, keys[$0]) }
            }
        }

        func key(_ item: RemoteItem) -> Key {
            let name = item.path.nameSlice
            let value: UInt64 = switch column {
            case .size: item.size ?? 0
            case .mtime: UInt64(item.mtime ?? 0)
            case .kind: Self.kindRank(item.kind)
            case .name: 0
            }
            return Key(folder: item.kind == .directory, value: value, folded: caseInsensitive ? Self.fold(name) : [], name: name)
        }

        /// What `String.lowercased()` makes of the name, as UTF-8. ASCII, the usual case, folds
        /// byte by byte, and a name with no capitals is its own fold.
        private static func fold(_ name: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
            var capitals = false
            for byte in name {
                if byte >= 0x80 { return Array(String(decoding: name, as: UTF8.self).lowercased().utf8)[...] }
                if byte &- 0x41 < 26 { capitals = true }
            }
            return capitals ? ArraySlice(name.map { $0 &- 0x41 < 26 ? $0 | 0x20 : $0 }) : name
        }

        /// The kinds in the order of their raw values, as the kind column sorted them before.
        private static func kindRank(_ kind: ItemKind) -> UInt64 {
            switch kind {
            case .directory: 0
            case .file: 1
            case .other: 2
            case .symlink: 3
            }
        }

        func precedes(_ lhs: Key, _ rhs: Key) -> Bool {
            if foldersFirst, lhs.folder != rhs.folder { return lhs.folder }
            if column != .name, lhs.value != rhs.value { return (lhs.value < rhs.value) == ascending }
            let names = compareNames(lhs, rhs)
            return column == .name && !ascending ? names > 0 : names < 0
        }

        private func compareNames(_ lhs: Key, _ rhs: Key) -> Int {
            if caseInsensitive {
                let folded = Self.compare(lhs.folded, rhs.folded)
                if folded != 0 { return folded }
            }
            return Self.compare(lhs.name, rhs.name)
        }

        private static func compare(_ left: ArraySlice<UInt8>, _ right: ArraySlice<UInt8>) -> Int {
            let count = min(left.count, right.count)
            let order = left.withUnsafeBufferPointer { l in
                right.withUnsafeBufferPointer { r in count == 0 ? 0 : memcmp(l.baseAddress!, r.baseAddress!, count) }
            }
            if order != 0 { return order < 0 ? -1 : 1 }
            return left.count == right.count ? 0 : (left.count < right.count ? -1 : 1)
        }
    }
}

public enum SyntaxPreview {
    /// A page for Quick Look, or when `compact`, a small unwrapped listing that follows the
    /// system appearance for the inspector pane. The page has no title: Quick Look shows the
    /// file's own name, and a server's name would go in unescaped.
    public static func html(text: String, compact: Bool = false, wraps: Bool = false) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let colored = color(escaped)
        // The compact page is transparent: the inspector draws the document background behind
        // it, so the two never differ. Its dark colors come after the light ones, which they override.
        let body = compact
            ? "body{margin:6px 8px;font:11px/1.35 ui-monospace,Menlo,monospace;white-space:\(wraps ? "pre-wrap" : "pre");overflow-wrap:anywhere;color:#1d1d1f;background:transparent;-webkit-user-select:text}"
            : "body{margin:24px;font:13px ui-monospace,Menlo,monospace;white-space:pre-wrap;color:#1d1d1f;background:#fff}"
        let dark = compact ? "\n@media(prefers-color-scheme:dark){body{color:#e5e5e7}.k{color:#6cb3ff}.s{color:#7ed49a}.c{color:#98989d}}" : ""
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
        \(body)
        .k{color:#0b4f9c;font-weight:600}.s{color:#0b6b3a}.c{color:#6e6e73}\(dark)
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

/// Compact measures in a fixed width: the number right-aligned in three characters, one slot for
/// the SI prefix (a space for none), then the unit: ` 22 B`, `6.1kB`, ` 78MB`, `1.2GB`, `821ms`,
/// `1.2ks`. Only a scaled value under 10 has a decimal; a value in the base unit is whole. Zero is
/// `  0 B`; a value beyond the prefixes, below one pico, negative, or not a number is `??? B`.
/// Every output for one unit is as wide as every other, so sizes stack in columns.
public enum Units {
    /// From pico (-4) to tera (4); the base unit is a space.
    private static let prefixes: [Character] = ["p", "n", "µ", "m", " ", "k", "M", "G", "T"]

    public static func scale(_ value: Double, unit: String) -> String {
        if value == 0 { return "  0 " + unit }
        guard value > 0, value.isFinite else { return "??? " + unit }
        // `value` in units of 1000^power, divided or multiplied by whole powers so that a whole
        // number of bytes divides exactly.
        func scaled(_ power: Int, times: Double = 1) -> Double {
            power >= 0 ? value / (pow(1000, Double(power)) / times) : value * pow(1000, Double(-power)) * times
        }
        var power = 0
        while scaled(power) < 0.995, power > -4 { power -= 1 }
        while scaled(power) >= 999.5, power < 4 { power += 1 }
        let shown = scaled(power)
        guard shown >= 0.995, shown < 999.5 else { return "??? " + unit }
        var digits = String(Int(shown.rounded()))
        if power != 0 {
            // At least 1.0: a value just over 0.995 can land a hair under in binary.
            let tenths = max(10, Int(scaled(power, times: 10).rounded()))
            if tenths < 100 { digits = "\(tenths / 10).\(tenths % 10)" }
        }
        return String(repeating: " ", count: 3 - digits.count) + digits + String(prefixes[power + 4]) + unit
    }

    public static func bytes(_ size: UInt64) -> String {
        scale(Double(size), unit: "B")
    }
}

/// Which columns a narrow row keeps: its flexible column (a name) keeps at least `floor`, the
/// required columns always show, and the optional ones give way last first.
public enum ColumnFit {
    /// How many of `optional`, in the order they are kept (the last gives way first), fit in
    /// `available` beside `required` and the flexible column, with `spacing` between columns.
    public static func kept(_ optional: [Double], required: [Double], spacing: Double, floor: Double, in available: Double) -> Int {
        func width(_ count: Int) -> Double {
            let columns = required + optional.prefix(count)
            return floor + columns.reduce(0, +) + spacing * Double(columns.count)
        }
        var count = optional.count
        while count > 0, width(count) > available { count -= 1 }
        return count
    }
}

public enum RetryPolicy {
    public static let delays: [Double] = [1, 2, 4]

    public static func isRetryable(_ error: Error) -> Bool {
        switch error as? TransferError {
        case .connectionLost?, .timeout?, .changedOnServer?: true
        default: false
        }
    }

    /// The delay before attempt `attempt` (zero-based), or nil when retries are exhausted.
    public static func delay(afterAttempt attempt: Int) -> Double? {
        attempt < delays.count ? delays[attempt] : nil
    }
}

public enum CacheEviction {
    public static let previewLimit: UInt64 = 1_073_741_824

    /// Oldest entries first, until the rest fit under `limit`.
    public static func victims(_ entries: [(id: String, size: UInt64, lastUsed: Date)], limit: UInt64) -> [String] {
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

/// How wide the inspector may grow: 60% of the split view's width, never under its own minimum,
/// and never so wide that the content pane would fall under its minimum (that minimum wins over
/// the 60%, but not over the inspector's own).
public enum InspectorWidth {
    public static let minimum = 240.0
    public static let share = 0.6
    public static let contentMinimum = 260.0

    /// `sidebar` is the sidebar's current width, 0 when it is hidden.
    public static func maximum(splitWidth: Double, sidebar: Double) -> Double {
        let room = splitWidth - sidebar - contentMinimum
        return max(minimum, min((splitWidth * share).rounded(.down), room))
    }
}

/// The split view's saved frames, one string per column ("x, y, width, height, collapsed,
/// hidden"). A window closed while its inspector was collapsing saves that column open at
/// width 0, and a split restored in the other state than the preference's flips it after
/// SwiftUI's first update; SwiftUI then never updates the chrome again (measured in
/// `InspectorTests`).
public enum SplitFrames {
    /// The saved frames with the inspector column in the state the preference asks for, or nil
    /// when they already are (or the format is unknown). A split restored with the inspector in
    /// the other state flips it after SwiftUI's first update, and from then on SwiftUI never
    /// updates the chrome again (measured in `InspectorTests`), so the save is rewritten before
    /// the split reads it. Only the column's flag changes; its width stays at least `inspectorMinimum`.
    public static func aligned(_ frames: [String], inspectorShown: Bool, inspectorMinimum: Double) -> [String]? {
        guard frames.count == 3 else { return nil }
        var fields = frames[2].split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count == 6, let width = Double(fields[2]), fields[4] == "YES" || fields[4] == "NO" else { return nil }
        let flag = inspectorShown ? "NO" : "YES"
        let wide = max(width, inspectorMinimum)
        guard fields[4] != flag || width < inspectorMinimum else { return nil }
        fields[2] = String(format: "%f", wide)
        fields[4] = flag
        var aligned = frames
        aligned[2] = fields.joined(separator: ", ")
        return aligned
    }
}

/// What Quit asks, or nil when quitting loses nothing. `unsynced` is nil when the Live count did
/// not arrive in time: then it asks, since unsynced edits cannot be ruled out.
public struct QuitQuestion: Equatable, Sendable {
    public var message: String
    public var detail: String

    public init?(unsynced: Int?, running: Int) {
        let stops = running > 0 ? "\(ClipText.count(running, "transfer")) not yet finished will stop; a move keeps each original until its copy is complete." : nil
        switch unsynced {
        case nil:
            message = "Transfer could not check its Live files"
            detail = ["Some may have edits that have not reached the server. Quitting now leaves any such edits on this Mac until the next launch.", stops].compactMap(\.self).joined(separator: " ")
        case let count? where count > 0:
            message = TransferError.liveUnsynced(count).localizedDescription
            detail = ["Uploads run only while Transfer is open. Quitting now leaves those edits on this Mac until the next launch.", stops].compactMap(\.self).joined(separator: " ")
        default:
            guard let stops else { return nil }
            message = running == 1 ? "A transfer has not finished" : "\(running) transfers have not finished"
            detail = stops
        }
    }
}
