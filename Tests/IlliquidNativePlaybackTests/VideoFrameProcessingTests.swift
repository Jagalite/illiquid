import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Metal
import Testing
@testable import IlliquidNativePlayback

@Suite("Video frame processing configuration")
struct VideoFrameProcessingConfigurationTests {
    @Test func disabledByDefault() {
        let configuration = VideoFrameProcessingConfiguration.fromEnvironment([:])
        #expect(configuration == .disabled)
        #expect(!configuration.isEnabled)
    }

    @Test func parsesTransformTerms() throws {
        let transform = try #require(VideoFrameProcessingConfiguration.parseTransform(
            "scale=0.5, rotate=-90, flip=hv, crop=0.1:0.2:0.5:0.6"
        ))
        #expect(transform.outputSize == .scale(0.5))
        #expect(transform.rotation == .clockwise270)
        #expect(transform.flipsHorizontally)
        #expect(transform.flipsVertically)
        #expect(transform.crop == CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6))
        #expect(VideoFrameProcessingConfiguration.parseTransform("fit=1280x720")?.outputSize
            == .fit(width: 1280, height: 720))
        #expect(VideoFrameProcessingConfiguration.parseTransform("size=640x360")?.outputSize
            == .exact(width: 640, height: 360))
    }

    @Test func rejectsInvalidTransformTerms() {
        for text in ["", "scale=0", "scale=abc", "rotate=45", "flip=x", "crop=0.5:0.5:0.6:0.1",
                     "fit=1x10", "unknown=1", "scale"] {
            #expect(VideoFrameProcessingConfiguration.parseTransform(text) == nil, "\(text)")
        }
    }

    @Test func parsesFrameRate() {
        #expect(VideoFrameProcessingConfiguration.parseFrameRate("60")
            == VideoFrameRateConversion(targetFrameRate: 60))
        #expect(VideoFrameProcessingConfiguration.parseFrameRate("120:high")
            == VideoFrameRateConversion(targetFrameRate: 120, quality: .high))
        #expect(VideoFrameProcessingConfiguration.parseFrameRate("0") == nil)
        #expect(VideoFrameProcessingConfiguration.parseFrameRate("60:best") == nil)
        let configuration = VideoFrameProcessingConfiguration.fromEnvironment([
            VideoFrameProcessingConfiguration.frameRateEnvironmentKey: "48",
            VideoFrameProcessingConfiguration.transformEnvironmentKey: "rotate=bad",
        ])
        #expect(configuration.transform == nil)
        #expect(configuration.frameRateConversion?.targetFrameRate == 48)
    }
}

@Suite("Video transform geometry")
struct VideoTransformGeometryTests {
    private func format(
        width: Int, height: Int,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        aperture: CGRect? = nil,
        pixelAspect: CGSize = CGSize(width: 1, height: 1)
    ) -> VideoProcessingFormat {
        VideoProcessingFormat(
            width: width, height: height, pixelFormat: pixelFormat,
            cleanAperture: aperture ?? CGRect(x: 0, y: 0, width: width, height: height),
            pixelAspectRatio: pixelAspect, rotationDegrees: 0,
            isFullRange: false, sourceComponentDepth: 8
        )
    }

    private func expectClose(_ value: SIMD2<Double>, _ expected: SIMD2<Double>,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(value.x - expected.x) < 1e-9 && abs(value.y - expected.y) < 1e-9,
                "\(value) != \(expected)", sourceLocation: sourceLocation)
    }

    @Test func identityMapsCornersToCorners() throws {
        let geometry = try VideoTransformGeometry(
            input: format(width: 1920, height: 1080), transform: VideoFrameTransform()
        )
        #expect(geometry.outputWidth == 1920 && geometry.outputHeight == 1080)
        expectClose(geometry.sourceCoordinate(u: 0, v: 0), SIMD2(0, 0))
        expectClose(geometry.sourceCoordinate(u: 1, v: 1), SIMD2(1, 1))
    }

    @Test func clockwiseRotationSwapsAxesAndTakesTopLeftFromBottomLeft() throws {
        let geometry = try VideoTransformGeometry(
            input: format(width: 1920, height: 1080),
            transform: VideoFrameTransform(rotation: .clockwise90)
        )
        #expect(geometry.outputWidth == 1080 && geometry.outputHeight == 1920)
        expectClose(geometry.sourceCoordinate(u: 0, v: 0), SIMD2(0, 1))
        expectClose(geometry.sourceCoordinate(u: 1, v: 0), SIMD2(0, 0))
        expectClose(geometry.sourceCoordinate(u: 0, v: 1), SIMD2(1, 1))
    }

    @Test func flipsMirrorAfterRotation() throws {
        let geometry = try VideoTransformGeometry(
            input: format(width: 100, height: 50),
            transform: VideoFrameTransform(flipsHorizontally: true, flipsVertically: true)
        )
        expectClose(geometry.sourceCoordinate(u: 0, v: 0), SIMD2(1, 1))
        expectClose(geometry.sourceCoordinate(u: 1, v: 1), SIMD2(0, 0))
    }

    @Test func anamorphicSourceBecomesSquarePixels() throws {
        let input = format(width: 1440, height: 1080, pixelAspect: CGSize(width: 4, height: 3))
        let geometry = try VideoTransformGeometry(input: input, transform: VideoFrameTransform())
        #expect(geometry.outputWidth == 1920 && geometry.outputHeight == 1080)
        let output = geometry.outputFormat(from: input)
        #expect(output.hasSquarePixels && output.hasFullAperture)
        #expect(output.displaySize == input.displaySize)
    }

    @Test func cropAppliesInsideCleanAperture() throws {
        let geometry = try VideoTransformGeometry(
            input: format(width: 1920, height: 1088, aperture: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            transform: VideoFrameTransform(crop: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5))
        )
        #expect(geometry.outputWidth == 960 && geometry.outputHeight == 540)
        expectClose(geometry.sourceMin, SIMD2(480.0 / 1920, 540.0 / 1088))
        expectClose(geometry.sourceMax, SIMD2(1440.0 / 1920, 1080.0 / 1088))
        expectClose(geometry.sourceCoordinate(u: 0, v: 0), geometry.sourceMin)
    }

    @Test func planarOutputRoundsToEvenDimensions() throws {
        let geometry = try VideoTransformGeometry(
            input: format(width: 1920, height: 1080),
            transform: VideoFrameTransform(outputSize: .scale(0.3333))
        )
        #expect(geometry.outputWidth.isMultiple(of: 2) && geometry.outputHeight.isMultiple(of: 2))
        let bgra = try VideoTransformGeometry(
            input: format(width: 1920, height: 1080, pixelFormat: kCVPixelFormatType_32BGRA),
            transform: VideoFrameTransform(outputSize: .exact(width: 641, height: 361))
        )
        #expect(bgra.outputWidth == 641 && bgra.outputHeight == 361)
    }

    @Test func fitKeepsAspectInsideBox() throws {
        let geometry = try VideoTransformGeometry(
            input: format(width: 1920, height: 800),
            transform: VideoFrameTransform(outputSize: .fit(width: 1280, height: 720))
        )
        #expect(geometry.outputWidth == 1280)
        #expect(geometry.outputHeight == 534)
    }

    @Test func unsupportedFormatThrows() {
        #expect(throws: VideoFrameProcessingError.self) {
            try VideoTransformGeometry(
                input: format(width: 64, height: 64, pixelFormat: kCVPixelFormatType_422YpCbCr8),
                transform: VideoFrameTransform()
            )
        }
    }
}

