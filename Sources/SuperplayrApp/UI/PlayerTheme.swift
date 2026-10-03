import AppKit
import Observation
import SuperplayrCore
import SuperplayrPlayer
import SwiftUI

enum PlayerTheme: String, CaseIterable, Hashable, Identifiable, Sendable {
    case liquidGlass = "liquid-glass"
    case graphite
    case midnight
    case nord
    case classic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .liquidGlass: "Liquid Glass"
        case .graphite: "Graphite"
        case .midnight: "Midnight"
        case .nord: "Nord"
        case .classic: "Classic macOS"
        }
    }

    var description: String {
        switch self {
        case .liquidGlass:
            "Clear native glass that adapts to the video beneath it."
        case .graphite:
            "Opaque charcoal surfaces with restrained blue accents."
        case .midnight:
            "Near-black navy surfaces with a vivid violet accent."
        case .nord:
            "Cool slate surfaces with an ice-blue accent."
        case .classic:
            "Traditional macOS materials, compact corners, and the system accent."
        }
    }

    var preferredColorScheme: ColorScheme { .dark }

    var primaryColor: Color {
        switch self {
        case .liquidGlass:
            Color.white
        case .graphite, .classic:
            Color.white.opacity(0.96)
        case .midnight:
            Color(red: 0.94, green: 0.95, blue: 1)
        case .nord:
            Color(red: 0.93, green: 0.95, blue: 0.98)
        }
    }

    var secondaryColor: Color {
        switch self {
        case .liquidGlass, .classic:
            Color.white.opacity(0.68)
        case .graphite:
            Color(red: 0.72, green: 0.74, blue: 0.78)
        case .midnight:
            Color(red: 0.65, green: 0.69, blue: 0.82)
        case .nord:
            Color(red: 0.71, green: 0.75, blue: 0.82)
        }
    }

    var accentColor: Color {
        switch self {
        case .liquidGlass, .classic:
            Color.accentColor
        case .graphite:
            Color(red: 0.38, green: 0.65, blue: 0.98)
        case .midnight:
            Color(red: 0.62, green: 0.48, blue: 1)
        case .nord:
            Color(red: 0.53, green: 0.75, blue: 0.82)
        }
    }

    var previewSurfaceColor: Color {
        switch self {
        case .liquidGlass:
            Color(red: 0.36, green: 0.39, blue: 0.45)
        case .graphite:
            Color(red: 0.12, green: 0.13, blue: 0.15)
        case .midnight:
            Color(red: 0.025, green: 0.035, blue: 0.08)
        case .nord:
            Color(red: 0.18, green: 0.20, blue: 0.25)
        case .classic:
            Color(red: 0.22, green: 0.23, blue: 0.25)
        }
    }

    var hoverFillColor: Color {
        primaryColor.opacity(self == .liquidGlass ? 0.07 : 0.12)
    }

    var selectedFillColor: Color {
        self == .liquidGlass
            ? primaryColor.opacity(0.14)
            : accentColor.opacity(0.24)
    }

    var separatorColor: Color {
        primaryColor.opacity(self == .liquidGlass ? 0.14 : 0.18)
    }

    var titlebarSeparatorColor: Color {
        primaryColor.opacity(self == .liquidGlass ? 0.16 : 0.18)
    }

    var selectedEdgeColor: Color {
        primaryColor.opacity(self == .liquidGlass ? 0.18 : 0.22)
    }

    var playingIndicatorColor: Color {
        self == .liquidGlass
            ? primaryColor.opacity(0.88)
            : accentColor.opacity(0.9)
    }

    var surfaceStyle: PlayerThemeSurfaceStyle {
        switch self {
        case .liquidGlass: .liquidGlass
        case .classic: .classicMaterial
        case .graphite, .midnight, .nord: .solid
        }
    }

    func surfaceColor(for role: PlayerOverlaySurfaceRole) -> Color {
        let opacity = role == .status ? 0.98 : 0.96
        switch self {
        case .liquidGlass:
            return .clear
        case .graphite:
            return Color(red: 0.105, green: 0.11, blue: 0.125).opacity(opacity)
        case .midnight:
            return Color(red: 0.025, green: 0.035, blue: 0.075).opacity(opacity)
        case .nord:
            return Color(red: 0.18, green: 0.20, blue: 0.25).opacity(opacity)
        case .classic:
            return .clear
        }
    }

    func resolvedCornerRadius(_ proposed: CGFloat) -> CGFloat {
        switch self {
        case .liquidGlass:
            proposed
        case .graphite, .nord:
            max(10, proposed - 4)
        case .midnight:
            max(8, proposed - 6)
        case .classic:
            max(7, proposed - 8)
        }
    }

    var surfaceShadowRadius: CGFloat {
        switch self {
        case .liquidGlass: 12
        case .graphite, .midnight, .nord: 9
        case .classic: 5
        }
    }

    var appKitPrimaryColor: NSColor {
        switch self {
        case .liquidGlass:
            NSColor.white
        case .graphite, .classic:
            NSColor.white.withAlphaComponent(0.96)
        case .midnight:
            NSColor(srgbRed: 0.94, green: 0.95, blue: 1, alpha: 1)
        case .nord:
            NSColor(srgbRed: 0.93, green: 0.95, blue: 0.98, alpha: 1)
        }
    }

    var appKitSecondaryColor: NSColor {
        switch self {
        case .liquidGlass, .classic:
            NSColor.white.withAlphaComponent(0.68)
        case .graphite:
            NSColor(srgbRed: 0.72, green: 0.74, blue: 0.78, alpha: 1)
        case .midnight:
            NSColor(srgbRed: 0.65, green: 0.69, blue: 0.82, alpha: 1)
        case .nord:
            NSColor(srgbRed: 0.71, green: 0.75, blue: 0.82, alpha: 1)
        }
    }

    var appKitAccentColor: NSColor {
        switch self {
        case .liquidGlass:
            NSColor(srgbRed: 0.78, green: 0.80, blue: 0.82, alpha: 1)
        case .graphite:
            NSColor(srgbRed: 0.38, green: 0.65, blue: 0.98, alpha: 1)
        case .midnight:
            NSColor(srgbRed: 0.62, green: 0.48, blue: 1, alpha: 1)
        case .nord:
            NSColor(srgbRed: 0.53, green: 0.75, blue: 0.82, alpha: 1)
        case .classic:
            NSColor.controlAccentColor
        }
    }
}

enum PlayerThemeSurfaceStyle {
    case liquidGlass
    case classicMaterial
    case solid
}

