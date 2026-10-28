import Foundation
import IlliquidCore
@testable import IlliquidPlayer
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// This driver calls the extracted production PlayerTextPalette.colors method.
// Fixture construction and component-hit seeding values are prepared before
// timing. Output consumption is identical for both variants and is timed too.
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

private struct Fixture {
    let name: String
    let mode: PlayerTextColorMode
    let region: PlayerTextContrastRegion
    let location: PlayerTextGridLocation?
    let aligned: PlayerTextGridRegion?
    let samples: [VideoColorSample]

    func key(_ palette: PlayerRainbowPalette) -> PlayerTextPaletteCacheKey {
        let keyLocation = region == .local ? location : nil
        return .init(column: keyLocation?.column ?? -1, row: keyLocation?.row ?? -1,
            contrastRegion: region, alignedRegion: aligned, mode: mode,
            rainbowPalette: palette)
    }
}

private func sample(_ distribution: String, seed: UInt64, one: Bool = false) -> VideoColorSample {
    var generator = Generator(state: seed)
    let colors = (0..<(one ? 1 : 96)).map { index -> SampledVideoColor in
        let red = generator.unit(), green = generator.unit(), blue = generator.unit()
        switch distribution {
        case "bright": return .init(red: 0.85 + red * 0.15, green: 0.85 + green * 0.15, blue: 0.85 + blue * 0.15)
        case "dark": return .init(red: red * 0.08, green: green * 0.08, blue: blue * 0.08)
        case "midgray":
            let value = 0.47 + red * 0.10
            return .init(red: value, green: value, blue: value)
        case "mixed":
            // Keep the mixed luminance shape while making every revision distinct.
            let value = index.isMultiple(of: 2) ? red * 0.015 : 0.985 + red * 0.015
            return .init(red: value, green: value, blue: value)
        case "saturated":
            switch index % 3 {
            case 0: return .init(red: 0.7 + red * 0.3, green: green * 0.2, blue: blue * 0.2)
            case 1: return .init(red: red * 0.2, green: 0.7 + green * 0.3, blue: blue * 0.2)
            default: return .init(red: red * 0.2, green: green * 0.2, blue: 0.7 + blue * 0.3)
            }
        default: return .init(red: red, green: green, blue: blue)
        }
    }
    return .init(columns: one ? 1 : 12, rows: one ? 1 : 8, colors: colors)
}

private func fixtures() -> [Fixture] {
    let local = PlayerTextGridLocation(column: 5, row: 4)
    let localRegion = PlayerTextGridRegion(minimumColumn: 4, maximumColumn: 6,
        minimumRow: 3, maximumRow: 5)
    let letterbox = PlayerTextGridRegion(minimumColumn: 0, maximumColumn: 11,
        minimumRow: 0, maximumRow: 7, canvasSampleCount: 128)
    let definitions: [(String, String, PlayerTextContrastRegion, PlayerTextGridLocation?, PlayerTextGridRegion?)] = [
        ("one", "varied", .local, .init(column: 0, row: 0), nil),
        ("local9-bright", "bright", .local, local, localRegion),
        ("local9-dark", "dark", .local, local, localRegion),
        ("local9-midgray", "midgray", .local, local, localRegion),
        ("leading32-saturated", "saturated", .leading, nil, nil),
        ("bottom24-varied", "varied", .bottom, nil, nil),
        ("overall96-bright", "bright", .overall, nil, nil),
        ("overall96-dark", "dark", .overall, nil, nil),
        ("overall96-midgray", "midgray", .overall, nil, nil),
        ("overall96-mixed", "mixed", .overall, nil, nil),
        ("overall96-varied", "varied", .overall, nil, nil),
        ("letterbox224", "varied", .local, local, letterbox),
    ]
    return definitions.enumerated().flatMap { index, definition in
        let samples = (0..<8).map {
            sample(definition.1, seed: UInt64(index * 97 + $0 + 1), one: definition.0 == "one")
        }
        return [PlayerTextColorMode.dynamicRainbow, .dynamicMonochrome].map { mode in
            Fixture(name: definition.0 + (mode == .dynamicRainbow ? "-rainbow" : "-mono"),
                mode: mode, region: definition.2, location: definition.3,
                aligned: definition.4, samples: samples)
        }
    }
}

@MainActor
private func colors(_ fixture: Fixture, index: Int, palette: PlayerRainbowPalette,
                    store: PlaybackVideoColorStore?) -> PlayerTextStyleColors {
    PlayerTextPalette(theme: .liquidGlass, mode: fixture.mode, rainbowPalette: palette,
        sample: store?.sample ?? fixture.samples[index], store: store)
        .colors(at: fixture.location, contrastRegion: fixture.region, alignedRegion: fixture.aligned)
}

