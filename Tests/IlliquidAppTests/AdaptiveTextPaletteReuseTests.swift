import SwiftUI
import IlliquidCore
import Testing
@testable import IlliquidApp
@testable import IlliquidPlayer

/// The oracle retains the old two-context call sequence. These checks exercise
/// the production palette wrapper and its cache, rather than only the unchanged
/// numeric legibility helpers.
@Suite("Adaptive text palette context reuse", .serialized)
@MainActor
struct AdaptiveTextPaletteReuseTests {
    @Test func uncachedStylesMatchTwoContextReferenceAcrossModesPalettesAndRegions() {
        for (sampleIndex, sample) in Self.samples.enumerated() {
            for mode in [PlayerTextColorMode.dynamicRainbow, .dynamicMonochrome] {
                for palette in PlayerRainbowPalette.allCases {
                    for (regionIndex, input) in Self.regions.enumerated() {
                        let actual = styles(sample: sample, mode: mode, palette: palette, input: input)
                        let expected = reference(sample: sample, mode: mode, palette: palette, input: input)
                        expectSameStyle(actual, expected.style,
                            "sample=\(sampleIndex) mode=\(mode.rawValue) palette=\(palette.rawValue) region=\(regionIndex)")
                    }
                }
            }
        }
    }

    @Test func revisionsAndStyleHitsPreservePreviousColorHistory() {
        let store = PlaybackVideoColorStore()
        var previous: [PlayerTextPaletteCacheKey: AdaptiveRainbowTextColor] = [:]
        for sample in Self.samples {
            store.publish(sample)
            var current: [PlayerTextPaletteCacheKey: AdaptiveRainbowTextColor] = [:]
            for mode in [PlayerTextColorMode.dynamicRainbow, .dynamicMonochrome] {
                for palette in PlayerRainbowPalette.allCases {
                    for input in Self.regions {
                        let key = input.key(mode: mode, palette: palette)
                        let expected = reference(sample: sample, mode: mode, palette: palette,
                            input: input, previous: previous[key])
                        expectSameStyle(styles(sample: sample, store: store, mode: mode,
                            palette: palette, input: input), expected.style)
                        expectSameStyle(styles(sample: sample, store: store, mode: mode,
                            palette: palette, input: input), expected.style, "style cache hit")
                        current[key] = expected.components
                    }
                }
            }
            previous = current
        }
    }

    @Test func generationResetAndStoreSwitchDiscardCachedStylesAndHistory() {
        let input = Self.regions[1]
        let first = Self.samples[0]
        let next = Self.samples[1]
        let store = PlaybackVideoColorStore(sample: first)
        _ = styles(sample: first, store: store, input: input)
        store.publish(next)
        _ = styles(sample: next, store: store, input: input)

        store.reset()
        expectSameStyle(styles(sample: nil, store: store, input: input), fallback(.liquidGlass))
        store.publish(first)
        expectSameStyle(styles(sample: first, store: store, input: input),
            reference(sample: first, input: input).style, "new generation")

        // Equal counters isolate owner identity from the revision/generation
        // invalidation exercised above. Both stores use the same palette key.
        let firstOwner = PlaybackVideoColorStore(sample: first)
        let secondOwner = PlaybackVideoColorStore(sample: next)
        #expect(firstOwner.generation == secondOwner.generation)
        #expect(firstOwner.revision == secondOwner.revision)
        expectSameStyle(styles(sample: first, store: firstOwner, input: input),
            reference(sample: first, input: input).style, "first owner")
        expectSameStyle(styles(sample: next, store: secondOwner, input: input),
            reference(sample: next, input: input).style, "new store")
        expectSameStyle(styles(sample: first, store: firstOwner, input: input),
            reference(sample: first, input: input).style, "return to old store")
    }

    @Test func existingComponentsAndFullStyleCacheRetainTheirFastPathBehavior() {
        let sample = Self.samples[2]
        let input = Self.regions[0]
        let store = PlaybackVideoColorStore(sample: sample)
        let components = AdaptiveRainbowTextColor(red: 0.38, green: 0.56, blue: 0.74)
        _ = PlayerTextPaletteCache.shared.resolve(store: store,
            key: input.key(mode: .dynamicRainbow, palette: .softSpectrum)) { previous in
                #expect(previous == nil)
                return components
            }
        let expected = reference(sample: sample, input: input, cachedComponents: components)
        expectSameStyle(styles(sample: sample, store: store, input: input), expected.style,
            "component hit with a style miss")
        // A fixed store revision is authoritative for cache identity. A cached
        // style must still return before consulting a different supplied sample.
        expectSameStyle(styles(sample: Self.samples[0], store: store, input: input),
            expected.style, "full style hit")
    }

