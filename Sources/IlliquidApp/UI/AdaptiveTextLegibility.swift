import Foundation
import IlliquidCore

/// Font-only decisions over an unchanged glass surface. The lift is an estimate,
/// so evaluate both the source sample and its lifted counterpart instead of
/// treating the estimate as a measurement of Apple's material.
struct AdaptiveTextLegibility {
    static let minimumTextContrast = 4.5
    let backgrounds: [SampledVideoColor]
    private let luminances: [Double]
    private let sourceBackgrounds: [SampledVideoColor]
    private let lift: Double
    let isMixed: Bool

    init(backgrounds: [SampledVideoColor], luminanceLift: Double) {
        let lift = luminanceLift.isFinite ? max(0, luminanceLift) : 0
        sourceBackgrounds = backgrounds
        self.lift = lift
        isMixed = AdaptiveRainbowTextColor.isMixedLuminanceRegion(
            backgrounds.map { min(1, $0.relativeLuminance + lift) })
        self.backgrounds = backgrounds.flatMap { color in
            // The rendered white fixture is darker behind regular glass. Use
            // a conservative darkened endpoint as well as the lifted endpoint;
            // neither is claimed to measure Apple's dynamic material exactly.
            [color, SampledVideoColor(red: color.red * 0.82,
                                      green: color.green * 0.82, blue: color.blue * 0.82),
             SampledVideoColor(
                red: Self.encoded(min(1, Self.linear(color.red) + lift)),
                green: Self.encoded(min(1, Self.linear(color.green) + lift)),
                blue: Self.encoded(min(1, Self.linear(color.blue) + lift)))]
        }
        luminances = self.backgrounds.map(\.relativeLuminance)
    }

    /// The lower tail is deliberately stricter than the old 20th-percentile
    /// palette search. Small label regions are evaluated at their worst sample.
    func score(_ foreground: AdaptiveRainbowTextColor) -> Double {
        score(luminance: SampledVideoColor(red: foreground.red, green: foreground.green,
                                         blue: foreground.blue).relativeLuminance)
    }

    private func score(luminance: Double) -> Double {
        let ratios = luminances.map { Self.contrast(luminance, $0) }.sorted()
        guard !ratios.isEmpty else { return 1 }
        return ratios[Int(Double(ratios.count - 1) * 0.10)]
    }

    func resolve(hueSource: SampledVideoColor, palette: PlayerRainbowPalette,
                 monochrome: Bool, previous: AdaptiveRainbowTextColor?) -> AdaptiveRainbowTextColor {
        guard !backgrounds.isEmpty else { return .init(red: 1, green: 1, blue: 1) }
        let candidate = monochrome
            ? AdaptiveRainbowTextColor.resolveMonochrome(against: sourceBackgrounds, luminanceLift: lift)
            : AdaptiveRainbowTextColor.resolve(hueFrom: hueSource, contrastAgainst: sourceBackgrounds,
                                               palette: palette, luminanceLift: lift, previous: previous)
        // Raw black/white samples omit the intermediate tones created by glass
        // blur. A minimax middle grey looked better numerically but disappeared
        // in the rendered texture fixture. Preserve the established polarity
        // and halo on mixed regions; strengthen subordinate text independently.
        if isMixed { return candidate }
        let candidateScore = score(candidate)
        var selected = candidate
        if candidateScore < Self.minimumTextContrast {
            var bestScore = candidateScore
            for value in [0.0, 1.0] {
                let neutral = AdaptiveRainbowTextColor(red: value, green: value, blue: value)
                let neutralScore = score(neutral)
                if neutralScore > bestScore + 0.02 {
                    selected = neutral
                    bestScore = neutralScore
                }
            }
        }
        if !monochrome, selected != candidate, score(selected) >= Self.minimumTextContrast {
            let endpoint = selected
            var low = 0.0
            var high = 1.0
            for _ in 0..<10 {
                let weight = (low + high) / 2
                let adjusted = AdaptiveRainbowTextColor(
                    red: candidate.red + (endpoint.red - candidate.red) * weight,
                    green: candidate.green + (endpoint.green - candidate.green) * weight,
                    blue: candidate.blue + (endpoint.blue - candidate.blue) * weight)
                if score(adjusted) >= Self.minimumTextContrast { selected = adjusted; high = weight }
                else { low = weight }
            }
        }
        if let previous {
            let oldScore = score(previous)
            let newScore = score(selected)
            let oldLuminance = SampledVideoColor(red: previous.red, green: previous.green, blue: previous.blue).relativeLuminance
            let newLuminance = SampledVideoColor(red: selected.red, green: selected.green, blue: selected.blue).relativeLuminance
            // Hysteresis is allowed only while the previous color is readable;
            // it must never delay an essential correction after a scene cut.
            if oldScore >= Self.minimumTextContrast,
               (oldLuminance > 0.18) != (newLuminance > 0.18),
               newScore < oldScore * 1.15 { return previous }
        }
        return selected
    }

    func readableOpacity(for foreground: AdaptiveRainbowTextColor, preferred: Double) -> Double {
        let preferred = preferred.isFinite ? min(1, max(0, preferred)) : 1
        let opaqueScore = score(foreground)
        // When even opaque text misses the target, fading can only worsen the
        // vulnerable part of the region. Preserve full opacity immediately.
        guard opaqueScore >= Self.minimumTextContrast else { return 1 }
        let target = Self.minimumTextContrast
        guard preferred < 1, opacityScore(foreground, opacity: preferred) < target else { return preferred }
        var low = preferred
        var high = 1.0
        for _ in 0..<10 {
            let midpoint = (low + high) / 2
            if opacityScore(foreground, opacity: midpoint) >= target { high = midpoint }
            else { low = midpoint }
        }
        return high
    }

    func opacityScore(_ foreground: AdaptiveRainbowTextColor, opacity: Double) -> Double {
        let fgLuminance = SampledVideoColor(red: foreground.red, green: foreground.green,
                                            blue: foreground.blue).relativeLuminance
        let inverse = 1 - opacity
        var ratios: [Double] = []
        ratios.reserveCapacity(backgrounds.count)
        for index in backgrounds.indices {
            let background = backgrounds[index]
            let gammaLuminance = 0.2126 * Self.linear(foreground.red * opacity + background.red * inverse)
                + 0.7152 * Self.linear(foreground.green * opacity + background.green * inverse)
                + 0.0722 * Self.linear(foreground.blue * opacity + background.blue * inverse)
            let backgroundLuminance = luminances[index]
            let linearLuminance = fgLuminance * opacity + backgroundLuminance * inverse
            ratios.append(min(Self.contrast(gammaLuminance, backgroundLuminance),
                              Self.contrast(linearLuminance, backgroundLuminance)))
        }
        ratios.sort()
        guard !ratios.isEmpty else { return 1 }
        return ratios[Int(Double(ratios.count - 1) * 0.10)]
    }

    private static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    private static func encoded(_ value: Double) -> Double {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
}
