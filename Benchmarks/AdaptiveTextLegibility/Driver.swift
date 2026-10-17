import Foundation
import IlliquidCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Inputs are prepared outside the timed region. No UI, sampled-region lookup,
// palette-cache lookup, or color decoding is included in these numeric kernels.
private struct Generator {
    var state: UInt64

    mutating func unit() -> Double {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return Double((value ^ (value >> 31)) >> 11) / 9_007_199_254_740_992
    }
}

private struct Variant {
    let backgrounds: [SampledVideoColor]
    let hue: SampledVideoColor
    let previous: AdaptiveRainbowTextColor?
    let foreground: AdaptiveRainbowTextColor
    let lift: Double
}

private struct Fixture {
    let name: String
    let distribution: String
    let count: Int
    let monochrome: Bool
    let variants: [Variant]
}

private func makeVariant(count: Int, distribution: String, seed: UInt64,
                         lift: Double = 0.08) -> Variant {
    var generator = Generator(state: seed)
    let colors = (0..<count).map { index -> SampledVideoColor in
        let r = generator.unit(), g = generator.unit(), b = generator.unit()
        switch distribution {
        case "bright":
            return .init(red: 0.85 + r * 0.15, green: 0.85 + g * 0.15, blue: 0.85 + b * 0.15)
        case "dark":
            return .init(red: r * 0.08, green: g * 0.08, blue: b * 0.08)
        case "midgray":
            let value = 0.47 + r * 0.1
            return .init(red: value, green: value, blue: value)
        case "mixed":
            let value = index % 2 == 0 ? 0.0 : 1.0
            return .init(red: value, green: value, blue: value)
        case "letterbox":
            return index >= 96 ? .init(red: 0, green: 0, blue: 0) : .init(red: r, green: g, blue: b)
        case "saturated":
            switch index % 3 {
            case 0: return .init(red: 0.7 + 0.3 * r, green: g * 0.2, blue: b * 0.2)
            case 1: return .init(red: r * 0.2, green: 0.7 + 0.3 * g, blue: b * 0.2)
            default: return .init(red: r * 0.2, green: g * 0.2, blue: 0.7 + 0.3 * b)
            }
        default:
            return .init(red: r, green: g, blue: b)
        }
    }
    let hue = colors.isEmpty
        ? SampledVideoColor(red: generator.unit(), green: generator.unit(), blue: generator.unit())
        : VideoColorSample(columns: count, rows: 1, colors: colors).overall
    let previous: AdaptiveRainbowTextColor?
    switch seed % 5 {
    case 0: previous = nil
    case 1: previous = .init(red: 0, green: 0, blue: 0)
    case 2: previous = .init(red: 1, green: 1, blue: 1)
    case 3: previous = .init(red: 0.5, green: 0.5, blue: 0.5)
    default: previous = .init(red: generator.unit(), green: generator.unit(), blue: generator.unit())
    }
    return Variant(backgrounds: colors, hue: hue, previous: previous,
                   foreground: .init(red: generator.unit(), green: generator.unit(), blue: generator.unit()),
                   lift: lift)
}

private func fixtures() -> [Fixture] {
    let regions: [(String, Int, String)] = [
        ("one", 1, "varied"),
        ("local9-bright", 9, "bright"),
        ("local9-dark", 9, "dark"),
        ("local9-midgray", 9, "midgray"),
        ("leading32-saturated", 32, "saturated"),
        ("overall96-bright", 96, "bright"),
        ("overall96-dark", 96, "dark"),
        ("overall96-midgray", 96, "midgray"),
        ("overall96-mixed", 96, "mixed"),
        ("overall96-varied", 96, "varied"),
        ("letterbox224", 224, "letterbox"),
    ]
    return regions.enumerated().flatMap { index, region in
        let variants = (0..<8).map {
            makeVariant(count: region.1, distribution: region.2,
                        seed: UInt64(index * 97 + $0 + 1))
        }
        return [false, true].map { monochrome in
            Fixture(name: region.0 + (monochrome ? "-mono" : "-rainbow"),
                    distribution: region.2, count: region.1,
                    monochrome: monochrome, variants: variants)
        }
    }
}

// Mirrors the numeric call graph of uncachedColors -> resolvedComponents:
// one context for primary resolution, then a second context for both opacities.
// The two initializations deliberately remain separate, as in PlayerTheme.swift.
@inline(never)
private func styleMiss(_ variant: Variant, monochrome: Bool,
                       palette: PlayerRainbowPalette) -> Double {
    let primaryContext = AdaptiveTextLegibility(backgrounds: variant.backgrounds,
                                                luminanceLift: variant.lift)
    let foreground = primaryContext.resolve(hueSource: variant.hue, palette: palette,
                                            monochrome: monochrome, previous: variant.previous)
    let opacityContext = AdaptiveTextLegibility(backgrounds: variant.backgrounds,
                                                luminanceLift: variant.lift)
    let secondary = opacityContext.readableOpacity(for: foreground, preferred: 0.96)
    let tertiary = opacityContext.readableOpacity(for: foreground, preferred: 0.90)
    return foreground.red + foreground.green * 2 + foreground.blue * 3
        + secondary * 5 + tertiary * 7 + (opacityContext.isMixed ? 11 : 13)
}

// A deliberately low-reuse control includes initialization and just one score.
@inline(never)
private func initScore(_ variant: Variant) -> Double {
    let context = AdaptiveTextLegibility(backgrounds: variant.backgrounds, luminanceLift: variant.lift)
    return context.score(variant.foreground)
}

@inline(never)
private func score(_ context: AdaptiveTextLegibility, _ foreground: AdaptiveRainbowTextColor) -> Double {
    context.score(foreground)
}

