import CoreMedia
import CoreVideo
import Foundation
import IlliquidCore
import IlliquidPlayback
import Metal
import Testing
@testable import IlliquidNativePlayback

@Suite("Picture adjustment mapping")
struct PictureAdjustmentMappingTests {
    @Test func controlsMapLikeMpv() {
        let neutral = PictureAdjustmentUniforms(VideoPictureAdjustments())
        #expect(neutral.brightness == 0 && neutral.contrast == 1 && neutral.saturation == 1)
        #expect(neutral.gammaExponent == 1 && neutral.hueCos == 1 && neutral.hueSin == 0)
        let extreme = PictureAdjustmentUniforms(VideoPictureAdjustments(
            brightness: 100, contrast: -100, saturation: 100, gamma: 100, hue: 100
        ))
        #expect(extreme.brightness == 1 && extreme.contrast == 0 && extreme.saturation == 2)
        #expect(abs(extreme.gammaExponent - 1.0 / 8) < 1e-6)
        #expect(abs(extreme.hueCos + 1) < 1e-6)
        // Out-of-range and non-finite input is clamped, not passed through.
        let wild = PictureAdjustmentUniforms(VideoPictureAdjustments(brightness: 500, contrast: .nan))
        #expect(wild.brightness == 1 && wild.contrast == 1)
    }

    @Test func neutralSettingsAddNoStages() {
        let stages = VideoFrameProcessingPipeline.makeStages(for: VideoFrameProcessingConfiguration(
            transform: VideoFrameTransform(), pictureAdjustments: VideoPictureAdjustments()
        ))
        #expect(stages.isEmpty)
        #expect(!VideoFrameProcessingConfiguration(pictureAdjustments: VideoPictureAdjustments()).isEnabled)
    }

    @Test func stagesRunInAFixedOrder() {
        let stages = VideoFrameProcessingPipeline.makeStages(for: VideoFrameProcessingConfiguration(
            transform: VideoFrameTransform(rotation: .clockwise90),
            frameRateConversion: VideoFrameRateConversion(targetFrameRate: 60),
            pictureAdjustments: VideoPictureAdjustments(brightness: 10),
            filters: [.sharpen, .deband, .denoise]
        ))
        #expect(stages.map(\.name) == [
            "denoise", "deband", "picture-adjust", "metal-transform", "sharpen", "frame-rate-conversion",
        ])
    }
}

@Suite("Picture filters on the GPU", .serialized)
struct PictureFilterGPUTests {
    private typealias Support = VideoProcessingTestSupport
    private static var hasMetal: Bool { MTLCreateSystemDefaultDevice() != nil }

    private func pipeline(_ configuration: VideoFrameProcessingConfiguration) throws -> VideoFrameProcessingPipeline {
        try VideoFrameProcessingPipeline(configuration: configuration)
    }

