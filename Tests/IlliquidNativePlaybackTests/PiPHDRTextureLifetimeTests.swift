import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import Metal
import Testing
@testable import IlliquidNativePlayback

/// Observes the native object weakly: keeping a receipt must not keep its bytes.
final class PiPHDRTextureProbe {
    private(set) weak var texture: AnyObject?
    private(set) var identity: ObjectIdentifier?
    private(set) var allocatedBytes = 0
    private(set) var width = 0
    private(set) var height = 0
    private(set) var active = false
    private(set) var workerActive = false

    init(_ compositor: PiPSubtitleCompositor) {
        compositor.inspectHDRTextureForTesting { active, workerActive, texture in
            self.active = active
            self.workerActive = workerActive
            self.texture = texture
            self.identity = texture.map(ObjectIdentifier.init)
            self.allocatedBytes = texture?.allocatedSize ?? 0
            self.width = texture?.width ?? 0
            self.height = texture?.height ?? 0
        }
    }

    var isAlive: Bool { texture != nil }
}

/// Holds the external Metal callback, leaving the compositor queue free to stop.
/// This controls delivery after GPU completion, not execution on the GPU itself.
private final class PiPHDRCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var arrived = false
    private var expired = false

    var hasArrived: Bool { lock.withLock { arrived } }
    var timedOut: Bool { lock.withLock { expired } }

    func hold() {
        lock.withLock { arrived = true }
        if release.wait(timeout: .now() + 10) != .success {
            lock.withLock { expired = true }
        }
    }

    func resume() { release.signal() }
}

private final class PiPHDRCallbackCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var firstSamples = 0
    private var failures = 0

    func recordFirstSample() { lock.withLock { firstSamples += 1 } }
    func recordFailure() { lock.withLock { failures += 1 } }
    var snapshot: (firstSamples: Int, failures: Int) {
        lock.withLock { (firstSamples, failures) }
    }
}

enum PiPHDRTextureFixture {
    struct OutputSignature: Codable, Equatable {
        let width: Int
        let height: Int
        let pixelFormat: UInt32
        let sha256: String
        let transferFunction: String?
        let primaries: String?
        let matrix: String?
    }

    static func frame(
        width: Int = 64, height: Int = 32, transfer: Int32 = 16
    ) throws -> NativeDecodedVideoFrame {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            attributes as CFDictionary, &created
        )
        try #require(status == kCVReturnSuccess)
        let pixels = try #require(created)
        try #require(CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess)
        for plane in 0..<2 {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, plane))
                .assumingMemoryBound(to: UInt16.self)
            let rowStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) / 2
            let rowWords = CVPixelBufferGetWidthOfPlane(pixels, plane) * (plane == 0 ? 1 : 2)
            for y in 0..<CVPixelBufferGetHeightOfPlane(pixels, plane) {
                for x in 0..<rowWords {
                    base[y * rowStride + x] = UInt16(plane == 0 ? 500 : 512) << 6
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let size = CGSize(width: width, height: height)
        return NativeDecodedVideoFrame(
            pixelBuffer: pixels, planarOwnershipToken: nil,
            presentationTime: .zero, duration: CMTime(value: 1, timescale: 30),
            generation: 0, codedSize: size, displaySize: size,
            pixelAspectRatio: CGSize(width: 1, height: 1), rotationDegrees: 0,
            colorPrimaries: 9, transferCharacteristic: transfer,
            matrixCoefficients: 9, isFullRange: false,
            hasMasteringDisplayMetadata: false, hasContentLightMetadata: false,
            sourceComponentDepth: 10, ffmpegPixelFormat: "p010le",
            isHardwareDecoded: false, isCopiedHardwarePath: false, isNearZeroCopy: false
        )
    }

    static func signature(_ pixels: CVPixelBuffer) throws -> OutputSignature {
        try #require(CVPixelBufferGetPixelFormatType(pixels)
            == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        try #require(CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        var hash = SHA256()
        for plane in 0..<2 {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, plane))
            let rowStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane)
            let rowBytes = CVPixelBufferGetWidthOfPlane(pixels, plane) * (plane == 0 ? 2 : 4)
            for y in 0..<CVPixelBufferGetHeightOfPlane(pixels, plane) {
                hash.update(data: Data(bytes: base.advanced(by: y * rowStride), count: rowBytes))
            }
            let first = base.assumingMemoryBound(to: UInt16.self).pointee
            #expect(first & 63 == 0)
            #expect(abs(Int(first >> 6) - (plane == 0 ? 500 : 512)) <= 2)
        }
        return OutputSignature(
            width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
            pixelFormat: CVPixelBufferGetPixelFormatType(pixels),
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
            transferFunction: CVBufferCopyAttachment(pixels, kCVImageBufferTransferFunctionKey, nil) as? String,
            primaries: CVBufferCopyAttachment(pixels, kCVImageBufferColorPrimariesKey, nil) as? String,
            matrix: CVBufferCopyAttachment(pixels, kCVImageBufferYCbCrMatrixKey, nil) as? String
        )
    }

    @MainActor
    static func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    @MainActor
    static func waitForIdleFrame(_ compositor: PiPSubtitleCompositor, count: Int = 1) async throws {
        try #require(await waitUntil {
            !PiPHDRTextureProbe(compositor).workerActive
                && compositor.metricsSnapshot().composedFrames == count
        })
        #expect(compositor.metricsSnapshot().enqueueFailures == 0)
    }

    @MainActor
    static func waitForRetirement(_ compositor: PiPSubtitleCompositor, probe: PiPHDRTextureProbe) async throws {
        try #require(await waitUntil {
            let state = PiPHDRTextureProbe(compositor)
            return !state.active && !state.workerActive
                && state.allocatedBytes == 0 && !probe.isAlive
        })
        withExtendedLifetime(compositor) {}
    }
}