@Suite("Frame-rate cadence planner")
struct FrameRateCadencePlannerTests {
    @Test func doublingInsertsOneMidpointAndKeepsEverySource() {
        var planner = FrameRateCadencePlanner(targetFrameRate: 48)
        #expect(planner.plan(next: 0).emitsSource)
        for index in 1...24 {
            let plan = planner.plan(next: Double(index) / 24)
            #expect(plan.emitsSource)
            #expect(plan.synthesized.count == 1)
            #expect(abs((plan.synthesized.first?.phase ?? 0) - 0.5) < 1e-4)
        }
    }

    @Test func film24To60KeepsUniformCadence() {
        var planner = FrameRateCadencePlanner(targetFrameRate: 60)
        var outputTimes: [Double] = [0]
        _ = planner.plan(next: 0)
        for index in 1...48 {
            let time = Double(index) / 24
            let plan = planner.plan(next: time)
            outputTimes += plan.synthesized.map(\.seconds)
            if plan.emitsSource { outputTimes.append(time) }
            // Sources at even indices sit on the 60 Hz grid; odd ones fall
            // halfway between grid times and are replaced.
            #expect(plan.emitsSource == index.isMultiple(of: 2))
        }
        #expect(outputTimes.count == 121)
        for (earlier, later) in zip(outputTimes, outputTimes.dropFirst()) {
            #expect(abs(later - earlier - 1.0 / 60) < 1e-6)
        }
    }

    @Test func sourceAtOrAboveTargetPassesThrough() {
        var planner = FrameRateCadencePlanner(targetFrameRate: 60)
        _ = planner.plan(next: 0)
        let plan = planner.plan(next: 1.0 / 60)
        #expect(plan.isPassThrough && plan.emitsSource && plan.synthesized.isEmpty)
    }

    @Test func breaksAndBackwardTimeReanchor() {
        var planner = FrameRateCadencePlanner(targetFrameRate: 60)
        _ = planner.plan(next: 1)
        let jump = planner.plan(next: 2)
        #expect(jump.reanchored && jump.emitsSource && jump.synthesized.isEmpty)
        let backward = planner.plan(next: 1.5)
        #expect(backward.reanchored && backward.emitsSource)
        #expect(planner.anchor == 1.5)
    }
}

@Suite("Video frame identity history with generated frames")
struct VideoFrameIdentitySynthesisTests {
    @Test func adjacentTimeDefersToFileWhenGenerationHasGeneratedFrames() {
        var history = VideoFrameIdentityHistory()
        typealias Identity = VideoFrameIdentityHistory.Identity
        history.append(Identity(surfaceID: 1, bufferID: 1, time: 0, generation: 1))
        history.append(Identity(surfaceID: 2, bufferID: 2, time: 1, generation: 1))
        let first = Identity(surfaceID: 1, bufferID: 1, time: 0, generation: 1)
        #expect(history.adjacentTime(to: first, direction: 1) == 1)
        history.append(Identity(surfaceID: 3, bufferID: 3, time: 0.5, generation: 1, isSynthesized: true))
        #expect(history.adjacentTime(to: first, direction: 1) == nil)
        let otherGeneration = Identity(surfaceID: 4, bufferID: 4, time: 0, generation: 2)
        history.append(otherGeneration)
        history.append(Identity(surfaceID: 5, bufferID: 5, time: 1, generation: 2))
        #expect(history.adjacentTime(to: otherGeneration, direction: 1) == 1)
    }
}

// MARK: - GPU and pipeline

