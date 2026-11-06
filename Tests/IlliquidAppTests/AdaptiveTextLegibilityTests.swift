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

    @MainActor private func composite(_ color: Color, over background: SampledVideoColor) -> SampledVideoColor {
        let rgb = NSColor(color).usingColorSpace(.sRGB)!
        let alpha = Double(rgb.alphaComponent)
        return .init(red: Double(rgb.redComponent) * alpha + background.red * (1 - alpha),
                     green: Double(rgb.greenComponent) * alpha + background.green * (1 - alpha),
                     blue: Double(rgb.blueComponent) * alpha + background.blue * (1 - alpha))
    }

    private func contrast(_ foreground: SampledVideoColor, _ background: SampledVideoColor) -> Double {
        let values = [foreground.relativeLuminance, background.relativeLuminance].sorted()
        return (values[1] + 0.05) / (values[0] + 0.05)
    }

    @MainActor @Test func titlebarTextIsReadableOnSelectedAndUnselectedTabs() {
        let background = SampledVideoColor(red: 0.18, green: 0.18, blue: 0.18)
        let selected = composite(PlayerTheme.liquidGlass.selectedFillColor, over: background)
        let samples = [white, black, SampledVideoColor(red: 1, green: 0, blue: 0),
                       SampledVideoColor(red: 0, green: 0, blue: 1)]
        for mode in [PlayerTextColorMode.dynamicRainbow, .dynamicMonochrome] {
            for sample in samples {
                let style = PlayerTextPalette(theme: .liquidGlass, mode: mode,
                    rainbowPalette: .softSpectrum,
                    sample: .init(columns: 1, rows: 1, colors: [sample]), store: nil).titlebarColors()
                #expect(contrast(composite(style.primary, over: selected), selected) >= 4.5)
                #expect(contrast(composite(style.secondary, over: background), background) >= 4.5)
                #expect(style.contrastHaloRadius == 0)
            }
        }
    }

    @MainActor @Test func popoverCaptionsAreReadableAcrossThemes() {
        for theme in PlayerTheme.allCases {
            let background = composite(theme.popoverSurfaceColor, over: black)
            for foreground in [theme.primaryColor, theme.secondaryColor] {
                #expect(contrast(composite(foreground, over: background), background) >= 4.5,
                        Comment(rawValue: theme.rawValue))
            }
        }
    }

    @MainActor @Test func titlebarFollowsVideoHueWithoutDarkTextOrHalos() {
        func colors(_ sample: SampledVideoColor) -> PlayerTextStyleColors {
            PlayerTextPalette(theme: .liquidGlass, mode: .dynamicRainbow,
                rainbowPalette: .softSpectrum,
                sample: .init(columns: 1, rows: 1, colors: [sample]), store: nil)
                .titlebarColors()
        }
        #expect(colors(.init(red: 1, green: 0, blue: 0)).primary
            != colors(.init(red: 0, green: 0, blue: 1)).primary)
        let background = SampledVideoColor(red: 0.18, green: 0.18, blue: 0.18)
        for sample in [white, black, SampledVideoColor(red: 0, green: 1, blue: 0)] {
            let style = colors(sample)
            let rgb = NSColor(style.primary).usingColorSpace(.sRGB)!
            let foreground = SampledVideoColor(red: rgb.redComponent,
                green: rgb.greenComponent, blue: rgb.blueComponent)
            #expect((foreground.relativeLuminance + 0.05)
                / (background.relativeLuminance + 0.05) >= 4.5)
            #expect(style.contrastHaloRadius == 0)
            #expect(style.contrastHalo == .clear)
        }
    }

    @MainActor @Test func titlebarRespectsStaticModeAndSampleReset() {
        let store = PlaybackVideoColorStore(sample: .init(columns: 1, rows: 1, colors: [white]))
        func colors(_ mode: PlayerTextColorMode) -> PlayerTextStyleColors {
            PlayerTextPalette(theme: .liquidGlass, mode: mode,
                rainbowPalette: .softSpectrum, sample: store.sample, store: store).titlebarColors()
        }
        #expect(colors(.staticColor).primary == PlayerTheme.liquidGlass.primaryColor)
        store.reset()
        #expect(colors(.dynamicRainbow).primary == PlayerTheme.liquidGlass.primaryColor)
    }

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
