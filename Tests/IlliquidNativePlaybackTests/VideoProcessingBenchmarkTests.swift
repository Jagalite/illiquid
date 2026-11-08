import CoreMedia
import CoreVideo
import Foundation
import IlliquidCore
import Metal
import Testing
@testable import IlliquidNativePlayback

/// Opt-in GPU cost of each processing stage at playback sizes. Set
/// ILLIQUID_VIDEO_PROCESSING_BENCHMARK=1. Times are wall-clock per frame for
/// encode + GPU completion on this Mac, measured after warm-up; they are not
/// display-pipeline or power measurements.
@Suite("Video processing stage cost", .serialized)
struct VideoProcessingBenchmarkTests {
    private typealias Support = VideoProcessingTestSupport
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["ILLIQUID_VIDEO_PROCESSING_BENCHMARK"] == "1"
            && MTLCreateSystemDefaultDevice() != nil
    }

    private static let cases: [(String, VideoFrameProcessingConfiguration)] = [
        ("passthrough", .disabled),
        ("adjust", VideoFrameProcessingConfiguration(pictureAdjustments: VideoPictureAdjustments(contrast: 20, hue: 10))),
        ("sharpen", VideoFrameProcessingConfiguration(filters: [.sharpen])),
        ("deband", VideoFrameProcessingConfiguration(filters: [.deband])),
        ("denoise", VideoFrameProcessingConfiguration(filters: [.denoise])),
        ("transform-half", VideoFrameProcessingConfiguration(transform: VideoFrameTransform(outputSize: .scale(0.5)))),
        ("all-filters+adjust", VideoFrameProcessingConfiguration(
            pictureAdjustments: VideoPictureAdjustments(contrast: 20), filters: [.denoise, .deband, .sharpen]
        )),
    ]

    @Test(.enabled(if: enabled), arguments: [
        (1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (3840, 2160, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
    ])
    func stageCost(width: Int, height: Int, pixelFormat: OSType) throws {
        let sources = try (0..<4).map { _ in try Support.makeBuffer(width: width, height: height, pixelFormat: pixelFormat) }
        for (name, configuration) in Self.cases {
            let pipeline = try VideoFrameProcessingPipeline(configuration: configuration)
            var times: [Double] = []
            for index in 0..<70 {
                let frame = Support.frame(sources[index % 4], seconds: Double(index) / 24, duration: 1.0 / 24)
                let started = DispatchTime.now().uptimeNanoseconds
                _ = pipeline.process(frame)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                if index >= 10 { times.append(elapsed) }
            }
            #expect(pipeline.snapshot.bypassReason == nil, "\(name): \(pipeline.snapshot.bypassReason ?? "")")
            times.sort()
            let median = times[times.count / 2]
            let p95 = times[Int(Double(times.count - 1) * 0.95)]
            print("STAGE_COST size=\(width)x\(height) format=\(VideoProcessingPlaneLayout.fourCC(pixelFormat)) "
                + "case=\(name) median-ms=\(String(format: "%.2f", median)) p95-ms=\(String(format: "%.2f", p95)) "
                + "budget24-ms=41.7 budget60-ms=16.7")
        }
    }
}
