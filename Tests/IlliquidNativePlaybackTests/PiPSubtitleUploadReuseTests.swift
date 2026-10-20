import CoreMedia
import CoreVideo
import Foundation
import IlliquidCore
import Testing
@testable import IlliquidNativePlayback

@Suite("PiP subtitle upload reuse", .serialized)
struct PiPSubtitleUploadReuseTests {
    // The direct composition seam does not use the production workerActive gate.
    // Await every GPU completion before changing the pipeline or composing again.
    @Test @MainActor
    func unchangedBitmapUploadsOnceAndPreservesExactOutput() async throws {
        let size = CGSize(width: 16, height: 16)
        let pipeline = try bitmapPipeline(size: size)
        defer { pipeline.terminate() }
        insertBitmap(into: pipeline, color: [0, 0, 128, 128], duration: 4)
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        let source = try blackPixelBuffer(size: size)

        let first = try await compose(compositor, source: source, seconds: 0.5)
        #expect(first.pixel(x: 5, y: 5) == [0, 0, 128, 255])
        #expect(first.pixel(x: 0, y: 0) == [0, 0, 0, 255])
        let initial = compositor.metricsSnapshot()
        #expect(initial.subtitleTextureUploads == 1)
        #expect(initial.subtitleVertexBuilds == 1)
        #expect(initial.subtitleTextureUploadBytes > 0)
        #expect(initial.subtitleVertexUploadBytes > 0)

        for seconds in [0.5, 0.6, 0.7, 1.0, 1.5, 2.0, 3.5] {
            let repeated = try await compose(compositor, source: source, seconds: seconds)
            #expect(repeated == first)
        }
        let final = compositor.metricsSnapshot()
        #expect(final.subtitleTextureUploads == 1)
        #expect(final.subtitleVertexBuilds == 1)
        #expect(final.subtitleTextureUploadBytes == initial.subtitleTextureUploadBytes)
        #expect(final.subtitleVertexUploadBytes == initial.subtitleVertexUploadBytes)
        #expect(final.subtitleResourceReuses == 7)
    }

    @Test @MainActor
    func sameTimestampReplacementRefreshesPixelsAndMovedQuad() async throws {
        let size = CGSize(width: 16, height: 16)
        let pipeline = try bitmapPipeline(size: size)
        defer { pipeline.terminate() }
        insertBitmap(into: pipeline, color: [0, 0, 255, 255])
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        let source = try blackPixelBuffer(size: size)
        let red = try await compose(compositor, source: source, seconds: 0.5)

        // Replace the same timeline entry, preserving timestamp and atlas size.
        insertBitmap(into: pipeline, color: [0, 255, 0, 255])
        let green = try await compose(compositor, source: source, seconds: 0.5)
        #expect(green != red)
        #expect(green.pixel(x: 5, y: 5) == [0, 255, 0, 255])
        #expect(compositor.metricsSnapshot().subtitleTextureUploads == 2)
        #expect(compositor.metricsSnapshot().subtitleVertexBuilds == 2)

        // Equal bitmap bytes and dimensions must not hide a changed position.
        insertBitmap(into: pipeline, color: [0, 255, 0, 255],
                     frame: CGRect(x: 9, y: 4, width: 4, height: 4))
        let moved = try await compose(compositor, source: source, seconds: 0.5)
        #expect(moved != green)
        #expect(moved.pixel(x: 5, y: 5) == [0, 0, 0, 255])
        #expect(moved.pixel(x: 10, y: 5) == [0, 255, 0, 255])
        let repeated = try await compose(compositor, source: source, seconds: 0.6)
        #expect(repeated == moved)
        let metrics = compositor.metricsSnapshot()
        #expect(metrics.subtitleTextureUploads == 3)
        #expect(metrics.subtitleVertexBuilds == 3)
        #expect(metrics.subtitleResourceReuses == 1)
    }