    @Test func cacheOverflowPreservesUncachedAndHistoryResults() {
        let store = PlaybackVideoColorStore()
        var previous: [PlayerTextPaletteCacheKey: AdaptiveRainbowTextColor] = [:]
        for sample in [Self.samples[2], Self.samples[3]] {
            store.publish(sample)
            var current: [PlayerTextPaletteCacheKey: AdaptiveRainbowTextColor] = [:]
            for column in 0..<270 {
                let input = PaletteRegionInput(location: .init(column: column, row: 0), region: .local)
                let key = input.key(mode: .dynamicRainbow, palette: .softSpectrum)
                let expected = reference(sample: sample, input: input, previous: previous[key])
                expectSameStyle(styles(sample: sample, store: store, input: input), expected.style)
                if column < 256 { current[key] = expected.components }
                else {
                    expectSameStyle(styles(sample: sample, store: store, input: input), expected.style,
                        "uncached key beyond capacity")
                }
            }
            #expect(PlayerTextPaletteCache.shared.entryCount == 256 + previous.count)
            previous = current
        }
    }

    @Test func staticThemesStaticModeAndMissingSamplesKeepFallbacks() {
        let input = Self.regions[0]
        let sample = Self.samples[0]
        let store = PlaybackVideoColorStore(sample: sample)
        for theme in PlayerTheme.allCases {
            for mode in PlayerTextColorMode.allCases {
                for palette in PlayerRainbowPalette.allCases {
                    expectSameStyle(styles(sample: nil, store: store, theme: theme,
                        mode: mode, palette: palette, input: input), fallback(theme))
                    if theme != .liquidGlass || mode == .staticColor {
                        expectSameStyle(styles(sample: sample, store: store, theme: theme,
                            mode: mode, palette: palette, input: input), fallback(theme))
                    }
                }
            }
        }
    }

    private func styles(
        sample: VideoColorSample?, store: PlaybackVideoColorStore? = nil,
        theme: PlayerTheme = .liquidGlass, mode: PlayerTextColorMode = .dynamicRainbow,
        palette: PlayerRainbowPalette = .softSpectrum, input: PaletteRegionInput
    ) -> PlayerTextStyleColors {
        PlayerTextPalette(theme: theme, mode: mode, rainbowPalette: palette, sample: sample, store: store)
            .colors(at: input.location, contrastRegion: input.region, alignedRegion: input.aligned)
    }

    private func reference(
        sample: VideoColorSample, mode: PlayerTextColorMode = .dynamicRainbow,
        palette: PlayerRainbowPalette = .softSpectrum, input: PaletteRegionInput,
        previous: AdaptiveRainbowTextColor? = nil, cachedComponents: AdaptiveRainbowTextColor? = nil
    ) -> (style: PlayerTextStyleColors, components: AdaptiveRainbowTextColor) {
        let components: AdaptiveRainbowTextColor
        if let cachedComponents {
            components = cachedComponents
        } else {
            let localColor = input.localColor(in: sample)
            let hue = input.region.color(in: sample, localColor: localColor, alignedRegion: input.aligned)
            let primaryContext = AdaptiveTextLegibility(backgrounds: input.region.colors(
                in: sample, localColor: localColor, alignedRegion: input.aligned), luminanceLift: 0.08)
            components = primaryContext.resolve(hueSource: hue, palette: palette,
                monochrome: mode == .dynamicMonochrome, previous: previous)
        }
        // Independently rebuild the second context as the original wrapper did.
        let localColor = input.localColor(in: sample)
        let opacityContext = AdaptiveTextLegibility(backgrounds: input.region.colors(
            in: sample, localColor: localColor, alignedRegion: input.aligned), luminanceLift: 0.08)
        let color = Color(red: components.red, green: components.green, blue: components.blue)
        let bright = SampledVideoColor(red: components.red, green: components.green,
            blue: components.blue).relativeLuminance > 0.45
        return (PlayerTextStyleColors(
            primary: color,
            secondary: color.opacity(opacityContext.readableOpacity(for: components, preferred: 0.96)),
            tertiary: color.opacity(opacityContext.readableOpacity(for: components, preferred: 0.90)),
            contrastHalo: bright ? Color.black.opacity(0.9) : Color.white.opacity(0.9),
            contrastHaloRadius: opacityContext.isMixed ? 1.4 : 1.0
        ), components)
    }