@MainActor
private func components(_ fixture: Fixture, index: Int,
                        palette: PlayerRainbowPalette) -> AdaptiveRainbowTextColor {
    let value = fixture.samples[index]
    let local = fixture.location.map {
        value.average(minimumColumn: $0.column - 1, maximumColumn: $0.column + 1,
            minimumRow: $0.row - 1, maximumRow: $0.row + 1)
    } ?? value.overall
    let context = AdaptiveTextLegibility(backgrounds: fixture.region.colors(
        in: value, localColor: local, alignedRegion: fixture.aligned), luminanceLift: 0.08)
    return context.resolve(hueSource: fixture.region.color(in: value, localColor: local,
        alignedRegion: fixture.aligned), palette: palette,
        monochrome: fixture.mode == .dynamicMonochrome, previous: nil)
}

private func colorBits(_ color: Color) -> [UInt64] {
#if canImport(SwiftUI)
    let resolved = color.resolve(in: EnvironmentValues())
    return [resolved.red, resolved.green, resolved.blue, resolved.opacity].map { UInt64($0.bitPattern) }
#else
    return [color.red, color.green, color.blue, color.alpha].map(\.bitPattern)
#endif
}

@inline(never)
private func consume(_ style: PlayerTextStyleColors) -> UInt64 {
    var result = UInt64(Double(style.contrastHaloRadius).bitPattern)
    for color in [style.primary, style.secondary, style.tertiary, style.contrastHalo] {
        for value in colorBits(color) { result = (result ^ value) &* 0x100000001b3 }
    }
    return result
}