enum VideoProcessingTestSupport {
    static func makeBuffer(width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, pixelFormat, attributes as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw VideoFrameProcessingError.bufferAllocation(status)
        }
        return buffer
    }

    static func fillBGRA(_ buffer: CVPixelBuffer, _ pixel: (Int, Int) -> [UInt8]) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            for x in 0..<CVPixelBufferGetWidth(buffer) {
                let value = pixel(x, y)
                for channel in 0..<4 { base[y * stride + x * 4 + channel] = value[channel] }
            }
        }
    }

    static func readBGRA(_ buffer: CVPixelBuffer, x: Int, y: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (0..<4).map { base[offset + $0] }
    }

    static func fillLuma(_ buffer: CVPixelBuffer, _ value: (Int, Int) -> UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 0) {
            for x in 0..<CVPixelBufferGetWidthOfPlane(buffer, 0) {
                base[y * stride + x] = value(x, y)
            }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
            for x in 0..<(CVPixelBufferGetWidthOfPlane(buffer, 1) * 2) {
                chroma[y * chromaStride + x] = 128
            }
        }
    }

    static func readLuma(_ buffer: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        return base[y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + x]
    }

    static func frame(
        _ buffer: CVPixelBuffer,
        seconds: Double,
        duration: Double,
        generation: Int = 1,
        permit: VideoFrameCapacityPermit? = nil
    ) -> NativeDecodedVideoFrame {
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        return NativeDecodedVideoFrame(
            pixelBuffer: buffer,
            planarOwnershipToken: nil,
            pipelineCapacityPermit: permit,
            presentationTime: CMTime(seconds: seconds, preferredTimescale: 90_000),
            duration: CMTime(seconds: duration, preferredTimescale: 90_000),
            generation: generation,
            codedSize: size,
            displaySize: size,
            pixelAspectRatio: CGSize(width: 1, height: 1),
            rotationDegrees: 0,
            colorPrimaries: 1,
            transferCharacteristic: 1,
            matrixCoefficients: 1,
            isFullRange: false,
            hasMasteringDisplayMetadata: false,
            hasContentLightMetadata: false,
            sourceComponentDepth: 8,
            ffmpegPixelFormat: "test",
            isHardwareDecoded: false,
            isCopiedHardwarePath: false,
            isNearZeroCopy: true
        )
    }
}

/// Fills each destination with its phase so tests can identify outputs.
final class RecordingInterpolator: VideoFrameInterpolator {
    /// Records identities and first bytes, never the buffers: holding them
    /// would starve the stage's history pool.
    struct Call {
        /// Whether either input was a buffer in `decoderBuffers`, checked
        /// while both are alive.
        let readDecoderBuffer: Bool
        let previousFirstByte: UInt8
        let nextFirstByte: UInt8
        let phases: [Float]
        let continuesPreviousCall: Bool
    }

    var decoderBuffers: [CVPixelBuffer] = []

    var calls: [Call] = []
    var delay: TimeInterval = 0
    var configureError: Error?
    var resets = 0

    let name = "recording"
    var supportedFormats: [OSType] = [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    var sourceBufferAttributes: [String: Any] { [:] }
    var destinationBufferAttributes: [String: Any] { [:] }

    func supportedPixelFormats(width: Int, height: Int) -> [OSType] { supportedFormats }

    private(set) var configureCount = 0

    func configure(width: Int, height: Int, pixelFormat: OSType) throws {
        configureCount += 1
        if let configureError { throw configureError }
    }

    func interpolate(
        previous: CVPixelBuffer, previousTime: CMTime,
        next: CVPixelBuffer, nextTime: CMTime,
        phases: [Float], destinations: [CVPixelBuffer],
        continuesPreviousCall: Bool
    ) throws {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        calls.append(Call(
            readDecoderBuffer: decoderBuffers.contains { $0 === previous || $0 === next },
            previousFirstByte: VideoProcessingTestSupport.readBGRA(previous, x: 0, y: 0)[0],
            nextFirstByte: VideoProcessingTestSupport.readBGRA(next, x: 0, y: 0)[0],
            phases: phases, continuesPreviousCall: continuesPreviousCall
        ))
        for (phase, buffer) in zip(phases, destinations) {
            let value = UInt8(clamping: Int(phase * 200))
            VideoProcessingTestSupport.fillBGRA(buffer) { _, _ in [value, value, value, 255] }
        }
    }

    func reset() { resets += 1 }
}

@Suite("Video frame processing pipeline", .serialized)
struct VideoFrameProcessingPipelineTests {
    private typealias Support = VideoProcessingTestSupport

    private static var hasMetal: Bool { MTLCreateSystemDefaultDevice() != nil }

    @Test(.enabled(if: hasMetal)) func horizontalFlipMirrorsBGRAPixels() throws {
        let pipeline = try VideoFrameProcessingPipeline(configuration: VideoFrameProcessingConfiguration(
            transform: VideoFrameTransform(flipsHorizontally: true)
        ))
        let source = try Support.makeBuffer(width: 4, height: 2, pixelFormat: kCVPixelFormatType_32BGRA)
        Support.fillBGRA(source) { x, y in [UInt8(x * 60), UInt8(y * 100), 7, 255] }
        let outputs = pipeline.process(Support.frame(source, seconds: 0, duration: 1.0 / 24))
        let output = try #require(outputs.first)
        #expect(outputs.count == 1)
        #expect(output.pixelBuffer !== source)
        #expect(output.origin == .processed)
        #expect(output.planarOwnershipToken == nil && output.pipelineCapacityPermit == nil)
        for y in 0..<2 {
            for x in 0..<4 {
                #expect(Support.readBGRA(output.pixelBuffer, x: x, y: y)
                    == [UInt8((3 - x) * 60), UInt8(y * 100), 7, 255])
            }
        }
        #expect(pipeline.snapshot.bypassReason == nil)
    }

