import Foundation
import Testing
import TransferCore

/// ListingSort computes each item's keys once (PERF-06). These tests hold it to the order the
/// per-comparison sort gave, kept here as `reference`, over every sort setting.
struct ListingSortTests {
    static let settings: [SortConfiguration] = ["name", "size", "mtime", "kind"].flatMap { column in
        [true, false].flatMap { ascending in
            [true, false].flatMap { folded in
                [true, false].map { foldersFirst in
                    SortConfiguration(column: column, ascending: ascending, caseInsensitive: folded, foldersFirst: foldersFirst)
                }
            }
        }
    }

    @Test(arguments: settings) func theOrderIsTheOneTheOldSortGave(sort: SortConfiguration) {
        var random = SplitMix(seed: 7)
        for round in 0..<20 {
            let items = Self.listing(count: round * 25, random: &random)
            #expect(ListingSort.apply(items, sort: sort) == Self.reference(items, sort: sort))
        }
    }

    /// A streamed listing merged page by page ends as the whole listing sorted at once, with
    /// items that tie on every key in the order they arrived, as a stable sort leaves them.
    @Test(arguments: settings) func mergingPagesGivesTheWholeSort(sort: SortConfiguration) {
        var random = SplitMix(seed: 11)
        for _ in 0..<10 {
            let items = Self.listing(count: 300, random: &random, duplicates: true)
            var merged: [RemoteItem] = []
            var start = 0
            while start < items.count {
                let end = min(items.count, start + Int(random.next() % 60))
                let page = Array(items[start..<end])
                #expect(ListingSort.merge(page, into: merged, sort: sort) == ListingSort.apply(merged + page, sort: sort))
                merged = ListingSort.merge(page, into: merged, sort: sort)
                start = end
            }
            #expect(merged == Self.reference(items, sort: sort))
        }
    }

    @Test func mergingIntoOrFromNothing() {
        let items = ["b", "a", "c"].map { RemoteItem(path: RemotePath(string: "/" + $0), kind: .file) }
        let sort = SortConfiguration()
        #expect(ListingSort.merge(items, into: [], sort: sort).map(\.name) == ["a", "b", "c"])
        let sorted = ListingSort.apply(items, sort: sort)
        #expect(ListingSort.merge([], into: sorted, sort: sort) == sorted)
        let late = [RemoteItem(path: RemotePath(string: "/0"), kind: .file), RemoteItem(path: RemotePath(string: "/z"), kind: .file)]
        #expect(ListingSort.merge(late, into: sorted, sort: sort).map(\.name) == ["0", "a", "b", "c", "z"])
    }

    @Test func tiesOnAColumnGoToNameOrderInEitherDirection() {
        let items = [("b", 5), ("a", 5), ("C", 5), ("d", 1)].map {
            RemoteItem(path: RemotePath(string: "/" + $0.0), kind: .file, size: UInt64($0.1), mtime: 1)
        }
        #expect(ListingSort.apply(items, sort: SortConfiguration(column: "size", ascending: false)).map(\.name) == ["C", "a", "b", "d"])
        #expect(ListingSort.apply(items, sort: SortConfiguration(column: "size", ascending: false, caseInsensitive: true)).map(\.name) == ["a", "b", "C", "d"])
        #expect(ListingSort.apply(items, sort: SortConfiguration(column: "mtime", ascending: false, caseInsensitive: true)).map(\.name) == ["a", "b", "C", "d"])
        #expect(ListingSort.apply(items, sort: SortConfiguration(column: "name", ascending: false, caseInsensitive: true)).map(\.name) == ["d", "C", "b", "a"])
    }

    /// The old comparator called a missing size both larger and smaller than 0, so where items
    /// without one landed depended on the sort's path. Missing now counts as 0.
    @Test func aMissingSizeOrTimeCountsAsZero() {
        let items = [
            RemoteItem(path: RemotePath(string: "/b"), kind: .file, size: 0, mtime: 0),
            RemoteItem(path: RemotePath(string: "/c"), kind: .file, size: 1, mtime: 1),
            RemoteItem(path: RemotePath(string: "/a"), kind: .file),
        ]
        #expect(ListingSort.apply(items, sort: SortConfiguration(column: "size")).map(\.name) == ["a", "b", "c"])
        #expect(ListingSort.apply(items, sort: SortConfiguration(column: "mtime", ascending: false)).map(\.name) == ["c", "a", "b"])
    }

    @Test func foldedNamesUseTheLiteralOrderOfTheOldSort() {
        let names = ["é", "E", "e\u{301}", "Z", "ß", "😀", "\u{E000}", "ﬁ", "İ", "a"]
        let items = names.map { RemoteItem(path: RemotePath(string: "/" + $0), kind: .file) }
        let sort = SortConfiguration(caseInsensitive: true)
        #expect(ListingSort.apply(items, sort: sort) == Self.reference(items, sort: sort))
    }

    // MARK: Fixtures

    /// Names from a small alphabet so that case-folded ties, shared prefixes, non-ASCII, and
    /// bytes that are not UTF-8 all turn up; sizes and times from a few values so columns tie.
    static func listing(count: Int, random: inout SplitMix, duplicates: Bool = false) -> [RemoteItem] {
        let pieces: [[UInt8]] = ["a", "A", "b", "B", "z", ".", "_", "1", "é", "É", "ß", "😀", "e\u{301}", "İ"].map { Array($0.utf8) }
            + [[0xE9], [0xFF], [0x80]]
        let kinds: [ItemKind] = [.file, .file, .directory, .symlink, .other]
        var seen: Set<[UInt8]> = []
        var items: [RemoteItem] = []
        while items.count < count {
            var name: [UInt8] = []
            for _ in 0...(random.next() % 4) { name += pieces[Int(random.next() % UInt64(pieces.count))] }
            guard duplicates || seen.insert(name).inserted else { continue }
            let kind = kinds[Int(random.next() % UInt64(kinds.count))]
            items.append(RemoteItem(path: RemotePath(string: "/srv").appending(name: name), kind: kind,
                                    size: random.next() % 4, mtime: UInt32(random.next() % 4), mode: UInt32(items.count)))
        }
        return items
    }

    /// The comparator ListingSort used before PERF-06. Its order is only defined for items
    /// with a size and a time (see `aMissingSizeOrTimeCountsAsZero`).
    static func reference(_ items: [RemoteItem], sort: SortConfiguration) -> [RemoteItem] {
        func compareNames(_ lhs: RemoteItem, _ rhs: RemoteItem) -> ComparisonResult {
            if sort.caseInsensitive {
                let folded = lhs.name.lowercased().compare(rhs.name.lowercased(), options: .literal)
                if folded != .orderedSame { return folded }
            }
            let left = lhs.path.nameBytes, right = rhs.path.nameBytes
            if left == right { return .orderedSame }
            return left.lexicographicallyPrecedes(right) ? .orderedAscending : .orderedDescending
        }
        return items.sorted { lhs, rhs in
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
                order = compareNames(lhs, rhs)
            }
            if order == .orderedSame {
                return compareNames(lhs, rhs) == .orderedAscending
            }
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}

/// A seeded generator, so a failure repeats.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