enum PlayerTextColorMode: String, CaseIterable, Hashable, Identifiable, Sendable {
    case dynamicRainbow = "dynamic-rainbow"
    case dynamicMonochrome = "dynamic-monochrome"
    case staticColor = "static"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dynamicRainbow: "Dynamic Rainbow"
        case .dynamicMonochrome: "Dynamic Black / White / Grey"
        case .staticColor: "Static"
        }
    }

    var description: String {
        switch self {
        case .dynamicRainbow:
            "Samples the video and chooses adaptive, readable hues."
        case .dynamicMonochrome:
            "Samples the video and chooses adaptive neutral text."
        case .staticColor:
            "Uses the theme's normal text colors without sampling video frames."
        }
    }

    var usesVideoSampling: Bool { self != .staticColor }
}

enum PlayerRainbowPalette: String, CaseIterable, Hashable, Identifiable, Sendable {
    case softSpectrum
    case balanced
    case analogous
    case complementary
    case warm
    case cool

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .softSpectrum: "Soft Spectrum"
        case .balanced: "Balanced"
        case .analogous: "Analogous"
        case .complementary: "Complementary"
        case .warm: "Warm"
        case .cool: "Cool"
        }
    }

    var description: String {
        switch self {
        case .softSpectrum:
            "Uses a quieter full-spectrum palette with restrained saturation."
        case .balanced:
            "Uses the current harmonic rainbow across the full color wheel."
        case .analogous:
            "Uses neighboring hues for calmer, smoother color changes."
        case .complementary:
            "Uses hues farther from the sampled video color for stronger separation."
        case .warm:
            "Restricts adaptive color to reds, oranges, and golds."
        case .cool:
            "Restricts adaptive color to cyan, blue, and violet hues."
        }
    }

    fileprivate func candidateHues(from sourceHue: Double) -> [Double] {
        switch self {
        case .softSpectrum:
            [0.10, -0.10, 0.20, -0.20].map { sourceHue + $0 }
        case .balanced:
            [0.125, -0.125, 0.25, -0.25].map { sourceHue + $0 }
        case .analogous:
            [1.0 / 12, -1.0 / 12, 1.0 / 6, -1.0 / 6].map {
                sourceHue + $0
            }
        case .complementary:
            [0.5, 5.0 / 12, 7.0 / 12, 1.0 / 3].map { sourceHue + $0 }
        case .warm:
            [0, 0.05, 0.10, 0.15]
        case .cool:
            [0.50, 0.58, 0.67, 0.75]
        }
    }

    fileprivate func saturation(for sourceSaturation: Double) -> Double {
        let base: Double
        let influence: Double
        let maximum: Double
        switch self {
        case .softSpectrum:
            (base, influence, maximum) = (0.38, 0.08, 0.48)
        case .balanced, .warm, .cool:
            (base, influence, maximum) = (0.58, 0.14, 0.74)
        case .analogous:
            (base, influence, maximum) = (0.50, 0.12, 0.66)
        case .complementary:
            (base, influence, maximum) = (0.64, 0.16, 0.80)
        }
        return min(max(base + sourceSaturation * influence, base), maximum)
    }
}

enum PlayerTextSamplingCoordinateSpace {
    static let name = "PlayerTextSamplingCoordinateSpace"
}

struct PlayerTextGridLocation: Equatable {
    let column: Int
    let row: Int

    static func resolve(
        frame: CGRect,
        viewportSize: CGSize,
        columns: Int,
        rows: Int
    ) -> Self? {
        resolve(
            frame: frame,
            videoContentRect: CGRect(origin: .zero, size: viewportSize),
            columns: columns,
            rows: rows
        )
    }

    static func resolve(
        frame: CGRect,
        videoContentRect: CGRect,
        columns: Int,
        rows: Int
    ) -> Self? {
        guard columns > 0,
              rows > 0,
              videoContentRect.width > 0,
              videoContentRect.height > 0,
              !frame.isNull,
              !frame.isInfinite
        else { return nil }
        let normalizedX = min(max(
            (frame.midX - videoContentRect.minX) / videoContentRect.width,
            0
        ), 0.999_999)
        let normalizedY = min(max(
            (frame.midY - videoContentRect.minY) / videoContentRect.height,
            0
        ), 0.999_999)
        return Self(
            column: Int(normalizedX * Double(columns)),
            row: Int(normalizedY * Double(rows))
        )
    }
}

struct PlayerTextGridRegion: Equatable, Hashable {
    let minimumColumn: Int
    let maximumColumn: Int
    let minimumRow: Int
    let maximumRow: Int
    var canvasSampleCount: Int = 0

    static func resolve(
        frame: CGRect,
        videoContentRect: CGRect,
        videoClipRect: CGRect? = nil,
        columns: Int,
        rows: Int
    ) -> Self? {
        guard columns > 0,
              rows > 0,
              videoContentRect.width > 0,
              videoContentRect.height > 0,
              !frame.isNull,
              !frame.isInfinite
        else { return nil }
        let overlap = frame.intersection(videoContentRect)
            .intersection(videoClipRect ?? videoContentRect)
        guard !overlap.isNull, !overlap.isEmpty else { return nil }

        var region = Self(
            minimumColumn: sampleCenterMinimumIndex(
                normalizedMinimum: normalized(
                    overlap.minX,
                    origin: videoContentRect.minX,
                    length: videoContentRect.width
                ),
                normalizedMaximum: normalized(
                    overlap.maxX,
                    origin: videoContentRect.minX,
                    length: videoContentRect.width
                ),
                count: columns
            ),
            maximumColumn: sampleCenterMaximumIndex(
                normalizedMinimum: normalized(
                    overlap.minX,
                    origin: videoContentRect.minX,
                    length: videoContentRect.width
                ),
                normalizedMaximum: normalized(
                    overlap.maxX,
                    origin: videoContentRect.minX,
                    length: videoContentRect.width
                ),
                count: columns
            ),
            minimumRow: sampleCenterMinimumIndex(
                normalizedMinimum: normalized(
                    overlap.minY,
                    origin: videoContentRect.minY,
                    length: videoContentRect.height
                ),
                normalizedMaximum: normalized(
                    overlap.maxY,
                    origin: videoContentRect.minY,
                    length: videoContentRect.height
                ),
                count: rows
            ),
            maximumRow: sampleCenterMaximumIndex(
                normalizedMinimum: normalized(
                    overlap.minY,
                    origin: videoContentRect.minY,
                    length: videoContentRect.height
                ),
                normalizedMaximum: normalized(
                    overlap.maxY,
                    origin: videoContentRect.minY,
                    length: videoContentRect.height
                ),
                count: rows
            )
        )
        // Decoded samples omit the black presentation canvas. Include its
        // proportional coverage when text straddles a letterbox/crop edge.
        // Quantize to sample counts so subpixel layout changes do not churn
        // the palette cache, and bound the extra work for tiny overlaps.
        let videoSamples = (region.maximumColumn - region.minimumColumn + 1)
            * (region.maximumRow - region.minimumRow + 1)
        let visibleArea = overlap.width * overlap.height
        let canvasArea = max(0, frame.width * frame.height - visibleArea)
        region.canvasSampleCount = Int(min(128,
            (CGFloat(videoSamples) * canvasArea / visibleArea).rounded()))
        return region
    }