    @Test(.enabled(if: hasMetal)) func rotationAndDownscaleResizePlanarFrames() throws {
        let pipeline = try VideoFrameProcessingPipeline(configuration: VideoFrameProcessingConfiguration(
            transform: VideoFrameTransform(outputSize: .scale(0.5), rotation: .clockwise90)
        ))
        let source = try Support.makeBuffer(
            width: 64, height: 32, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        // Left half dark, right half bright.
        Support.fillLuma(source) { x, _ in x < 32 ? 40 : 200 }
        let output = try #require(pipeline.process(Support.frame(source, seconds: 0, duration: 0.04)).first)
        #expect(CVPixelBufferGetWidth(output.pixelBuffer) == 16)
        #expect(CVPixelBufferGetHeight(output.pixelBuffer) == 32)
        #expect(CVPixelBufferGetPixelFormatType(output.pixelBuffer)
            == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(output.displaySize == CGSize(width: 16, height: 32))
        // Clockwise: the source's left edge becomes the top.
        #expect(Support.readLuma(output.pixelBuffer, x: 8, y: 2) == 40)
        #expect(Support.readLuma(output.pixelBuffer, x: 8, y: 29) == 200)
    }

    @Test(.enabled(if: hasMetal)) func frameRateConversionInsertsGeneratedFramesInOrder() throws {
        let interpolator = RecordingInterpolator()
        let stage = FrameRateConversionStage(
            conversion: VideoFrameRateConversion(targetFrameRate: 48), interpolator: interpolator
        )
        let pipeline = try VideoFrameProcessingPipeline(
            configuration: VideoFrameProcessingConfiguration(
                frameRateConversion: VideoFrameRateConversion(targetFrameRate: 48)
            ),
            stages: [stage]
        )
        var sources: [CVPixelBuffer] = []
        var outputs: [NativeDecodedVideoFrame] = []
        for index in 0..<3 {
            let buffer = try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA)
            Support.fillBGRA(buffer) { _, _ in [UInt8(index * 10), 0, 0, 255] }
            sources.append(buffer)
            interpolator.decoderBuffers = sources
            outputs += pipeline.process(Support.frame(buffer, seconds: Double(index) / 24, duration: 1.0 / 24))
        }
        #expect(outputs.map(\.presentationTime.seconds).map { ($0 * 48).rounded() } == [0, 1, 2, 3, 4])
        #expect(outputs.map(\.origin.isSynthesized) == [false, true, false, true, false])
        // Source frames are the decoder's own buffers; generated ones are not.
        #expect(outputs[0].pixelBuffer === sources[0])
        #expect(outputs[2].pixelBuffer === sources[1])
        #expect(outputs[4].pixelBuffer === sources[2])
        #expect(outputs[1].planarOwnershipToken == nil && outputs[1].pipelineCapacityPermit == nil)
        #expect(abs(outputs[1].duration.seconds - 1.0 / 48) < 1e-4)
        // Generated frames keep the source geometry, so they never look like
        // a format change.
        #expect(outputs[1].displaySize == outputs[0].displaySize)
        #expect(outputs[1].cleanAperture == outputs[0].cleanAperture)
        // The interpolator reads pipeline-owned copies, never decoder buffers.
        #expect(interpolator.calls.count == 2)
        #expect(interpolator.calls.allSatisfy { !$0.readDecoderBuffer })
        #expect(interpolator.calls[0].previousFirstByte == 0)
        #expect(interpolator.calls[0].nextFirstByte == 10)
        #expect(!interpolator.calls[0].continuesPreviousCall)
        #expect(interpolator.calls[1].continuesPreviousCall)
        #expect(pipeline.snapshot.synthesizedFrames == 2)
    }

