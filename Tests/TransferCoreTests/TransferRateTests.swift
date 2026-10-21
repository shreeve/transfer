import Foundation
import Testing
@testable import TransferCore

/// Ten reports a second of `perSecond` bytes, at each tenth of a second in `tenths`, as the shelf
/// hears them; the bytes done at the last.
private func feed(_ rate: inout TransferRate, _ tenths: ClosedRange<Int>, perSecond: UInt64, startingAt bytes: UInt64 = 0) -> UInt64 {
    for tenth in tenths {
        rate.record(at: Double(tenth) / 10, completed: bytes + UInt64(tenth - tenths.lowerBound) * perSecond / 10)
    }
    return bytes + UInt64(tenths.count - 1) * perSecond / 10
}

@Test func aSteadyTransferReadsItsSpeedAndTimeLeft() throws {
    var rate = TransferRate()
    let done = feed(&rate, 0...100, perSecond: 10_000_000)
    let reading = try #require(rate.reading(at: 10, total: done + 1_200_000_000))
    #expect(abs(reading.bytesPerSecond - 10_000_000) < 1)
    #expect(abs(try #require(reading.secondsLeft) - 120) < 0.1)
    #expect(reading.text == "10 MB/s · about 2 minutes left")
}

@Test func nothingShowsUntilTwoSecondsOfReports() throws {
    var rate = TransferRate()
    _ = feed(&rate, 0...19, perSecond: 1_000_000)
    #expect(rate.reading(at: 1.9, total: 100_000_000) == nil)
    rate.record(at: 2, completed: 2_000_000)
    #expect(try #require(rate.reading(at: 2, total: 100_000_000)).text == "1.0 MB/s · about 2 minutes left")
}

@Test func aBurstMovesTheSpeedOnlyByItsShareOfTheWindow() throws {
    var rate = TransferRate()
    var done = feed(&rate, 0...100, perSecond: 10_000_000)
    // One second at five times the speed.
    done = feed(&rate, 101...110, perSecond: 50_000_000, startingAt: done + 5_000_000)
    let speed = try #require(rate.reading(at: 11, total: nil)).bytesPerSecond
    #expect(speed > 10_000_000 && speed < 20_000_000, "\(speed)")
    // And the window forgets it five seconds later.
    _ = feed(&rate, 111...170, perSecond: 10_000_000, startingAt: done + 1_000_000)
    #expect(abs(try #require(rate.reading(at: 17, total: nil)).bytesPerSecond - 10_000_000) < 1)
}

@Test func aStallFallsAwayAndThenReadsStalled() throws {
    var rate = TransferRate()
    _ = feed(&rate, 0...100, perSecond: 10_000_000)
    // No reports come while nothing moves: the speed falls with time alone.
    let paused = try #require(rate.reading(at: 12, total: nil)).bytesPerSecond
    #expect(paused < 7_000_000 && paused > 5_000_000, "\(paused)")
    #expect(rate.reading(at: 14.9, total: nil)?.stalled == false)
    let stalled = try #require(rate.reading(at: 15, total: 10_000_000_000_000))
    #expect(stalled.stalled && stalled.text == "Stalled" && stalled.timeLeft == nil)
    // Bytes again: the speed returns, and the stall is over.
    rate.record(at: 16, completed: 101_000_000)
    #expect(rate.reading(at: 16, total: nil)?.stalled == false)
}

@Test func aTransferThatHasNotMovedSinceItsFirstReportSaysNothingYet() {
    var rate = TransferRate()
    rate.record(at: 0, completed: 0)
    rate.record(at: 3, completed: 0)
    #expect(rate.reading(at: 3, total: 100) == nil)
    #expect(rate.reading(at: 5, total: 100)?.stalled == true)
}

@Test func anUnknownTotalShowsOnlyTheSpeed() throws {
    var rate = TransferRate()
    _ = feed(&rate, 0...50, perSecond: 1_200_000)
    let reading = try #require(rate.reading(at: 5, total: nil))
    #expect(reading.secondsLeft == nil && reading.timeLeft == nil)
    #expect(reading.text == "1.2 MB/s")
}

@Test func anEstimateTooLongToMeanAnythingIsLeftOut() throws {
    var rate = TransferRate()
    _ = feed(&rate, 0...50, perSecond: 1000)
    #expect(try #require(rate.reading(at: 5, total: 1_000_000_000)).text == "1.0 kB/s")
}

@Test func timeLeftIsWordedTheWayFinderWordsIt() {
    let cases: [(Double, String?)] = [
        (0, "a few seconds"), (4.9, "a few seconds"), (5, "about 5 seconds"), (7.4, "about 5 seconds"),
        (7.5, "about 10 seconds"), (54, "about 55 seconds"), (57.4, "about 55 seconds"), (57.5, "about 1 minute"),
        (89, "about 1 minute"), (90, "about 2 minutes"), (125, "about 2 minutes"), (3569, "about 59 minutes"),
        (3570, "about 1 hour"), (5399, "about 1 hour"), (5400, "about 2 hours"), (99 * 3600, "about 99 hours"),
        (99 * 3600 + 1, nil), (-1, nil), (.infinity, nil), (.nan, nil),
    ]
    for (seconds, words) in cases { #expect(TransferRate.words(seconds) == words, "\(seconds)") }
}

@Test func bytesThatGoBackwardsStartTheCountAgain() throws {
    var rate = TransferRate()
    _ = feed(&rate, 0...100, perSecond: 10_000_000)
    rate.record(at: 10.1, completed: 1_000)
    #expect(rate.reading(at: 11, total: nil) == nil)
    _ = feed(&rate, 102...160, perSecond: 1_000_000, startingAt: 2_000)
    #expect(abs(try #require(rate.reading(at: 16, total: nil)).bytesPerSecond - 1_000_000) < 1)
}

@Test func aNewRateStartsEmpty() {
    var rate = TransferRate()
    _ = feed(&rate, 0...100, perSecond: 10_000_000)
    rate = TransferRate()
    #expect(rate.reading(at: 10, total: nil) == nil)
    #expect(rate == TransferRate())
}

@Test func theWidestTextsHoldEveryReading() {
    // Every speed reads in at most eight characters, as "888 MB/s" does.
    for exponent in 0...12 {
        let speed = TransferRate.Reading(bytesPerSecond: pow(10, Double(exponent)) * 0.9995, secondsLeft: nil).speed
        #expect(speed.count <= "888 MB/s".count, "\(speed)")
    }
    // Every time left is "a few seconds" or "about", at most two digits, and a unit the slot was
    // sized for.
    for seconds in stride(from: 0.0, through: TransferRate.longestEstimate, by: 7) {
        guard let words = TransferRate.words(seconds) else { continue }
        let parts = words.split(separator: " ")
        #expect(words == "a few seconds" || (parts.count == 3 && parts[0] == "about" && parts[1].count <= 2
            && ["second", "seconds", "minute", "minutes", "hour", "hours"].contains(parts[2])), "\(words)")
    }
}
