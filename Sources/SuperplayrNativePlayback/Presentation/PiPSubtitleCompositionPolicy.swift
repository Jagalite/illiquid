import CoreVideo
import Foundation

enum PiPSubtitleCompositionMode: Equatable, Sendable {
    case bgra
    case nv12VideoRange
    case nv12FullRange
    case p010VideoRange
    case p010FullRange
    case hdrP010VideoRange
    case hdrP010FullRange

    var usesTenBitOutput: Bool { self == .p010VideoRange || self == .p010FullRange || isHDR }
    var isHDR: Bool { self == .hdrP010VideoRange || self == .hdrP010FullRange }
    var isFullRange: Bool { self == .nv12FullRange || self == .p010FullRange || self == .hdrP010FullRange }
}

enum PiPSubtitleCompositionFallbackReason: Equatable, Sendable {
    case hdrTransferCharacteristic(Int32)
    case hdrMetadata
    case hdrColorMetadata
    case unsupportedPixelFormat(OSType)

    var diagnosticDescription: String {
        switch self {
        case let .hdrTransferCharacteristic(value):
            "HDR transfer characteristic \(value) is not qualified."
        case .hdrMetadata:
            "HDR mastering or content-light metadata requires a known PQ/HLG transfer."
        case .hdrColorMetadata:
            "HDR composition requires declared BT.709/BT.2020 primaries and a supported nonconstant-luminance matrix."
        case let .unsupportedPixelFormat(format):
            "Pixel-buffer format \(format) is not qualified."
        }
    }
}

enum PiPSubtitleCompositionEligibility: Equatable, Sendable {
    case supported(PiPSubtitleCompositionMode)
    case videoOnly(PiPSubtitleCompositionFallbackReason)
}

/// The production boundary for subtitle-composited PiP. HDR requires a P010
/// source with a known PQ/HLG transfer; other layouts retain video-only PiP.
enum PiPSubtitleCompositionPolicy {
    static func eligibility(
        pixelFormat: OSType,
        transferCharacteristic: Int32?,
        hasMasteringDisplayMetadata: Bool,
        hasContentLightMetadata: Bool,
        sourceComponentDepth: Int,
        ffmpegPixelFormat: String
    ) -> PiPSubtitleCompositionEligibility {
        if let transferCharacteristic,
           transferCharacteristic == 16 || transferCharacteristic == 18
        {
            if pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange { return .supported(.hdrP010VideoRange) }
            if pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange { return .supported(.hdrP010FullRange) }
            return .videoOnly(
                .hdrTransferCharacteristic(transferCharacteristic)
            )
        }
        if hasMasteringDisplayMetadata || hasContentLightMetadata {
            return .videoOnly(.hdrMetadata)
        }

        // Composition consumes the decoded buffer. A higher-precision source
        // already converted to SDR BGRA/NV12 does not change that layout.
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            return .supported(.bgra)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return .supported(.nv12VideoRange)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return .supported(.nv12FullRange)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            return .supported(.p010VideoRange)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return .supported(.p010FullRange)
        default:
            return .videoOnly(.unsupportedPixelFormat(pixelFormat))
        }
    }

    static func eligibility(
        for frame: NativeDecodedVideoFrame
    ) -> PiPSubtitleCompositionEligibility {
        let result = eligibility(
            pixelFormat: CVPixelBufferGetPixelFormatType(frame.pixelBuffer),
            transferCharacteristic: frame.transferCharacteristic,
            hasMasteringDisplayMetadata: frame.hasMasteringDisplayMetadata,
            hasContentLightMetadata: frame.hasContentLightMetadata,
            sourceComponentDepth: frame.sourceComponentDepth,
            ffmpegPixelFormat: frame.ffmpegPixelFormat
        )
        if case let .supported(mode) = result, mode.isHDR,
           !([Int32(1), 9].contains(frame.colorPrimaries ?? -1)
             && [Int32(1), 9].contains(frame.matrixCoefficients ?? -1)) {
            return .videoOnly(.hdrColorMetadata)
        }
        return result
    }
}
