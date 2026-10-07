import Foundation
import Testing
@testable import IlliquidCore

@Suite("Aspect-fit window sizing")
struct AspectFitWindowSizingTests {
    @Test func shrinksHeightForWideVideoAndKeepsSidebarWidth() {
        let result = AspectFitWindowSizing.fittedWindowSize(
            currentWindowSize: CGSize(width: 1_200, height: 760),
            currentVideoViewportSize: CGSize(width: 930, height: 760),
            minimumWindowSize: CGSize(width: 720, height: 440),
            videoAspectRatio: 16.0 / 9.0
        )

        #expect(result != nil)
        #expect(abs((result?.width ?? 0) - 1_200) < 0.01)
        #expect(abs((result?.height ?? 0) - 523.125) < 0.01)
    }

    @Test func shrinksWidthForTallVideo() {
        let result = AspectFitWindowSizing.fittedWindowSize(
            currentWindowSize: CGSize(width: 1_000, height: 800),
            currentVideoViewportSize: CGSize(width: 1_000, height: 800),
            minimumWindowSize: CGSize(width: 400, height: 300),
            videoAspectRatio: 4.0 / 3.0
        )

        #expect(result?.width == 1_000)
        #expect(result?.height == 750)
    }

    @Test func refusesAResultThatWouldViolateMinimumWindowSize() {
        let result = AspectFitWindowSizing.fittedWindowSize(
            currentWindowSize: CGSize(width: 720, height: 600),
            currentVideoViewportSize: CGSize(width: 450, height: 600),
            minimumWindowSize: CGSize(width: 720, height: 440),
            videoAspectRatio: 9.0 / 16.0
        )

        #expect(result == nil)
    }
}
