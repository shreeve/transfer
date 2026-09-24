import Testing
import TransferCore

/// A download against a server that answers READs from a file of `length` bytes, at most `cap`
/// bytes a reply, keeping up to `window` requests in flight and answering the oldest first, as
/// the download loop does. Returns the plan and the bytes it covered.
private func download(size: UInt64, length: UInt64, cap: UInt32, window: Int = 32) -> (ReadPlan, [Bool]) {
    var plan = ReadPlan(size: size)
    var covered = [Bool](repeating: false, count: Int(max(size, length)))
    var inFlight: [(offset: UInt64, length: UInt32)] = []
    while true {
        while inFlight.count < window, let request = plan.nextRequest() { inFlight.append(request) }
        guard !inFlight.isEmpty else { break }
        let read = inFlight.removeFirst()
        guard read.offset < length else {
            plan.endOfFile()
            continue
        }
        let count = UInt32(min(UInt64(min(read.length, cap)), length - read.offset))
        for i in 0..<Int(count) { covered[Int(read.offset) + i] = true }
        plan.record(offset: read.offset, length: read.length, count: count)
    }
    return (plan, covered)
}

/// A server that caps its replies below 64 KB once crashed the download or left a hole of zeroes.
@Test func shortReadsAreAskedForAgainUntilTheFileIsWhole() {
    for size: UInt64 in [0, 1, 20_000, 65_536, 131_072, 131_073, 1_000_000] {
        let (plan, covered) = download(size: size, length: size, cap: 20_000)
        #expect(plan.isComplete)
        #expect(plan.received == size)
        #expect(covered.allSatisfy { $0 })
    }
}

@Test func aFileShorterThanItsListingEndsAtEOF() {
    let (plan, covered) = download(size: 300_000, length: 170_000, cap: 65_536)
    #expect(plan.isComplete)
    #expect(plan.received == 170_000)
    #expect(covered.prefix(170_000).allSatisfy { $0 })
}

@Test func aGapLeftByAnEarlyEOFIsNotComplete() {
    var plan = ReadPlan(size: 200_000)
    let first = plan.nextRequest()!
    let second = plan.nextRequest()!
    // The server says EOF for the first range but sends bytes for the second.
    plan.endOfFile()
    plan.record(offset: second.offset, length: second.length, count: second.length)
    #expect(first.offset == 0)
    #expect(!plan.isComplete)
}

@Test func anEmptyReplyEndsTheFile() {
    var plan = ReadPlan(size: 100)
    let request = plan.nextRequest()!
    plan.record(offset: request.offset, length: request.length, count: 0)
    #expect(plan.nextRequest() == nil)
    #expect(plan.isComplete)
    #expect(plan.received == 0)
}