    @Test(.enabled(if: hasMetal)) func newGenerationDropsHistory() throws {
        let interpolator = RecordingInterpolator()
        let pipeline = try VideoFrameProcessingPipeline(
            configuration: VideoFrameProcessingConfiguration(
                frameRateConversion: VideoFrameRateConversion(targetFrameRate: 48)
            ),
            stages: [FrameRateConversionStage(
                conversion: VideoFrameRateConversion(targetFrameRate: 48), interpolator: interpolator
            )]
        )
        let first = try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA)
        let second = try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA)
        _ = pipeline.process(Support.frame(first, seconds: 0, duration: 1.0 / 24, generation: 1))
        let afterSeek = pipeline.process(Support.frame(second, seconds: 1.0 / 24, duration: 1.0 / 24, generation: 2))
        #expect(afterSeek.count == 1)
        #expect(afterSeek.first?.pixelBuffer === second)
        #expect(interpolator.calls.isEmpty)
    }

    private func frameRatePipeline(
        _ rate: Double,
        interpolator: RecordingInterpolator = RecordingInterpolator()
    ) throws -> VideoFrameProcessingPipeline {
        try VideoFrameProcessingPipeline(
            configuration: VideoFrameProcessingConfiguration(
                frameRateConversion: VideoFrameRateConversion(targetFrameRate: rate)
            ),
            stages: [FrameRateConversionStage(
                conversion: VideoFrameRateConversion(targetFrameRate: rate), interpolator: interpolator
            )]
        )
    }

    /// Feeds frames at `times` and returns every output, including the tail.
    private func play(_ pipeline: VideoFrameProcessingPipeline, times: [Double], duration: Double) throws
        -> (outputs: [NativeDecodedVideoFrame], tail: [NativeDecodedVideoFrame]) {
        var outputs: [NativeDecodedVideoFrame] = []
        for time in times {
            let buffer = try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA)
            outputs += pipeline.process(Support.frame(buffer, seconds: time, duration: duration))
        }
        return (outputs, pipeline.finish())
    }

    private func expectContiguous(
        _ frames: [NativeDecodedVideoFrame], endingAt end: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for (earlier, later) in zip(frames, frames.dropFirst()) {
            let earlierEnd = earlier.presentationTime.seconds + earlier.duration.seconds
            #expect(abs(earlierEnd - later.presentationTime.seconds) < 1e-5,
                    "gap or overlap at \(later.presentationTime.seconds)", sourceLocation: sourceLocation)
        }
        let last = frames.last.map { $0.presentationTime.seconds + $0.duration.seconds } ?? 0
        #expect(abs(last - end) < 1e-5, "ends at \(last), not \(end)", sourceLocation: sourceLocation)
    }

    @Test(.enabled(if: hasMetal)) func endOfStreamShowsFinalOffGridSourceWithoutOverlap() throws {
        let pipeline = try frameRatePipeline(60)
        let result = try play(pipeline, times: [0, 1.0 / 24], duration: 1.0 / 24)
        // 1/24 s lies between 60 Hz grid times, so it was not shown yet. It
        // starts where the last generated frame ends and lasts to 2/24 s.
        #expect(result.tail.count == 1)
        #expect(abs((result.tail.first?.presentationTime.seconds ?? 0) - 3.0 / 60) < 1e-6)
        #expect(result.tail.first?.origin.isSynthesized == false)
        expectContiguous(result.outputs + result.tail, endingAt: 2.0 / 24)
        #expect(pipeline.finish().isEmpty)
    }

    @Test(.enabled(if: hasMetal)) func endOfStreamCompletesShortenedOnGridSource() throws {
        let pipeline = try frameRatePipeline(48)
        let result = try play(pipeline, times: [0, 1.0 / 24], duration: 1.0 / 24)
        // The final source was shown for one 48 Hz interval; the tail shows
        // it for the rest of its own duration.
        #expect(result.tail.count == 1)
        expectContiguous(result.outputs + result.tail, endingAt: 2.0 / 24)
    }

    @Test(.enabled(if: hasMetal)) func endOfStreamCompletesASingleSourceFrame() throws {
        // Only the decoder's own buffer was shown, for one 60 Hz interval.
        let pipeline = try frameRatePipeline(60)
        let result = try play(pipeline, times: [0], duration: 1.0 / 24)
        #expect(result.outputs.count == 1)
        #expect(result.tail.count == 1)
        #expect(result.tail.first?.planarOwnershipToken == nil)
        #expect(result.tail.first?.displaySize == result.outputs.first?.displaySize)
        expectContiguous(result.outputs + result.tail, endingAt: 1.0 / 24)
    }

    @Test(.enabled(if: hasMetal)) func outputsNeverOutlastAShortFinalSource() throws {
        let pipeline = try frameRatePipeline(60)
        var outputs: [NativeDecodedVideoFrame] = []
        for (time, duration) in [(0.0, 0.040), (0.040, 0.005)] {
            let buffer = try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA)
            outputs += pipeline.process(Support.frame(buffer, seconds: time, duration: duration))
        }
        outputs += pipeline.finish()
        expectContiguous(outputs, endingAt: 0.045)
    }

    @Test(.enabled(if: hasMetal)) func longGapsShowSourceInsteadOfFillingThePool() throws {
        let interpolator = RecordingInterpolator()
        let pipeline = try frameRatePipeline(120, interpolator: interpolator)
        // 200 ms at 120 Hz would need 23 generated frames; the limit is 8.
        var outputs: [NativeDecodedVideoFrame] = []
        for time in [0, 0.2] {
            let buffer = try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA)
            outputs += pipeline.process(Support.frame(buffer, seconds: time, duration: 0.2))
        }
        #expect(outputs.count == 2)
        #expect(!outputs.contains { $0.origin.isSynthesized })
        #expect(interpolator.calls.isEmpty)
        #expect(pipeline.snapshot.bypassReason == nil)
        // A shorter gap still interpolates afterwards.
        let buffer = try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA)
        let next = pipeline.process(Support.frame(buffer, seconds: 0.225, duration: 0.025))
        #expect(next.filter { $0.origin.isSynthesized }.count == 2)
    }

    @Test func unsupportedTargetRatesAreRejected() {
        for rate in [Double.infinity, .nan, 0, -24, 1_000] {
            #expect(throws: VideoFrameProcessingError.self, "\(rate)") {
                try VideoFrameProcessingPipeline(configuration: VideoFrameProcessingConfiguration(
                    frameRateConversion: VideoFrameRateConversion(targetFrameRate: rate)
                ))
            }
            var planner = FrameRateCadencePlanner(targetFrameRate: rate)
            _ = planner.plan(next: 0)
            #expect(planner.plan(next: 0.1).isPassThrough)
        }
    }

    @Test(.enabled(if: hasMetal)) func textureFailureFallsBackWithoutBreakingLaterFrames() throws {
        let pipeline = try VideoFrameProcessingPipeline(configuration: VideoFrameProcessingConfiguration(
            transform: VideoFrameTransform(flipsHorizontally: true)
        ))
        // No IOSurface: Metal cannot wrap it, so texture creation fails.
        var plain: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA, nil, &plain)
        let buffer = try #require(plain)
        let outputs = pipeline.process(Support.frame(buffer, seconds: 0, duration: 1.0 / 24))
        #expect(outputs.count == 1 && outputs.first?.pixelBuffer === buffer)
        #expect(pipeline.snapshot.bypassReason?.contains("Texture creation failed") == true)
        // A fresh pipeline on the same device still works afterwards.
        let healthy = try VideoFrameProcessingPipeline(configuration: VideoFrameProcessingConfiguration(
            transform: VideoFrameTransform(flipsHorizontally: true)
        ))
        let surface = try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA)
        #expect(healthy.process(Support.frame(surface, seconds: 0, duration: 1.0 / 24)).first?.origin == .processed)
    }

    @Test(.enabled(if: hasMetal)) func slowInterpolationSuspendsGeneratedFrames() throws {
        let interpolator = RecordingInterpolator()
        interpolator.delay = 0.03
        let pipeline = try VideoFrameProcessingPipeline(
            configuration: VideoFrameProcessingConfiguration(
                frameRateConversion: VideoFrameRateConversion(targetFrameRate: 96)
            ),
            stages: [FrameRateConversionStage(
                conversion: VideoFrameRateConversion(targetFrameRate: 96), interpolator: interpolator
            )]
        )
        var lastOutputs: [NativeDecodedVideoFrame] = []
        for index in 0...(VideoFrameProcessingPipeline.overrunLimit + 2) {
            let buffer = try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA)
            // 30 ms per call against a 16.7 ms budget at 1/48 s per source frame.
            lastOutputs = pipeline.process(Support.frame(buffer, seconds: Double(index) / 48, duration: 1.0 / 48))
        }
        #expect(pipeline.snapshot.synthesisSuspended)
        #expect(lastOutputs.count == 1)
        #expect(lastOutputs.first?.origin == .decoded)
        pipeline.reset()
        #expect(!pipeline.snapshot.synthesisSuspended)
    }

    @Test(.enabled(if: hasMetal)) func unsupportedProcessorPassesFramesThrough() throws {
        let interpolator = RecordingInterpolator()
        interpolator.configureError = VideoFrameProcessingError.processorUnavailable("test")
        let pipeline = try VideoFrameProcessingPipeline(
            configuration: VideoFrameProcessingConfiguration(
                frameRateConversion: VideoFrameRateConversion(targetFrameRate: 60)
            ),
            stages: [FrameRateConversionStage(
                conversion: VideoFrameRateConversion(targetFrameRate: 60), interpolator: interpolator
            )]
        )
        let buffer = try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA)
        let outputs = pipeline.process(Support.frame(buffer, seconds: 0, duration: 1.0 / 24))
        #expect(outputs.count == 1 && outputs.first?.pixelBuffer === buffer)
        #expect(pipeline.snapshot.bypassReason?.contains("test") == true)
        let later = pipeline.process(Support.frame(buffer, seconds: 1.0 / 24, duration: 1.0 / 24))
        #expect(later.count == 1 && later.first?.pixelBuffer === buffer)
    }

    @Test(.enabled(if: hasMetal)) func decoderPermitIsReleasedWhenCallerDropsTheFrame() throws {
        let gate = VideoFrameCapacityGate(capacity: 1)
        let pipeline = try VideoFrameProcessingPipeline(
            configuration: VideoFrameProcessingConfiguration(
                frameRateConversion: VideoFrameRateConversion(targetFrameRate: 48)
            ),
            stages: [FrameRateConversionStage(
                conversion: VideoFrameRateConversion(targetFrameRate: 48), interpolator: RecordingInterpolator()
            )]
        )
        for index in 0..<3 {
            // With capacity one, a stage that kept a decoder frame would make
            // this acquisition wait forever.
            let buffer = try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA)
            let outputs = pipeline.process(Support.frame(
                buffer, seconds: Double(index) / 24, duration: 1.0 / 24,
                permit: gate.acquire(while: { true })
            ))
            #expect(gate.snapshot.inUse == (outputs.contains { $0.pipelineCapacityPermit != nil } ? 1 : 0))
            // Once the caller presents and drops its frames, nothing in the
            // pipeline still holds the permit.
            _ = consume outputs
            #expect(gate.snapshot.inUse == 0)
        }
    }

    @Test(.enabled(if: hasMetal && VideoToolboxLowLatencyInterpolator.isSupported))
    func videoToolboxGeneratesBetweenFrames() throws {
        let pipeline = try VideoFrameProcessingPipeline(configuration: VideoFrameProcessingConfiguration(
            frameRateConversion: VideoFrameRateConversion(targetFrameRate: 48)
        ))
        var outputs: [NativeDecodedVideoFrame] = []
        for index in 0..<2 {
            let buffer = try Support.makeBuffer(
                width: 640, height: 360, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )
            Support.fillLuma(buffer) { x, _ in x < 320 + index * 40 ? 40 : 200 }
            outputs += pipeline.process(Support.frame(buffer, seconds: Double(index) / 24, duration: 1.0 / 24))
            if index == 0 { #expect(pipeline.waitUntilReady(timeout: 30)) }
        }
        let snapshot = pipeline.snapshot
        print("VIDEO_TOOLBOX_420V: outputs=\(outputs.map(\.origin)) bypass=\(snapshot.bypassReason ?? "none")")
        // Low-latency interpolation accepts 420v directly: no conversion.
        #expect(snapshot.bypassReason == nil)
        #expect(outputs.allSatisfy {
            CVPixelBufferGetPixelFormatType($0.pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        })
        #expect(outputs.map(\.origin.isSynthesized) == [false, true, false])
    }
}