@Suite("PiP HDR working-texture lifetime", .serialized)
@MainActor
struct PiPHDRTextureLifetimeTests {
    @Test(arguments: [Int32(16), 18])
    func idleStopReleasesTextureAndPausedReentryPreservesPixels(transfer: Int32) async throws {
        let compositor = try PiPSubtitleCompositor()
        defer { compositor.stop() }
        let frame = try PiPHDRTextureFixture.frame(transfer: transfer)
        let heldOutput = try await compositor.composedPixelBufferForTesting(frame)
        let expected = try PiPHDRTextureFixture.signature(heldOutput)
        let original = autoreleasepool { PiPHDRTextureProbe(compositor) }
        try #require(original.allocatedBytes > 0)
        compositor.receive(frame)
        compositor.start(onFirstSample: { _ in }, onFailure: { _ in })
        try await PiPHDRTextureFixture.waitForIdleFrame(compositor)
        compositor.receive(frame)
        try await PiPHDRTextureFixture.waitForIdleFrame(compositor, count: 2)
        #expect(PiPHDRTextureProbe(compositor).identity == original.identity)
        #expect(original.isAlive)

        compositor.stop()
        try await PiPHDRTextureFixture.waitForRetirement(compositor, probe: original)
        #expect(try PiPHDRTextureFixture.signature(heldOutput) == expected)

        // No new receive: start must use the retained paused frame.
        compositor.start(onFirstSample: { _ in }, onFailure: { _ in })
        try await PiPHDRTextureFixture.waitForIdleFrame(compositor)
        #expect(compositor.metricsSnapshot().immediatelyDisplayedFrames == 1)
        let replacement = autoreleasepool { PiPHDRTextureProbe(compositor) }
        #expect(replacement.allocatedBytes == original.allocatedBytes)
        let reentered = try await compositor.composedPixelBufferForTesting(frame)
        #expect(try PiPHDRTextureFixture.signature(reentered) == expected)
        compositor.stop()
        try await PiPHDRTextureFixture.waitForRetirement(compositor, probe: replacement)
        #expect(try PiPHDRTextureFixture.signature(heldOutput) == expected)
        #expect(try PiPHDRTextureFixture.signature(reentered) == expected)
    }

    @Test(arguments: [Int32(16), 18])
    func stopKeepsTextureUntilOutstandingCompletionReturns(transfer: Int32) async throws {
        let compositor = try PiPSubtitleCompositor()
        defer { compositor.stop() }
        let frame = try PiPHDRTextureFixture.frame(transfer: transfer)
        let heldOutput = try await compositor.composedPixelBufferForTesting(frame)
        let expected = try PiPHDRTextureFixture.signature(heldOutput)
        let original = autoreleasepool { PiPHDRTextureProbe(compositor) }
        let gate = PiPHDRCompletionGate()
        let callbacks = PiPHDRCallbackCounts()
        defer { gate.resume() }
        compositor.setNextCompositionCompletionHookForTesting { gate.hold() }
        compositor.receive(frame)
        compositor.start(onFirstSample: { _ in callbacks.recordFirstSample() },
                         onFailure: { _ in callbacks.recordFailure() })
        try #require(await PiPHDRTextureFixture.waitUntil { gate.hasArrived })

        compositor.stop()
        // Inspection runs behind queued stop cleanup, while the callback is held.
        let stopped = PiPHDRTextureProbe(compositor)
        #expect(!stopped.active && stopped.workerActive)
        #expect(stopped.identity == original.identity)
        #expect(original.isAlive)

        gate.resume()
        try await PiPHDRTextureFixture.waitForRetirement(compositor, probe: original)
        #expect(compositor.metricsSnapshot().discardedStaleCompositions == 1)
        #expect(compositor.metricsSnapshot().composedFrames == 0)
        #expect(callbacks.snapshot.firstSamples == 0)
        #expect(callbacks.snapshot.failures == 0)
        #expect(!gate.timedOut)
        #expect(try PiPHDRTextureFixture.signature(heldOutput) == expected)
    }