    private static func normalized(
        _ value: CGFloat,
        origin: CGFloat,
        length: CGFloat
    ) -> Double {
        min(max(Double((value - origin) / length), 0), 1)
    }

    private static func sampleCenterMinimumIndex(
        normalizedMinimum: Double,
        normalizedMaximum: Double,
        count: Int
    ) -> Int {
        let first = Int(ceil(normalizedMinimum * Double(count) - 0.5))
        let last = Int(floor(normalizedMaximum * Double(count) - 0.5))
        if first <= last { return min(max(first, 0), count - 1) }
        return midpointIndex(
            normalizedMinimum: normalizedMinimum,
            normalizedMaximum: normalizedMaximum,
            count: count
        )
    }

    private static func sampleCenterMaximumIndex(
        normalizedMinimum: Double,
        normalizedMaximum: Double,
        count: Int
    ) -> Int {
        let first = Int(ceil(normalizedMinimum * Double(count) - 0.5))
        let last = Int(floor(normalizedMaximum * Double(count) - 0.5))
        if first <= last { return min(max(last, 0), count - 1) }
        return midpointIndex(
            normalizedMinimum: normalizedMinimum,
            normalizedMaximum: normalizedMaximum,
            count: count
        )
    }

    private static func midpointIndex(
        normalizedMinimum: Double,
        normalizedMaximum: Double,
        count: Int
    ) -> Int {
        min(max(
            Int(((normalizedMinimum + normalizedMaximum) / 2) * Double(count)),
            0
        ), count - 1)
    }

    func colors(in sample: VideoColorSample) -> [SampledVideoColor] {
        let minimumColumn = min(max(self.minimumColumn, 0), sample.columns - 1)
        let maximumColumn = min(
            max(self.maximumColumn, minimumColumn),
            sample.columns - 1
        )
        let minimumRow = min(max(self.minimumRow, 0), sample.rows - 1)
        let maximumRow = min(max(self.maximumRow, minimumRow), sample.rows - 1)

        let videoColors = (minimumRow...maximumRow).flatMap { row in
            (minimumColumn...maximumColumn).map { column in
                sample.color(column: column, row: row)
            }
        }
        return videoColors + Array(repeating: SampledVideoColor(red: 0, green: 0, blue: 0),
                                   count: min(max(canvasSampleCount, 0), 128))
    }
}

enum PlayerTextVideoGeometry {
    static func contentRect(
        viewportSize: CGSize,
        aspectRatio: Double?
    ) -> CGRect {
        let bounds = CGRect(origin: .zero, size: viewportSize)
        guard viewportSize.width > 0,
              viewportSize.height > 0,
              let aspectRatio,
              aspectRatio.isFinite,
              aspectRatio > 0
        else { return bounds }
        let resolvedAspectRatio = CGFloat(aspectRatio)

        let viewportAspectRatio = viewportSize.width / viewportSize.height
        if viewportAspectRatio > resolvedAspectRatio {
            let width = viewportSize.height * resolvedAspectRatio
            return CGRect(
                x: (viewportSize.width - width) / 2,
                y: 0,
                width: width,
                height: viewportSize.height
            )
        }
        let height = viewportSize.width / resolvedAspectRatio
        return CGRect(
            x: 0,
            y: (viewportSize.height - height) / 2,
            width: viewportSize.width,
            height: height
        )
    }
}

@MainActor
@Observable
private final class PlayerTextSamplingLayout {
    static let shared = PlayerTextSamplingLayout()

    private(set) var leadingRegion: PlayerTextGridRegion?

    func setLeadingRegion(_ region: PlayerTextGridRegion?) {
        guard leadingRegion != region else { return }
        leadingRegion = region
    }
}

enum PlayerDynamicTextRole {
    case primary
    case secondary
    case tertiary

    var opacity: Double {
        switch self {
        case .primary: 1
        case .secondary: 0.96
        case .tertiary: 0.90
        }
    }
}

enum PlayerTextContrastRegion: Hashable {
    case local
    case overall
    case leading
    case bottom

    func color(
        in sample: VideoColorSample,
        localColor: SampledVideoColor,
        alignedRegion: PlayerTextGridRegion?
    ) -> SampledVideoColor {
        switch self {
        case .local: return localColor
        case .overall: return sample.overall
        case .leading:
            guard let alignedRegion else { return sample.leading }
            return sample.average(
                minimumColumn: alignedRegion.minimumColumn,
                maximumColumn: alignedRegion.maximumColumn,
                minimumRow: alignedRegion.minimumRow,
                maximumRow: alignedRegion.maximumRow
            )
        case .bottom: return sample.bottom
        }
    }

    func colors(
        in sample: VideoColorSample,
        localColor: SampledVideoColor,
        alignedRegion: PlayerTextGridRegion?
    ) -> [SampledVideoColor] {
        switch self {
        case .local:
            return alignedRegion?.colors(in: sample) ?? [localColor]
        case .overall:
            return sample.colors
        case .leading:
            let region = alignedRegion ?? PlayerTextGridRegion(
                minimumColumn: 0,
                maximumColumn: max(
                    0,
                    Int((Double(sample.columns) * 0.32).rounded(.up)) - 1
                ),
                minimumRow: 0,
                maximumRow: sample.rows - 1
            )
            return region.colors(in: sample)
        case .bottom:
            return PlayerTextGridRegion(
                minimumColumn: 0,
                maximumColumn: sample.columns - 1,
                minimumRow: min(
                    sample.rows - 1,
                    Int((Double(sample.rows) * 0.72 - 0.5).rounded(.up))
                ),
                maximumRow: sample.rows - 1
            ).colors(in: sample)
        }
    }
}

fileprivate struct PlayerTextStyleColors {
    let primary: Color
    let secondary: Color
    let tertiary: Color
    let contrastHalo: Color
    let contrastHaloRadius: CGFloat

    func color(for role: PlayerDynamicTextRole) -> Color {
        switch role {
        case .primary: primary
        case .secondary: secondary
        case .tertiary: tertiary
        }
    }
}

struct PlayerTextPaletteCacheKey: Hashable {
    let column: Int
    let row: Int
    let contrastRegion: PlayerTextContrastRegion
    let alignedRegion: PlayerTextGridRegion?
    let mode: PlayerTextColorMode
    let rainbowPalette: PlayerRainbowPalette
}

@MainActor
final class PlayerTextPaletteCache {
    static let shared = PlayerTextPaletteCache()

    private weak var source: PlaybackVideoColorStore?
    private var generation: UInt64?
    private var styles: [PlayerTextPaletteCacheKey: PlayerTextStyleColors] = [:]
    static let maximumEntries = 256
    var entryCount: Int { components.count + previousComponents.count }
    private var revision: UInt64?
    private var components: [
        PlayerTextPaletteCacheKey: AdaptiveRainbowTextColor
    ] = [:]
    private var previousComponents: [
        PlayerTextPaletteCacheKey: AdaptiveRainbowTextColor
    ] = [:]

