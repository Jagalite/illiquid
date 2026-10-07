import CoreGraphics
import IlliquidCore
import Testing
@testable import IlliquidApp

@Suite("Adaptive rainbow text color")
struct AdaptiveRainbowTextColorTests {
    @Test func sidebarHeaderOverLetterboxDoesNotSampleBrightVideo() throws {
        let video = PlayerTextVideoGeometry.contentRect(
            viewportSize: CGSize(width: 1_200, height: 800), aspectRatio: 2.4)
        let header = try #require(PlayerTextSamplingGeometry.resolve(
            frame: CGRect(x: 14, y: 12, width: 300, height: 60),
            videoContentRect: video, videoClipRect: video, columns: 12, rows: 8))
        #expect(header.isOutsideVideo)
        #expect(header.region == nil)
        let row = try #require(PlayerTextSamplingGeometry.resolve(
            frame: CGRect(x: 14, y: 200, width: 300, height: 30),
            videoContentRect: video, videoClipRect: video, columns: 12, rows: 8))
        #expect(!row.isOutsideVideo)
        #expect(row.region?.canvasSampleCount == 0)
    }

    @Test func textCrossingLetterboxIncludesBlackCanvasInContrastAndCacheIdentity() throws {
        let video = CGRect(x: 0, y: 100, width: 1_200, height: 600)
        let crossing = try #require(PlayerTextGridRegion.resolve(
            frame: CGRect(x: 0, y: 80, width: 300, height: 40),
            videoContentRect: video, columns: 12, rows: 8))
        let inside = try #require(PlayerTextGridRegion.resolve(
            frame: CGRect(x: 0, y: 100, width: 300, height: 20),
            videoContentRect: video, columns: 12, rows: 8))
        let white = SampledVideoColor(red: 1, green: 1, blue: 1)
        let black = SampledVideoColor(red: 0, green: 0, blue: 0)
        let sample = VideoColorSample(columns: 12, rows: 8, colors: Array(repeating: white, count: 96))
        let colors = crossing.colors(in: sample)
        #expect(colors.filter { $0 == black }.count == colors.filter { $0 == white }.count)
        #expect(crossing != inside)
        #expect(inside.colors(in: sample).allSatisfy { $0 == white })
    }

    @Test func sidebarOverPillarboxOrCroppedAreaUsesCanvas() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        for image in [bounds, CGRect(x: 300, y: 0, width: 600, height: 800)] {
            let geometry = try #require(PlayerTextSamplingGeometry.resolve(
                frame: CGRect(x: 14, y: 12, width: 250, height: 60),
                videoContentRect: image, videoClipRect: CGRect(x: 300, y: 0, width: 600, height: 800),
                columns: 12, rows: 8))
            #expect(geometry.isOutsideVideo)
        }
    }

    @Test func fillGeometryRemovesLetterboxClassification() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let geometry = try #require(PlayerTextSamplingGeometry.resolve(
            frame: CGRect(x: 14, y: 12, width: 300, height: 60),
            videoContentRect: CGRect(x: -360, y: 0, width: 1_920, height: 800),
            videoClipRect: bounds, columns: 12, rows: 8))
        #expect(!geometry.isOutsideVideo)
        #expect(geometry.region?.canvasSampleCount == 0)
    }

    @Test func tinyVisibleOverlapKeepsCanvasSamplingBounded() throws {
        let region = try #require(PlayerTextGridRegion.resolve(
            frame: CGRect(x: 0, y: 0, width: 300, height: 100.001),
            videoContentRect: CGRect(x: 0, y: 100, width: 1_200, height: 600),
            columns: 12, rows: 8))
        #expect(region.canvasSampleCount == 128)
    }

    @Test func mapsViewPositionsAcrossBothGridAxes() throws {
        let viewport = CGSize(width: 1_200, height: 800)

        let topLeft = try #require(PlayerTextGridLocation.resolve(
            frame: CGRect(x: 40, y: 30, width: 120, height: 40),
            viewportSize: viewport,
            columns: 12,
            rows: 8
        ))
        let bottomRight = try #require(PlayerTextGridLocation.resolve(
            frame: CGRect(x: 1_040, y: 700, width: 120, height: 40),
            viewportSize: viewport,
            columns: 12,
            rows: 8
        ))

        #expect(topLeft == PlayerTextGridLocation(column: 1, row: 0))
        #expect(bottomRight == PlayerTextGridLocation(column: 11, row: 7))
    }

    @Test func mapsActualSidebarBoundsWithoutIncludingOutsideColumn() throws {
        let viewport = CGSize(width: 1_765, height: 993)
        let videoContentRect = PlayerTextVideoGeometry.contentRect(
            viewportSize: viewport,
            aspectRatio: 16.0 / 9.0
        )
        let region = try #require(PlayerTextGridRegion.resolve(
            frame: CGRect(x: 10, y: 0, width: 444, height: 993),
            videoContentRect: videoContentRect,
            columns: 12,
            rows: 8
        ))

        #expect(region == PlayerTextGridRegion(
            minimumColumn: 0,
            maximumColumn: 2,
            minimumRow: 0,
            maximumRow: 7
        ))
    }

    @Test func aspectFitMappingExcludesLetterboxAndPreservesBothAxes() throws {
        let videoContentRect = PlayerTextVideoGeometry.contentRect(
            viewportSize: CGSize(width: 1_200, height: 800),
            aspectRatio: 16.0 / 9.0
        )
        #expect(abs(videoContentRect.minY - 62.5) < 0.001)
        #expect(abs(videoContentRect.height - 675) < 0.001)

        let region = try #require(PlayerTextGridRegion.resolve(
            frame: CGRect(x: 0, y: 62.5, width: 300, height: 337.5),
            videoContentRect: videoContentRect,
            columns: 12,
            rows: 8
        ))
        #expect(region == PlayerTextGridRegion(
            minimumColumn: 0,
            maximumColumn: 2,
            minimumRow: 0,
            maximumRow: 3
        ))

        let location = try #require(PlayerTextGridLocation.resolve(
            frame: CGRect(x: 1_080, y: 650, width: 40, height: 40),
            videoContentRect: videoContentRect,
            columns: 12,
            rows: 8
        ))
        #expect(location == PlayerTextGridLocation(column: 11, row: 7))
    }

    @Test func alignedLeadingColorIgnoresSampleOutsideSidebar() throws {
        let red = SampledVideoColor(red: 0.8, green: 0.1, blue: 0.1)
        let blue = SampledVideoColor(red: 0.1, green: 0.1, blue: 0.8)
        let sample = VideoColorSample(
            columns: 12,
            rows: 1,
            colors: [red, red, red] + Array(repeating: blue, count: 9)
        )
        let aligned = PlayerTextGridRegion(
            minimumColumn: 0,
            maximumColumn: 2,
            minimumRow: 0,
            maximumRow: 0
        )

        let alignedColor = PlayerTextContrastRegion.leading.color(
            in: sample,
            localColor: blue,
            alignedRegion: aligned
        )
        #expect(abs(alignedColor.red - red.red) < 0.000_001)
        #expect(abs(alignedColor.green - red.green) < 0.000_001)
        #expect(abs(alignedColor.blue - red.blue) < 0.000_001)
        #expect(sample.leading != red)
        #expect(PlayerTextContrastRegion.leading.colors(
            in: sample,
            localColor: blue,
            alignedRegion: aligned
        ) == [red, red, red])
    }

    @Test func choosesBrightHarmonicColorForDarkContent() {
        let background = SampledVideoColor(red: 0.05, green: 0.02, blue: 0.02)
        let result = AdaptiveRainbowTextColor.resolve(
            hueFrom: background,
            contrastAgainst: background,
            palette: .balanced
        )
        let resultColor = SampledVideoColor(
            red: result.red,
            green: result.green,
            blue: result.blue
        )

        #expect(result.red > 0.9)
        #expect(result.green > 0.75)
        #expect(result.blue < 0.55)
        #expect(abs(resultColor.hue - 0.125) < 0.02)
    }

    @Test func softSpectrumReducesSaturationWithoutSacrificingContrast() {
        let hueSource = SampledVideoColor(red: 0.72, green: 0.12, blue: 0.42)
        let background = SampledVideoColor(red: 0.04, green: 0.04, blue: 0.04)
        let soft = AdaptiveRainbowTextColor.resolve(
            hueFrom: hueSource,
            contrastAgainst: background,
            palette: .softSpectrum
        )
        let balanced = AdaptiveRainbowTextColor.resolve(
            hueFrom: hueSource,
            contrastAgainst: background,
            palette: .balanced
        )
        let softColor = SampledVideoColor(
            red: soft.red,
            green: soft.green,
            blue: soft.blue
        )
        let balancedColor = SampledVideoColor(
            red: balanced.red,
            green: balanced.green,
            blue: balanced.blue
        )

        #expect(softColor.saturation + 0.10 < balancedColor.saturation)
        #expect(contrastRatio(soft, against: background) >= 5.4)
    }

    @Test func choosesDarkHarmonicColorForBrightContent() {
        let background = SampledVideoColor(red: 1, green: 0.92, blue: 0.88)
        let result = AdaptiveRainbowTextColor.resolve(against: background)

        #expect(max(result.red, result.green, result.blue) <= 0.42)
    }

    @Test func warmAndCoolPalettesConstrainResolvedHueFamilies() {
        let hueSource = SampledVideoColor(red: 0.7, green: 0.2, blue: 0.1)
        let background = SampledVideoColor(red: 0.03, green: 0.03, blue: 0.03)
        let warm = AdaptiveRainbowTextColor.resolve(
            hueFrom: hueSource,
            contrastAgainst: background,
            palette: .warm
        )
        let cool = AdaptiveRainbowTextColor.resolve(
            hueFrom: hueSource,
            contrastAgainst: background,
            palette: .cool
        )
        let warmHue = SampledVideoColor(
            red: warm.red,
            green: warm.green,
            blue: warm.blue
        ).hue
        let coolHue = SampledVideoColor(
            red: cool.red,
            green: cool.green,
            blue: cool.blue
        ).hue

        #expect(warmHue >= 0 && warmHue <= 0.15)
        #expect(coolHue >= 0.50 && coolHue <= 0.75)
        #expect(contrastRatio(warm, against: background) >= 5.4)
        #expect(contrastRatio(cool, against: background) >= 5.4)
    }

    @Test func fallsBackToNeutralAtTheNarrowMidtoneBoundary() {
        let background = SampledVideoColor(red: 0.18, green: 0.50, blue: 0.64)
        let result = AdaptiveRainbowTextColor.resolve(against: background)
        let resultColor = SampledVideoColor(
            red: result.red,
            green: result.green,
            blue: result.blue
        )
        let lighter = max(
            resultColor.relativeLuminance,
            background.relativeLuminance
        )
        let darker = min(
            resultColor.relativeLuminance,
            background.relativeLuminance
        )

        #expect((lighter + 0.05) / (darker + 0.05) >= 4.5)
        #expect(
            max(result.red, result.green, result.blue)
                - min(result.red, result.green, result.blue) < 0.02
        )
    }

    @Test func preservesVisibleHueAgainstBrightGreen() {
        let background = SampledVideoColor(red: 0.46, green: 0.86, blue: 0.24)
        let result = AdaptiveRainbowTextColor.resolve(
            hueFrom: background,
            contrastAgainst: background,
            palette: .balanced,
            luminanceLift: 0.08
        )
        let resultColor = SampledVideoColor(
            red: result.red,
            green: result.green,
            blue: result.blue
        )
        let lighter = max(
            resultColor.relativeLuminance,
            background.relativeLuminance
        )
        let darker = min(
            resultColor.relativeLuminance,
            background.relativeLuminance
        )
        let chroma = max(result.red, result.green, result.blue)
            - min(result.red, result.green, result.blue)

        #expect((lighter + 0.05) / (darker + 0.05) >= 5.4)
        #expect(chroma > 0.2)
        #expect(max(result.red, result.green, result.blue) > 0.3)
    }

    @Test func sharedContrastRegionKeepsOnePolarityAcrossLocalHues() {
        let contrastRegion = SampledVideoColor(red: 0.56, green: 0.62, blue: 0.66)
        let warm = AdaptiveRainbowTextColor.resolve(
            hueFrom: SampledVideoColor(red: 0.8, green: 0.22, blue: 0.1),
            contrastAgainst: contrastRegion
        )
        let cool = AdaptiveRainbowTextColor.resolve(
            hueFrom: SampledVideoColor(red: 0.1, green: 0.38, blue: 0.8),
            contrastAgainst: contrastRegion
        )

        #expect(max(warm.red, warm.green, warm.blue) <= 0.42)
        #expect(max(cool.red, cool.green, cool.blue) <= 0.42)
        #expect(warm != cool)
    }

    @Test func rainbowUsesRegionalDistributionInsteadOfAveragedColor() {
        let dark = SampledVideoColor(red: 0, green: 0, blue: 0)
        let midtone = SampledVideoColor(red: 0.55, green: 0.55, blue: 0.55)
        let backgrounds = Array(repeating: dark, count: 3)
            + Array(repeating: midtone, count: 7)
        let hueSource = SampledVideoColor(red: 0.385, green: 0.2, blue: 0.1)
        let averagedBackground = SampledVideoColor(
            red: 0.385,
            green: 0.385,
            blue: 0.385
        )

        let averaged = AdaptiveRainbowTextColor.resolve(
            hueFrom: hueSource,
            contrastAgainst: averagedBackground,
            luminanceLift: 0.08
        )
        let distributed = AdaptiveRainbowTextColor.resolve(
            hueFrom: hueSource,
            contrastAgainst: backgrounds,
            luminanceLift: 0.08
        )

        #expect(max(averaged.red, averaged.green, averaged.blue) <= 0.42)
        #expect(max(distributed.red, distributed.green, distributed.blue) > 0.9)
        #expect(distributed != averaged)
    }

    @Test func regionalRainbowKeepsOnePolarityAcrossHueSources() {
        let dark = SampledVideoColor(red: 0, green: 0, blue: 0)
        let midtone = SampledVideoColor(red: 0.55, green: 0.55, blue: 0.55)
        let backgrounds = Array(repeating: dark, count: 3)
            + Array(repeating: midtone, count: 7)
        let warm = AdaptiveRainbowTextColor.resolve(
            hueFrom: SampledVideoColor(red: 0.8, green: 0.22, blue: 0.1),
            contrastAgainst: backgrounds,
            luminanceLift: 0.08
        )
        let cool = AdaptiveRainbowTextColor.resolve(
            hueFrom: SampledVideoColor(red: 0.1, green: 0.38, blue: 0.8),
            contrastAgainst: backgrounds,
            luminanceLift: 0.08
        )

        #expect(max(warm.red, warm.green, warm.blue) > 0.9)
        #expect(max(cool.red, cool.green, cool.blue) > 0.9)
    }

    @Test func sparseBrightHighlightsDoNotInvertADarkRegion() {
        let dark = SampledVideoColor(red: 0.04, green: 0.06, blue: 0.10)
        let highlight = SampledVideoColor(red: 0.96, green: 0.94, blue: 0.72)
        let backgrounds = Array(repeating: dark, count: 19)
            + Array(repeating: highlight, count: 5)

        let rainbow = AdaptiveRainbowTextColor.resolve(
            hueFrom: SampledVideoColor(red: 0.06, green: 0.12, blue: 0.28),
            contrastAgainst: backgrounds,
            luminanceLift: 0.08
        )
        let monochrome = AdaptiveRainbowTextColor.resolveMonochrome(
            against: backgrounds,
            luminanceLift: 0.08
        )

        #expect(max(rainbow.red, rainbow.green, rainbow.blue) > 0.9)
        #expect(monochrome.red > 0.5)
    }

    @Test func mixedBrightAndDarkPanelUsesOneStableLightColor() {
        let brightPeach = SampledVideoColor(red: 1, green: 0.72, blue: 0.62)
        let darkTeal = SampledVideoColor(red: 0.03, green: 0.22, blue: 0.28)
        let backgrounds = Array(repeating: brightPeach, count: 14)
            + Array(repeating: darkTeal, count: 10)

        let rainbow = AdaptiveRainbowTextColor.resolve(
            hueFrom: SampledVideoColor(red: 0.55, green: 0.35, blue: 0.40),
            contrastAgainst: backgrounds,
            luminanceLift: 0.08
        )
        let monochrome = AdaptiveRainbowTextColor.resolveMonochrome(
            against: backgrounds,
            luminanceLift: 0.08
        )

        #expect(min(rainbow.red, rainbow.green, rainbow.blue) > 0.75)
        #expect(monochrome.red > 0.5)
    }

    @Test func monochromeUsesReadableGreyForDarkContent() {
        let background = SampledVideoColor(red: 0.04, green: 0.06, blue: 0.08)
        let result = AdaptiveRainbowTextColor.resolveMonochrome(
            against: background
        )

        #expect(result.red == result.green)
        #expect(result.green == result.blue)
        #expect(result.red > 0.5)
        #expect(result.red < 1)
        #expect(contrastRatio(result, against: background) >= 5.4)
    }

    @Test func monochromeUsesReadableGreyForBrightContent() {
        let background = SampledVideoColor(red: 0.88, green: 0.92, blue: 0.82)
        let result = AdaptiveRainbowTextColor.resolveMonochrome(
            against: background
        )

        #expect(result.red == result.green)
        #expect(result.green == result.blue)
        #expect(result.red < 0.5)
        #expect(contrastRatio(result, against: background) >= 5.4)
    }

    @Test func monochromeUsesRegionalDistributionInsteadOfAveragedColor() {
        let dark = SampledVideoColor(red: 0, green: 0, blue: 0)
        let midtone = SampledVideoColor(red: 0.55, green: 0.55, blue: 0.55)
        let backgrounds = Array(repeating: dark, count: 3)
            + Array(repeating: midtone, count: 7)
        let averagedBackground = SampledVideoColor(
            red: 0.385,
            green: 0.385,
            blue: 0.385
        )

        let averaged = AdaptiveRainbowTextColor.resolveMonochrome(
            against: averagedBackground,
            luminanceLift: 0.08
        )
        let distributed = AdaptiveRainbowTextColor.resolveMonochrome(
            against: backgrounds,
            luminanceLift: 0.08
        )

        #expect(averaged.red < 0.5)
        #expect(distributed.red > 0.5)
        #expect(distributed.red == distributed.green)
        #expect(distributed.green == distributed.blue)
    }

    @Test func monochromePrefersLightGreyWhenRegionalContrastIsNearlyTied() {
        let dark = SampledVideoColor(red: 0, green: 0, blue: 0)
        let midtone = SampledVideoColor(red: 0.59, green: 0.59, blue: 0.59)
        let backgrounds = Array(repeating: dark, count: 3)
            + Array(repeating: midtone, count: 7)

        let result = AdaptiveRainbowTextColor.resolveMonochrome(
            against: backgrounds,
            luminanceLift: 0.08
        )

        #expect(result.red > 0.5)
        #expect(result.red == result.green)
        #expect(result.green == result.blue)
    }

    @Test func sampledVideoColorReportsSRGBRelativeLuminance() {
        #expect(SampledVideoColor(red: 0, green: 0, blue: 0).relativeLuminance == 0)
        #expect(
            abs(
                SampledVideoColor(red: 1, green: 1, blue: 1).relativeLuminance
                    - 1
            ) < 0.000_001
        )
    }


    private func contrastRatio(
        _ foreground: AdaptiveRainbowTextColor,
        against background: SampledVideoColor
    ) -> Double {
        let foregroundLuminance = SampledVideoColor(
            red: foreground.red,
            green: foreground.green,
            blue: foreground.blue
        ).relativeLuminance
        let lighter = max(foregroundLuminance, background.relativeLuminance)
        let darker = min(foregroundLuminance, background.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
