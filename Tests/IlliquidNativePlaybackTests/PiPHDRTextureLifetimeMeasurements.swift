import CoreVideo
import Foundation
import Metal
import Testing
@testable import IlliquidNativePlayback

/// Identical native experiment for the pinned baseline and candidate. The runner
/// checks their ownership difference; this suite never assumes which is loaded.
@Suite("PiP HDR working-texture measurements", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_PIP_HDR_MEASURE"] == "1"))
@MainActor
struct PiPHDRTextureLifetimeMeasurements {
    private struct Workload: Decodable {
        let name: String
        let width: Int
        let height: Int
        let transfer: Int32
    }

    private struct Observation: Encodable {
        let workload: String
        let width: Int
        let height: Int
        let transfer: Int32
        let metalDevice: String
        let logicalTextureBytes: Int
        let allocatedTextureBytes: Int
        let activeResourceReused: Bool
        let retainedAllocatedBytesAfterStop: Int
        let textureAliveAfterStop: Bool
        let compositorOwnsTextureAfterStop: Bool
        let reentryAllocatedTextureBytes: Int
        let reentryImmediatelyDisplayedFrames: Int
        let retainedAllocatedBytesAfterFinalStop: Int
        let outputBeforeStop: PiPHDRTextureFixture.OutputSignature
        let outputAfterStop: PiPHDRTextureFixture.OutputSignature
        let outputAfterReentry: PiPHDRTextureFixture.OutputSignature
    }

    @Test
    func recordNativeLifetime() async throws {
        let specification = try #require(
            ProcessInfo.processInfo.environment["ILLIQUID_PIP_HDR_WORKLOAD"]
        )
        let workload = try JSONDecoder().decode(Workload.self, from: Data(specification.utf8))
        try #require((2...3_840).contains(workload.width) && workload.width % 2 == 0)
        try #require((2...2_160).contains(workload.height) && workload.height % 2 == 0)
        try #require([Int32(16), 18].contains(workload.transfer))
        let compositor = try PiPSubtitleCompositor()
        defer { compositor.stop() }
        let frame = try PiPHDRTextureFixture.frame(
            width: workload.width, height: workload.height, transfer: workload.transfer
        )
        let heldOutput = try await compositor.composedPixelBufferForTesting(frame)
        let before = try PiPHDRTextureFixture.signature(heldOutput)
        let original = autoreleasepool { PiPHDRTextureProbe(compositor) }
        try #require(original.allocatedBytes > 0)
        try #require(original.width == workload.width && original.height == workload.height)

        compositor.receive(frame)
        compositor.start(onFirstSample: { _ in }, onFailure: { _ in })
        try await PiPHDRTextureFixture.waitForIdleFrame(compositor)
        let activeResourceReused = PiPHDRTextureProbe(compositor).identity == original.identity
            && original.isAlive
        compositor.stop()
        let stopped = autoreleasepool { PiPHDRTextureProbe(compositor) }
        try #require(!stopped.active && !stopped.workerActive)
        if stopped.identity == nil {
            try #require(await PiPHDRTextureFixture.waitUntil { !original.isAlive })
        }
        let aliveAfterStop = original.isAlive
        let after = try PiPHDRTextureFixture.signature(heldOutput)

        compositor.start(onFirstSample: { _ in }, onFailure: { _ in })
        try await PiPHDRTextureFixture.waitForIdleFrame(compositor)
        let reentry = autoreleasepool { PiPHDRTextureProbe(compositor) }
        let immediateFrames = compositor.metricsSnapshot().immediatelyDisplayedFrames
        let reenteredOutput = try await compositor.composedPixelBufferForTesting(frame)
        let reentered = try PiPHDRTextureFixture.signature(reenteredOutput)
        compositor.stop()
        let finalState = autoreleasepool { PiPHDRTextureProbe(compositor) }
        try #require(!finalState.active && !finalState.workerActive)
        if finalState.identity == nil {
            try #require(await PiPHDRTextureFixture.waitUntil { !reentry.isAlive })
        }
        #expect(try PiPHDRTextureFixture.signature(heldOutput) == before)
        #expect(try PiPHDRTextureFixture.signature(reenteredOutput) == before)

        let observation = Observation(
            workload: workload.name, width: workload.width, height: workload.height,
            transfer: workload.transfer,
            metalDevice: try #require(MTLCreateSystemDefaultDevice()).name,
            logicalTextureBytes: workload.width * workload.height * 8,
            allocatedTextureBytes: original.allocatedBytes,
            activeResourceReused: activeResourceReused,
            retainedAllocatedBytesAfterStop: stopped.allocatedBytes,
            textureAliveAfterStop: aliveAfterStop,
            compositorOwnsTextureAfterStop: stopped.identity != nil,
            reentryAllocatedTextureBytes: reentry.allocatedBytes,
            reentryImmediatelyDisplayedFrames: immediateFrames,
            retainedAllocatedBytesAfterFinalStop: finalState.allocatedBytes,
            outputBeforeStop: before, outputAfterStop: after, outputAfterReentry: reentered
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print("PIP_HDR_LIFETIME_MEASUREMENT "
            + String(decoding: try encoder.encode(observation), as: UTF8.self))
        withExtendedLifetime((compositor, heldOutput, reenteredOutput)) {}
    }
}
