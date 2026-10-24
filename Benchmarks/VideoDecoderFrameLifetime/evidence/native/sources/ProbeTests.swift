import CFFmpeg
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import Testing
@testable import IlliquidNativePlayback

// This suite is copied into the native test target only by run.py. The strict
// regression tests remain unchanged and run against the candidate separately.
// Both variants use the same real rawvideo packet/decoder fixture from those
// tests. Its AVBuffer free callback observes a specific allocation, not RSS.
@Suite("Video decoder frame lifetime measurements", .serialized)
struct VideoDecoderFrameLifetimeProbeTests {
    private enum Scenario: String, CaseIterable {
        case normal = "normal"
        case cancelledBeforeDecode = "cancelled_before_decode"
        case cancelledAfterEmit = "cancelled_after_emit"
        case throwingFrameConsumer = "throwing_frame_consumer"
        case refusedOutputReservation = "refused_output_reservation"
        case throwingTimestampConsumer = "throwing_timestamp_consumer"
        case normalTimestamp = "normal_timestamp"
    }

    private enum ConsumerFailure: Error { case requested }

    private struct Snapshot: Codable, Equatable {
        let trackedLiveAllocationBytes: Int
        let trackedBufferFreeCallbacks: Int

        init(_ probe: VideoFrameLifetimeBufferProbe) {
            trackedLiveAllocationBytes = probe.liveBytes
            trackedBufferFreeCallbacks = probe.releaseCount
        }
    }

    private struct Attempt {
        let probe: VideoFrameLifetimeBufferProbe
        let frames: [NativeDecodedVideoFrame]
        let times: [CMTime]
        let error: String?
    }

    private struct FrameReceipt: Codable, Equatable {
        let pixelBytes: Int
        let pixelSHA256: String
        let metadata: [String: String]
    }

    private struct OutputReceipt: Codable, Equatable {
        let error: String?
        let frames: [FrameReceipt]
        let presentationTimes: [String]
    }

    private struct Receipt: Encodable {
        let schema = 1
        let scenario: String
        let width: Int
        let height: Int
        let inputPayloadBytes: Int
        let trackedAllocationBytes: Int
        let packetPaddingBytes: Int
        let idleMilliseconds: Int
        let ffmpegVersion: String
        let snapshots: [String: Snapshot]
        let output: OutputReceipt
        let recovery: OutputReceipt
        let recoveryAllocation: Snapshot
        let pixelsEqualExpectedAfterRecoveryAndDestruction: Bool
    }