    func resolve(
        store: PlaybackVideoColorStore,
        key: PlayerTextPaletteCacheKey,
        make: (AdaptiveRainbowTextColor?) -> AdaptiveRainbowTextColor
    ) -> AdaptiveRainbowTextColor {
        update(for: store)
        if let cached = components[key] { return cached }
        let resolved = make(previousComponents[key])
        if components.count < Self.maximumEntries { components[key] = resolved }
        return resolved
    }
    fileprivate func style(store: PlaybackVideoColorStore, key: PlayerTextPaletteCacheKey,
                           make: () -> PlayerTextStyleColors) -> PlayerTextStyleColors {
        update(for: store)
        if let cached = styles[key] { return cached }
        let result = make()
        if styles.count < Self.maximumEntries { styles[key] = result }
        return result
    }

    private func update(for store: PlaybackVideoColorStore) {
        if source !== store || generation != store.generation {
            source = store
            generation = store.generation
            revision = store.revision
            styles.removeAll(keepingCapacity: true)
            components.removeAll(keepingCapacity: true)
            previousComponents.removeAll(keepingCapacity: true)
        } else if revision != store.revision {
            revision = store.revision
            previousComponents = components
            styles.removeAll(keepingCapacity: true)
            components.removeAll(keepingCapacity: true)
        }
    }

}

@MainActor
struct PlayerTextPalette {
    private static let estimatedClearGlassLuminanceLift = 0.08
    let theme: PlayerTheme
    let mode: PlayerTextColorMode
    let rainbowPalette: PlayerRainbowPalette
    let sample: VideoColorSample?
    let store: PlaybackVideoColorStore?

    fileprivate func colors(
        at location: PlayerTextGridLocation?,
        contrastRegion: PlayerTextContrastRegion,
        alignedRegion: PlayerTextGridRegion?
    ) -> PlayerTextStyleColors {
        guard theme == .liquidGlass, mode.usesVideoSampling, sample != nil, let store else {
            return uncachedColors(at: location, contrastRegion: contrastRegion, alignedRegion: alignedRegion)
        }
        return PlayerTextPaletteCache.shared.style(store: store,
            key: cacheKey(at: location, contrastRegion: contrastRegion, alignedRegion: alignedRegion)) {
            uncachedColors(at: location, contrastRegion: contrastRegion, alignedRegion: alignedRegion)
        }
    }

    private func cacheKey(at location: PlayerTextGridLocation?, contrastRegion: PlayerTextContrastRegion,
                          alignedRegion: PlayerTextGridRegion?) -> PlayerTextPaletteCacheKey {
        let cacheLocation = contrastRegion == .local ? location : nil
        return PlayerTextPaletteCacheKey(column: cacheLocation?.column ?? -1, row: cacheLocation?.row ?? -1,
            contrastRegion: contrastRegion, alignedRegion: alignedRegion, mode: mode, rainbowPalette: rainbowPalette)
    }

    private func uncachedColors(at location: PlayerTextGridLocation?, contrastRegion: PlayerTextContrastRegion,
                                alignedRegion: PlayerTextGridRegion?) -> PlayerTextStyleColors {
        guard theme == .liquidGlass, mode.usesVideoSampling, let sample else {
            return PlayerTextStyleColors(
                primary: fallbackColor(for: .primary),
                secondary: fallbackColor(for: .secondary),
                tertiary: fallbackColor(for: .tertiary),
                contrastHalo: .clear,
                contrastHaloRadius: 0
            )
        }
        let components = resolvedComponents(
            at: location,
            contrastRegion: contrastRegion,
            alignedRegion: alignedRegion,
            sample: sample
        )
        let color = Color(
            red: components.red,
            green: components.green,
            blue: components.blue
        )
        let localColor = sampledColor(at: location, in: sample)
        let backgroundLuminances = contrastRegion.colors(
            in: sample,
            localColor: localColor,
            alignedRegion: alignedRegion
        ).map {
            min(
                1,
                $0.relativeLuminance
                    + Self.estimatedClearGlassLuminanceLift
            )
        }
        let legibility = AdaptiveTextLegibility(backgrounds: contrastRegion.colors(
            in: sample, localColor: localColor, alignedRegion: alignedRegion),
            luminanceLift: Self.estimatedClearGlassLuminanceLift)
        let usesContrastHalo = AdaptiveRainbowTextColor
            .isMixedLuminanceRegion(backgroundLuminances)
        let usesBrightForeground = max(
            components.red,
            components.green,
            components.blue
        ) > 0.5
        return PlayerTextStyleColors(
            primary: color,
            secondary: color.opacity(legibility.readableOpacity(for: components, preferred: PlayerDynamicTextRole.secondary.opacity)),
            tertiary: color.opacity(legibility.readableOpacity(for: components, preferred: PlayerDynamicTextRole.tertiary.opacity)),
            contrastHalo: usesContrastHalo
                ? (usesBrightForeground
                    ? Color.black.opacity(0.82)
                    : Color.white.opacity(0.76))
                : .clear,
            contrastHaloRadius: usesContrastHalo ? 1.4 : 0
        )
    }

    private func resolvedComponents(
        at location: PlayerTextGridLocation?,
        contrastRegion: PlayerTextContrastRegion,
        alignedRegion: PlayerTextGridRegion?,
        sample: VideoColorSample
    ) -> AdaptiveRainbowTextColor {
        let make = { (previous: AdaptiveRainbowTextColor?) in
            let localColor = sampledColor(at: location, in: sample)
            let paletteColor = contrastRegion.color(
                in: sample,
                localColor: localColor,
                alignedRegion: alignedRegion
            )
            let legibility = AdaptiveTextLegibility(backgrounds: contrastRegion.colors(
                in: sample, localColor: localColor, alignedRegion: alignedRegion),
                luminanceLift: Self.estimatedClearGlassLuminanceLift)
            return legibility.resolve(hueSource: paletteColor, palette: rainbowPalette,
                monochrome: mode == .dynamicMonochrome, previous: previous)
        }
        guard let store else { return make(nil) }
        return PlayerTextPaletteCache.shared.resolve(store: store,
            key: cacheKey(at: location, contrastRegion: contrastRegion, alignedRegion: alignedRegion), make: make)
    }

    private func fallbackColor(for role: PlayerDynamicTextRole) -> Color {
        switch role {
        case .primary:
            theme.primaryColor
        case .secondary:
            theme.secondaryColor
        case .tertiary:
            theme.secondaryColor.opacity(0.72)
        }
    }