@Suite("Video frame RGBA conversion and interpolator selection", .serialized)
struct VideoFrameInterpolatorSelectionTests {
    private typealias Support = VideoProcessingTestSupport
    private static var hasMetal: Bool { MTLCreateSystemDefaultDevice() != nil }

    private static func readRGBAHalf(_ buffer: CVPixelBuffer, x: Int, y: Int) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer))
            .assumingMemoryBound(to: Float16.self)
        return (0..<4).map { Float(row[x * 4 + $0]) }
    }

    @Test func bt709CoefficientsMatchTheStandard() {
        let c = VideoColorConversionUniforms.coefficients(kr: 0.2126, kb: 0.0722)
        #expect(abs(c.x - 1.5748) < 1e-4)
        #expect(abs(c.y - 0.18732) < 1e-4)
        #expect(abs(c.z - 0.46812) < 1e-4)
        #expect(abs(c.w - 1.8556) < 1e-4)
    }

    @Test func videoRangeBlackAndWhiteMapToZeroAndOne() throws {
        let eight = try #require(VideoColorConversionUniforms.make(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, matrix: nil
        ))
        // Untagged matches the display layer's BT.601 default at any size.
        #expect(abs(eight.coefficients.x - 2 * (1 - 0.299)) < 1e-5)
        #expect(abs((16.0 / 255 - eight.lumaOffset) * eight.lumaScale) < 1e-5)
        #expect(abs((235.0 / 255 - eight.lumaOffset) * eight.lumaScale - 1) < 1e-5)
        let ten = try #require(VideoColorConversionUniforms.make(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020
        ))
        #expect(abs((940.0 * 64 / 65_535 - ten.lumaOffset) * ten.lumaScale - 1) < 1e-5)
        #expect(abs(ten.coefficients.x - 2 * (1 - 0.2627)) < 1e-5)
        #expect(VideoColorConversionUniforms.make(
            pixelFormat: kCVPixelFormatType_32BGRA, matrix: nil
        ) == nil)
    }

    @Test func lowLatencyPhasesSnapToAvailablePoints() {
        #expect(VideoToolboxLowLatencyInterpolator.snappedPhases([0.5]) == (1, [0.5]))
        let film = VideoToolboxLowLatencyInterpolator.snappedPhases([0.4, 0.8])
        #expect(film.exponent == 3 && film.phases == [0.375, 0.75])
        #expect(VideoToolboxLowLatencyInterpolator.snappedPhases([0.01, 0.99]).phases == [0.125, 0.875])
    }

    @Test(.enabled(if: hasMetal)) func convertsPlanarAndBGRAToRGBAHalf() throws {
        let context = try VideoFrameProcessingContext()
        let converter = try MetalRGBAConverter(width: 4, height: 4, maximumBufferCount: 4)
        let planar = try Support.makeBuffer(
            width: 4, height: 4, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        Support.fillLuma(planar) { _, _ in 235 }
        let white = try converter.convert(planar, context: context)
        let bgra = try Support.makeBuffer(width: 4, height: 4, pixelFormat: kCVPixelFormatType_32BGRA)
        Support.fillBGRA(bgra) { _, _ in [0, 0, 255, 255] }
        let red = try converter.convert(bgra, context: context)
        try context.synchronize()
        #expect(CVPixelBufferGetPixelFormatType(white) == kCVPixelFormatType_64RGBAHalf)
        let whitePixel = Self.readRGBAHalf(white, x: 1, y: 1)
        #expect(whitePixel.allSatisfy { abs($0 - 1) < 0.01 }, "\(whitePixel)")
        let redPixel = Self.readRGBAHalf(red, x: 2, y: 3)
        #expect(redPixel == [1, 0, 0, 1], "\(redPixel)")
    }

    @Test(.enabled(if: hasMetal)) func rgbaOnlyInterpolatorConvertsEveryFrame() throws {
        let interpolator = RecordingInterpolator()
        interpolator.supportedFormats = [kCVPixelFormatType_64RGBAHalf]
        let stage = FrameRateConversionStage(
            conversion: VideoFrameRateConversion(targetFrameRate: 48), interpolator: interpolator
        )
        let pipeline = try VideoFrameProcessingPipeline(
            configuration: VideoFrameProcessingConfiguration(
                frameRateConversion: VideoFrameRateConversion(targetFrameRate: 48)
            ),
            stages: [stage]
        )
        var outputs: [NativeDecodedVideoFrame] = []
        for index in 0..<2 {
            let buffer = try Support.makeBuffer(
                width: 8, height: 8, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )
            Support.fillLuma(buffer) { _, _ in 126 }
            outputs += pipeline.process(Support.frame(buffer, seconds: Double(index) / 24, duration: 1.0 / 24))
        }
        #expect(stage.convertsToRGBA)
        #expect(outputs.count == 3)
        // One pixel format for the whole session: no per-frame format changes.
        #expect(outputs.allSatisfy {
            CVPixelBufferGetPixelFormatType($0.pixelBuffer) == kCVPixelFormatType_64RGBAHalf
        })
        #expect(outputs.map(\.origin.isSynthesized) == [false, true, false])
        #expect(outputs[0].origin == .processed)
    }

    @Test func noCompatibleInterpolatorBypasses() throws {
        guard Self.hasMetal else { return }
        let interpolator = RecordingInterpolator()
        interpolator.supportedFormats = []
        let pipeline = try VideoFrameProcessingPipeline(
            configuration: VideoFrameProcessingConfiguration(
                frameRateConversion: VideoFrameRateConversion(targetFrameRate: 48)
            ),
            stages: [FrameRateConversionStage(
                conversion: VideoFrameRateConversion(targetFrameRate: 48), interpolator: interpolator
            )]
        )
        let buffer = try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA)
        let outputs = pipeline.process(Support.frame(buffer, seconds: 0, duration: 1.0 / 24))
        #expect(outputs.first?.pixelBuffer === buffer)
        #expect(pipeline.snapshot.bypassReason?.contains("No interpolator") == true)
    }

    @Test(.enabled(if: hasMetal && VideoToolboxFrameInterpolator.isSupported))
    func videoToolboxInterpolatesBGRAThroughRGBA() throws {
        let pipeline = try VideoFrameProcessingPipeline(configuration: VideoFrameProcessingConfiguration(
            frameRateConversion: VideoFrameRateConversion(targetFrameRate: 60)
        ))
        var outputs: [NativeDecodedVideoFrame] = []
        for index in 0..<3 {
            let buffer = try Support.makeBuffer(width: 640, height: 360, pixelFormat: kCVPixelFormatType_32BGRA)
            Support.fillBGRA(buffer) { x, _ in x < 200 + index * 40 ? [20, 20, 20, 255] : [220, 200, 180, 255] }
            outputs += pipeline.process(Support.frame(buffer, seconds: Double(index) / 24, duration: 1.0 / 24))
            if index == 0 { #expect(pipeline.waitUntilReady(timeout: 30)) }
        }
        print("VIDEO_TOOLBOX_RGBA: outputs=\(outputs.map(\.origin)) bypass=\(pipeline.snapshot.bypassReason ?? "none")")
        #expect(pipeline.snapshot.bypassReason == nil)
        #expect(outputs.contains { $0.origin.isSynthesized })
        #expect(outputs.allSatisfy {
            CVPixelBufferGetPixelFormatType($0.pixelBuffer) == kCVPixelFormatType_64RGBAHalf
        })
    }
}