    private func planar(_ width: Int = 16, _ height: Int = 16, luma: (Int, Int) -> UInt8, chroma: UInt8 = 128) throws
        -> CVPixelBuffer {
        let buffer = try Support.makeBuffer(
            width: width, height: height, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        Support.fillLuma(buffer, luma)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<(height / 2) {
            for x in 0..<width { base[y * stride + x] = x.isMultiple(of: 2) ? chroma : 255 - chroma }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func chroma(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (UInt8, UInt8) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + x * 2
        return (base[offset], base[offset + 1])
    }

    private func lumaRow(_ buffer: CVPixelBuffer, y: Int) -> [Int] {
        (0..<CVPixelBufferGetWidth(buffer)).map { Int(Support.readLuma(buffer, x: $0, y: y)) }
    }

    private func process(_ pipeline: VideoFrameProcessingPipeline, _ buffer: CVPixelBuffer, at seconds: Double = 0)
        throws -> NativeDecodedVideoFrame {
        let outputs = pipeline.process(Support.frame(buffer, seconds: seconds, duration: 1.0 / 24))
        #expect(pipeline.snapshot.bypassReason == nil, "\(pipeline.snapshot.bypassReason ?? "")")
        return try #require(outputs.first)
    }

    @Test(.enabled(if: hasMetal)) func brightnessRaisesLumaAndKeepsChroma() throws {
        let processing = try pipeline(VideoFrameProcessingConfiguration(
            pictureAdjustments: VideoPictureAdjustments(brightness: 25)
        ))
        let output = try process(processing, try planar(luma: { _, _ in 126 }, chroma: 90))
        // 126 is mid-grey in video range; +25 adds a quarter of 219 codes.
        #expect(abs(Int(Support.readLuma(output.pixelBuffer, x: 4, y: 4)) - (126 + 55)) <= 1)
        let (cb, cr) = chroma(output.pixelBuffer, x: 2, y: 2)
        #expect(abs(Int(cb) - 90) <= 1 && abs(Int(cr) - 165) <= 1)
        #expect(output.origin == .processed)
    }

    @Test(.enabled(if: hasMetal)) func zeroSaturationRemovesColor() throws {
        let processing = try pipeline(VideoFrameProcessingConfiguration(
            pictureAdjustments: VideoPictureAdjustments(saturation: -100)
        ))
        let output = try process(processing, try planar(luma: { _, _ in 100 }, chroma: 60))
        let (cb, cr) = chroma(output.pixelBuffer, x: 3, y: 3)
        #expect(abs(Int(cb) - 128) <= 1 && abs(Int(cr) - 128) <= 1)
        #expect(Support.readLuma(output.pixelBuffer, x: 1, y: 1) == 100)
    }

    @Test(.enabled(if: hasMetal)) func bgraSaturationGoesGrey() throws {
        let processing = try pipeline(VideoFrameProcessingConfiguration(
            pictureAdjustments: VideoPictureAdjustments(saturation: -100)
        ))
        let buffer = try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA)
        Support.fillBGRA(buffer) { _, _ in [0, 0, 255, 255] }
        let output = try process(processing, buffer)
        let pixel = Support.readBGRA(output.pixelBuffer, x: 2, y: 2)
        #expect(abs(Int(pixel[0]) - Int(pixel[2])) <= 1 && abs(Int(pixel[1]) - Int(pixel[2])) <= 1)
        #expect(abs(Int(pixel[2]) - 76) <= 2) // BT.601 luma of pure red
    }

    @Test(.enabled(if: hasMetal)) func sharpenLeavesFlatAreasAndSteepensEdges() throws {
        let processing = try pipeline(VideoFrameProcessingConfiguration(filters: [.sharpen]))
        let input = try planar(luma: { x, _ in x < 8 ? 80 : 160 })
        let output = try process(processing, input)
        let row = lumaRow(output.pixelBuffer, y: 8)
        #expect(row[2] == 80 && row[13] == 160)
        #expect(row[7] < 80 && row[8] > 160)
        #expect(row.allSatisfy { (0...255).contains($0) })
    }

    @Test(.enabled(if: hasMetal)) func debandSmoothsStepsButKeepsDetail() throws {
        let processing = try pipeline(VideoFrameProcessingConfiguration(filters: [.deband]))
        // Left: a gradient in one-code steps every 8 pixels. Right: hard
        // 0/255-style detail far above the threshold.
        let input = try planar(64, 16, luma: { x, y in
            x < 32 ? UInt8(100 + x / 8) : ((x / 4 + y / 4).isMultiple(of: 2) ? 30 : 220)
        })
        let output = try process(processing, input)
        var changedInGradient = 0
        for y in 0..<16 {
            let before = lumaRow(input, y: y)
            let after = lumaRow(output.pixelBuffer, y: y)
            // Detail survives: no pixel moves by more than the threshold
            // (3 codes) plus grain (under 1), against a 190-code pattern.
            for x in 32..<64 { #expect(abs(after[x] - before[x]) <= 4, "detail changed at \(x),\(y)") }
            for x in 4..<28 where after[x] != before[x] { changedInGradient += 1 }
        }
        #expect(changedInGradient > 50)
    }

    @Test(.enabled(if: hasMetal)) func denoiseReducesStaticNoiseWithoutGhostingMotion() throws {
        let processing = try pipeline(VideoFrameProcessingConfiguration(filters: [.denoise]))
        var generator = SystemRandomNumberGenerator()
        var lastOutput: CVPixelBuffer?
        var inputDeviation = 0.0
        for index in 0..<6 {
            let noise = (0..<256).map { _ in Int.random(in: -6...6, using: &generator) }
            let input = try planar(luma: { x, y in UInt8(128 + noise[y * 16 + x]) })
            inputDeviation = deviation(lumaRow(input, y: 5) + lumaRow(input, y: 9))
            lastOutput = try process(processing, input, at: Double(index) / 24).pixelBuffer
        }
        let outputDeviation = deviation(lumaRow(try #require(lastOutput), y: 5) + lumaRow(try #require(lastOutput), y: 9))
        #expect(outputDeviation < inputDeviation * 0.7, "\(outputDeviation) vs \(inputDeviation)")
        // A bright square appears: it must show at once, not fade in.
        let moved = try planar(luma: { x, y in (4..<12).contains(x) && (4..<12).contains(y) ? 230 : 128 })
        let output = try process(processing, moved, at: 6.0 / 24)
        #expect(Support.readLuma(output.pixelBuffer, x: 8, y: 8) > 215)
    }

    private func deviation(_ values: [Int]) -> Double {
        let mean = Double(values.reduce(0, +)) / Double(values.count)
        return (values.map { pow(Double($0) - mean, 2) }.reduce(0, +) / Double(values.count)).squareRoot()
    }

    @Test(.enabled(if: hasMetal)) func tenBitAndBGRAInputsAreSupported() throws {
        let processing = try pipeline(VideoFrameProcessingConfiguration(
            pictureAdjustments: VideoPictureAdjustments(contrast: 20), filters: [.denoise, .deband, .sharpen]
        ))
        let tenBit = try Support.makeBuffer(
            width: 32, height: 16, pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        let output = try process(processing, tenBit)
        #expect(CVPixelBufferGetPixelFormatType(output.pixelBuffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let bgra = try Support.makeBuffer(width: 32, height: 16, pixelFormat: kCVPixelFormatType_32BGRA)
        _ = try process(processing, bgra, at: 1.0 / 24)
    }
}

@Suite("Live processing changes", .serialized)
struct VideoProcessingLiveUpdateTests {
    private typealias Support = VideoProcessingTestSupport
    private static var hasMetal: Bool { MTLCreateSystemDefaultDevice() != nil }

    @Test(.enabled(if: hasMetal)) func changesApplyFromTheNextFrame() throws {
        let processing = try VideoFrameProcessingPipeline(configuration: .disabled)
        let source = try Support.makeBuffer(
            width: 16, height: 16, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        Support.fillLuma(source) { _, _ in 126 }
        // Nothing enabled: the decoder's frame passes through untouched.
        let untouched = processing.process(Support.frame(source, seconds: 0, duration: 0.04))
        #expect(untouched.first?.pixelBuffer === source)
        #expect(processing.snapshot.stageNames.isEmpty)

        try processing.update(configuration: VideoFrameProcessingConfiguration(
            pictureAdjustments: VideoPictureAdjustments(brightness: 25)
        ))
        #expect(processing.snapshot.stageNames == ["picture-adjust"])
        let brighter = try #require(processing.process(Support.frame(source, seconds: 0.04, duration: 0.04)).first)
        #expect(Support.readLuma(brighter.pixelBuffer, x: 3, y: 3) > 170)

        try processing.update(configuration: VideoFrameProcessingConfiguration(
            pictureAdjustments: VideoPictureAdjustments(brightness: -25)
        ))
        let darker = try #require(processing.process(Support.frame(source, seconds: 0.08, duration: 0.04)).first)
        #expect(Support.readLuma(darker.pixelBuffer, x: 3, y: 3) < 80)

        try processing.update(configuration: .disabled)
        let restored = processing.process(Support.frame(source, seconds: 0.12, duration: 0.04))
        #expect(restored.first?.pixelBuffer === source)
    }

    @Test(.enabled(if: hasMetal)) func unchangedStagesKeepTheirState() throws {
        let interpolator = RecordingInterpolator()
        let conversion = VideoFrameRateConversion(targetFrameRate: 48)
        let frameRate = FrameRateConversionStage(conversion: conversion, interpolator: interpolator)
        let processing = try VideoFrameProcessingPipeline(
            configuration: VideoFrameProcessingConfiguration(frameRateConversion: conversion),
            stages: [frameRate]
        )
        for index in 0..<2 {
            let buffer = try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA)
            _ = processing.process(Support.frame(buffer, seconds: Double(index) / 24, duration: 1.0 / 24))
        }
        #expect(interpolator.configureCount == 1)
        // A color change mid-play keeps interpolation's history and model.
        for (index, brightness) in [10.0, 20.0, 30.0].enumerated() {
            try processing.update(configuration: VideoFrameProcessingConfiguration(
                frameRateConversion: conversion,
                pictureAdjustments: VideoPictureAdjustments(brightness: brightness)
            ))
            let buffer = try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA)
            let outputs = processing.process(Support.frame(buffer, seconds: Double(index + 2) / 24, duration: 1.0 / 24))
            #expect(outputs.contains { $0.origin.isSynthesized })
        }
        #expect(interpolator.configureCount == 1)
        #expect(interpolator.calls.last?.continuesPreviousCall == true)
        #expect(processing.snapshot.stageNames == ["picture-adjust", "frame-rate-conversion"])
    }

    @Test(.enabled(if: hasMetal)) func updatesNeverWaitForAFrameInProgress() throws {
        let interpolator = RecordingInterpolator()
        interpolator.delay = 0.3
        let conversion = VideoFrameRateConversion(targetFrameRate: 48)
        let processing = try VideoFrameProcessingPipeline(
            configuration: VideoFrameProcessingConfiguration(frameRateConversion: conversion),
            stages: [FrameRateConversionStage(conversion: conversion, interpolator: interpolator)]
        )
        let first = try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA)
        _ = processing.process(Support.frame(first, seconds: 0, duration: 1.0 / 24))
        let second = Support.frame(
            try Support.makeBuffer(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA),
            seconds: 1.0 / 24, duration: 1.0 / 24
        )
        let finished = DispatchSemaphore(value: 0)
        let worker = Thread {
            _ = processing.process(second)
            finished.signal()
        }
        worker.start()
        Thread.sleep(forTimeInterval: 0.05)
        let started = Date()
        try processing.update(configuration: VideoFrameProcessingConfiguration(
            frameRateConversion: conversion, filters: [.sharpen]
        ))
        #expect(Date().timeIntervalSince(started) < 0.1)
        #expect(finished.wait(timeout: .now() + 2) == .success)
    }
}

@Suite("Native runtime picture controls")
@MainActor
struct NativeRuntimePictureControlTests {
    @Test func runtimeAdvertisesAndAppliesPictureControls() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let runtime = try NativePlaybackRuntime(videoFrameProcessing: .disabled)
        #expect(runtime.capabilities.contains(.videoAdjustments))
        #expect(runtime.capabilities.contains(.videoFilters))
        #expect(!runtime.effectiveVideoProcessing.isEnabled)

        var adjustments = VideoAdjustmentState.standard
        adjustments.contrast = 15
        adjustments.hue = -10
        runtime.setVideoEqualizer(adjustments)
        runtime.setVideoRotation(270)
        try await runtime.execute(.addVideoFilter(.deband))
        try await runtime.execute(.addVideoFilter(.sharpen))
        try await runtime.execute(.removeVideoFilter(.sharpen))

        let effective = runtime.effectiveVideoProcessing
        #expect(effective.pictureAdjustments == VideoPictureAdjustments(contrast: 15, hue: -10))
        // Rotation is a view transform: it never reaches the GPU pipeline.
        #expect(effective.transform == nil)
        #expect(effective.filters == [.deband])

        runtime.setVideoEqualizer(.standard)
        runtime.setVideoRotation(0)
        try await runtime.execute(.removeVideoFilter(.deband))
        #expect(!runtime.effectiveVideoProcessing.isEnabled)
        await runtime.shutdown()
    }
}