    private func sampledColor(
        at location: PlayerTextGridLocation?,
        in sample: VideoColorSample
    ) -> SampledVideoColor {
        guard let location else { return sample.overall }
        return sample.average(
            minimumColumn: location.column - 1,
            maximumColumn: location.column + 1,
            minimumRow: location.row - 1,
            maximumRow: location.row + 1
        )
    }
}

@MainActor
private struct DynamicPlayerTextStyleModifier: ViewModifier {
    let store: PlaybackVideoColorStore?
    let role: PlayerDynamicTextRole?
    let contrastRegion: PlayerTextContrastRegion
    let publishesLeadingRegion: Bool
    let appliesControlTint: Bool
    let opacity: Double
    @State private var location: PlayerTextGridLocation?
    @State private var localRegion: PlayerTextGridRegion?
    @State private var isOutsideVideo = false
    @State private var samplingLayout = PlayerTextSamplingLayout.shared
    @Environment(\.playerTheme) private var theme
    @Environment(\.playerTextColorMode) private var mode
    @Environment(\.playerRainbowPalette) private var rainbowPalette
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.playbackVideoColorStore) private var environmentStore
    @Environment(\.playerTextSamplingViewportSize) private var viewportSize
    @Environment(\.playerTextSamplingVideoClipRect) private var videoClipRect
    @Environment(\.playerTextSamplingVideoContentRect) private var videoContentRect

    func body(content: Content) -> some View {
        let activeStore = store ?? environmentStore
        let sample = activeStore?.sample
        let viewportSize = viewportSize
        let resolvedVideoContentRect = videoContentRect.isEmpty
            ? CGRect(origin: .zero, size: viewportSize)
            : videoContentRect
        let resolvedClipRect = videoClipRect.isEmpty ? resolvedVideoContentRect : videoClipRect
        let palette = PlayerTextPalette(
            theme: theme,
            mode: colorSchemeContrast == .increased && mode.usesVideoSampling ? .dynamicMonochrome : mode,
            rainbowPalette: rainbowPalette,
            sample: isOutsideVideo ? nil : sample,
            store: isOutsideVideo ? nil : activeStore
        )
        styled(content: content, palette: palette)
            // The sampler and palette already smooth safe transitions. A second
            // UI interpolation could cross an unreadable grey during polarity flips.
            .animation(nil, value: activeStore?.revision)
            .onGeometryChange(for: PlayerTextSamplingGeometry?.self) { proxy in
                guard let sample else { return nil }
                let frame = proxy.frame(
                    in: .named(PlayerTextSamplingCoordinateSpace.name)
                )
                return PlayerTextSamplingGeometry.resolve(
                    frame: frame,
                    videoContentRect: resolvedVideoContentRect,
                    videoClipRect: resolvedClipRect,
                    columns: sample.columns,
                    rows: sample.rows
                )
            } action: { geometry in
                location = geometry?.location
                localRegion = geometry?.region
                isOutsideVideo = geometry?.isOutsideVideo ?? false
                if publishesLeadingRegion {
                    samplingLayout.setLeadingRegion(geometry?.region)
                }
            }
            .onDisappear {
                if publishesLeadingRegion {
                    samplingLayout.setLeadingRegion(nil)
                }
            }
    }

    @ViewBuilder
    private func styled(
        content: Content,
        palette: PlayerTextPalette
    ) -> some View {
        let colors = palette.colors(
            at: location,
            contrastRegion: contrastRegion,
            alignedRegion: contrastRegion == .leading
                ? samplingLayout.leadingRegion
                : contrastRegion == .local ? localRegion : nil
        )
        if let role {
            let color = colors.color(for: role).opacity(opacity)
            if appliesControlTint {
                content
                    .foregroundStyle(color)
                    .tint(color)
                    .shadow(
                        color: colors.contrastHalo,
                        radius: colors.contrastHaloRadius,
                        y: 0.5
                    )
            } else {
                content
                    .foregroundStyle(color)
                    .shadow(
                        color: colors.contrastHalo,
                        radius: colors.contrastHaloRadius,
                        y: 0.5
                    )
            }
        } else {
            let primary = colors.primary.opacity(opacity)
            if appliesControlTint {
                content
                    .foregroundStyle(
                        primary,
                        colors.secondary.opacity(opacity),
                        colors.tertiary.opacity(opacity)
                    )
                    .tint(primary)
                    .shadow(
                        color: colors.contrastHalo,
                        radius: colors.contrastHaloRadius,
                        y: 0.5
                    )
            } else {
                content
                    .foregroundStyle(
                        primary,
                        colors.secondary.opacity(opacity),
                        colors.tertiary.opacity(opacity)
                    )
                    .shadow(
                        color: colors.contrastHalo,
                        radius: colors.contrastHaloRadius,
                        y: 0.5
                    )
            }
        }
    }

}

struct PlayerTextSamplingGeometry: Equatable {
    let location: PlayerTextGridLocation
    let isOutsideVideo: Bool
    let region: PlayerTextGridRegion?

    static func resolve(frame: CGRect, videoContentRect: CGRect, videoClipRect: CGRect,
                        columns: Int, rows: Int) -> Self? {
        guard let location = PlayerTextGridLocation.resolve(frame: frame,
            videoContentRect: videoContentRect, columns: columns, rows: rows) else { return nil }
        let region = PlayerTextGridRegion.resolve(frame: frame,
            videoContentRect: videoContentRect, videoClipRect: videoClipRect,
            columns: columns, rows: rows)
        return Self(location: location, isOutsideVideo: region == nil, region: region)
    }
}

struct AdaptiveRainbowTextColor: Equatable {
    private static let preferredContrastRatio = 5.5
    private static let contrastSearchSteps = 8
    private static let regionalContrastPercentile = 0.20
    private static let darkPolarityMinimumAdvantage = 1.10
    private static let previousCandidateChromaTolerance = 0.04
    private static let reliableSourceChromaThreshold = 0.04
    private static let maximumSamePolarityTransitionDistance = 0.12
    private static let mixedRegionLowerLuminanceCeiling = 0.34
    private static let mixedRegionUpperLuminanceFloor = 0.52
    private static let mixedRegionMaximumSaturation = 0.18
    let red: Double
    let green: Double
    let blue: Double

    static func resolve(against background: SampledVideoColor) -> Self {
        resolve(
            hueFrom: background,
            contrastAgainst: background,
            palette: .softSpectrum
        )
    }

    static func resolve(
        hueFrom hueSource: SampledVideoColor,
        contrastAgainst background: SampledVideoColor,
        palette: PlayerRainbowPalette = .softSpectrum,
        luminanceLift: Double = 0
    ) -> Self {
        resolve(
            hueFrom: hueSource,
            contrastAgainst: [background],
            palette: palette,
            luminanceLift: luminanceLift
        )
    }

