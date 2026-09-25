import Foundation

/// One value behind a lock, for state that tasks, callbacks, and threads share. Every read and
/// change holds the lock; `withLock` makes a read-modify-write one step.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    public init(_ value: Value) {
        stored = value
    }

    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&stored) }
    }

    public var value: Value {
        get { withLock { $0 } }
        set { withLock { $0 = newValue } }
    }
}
