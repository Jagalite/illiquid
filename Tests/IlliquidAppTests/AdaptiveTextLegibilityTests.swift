import AppKit
import Foundation
import SwiftUI
import IlliquidCore
import Testing
@testable import IlliquidApp
@testable import IlliquidPlayer

@Suite("Glass font legibility", .serialized)
struct AdaptiveTextLegibilityTests {
    private let white = SampledVideoColor(red: 1, green: 1, blue: 1)
    private let black = SampledVideoColor(red: 0, green: 0, blue: 0)

    @MainActor @Test func adaptiveTextRefreshesAcrossBrightDarkCutsAndReset() {
        let store = PlaybackVideoColorStore(sample: .init(columns: 1, rows: 1, colors: [white]))
        func colors() -> PlayerTextStyleColors {
            PlayerTextPalette(theme: .liquidGlass, mode: .dynamicMonochrome,
                rainbowPalette: .softSpectrum, sample: store.sample, store: store)
                .colors(at: .init(column: 0, row: 0), contrastRegion: .local, alignedRegion: nil)
        }
        let bright = colors()
        #expect(bright.contrastHaloRadius > 0)
        store.publish(.init(columns: 1, rows: 1, colors: [black]))
        let dark = colors()
        #expect(dark.primary != bright.primary)
        #expect(dark.contrastHalo != bright.contrastHalo)
        #expect(dark.contrastHaloRadius > 0)
        #expect(colors().primary == dark.primary)
        store.reset()
        store.publish(.init(columns: 1, rows: 1, colors: [white]))
        #expect(colors().primary == bright.primary)
    }

    @Test func namedDifficultRegionsImproveTheContrastFloor() {
        let cases: [(String, [SampledVideoColor])] = [
            ("black", [black]), ("white", [white]),
            ("middle-grey", [.init(red: 0.48, green: 0.48, blue: 0.48)]),
            ("saturated-red", [.init(red: 1, green: 0, blue: 0)]),
            ("saturated-green", [.init(red: 0, green: 1, blue: 0)]),
            ("saturated-blue", [.init(red: 0, green: 0, blue: 1)]),
            ("split-black-white", [black, white]),
            ("small-white-patch", Array(repeating: black, count: 8) + [white]),
            ("small-black-patch", Array(repeating: white, count: 8) + [black]),
            ("fine-texture", (0..<16).map { $0.isMultiple(of: 2) ? black : white }),
        ]
        for (name, backgrounds) in cases {
            let context = AdaptiveTextLegibility(backgrounds: backgrounds, luminanceLift: 0.08)
            let before = AdaptiveRainbowTextColor.resolve(hueFrom: backgrounds[0], contrastAgainst: backgrounds,
                                                          luminanceLift: 0.08)
            let after = context.resolve(hueSource: backgrounds[0], palette: .softSpectrum, monochrome: false, previous: nil)
            let beforeScore = context.score(before)
            let afterScore = context.score(after)
            print("GLASS_CASE \(name) before=\(beforeScore) after=\(afterScore)")
            #expect(afterScore + 0.05 >= min(4.5, beforeScore), Comment(rawValue: name))
            if context.isMixed {
                #expect(after == before, "Mixed textures must preserve the visually qualified polarity")
                #expect(after.red > 0.5 || after.green > 0.5 || after.blue > 0.5)
            }
            for preferred in [0.96, 0.90] {
                let opacity = context.readableOpacity(for: after, preferred: preferred)
                #expect(opacity >= preferred && opacity <= 1)
                #expect(context.opacityScore(after, opacity: opacity) + 0.001 >= min(4.5, afterScore), Comment(rawValue: name))
            }
        }
    }

    @Test func subordinateTextIsCheckedAfterBothAlphaBlendConventions() {
        let context = AdaptiveTextLegibility(backgrounds: [white], luminanceLift: 0.08)
        let foreground = AdaptiveRainbowTextColor(red: 0.34, green: 0.34, blue: 0.34)
        let alpha = context.readableOpacity(for: foreground, preferred: 0.90)
        #expect(alpha > 0.90)
        let blended = foreground.red * alpha + (1 - alpha)
        let linear = blended <= 0.04045 ? blended / 12.92 : pow((blended + 0.055) / 1.055, 2.4)
        let ratio = 1.05 / (linear + 0.05)
        #expect(ratio >= 4.5)
        #expect(context.opacityScore(foreground, opacity: alpha) >= 4.5)
    }

