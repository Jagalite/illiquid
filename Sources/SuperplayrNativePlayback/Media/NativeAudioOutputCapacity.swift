import Foundation

/// A small discovery snapshot shared with the decoder. It owns no renderer or
/// recovery policy. Unknown/unsupported routes deliberately retain stereo.
final class NativeAudioOutputCapacity: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: Int

    init(channels: Int = 2) { self.channels = Self.sanitized(channels) }

    @discardableResult
    func update(channels: Int) -> Bool {
        lock.withLock {
            let next = Self.sanitized(channels)
            guard next != self.channels else { return false }
            self.channels = next
            return true
        }
    }

    func outputChannels(forSourceChannels source: Int) -> Int {
        lock.withLock {
            if source >= 8, channels >= 8 { return 8 }
            if source >= 6, channels >= 6 { return 6 }
            return 2
        }
    }

    private static func sanitized(_ channels: Int) -> Int {
        channels >= 8 ? 8 : channels >= 6 ? 6 : 2
    }
}
