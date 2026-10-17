import Foundation
import IlliquidCore
import Testing
@testable import IlliquidApp

/// Differential coverage for the optimized contrast queries. The oracle keeps
/// the original full-sort definition and deliberately derives each background's
/// luminance from its own RGB value, independently of the production caches.
@Suite("Adaptive text legibility contrast equivalence")
struct AdaptiveTextLegibilityPerformanceTests {
    @Test func opaqueScoresMatchSortedReferenceAcrossQuantileBoundaries() {
        var random = LegibilityRandom(state: 0x1E61_B111_2026)
        for count in [0, 1, 2, 3, 4, 9, 10, 11, 24, 32, 96, 224] {
            let randomColors = (0..<count).map { _ in random.color() }
            let duplicateColors = (0..<count).map { index in
                index.isMultiple(of: 3) ? Self.white : Self.black
            }
            let foregrounds = [Self.foreground(0), Self.foreground(1),
                               .init(red: 1, green: 0.15, blue: 0.6)]
                + (0..<8).map { _ in Self.foreground(random.color()) }
            for source in [randomColors, duplicateColors] {
                for lift in [0.0, 0.08, 0.35] {
                    let context = AdaptiveTextLegibility(backgrounds: source, luminanceLift: lift)
                    let reference = SortedLegibilityReference(backgrounds: context.backgrounds)
                    #expect(context.backgrounds.count == count * 3)
                    for foreground in foregrounds {
                        #expect(context.score(foreground) == reference.score(foreground))
                    }
                }
            }
        }
    }

