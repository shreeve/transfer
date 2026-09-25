import Foundation

/// The READ requests a download sends, for one that keeps several in flight. A server may answer
/// a READ with fewer bytes than were asked for, and the draft says nothing about why, so a short
/// reply is not the end of the file: the rest of its range is asked for again. Only an EOF
/// status, or a reply with no bytes, says the file ends there.
public struct ReadPlan: Sendable {
    public let size: UInt64
    public static let chunk: UInt32 = 65_536
    /// Bytes written so far. The ranges never overlap, so this is also how much of the file is
    /// covered.
    public private(set) var received: UInt64 = 0
    private var next: UInt64 = 0
    private var remainders: [(offset: UInt64, length: UInt32)] = []
    private var ended = false
    private var furthest: UInt64 = 0

    public init(size: UInt64) {
        self.size = size
    }

    /// The next range to ask for: the rest of a short reply first, then fresh ranges until the
    /// listed size, or until the file is known to end sooner. Nil when nothing is left to ask.
    public mutating func nextRequest() -> (offset: UInt64, length: UInt32)? {
        if !remainders.isEmpty { return remainders.removeFirst() }
        guard !ended, next < size else { return nil }
        let length = UInt32(min(UInt64(Self.chunk), size - next))
        defer { next += UInt64(length) }
        return (next, length)
    }

    /// A reply of `count` bytes to a READ of `length` at `offset`. The caller refuses a reply
    /// longer than was asked for.
    public mutating func record(offset: UInt64, length: UInt32, count: UInt32) {
        precondition(count <= length, "a READ reply longer than the request")
        guard count > 0 else {
            ended = true
            return
        }
        received += UInt64(count)
        furthest = max(furthest, offset + UInt64(count))
        if count < length { remainders.append((offset + UInt64(count), length - count)) }
    }

    /// The server answered EOF: the file is shorter than its listed size.
    public mutating func endOfFile() {
        ended = true
    }

    /// Whether the bytes written are the whole file with no gap: every listed byte, or, when the
    /// file turned out shorter, every byte up to the furthest one written.
    public var isComplete: Bool {
        ended ? received == furthest : received == size
    }
}