    @Test(arguments: [Int32(16), 18])
    func restartBeforeOldCompletionPreservesActiveReuse(transfer: Int32) async throws {
        let compositor = try PiPSubtitleCompositor()
        defer { compositor.stop() }
        let frame = try PiPHDRTextureFixture.frame(transfer: transfer)
        let heldOutput = try await compositor.composedPixelBufferForTesting(frame)
        let expected = try PiPHDRTextureFixture.signature(heldOutput)
        let original = autoreleasepool { PiPHDRTextureProbe(compositor) }
        let gate = PiPHDRCompletionGate()
        let callbacks = PiPHDRCallbackCounts()
        defer { gate.resume() }
        compositor.setNextCompositionCompletionHookForTesting { gate.hold() }
        compositor.receive(frame)
        compositor.start(onFirstSample: { _ in callbacks.recordFirstSample() },
                         onFailure: { _ in callbacks.recordFailure() })
        try #require(await PiPHDRTextureFixture.waitUntil { gate.hasArrived })
        compositor.stop()
        compositor.start(onFirstSample: { _ in callbacks.recordFirstSample() },
                         onFailure: { _ in callbacks.recordFailure() })
        #expect(PiPHDRTextureProbe(compositor).identity == original.identity)
        gate.resume()

        try await PiPHDRTextureFixture.waitForIdleFrame(compositor)
        #expect(compositor.metricsSnapshot().discardedStaleCompositions == 1)
        #expect(compositor.metricsSnapshot().immediatelyDisplayedFrames == 1)
        #expect(PiPHDRTextureProbe(compositor).identity == original.identity)
        #expect(original.isAlive)
        #expect(callbacks.snapshot.firstSamples == 1)
        #expect(callbacks.snapshot.failures == 0)
        #expect(!gate.timedOut)
        compositor.stop()
        try await PiPHDRTextureFixture.waitForRetirement(compositor, probe: original)
        #expect(try PiPHDRTextureFixture.signature(heldOutput) == expected)
    }

    @Test
    func poolBackpressureDoesNotPreventStopRetirement() async throws {
        let compositor = try PiPSubtitleCompositor()
        defer { compositor.stop() }
        let frame = try PiPHDRTextureFixture.frame()
        var heldOutputs: [CVPixelBuffer] = []
        for _ in 0..<12 {
            heldOutputs.append(try await compositor.composedPixelBufferForTesting(frame))
        }
        let expected = try PiPHDRTextureFixture.signature(heldOutputs[0])
        let original = autoreleasepool { PiPHDRTextureProbe(compositor) }
        compositor.receive(frame)
        compositor.start(onFirstSample: { _ in }, onFailure: { _ in })
        try #require(await PiPHDRTextureFixture.waitUntil {
            compositor.metricsSnapshot().outputPoolMisses == 1
                && !PiPHDRTextureProbe(compositor).workerActive
        })
        compositor.stop()
        try await PiPHDRTextureFixture.waitForRetirement(compositor, probe: original)
        for output in heldOutputs {
            #expect(try PiPHDRTextureFixture.signature(output) == expected)
        }
    }

    @Test
    func sdrControlDoesNotAllocateHDRWorkingTexture() async throws {
        let compositor = try PiPSubtitleCompositor()
        defer { compositor.stop() }
        let frame = try PiPHDRTextureFixture.frame(transfer: 1)
        compositor.receive(frame)
        compositor.start(onFirstSample: { _ in }, onFailure: { _ in })
        try await PiPHDRTextureFixture.waitForIdleFrame(compositor)
        let state = PiPHDRTextureProbe(compositor)
        #expect(state.identity == nil)
        #expect(state.allocatedBytes == 0)
        compositor.stop()
        try await PiPHDRTextureFixture.waitForRetirement(compositor, probe: state)
    }
}
