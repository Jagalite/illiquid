// Linux-only component-test shim. Native runs import Apple's CoreMedia.
// This implements the small rational-time subset used by the extracted audio
// frame and delay timeline. It does not qualify CoreMedia or native playback.
import Foundation

public struct CMTime: Equatable, Sendable {
    public let value: Int64
    public let timescale: Int32
    public static let zero = CMTime(value: 0, timescale: 1)
    public static let invalid = CMTime(value: 0, timescale: 0)

    public init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    public init(seconds: Double, preferredTimescale: Int32) {
        guard seconds.isFinite, preferredTimescale > 0 else {
            self = .invalid
            return
        }
        self.init(value: Int64((seconds * Double(preferredTimescale)).rounded()),
                  timescale: preferredTimescale)
    }

    public var isNumeric: Bool { timescale > 0 }
    public var seconds: Double { isNumeric ? Double(value) / Double(timescale) : .nan }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.isNumeric, rhs.isNumeric else { return !lhs.isNumeric && !rhs.isNumeric }
        return lhs.value * Int64(rhs.timescale) == rhs.value * Int64(lhs.timescale)
    }
}

public func CMTimeAdd(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
    guard lhs.isNumeric, rhs.isNumeric else { return .invalid }
    var a = Int64(lhs.timescale), b = Int64(rhs.timescale)
    while b != 0 { (a, b) = (b, a % b) }
    let scale = Int64(lhs.timescale) / a * Int64(rhs.timescale)
    precondition(scale <= Int64(Int32.max), "Fixture timescale exceeds shim range")
    return CMTime(value: lhs.value * (scale / Int64(lhs.timescale))
                    + rhs.value * (scale / Int64(rhs.timescale)), timescale: Int32(scale))
}

public func CMTimeSubtract(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
    CMTimeAdd(lhs, CMTime(value: -rhs.value, timescale: rhs.timescale))
}

public func CMTimeCompare(_ lhs: CMTime, _ rhs: CMTime) -> Int32 {
    if lhs == rhs { return 0 }
    return lhs.seconds < rhs.seconds ? -1 : 1
}
