import CoreGraphics
import Foundation
import IlliquidCore

/// A crop, scale, rotation and flip applied on the GPU before presentation.
///
/// The output always has square pixels and no clean aperture: the source's
/// crop and pixel aspect are folded into the resampled picture.
public struct VideoFrameTransform: Equatable, Sendable {
    public enum Rotation: Int, Equatable, Sendable, CaseIterable {
        case none = 0
        case clockwise90 = 90
        case clockwise180 = 180
        case clockwise270 = 270

        var swapsAxes: Bool { self == .clockwise90 || self == .clockwise270 }
    }

    public enum OutputSize: Equatable, Sendable {
        /// The source's visible size with square pixels.
        case source
        /// The source's visible size multiplied by a factor.
        case scale(Double)
        /// The largest size with the source's aspect ratio that fits the box.
        case fit(width: Int, height: Int)
        /// Exactly this size; the picture is stretched to fill it.
        case exact(width: Int, height: Int)
    }

    /// Normalized crop inside the source's visible region, origin top-left.
    public var crop: CGRect?
    public var outputSize: OutputSize
    public var rotation: Rotation
    public var flipsHorizontally: Bool
    public var flipsVertically: Bool

    public init(
        crop: CGRect? = nil,
        outputSize: OutputSize = .source,
        rotation: Rotation = .none,
        flipsHorizontally: Bool = false,
        flipsVertically: Bool = false
    ) {
        self.crop = crop
        self.outputSize = outputSize
        self.rotation = rotation
        self.flipsHorizontally = flipsHorizontally
        self.flipsVertically = flipsVertically
    }
}

/// Generates frames between decoded frames so playback runs at a steady
/// higher rate.
public struct VideoFrameRateConversion: Equatable, Sendable {
    public enum Quality: Equatable, Sendable {
        case normal
        case high
    }

    /// Rates the pipeline accepts. Configurations outside it are rejected
    /// when the pipeline is built.
    public static let supportedTargetFrameRates: ClosedRange<Double> = 1...480

    /// Output cadence. Frames already at or above this rate pass through.
    public var targetFrameRate: Double
    public var quality: Quality

    public init(targetFrameRate: Double, quality: Quality = .normal) {
        self.targetFrameRate = targetFrameRate
        self.quality = quality
    }
}

/// Which processing stages run between the decoder and the renderer.
/// The disabled configuration leaves the existing frame path untouched.
public struct VideoFrameProcessingConfiguration: Equatable, Sendable {
    public var transform: VideoFrameTransform?
    public var frameRateConversion: VideoFrameRateConversion?
    /// Equalizer values; nil or neutral skips the stage.
    public var pictureAdjustments: VideoPictureAdjustments?
    /// Filter presets; order does not matter, the pipeline fixes it.
    public var filters: Set<VideoFilterPreset>

    public init(
        transform: VideoFrameTransform? = nil,
        frameRateConversion: VideoFrameRateConversion? = nil,
        pictureAdjustments: VideoPictureAdjustments? = nil,
        filters: Set<VideoFilterPreset> = []
    ) {
        self.transform = transform
        self.frameRateConversion = frameRateConversion
        self.pictureAdjustments = pictureAdjustments
        self.filters = filters
    }

    public static let disabled = VideoFrameProcessingConfiguration()

    public var isEnabled: Bool {
        transform != nil || frameRateConversion != nil
            || pictureAdjustments.map { !$0.isNeutral } == true || !filters.isEmpty
    }

    public static let transformEnvironmentKey = "ILLIQUID_VIDEO_TRANSFORM"
    public static let frameRateEnvironmentKey = "ILLIQUID_VIDEO_INTERPOLATE"

    /// Reads the development switches.
    ///
    /// `ILLIQUID_VIDEO_TRANSFORM` takes comma-separated terms:
    /// `scale=0.5`, `fit=1920x1080`, `size=1280x720`, `rotate=90`,
    /// `flip=h`, `flip=v`, `flip=hv`, `crop=x:y:w:h` (normalized).
    /// `ILLIQUID_VIDEO_INTERPOLATE` takes a target rate such as `60`, or
    /// `60:high` for the higher-quality model.
    /// Invalid values disable that stage rather than failing playback.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> VideoFrameProcessingConfiguration {
        VideoFrameProcessingConfiguration(
            transform: environment[transformEnvironmentKey].flatMap(parseTransform),
            frameRateConversion: environment[frameRateEnvironmentKey].flatMap(parseFrameRate)
        )
    }

    static func parseTransform(_ text: String) -> VideoFrameTransform? {
        var transform = VideoFrameTransform()
        var sawTerm = false
        for rawTerm in text.split(separator: ",") {
            let term = rawTerm.trimmingCharacters(in: .whitespaces).lowercased()
            guard !term.isEmpty else { continue }
            let parts = term.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let (key, value) = (parts[0], parts[1])
            switch key {
            case "scale":
                guard let factor = Double(value), factor.isFinite, factor > 0, factor <= 8 else {
                    return nil
                }
                transform.outputSize = .scale(factor)
            case "fit", "size":
                guard let size = parseSize(value) else { return nil }
                transform.outputSize = key == "fit"
                    ? .fit(width: size.width, height: size.height)
                    : .exact(width: size.width, height: size.height)
            case "rotate":
                guard let degrees = Int(value),
                      let rotation = VideoFrameTransform.Rotation(rawValue: ((degrees % 360) + 360) % 360)
                else { return nil }
                transform.rotation = rotation
            case "flip":
                guard !value.isEmpty, value.allSatisfy({ $0 == "h" || $0 == "v" }) else { return nil }
                transform.flipsHorizontally = value.contains("h")
                transform.flipsVertically = value.contains("v")
            case "crop":
                let numbers = value.split(separator: ":").compactMap { Double($0) }
                guard numbers.count == 4 else { return nil }
                let rect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
                guard rect.minX >= 0, rect.minY >= 0, rect.width > 0, rect.height > 0,
                      rect.maxX <= 1, rect.maxY <= 1
                else { return nil }
                transform.crop = rect
            default:
                return nil
            }
            sawTerm = true
        }
        return sawTerm ? transform : nil
    }

    static func parseFrameRate(_ text: String) -> VideoFrameRateConversion? {
        let parts = text.trimmingCharacters(in: .whitespaces).lowercased()
            .split(separator: ":").map(String.init)
        guard (1...2).contains(parts.count),
              let rate = Double(parts[0]),
              VideoFrameRateConversion.supportedTargetFrameRates.contains(rate)
        else { return nil }
        var quality = VideoFrameRateConversion.Quality.normal
        if parts.count == 2 {
            switch parts[1] {
            case "normal": quality = .normal
            case "high": quality = .high
            default: return nil
            }
        }
        return VideoFrameRateConversion(targetFrameRate: rate, quality: quality)
    }

    private static func parseSize(_ text: String) -> (width: Int, height: Int)? {
        let parts = text.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, (2...16_384).contains(parts[0]), (2...16_384).contains(parts[1]) else {
            return nil
        }
        return (parts[0], parts[1])
    }
}