    @Test func opacitySearchMatchesSortedReferenceForDiverseRegions() {
        var random = LegibilityRandom(state: 0xA1FA_2026_1017)
        let foregrounds = [0.0, 0.1, 0.34, 0.46, 0.65, 0.8, 1.0].map(Self.foreground)
            + [AdaptiveRainbowTextColor(red: 0, green: 1, blue: 0),
               AdaptiveRainbowTextColor(red: 1, green: 0.15, blue: 0.6)]
        for count in [0, 1, 3, 4, 9, 10, 11, 24, 96] {
            let randomColors = (0..<count).map { _ in random.color() }
            let narrowBrightGradient = (0..<count).map { index in
                Self.grey(0.84 + 0.16 * Double(index) / Double(max(count - 1, 1)))
            }
            for source in [randomColors, narrowBrightGradient,
                           Array(repeating: Self.black, count: count),
                           Array(repeating: Self.grey(0.48), count: count)] {
                let context = AdaptiveTextLegibility(backgrounds: source, luminanceLift: 0.08)
                let reference = SortedLegibilityReference(backgrounds: context.backgrounds)
                for foreground in foregrounds {
                    for preferred in [0.0, 0.45, 0.90, 0.96, 1.0] {
                        #expect(context.opacityScore(foreground, opacity: preferred)
                            == reference.opacityScore(foreground, opacity: preferred))
                        // Exact equality checks every binary-search decision,
                        // rather than merely allowing a similar final opacity.
                        #expect(context.readableOpacity(for: foreground, preferred: preferred)
                            == reference.readableOpacity(for: foreground, preferred: preferred))
                    }
                }
            }
        }
    }

    @Test func percentileAllowsExactlyItsRankOfFailingSamples() {
        let foreground = AdaptiveRainbowTextColor(red: 0, green: 1, blue: 0)
        for count in [9, 10, 11, 12] {
            // The one white source contributes three failing endpoints. With
            // 10 sources the expanded rank is 2; with 11 it becomes 3.
            let source = Array(repeating: Self.black, count: count - 1) + [Self.white]
            let context = AdaptiveTextLegibility(backgrounds: source, luminanceLift: 0)
            let reference = SortedLegibilityReference(backgrounds: context.backgrounds)
            let result = context.readableOpacity(for: foreground, preferred: 0.9)
            #expect(result == reference.readableOpacity(for: foreground, preferred: 0.9))
            #expect(result == (count <= 10 ? 1 : 0.9))
        }
    }

    @Test func opacityThresholdIncludesEqualityAndDistinguishesAdjacentValues() throws {
        let context = AdaptiveTextLegibility(backgrounds: [Self.black], luminanceLift: 0)
        let reference = SortedLegibilityReference(backgrounds: context.backgrounds)
        let target = 4.5
        var exactBoundary: (AdaptiveRainbowTextColor, Double)?

        // Search actual representable inputs rather than assume that an sRGB
        // inverse computed by a particular platform's libm rounds identically.
        for red in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0] {
            let foreground = AdaptiveRainbowTextColor(red: red, green: 1, blue: 0)
            var low = 0.0
            var high = 1.0
            for _ in 0..<64 {
                let midpoint = (low + high) / 2
                if reference.opacityScore(foreground, opacity: midpoint) >= target {
                    high = midpoint
                } else {
                    low = midpoint
                }
            }
            #expect(reference.opacityScore(foreground, opacity: low) < target)
            #expect(reference.opacityScore(foreground, opacity: high) >= target)
            #expect(context.readableOpacity(for: foreground, preferred: high) == high)
            #expect(context.readableOpacity(for: foreground, preferred: low)
                == reference.readableOpacity(for: foreground, preferred: low))
            #expect(context.readableOpacity(for: foreground, preferred: low) > low)
            if reference.opacityScore(foreground, opacity: high) == target {
                exactBoundary = (foreground, high)
            }
        }
        let (foreground, opacity) = try #require(exactBoundary)
        #expect(context.opacityScore(foreground, opacity: opacity) == target)
        #expect(context.readableOpacity(for: foreground, preferred: opacity) == opacity)
    }

    @Test func opacityKeepsEachBackgroundPairedWithItsOwnLuminance() {
        let source: [SampledVideoColor] = [
            Self.white, .init(red: 0, green: 0, blue: 0.12),
            .init(red: 0.05, green: 1, blue: 0.1), Self.black,
            .init(red: 0.9, green: 0.12, blue: 0.04), Self.grey(0.61),
            .init(red: 0.08, green: 0.6, blue: 1),
        ]
        let context = AdaptiveTextLegibility(backgrounds: source, luminanceLift: 0.08)
        let reordered = AdaptiveTextLegibility(backgrounds: Array(source.reversed()), luminanceLift: 0.08)
        let reference = SortedLegibilityReference(backgrounds: context.backgrounds)
        for foreground in [Self.foreground(0), Self.foreground(0.34), Self.foreground(1),
                           .init(red: 0.04, green: 0.78, blue: 0.25)] {
            for opacity in [0.0, 0.3, 0.9, 0.96, 1.0] {
                let expected = reference.opacityScore(foreground, opacity: opacity)
                #expect(context.opacityScore(foreground, opacity: opacity) == expected)
                #expect(reordered.opacityScore(foreground, opacity: opacity) == expected)
                #expect(context.readableOpacity(for: foreground, preferred: opacity)
                    == reference.readableOpacity(for: foreground, preferred: opacity))
            }
        }
    }

    @Test func sanitizedInputsAndEmptyRegionsRetainTheirBehavior() {
        let source: [SampledVideoColor] = [
            .init(red: .nan, green: .infinity, blue: -.infinity),
            .init(red: -4, green: 5, blue: 0.7), Self.white,
        ]
        #expect(source[0] == Self.black)
        #expect(source[1] == SampledVideoColor(red: 0, green: 1, blue: 0.7))
        let sanitizedForeground = Self.foreground(SampledVideoColor(red: .infinity, green: -5, blue: 2))
        let foregrounds = [Self.foreground(0), Self.foreground(1), sanitizedForeground,
                           .init(red: .nan, green: 1, blue: 1),
                           .init(red: .infinity, green: 1, blue: 1),
                           .init(red: -.infinity, green: 1, blue: 1),
                           .init(red: -4, green: 1, blue: 1),
                           .init(red: 2, green: 0, blue: 0)]
        for backgrounds in [[], source, [Self.black], [Self.white]] {
            for lift in [-1.0, 0, 0.08, 2, .nan, .infinity, -.infinity] {
                let context = AdaptiveTextLegibility(backgrounds: backgrounds, luminanceLift: lift)
                let reference = SortedLegibilityReference(backgrounds: context.backgrounds)
                for foreground in foregrounds {
                    #expect(context.score(foreground) == reference.score(foreground))
                    for preferred in [-2.0, 0, 0.9, 0.96, 1, 2, .nan, .infinity, -.infinity] {
                        #expect(context.readableOpacity(for: foreground, preferred: preferred)
                            == reference.readableOpacity(for: foreground, preferred: preferred))
                    }
                }
                if backgrounds.isEmpty {
                    #expect(context.score(Self.foreground(1)) == 1)
                    #expect(context.opacityScore(Self.foreground(1), opacity: 0.9) == 1)
                    #expect(context.resolve(hueSource: Self.black, palette: .softSpectrum,
                        monochrome: false, previous: nil) == Self.foreground(1))
                }
            }
        }
        let context = AdaptiveTextLegibility(backgrounds: source, luminanceLift: 0.08)
        let reference = SortedLegibilityReference(backgrounds: context.backgrounds)
        // score's public foreground conversion itself also sanitizes channels.
        let rawForeground = AdaptiveRainbowTextColor(red: .nan, green: .infinity, blue: -2)
        #expect(context.score(rawForeground) == reference.score(rawForeground))
    }

    private static let black = grey(0)
    private static let white = grey(1)

    private static func grey(_ value: Double) -> SampledVideoColor {
        .init(red: value, green: value, blue: value)
    }

    private static func foreground(_ value: Double) -> AdaptiveRainbowTextColor {
        .init(red: value, green: value, blue: value)
    }

    private static func foreground(_ color: SampledVideoColor) -> AdaptiveRainbowTextColor {
        .init(red: color.red, green: color.green, blue: color.blue)
    }
}

