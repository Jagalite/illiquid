import Foundation

private struct Generator {
    var state: UInt64 = 0x7468756D626E6169

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

@main
enum Validate {
    static func main() {
        var checks = 0
        func check(duration: Double, focus: Double, count: Int) {
            let baseline = BaselineThumbnailPolicy.samples(duration: duration, focus: focus, count: count)
            let candidate = ThumbnailPolicy.samples(duration: duration, focus: focus, count: count)
            guard baseline.map(\.bitPattern) == candidate.map(\.bitPattern) else {
                fatalError("Mismatch: duration=\(duration), focus=\(focus), count=\(count), "
                    + "baseline=\(baseline), candidate=\(candidate)")
            }
            checks += 1
        }
        let durations: [Double] = [
            -.infinity, -.greatestFiniteMagnitude, -1, -0.0, 0,
            .leastNonzeroMagnitude, .leastNormalMagnitude,
            0.1, 0.49, 0.5, 0.51, 0.75, 1, 1.4, 2.1, 7.9, 30, 64, 120, 7_200,
            86_400, 1e16, .greatestFiniteMagnitude / 256,
            .greatestFiniteMagnitude / 2, .greatestFiniteMagnitude, .infinity, .nan,
        ]
        let counts = [Int.min, -10, -1, 0] + Array(1...66) + [128, Int.max]
        for duration in durations {
            let focuses: [Double] = [
                -.infinity, -.greatestFiniteMagnitude, -1, -0.0, 0,
                .leastNonzeroMagnitude, 0.24, 0.25, 0.26, 42.3,
                duration / 2, duration.nextDown, duration, duration.nextUp,
                .greatestFiniteMagnitude, .infinity, .nan,
            ]
            for focus in focuses {
                for count in counts {
                    check(duration: duration, focus: focus, count: count)
                }
            }
            guard BaselineThumbnailPolicy.storyboard(duration: duration).map(\.bitPattern)
                == ThumbnailPolicy.storyboard(duration: duration).map(\.bitPattern) else {
                fatalError("Storyboard mismatch for \(duration)")
            }
            checks += 1
        }
        var random = Generator()
        for index in 0..<20_000 {
            let duration: Double
            let focus: Double
            if index.isMultiple(of: 2) {
                duration = Double(random.next() % 1_440_001) / 100
                focus = Double(Int(random.next() % 2_000_001) - 200_000) / 100
            } else {
                duration = Double(bitPattern: random.next())
                focus = Double(bitPattern: random.next())
            }
            check(duration: duration, focus: focus, count: Int(random.next() % 96) - 8)
        }
        print("{\"differential_cases\":\(checks),\"bitwise_equal\":true}")
    }
}