    @Test @MainActor
    func expiryAndGenerationClearRemovePixelsWithoutUploadingEmptyResources() async throws {
        let size = CGSize(width: 16, height: 16)
        let pipeline = try bitmapPipeline(size: size)
        defer { pipeline.terminate() }
        insertBitmap(into: pipeline, color: [0, 0, 255, 255], duration: 1)
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        let source = try blackPixelBuffer(size: size)
        let shown = try await compose(compositor, source: source, seconds: 0.5)
        #expect(shown.nonblackPixelCount > 0)

        let expired = try await compose(compositor, source: source, seconds: 1.0)
        let stillExpired = try await compose(compositor, source: source, seconds: 1.5)
        #expect(expired.nonblackPixelCount == 0)
        #expect(stillExpired == expired)
        #expect(compositor.metricsSnapshot().subtitleTextureUploads == 1)
        #expect(compositor.metricsSnapshot().subtitleVertexBuilds == 1)

        insertBitmap(into: pipeline, color: [255, 0, 0, 255], start: 2, duration: 1)
        let next = try await compose(compositor, source: source, seconds: 2.5)
        #expect(next.pixel(x: 5, y: 5) == [255, 0, 0, 255])
        pipeline.clear(generation: 1)
        let cleared = try await compose(compositor, source: source, seconds: 2.5)
        #expect(cleared == expired)

        // An old-generation packet cannot resurrect the retired upload.
        insertBitmap(into: pipeline, color: [0, 0, 255, 255], start: 2, generation: 0)
        let stale = try await compose(compositor, source: source, seconds: 2.5)
        #expect(stale == expired)
        insertBitmap(into: pipeline, color: [0, 255, 0, 255], start: 2, generation: 1)
        let restored = try await compose(compositor, source: source, seconds: 2.5)
        #expect(restored.pixel(x: 5, y: 5) == [0, 255, 0, 255])
        let metrics = compositor.metricsSnapshot()
        #expect(metrics.subtitleTextureUploads == 3)
        #expect(metrics.subtitleVertexBuilds == 3)
    }

    @Test @MainActor
    func disabledTextClearsAndReenablesAtTheSameTimestamp() async throws {
        let pipeline = try textPipeline()
        defer { pipeline.terminate() }
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        let source = try blackPixelBuffer(size: CGSize(width: 320, height: 180))
        let shown = try await compose(compositor, source: source, seconds: 0.5)
        #expect(shown.nonblackPixelCount > 100)
        let uploaded = compositor.metricsSnapshot()

        pipeline.isEnabled = false
        let disabled = try await compose(compositor, source: source, seconds: 0.5)
        let stillDisabled = try await compose(compositor, source: source, seconds: 0.5)
        #expect(disabled.nonblackPixelCount == 0)
        #expect(stillDisabled == disabled)
        #expect(compositor.metricsSnapshot().subtitleTextureUploads == uploaded.subtitleTextureUploads)
        #expect(compositor.metricsSnapshot().subtitleVertexBuilds == uploaded.subtitleVertexBuilds)

        // External ASS events survive clear; no new packet is needed to reenable.
        pipeline.isEnabled = true
        let restored = try await compose(compositor, source: source, seconds: 0.5)
        let repeated = try await compose(compositor, source: source, seconds: 0.6)
        #expect(restored == shown)
        #expect(repeated == shown)
        let metrics = compositor.metricsSnapshot()
        #expect(metrics.subtitleTextureUploads == 2)
        #expect(metrics.subtitleVertexBuilds == 2)
        #expect(metrics.subtitleResourceReuses == 1)
    }

    @Test @MainActor
    func backwardSeekRestoresEarlierCueAfterInvalidation() async throws {
        let pipeline = try textPipeline()
        defer { pipeline.terminate() }
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        let source = try blackPixelBuffer(size: CGSize(width: 320, height: 180))
        let first = try await compose(compositor, source: source, seconds: 0.5)
        let later = try await compose(compositor, source: source, seconds: 3.0)
        #expect(first.nonblackPixelCount > 100)
        #expect(later.nonblackPixelCount > 100)
        #expect(later != first)

        pipeline.clear(generation: 1)
        let sought = try await compose(compositor, source: source, seconds: 0.5)
        let repeated = try await compose(compositor, source: source, seconds: 0.6)
        #expect(sought == first)
        #expect(repeated == first)
        let metrics = compositor.metricsSnapshot()
        #expect(metrics.subtitleTextureUploads == 3)
        #expect(metrics.subtitleVertexBuilds == 3)
        #expect(metrics.subtitleResourceReuses == 1)
    }