    @Test func sceneCutCannotRetainAnUnreadablePreviousColor() {
        let dark = AdaptiveTextLegibility(backgrounds: [black], luminanceLift: 0.08)
        let bright = AdaptiveTextLegibility(backgrounds: [white], luminanceLift: 0.08)
        let initial = dark.resolve(hueSource: black, palette: .softSpectrum, monochrome: true, previous: nil)
        let cut = bright.resolve(hueSource: white, palette: .softSpectrum, monochrome: true, previous: initial)
        #expect(bright.score(initial) < 4.5)
        #expect(bright.score(cut) >= 4.5)
    }

    @Test func localContrastUsesLabelExtentInsteadOfAnAverage() {
        let sample = VideoColorSample(columns: 3, rows: 1, colors: [black, white, black])
        let region = PlayerTextGridRegion(minimumColumn: 0, maximumColumn: 1, minimumRow: 0, maximumRow: 0)
        let colors = PlayerTextContrastRegion.local.colors(in: sample, localColor: sample.overall, alignedRegion: region)
        #expect(colors == [black, white])
    }

    @MainActor @Test func paletteHistoryIsBoundedAndResetBySourceGeneration() {
        let store = PlaybackVideoColorStore(sample: .init(columns: 1, rows: 1, colors: [black]))
        let cache = PlayerTextPaletteCache()
        func key(_ column: Int) -> PlayerTextPaletteCacheKey {
            .init(column: column, row: 0, contrastRegion: .local, alignedRegion: nil,
                  mode: .dynamicRainbow, rainbowPalette: .softSpectrum)
        }
        let first = AdaptiveRainbowTextColor(red: 1, green: 0.8, blue: 0.8)
        _ = cache.resolve(store: store, key: key(0)) { previous in
            #expect(previous == nil)
            return first
        }
        store.publish(.init(columns: 1, rows: 1, colors: [white]))
        _ = cache.resolve(store: store, key: key(0)) { previous in
            #expect(previous == first)
            return first
        }
        store.reset()
        store.publish(.init(columns: 1, rows: 1, colors: [black]))
        _ = cache.resolve(store: store, key: key(0)) { previous in
            #expect(previous == nil)
            return first
        }
        for column in 0..<1_000 { _ = cache.resolve(store: store, key: key(column)) { _ in first } }
        #expect(cache.entryCount <= PlayerTextPaletteCache.maximumEntries * 2)
    }

    @Test func optimizedContrastRanksMatchIndependentSortedRatios() {
        for count in [1, 2, 3, 24, 96] {
            let backgrounds = (0..<count).map { Double(($0 * 37 + 11) % 101) / 100 }.sorted()
            for foreground in stride(from: 0.0, through: 1.0, by: 0.025) {
                let reference = backgrounds.map { (max($0, foreground) + 0.05) / (min($0, foreground) + 0.05) }.sorted()
                for rank in reference.indices {
                    let actual = AdaptiveRainbowTextColor.contrastQuantile(
                        luminance: foreground, sortedBackgrounds: backgrounds, rank: rank)
                    #expect(abs(actual - reference[rank]) < 0.0000001)
                }
            }
        }
    }

    @Test func recordsBoundedUncachedPaletteCost() {
        var backgrounds: [SampledVideoColor] = []
        for index in 0..<96 {
            let red = Double(index % 7) / 6.0
            let green = Double(index % 11) / 10.0
            let blue = Double(index % 13) / 12.0
            backgrounds.append(SampledVideoColor(red: red, green: green, blue: blue))
        }
        let start = ContinuousClock.now
        for _ in 0..<50 {
            let context = AdaptiveTextLegibility(backgrounds: backgrounds, luminanceLift: 0.08)
            let color = context.resolve(hueSource: backgrounds[0], palette: .softSpectrum, monochrome: false, previous: nil)
            _ = context.readableOpacity(for: color, preferred: 0.90)
        }
        print("GLASS_UNCACHED_50 \(start.duration(to: .now))")
        #expect(start.duration(to: .now) < .seconds(2))
    }
}
