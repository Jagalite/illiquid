import Foundation
import IlliquidCore
import Testing
@testable import IlliquidApp

@Suite("Adaptive text color audit")
struct AdaptiveTextColorAuditTests {
    private let luminanceLift = 0.08
    private let preferredContrast = 5.5
    private let contrastTolerance = 0.12
    private let maximumSamePolarityTransition = 0.125

    @Test func deterministicColorSpaceAndRegionalAudit() {
        var audit = AuditResult()

        for redIndex in 0...16 {
            for greenIndex in 0...16 {
                for blueIndex in 0...16 {
                    let background = SampledVideoColor(
                        red: Double(redIndex) / 16,
                        green: Double(greenIndex) / 16,
                        blue: Double(blueIndex) / 16
                    )
                    auditScenario(
                        name: "uniform-\(redIndex)-\(greenIndex)-\(blueIndex)",
                        backgrounds: Array(repeating: background, count: 24),
                        hueSource: background,
                        audit: &audit
                    )
                }
            }
        }

        let anchors: [(String, SampledVideoColor)] = [
            ("black", SampledVideoColor(red: 0, green: 0, blue: 0)),
            ("night-blue", SampledVideoColor(red: 0.03, green: 0.07, blue: 0.15)),
            ("dark-warm", SampledVideoColor(red: 0.14, green: 0.04, blue: 0.02)),
            ("middle-grey", SampledVideoColor(red: 0.46, green: 0.46, blue: 0.46)),
            ("green", SampledVideoColor(red: 0.15, green: 0.65, blue: 0.25)),
            ("moon", SampledVideoColor(red: 0.96, green: 0.94, blue: 0.72)),
            ("white", SampledVideoColor(red: 1, green: 1, blue: 1)),
        ]
        for (firstName, first) in anchors {
            for (secondName, second) in anchors where firstName != secondName {
                for secondCount in 1..<24 {
                    let backgrounds = Array(
                        repeating: first,
                        count: 24 - secondCount
                    ) + Array(repeating: second, count: secondCount)
                    auditScenario(
                        name: "mix-\(firstName)-\(secondName)-\(secondCount)",
                        backgrounds: backgrounds,
                        hueSource: average(backgrounds),
                        audit: &audit
                    )
                }

                let gradient = (0..<24).map { index in
                    interpolate(
                        from: first,
                        to: second,
                        amount: Double(index) / 23
                    )
                }
                auditScenario(
                    name: "gradient-\(firstName)-\(secondName)",
                    backgrounds: gradient,
                    hueSource: average(gradient),
                    audit: &audit
                )
            }
        }

        var generator = DeterministicGenerator(state: 0x5EED_C010_2026)
        for scenarioIndex in 0..<512 {
            let backgrounds = (0..<24).map { _ in
                SampledVideoColor(
                    red: generator.nextUnit(),
                    green: generator.nextUnit(),
                    blue: generator.nextUnit()
                )
            }
            auditScenario(
                name: "seeded-\(scenarioIndex)",
                backgrounds: backgrounds,
                hueSource: average(backgrounds),
                audit: &audit
            )
        }

        auditNeighbouringTransitions(audit: &audit)
        audit.requireSamePolarityTransitions(
            atMost: maximumSamePolarityTransition
        )

        print(audit.report)
        #expect(
            audit.failures.isEmpty,
            Comment(rawValue: audit.failureReport)
        )
    }

    private func auditScenario(
        name: String,
        backgrounds: [SampledVideoColor],
        hueSource: SampledVideoColor,
        audit: inout AuditResult
    ) {
        let expectedBright = expectedBrightPolarity(backgrounds: backgrounds)
        let monochrome = AdaptiveRainbowTextColor.resolveMonochrome(
            against: backgrounds,
            luminanceLift: luminanceLift
        )
        auditOutput(
            name: "\(name)/monochrome",
            output: monochrome,
            backgrounds: backgrounds,
            expectedBright: expectedBright,
            audit: &audit
        )
        if abs(monochrome.red - monochrome.green) > 0.000_001
            || abs(monochrome.green - monochrome.blue) > 0.000_001
        {
            audit.recordFailure("\(name): monochrome output is not neutral")
        }

        for palette in PlayerRainbowPalette.allCases {
            let rainbow = AdaptiveRainbowTextColor.resolve(
                hueFrom: hueSource,
                contrastAgainst: backgrounds,
                palette: palette,
                luminanceLift: luminanceLift
            )
            auditOutput(
                name: "\(name)/\(palette.rawValue)",
                output: rainbow,
                backgrounds: backgrounds,
                expectedBright: expectedBright,
                audit: &audit
            )
            if isBright(rainbow) != isBright(monochrome) {
                audit.recordFailure(
                    "\(name)/\(palette.rawValue): rainbow and monochrome polarity differ"
                )
            }
        }
    }

    private func auditOutput(
        name: String,
        output: AdaptiveRainbowTextColor,
        backgrounds: [SampledVideoColor],
        expectedBright: Bool,
        audit: inout AuditResult
    ) {
        audit.outputCount += 1
        let components = [output.red, output.green, output.blue]
        if components.contains(where: { !$0.isFinite || $0 < 0 || $0 > 1 }) {
            audit.recordFailure("\(name): component outside finite sRGB range")
            return
        }

        let bright = isBright(output)
        if bright != expectedBright {
            audit.recordFailure(
                "\(name): expected \(expectedBright ? "bright" : "dark") polarity"
            )
        }

        let outputScore = regionalContrastScore(
            output: output,
            backgrounds: backgrounds
        )
        let pole = bright
            ? AdaptiveRainbowTextColor(red: 1, green: 1, blue: 1)
            : AdaptiveRainbowTextColor(red: 0, green: 0, blue: 0)
        let poleScore = regionalContrastScore(
            output: pole,
            backgrounds: backgrounds
        )
        let target = min(preferredContrast, poleScore)
        let margin = outputScore - target
        audit.recordContrastMargin(margin, name: name)
        if margin < -contrastTolerance {
            audit.recordFailure(
                String(
                    format: "%@: contrast %.3f misses selected-polarity target %.3f",
                    name,
                    outputScore,
                    target
                )
            )
        }
    }

    private func expectedBrightPolarity(
        backgrounds: [SampledVideoColor]
    ) -> Bool {
        if isMixedLuminanceRegion(backgrounds) { return true }
        let white = AdaptiveRainbowTextColor(red: 1, green: 1, blue: 1)
        let black = AdaptiveRainbowTextColor(red: 0, green: 0, blue: 0)
        let whiteRegional = regionalContrastScore(
            output: white,
            backgrounds: backgrounds
        )
        let blackRegional = regionalContrastScore(
            output: black,
            backgrounds: backgrounds
        )
        if whiteRegional * 1.10 >= blackRegional { return true }
        return typicalContrastScore(output: white, backgrounds: backgrounds)
            >= typicalContrastScore(output: black, backgrounds: backgrounds)
    }

    private func isMixedLuminanceRegion(
        _ backgrounds: [SampledVideoColor]
    ) -> Bool {
        guard backgrounds.count > 1 else { return false }
        let luminances = backgrounds.map {
            min(1, $0.relativeLuminance + luminanceLift)
        }.sorted()
        let lowerIndex = Int(
            (Double(luminances.count - 1) * 0.25).rounded(.down)
        )
        let upperIndex = Int(
            (Double(luminances.count - 1) * 0.75).rounded(.up)
        )
        return luminances[lowerIndex] <= 0.34
            && luminances[upperIndex] >= 0.52
    }

    private func regionalContrastScore(
        output: AdaptiveRainbowTextColor,
        backgrounds: [SampledVideoColor]
    ) -> Double {
        let contrasts = contrasts(output: output, backgrounds: backgrounds)
            .sorted()
        let index = min(
            contrasts.count - 1,
            Int((Double(contrasts.count - 1) * 0.20).rounded(.down))
        )
        return contrasts[index]
    }

    private func typicalContrastScore(
        output: AdaptiveRainbowTextColor,
        backgrounds: [SampledVideoColor]
    ) -> Double {
        let values = contrasts(output: output, backgrounds: backgrounds).sorted()
        let midpoint = values.count / 2
        guard values.count.isMultiple(of: 2) else { return values[midpoint] }
        return (values[midpoint - 1] + values[midpoint]) / 2
    }

    private func contrasts(
        output: AdaptiveRainbowTextColor,
        backgrounds: [SampledVideoColor]
    ) -> [Double] {
        let foregroundLuminance = SampledVideoColor(
            red: output.red,
            green: output.green,
            blue: output.blue
        ).relativeLuminance
        return backgrounds.map { background in
            let backgroundLuminance = min(
                1,
                background.relativeLuminance + luminanceLift
            )
            let lighter = max(foregroundLuminance, backgroundLuminance)
            let darker = min(foregroundLuminance, backgroundLuminance)
            return (lighter + 0.05) / (darker + 0.05)
        }
    }

    private func auditNeighbouringTransitions(audit: inout AuditResult) {
        for palette in PlayerRainbowPalette.allCases {
            var previous: AdaptiveRainbowTextColor?
            for step in 0...512 {
                let value = Double(step) / 512
                let background = SampledVideoColor(
                    red: value,
                    green: value,
                    blue: value
                )
                let output = AdaptiveRainbowTextColor.resolve(
                    hueFrom: background,
                    contrastAgainst: Array(repeating: background, count: 24),
                    palette: palette,
                    luminanceLift: luminanceLift,
                    previous: previous
                )
                if let previous {
                    let delta = colorDistance(previous, output)
                    audit.recordTransition(
                        delta,
                        polarityChanged: isBright(previous) != isBright(output),
                        name: String(
                            format: "grey-ramp/%@/%d-%d bg %.4f->%.4f rgb (%.3f,%.3f,%.3f)->(%.3f,%.3f,%.3f)",
                            palette.rawValue,
                            step - 1,
                            step,
                            Double(step - 1) / 512,
                            value,
                            previous.red,
                            previous.green,
                            previous.blue,
                            output.red,
                            output.green,
                            output.blue
                        )
                    )
                }
                previous = output
            }
        }

        var generator = DeterministicGenerator(state: 0xC010_51DE_2026)
        for scenarioIndex in 0..<2_048 {
            let background = SampledVideoColor(
                red: generator.nextUnit(),
                green: generator.nextUnit(),
                blue: generator.nextUnit()
            )
            for component in 0..<3 {
                let neighbour = neighbouringColor(background, component: component)
                let firstBackgrounds = Array(repeating: background, count: 24)
                let secondBackgrounds = Array(repeating: neighbour, count: 24)

                let firstMonochrome = AdaptiveRainbowTextColor.resolveMonochrome(
                    against: firstBackgrounds,
                    luminanceLift: luminanceLift
                )
                let secondMonochrome = AdaptiveRainbowTextColor.resolveMonochrome(
                    against: secondBackgrounds,
                    luminanceLift: luminanceLift
                )
                audit.recordTransition(
                    colorDistance(firstMonochrome, secondMonochrome),
                    polarityChanged: isBright(firstMonochrome)
                        != isBright(secondMonochrome),
                    name: transitionName(
                        prefix: "seeded-neighbour-\(scenarioIndex)-\(component)/monochrome",
                        firstBackground: background,
                        secondBackground: neighbour,
                        firstOutput: firstMonochrome,
                        secondOutput: secondMonochrome
                    )
                )

                for palette in PlayerRainbowPalette.allCases {
                    let first = AdaptiveRainbowTextColor.resolve(
                        hueFrom: background,
                        contrastAgainst: firstBackgrounds,
                        palette: palette,
                        luminanceLift: luminanceLift
                    )
                    let second = AdaptiveRainbowTextColor.resolve(
                        hueFrom: neighbour,
                        contrastAgainst: secondBackgrounds,
                        palette: palette,
                        luminanceLift: luminanceLift,
                        previous: first
                    )
                    audit.recordTransition(
                        colorDistance(first, second),
                        polarityChanged: isBright(first) != isBright(second),
                        name: transitionName(
                            prefix: "seeded-neighbour-\(scenarioIndex)-\(component)/\(palette.rawValue)",
                            firstBackground: background,
                            secondBackground: neighbour,
                            firstOutput: first,
                            secondOutput: second
                        )
                    )
                }
            }
        }
    }

    private func neighbouringColor(
        _ color: SampledVideoColor,
        component: Int
    ) -> SampledVideoColor {
        var values = [color.red, color.green, color.blue]
        let step = 1.0 / 512
        values[component] += values[component] <= 1 - step ? step : -step
        return SampledVideoColor(red: values[0], green: values[1], blue: values[2])
    }

    private func transitionName(
        prefix: String,
        firstBackground: SampledVideoColor,
        secondBackground: SampledVideoColor,
        firstOutput: AdaptiveRainbowTextColor,
        secondOutput: AdaptiveRainbowTextColor
    ) -> String {
        String(
            format: "%@ bg (%.3f,%.3f,%.3f)->(%.3f,%.3f,%.3f) rgb (%.3f,%.3f,%.3f)->(%.3f,%.3f,%.3f)",
            prefix,
            firstBackground.red,
            firstBackground.green,
            firstBackground.blue,
            secondBackground.red,
            secondBackground.green,
            secondBackground.blue,
            firstOutput.red,
            firstOutput.green,
            firstOutput.blue,
            secondOutput.red,
            secondOutput.green,
            secondOutput.blue
        )
    }

    private func isBright(_ output: AdaptiveRainbowTextColor) -> Bool {
        max(output.red, output.green, output.blue) > 0.5
    }

    private func average(_ colors: [SampledVideoColor]) -> SampledVideoColor {
        let divisor = Double(colors.count)
        return SampledVideoColor(
            red: colors.reduce(0) { $0 + $1.red } / divisor,
            green: colors.reduce(0) { $0 + $1.green } / divisor,
            blue: colors.reduce(0) { $0 + $1.blue } / divisor
        )
    }

    private func interpolate(
        from: SampledVideoColor,
        to: SampledVideoColor,
        amount: Double
    ) -> SampledVideoColor {
        SampledVideoColor(
            red: from.red + (to.red - from.red) * amount,
            green: from.green + (to.green - from.green) * amount,
            blue: from.blue + (to.blue - from.blue) * amount
        )
    }

    private func colorDistance(
        _ first: AdaptiveRainbowTextColor,
        _ second: AdaptiveRainbowTextColor
    ) -> Double {
        sqrt(
            pow(first.red - second.red, 2)
                + pow(first.green - second.green, 2)
                + pow(first.blue - second.blue, 2)
        )
    }
}

