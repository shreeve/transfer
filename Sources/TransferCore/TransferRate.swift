import Foundation

/// A running transfer's speed and time left, from the (time, bytes done) progress it reports:
/// "12 MB/s · about 2 minutes left". One per attempt: a Restart or a Retry starts a new one.
///
/// The speed is the bytes done over the last `window` seconds divided by that span, measured up to
/// the moment it is read, not to the last report. At ten reports a second that is about fifty
/// samples, so a one-second burst moves the number by a fifth of its excess and a short pause
/// (an SFTP round trip, a disk flush) barely at all, while a real change of speed shows within a
/// few seconds. Reading to now, not to the last report, is what lets a stall show: no reports come
/// while nothing moves, and the speed falls to zero across the window, at which point the transfer
/// reads Stalled (`stallAfter` equals `window` for that reason) instead of a time left of days.
public struct TransferRate: Hashable, Sendable {
    /// How far back the speed looks, in seconds.
    public static let window: Double = 5
    /// How long after its first report a transfer says anything: the first moments are the 2 MB
    /// pipeline filling and the first file opening, which overstate and understate the speed.
    public static let warmup: Double = 2
    /// How long without a new byte before the transfer reads Stalled.
    public static let stallAfter: Double = 5
    /// The longest time left worth saying; past it the row shows only its speed.
    public static let longestEstimate: Double = 99 * 3600

    private struct Sample: Hashable, Sendable {
        var time: Double
        var bytes: UInt64
    }

    /// The window's samples, oldest first, and the last one before it, from which the bytes done
    /// as the window opened are read.
    private var samples: [Sample] = []
    /// The first report's time, for the warm-up.
    private var first: Double?
    /// When the bytes done last grew.
    private var advanced: Double?

    public init() {}

    /// Adds a report. Bytes done that go backwards (a file started over) begin the count again.
    public mutating func record(at time: Double, completed: UInt64) {
        if let last = samples.last, completed < last.bytes || time < last.time {
            self = TransferRate()
        }
        if let last = samples.last {
            if completed > last.bytes { advanced = time }
        } else {
            first = time
            advanced = time
        }
        samples.append(Sample(time: time, bytes: completed))
        // Keep one sample at or before the window's start: the bytes done as it opened.
        let start = time - Self.window
        if let kept = samples.lastIndex(where: { $0.time <= start }), kept > 0 {
            samples.removeFirst(kept)
        }
    }

    /// What the row says at `now`, for a transfer of `total` bytes when that is known; nil until
    /// the warm-up has passed.
    public func reading(at now: Double, total: UInt64?) -> Reading? {
        guard let first, let advanced, let last = samples.last, now - first >= Self.warmup else { return nil }
        if now - advanced >= Self.stallAfter { return .stalled }
        let start = max(first, now - Self.window)
        let span = now - start
        guard span > 0 else { return nil }
        let speed = max(0, Double(last.bytes) - bytes(at: start)) / span
        // Nothing has moved since the first report, but not yet for long enough to call it stalled.
        guard speed > 0 else { return nil }
        var left: Double?
        if let total, total >= last.bytes {
            left = Double(total - last.bytes) / speed
        }
        return Reading(bytesPerSecond: speed, secondsLeft: left)
    }

    /// The bytes done at `time`, between the reports either side of it, so the speed slides
    /// smoothly as the window moves rather than stepping a report at a time.
    private func bytes(at time: Double) -> Double {
        guard let after = samples.firstIndex(where: { $0.time > time }) else { return Double(samples.last?.bytes ?? 0) }
        guard after > 0 else { return Double(samples[0].bytes) }
        let (earlier, later) = (samples[after - 1], samples[after])
        let share = (time - earlier.time) / (later.time - earlier.time)
        return Double(earlier.bytes) + share * (Double(later.bytes) - Double(earlier.bytes))
    }

    public struct Reading: Hashable, Sendable {
        /// Zero when stalled.
        public var bytesPerSecond: Double
        /// Nil when the total is unknown, and when stalled.
        public var secondsLeft: Double?
        public var stalled: Bool

        public init(bytesPerSecond: Double, secondsLeft: Double?) {
            self.bytesPerSecond = bytesPerSecond
            self.secondsLeft = secondsLeft
            stalled = false
        }

        public static let stalled: Reading = {
            var reading = Reading(bytesPerSecond: 0, secondsLeft: nil)
            reading.stalled = true
            return reading
        }()

        /// "12 MB/s", in the sizes' own three characters.
        public var speed: String {
            Units.bytes(UInt64(bytesPerSecond.rounded())).trimmingCharacters(in: .whitespaces) + "/s"
        }

        /// "about 2 minutes left", or nil when there is nothing worth saying.
        public var timeLeft: String? {
            secondsLeft.flatMap(TransferRate.words).map { "\($0) left" }
        }

        /// "12 MB/s · about 2 minutes left", "12 MB/s", or "Stalled".
        public var text: String {
            if stalled { return "Stalled" }
            return [speed, timeLeft].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// A time left the way Finder words it: "a few seconds" under 5 s, then "about 5 seconds" in
    /// steps of five, "about 1 minute", "about 2 minutes", "about 1 hour", rounded to the nearest
    /// step; nil past `longestEstimate`, or for a time that is not a number.
    public static func words(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0, seconds <= longestEstimate else { return nil }
        if seconds < 5 { return "a few seconds" }
        let fives = Int((seconds / 5).rounded()) * 5
        if fives < 60 { return "about \(fives) seconds" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return minutes == 1 ? "about 1 minute" : "about \(minutes) minutes" }
        let hours = Int((seconds / 3600).rounded())
        return hours == 1 ? "about 1 hour" : "about \(hours) hours"
    }

    /// The widest texts a reading can make, for a slot as wide as the widest of them, which then
    /// never changes size as the numbers do.
    public static let widestTexts = [
        "888 MB/s · about 88 seconds left",
        "888 MB/s · about 88 minutes left",
        "888 MB/s · about 88 hours left",
        "888 MB/s · a few seconds left",
    ]
}