private struct SortedLegibilityReference {
    let backgrounds: [SampledVideoColor]

    func score(_ foreground: AdaptiveRainbowTextColor) -> Double {
        let sanitized = SampledVideoColor(red: foreground.red, green: foreground.green, blue: foreground.blue)
        let luminance = Self.luminance(red: sanitized.red, green: sanitized.green, blue: sanitized.blue)
        return quantile(backgrounds.map { background in
            Self.contrast(luminance, Self.luminance(red: background.red, green: background.green, blue: background.blue))
        })
    }

    func opacityScore(_ foreground: AdaptiveRainbowTextColor, opacity: Double) -> Double {
        let sanitized = SampledVideoColor(red: foreground.red, green: foreground.green, blue: foreground.blue)
        let foregroundLuminance = Self.luminance(red: sanitized.red, green: sanitized.green, blue: sanitized.blue)
        return quantile(backgrounds.map { background in
            let backgroundLuminance = Self.luminance(red: background.red, green: background.green, blue: background.blue)
            let encodedBlendLuminance = Self.luminance(
                red: foreground.red * opacity + background.red * (1 - opacity),
                green: foreground.green * opacity + background.green * (1 - opacity),
                blue: foreground.blue * opacity + background.blue * (1 - opacity))
            let linearBlendLuminance = foregroundLuminance * opacity + backgroundLuminance * (1 - opacity)
            return min(Self.contrast(encodedBlendLuminance, backgroundLuminance),
                       Self.contrast(linearBlendLuminance, backgroundLuminance))
        })
    }

    func readableOpacity(for foreground: AdaptiveRainbowTextColor, preferred: Double) -> Double {
        let preferred = preferred.isFinite ? min(1, max(0, preferred)) : 1
        guard score(foreground) >= 4.5 else { return 1 }
        guard preferred < 1, opacityScore(foreground, opacity: preferred) < 4.5 else { return preferred }
        var low = preferred
        var high = 1.0
        for _ in 0..<10 {
            let midpoint = (low + high) / 2
            if opacityScore(foreground, opacity: midpoint) >= 4.5 { high = midpoint }
            else { low = midpoint }
        }
        return high
    }

    private func quantile(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 1 }
        return values.sorted()[Int(Double(values.count - 1) * 0.10)]
    }

    private static func luminance(red: Double, green: Double, blue: Double) -> Double {
        0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func contrast(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}

private struct LegibilityRandom {
    var state: UInt64

    mutating func color() -> SampledVideoColor {
        .init(red: unit(), green: unit(), blue: unit())
    }

    private mutating func unit() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / 9_007_199_254_740_992
    }
}
