import CFFmpeg
import CoreMedia
import Foundation

struct FFmpegRational: Equatable, Sendable {
    let numerator: Int32
    let denominator: Int32

    init(_ value: AVRational) {
        numerator = value.num
        denominator = value.den
    }

    init(numerator: Int32, denominator: Int32) {
        self.numerator = numerator
        self.denominator = denominator
    }

    var isValid: Bool {
        numerator != 0 && denominator > 0
    }
}

enum MediaTime {
    static func cmTime(
        _ timestamp: Int64,
        timeBase: FFmpegRational
    ) -> CMTime {
        guard timestamp != Int64.min, timeBase.isValid else { return .invalid }
        return CMTime(
            value: timestamp * Int64(timeBase.numerator),
            timescale: timeBase.denominator
        )
    }

    static func timestamp(
        _ time: CMTime,
        timeBase: FFmpegRational,
        rounding: CMTimeRoundingMethod = .roundTowardZero
    ) -> Int64 {
        guard time.isNumeric, timeBase.isValid else { return 0 }
        let scaled = CMTimeConvertScale(
            time,
            timescale: timeBase.denominator,
            method: rounding
        )
        return scaled.value / Int64(timeBase.numerator)
    }

    static func seconds(_ timestamp: Int64, timeBase: FFmpegRational) -> Double {
        guard timestamp != Int64.min, timeBase.isValid else { return 0 }
        return Double(timestamp)
            * Double(timeBase.numerator)
            / Double(timeBase.denominator)
    }
}