    @Test func recordsActualNativeAllocationLifetimes() throws {
        let directory = try #require(
            ProcessInfo.processInfo.environment["ILLIQUID_VIDEO_FRAME_LIFETIME_EVIDENCE_DIR"],
            "The measurement runner must provide a fresh receipt directory"
        )
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for (width, height) in [(64, 48), (1_920, 1_080), (3_840, 2_160)] {
            for scenario in Scenario.allCases {
                let receipt = try autoreleasepool {
                    try observe(scenario, width: width, height: height)
                }
                let path = output.appendingPathComponent("\(scenario.rawValue)-\(width)x\(height).json")
                try #require(!FileManager.default.fileExists(atPath: path.path),
                             "Measurement receipts must not overwrite an earlier observation")
                try encoder.encode(receipt).write(to: path, options: .atomic)
            }
        }
    }

    // No packet, decoder, pixel buffer, or fixture allocation escapes this
    // method in its receipt. Samples precede pixel extraction, hashing and JSON.
    @inline(never)
    private func observe(_ scenario: Scenario, width: Int, height: Int) throws -> Receipt {
        let fixture = VideoFrameLifetimeFixture(width: width, height: height)
        var decoder: VideoDecoder? = try fixture.makeDecoder()
        weak var retiredDecoder = decoder
        let attempt = try decode(try #require(decoder), fixture: fixture, scenario: scenario)
        var snapshots = ["after_packet_release": Snapshot(attempt.probe)]
        // Neither another packet nor a flush can conceal an idle retained ref.
        Thread.sleep(forTimeInterval: 0.025)
        snapshots["after_idle"] = withExtendedLifetime((decoder, attempt.frames)) {
            Snapshot(attempt.probe)
        }
        decoder?.flush()
        snapshots["after_flush"] = Snapshot(attempt.probe)

        // A healthy subsequent packet must still decode, and must retire any
        // old scratch reference left behind by the unmodified implementation.
        let recovery = try decode(try #require(decoder), fixture: fixture,
                                  scenario: .normal, timestamp: 1, marker: 91)
        snapshots["after_recovery"] = Snapshot(attempt.probe)
        let recoveryAllocation = Snapshot(recovery.probe)
        decoder = nil
        try #require(retiredDecoder == nil, "The test must release its decoder")
        snapshots["after_decoder_destruction"] = Snapshot(attempt.probe)

        // Keep all caller-owned frames alive through flush, subsequent decode
        // and decoder destruction. Full pixel equality is checked before hashes.
        let output = try outputReceipt(attempt, fixture: fixture, marker: 17)
        let recoveredOutput = try outputReceipt(recovery, fixture: fixture, marker: 91)
        return Receipt(
            scenario: scenario.rawValue, width: width, height: height,
            inputPayloadBytes: fixture.payloadBytes,
            trackedAllocationBytes: fixture.allocatedBytes,
            packetPaddingBytes: Int(AV_INPUT_BUFFER_PADDING_SIZE),
            idleMilliseconds: 25,
            ffmpegVersion: String(cString: av_version_info()),
            snapshots: snapshots, output: output, recovery: recoveredOutput,
            recoveryAllocation: recoveryAllocation,
            pixelsEqualExpectedAfterRecoveryAndDestruction: true
        )
    }

    // This boundary drops the sole caller-owned FFmpegPacket before any sample.
    // Only copied presentation output and the allocation's free-callback probe
    // escape; neither retains the packet or its native AVBufferRef.
    @inline(never)
    private func decode(
        _ decoder: VideoDecoder, fixture: VideoFrameLifetimeFixture,
        scenario: Scenario, timestamp: Int64 = 0, marker: UInt8 = 17
    ) throws -> Attempt {
        let (packet, probe) = try fixture.makePacket(at: timestamp, marker: marker)
        var frames: [NativeDecodedVideoFrame] = []
        var times: [CMTime] = []
        var error: String?
        var continueDecoding = true
        do {
            switch scenario {
            case .normal:
                try decoder.decode(packet, while: { true }) { frames.append($0) }
            case .cancelledBeforeDecode:
                try decoder.decode(packet, while: { false }) { frames.append($0) }
            case .cancelledAfterEmit:
                try decoder.decode(packet, while: { continueDecoding }) {
                    frames.append($0)
                    continueDecoding = false
                }
            case .throwingFrameConsumer:
                try decoder.decode(packet, while: { true }) {
                    frames.append($0)
                    throw ConsumerFailure.requested
                }
            case .refusedOutputReservation:
                try decoder.decode(packet, while: { true }, reserveSoftwareOutput: { nil }) {
                    frames.append($0)
                }
            case .throwingTimestampConsumer:
                try decoder.decodePresentationTimes(packet, while: { true }) {
                    times.append($0)
                    throw ConsumerFailure.requested
                }
            case .normalTimestamp:
                try decoder.decodePresentationTimes(packet, while: { true }) { times.append($0) }
            }
        } catch SoftwarePixelBufferPoolError.cancelled {
            error = "cancelled"
        } catch ConsumerFailure.requested {
            error = "consumer"
        }
        let expectedError: String? = switch scenario {
        case .normal, .normalTimestamp: nil
        case .cancelledBeforeDecode, .cancelledAfterEmit, .refusedOutputReservation: "cancelled"
        case .throwingFrameConsumer, .throwingTimestampConsumer: "consumer"
        }
        let expectedFrames: Int = switch scenario {
        case .normal, .cancelledAfterEmit, .throwingFrameConsumer: 1
        default: 0
        }
        let expectedTimes = scenario == .throwingTimestampConsumer || scenario == .normalTimestamp ? 1 : 0
        try #require(error == expectedError)
        try #require(frames.count == expectedFrames)
        try #require(times.count == expectedTimes)
        return Attempt(probe: probe, frames: frames, times: times, error: error)
    }

    private func outputReceipt(
        _ attempt: Attempt, fixture: VideoFrameLifetimeFixture, marker: UInt8
    ) throws -> OutputReceipt {
        let frames = try attempt.frames.map { frame in
            let pixels = try fixture.pixels(of: frame)
            try #require(pixels == fixture.expectedPixels(marker: marker),
                         "Caller-owned pixels changed after native scratch teardown")
            return FrameReceipt(pixelBytes: pixels.count, pixelSHA256: hash(pixels), metadata: [
                "pixelBufferFormat": String(CVPixelBufferGetPixelFormatType(frame.pixelBuffer)),
                "pixelBufferWidth": String(CVPixelBufferGetWidth(frame.pixelBuffer)),
                "pixelBufferHeight": String(CVPixelBufferGetHeight(frame.pixelBuffer)),
                "hasPlanarOwnershipToken": String(frame.planarOwnershipToken != nil),
                "hasPipelineCapacityPermit": String(frame.pipelineCapacityPermit != nil),
                "presentationTime": time(frame.presentationTime),
                "duration": time(frame.duration), "generation": String(frame.generation),
                "codedSize": size(frame.codedSize), "displaySize": size(frame.displaySize),
                "pixelAspectRatio": size(frame.pixelAspectRatio),
                "rotationDegreesBits": bits(frame.rotationDegrees),
                "isHorizontallyMirrored": String(frame.isHorizontallyMirrored),
                "colorPrimaries": optional(frame.colorPrimaries),
                "transferCharacteristic": optional(frame.transferCharacteristic),
                "matrixCoefficients": optional(frame.matrixCoefficients),
                "isFullRange": String(frame.isFullRange),
                "hasMasteringDisplayMetadata": String(frame.hasMasteringDisplayMetadata),
                "hasContentLightMetadata": String(frame.hasContentLightMetadata),
                "sourceComponentDepth": String(frame.sourceComponentDepth),
                "ffmpegPixelFormat": frame.ffmpegPixelFormat,
                "isHardwareDecoded": String(frame.isHardwareDecoded),
                "isCopiedHardwarePath": String(frame.isCopiedHardwarePath),
                "isNearZeroCopy": String(frame.isNearZeroCopy),
                "chromaLocation": optional(frame.chromaLocation),
                "cleanAperture": frame.cleanAperture.map {
                    [bits(Double($0.origin.x)), bits(Double($0.origin.y)), size($0.size)].joined(separator: ",")
                } ?? "nil",
                "masteringDisplayMetadataSHA256": frame.masteringDisplayMetadata.map(hash) ?? "nil",
                "contentLightMetadataSHA256": frame.contentLightMetadata.map(hash) ?? "nil",
                "beginsTimelineDiscontinuity": String(frame.beginsTimelineDiscontinuity),
                "usesDeinterlacingFilter": String(frame.usesDeinterlacingFilter),
                "deinterlacingFailure": frame.deinterlacingFailure ?? "nil",
            ])
        }
        return OutputReceipt(error: attempt.error, frames: frames, presentationTimes: attempt.times.map(time))
    }

    private func bits(_ value: Double) -> String { String(value.bitPattern, radix: 16) }
    private func size(_ value: CGSize) -> String {
        bits(Double(value.width)) + "," + bits(Double(value.height))
    }
    private func time(_ value: CMTime) -> String {
        "\(value.value),\(value.timescale),\(value.flags.rawValue),\(value.epoch)"
    }
    private func optional<T>(_ value: T?) -> String { value.map { String(describing: $0) } ?? "nil" }
    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
