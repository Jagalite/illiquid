import Foundation

public struct Chapter: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let title: String?
    public let startTime: TimeInterval

    public init(id: Int64, title: String?, startTime: TimeInterval) {
        self.id = id
        self.title = title
        self.startTime = max(0, startTime.isFinite ? startTime : 0)
    }
}

public struct AudioOutputDevice: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool
    public let isSelected: Bool

    public init(id: String, name: String, isDefault: Bool, isSelected: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.isSelected = isSelected
    }
}

public enum HardwareDecodingPolicy: String, Codable, CaseIterable, Sendable {
    case automatic
    case compatibility
    case off
}

public struct HardwareDecodingStatus: Codable, Equatable, Sendable {
    public var policy: HardwareDecodingPolicy
    public var activeDecoder: String?
    public var activeIsHardwareDecoded: Bool
    public var fallbackToSoftwareObserved: Bool

    public var isHardwareDecoded: Bool {
        activeIsHardwareDecoded
    }

    public var didFallbackToSoftware: Bool {
        fallbackToSoftwareObserved
    }

    public init(
        policy: HardwareDecodingPolicy,
        activeDecoder: String? = nil,
        activeIsHardwareDecoded: Bool = false,
        fallbackToSoftwareObserved: Bool = false
    ) {
        self.policy = policy
        self.activeDecoder = activeDecoder
        self.activeIsHardwareDecoded = activeIsHardwareDecoded
        self.fallbackToSoftwareObserved = fallbackToSoftwareObserved
    }
}

public struct BufferStatus: Codable, Equatable, Sendable {
    public var isBuffering: Bool
    public var cacheDuration: TimeInterval
    public var cachePercent: Double?
    public var bytesPerSecond: Int64?

    public init(
        isBuffering: Bool = false,
        cacheDuration: TimeInterval = 0,
        cachePercent: Double? = nil,
        bytesPerSecond: Int64? = nil
    ) {
        self.isBuffering = isBuffering
        self.cacheDuration = max(0, cacheDuration.isFinite ? cacheDuration : 0)
        self.cachePercent = cachePercent.map { min(max($0, 0), 100) }
        self.bytesPerSecond = bytesPerSecond
    }

    public static let empty = BufferStatus()
}

public struct VideoOutputStatus: Codable, Equatable, Sendable {
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var codec: String?
    public var pixelFormat: String?
    public var colorPrimaries: String?
    public var transferFunction: String?
    public var isHDR: Bool
    public var decoder: String?
    public var isHardwareDecoded: Bool

    public init(
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        codec: String? = nil,
        pixelFormat: String? = nil,
        colorPrimaries: String? = nil,
        transferFunction: String? = nil,
        isHDR: Bool = false,
        decoder: String? = nil,
        isHardwareDecoded: Bool = false
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.codec = codec
        self.pixelFormat = pixelFormat
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.isHDR = isHDR
        self.decoder = decoder
        self.isHardwareDecoded = isHardwareDecoded
    }

    public static let empty = VideoOutputStatus()
}

public struct DisplayOutputStatus: Codable, Equatable, Sendable {
    public var name: String?
    public var maximumFramesPerSecond: Int?
    public var maximumPotentialEDR: Double
    public var isEDREnabled: Bool
    public var colorSpaceName: String?

    public init(
        name: String? = nil,
        maximumFramesPerSecond: Int? = nil,
        maximumPotentialEDR: Double = 1,
        isEDREnabled: Bool = false,
        colorSpaceName: String? = nil
    ) {
        self.name = name
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.maximumPotentialEDR = maximumPotentialEDR
        self.isEDREnabled = isEDREnabled
        self.colorSpaceName = colorSpaceName
    }

    public static let empty = DisplayOutputStatus()
}

public struct VideoAdjustmentState: Codable, Equatable, Sendable {
    public var scaleMode: VideoScaleMode?
    public var aspectRatio: String?
    public var crop: String?
    public var rotation: Int
    public var isDeinterlacing: Bool
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    public var gamma: Double
    public var hue: Double

    public init(
        aspectRatio: String? = nil,
        crop: String? = nil,
        rotation: Int = 0,
        isDeinterlacing: Bool = false,
        brightness: Double = 0,
        contrast: Double = 0,
        saturation: Double = 0,
        gamma: Double = 0,
        hue: Double = 0
    ) {
        self.aspectRatio = aspectRatio
        self.crop = crop
        self.rotation = rotation
        self.isDeinterlacing = isDeinterlacing
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.gamma = gamma
        self.hue = hue
    }

    public static let standard = VideoAdjustmentState()
}

/// Curated, product-level filters that Illiquid can apply safely.
///
/// Backend filter syntax intentionally does not cross into IlliquidCore. A
/// closed set also prevents media or UI text from becoming an executable mpv
/// filter expression.
public enum VideoFilterPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case deband
    case denoise
    case sharpen

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deband: "Deband"
        case .denoise: "Denoise"
        case .sharpen: "Sharpen"
        }
    }

    public var helpText: String {
        switch self {
        case .deband: "Reduce visible color banding in gradients."
        case .denoise: "Reduce moderate spatial and temporal noise."
        case .sharpen: "Apply gentle contrast-adaptive sharpening."
        }
    }
}

public struct PlaybackDiagnosticsSnapshot: Codable, Equatable, Sendable {
    public var capturedAt: Date
    public var source: MediaSource?
    public var sourceOrigin: MediaSourceOrigin?
    public var phase: PlaybackPhase
    public var position: TimeInterval
    public var duration: TimeInterval
    public var buffer: BufferStatus
    public var video: VideoOutputStatus
    public var display: DisplayOutputStatus
    public var audioDevice: AudioOutputDevice?
    public var recentMessages: [String]

    public init(
        capturedAt: Date = Date(),
        source: MediaSource? = nil,
        sourceOrigin: MediaSourceOrigin? = nil,
        phase: PlaybackPhase = .idle,
        position: TimeInterval = 0,
        duration: TimeInterval = 0,
        buffer: BufferStatus = .empty,
        video: VideoOutputStatus = .empty,
        display: DisplayOutputStatus = .empty,
        audioDevice: AudioOutputDevice? = nil,
        recentMessages: [String] = []
    ) {
        self.capturedAt = capturedAt
        self.source = source
        self.sourceOrigin = sourceOrigin
        self.phase = phase
        self.position = position
        self.duration = duration
        self.buffer = buffer
        self.video = video
        self.display = display
        self.audioDevice = audioDevice
        self.recentMessages = Array(recentMessages.suffix(100))
    }
}