    @Test @MainActor
    func rebindingAnAlreadyRenderedPipelineNeverReusesThePreviousAtlas() async throws {
        let size = CGSize(width: 16, height: 16)
        let firstPipeline = try bitmapPipeline(size: size)
        let secondPipeline = try bitmapPipeline(size: size)
        defer {
            firstPipeline.terminate()
            secondPipeline.terminate()
        }
        insertBitmap(into: firstPipeline, color: [0, 0, 255, 255])
        insertBitmap(into: secondPipeline, color: [255, 0, 0, 255])
        let compositor = try PiPSubtitleCompositor(subtitles: firstPipeline)
        let source = try blackPixelBuffer(size: size)
        let first = try await compose(compositor, source: source, seconds: 0.5)

        // The new pipeline will report changed == false at the next same-time
        // snapshot. The compositor's binding revision must still invalidate.
        let warm = secondPipeline.pictureInPictureSubtitleSnapshot(
            at: CMTime(seconds: 0.5, preferredTimescale: 1_000),
            viewport: CGRect(origin: .zero, size: size), videoSize: size)
        #expect(!warm.regions.isEmpty)
        compositor.setSubtitlePipeline(secondPipeline)
        let second = try await compose(compositor, source: source, seconds: 0.5)
        let repeated = try await compose(compositor, source: source, seconds: 0.6)
        #expect(second != first)
        #expect(second.pixel(x: 5, y: 5) == [255, 0, 0, 255])
        #expect(repeated == second)

        compositor.setSubtitlePipeline(nil)
        let unbound = try await compose(compositor, source: source, seconds: 0.6)
        #expect(unbound.nonblackPixelCount == 0)
        compositor.setSubtitlePipeline(firstPipeline)
        let restored = try await compose(compositor, source: source, seconds: 0.5)
        #expect(restored == first)
        let metrics = compositor.metricsSnapshot()
        #expect(metrics.subtitleTextureUploads == 3)
        #expect(metrics.subtitleVertexBuilds == 3)
        #expect(metrics.subtitleResourceReuses == 1)
    }

    @Test @MainActor
    func displayResizeAndCropRebuildSubtitleGeometry() async throws {
        let size = CGSize(width: 16, height: 16)
        let displaySize = CGSize(width: 32, height: 16)
        let pipeline = try bitmapPipeline(size: size)
        defer { pipeline.terminate() }
        insertBitmap(into: pipeline, color: [0, 0, 255, 255],
                     frame: CGRect(x: 10, y: 4, width: 2, height: 4))
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        let source = try blackPixelBuffer(size: size)
        let original = try await compose(compositor, source: source, seconds: 0.5)
        #expect(original.pixel(x: 11, y: 5) == [0, 0, 255, 255])

        let resized = try await compose(compositor, source: source, seconds: 0.5,
                                        displaySize: displaySize)
        #expect(resized.width == 32 && resized.height == 16)
        #expect(resized.pixel(x: 22, y: 5) == [0, 0, 255, 255])
        #expect(resized.pixel(x: 11, y: 5) == [0, 0, 0, 255])

        compositor.setVideoAdjustments(VideoAdjustmentState(crop: "1:1"))
        let cropped = try await compose(compositor, source: source, seconds: 0.5,
                                        displaySize: displaySize)
        let repeated = try await compose(compositor, source: source, seconds: 0.6,
                                         displaySize: displaySize)
        #expect(cropped.width == 16 && cropped.height == 16)
        #expect(cropped.pixel(x: 14, y: 5) == [0, 0, 255, 255])
        #expect(cropped.pixel(x: 6, y: 5) == [0, 0, 0, 255])
        #expect(repeated == cropped)
        let metrics = compositor.metricsSnapshot()
        #expect(metrics.subtitleTextureUploads == 3)
        #expect(metrics.subtitleVertexBuilds == 3)
        #expect(metrics.subtitleResourceReuses == 1)
    }

    @Test @MainActor
    func staticASSReusesUploadsWhileAnimatedMovementRefreshesThem() async throws {
        let pipeline = try textPipeline()
        defer { pipeline.terminate() }
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        let source = try blackPixelBuffer(size: CGSize(width: 320, height: 180))
        let first = try await compose(compositor, source: source, seconds: 0.5)
        #expect(first.nonblackPixelCount > 100)
        let initial = compositor.metricsSnapshot()
        for seconds in [0.6, 0.7, 0.8] {
            let repeated = try await compose(compositor, source: source, seconds: seconds)
            #expect(repeated == first)
        }
        let staticMetrics = compositor.metricsSnapshot()
        #expect(staticMetrics.subtitleTextureUploads == 1)
        #expect(staticMetrics.subtitleVertexBuilds == 1)
        #expect(staticMetrics.subtitleTextureUploadBytes == initial.subtitleTextureUploadBytes)
        #expect(staticMetrics.subtitleVertexUploadBytes == initial.subtitleVertexUploadBytes)

        var previous = first
        for seconds in [5.25, 6.0, 7.0] {
            let moving = try await compose(compositor, source: source, seconds: seconds)
            #expect(moving.nonblackPixelCount > 100)
            #expect(moving != previous)
            previous = moving
        }
        let held = try await compose(compositor, source: source, seconds: 7.0)
        #expect(held == previous)
        let metrics = compositor.metricsSnapshot()
        #expect(metrics.subtitleTextureUploads == 4)
        #expect(metrics.subtitleVertexBuilds == 4)
        #expect(metrics.subtitleResourceReuses == 4)
        #expect(pipeline.counters().metalFailures == 0)
    }