@inline(never)
private func opacity(_ context: AdaptiveTextLegibility, _ foreground: AdaptiveRainbowTextColor) -> Double {
    context.readableOpacity(for: foreground, preferred: 0.96)
        + context.readableOpacity(for: foreground, preferred: 0.90) * 2
}

private func bits(_ value: Double) -> String { String(value.bitPattern, radix: 16) }

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func emit(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

private func timing(fixture: Fixture, kernel: String, iterations: Int, warmup: Int) throws {
    let contexts = fixture.variants.map {
        AdaptiveTextLegibility(backgrounds: $0.backgrounds, luminanceLift: $0.lift)
    }
    let foregrounds = zip(contexts, fixture.variants).map {
        $0.resolve(hueSource: $1.hue, palette: .softSpectrum,
                   monochrome: fixture.monochrome, previous: $1.previous)
    }
    let palettes = PlayerRainbowPalette.allCases
    func run(_ count: Int) -> UInt64 {
        var checksum: UInt64 = 0
        for iteration in 0..<count {
            let index = iteration & 7
            let value: Double
            switch kernel {
            case "style_miss":
                value = styleMiss(fixture.variants[index], monochrome: fixture.monochrome,
                                  palette: palettes[iteration % palettes.count])
            case "init_score": value = initScore(fixture.variants[index])
            case "score": value = score(contexts[index], fixture.variants[index].foreground)
            case "opacity": value = opacity(contexts[index], foregrounds[index])
            default: fatalError("Unknown kernel: \(kernel)")
            }
            checksum &+= value.bitPattern &* UInt64((iteration & 127) + 1)
        }
        return checksum
    }
    let warmupChecksum = run(warmup)
    let cpuStart = cpuNanoseconds()
    let start = DispatchTime.now().uptimeNanoseconds
    let checksum = run(iterations)
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let cpuElapsed = cpuNanoseconds() - cpuStart
    try emit(["case": fixture.name, "kernel": kernel, "iterations": iterations,
              "warmup_iterations": warmup, "elapsed_ns": elapsed,
              "ns_per_operation": Double(elapsed) / Double(iterations),
              "cpu_elapsed_ns": cpuElapsed,
              "cpu_ns_per_operation": Double(cpuElapsed) / Double(iterations),
              "checksum": String(checksum, radix: 16),
              "warmup_checksum": String(warmupChecksum, radix: 16)])
}

// Exact bit receipts are emitted in a separate, untimed process. Besides all
// palettes and both modes, these cover empty input, duplicates, previous colors,
// finite clamping, nonfinite lifts/preferences, and direct score kernels.
private func receipts(count: Int) throws {
    let sizes = [0, 1, 2, 3, 9, 32, 96, 224]
    let distributions = ["bright", "dark", "midgray", "mixed", "saturated", "varied", "letterbox"]
    let lifts: [Double] = [-.infinity, -1, -0.0, 0, 0.08, 0.3, 1, 4, .infinity, .nan]
    let preferences: [Double] = [-.infinity, -1, -0.0, 0, 0.25, 0.90, 0.96, 1, 2, .infinity, .nan]
    let directOpacities = [0.0, 0.25, 0.5, 0.9, 0.96, 1.0]
    for sample in 0..<count {
        let variant = makeVariant(count: sizes[sample % sizes.count],
            distribution: distributions[sample % distributions.count],
            seed: UInt64(sample + 1) &* 7919, lift: lifts[sample % lifts.count])
        let context = AdaptiveTextLegibility(backgrounds: variant.backgrounds, luminanceLift: variant.lift)
        for palette in PlayerRainbowPalette.allCases {
            for monochrome in [false, true] {
                let foreground = context.resolve(hueSource: variant.hue, palette: palette,
                                                  monochrome: monochrome, previous: variant.previous)
                try emit(["sample": sample, "count": variant.backgrounds.count,
                          "palette": palette.rawValue, "monochrome": monochrome,
                          "lift_bits": bits(variant.lift), "mixed": context.isMixed,
                          "rgb": [foreground.red, foreground.green, foreground.blue].map(bits),
                          "scores": [context.score(foreground), context.score(variant.foreground),
                                     context.score(.init(red: 0, green: 0, blue: 0)),
                                     context.score(.init(red: 1, green: 1, blue: 1))].map(bits),
                          "preferences": preferences.map(bits),
                          "readable_opacities": preferences.map {
                              bits(context.readableOpacity(for: foreground, preferred: $0))
                          },
                          "random_foreground_opacities": preferences.map {
                              bits(context.readableOpacity(for: variant.foreground, preferred: $0))
                          },
                          "opacity_scores": directOpacities.map {
                              bits(context.opacityScore(foreground, opacity: $0))
                          }])
            }
        }
    }
}

@main
private struct Main {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "cases":
            try emit(fixtures().map {
                ["name": $0.name, "source_background_count": $0.count,
                 "expanded_background_count": $0.count * 3,
                 "distribution": $0.distribution, "monochrome": $0.monochrome,
                 "variant_count": $0.variants.count] as [String: Any]
            })
        case "time":
            guard arguments.count == 5, let fixture = fixtures().first(where: { $0.name == arguments[1] }),
                  let iterations = Int(arguments[3]), iterations > 0,
                  let warmup = Int(arguments[4]), warmup >= 0 else {
                fatalError("Usage: time CASE KERNEL ITERATIONS WARMUP")
            }
            try timing(fixture: fixture, kernel: arguments[2], iterations: iterations, warmup: warmup)
        case "receipts":
            try receipts(count: arguments.count > 1 ? Int(arguments[1])! : 320)
        default:
            fatalError("Usage: cases | time CASE KERNEL ITERATIONS WARMUP | receipts [COUNT]")
        }
    }
}
