import Foundation

/// Monotonic media identity used across file replacements and seeks.
final class PlaybackGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.withLock { value }
    }

    @discardableResult
    func advance() -> Int {
        lock.withLock {
            value &+= 1
            return value
        }
    }

    func accepts(_ candidate: Int) -> Bool {
        lock.withLock { candidate == value }
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
