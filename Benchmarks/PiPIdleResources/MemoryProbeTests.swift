import AppKit
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import IlliquidNativePlayback

/// Staged into the ordinary native test target only by run.py. Both variants
/// execute the complete production compositor and the same observation code.
@Suite("PiP idle resource native measurement", .serialized)
struct PiPIdleResourcesMemoryProbeTests {
    private struct OutputDigest: Codable, Equatable, Sendable {
        let checksum: String
        let activeBytes: Int
        let width: Int
        let height: Int
        let pixelFormat: UInt32
        let transfer: String?
        let primaries: String?
        let matrix: String?
    }

    private struct Stage: Codable, Sendable {
        let resources: PiPSubtitleResourceSnapshot
        let budgetStagingBytes: Int
    }

    private struct Measurement: Codable, Sendable {
        let variant: String
        let workload: String
        let constructed: Stage
        let composed: Stage
        let stopped: Stage
        let stoppedAfterSettling: Stage
        let reentered: Stage
        let stoppedAgain: Stage
        let firstOutput: OutputDigest
        let reenteredOutput: OutputDigest
        let firstSampleNanoseconds: UInt64
        let reentryFirstSampleNanoseconds: UInt64
    }

    private struct ProbeError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private final class StartOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: (Result<Void, Error>, UInt64)?

        func finish(_ result: Result<Void, Error>) {
            lock.withLock {
                if outcome == nil {
                    outcome = (result, DispatchTime.now().uptimeNanoseconds)
                }
            }
        }

