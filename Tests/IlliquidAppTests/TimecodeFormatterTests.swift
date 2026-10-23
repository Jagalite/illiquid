import Foundation
import Testing
@testable import IlliquidApp

@Suite("Playback timecode formatting")
struct TimecodeFormatterTests {
    @Test func invalidIntervalsKeepTheExistingPlaceholder() {
        let intervals: [TimeInterval] = [
            .nan, .infinity, -.infinity, -1, -0.5, -Double.leastNonzeroMagnitude,
        ]
        for interval in intervals {
            #expect(TimecodeFormatter.string(from: interval) == "0:00")
        }
    }

    @Test func goldenValuesPreservePaddingFractionsAndHourBoundaries() {
        let cases: [(TimeInterval, String)] = [
            (-0.0, "00:00"),
            (0, "00:00"),
            (Double.leastNonzeroMagnitude, "00:00"),
            (0.999, "00:00"),
            (1, "00:01"),
            (9.999, "00:09"),
            (10, "00:10"),
            (59.999, "00:59"),
            (60, "01:00"),
            (61.9, "01:01"),
            (599.9, "09:59"),
            (600, "10:00"),
            (3_599.999, "59:59"),
            (3_600, "1:00:00"),
            (3_601.9, "1:00:01"),
            (35_999, "9:59:59"),
            (36_000, "10:00:00"),
            (86_400, "24:00:00"),
            (359_999, "99:59:59"),
            (360_000, "100:00:00"),
        ]
        for (interval, expected) in cases {
            #expect(TimecodeFormatter.string(from: interval) == expected)
        }
    }

    @Test func allMinuteAndSecondPairsMatchTheFoundationReference() {
        // Exercise every cached component at several hour digit widths. The
        // reference retains the original formatting call, not the lookup table.
        for hours in [0, 1, 9, 10, 99, 100, 999, 1_000, 1_000_000] {
            for remainder in 0..<3_600 {
                let interval = Double(hours * 3_600 + remainder) + 0.625
                #expect(TimecodeFormatter.string(from: interval) == legacyString(from: interval))
            }
        }
    }

    @Test func adjacentFloatingPointValuesKeepFlooringAtBoundaries() {
        let boundaries: [TimeInterval] = [
            1, 10, 59, 60, 61, 599, 600, 3_599, 3_600, 3_601,
            35_999, 36_000, 359_999, 360_000, 3_600_000_000,
        ]
        for boundary in boundaries {
            for interval in [boundary.nextDown, boundary, boundary.nextUp] {
                #expect(TimecodeFormatter.string(from: interval) == legacyString(from: interval))
            }
        }
    }

    @Test func largeRepresentableIntervalsKeepTheLegacyHourField() {
        // `%d` narrows its hour argument; ordinary String interpolation would
        // change these existing outputs. Stay inside the original Int domain.
        let hourCounts: [Int] = [
            Int(Int32.max) - 1, Int(Int32.max), Int(Int32.max) + 1,
            Int(UInt32.max), Int(UInt32.max) + 1,
        ]
        for hours in hourCounts {
            for remainder in [0, 1, 59, 60, 3_599] {
                let interval = Double(hours * 3_600 + remainder)
                for value in [interval.nextDown, interval, interval.nextUp] {
                    #expect(TimecodeFormatter.string(from: value) == legacyString(from: value))
                }
            }
        }
        let largestRepresentableIntInterval = Double(Int.max).nextDown
        #expect(TimecodeFormatter.string(from: largestRepresentableIntInterval)
            == legacyString(from: largestRepresentableIntInterval))
    }

    private func legacyString(from interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00" }
        let totalSeconds = Int(interval.rounded(.down))
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3_600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
