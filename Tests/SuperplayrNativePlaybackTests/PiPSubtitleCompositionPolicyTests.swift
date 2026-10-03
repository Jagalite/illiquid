import CoreVideo
import Testing
@testable import SuperplayrNativePlayback

@Suite("PiP subtitle composition capability policy")
struct PiPSubtitleCompositionPolicyTests {
    @Test func acceptsSDRBGRAAndBiPlanarEightAndTenBitFormats() {
        #expect(eligibility(kCVPixelFormatType_32BGRA) == .supported(.bgra))
        #expect(
            eligibility(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                == .supported(.nv12VideoRange)
        )
        #expect(
            eligibility(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                == .supported(.nv12FullRange)
        )
        #expect(eligibility(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) == .supported(.p010VideoRange))
        #expect(eligibility(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) == .supported(.p010FullRange))
    }

    @Test func admitsP010HDRAndRejectsUninterpretableHDRBuffers() {
        for transfer: Int32 in [16, 18] {
            #expect(eligibility(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, transfer: transfer)
                == .supported(.hdrP010VideoRange))
            #expect(eligibility(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, transfer: transfer)
                == .supported(.hdrP010FullRange))
        }
        #expect(
            eligibility(kCVPixelFormatType_32BGRA, transfer: 16)
                == .videoOnly(.hdrTransferCharacteristic(16))
        )
        #expect(
            eligibility(kCVPixelFormatType_32BGRA, transfer: 18)
                == .videoOnly(.hdrTransferCharacteristic(18))
        )
        #expect(
            eligibility(kCVPixelFormatType_32BGRA, mastering: true)
                == .videoOnly(.hdrMetadata)
        )
        #expect(
            eligibility(kCVPixelFormatType_32BGRA, contentLight: true)
                == .videoOnly(.hdrMetadata)
        )
    }

    @Test func sourceDepthDoesNotRejectAnAlreadyConvertedSDRBuffer() {
        #expect(
            eligibility(kCVPixelFormatType_32BGRA, ffmpegFormat: "p010le")
                == .supported(.bgra)
        )
        #expect(
            eligibility(
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                ffmpegFormat: "av1-main10"
            ) == .supported(.nv12VideoRange)
        )
        #expect(
            eligibility(
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                ffmpegFormat: "yuv420p10bit"
            ) == .supported(.nv12FullRange)
        )
        #expect(
            eligibility(
                kCVPixelFormatType_32BGRA,
                sourceComponentDepth: 10,
                ffmpegFormat: "yuv420p10le"
            ) == .supported(.bgra)
        )
        #expect(
            eligibility(
                kCVPixelFormatType_32BGRA,
                sourceComponentDepth: 12,
                ffmpegFormat: "yuv444p12le"
            ) == .supported(.bgra)
        )
    }

    @Test func rejectsUnqualifiedPixelBufferLayouts() {
        let unsupported = kCVPixelFormatType_OneComponent8
        #expect(
            eligibility(unsupported)
                == .videoOnly(.unsupportedPixelFormat(unsupported))
        )
    }

    private func eligibility(
        _ pixelFormat: OSType,
        transfer: Int32? = nil,
        mastering: Bool = false,
        contentLight: Bool = false,
        sourceComponentDepth: Int = 8,
        ffmpegFormat: String = "yuv420p"
    ) -> PiPSubtitleCompositionEligibility {
        PiPSubtitleCompositionPolicy.eligibility(
            pixelFormat: pixelFormat,
            transferCharacteristic: transfer,
            hasMasteringDisplayMetadata: mastering,
            hasContentLightMetadata: contentLight,
            sourceComponentDepth: sourceComponentDepth,
            ffmpegPixelFormat: ffmpegFormat
        )
    }
}
