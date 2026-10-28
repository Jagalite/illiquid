import Foundation
import Testing
@testable import IlliquidCore

@Suite("Thumbnail sample planning")
struct ThumbnailSamplePlanningTests {
    @Test func storyboardKeepsProgressiveGapOrder() {
        #expect(ThumbnailPolicy.storyboard(duration: 64) == [
            0, 32, 16, 48, 8, 24, 40, 56, 4, 12, 20, 28,
            36, 44, 52, 60, 2, 6, 10, 14, 18, 22, 26, 30,
        ])
        #expect(ThumbnailPolicy.samples(duration: 120, focus: 42.3, count: 12) == [
            42.5, 0, 60, 30, 90, 15, 45, 75, 105, 7.5, 22.5, 37.5,
        ])
    }

    @Test func everyBudgetKeepsTheSameOrderedPrefix() {
        for duration in [0.1, 1.4, 2.1, 30, 120, 7_200] {
            for focus in [0, 0.24, 0.26, 42.3, duration / 2, duration, duration + 10] {
                let complete = ThumbnailPolicy.samples(duration: duration, focus: focus, count: 64)
                for count in 1...64 {
                    #expect(ThumbnailPolicy.samples(duration: duration, focus: focus, count: count)
                        == Array(complete.prefix(count)))
                }
            }
        }
    }

    @Test func clampedBudgetsKeepInterestFirst() {
        for count in [Int.min, -1, 0, 1] {
            #expect(ThumbnailPolicy.samples(duration: 120, focus: 42.3, count: count) == [42.5])
        }
        let maximum = ThumbnailPolicy.samples(duration: 120, focus: 42.3, count: 64)
        #expect(maximum.count == 64)
        for count in [65, 128, Int.max] {
            #expect(ThumbnailPolicy.samples(duration: 120, focus: 42.3, count: count) == maximum)
        }
    }

    @Test func quantizedDuplicatesDoNotConsumeTheBudget() {
        #expect(ThumbnailPolicy.samples(duration: 0.1, focus: 99, count: 64) == [0])
        #expect(ThumbnailPolicy.samples(duration: Double(1).nextDown, focus: 99, count: 64) == [0])
        #expect(ThumbnailPolicy.samples(duration: 1, focus: 99, count: 64) == [0.5, 0])
        #expect(ThumbnailPolicy.samples(duration: 1.4, focus: 0.51, count: 64) == [0.5, 0])
        #expect(ThumbnailPolicy.samples(duration: 2.1, focus: 0.51, count: 3) == [0.5, 0, 1])
        #expect(ThumbnailPolicy.samples(duration: 2.1, focus: 0.51, count: 64) == [0.5, 0, 1, 1.5])
        #expect(ThumbnailPolicy.samples(duration: 120, focus: 999, count: 2) == [119.5, 0])
        for focus in [Double.nan, Double.infinity, -Double.infinity] {
            #expect(ThumbnailPolicy.samples(duration: 120, focus: focus, count: 2) == [0, 60])
        }
        for duration in [Double.nan, Double.infinity, -Double.infinity, -1, 0] {
            #expect(ThumbnailPolicy.samples(duration: duration, focus: 0, count: 12).isEmpty)
        }
    }
}