    private func fallback(_ theme: PlayerTheme) -> PlayerTextStyleColors {
        PlayerTextStyleColors(primary: theme.primaryColor, secondary: theme.secondaryColor,
            tertiary: theme.secondaryColor.opacity(0.72), contrastHalo: .clear, contrastHaloRadius: 0)
    }

    private func expectSameStyle(_ actual: PlayerTextStyleColors, _ expected: PlayerTextStyleColors,
                                 _ label: String = "two-context reference") {
        #expect(actual.primary == expected.primary, Comment(rawValue: label))
        #expect(actual.secondary == expected.secondary, Comment(rawValue: label))
        #expect(actual.tertiary == expected.tertiary, Comment(rawValue: label))
        #expect(actual.contrastHalo == expected.contrastHalo, Comment(rawValue: label))
        #expect(actual.contrastHaloRadius == expected.contrastHaloRadius, Comment(rawValue: label))
    }

    private static let regions: [PaletteRegionInput] = [
        .init(location: .init(column: 5, row: 3), region: .local),
        .init(region: .overall),
        .init(region: .leading),
        .init(region: .bottom),
        .init(region: .local),
        .init(location: .init(column: 0, row: 0), region: .local,
            aligned: .init(minimumColumn: 0, maximumColumn: 2, minimumRow: 0, maximumRow: 2)),
        .init(region: .leading,
            aligned: .init(minimumColumn: 1, maximumColumn: 5, minimumRow: 1, maximumRow: 6,
                           canvasSampleCount: 17)),
        .init(location: .init(column: -2, row: 20), region: .local,
            aligned: .init(minimumColumn: -4, maximumColumn: 50, minimumRow: -2, maximumRow: 20,
                           canvasSampleCount: 400)),
    ]

    private static var samples: [VideoColorSample] {
        let black = SampledVideoColor(red: 0, green: 0, blue: 0)
        let white = SampledVideoColor(red: 1, green: 1, blue: 1)
        let grey = SampledVideoColor(red: 0.48, green: 0.48, blue: 0.48)
        let varied: [SampledVideoColor] = (0..<96).map { index in
            SampledVideoColor(red: Double(index % 7) / 6,
                green: Double(index % 11) / 10, blue: Double(index % 13) / 12)
        }
        let mixed: [SampledVideoColor] = (0..<96).map { $0.isMultiple(of: 2) ? black : white }
        let textures: [[SampledVideoColor]] = [
            Array(repeating: white, count: 96),
            Array(repeating: black, count: 96),
            Array(repeating: grey, count: 96),
            varied,
            mixed,
        ]
        return textures.map { VideoColorSample(columns: 12, rows: 8, colors: $0) }
            + [VideoColorSample(columns: 1, rows: 1,
                colors: [.init(red: .nan, green: .infinity, blue: -2)])]
    }
}

private struct PaletteRegionInput {
    var location: PlayerTextGridLocation? = nil
    let region: PlayerTextContrastRegion
    var aligned: PlayerTextGridRegion? = nil

    func key(mode: PlayerTextColorMode, palette: PlayerRainbowPalette) -> PlayerTextPaletteCacheKey {
        let cacheLocation = region == .local ? location : nil
        return .init(column: cacheLocation?.column ?? -1, row: cacheLocation?.row ?? -1,
            contrastRegion: region, alignedRegion: aligned, mode: mode, rainbowPalette: palette)
    }

    func localColor(in sample: VideoColorSample) -> SampledVideoColor {
        guard let location else { return sample.overall }
        return sample.average(minimumColumn: location.column - 1, maximumColumn: location.column + 1,
            minimumRow: location.row - 1, maximumRow: location.row + 1)
    }
}