private func receipt(_ style: PlayerTextStyleColors) -> [String: Any] {
    ["colors": [style.primary, style.secondary, style.tertiary, style.contrastHalo].map {
        colorBits($0).map { String($0, radix: 16) }
    }, "halo_radius": String(Double(style.contrastHaloRadius).bitPattern, radix: 16)]
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func emit(_ value: Any) throws {
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    FileHandle.standardOutput.write(Data([10]))
}

@MainActor
private func timing(_ fixture: Fixture, kernel: String, iterations: Int, warmup: Int) throws {
    let palettes = PlayerRainbowPalette.allCases
    let seeded = kernel == "component_hit" ? fixture.samples.indices.map { index in
        palettes.map { components(fixture, index: index, palette: $0) }
    } : []

    func prepare() -> PlaybackVideoColorStore? {
        guard kernel != "uncached" else { return nil }
        let store = PlaybackVideoColorStore(sample: fixture.samples[kernel == "hit" ? 0 : 7])
        if kernel == "hit" {
            for palette in palettes { _ = colors(fixture, index: 0, palette: palette, store: store) }
        }
        return store
    }

    func run(_ count: Int, store: PlaybackVideoColorStore?) -> UInt64 {
        var checksum: UInt64 = 0
        for iteration in 0..<count {
            let index = iteration & 7
            let paletteIndex = (iteration / 8) % palettes.count
            let palette = palettes[paletteIndex]
            if kernel == "revision" || kernel == "component_hit" {
                store!.publish(fixture.samples[index])
            }
            if kernel == "component_hit" {
                _ = PlayerTextPaletteCache.shared.resolve(store: store!, key: fixture.key(palette)) { _ in
                    seeded[index][paletteIndex]
                }
            }
            let style = colors(fixture, index: index, palette: palette, store: store)
            checksum &+= consume(style) &* UInt64((iteration & 127) + 1)
        }
        return checksum
    }

    let warmupChecksum = run(warmup, store: prepare())
    let store = prepare()
    let cpuStart = cpuNanoseconds()
    let start = DispatchTime.now().uptimeNanoseconds
    let checksum = run(iterations, store: store)
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let cpuElapsed = cpuNanoseconds() - cpuStart
    try emit(["case": fixture.name, "kernel": kernel, "iterations": iterations,
        "warmup_iterations": warmup, "elapsed_ns": elapsed, "cpu_elapsed_ns": cpuElapsed,
        "ns_per_operation": Double(elapsed) / Double(iterations),
        "cpu_ns_per_operation": Double(cpuElapsed) / Double(iterations),
        "checksum": String(checksum, radix: 16), "warmup_checksum": String(warmupChecksum, radix: 16),
        "revision": store?.revision ?? 0, "generation": store?.generation ?? 0])
}

// Keep complete bit receipts, including transitions and hit paths, outside
// timing. Comparing two separately compiled historical/current implementations
// checks the production call graph rather than a second handwritten algorithm.
@MainActor
private func verify() throws {
    for fixture in fixtures() {
        let store = PlaybackVideoColorStore()
        for cycle in 0..<3 {
            if cycle == 2 { store.reset() }
            for index in fixture.samples.indices {
                store.publish(fixture.samples[index])
                for palette in PlayerRainbowPalette.allCases {
                    let uncached = colors(fixture, index: index, palette: palette, store: nil)
                    let first = colors(fixture, index: index, palette: palette, store: store)
                    let hit = colors(fixture, index: index, palette: palette, store: store)
                    precondition(consume(first) == consume(hit), "style cache altered output")
                    try emit(["case": fixture.name, "cycle": cycle, "sample": index,
                        "palette": palette.rawValue, "uncached": receipt(uncached),
                        "revision_miss": receipt(first), "hit": receipt(hit),
                        "revision": store.revision, "generation": store.generation])
                }
            }
        }
        // Source changes and returning to an older owner discard history.
        let other = PlaybackVideoColorStore(sample: fixture.samples[3])
        for active in [other, store, other] {
            try emit(["case": fixture.name, "store_switch": active === other,
                "style": receipt(colors(fixture, index: 3, palette: .balanced, store: active))])
        }
        // Isolate source identity: these owners have identical counters but
        // different samples, so generation/revision checks alone cannot help.
        let firstOwner = PlaybackVideoColorStore(sample: fixture.samples[0])
        let secondOwner = PlaybackVideoColorStore(sample: fixture.samples[7])
        precondition(firstOwner.generation == secondOwner.generation && firstOwner.revision == secondOwner.revision)
        for (index, active) in [firstOwner, secondOwner, firstOwner].enumerated() {
            try emit(["case": fixture.name, "equal_counter_switch": index,
                "style": receipt(colors(fixture, index: 0, palette: .balanced, store: active))])
        }
        // A components hit with a style miss already used one context before.
        let seededStore = PlaybackVideoColorStore()
        for index in fixture.samples.indices {
            seededStore.publish(fixture.samples[index])
            for palette in PlayerRainbowPalette.allCases {
                let seeded = components(fixture, index: index, palette: palette)
                _ = PlayerTextPaletteCache.shared.resolve(store: seededStore, key: fixture.key(palette)) { _ in seeded }
                try emit(["case": fixture.name, "component_hit": index, "palette": palette.rawValue,
                    "style": receipt(colors(fixture, index: index, palette: palette, store: seededStore))])
            }
        }
    }

    // Cache saturation, per-key geometry, nil location, clamping, letterboxing,
    // fallback modes/themes, and reset are covered using actual public inputs.
    let values = sample("varied", seed: 98_765)
    let store = PlaybackVideoColorStore(sample: values)
    for cycle in 0..<2 {
        if cycle == 1 { store.publish(sample("bright", seed: 76_543)) }
        for index in 0..<300 {
            let region = PlayerTextGridRegion(minimumColumn: (index % 16) - 2,
                maximumColumn: 13, minimumRow: (index % 10) - 1, maximumRow: 8,
                canvasSampleCount: index - 20)
            let palette = PlayerTextPalette(theme: .liquidGlass, mode: .dynamicRainbow,
                rainbowPalette: .complementary, sample: store.sample, store: store)
            let location = PlayerTextGridLocation(column: index - 10, row: index % 8)
            let first = palette.colors(at: location, contrastRegion: .local, alignedRegion: region)
            let again = palette.colors(at: location, contrastRegion: .local, alignedRegion: region)
            precondition(consume(first) == consume(again))
            try emit(["overflow": index, "cycle": cycle, "style": receipt(first),
                "entry_count": PlayerTextPaletteCache.shared.entryCount])
        }
    }
    for theme in PlayerTheme.allCases {
        for mode in PlayerTextColorMode.allCases {
            for hasSample in [false, true] {
                let palette = PlayerTextPalette(theme: theme, mode: mode, rainbowPalette: .softSpectrum,
                    sample: hasSample ? values : nil, store: nil)
                try emit(["fallback_theme": theme.rawValue, "mode": mode.rawValue,
                    "has_sample": hasSample, "style": receipt(palette.colors(
                        at: nil, contrastRegion: .overall, alignedRegion: nil))])
            }
        }
    }
}

@main
private struct Main {
    @MainActor static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "cases":
            try emit(fixtures().map { ["name": $0.name, "mode": $0.mode.rawValue,
                "variants": $0.samples.count] as [String: Any] })
        case "verify": try verify()
        case "time":
            guard arguments.count == 5,
                  let fixture = fixtures().first(where: { $0.name == arguments[1] }),
                  ["uncached", "revision", "hit", "component_hit"].contains(arguments[2]),
                  let iterations = Int(arguments[3]), iterations > 0,
                  let warmup = Int(arguments[4]), warmup >= 0
            else { fatalError("Usage: time CASE KERNEL ITERATIONS WARMUP") }
            try timing(fixture, kernel: arguments[2], iterations: iterations, warmup: warmup)
        default: fatalError("Usage: cases | verify | time CASE KERNEL ITERATIONS WARMUP")
        }
    }
}
