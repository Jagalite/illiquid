import Foundation
import Testing
@testable import IlliquidCore

@Suite("Video color region averages")
struct VideoColorSampleAverageTests {
    private func bits(_ color: SampledVideoColor) -> [UInt64] {
        [color.red.bitPattern, color.green.bitPattern, color.blue.bitPattern]
    }

    private func sample(columns: Int, rows: Int) -> VideoColorSample {
        let colors = (0..<(columns * rows)).map { index in
            SampledVideoColor(
                red: Double((index * 37 + 11) % 257) / 256,
                green: Double((index * 73 + 19) % 251) / 250,
                blue: Double((index * 17 + 23) % 241) / 240
            )
        }
        return VideoColorSample(columns: columns, rows: rows, colors: colors)
    }

    // Enumerate storage in row-major order and select membership independently
    // of the implementation's nested coordinate loops.
    private func reference(
        _ sample: VideoColorSample, _ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int
    ) -> SampledVideoColor {
        func bounded(_ value: Int, size: Int) -> Int {
            if value < 0 { return 0 }
            if value >= size { return size - 1 }
            return value
        }
        let left = bounded(x0, size: sample.columns)
        let right = max(left, bounded(x1, size: sample.columns))
        let top = bounded(y0, size: sample.rows)
        let bottom = max(top, bounded(y1, size: sample.rows))
        var red = 0.0, green = 0.0, blue = 0.0
        var count = 0
        for (index, color) in sample.colors.enumerated() {
            let x = index % sample.columns, y = index / sample.columns
            if x >= left && x <= right && y >= top && y <= bottom {
                red += color.red
                green += color.green
                blue += color.blue
                count += 1
            }
        }
        return SampledVideoColor(
            red: red / Double(count), green: green / Double(count), blue: blue / Double(count)
        )
    }

    @Test func explicitRectanglesSelectTheSpecifiedCells() {
        let value = sample(columns: 3, rows: 2)
        let cases: [(Int, Int, Int, Int, [Int])] = [
            (1, 2, 0, 1, [1, 2, 4, 5]),
            (1, 1, 1, 1, [4]),
            (2, 0, 0, 1, [2, 5]),
            (0, 2, 1, 0, [3, 4, 5]),
            (2, 0, 1, 0, [5]),
            (Int.min, -1, Int.min, -1, [0]),
            (Int.max, Int.max, Int.max, Int.max, [5]),
            (Int.min, Int.max, Int.min, Int.max, [0, 1, 2, 3, 4, 5]),
            (Int.max, Int.min, Int.max, Int.min, [5]),
            (-10, 1, 0, 99, [0, 1, 3, 4]),
        ]
        for (x0, x1, y0, y1, indices) in cases {
            var red = 0.0, green = 0.0, blue = 0.0
            for index in indices {
                red += value.colors[index].red
                green += value.colors[index].green
                blue += value.colors[index].blue
            }
            let expected = SampledVideoColor(
                red: red / Double(indices.count),
                green: green / Double(indices.count),
                blue: blue / Double(indices.count)
            )
            #expect(bits(value.average(
                minimumColumn: x0, maximumColumn: x1, minimumRow: y0, maximumRow: y1
            )) == bits(expected))
        }
    }

    @Test func reversedBoundsCollapseAtTheClampedMinimum() {
        let value = sample(columns: 12, rows: 8)
        let result = value.average(
            minimumColumn: 9, maximumColumn: -8, minimumRow: 6, maximumRow: 1
        )
        #expect(bits(result) == bits(value.colors[6 * 12 + 9]))
    }

    @Test func extremeAndOutOfRangeBoundsPreserveTheirMeaning() {
        let value = sample(columns: 12, rows: 8)
        for rectangle in [
            (Int.min, Int.max, Int.min, Int.max),
            (Int.max, Int.min, Int.max, Int.min),
            (-500, -1, -200, -1), (500, 700, 200, 300),
            (-3, 2, 5, 30), (4, 7, 2, 4),
        ] {
            let (x0, x1, y0, y1) = rectangle
            #expect(bits(value.average(
                minimumColumn: x0, maximumColumn: x1, minimumRow: y0, maximumRow: y1
            )) == bits(reference(value, x0, x1, y0, y1)))
        }
    }

    @Test func deterministicRectanglesMatchTheExactRowMajorReference() {
        var random: UInt64 = 0xA1DB02
        func next() -> UInt64 {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return random
        }
        for (columns, rows) in [(1, 1), (1, 8), (12, 1), (12, 8), (17, 11)] {
            let value = sample(columns: columns, rows: rows)
            let xs = [Int.min, -25, -1, 0, 1, columns / 2, columns - 1, columns, columns + 1, Int.max]
            let ys = [Int.min, -25, -1, 0, 1, rows / 2, rows - 1, rows, rows + 1, Int.max]
            for _ in 0..<2_000 {
                let x0 = xs[Int(next() >> 32) % xs.count]
                let x1 = xs[Int(next() >> 32) % xs.count]
                let y0 = ys[Int(next() >> 32) % ys.count]
                let y1 = ys[Int(next() >> 32) % ys.count]
                #expect(bits(value.average(
                    minimumColumn: x0, maximumColumn: x1, minimumRow: y0, maximumRow: y1
                )) == bits(reference(value, x0, x1, y0, y1)))
            }
        }
    }

    @Test func derivedUIRegionsUseTheSameCells() {
        let value = sample(columns: 12, rows: 8)
        #expect(bits(value.overall) == bits(reference(value, 0, 11, 0, 7)))
        #expect(bits(value.leading) == bits(reference(value, 0, 3, 0, 7)))
        #expect(bits(value.bottom) == bits(reference(value, 0, 11, 6, 7)))
    }

    @Test func summationOrderAndInputClampingRemainExact() {
        let values: [Double] = [.nan, .infinity, -.infinity, -1, 0, 0.25, 1, 2,
                                Double.ulpOfOne / 4, Double.leastNonzeroMagnitude]
        let colors = (0..<96).map { index in
            SampledVideoColor(red: values[index % values.count],
                              green: values[(index * 3 + 1) % values.count],
                              blue: values[(index * 7 + 2) % values.count])
        }
        let value = VideoColorSample(columns: 12, rows: 8, colors: colors)
        #expect(bits(value.overall) == bits(reference(value, 0, 11, 0, 7)))
        #expect(bits(value.average(
            minimumColumn: 2, maximumColumn: 8, minimumRow: 1, maximumRow: 6
        )) == bits(reference(value, 2, 8, 1, 6)))
    }

    @Test func publicPointLookupStillClampsCoordinates() {
        let value = sample(columns: 12, rows: 8)
        #expect(value.color(column: Int.min, row: Int.min) == value.colors[0])
        #expect(value.color(column: Int.max, row: Int.max) == value.colors[95])
        #expect(value.color(column: 4, row: 3) == value.colors[40])
    }
}