private struct AuditResult {
    private static let retainedFailureCount = 40
    private static let retainedWorstCount = 10

    var outputCount = 0
    var failureCount = 0
    var failures: [String] = []
    private var worstContrastMargins: [(Double, String)] = []
    private var largestPolarityTransitions: [(Double, String)] = []
    private var largestSamePolarityTransitions: [(Double, String)] = []

    mutating func recordFailure(_ failure: String) {
        failureCount += 1
        if failures.count < Self.retainedFailureCount {
            failures.append(failure)
        }
    }

    mutating func recordContrastMargin(_ margin: Double, name: String) {
        worstContrastMargins.append((margin, name))
        worstContrastMargins.sort { $0.0 < $1.0 }
        if worstContrastMargins.count > Self.retainedWorstCount {
            worstContrastMargins.removeLast()
        }
    }

    mutating func recordTransition(
        _ delta: Double,
        polarityChanged: Bool,
        name: String
    ) {
        if polarityChanged {
            largestPolarityTransitions.append((delta, name))
            largestPolarityTransitions.sort { $0.0 > $1.0 }
            if largestPolarityTransitions.count > Self.retainedWorstCount {
                largestPolarityTransitions.removeLast()
            }
        } else {
            largestSamePolarityTransitions.append((delta, name))
            largestSamePolarityTransitions.sort { $0.0 > $1.0 }
            if largestSamePolarityTransitions.count > Self.retainedWorstCount {
                largestSamePolarityTransitions.removeLast()
            }
        }
    }