    static func resolve(
        hueFrom hueSource: SampledVideoColor,
        contrastAgainst backgrounds: [SampledVideoColor],
        palette: PlayerRainbowPalette = .softSpectrum,
        luminanceLift: Double = 0,
        previous: Self? = nil
    ) -> Self {
        precondition(!backgrounds.isEmpty)
        let candidateHues = palette.candidateHues(from: hueSource.hue).map {
            normalizedHue($0)
        }
        let backgroundLuminances = backgrounds.map {
            min(1, $0.relativeLuminance + max(0, luminanceLift))
        }.sorted()
        let usesMixedRegionFallback = isMixedLuminanceRegion(
            backgroundLuminances
        )
        let saturation = min(
            palette.saturation(for: hueSource.saturation),
            usesMixedRegionFallback ? mixedRegionMaximumSaturation : 1
        )
        let whiteContrast = regionalContrastScore(
            foreground: Self(red: 1, green: 1, blue: 1),
            backgroundLuminances: backgroundLuminances
        )
        let blackContrast = regionalContrastScore(
            foreground: Self(red: 0, green: 0, blue: 0),
            backgroundLuminances: backgroundLuminances
        )

        let prefersBrightPolarity = prefersBrightPolarity(
            whiteContrast: whiteContrast,
            blackContrast: blackContrast,
            backgroundLuminances: backgroundLuminances,
            usesNearTiePreference: backgrounds.count > 1
        )
        if prefersBrightPolarity {
            let targetContrast = min(preferredContrastRatio, whiteContrast)
            return mostChromatic(candidateHues.map {
                readableBrightColor(
                    hue: $0,
                    saturation: saturation,
                    backgroundLuminances: backgroundLuminances,
                    targetContrast: targetContrast
                )
            }, previous: previous,
               sourceChroma: sourceChroma(hueSource),
               backgroundLuminances: backgroundLuminances,
               targetContrast: targetContrast)
        }
        let targetContrast = min(preferredContrastRatio, blackContrast)
        return mostChromatic(candidateHues.map {
            readableDarkColor(
                hue: $0,
                saturation: min(0.8, saturation + 0.06),
                backgroundLuminances: backgroundLuminances,
                targetContrast: targetContrast
            )
        }, previous: previous,
           sourceChroma: sourceChroma(hueSource),
           backgroundLuminances: backgroundLuminances,
           targetContrast: targetContrast)
    }

    static func resolveMonochrome(
        against background: SampledVideoColor,
        luminanceLift: Double = 0
    ) -> Self {
        resolveMonochrome(
            against: [background],
            luminanceLift: luminanceLift
        )
    }

    static func resolveMonochrome(
        against backgrounds: [SampledVideoColor],
        luminanceLift: Double = 0
    ) -> Self {
        precondition(!backgrounds.isEmpty)
        let backgroundLuminances = backgrounds.map {
            min(1, $0.relativeLuminance + max(0, luminanceLift))
        }.sorted()
        let white = Self(red: 1, green: 1, blue: 1)
        let black = Self(red: 0, green: 0, blue: 0)
        let whiteContrast = regionalContrastScore(
            foreground: white,
            backgroundLuminances: backgroundLuminances
        )
        let blackContrast = regionalContrastScore(
            foreground: black,
            backgroundLuminances: backgroundLuminances
        )

        if prefersBrightPolarity(
            whiteContrast: whiteContrast,
            blackContrast: blackContrast,
            backgroundLuminances: backgroundLuminances,
            usesNearTiePreference: true
        ) {
            let target = min(preferredContrastRatio, whiteContrast)
            var unreadableValue = 0.5
            var readableValue = 1.0
            for _ in 0..<contrastSearchSteps {
                let candidateValue = (unreadableValue + readableValue) / 2
                let candidate = Self(
                    red: candidateValue,
                    green: candidateValue,
                    blue: candidateValue
                )
                if regionalContrastScore(
                    foreground: candidate,
                    backgroundLuminances: backgroundLuminances
                ) >= target {
                    readableValue = candidateValue
                } else {
                    unreadableValue = candidateValue
                }
            }
            return Self(
                red: readableValue,
                green: readableValue,
                blue: readableValue
            )
        }

        let target = min(preferredContrastRatio, blackContrast)
        var readableValue = 0.0
        var unreadableValue = 0.5
        for _ in 0..<contrastSearchSteps {
            let candidateValue = (readableValue + unreadableValue) / 2
            let candidate = Self(
                red: candidateValue,
                green: candidateValue,
                blue: candidateValue
            )
            if regionalContrastScore(
                foreground: candidate,
                backgroundLuminances: backgroundLuminances
            ) >= target {
                readableValue = candidateValue
            } else {
                unreadableValue = candidateValue
            }
        }
        return Self(
            red: readableValue,
            green: readableValue,
            blue: readableValue
        )
    }

    private static func regionalContrastScore(
        foreground: Self,
        backgroundLuminances: [Double]
    ) -> Double {
        let foregroundLuminance = SampledVideoColor(red: foreground.red, green: foreground.green,
                                                    blue: foreground.blue).relativeLuminance
        return contrastQuantile(luminance: foregroundLuminance,
            sortedBackgrounds: backgroundLuminances,
            rank: Int(Double(backgroundLuminances.count - 1) * regionalContrastPercentile))
    }

    // Background luminances are sorted once per palette resolution. Contrast is
    // monotonic outward from the foreground, so merge the two sides only up to
    // the requested rank instead of allocating/sorting for every hue candidate.
    static func contrastQuantile(luminance: Double, sortedBackgrounds: [Double], rank: Int) -> Double {
        var low = 0
        var high = sortedBackgrounds.count
        while low < high {
            let mid = (low + high) / 2
            if sortedBackgrounds[mid] < luminance { low = mid + 1 } else { high = mid }
        }
        var left = low - 1
        var right = low
        var result = 1.0
        for _ in 0...rank {
            let lower = left >= 0 ? (luminance + 0.05) / (sortedBackgrounds[left] + 0.05) : Double.infinity
            let upper = right < sortedBackgrounds.count ? (sortedBackgrounds[right] + 0.05) / (luminance + 0.05) : Double.infinity
            if lower <= upper { result = lower; left -= 1 }
            else { result = upper; right += 1 }
        }
        return result
    }

    private static func prefersBrightPolarity(
        whiteContrast: Double,
        blackContrast: Double,
        backgroundLuminances: [Double],
        usesNearTiePreference: Bool
    ) -> Bool {
        if usesNearTiePreference,
           isMixedLuminanceRegion(backgroundLuminances)
        {
            return true
        }
        let regionalPreference = usesNearTiePreference
            ? whiteContrast * darkPolarityMinimumAdvantage >= blackContrast
            : whiteContrast >= blackContrast
        if regionalPreference { return true }
        guard backgroundLuminances.count > 1 else { return false }

        let whiteTypicalContrast = typicalContrastScore(
            foreground: Self(red: 1, green: 1, blue: 1),
            backgroundLuminances: backgroundLuminances
        )
        let blackTypicalContrast = typicalContrastScore(
            foreground: Self(red: 0, green: 0, blue: 0),
            backgroundLuminances: backgroundLuminances
        )
        return whiteTypicalContrast >= blackTypicalContrast
    }