@Suite("Video frame processing with VideoToolbox after a transform", .serialized)
struct VideoFrameTransformInterpolationTests {
    private typealias Support = VideoProcessingTestSupport

    /// Transformed frames feed interpolation and also reach the renderer.
    /// VideoToolbox writes into padding its own pools add; given another
    /// stage's buffer directly, it corrupted memory and crashed on release.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil && VideoToolboxLowLatencyInterpolator.isSupported))
    func transformedFramesSurviveInterpolation() throws {
        let pipeline = try VideoFrameProcessingPipeline(configuration: VideoFrameProcessingConfiguration(
            transform: VideoFrameTransform(outputSize: .scale(0.5), flipsHorizontally: true),
            frameRateConversion: VideoFrameRateConversion(targetFrameRate: 60)
        ))
        var retained: [NativeDecodedVideoFrame] = []
        for index in 0..<36 {
            let buffer = try Support.makeBuffer(
                width: 640, height: 360, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )
            Support.fillLuma(buffer) { x, _ in x < 200 + index * 8 ? 40 : 200 }
            let outputs = pipeline.process(Support.frame(buffer, seconds: Double(index) / 24, duration: 1.0 / 24))
            if index == 0 { #expect(pipeline.waitUntilReady(timeout: 30)) }
            retained += outputs
            // Mimic the renderer and PiP compositor holding a few frames.
            if retained.count > 6 { retained.removeFirst(retained.count - 6) }
            for frame in outputs {
                #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == 320)
                _ = Support.readLuma(frame.pixelBuffer, x: 10, y: 10)
            }
        }
        retained.removeAll()
        #expect(pipeline.snapshot.bypassReason == nil)
        #expect(pipeline.snapshot.synthesizedFrames > 0)
    }
}

@Suite("Video frame processing at 1080p", .serialized)
struct VideoFrameProcessingHighDefinitionTests {
    private typealias Support = VideoProcessingTestSupport