    mutating func requireSamePolarityTransitions(atMost maximum: Double) {
        guard let worst = largestSamePolarityTransitions.first,
              worst.0 > maximum
        else { return }
        recordFailure(
            String(
                format: "same-polarity transition %.3f exceeds %.3f: %@",
                worst.0,
                maximum,
                worst.1
            )
        )
    }

    var report: String {
        let contrast = worstContrastMargins.map {
            String(format: "  %.3f %@", $0.0, $0.1)
        }.joined(separator: "\n")
        let polarityTransitions = largestPolarityTransitions.map {
            String(format: "  %.3f %@", $0.0, $0.1)
        }.joined(separator: "\n")
        let samePolarityTransitions = largestSamePolarityTransitions.map {
            String(format: "  %.3f %@", $0.0, $0.1)
        }.joined(separator: "\n")
        return """
        Adaptive text color audit
        outputs: \(outputCount)
        failures: \(failureCount)
        worst contrast margins:
        \(contrast)
        largest polarity-changing neighboring-input output changes:
        \(polarityTransitions)
        largest same-polarity neighboring-input output changes:
        \(samePolarityTransitions)
        """
    }

    var failureReport: String {
        guard failureCount > 0 else { return "no failures" }
        let retained = failures.joined(separator: "\n")
        let omitted = max(0, failureCount - failures.count)
        return omitted > 0
            ? "\(retained)\n... \(omitted) additional failures omitted"
            : retained
    }
}

private struct DeterministicGenerator {
    var state: UInt64

    mutating func nextUnit() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
}