    static func isMixedLuminanceRegion(
        _ backgroundLuminances: [Double]
    ) -> Bool {
        guard backgroundLuminances.count > 1 else { return false }
        let sorted = backgroundLuminances.sorted()
        let lowerIndex = Int(
            (Double(sorted.count - 1) * 0.25).rounded(.down)
        )
        let upperIndex = Int(
            (Double(sorted.count - 1) * 0.75).rounded(.up)
        )
        return sorted[lowerIndex] <= mixedRegionLowerLuminanceCeiling
            && sorted[upperIndex] >= mixedRegionUpperLuminanceFloor
    }

    private static func typicalContrastScore(
        foreground: Self,
        backgroundLuminances: [Double]
    ) -> Double {
        let foregroundLuminance = SampledVideoColor(red: foreground.red, green: foreground.green,
                                                    blue: foreground.blue).relativeLuminance
        let midpoint = backgroundLuminances.count / 2
        let upper = contrastQuantile(luminance: foregroundLuminance, sortedBackgrounds: backgroundLuminances, rank: midpoint)
        guard backgroundLuminances.count.isMultiple(of: 2) else { return upper }
        let lower = contrastQuantile(luminance: foregroundLuminance, sortedBackgrounds: backgroundLuminances, rank: midpoint - 1)
        return (lower + upper) / 2
    }

    private static func normalizedHue(_ hue: Double) -> Double {
        let remainder = hue.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private static func mostChromatic(
        _ colors: [Self],
        previous: Self?,
        sourceChroma: Double,
        backgroundLuminances: [Double],
        targetContrast: Double
    ) -> Self {
        let mostChromatic = colors.dropFirst().reduce(colors[0]) {
            result,
            candidate in
            candidate.chroma > result.chroma ? candidate : result
        }
        guard let previous,
              isBright(previous) == isBright(mostChromatic)
        else { return mostChromatic }

        if sourceChroma <= reliableSourceChromaThreshold,
           regionalContrastScore(
               foreground: previous,
               backgroundLuminances: backgroundLuminances
           ) >= targetContrast
        {
            return previous
        }

        let eligible = colors.filter {
            mostChromatic.chroma - $0.chroma
                <= previousCandidateChromaTolerance
        }
        let selected = eligible.min {
            colorDistanceSquared($0, previous)
                < colorDistanceSquared($1, previous)
        } ?? mostChromatic
        return limitedTransition(
            from: previous,
            to: selected,
            backgroundLuminances: backgroundLuminances,
            targetContrast: targetContrast
        )
    }

    private static func isBright(_ color: Self) -> Bool {
        max(color.red, color.green, color.blue) > 0.5
    }

    private static func sourceChroma(_ color: SampledVideoColor) -> Double {
        max(color.red, color.green, color.blue)
            - min(color.red, color.green, color.blue)
    }

    private static func colorDistanceSquared(_ first: Self, _ second: Self) -> Double {
        let red = first.red - second.red
        let green = first.green - second.green
        let blue = first.blue - second.blue
        return red * red + green * green + blue * blue
    }

    private static func limitedTransition(
        from previous: Self,
        to target: Self,
        backgroundLuminances: [Double],
        targetContrast: Double
    ) -> Self {
        let distance = sqrt(colorDistanceSquared(previous, target))
        guard distance > maximumSamePolarityTransitionDistance else {
            return target
        }

        let limitedAmount = maximumSamePolarityTransitionDistance / distance
        let limited = interpolate(from: previous, to: target, amount: limitedAmount)
        guard regionalContrastScore(
            foreground: limited,
            backgroundLuminances: backgroundLuminances
        ) < targetContrast else { return limited }

        var unreadableAmount = limitedAmount
        var readableAmount = 1.0
        for _ in 0..<contrastSearchSteps {
            let candidateAmount = (unreadableAmount + readableAmount) / 2
            let candidate = interpolate(
                from: previous,
                to: target,
                amount: candidateAmount
            )
            if regionalContrastScore(
                foreground: candidate,
                backgroundLuminances: backgroundLuminances
            ) >= targetContrast {
                readableAmount = candidateAmount
            } else {
                unreadableAmount = candidateAmount
            }
        }
        return interpolate(from: previous, to: target, amount: readableAmount)
    }

    private static func interpolate(
        from first: Self,
        to second: Self,
        amount: Double
    ) -> Self {
        Self(
            red: first.red + (second.red - first.red) * amount,
            green: first.green + (second.green - first.green) * amount,
            blue: first.blue + (second.blue - first.blue) * amount
        )
    }

    private var chroma: Double {
        max(red, green, blue) - min(red, green, blue)
    }

    private static func readableBrightColor(
        hue: Double,
        saturation: Double,
        backgroundLuminances: [Double],
        targetContrast: Double
    ) -> Self {
        let preferred = hsv(hue: hue, saturation: saturation, value: 1)
        guard regionalContrastScore(
            foreground: preferred,
            backgroundLuminances: backgroundLuminances
        ) < targetContrast else { return preferred }

        var readableSaturation = 0.0
        var unreadableSaturation = saturation
        for _ in 0..<contrastSearchSteps {
            let candidateSaturation = (
                readableSaturation + unreadableSaturation
            ) / 2
            let candidate = hsv(
                hue: hue,
                saturation: candidateSaturation,
                value: 1
            )
            if regionalContrastScore(
                foreground: candidate,
                backgroundLuminances: backgroundLuminances
            ) >= targetContrast {
                readableSaturation = candidateSaturation
            } else {
                unreadableSaturation = candidateSaturation
            }
        }
        return hsv(hue: hue, saturation: readableSaturation, value: 1)
    }

    private static func readableDarkColor(
        hue: Double,
        saturation: Double,
        backgroundLuminances: [Double],
        targetContrast: Double
    ) -> Self {
        let preferredValue = 0.42
        let preferred = hsv(
            hue: hue,
            saturation: saturation,
            value: preferredValue
        )
        guard regionalContrastScore(
            foreground: preferred,
            backgroundLuminances: backgroundLuminances
        ) < targetContrast else { return preferred }

        var readableValue = 0.0
        var unreadableValue = preferredValue
        for _ in 0..<contrastSearchSteps {
            let candidateValue = (readableValue + unreadableValue) / 2
            let candidate = hsv(
                hue: hue,
                saturation: saturation,
                value: candidateValue
            )
            if regionalContrastScore(
                foreground: candidate,
                backgroundLuminances: backgroundLuminances
            ) >= targetContrast {
                readableValue = candidateValue
            } else {
                unreadableValue = candidateValue
            }
        }
        return hsv(hue: hue, saturation: saturation, value: readableValue)
    }

    private static func hsv(
        hue: Double,
        saturation: Double,
        value: Double
    ) -> Self {
        let sector = hue * 6
        let index = Int(floor(sector)) % 6
        let fraction = sector - floor(sector)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * fraction)
        let t = value * (1 - saturation * (1 - fraction))

        return switch index {
        case 0: Self(red: value, green: t, blue: p)
        case 1: Self(red: q, green: value, blue: p)
        case 2: Self(red: p, green: value, blue: t)
        case 3: Self(red: p, green: q, blue: value)
        case 4: Self(red: t, green: p, blue: value)
        default: Self(red: value, green: p, blue: q)
        }
    }

