import TransferCore

enum PerformanceDirectoryCopy {
    static func available() -> Bool { false }

    static func refused() -> TransferError { .performanceUnavailable }
}
