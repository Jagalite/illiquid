import Foundation
import Testing
@testable import IlliquidCore

@Suite("Thumbnail sample planning")
struct ThumbnailSamplePlanningTests {
    @Test func goldenPriorityAndPrefixBoundaries() {
        #expect(ThumbnailPolicy.samples(duration: 120, focus: 42.3, count: 12) ==
            [42.5, 0, 60, 30, 90, 15, 45, 75, 105, 7.5, 22.5, 37.5])
        let ordered: [Double] = [
            0, 64, 32, 96, 16, 48, 80, 112, 8, 24, 40, 56, 72, 88, 104, 120,
            4, 12, 20, 28, 36, 44, 52, 60, 68, 76, 84, 92, 100, 108, 116, 124
        ]
        for count in [1, 2, 3, 4, 7, 8, 9, 12, 15, 16, 17, 24, 31, 32] {
            #expect(ThumbnailPolicy.samples(duration: 128, focus: 0, count: count) ==
                Array(ordered.prefix(count)))
        }
        #expect(ThumbnailPolicy.samples(duration: 2, focus: 99, count: 24) ==
            [1.5, 0, 1, 0.5])
    }

    @Test func countsClampWithoutChangingTheFirstSample() {
        for count in [Int.min, -1, 0, 1] {
            #expect(ThumbnailPolicy.samples(duration: 120, focus: 42.3, count: count) == [42.5])
        }
        let full = ThumbnailPolicy.samples(duration: 128, focus: 0, count: 64)
        #expect(full.count == 64)
        for count in [63, 64, 65, Int.max] {
            #expect(ThumbnailPolicy.samples(duration: 128, focus: 0, count: count) ==
                Array(full.prefix(min(count, 64))))
            expectParity(duration: 128, focus: 0, count: count)
        }
    }

    @Test func exhaustedHalfSecondPositionsPreservePriority() {
        for duration in [Double.leastNonzeroMagnitude, 0.1, 0.5, 1.0.nextDown] {
            for focus in [-1.0, 0, 0.25, 99, .nan, .infinity] {
                for count in [1, 6, 12, 24, 64] {
                    #expect(ThumbnailPolicy.samples(duration: duration, focus: focus, count: count) == [0])
                }
            }
        }
        #expect(ThumbnailPolicy.samples(duration: 1, focus: 0, count: 64) == [0, 0.5])
        #expect(ThumbnailPolicy.samples(duration: 1.5, focus: 0, count: 64) == [0, 1, 0.5])
        #expect(ThumbnailPolicy.samples(duration: 2, focus: 0, count: 64) == [0, 1, 0.5, 1.5])
    }

    @Test func invalidAndExtremeValuesMatchTheOriginalPolicy() {
        let invalid: [Double] = [-.infinity, -.greatestFiniteMagnitude, -1, -0.0, 0, .infinity, .nan]
        for duration in invalid {
            for count in [Int.min, 1, 24, Int.max] {
                #expect(ThumbnailPolicy.samples(duration: duration, focus: 42.3, count: count).isEmpty)
            }
        }
        let durations: [Double] = [.leastNonzeroMagnitude, .leastNormalMagnitude,
            .greatestFiniteMagnitude / 4, .greatestFiniteMagnitude / 2, .greatestFiniteMagnitude]
        let focuses: [Double] = [-.greatestFiniteMagnitude, -0.0, 0,
            .greatestFiniteMagnitude, -.infinity, .infinity, .nan]
        for duration in durations {
            for focus in focuses {
                for count in [Int.min, 0, 1, 2, 12, 24, 63, 64, 65, Int.max] {
                    expectParity(duration: duration, focus: focus, count: count)
                }
            }
        }
    }

    @Test func everyHalfSecondDurationBoundaryThroughThirtyTwoAndAHalfSeconds() {
        // 66 boundaries x 3 adjacent doubles x 7 focuses x 9 counts = 12,474 comparisons.
        for halfStep in 0...65 {
            let boundary = Double(halfStep) / 2
            for duration in [boundary.nextDown, boundary, boundary.nextUp] {
                let focuses: [Double] = [-1, -0.0, 0.25, duration / 2,
                    duration - 0.25, duration, .nan]
                for focus in focuses {
                    for count in [0, 1, 2, 6, 12, 24, 33, 64, Int.max] {
                        expectParity(duration: duration, focus: focus, count: count)
                    }
                }
            }
        }
    }

    @Test func seededFloatingPointBitPatternsPreserveExactOutputs() {
        var random = SamplePlanningRandomBits()
        let counts = [Int.min, -1, 0, 1, 2, 6, 12, 24, 31, 32, 33, 63, 64, 65, Int.max]
        for index in 0..<5_000 {
            let bits = random.next()
            let duration = Double(bitPattern: index.isMultiple(of: 2)
                ? bits : bits & 0x7fff_ffff_ffff_ffff)
            let focus = Double(bitPattern: random.next())
            let countBits = random.next()
            let count = index.isMultiple(of: 4) ? Int(truncatingIfNeeded: countBits)
                : counts[Int(countBits % UInt64(counts.count))]
            expectParity(duration: duration, focus: focus, count: count)
        }
    }

    private func expectParity(duration: Double, focus: Double, count: Int) {
        let actual = ThumbnailPolicy.samples(duration: duration, focus: focus, count: count)
        let expected = FrozenThumbnailSamples.samples(duration: duration, focus: focus, count: count)
        #expect(actual.map(\.bitPattern) == expected.map(\.bitPattern),
            "duration bits \(duration.bitPattern), focus bits \(focus.bitPattern), count \(count)")
    }
}

private struct SamplePlanningRandomBits {
    private var state: UInt64 = 0x51a7_2026_1028_0064
    init() {}
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }
}

// Declaration and body copied verbatim from ThumbnailPolicy.swift at
// ea2ff568237e2667f7b1aeee67b11a44ebe95b72. Keep this oracle independent of production edits.
private enum FrozenThumbnailSamples {
    public static func samples(duration: Double, focus: Double, count: Int) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        let last = max(0, floor((duration - 0.5) * 2) / 2)
        var result: [Double] = []
        func add(_ value: Double) {
            let time = min(last, max(0, (value * 2).rounded() / 2))
            if !result.contains(time) { result.append(time) }
        }
        add(focus.isFinite ? focus : 0)
        add(0)
        var divisions = 2
        while result.count < min(max(count, 1), 64), divisions <= 128 {
            for numerator in stride(from: 1, to: divisions, by: 2) {
                add(duration * Double(numerator) / Double(divisions))
            }
            divisions *= 2
        }
        return Array(result.prefix(min(max(count, 1), 64)))
    }
}
