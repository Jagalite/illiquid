#if !canImport(CoreMedia)
import Foundation

// Test-only Linux boundary shim. The benchmark uses finite, epoch-zero media
// times with small positive timescales. This lets the unmodified PCM ownership
// and timeline code run against Foundation; it does not validate CoreMedia's
// clock behavior. macOS builds use the real CoreMedia implementation instead.
struct CMTimeFlags: OptionSet, Sendable {
    let rawValue: UInt32
    static let valid = CMTimeFlags(rawValue: 1)
    static let hasBeenRounded = CMTimeFlags(rawValue: 2)
}

struct CMTime: Equatable, Sendable {
    let value: Int64
    let timescale: Int32
    let flags: CMTimeFlags
    let epoch: Int64

    init(value: Int64, timescale: Int32) {
        precondition(timescale > 0)
        self.init(value: value, timescale: timescale, flags: .valid)
    }

    init(seconds: Double, preferredTimescale: Int32) {
        precondition(seconds.isFinite && preferredTimescale > 0)
        let scaled = seconds * Double(preferredTimescale)
        let rounded = scaled.rounded()
        guard let value = Int64(exactly: rounded) else {
            preconditionFailure("Boundary shim only supports finite, representable test times")
        }
        self.init(value: value, timescale: preferredTimescale,
                  flags: scaled == rounded ? .valid : [.valid, .hasBeenRounded])
    }

    fileprivate init(value: Int64, timescale: Int32, flags: CMTimeFlags) {
        self.value = value
        self.timescale = timescale
        self.flags = flags
        epoch = 0
    }

    var seconds: Double { Double(value) / Double(timescale) }
    static let zero = CMTime(value: 0, timescale: 1)

    static func == (lhs: Self, rhs: Self) -> Bool {
        let scale = commonTimescale(lhs, rhs)
        return lhs.epoch == rhs.epoch
            && lhs.value * (scale / Int64(lhs.timescale))
                == rhs.value * (scale / Int64(rhs.timescale))
    }
}

private func commonTimescale(_ lhs: CMTime, _ rhs: CMTime) -> Int64 {
    var a = Int64(lhs.timescale)
    var b = Int64(rhs.timescale)
    while b != 0 { (a, b) = (b, a % b) }
    return Int64(lhs.timescale) / a * Int64(rhs.timescale)
}

func CMTimeAdd(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
    let scale = commonTimescale(lhs, rhs)
    guard let timescale = Int32(exactly: scale) else {
        preconditionFailure("Boundary shim only supports small test timescales")
    }
    return CMTime(
        value: lhs.value * (scale / Int64(lhs.timescale))
            + rhs.value * (scale / Int64(rhs.timescale)),
        timescale: timescale,
        flags: lhs.flags.union(rhs.flags)
    )
}
#endif