    /// Ten-bit 1080p goes through RGBA conversion and full frame-rate
    /// conversion; a live run hung on its first frame.
    @Test(.enabled(if: VideoToolboxFrameInterpolator.isSupported))
    func tenBitHighDefinitionInterpolatesWithoutStalling() throws {
        let pipeline = try VideoFrameProcessingPipeline(configuration: VideoFrameProcessingConfiguration(
            frameRateConversion: VideoFrameRateConversion(targetFrameRate: 60)
        ))
        var outputs: [NativeDecodedVideoFrame] = []
        for index in 0..<4 {
            let buffer = try Support.makeBuffer(
                width: 1920, height: 1080, pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            )
            let started = Date()
            outputs += pipeline.process(Support.frame(buffer, seconds: Double(index) / 24, duration: 1.0 / 24))
            if index == 0 { #expect(pipeline.waitUntilReady(timeout: 30)) }
            print("HD_FRAME \(index) ms=\(Int(Date().timeIntervalSince(started) * 1000)) "
                + "snapshot=\(pipeline.snapshot)")
        }
        #expect(pipeline.snapshot.bypassReason == nil)
        #expect(outputs.contains { $0.origin.isSynthesized })
    }
}

/// Stands in for a model that loads slowly the first time.
final class SlowStartingInterpolator: VideoFrameInterpolator {
    let name = "slow-start"
    let started = DispatchSemaphore(value: 0)
    var sourceBufferAttributes: [String: Any] { [:] }
    var destinationBufferAttributes: [String: Any] { [:] }
    var requiresWarmUp: Bool { true }
    func supportedPixelFormats(width: Int, height: Int) -> [OSType] { [kCVPixelFormatType_32BGRA] }
    func configure(width: Int, height: Int, pixelFormat: OSType) throws {}
    func warmUp() throws { _ = started.wait(timeout: .now() + 10) }
    func interpolate(
        previous: CVPixelBuffer, previousTime: CMTime, next: CVPixelBuffer, nextTime: CMTime,
        phases: [Float], destinations: [CVPixelBuffer], continuesPreviousCall: Bool
    ) throws {}
    func reset() {}
}

@Suite("Video frame processing warm-up", .serialized)
struct VideoFrameProcessingWarmUpTests {
    private typealias Support = VideoProcessingTestSupport

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func modelLoadingNeverHoldsUpFrames() throws {
        let interpolator = SlowStartingInterpolator()
        let pipeline = try VideoFrameProcessingPipeline(
            configuration: VideoFrameProcessingConfiguration(
                frameRateConversion: VideoFrameRateConversion(targetFrameRate: 48)
            ),
            stages: [FrameRateConversionStage(
                conversion: VideoFrameRateConversion(targetFrameRate: 48), interpolator: interpolator
            )]
        )
        let started = Date()
        var outputs: [NativeDecodedVideoFrame] = []
        for index in 0..<3 {
            let buffer = try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA)
            outputs += pipeline.process(Support.frame(buffer, seconds: Double(index) / 24, duration: 1.0 / 24))
        }
        // Frames flow immediately as sources while the model is loading.
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(outputs.count == 3)
        #expect(!outputs.contains { $0.origin.isSynthesized })
        #expect(pipeline.snapshot.warmingUp)
        interpolator.started.signal()
        #expect(pipeline.waitUntilReady(timeout: 5))
        let buffer = try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA)
        let later = pipeline.process(Support.frame(buffer, seconds: 3.0 / 24, duration: 1.0 / 24))
        #expect(later.contains { $0.origin.isSynthesized })
        #expect(!pipeline.snapshot.warmingUp)
    }
}
