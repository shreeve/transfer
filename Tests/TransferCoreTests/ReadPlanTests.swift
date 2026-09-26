import Testing
import TransferCore

/// A download against a server that answers READs from a file of `length` bytes, at most `cap`
/// bytes a reply, keeping up to `window` requests in flight and answering the oldest first, as
/// the download loop does. With a seed, it answers them in random order, each reply capped
/// anywhere up to `cap`. Returns the plan and the bytes it covered.
private func download(size: UInt64, length: UInt64, cap: UInt32, window: Int = 32, seed: UInt64? = nil) -> (ReadPlan, [Bool]) {
    var random = seed.map(SeededRandom.init)
    var plan = ReadPlan(size: size)
    var covered = [Bool](repeating: false, count: Int(max(size, length)))
    var inFlight: [(offset: UInt64, length: UInt32)] = []
    while true {
        while inFlight.count < window, let request = plan.nextRequest() { inFlight.append(request) }
        guard !inFlight.isEmpty else { break }
        let read = inFlight.remove(at: (random?.next()).map { Int($0 % UInt64(inFlight.count)) } ?? 0)
        guard read.offset < length else {
            plan.endOfFile()
            continue
        }
        let most = (random?.next()).map { UInt32(1 + $0 % UInt64(cap)) } ?? cap
        let count = UInt32(min(UInt64(min(read.length, most)), length - read.offset))
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

/// Replies in any order, at any size, from files shorter or longer than listed: the whole file
/// arrives, each byte once.
@Test func aDownloadIsWholeWhateverOrderTheRepliesComeIn() {
    var random = SeededRandom(state: 5)
    for seed: UInt64 in 0..<100 {
        let size = random.next() % 150_000
        let length = random.next() % 3 == 0 ? random.next() % 150_000 : size
        let (plan, covered) = download(size: size, length: length, cap: UInt32(1_024 + random.next() % 70_000), window: 1 + Int(random.next() % 40), seed: seed)
        #expect(plan.received == UInt64(covered.count(where: \.self)), "a byte written twice")
        #expect(plan.isComplete, "size \(size), length \(length)")
        #expect(covered.prefix(Int(min(size, length))).allSatisfy { $0 })
    }
}
