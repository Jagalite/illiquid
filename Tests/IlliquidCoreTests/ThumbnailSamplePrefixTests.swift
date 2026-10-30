import Foundation
import Testing
@testable import IlliquidCore

@Suite("Thumbnail sample prefix planning")
struct ThumbnailSamplePrefixTests {
    @Test(arguments: [Int.min, -1, 0, 1])
    func oneSampleKeepsQuantizedInterest(count: Int) {
        #expect(ThumbnailPolicy.samples(duration: 120, focus: 42.3, count: count) == [42.5])
        #expect(ThumbnailPolicy.samples(duration: 120, focus: 200, count: count) == [119.5])
        #expect(ThumbnailPolicy.samples(duration: 120, focus: -20, count: count) == [0])
    }

    @Test func defaultTwelveSamplesKeepTheirEstablishedOrder() {
        #expect(ThumbnailPolicy.samples(duration: 120, focus: 42.3, count: 12) == [
            42.5, 0, 60, 30, 90, 15, 45, 75, 105, 7.5, 22.5, 37.5,
        ])
    }

    @Test func storyboardKeepsItsTwentyFourSamplePrefix() {
        #expect(ThumbnailPolicy.storyboard(duration: 7_200) == [
            0, 3_600, 1_800, 5_400, 900, 2_700, 4_500, 6_300,
            450, 1_350, 2_250, 3_150, 4_050, 4_950, 5_850, 6_750,
            225, 675, 1_125, 1_575, 2_025, 2_475, 2_925, 3_375,
        ])
    }

    @Test func duplicateFocusDoesNotConsumeAnotherSlot() {
        #expect(ThumbnailPolicy.samples(duration: 120, focus: 59.8, count: 6) == [
            60, 0, 30, 90, 15, 45,
        ])
        #expect(ThumbnailPolicy.samples(duration: 120, focus: -0.0, count: 2) == [0, 60])
        #expect(ThumbnailPolicy.samples(duration: 1.5, focus: 0, count: 64) == [0, 1, 0.5])
    }

    @Test func subsecondClipsKeepTheirSingleInitialSample() {
        let durations = [Double.leastNonzeroMagnitude, 0.1, 0.5, Double(1).nextDown]
        let focuses = [-Double.greatestFiniteMagnitude, -0.0, 0.0,
                       Double.greatestFiniteMagnitude, Double.infinity,
                       -Double.infinity, Double.nan]
        for duration in durations {
            for focus in focuses {
                let initial = ThumbnailPolicy.samples(duration: duration, focus: focus, count: 1)
                for count in [12, 24, 64, Int.max] {
                    let result = ThumbnailPolicy.samples(duration: duration, focus: focus, count: count)
                    #expect(result == [0])
                    #expect(result.map(\.bitPattern) == initial.map(\.bitPattern))
                }
            }
        }
        #expect(ThumbnailPolicy.samples(duration: 1, focus: 0, count: 64) == [0, 0.5])
    }

    @Test func invalidInputsKeepTheirExistingFallbacks() {
        for duration in [Double.nan, Double.infinity, -Double.infinity, -1, -0.0, 0] {
            #expect(ThumbnailPolicy.samples(duration: duration, focus: 42.3, count: 12).isEmpty)
        }
        let zeroFocus = ThumbnailPolicy.samples(duration: 120, focus: 0, count: 12)
        for focus in [Double.nan, Double.infinity, -Double.infinity] {
            #expect(ThumbnailPolicy.samples(duration: 120, focus: focus, count: 12) == zeroFocus)
        }
    }

    @Test func boundedCountsReturnTheSameOrderedPrefix() {
        let durations = [Double.leastNonzeroMagnitude, Double(1).nextDown,
                         1, Double(1).nextUp, 3.7, 30, 120, 7_200,
                         Double.greatestFiniteMagnitude]
        let focuses = [-Double.greatestFiniteMagnitude, -0.0, 0.0, 3.7, 59.8,
                       10_000, Double.greatestFiniteMagnitude]
        for duration in durations {
            for focus in focuses {
                let full = ThumbnailPolicy.samples(duration: duration, focus: focus, count: 64)
                for count in [Int.min, 0, 1, 2, 3, 6, 12, 24, 63, 64, Int.max] {
                    let result = ThumbnailPolicy.samples(duration: duration, focus: focus, count: count)
                    let expected = full.prefix(min(max(count, 1), 64))
                    #expect(result.map(\.bitPattern) == expected.map(\.bitPattern))
                }
            }
        }
    }
}