    @MainActor
    private func bitmapPipeline(size: CGSize) throws -> SubtitlePipeline {
        let pipeline = try SubtitlePipeline(
            overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        _ = try pipeline.configure(codecPrivate: nil, codecName: "hdmv_pgs_subtitle",
                                   attachments: [], frameSize: size, storageSize: size)
        return pipeline
    }

    private func insertBitmap(
        into pipeline: SubtitlePipeline,
        color: [UInt8],
        frame: CGRect = CGRect(x: 4, y: 4, width: 4, height: 4),
        start: Double = 0,
        duration: Double = 4,
        generation: Int = 0
    ) {
        let pixels = Data((0..<(Int(frame.width * frame.height))).flatMap { _ in color })
        let composition = NativeBitmapSubtitleComposition(
            regions: [.init(pixels: pixels, frame: frame, isForced: false)],
            canvasSize: CGSize(width: 16, height: 16), duration: duration, memoryLease: nil)
        #expect(pipeline.process(event: .init(
            assData: Data(), presentationSeconds: start, durationSeconds: duration,
            generation: generation, bitmapComposition: composition)))
    }

    @MainActor
    private func textPipeline() throws -> SubtitlePipeline {
        let pipeline = try SubtitlePipeline(
            overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        try pipeline.installExternal(data: Data(Self.assScript.utf8))
        return pipeline
    }

    private static let assScript = #"""
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 320
        PlayResY: 180
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,26,&H00FFFFFF,&H000000FF,&H00101010,&H80000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,16,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,STATIC CUE
        Dialogue: 0,0:00:02.50,0:00:04.50,Default,,0,0,0,,A DIFFERENT CUE
        Dialogue: 0,0:00:05.00,0:00:09.00,Default,,0,0,0,,{\an5\move(60,70,250,70,0,4000)}MOVING
        """#

    private struct PixelImage: Equatable {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        func pixel(x: Int, y: Int) -> [UInt8] {
            let offset = (y * width + x) * 4
            return Array(pixels[offset..<(offset + 4)])
        }

        var nonblackPixelCount: Int {
            stride(from: 0, to: pixels.count, by: 4).reduce(into: 0) { count, offset in
                if pixels[offset] > 8 || pixels[offset + 1] > 8 || pixels[offset + 2] > 8 {
                    count += 1
                }
            }
        }
    }

    @MainActor
    private func compose(
        _ compositor: PiPSubtitleCompositor,
        source: CVPixelBuffer,
        seconds: Double,
        displaySize: CGSize? = nil
    ) async throws -> PixelImage {
        let size = CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        let frame = NativeDecodedVideoFrame(
            pixelBuffer: source, planarOwnershipToken: nil,
            presentationTime: CMTime(seconds: seconds, preferredTimescale: 1_000),
            duration: CMTime(value: 1, timescale: 30), generation: 0,
            codedSize: size, displaySize: displaySize ?? size,
            pixelAspectRatio: CGSize(width: 1, height: 1), rotationDegrees: 0,
            colorPrimaries: nil, transferCharacteristic: nil, matrixCoefficients: nil,
            isFullRange: true, hasMasteringDisplayMetadata: false,
            hasContentLightMetadata: false, sourceComponentDepth: 8,
            ffmpegPixelFormat: "bgra", isHardwareDecoded: false,
            isCopiedHardwarePath: false, isNearZeroCopy: false)
        let output = try await compositor.composedPixelBufferForTesting(frame)
        #expect(CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferLockBaseAddress(output, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(output)
        let height = CVPixelBufferGetHeight(output)
        let stride = CVPixelBufferGetBytesPerRow(output)
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            pixels.append(contentsOf: UnsafeBufferPointer(start: base + y * stride, count: width * 4))
        }
        return PixelImage(width: width, height: height, pixels: pixels)
    }

    private func blackPixelBuffer(size: CGSize) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &pixelBuffer)
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        #expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, 0, bytesPerRow * Int(size.height))
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<Int(size.height) {
            for x in 0..<Int(size.width) {
                bytes[y * bytesPerRow + x * 4 + 3] = 255
            }
        }
        return buffer
    }
}
