import CFFmpeg
import CoreMedia
import Foundation
import Testing
@testable import IlliquidNativePlayback

/// Real decoder ownership checks complement the exact production-loop harness,
/// which separately verifies the placement of the successful-EOF reset.
@Suite("Video recovery EOF native ownership", .serialized)
struct VideoRecoveryEOFLifetimeTests {
    @Test(arguments: [false, true])
    func successfulDrainAllowsRecoveryReleaseWithoutInvalidatingDecodedOutput(
        holdNativeClone: Bool
    ) throws {
        let decoder = try VideoScratchFrameFixture.makeDecoder(width: 32, height: 24, deinterlacing: false)
        let recovery = VideoRecoveryPacketBuffer()
        var tracked: (FFmpegPacket, VideoScratchAllocationProbe)? =
            try VideoScratchFrameFixture.makePacket(width: 32, height: 24, timestamp: 2_000, generation: 7)
        let probe = tracked!.1
        let expectedPacketBytes = try #require(tracked!.0.data)
        var clone: UnsafeMutablePointer<AVPacket>?
        defer {
            tracked = nil
            recovery.reset()
            av_packet_free(&clone)
        }
        recovery.record(tracked!.0)
        if holdNativeClone {
            clone = av_packet_clone(tracked!.0.pointer)
            _ = try #require(clone)
        }

        let outputs = try decoder.decode(tracked!.0)
        try #require(outputs.count == 1)
        let heldOutput = try #require(outputs.first)
        let pixelsBeforeRelease = try VideoScratchFrameFixture.pixelBytes(heldOutput)
        let presentationTime = heldOutput.presentationTime
        let duration = heldOutput.duration
        #expect(pixelsBeforeRelease.count == 32 * 24 * 4)
        #expect(presentationTime.seconds == 2)
        #expect(heldOutput.generation == 7)
        #expect(!heldOutput.isHardwareDecoded)

        // The counter does not retain the input. Only the recovery buffer and
        // optional native clone should still own its backing allocation.
        tracked = nil
        #expect(probe.releaseCount == 0)
        #expect(try decoder.drain(generation: 7).isEmpty)
        #expect(probe.releaseCount == 0)
        recovery.reset(generation: 7)
        #expect(probe.releaseCount == (holdNativeClone ? 0 : 1))
        #expect(try VideoScratchFrameFixture.pixelBytes(heldOutput) == pixelsBeforeRelease)
        #expect(heldOutput.presentationTime == presentationTime)
        #expect(heldOutput.duration == duration)

        if let retained = clone {
            #expect(retained.pointee.size == Int32(expectedPacketBytes.count))
            let bytes = try #require(retained.pointee.data)
            #expect(Data(bytes: bytes, count: Int(retained.pointee.size)) == expectedPacketBytes)
            #expect(retained.pointee.pts == 2_000)
            #expect(retained.pointee.dts == 2_000)
            av_packet_free(&clone)
        }
        #expect(probe.releaseCount == 1)
        recovery.reset(generation: 7)
        recovery.reset(generation: 7)
        #expect(probe.releaseCount == 1)
        decoder.flush()
        #expect(try VideoScratchFrameFixture.pixelBytes(heldOutput) == pixelsBeforeRelease)
        #expect(heldOutput.presentationTime == presentationTime)
        #expect(heldOutput.duration == duration)
        withExtendedLifetime(decoder) {}
    }

    @Test func cancelledNativeDrainLeavesTheRecordedPacketAvailableForReplay() throws {
        let decoder = try VideoScratchFrameFixture.makeDecoder(width: 32, height: 24, deinterlacing: false)
        let recovery = VideoRecoveryPacketBuffer()
        var tracked: (FFmpegPacket, VideoScratchAllocationProbe)? =
            try VideoScratchFrameFixture.makePacket(width: 32, height: 24, timestamp: 2_000, generation: 7)
        let probe = tracked!.1
        let expectedPacketBytes = try #require(tracked!.0.data)
        var replay: [FFmpegPacket]?
        defer {
            tracked = nil
            replay = nil
            recovery.reset()
        }
        recovery.record(tracked!.0)
        let outputs = try decoder.decode(tracked!.0)
        try #require(outputs.count == 1)
        let heldOutput = try #require(outputs.first)
        let pixelsBeforeDrain = try VideoScratchFrameFixture.pixelBytes(heldOutput)
        tracked = nil
        #expect(probe.releaseCount == 0)
        #expect(throws: SoftwarePixelBufferPoolError.cancelled) {
            try decoder.drain(generation: 7, while: { false }) { _ in
                Issue.record("A cancelled drain unexpectedly delivered a frame")
            }
        }
        #expect(probe.releaseCount == 0)
        replay = recovery.takeReplayPackets(generation: 7)
        #expect(replay?.count == 1)
        #expect(replay?.first?.isKeyframe == true)
        #expect(replay?.first?.generation == 7)
        #expect(replay?.first?.data == expectedPacketBytes)
        #expect(probe.releaseCount == 0)
        replay = nil
        #expect(probe.releaseCount == 1)
        recovery.reset(generation: 7)
        #expect(probe.releaseCount == 1)
        #expect(try VideoScratchFrameFixture.pixelBytes(heldOutput) == pixelsBeforeDrain)
        #expect(heldOutput.presentationTime.seconds == 2)
        withExtendedLifetime(decoder) {}
    }
}