        func completionTime() throws -> UInt64? {
            try lock.withLock {
                guard let outcome else { return nil }
                try outcome.0.get()
                return outcome.1
            }
        }
    }

    @Test @MainActor
    func measureProductionLifecycle() async throws {
        let environment = ProcessInfo.processInfo.environment
        let variant = try #require(environment["ILLIQUID_PIP_IDLE_VARIANT"])
        let workload = try #require(environment["ILLIQUID_PIP_IDLE_WORKLOAD"])
        let report = try #require(environment["ILLIQUID_PIP_IDLE_REPORT"])
        #expect(variant == "baseline" || variant == "candidate")
        #expect(workload == "sdr-1080p" || workload == "hdr-pq-4k")
        let hdr = workload == "hdr-pq-4k"
        let size = hdr ? CGSize(width: 3840, height: 2160)
            : CGSize(width: 1920, height: 1080)
        let budget = SubtitleMemoryBudget()
        let pipeline = try SubtitlePipeline(
            overlay: SubtitleOverlayView(headless: true), presentsOverlay: false
        )
        defer { pipeline.terminate() }
        _ = try pipeline.configure(
            codecPrivate: nil, codecName: "hdmv_pgs_subtitle", attachments: [],
            frameSize: size, storageSize: size
        )
        let caption = bitmapCaption(canvas: size)
        pipeline.process(event: .init(
            assData: Data(), presentationSeconds: 0, durationSeconds: 10,
            generation: 0, bitmapComposition: caption
        ))
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline, memoryBudget: budget)
        defer { compositor.stop() }
        let source = try sourcePixelBuffer(size: size, hdr: hdr)
        let frame = decodedFrame(source, size: size, hdr: hdr)
        compositor.receive(frame)
        let constructed = await stage(compositor, budget: budget)

        let firstLatency = try await startAndWait(compositor)
        // This companion readback uses the same completed frame and production
        // compose method. The production worker is idle before this test seam.
        let firstOutput = try await outputDigest(compositor, frame: frame)
        let composed = await stage(compositor, budget: budget)
        try requirePopulated(composed, hdr: hdr)
        #expect(compositor.metricsSnapshot().subtitleVisibleFrames > 0)

        compositor.stop()
        let stopped = try await stoppedStage(compositor, budget: budget)
        // Metal/CoreVideo may release backing allocations asynchronously. This
        // secondary device reading is diagnostic, never the pass criterion.
        try await Task.sleep(for: .milliseconds(150))
        let settled = await stage(compositor, budget: budget)
        try requireStopped(stopped, variant: variant, hdr: hdr)

        // receive() is deliberately not called again: start must preserve and
        // reconstruct the same cached paused source frame after retirement.
        let reentryLatency = try await startAndWait(compositor)
        let reenteredOutput = try await outputDigest(compositor, frame: frame)
        let reentered = await stage(compositor, budget: budget)
        try requirePopulated(reentered, hdr: hdr)
        #expect(compositor.metricsSnapshot().immediatelyDisplayedFrames == 1)
        #expect(compositor.metricsSnapshot().subtitleVisibleFrames > 0)
        #expect(firstOutput == reenteredOutput)

        compositor.stop()
        let stoppedAgain = try await stoppedStage(compositor, budget: budget)
        try requireStopped(stoppedAgain, variant: variant, hdr: hdr)
        let measurement = Measurement(
            variant: variant, workload: workload, constructed: constructed,
            composed: composed, stopped: stopped, stoppedAfterSettling: settled,
            reentered: reentered, stoppedAgain: stoppedAgain,
            firstOutput: firstOutput, reenteredOutput: reenteredOutput,
            firstSampleNanoseconds: firstLatency,
            reentryFirstSampleNanoseconds: reentryLatency
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(measurement).write(to: URL(fileURLWithPath: report), options: .atomic)
    }

    @MainActor
    private func startAndWait(_ compositor: PiPSubtitleCompositor) async throws -> UInt64 {
        let outcome = StartOutcome()
        let started = DispatchTime.now().uptimeNanoseconds
        compositor.start(onFirstSample: { outcome.finish($0) },
                         onFailure: { outcome.finish(.failure($0)) })
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let completed = try outcome.completionTime() {
                let snapshot = await compositor.resourceSnapshotForTesting()
                if !snapshot.workerActive { return completed - started }
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ProbeError("PiP first sample or worker drainage did not finish")
    }

    private func stage(_ compositor: PiPSubtitleCompositor,
                       budget: SubtitleMemoryBudget) async -> Stage {
        Stage(resources: await compositor.resourceSnapshotForTesting(),
              budgetStagingBytes: budget.snapshot.reservationsByOwner[.pictureInPictureStaging] ?? 0)
    }

    private func stoppedStage(_ compositor: PiPSubtitleCompositor,
                              budget: SubtitleMemoryBudget) async throws -> Stage {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let result = await stage(compositor, budget: budget)
            if !result.resources.isActive && !result.resources.workerActive { return result }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ProbeError("Stopped PiP worker did not drain")
    }

    private func requirePopulated(_ stage: Stage, hdr: Bool) throws {
        let resources = stage.resources
        try #require(resources.hasOutputPool && resources.hasOutputPoolObserver)
        try #require(resources.outputBufferIdentityCount > 0)
        try #require(resources.subtitleTextureAllocatedBytes > 0)
        try #require(resources.subtitleVertexAllocatedBytes > 0)
        try #require(resources.stagingBytes > 0 && resources.preparedPixelBytes > 0)
        try #require(stage.budgetStagingBytes == resources.stagingBytes)
        try #require(hdr ? resources.hdrTextureAllocatedBytes > 0
                     : resources.hdrTextureAllocatedBytes == 0)
    }

    private func requireStopped(_ stage: Stage, variant: String, hdr: Bool) throws {
        try #require(!stage.resources.isActive && !stage.resources.workerActive)
        if variant == "baseline" {
            try requirePopulated(stage, hdr: hdr)
            return
        }
        let resources = stage.resources
        try #require(!resources.hasOutputPool && !resources.hasOutputPoolObserver)
        try #require(resources.outputBufferIdentityCount == 0)
        try #require(resources.hdrTextureAllocatedBytes == 0)
        try #require(resources.subtitleTextureAllocatedBytes == 0)
        try #require(resources.subtitleVertexAllocatedBytes == 0)
        try #require(resources.stagingBytes == 0 && resources.preparedPixelBytes == 0)
        try #require(stage.budgetStagingBytes == 0)
    }

    private func bitmapCaption(canvas: CGSize) -> NativeBitmapSubtitleComposition {
        let width = 1024
        let height = 256
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let pixels = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    pixels[offset] = UInt8(32 + x % 128)
                    pixels[offset + 1] = UInt8(32 + y % 128)
                    pixels[offset + 2] = 192
                    pixels[offset + 3] = 255
                }
            }
        }
        return NativeBitmapSubtitleComposition(
            regions: [.init(pixels: bytes,
                            frame: CGRect(x: 64, y: 64, width: width, height: height),
                            isForced: false)],
            canvasSize: canvas, duration: 10, memoryLease: nil
        )
    }

    private func sourcePixelBuffer(size: CGSize, hdr: Bool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let format = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_32BGRA
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                                        format, attributes as CFDictionary, &buffer) == kCVReturnSuccess)
        let result = try #require(buffer)
        try #require(CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        if hdr {
            for plane in 0..<2 {
                let base = try #require(CVPixelBufferGetBaseAddressOfPlane(result, plane))
                    .assumingMemoryBound(to: UInt16.self)
                let wordsPerRow = CVPixelBufferGetBytesPerRowOfPlane(result, plane) / 2
                let code: UInt16 = plane == 0 ? 64 : 512
                for y in 0..<CVPixelBufferGetHeightOfPlane(result, plane) {
                    for x in 0..<Int(size.width) { base[y * wordsPerRow + x] = code << 6 }
                }
            }
        } else {
            let base = try #require(CVPixelBufferGetBaseAddress(result)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(result)
            for y in 0..<Int(size.height) {
                for x in 0..<Int(size.width) {
                    let offset = y * stride + x * 4
                    base[offset] = 0
                    base[offset + 1] = 0
                    base[offset + 2] = 0
                    base[offset + 3] = 255
                }
            }
        }
        return result
    }

    private func decodedFrame(_ source: CVPixelBuffer, size: CGSize,
                              hdr: Bool) -> NativeDecodedVideoFrame {
        NativeDecodedVideoFrame(
            pixelBuffer: source, planarOwnershipToken: nil,
            presentationTime: CMTime(seconds: 0.5, preferredTimescale: 1000),
            duration: CMTime(value: 1, timescale: 30), generation: 0,
            codedSize: size, displaySize: size, pixelAspectRatio: CGSize(width: 1, height: 1),
            rotationDegrees: 0, colorPrimaries: hdr ? 9 : nil,
            transferCharacteristic: hdr ? 16 : nil, matrixCoefficients: hdr ? 9 : nil,
            isFullRange: !hdr, hasMasteringDisplayMetadata: false,
            hasContentLightMetadata: false, sourceComponentDepth: hdr ? 10 : 8,
            ffmpegPixelFormat: hdr ? "p010le" : "bgra", isHardwareDecoded: false,
            isCopiedHardwarePath: false, isNearZeroCopy: false
        )
    }

    private func outputDigest(_ compositor: PiPSubtitleCompositor,
                              frame: NativeDecodedVideoFrame) async throws -> OutputDigest {
        let output = try await compositor.composedPixelBufferForTesting(frame)
        // The output is confined to this helper, so the caller retains only the
        // digest when stop() measures compositor-owned allocations.
        try #require(CVPixelBufferLockBaseAddress(output, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let planar = CVPixelBufferIsPlanar(output)
        let planes = planar ? CVPixelBufferGetPlaneCount(output) : 1
        var checksum: UInt64 = 14695981039346656037
        var activeBytes = 0
        for plane in 0..<planes {
            let width = planar ? CVPixelBufferGetWidthOfPlane(output, plane) : CVPixelBufferGetWidth(output)
            let height = planar ? CVPixelBufferGetHeightOfPlane(output, plane) : CVPixelBufferGetHeight(output)
            let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(output, plane) : CVPixelBufferGetBytesPerRow(output)
            let base = try #require(planar ? CVPixelBufferGetBaseAddressOfPlane(output, plane)
                                   : CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt8.self)
            let rowBytes = width * (planar && plane == 0 ? 2 : 4)
            try #require(rowBytes <= stride)
            for y in 0..<height {
                for x in 0..<rowBytes {
                    checksum = (checksum ^ UInt64(base[y * stride + x])) &* 1099511628211
                }
            }
            activeBytes += rowBytes * height
        }
        return OutputDigest(
            checksum: String(checksum, radix: 16), activeBytes: activeBytes,
            width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output),
            pixelFormat: CVPixelBufferGetPixelFormatType(output),
            transfer: CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String,
            primaries: CVBufferCopyAttachment(output, kCVImageBufferColorPrimariesKey, nil) as? String,
            matrix: CVBufferCopyAttachment(output, kCVImageBufferYCbCrMatrixKey, nil) as? String
        )
    }
}