    private static func contrastRatio(
        foreground: Self,
        backgroundLuminance: Double
    ) -> Double {
        let foregroundLuminance = SampledVideoColor(
            red: foreground.red,
            green: foreground.green,
            blue: foreground.blue
        ).relativeLuminance
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

@MainActor
@Observable
final class PlayerThemeStore {
    static let storageKey = "Superplayr.interface-theme.v1"
    static let textColorModeStorageKey = "Superplayr.text-color-mode.v1"
    static let rainbowPaletteStorageKey = "Superplayr.rainbow-palette.v1"
    static let shared = PlayerThemeStore()

    private let defaults: UserDefaults
    private(set) var selection: PlayerTheme
    private(set) var textColorMode: PlayerTextColorMode
    private(set) var rainbowPalette: PlayerRainbowPalette

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: Self.storageKey)
            .flatMap(PlayerTheme.init(rawValue:))
            ?? .liquidGlass
        textColorMode = defaults.string(forKey: Self.textColorModeStorageKey)
            .flatMap(PlayerTextColorMode.init(rawValue:))
            ?? .dynamicRainbow
        rainbowPalette = defaults.string(forKey: Self.rainbowPaletteStorageKey)
            .flatMap(PlayerRainbowPalette.init(rawValue:))
            ?? .softSpectrum
    }

    func select(_ theme: PlayerTheme) {
        guard selection != theme else { return }
        selection = theme
        defaults.set(theme.rawValue, forKey: Self.storageKey)
    }

    func selectTextColorMode(_ mode: PlayerTextColorMode) {
        guard textColorMode != mode else { return }
        textColorMode = mode
        defaults.set(mode.rawValue, forKey: Self.textColorModeStorageKey)
    }

    func selectRainbowPalette(_ palette: PlayerRainbowPalette) {
        guard rainbowPalette != palette else { return }
        rainbowPalette = palette
        defaults.set(palette.rawValue, forKey: Self.rainbowPaletteStorageKey)
    }

    var usesVideoColorSampling: Bool {
        selection == .liquidGlass && textColorMode.usesVideoSampling
    }
}

private struct PlayerTextSamplingVideoClipRectEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGRect = .zero
}

private struct PlayerThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = PlayerTheme.liquidGlass
}

private struct PlaybackVideoColorStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue: PlaybackVideoColorStore? = nil
}

private struct PlayerTextColorModeEnvironmentKey: EnvironmentKey {
    static let defaultValue = PlayerTextColorMode.dynamicRainbow
}

private struct PlayerRainbowPaletteEnvironmentKey: EnvironmentKey {
    static let defaultValue = PlayerRainbowPalette.softSpectrum
}

private struct PlayerTextSamplingViewportSizeEnvironmentKey: EnvironmentKey {
    static let defaultValue = CGSize.zero
}

private struct PlayerTextSamplingVideoContentRectEnvironmentKey: EnvironmentKey {
    static let defaultValue = CGRect.zero
}

extension EnvironmentValues {
    var playerTheme: PlayerTheme {
        get { self[PlayerThemeEnvironmentKey.self] }
        set { self[PlayerThemeEnvironmentKey.self] = newValue }
    }

    var playbackVideoColorStore: PlaybackVideoColorStore? {
        get { self[PlaybackVideoColorStoreEnvironmentKey.self] }
        set { self[PlaybackVideoColorStoreEnvironmentKey.self] = newValue }
    }

    var playerTextColorMode: PlayerTextColorMode {
        get { self[PlayerTextColorModeEnvironmentKey.self] }
        set { self[PlayerTextColorModeEnvironmentKey.self] = newValue }
    }

    var playerRainbowPalette: PlayerRainbowPalette {
        get { self[PlayerRainbowPaletteEnvironmentKey.self] }
        set { self[PlayerRainbowPaletteEnvironmentKey.self] = newValue }
    }

    var playerTextSamplingViewportSize: CGSize {
        get { self[PlayerTextSamplingViewportSizeEnvironmentKey.self] }
        set { self[PlayerTextSamplingViewportSizeEnvironmentKey.self] = newValue }
    }

    var playerTextSamplingVideoClipRect: CGRect {
        get { self[PlayerTextSamplingVideoClipRectEnvironmentKey.self] }
        set { self[PlayerTextSamplingVideoClipRectEnvironmentKey.self] = newValue }
    }

    var playerTextSamplingVideoContentRect: CGRect {
        get { self[PlayerTextSamplingVideoContentRectEnvironmentKey.self] }
        set { self[PlayerTextSamplingVideoContentRectEnvironmentKey.self] = newValue }
    }
}

private struct PlayerProminentButtonTextStyle: ViewModifier {
    @Environment(\.playerTheme) private var theme
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        // Native prominent buttons use a pale inactive fill. Their labels must
        // not inherit the video palette intended for transparent surfaces.
        let accent = NSColor(theme.accentColor).usingColorSpace(.sRGB)
        let background = controlActiveState == .inactive
            ? SampledVideoColor(red: 1, green: 1, blue: 1)
            : SampledVideoColor(red: Double(accent?.redComponent ?? 1),
                                green: Double(accent?.greenComponent ?? 1),
                                blue: Double(accent?.blueComponent ?? 1))
        let foreground = AdaptiveRainbowTextColor.resolveMonochrome(against: background)
        content.foregroundStyle(Color(red: foreground.red, green: foreground.green, blue: foreground.blue))
    }
}

extension View {
    func playerProminentButtonTextStyle() -> some View {
        modifier(PlayerProminentButtonTextStyle())
    }

    func dynamicPlayerTextStyle(
        store: PlaybackVideoColorStore? = nil,
        role: PlayerDynamicTextRole? = nil,
        contrastRegion: PlayerTextContrastRegion = .local,
        publishesLeadingRegion: Bool = false,
        appliesControlTint: Bool = false,
        opacity: Double = 1
    ) -> some View {
        modifier(
            DynamicPlayerTextStyleModifier(
                store: store,
                role: role,
                contrastRegion: contrastRegion,
                publishesLeadingRegion: publishesLeadingRegion,
                appliesControlTint: appliesControlTint,
                opacity: opacity
            )
        )
    }
}
