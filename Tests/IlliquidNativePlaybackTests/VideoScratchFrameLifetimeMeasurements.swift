import CFFmpeg
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import IlliquidNativePlayback

/// Opt-in, real-decoder observations. The runner compiles this identical file
/// against both revisions; it checks the expected ownership difference there.
@Suite("Video scratch frame lifetime measurements", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_VIDEO_SCRATCH_MEASURE"] == "1"))
struct VideoScratchFrameLifetimeMeasurements {
    private enum Mode: String, Decodable {
        case frameThrow = "frame-throw"
        case frameCancel = "frame-cancel"
        case reservationDenied = "reservation-denied"
        case timestampThrow = "timestamp-throw"
        case normal
    }

    private struct Workload: Decodable {
        let name: String
        let width: Int
        let height: Int
        let mode: Mode
        let iterations: Int
    }

    private enum ConsumerFailure: Error { case requested }

    private struct Observation {
        let probe: VideoScratchAllocationProbe
        let frame: NativeDecodedVideoFrame?
        let packetRefcount: Int
        let outputCount: Int
        let timestampSum: Double
        let wallNanoseconds: UInt64
        let cpuNanoseconds: Double
    }

    @Test func recordNativeOwnership() throws {
        let specification = try #require(
            ProcessInfo.processInfo.environment["ILLIQUID_VIDEO_SCRATCH_WORKLOAD"]
        )
        let workload = try JSONDecoder().decode(Workload.self, from: Data(specification.utf8))
        try #require((1...200).contains(workload.iterations))
        try #require(workload.mode == .normal || workload.iterations == 1)
        try #require((1...3_840).contains(workload.width) && (1...2_160).contains(workload.height))

        // Warm the conversion and framework code with a separate decoder.
        // The measured decoder still starts with its own empty pool and state.
        try warmUp(workload)
        var decoder: VideoDecoder? = try VideoScratchFrameFixture.makeDecoder(
            width: workload.width, height: workload.height
        )
        weak var retiredDecoder = decoder
        var probes: [VideoScratchAllocationProbe] = []
        var refcounts: [Int] = []
        var releases: [Int] = []
        var last: Observation?
        var outputCount = 0
        var timestampSum = 0.0
        var wallNanoseconds: UInt64 = 0
        var cpuNanoseconds = 0.0

        for iteration in 0..<workload.iterations {
            // runOne owns the input packet. Returning from it is the lifetime
            // boundary: only the decoder and emitted output can retain data.
            let observation = try autoreleasepool {
                try runOne(try #require(decoder), workload: workload,
                           timestamp: Int64(iteration) * 40)
            }
            probes.append(observation.probe)
            refcounts.append(observation.packetRefcount)
            releases.append(observation.probe.releaseCount)
            outputCount += observation.outputCount
            timestampSum += observation.timestampSum
            wallNanoseconds += observation.wallNanoseconds
            cpuNanoseconds += observation.cpuNanoseconds
            last = observation
        }

        let observation = try #require(last)
        let probe = observation.probe
        let stillRetained = probe.releaseCount == 0
        let digestBefore = try digest(observation.frame)
        let metadata = metadata(observation.frame)
        // Keep the decoder and held output alive across the packet-release
        // sample; neither fixture ARC nor an autorelease pool is the fix.
        withExtendedLifetime(decoder) {}
        decoder?.flush()
        let afterFlush = probe.releaseCount
        let digestAfterFlush = try digest(observation.frame)
        decoder = nil
        try #require(retiredDecoder == nil)
        let afterDestroy = probe.releaseCount
        let digestAfterDestroy = try digest(observation.frame)
        let allReleasedOnce = probes.allSatisfy { $0.releaseCount == 1 }
        #expect(allReleasedOnce)
        #expect(digestBefore == digestAfterFlush)
        #expect(digestBefore == digestAfterDestroy)
        #expect(outputCount == (workload.mode == .reservationDenied ? 0 : workload.iterations))

        let record: [String: Any] = [
            "scenario": workload.name,
            "width": workload.width,
            "height": workload.height,
            "mode": workload.mode.rawValue,
            "iterations": workload.iterations,
            "payload_bytes": probe.payloadByteCount,
            "storage_bytes": probe.storageByteCount,
            "packet_refcounts_after_decode": refcounts,
            "source_release_counts_after_packet_release": releases,
            "retained_payload_bytes_after_packet_release": stillRetained ? probe.payloadByteCount : 0,
            "retained_storage_bytes_after_packet_release": stillRetained ? probe.storageByteCount : 0,
            "source_release_count_after_flush": afterFlush,
            "source_release_count_after_decoder_destroy": afterDestroy,
            "all_sources_released_exactly_once": allReleasedOnce,
            "output_count": outputCount,
            "timestamp_sum": timestampSum,
            "output_sha256_before_flush": digestBefore.map { $0 as Any } ?? NSNull(),
            "output_sha256_after_flush": digestAfterFlush.map { $0 as Any } ?? NSNull(),
            "output_sha256_after_decoder_destroy": digestAfterDestroy.map { $0 as Any } ?? NSNull(),
            "output_metadata": metadata,
            "wall_ns_per_decode": Double(wallNanoseconds) / Double(workload.iterations),
            "cpu_ns_per_decode": cpuNanoseconds / Double(workload.iterations),
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print("VIDEO_SCRATCH_MEASUREMENT " + String(decoding: data, as: UTF8.self))
        withExtendedLifetime(observation.frame) {}
    }

    private func warmUp(_ workload: Workload) throws {
        let decoder = try VideoScratchFrameFixture.makeDecoder(width: workload.width, height: workload.height)
        let warm = Workload(name: "warmup", width: workload.width, height: workload.height,
                            mode: .normal, iterations: 1)
        let observation = try runOne(decoder, workload: warm, timestamp: 0)
        #expect(observation.probe.releaseCount == 1)
        #expect(observation.outputCount == 1)
        decoder.flush()
    }

    @inline(never)
    private func runOne(_ decoder: VideoDecoder, workload: Workload, timestamp: Int64) throws -> Observation {
        let (packet, probe) = try VideoScratchFrameFixture.makePacket(
            width: workload.width, height: workload.height, timestamp: timestamp, generation: 7
        )
        var frame: NativeDecodedVideoFrame?
        var outputCount = 0
        var timestampSum = 0.0
        var receivedExpectedError = false
        var before = rusage()
        getrusage(RUSAGE_SELF, &before)
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            switch workload.mode {
            case .timestampThrow:
                try decoder.decodePresentationTimes(packet, while: { true }) { time in
                    outputCount += 1
                    timestampSum += time.seconds
                    throw ConsumerFailure.requested
                }
            case .reservationDenied:
                try decoder.decode(packet, while: { true }, reserveSoftwareOutput: { nil }) { _ in
                    outputCount += 1
                }
            case .frameThrow, .frameCancel, .normal:
                try decoder.decode(packet, while: { workload.mode != .frameCancel || outputCount == 0 }) { output in
                    outputCount += 1
                    timestampSum += output.presentationTime.seconds
                    frame = output
                    if workload.mode == .frameThrow { throw ConsumerFailure.requested }
                }
            }
        } catch ConsumerFailure.requested {
            try #require(workload.mode == .frameThrow || workload.mode == .timestampThrow)
            receivedExpectedError = true
        } catch SoftwarePixelBufferPoolError.cancelled {
            try #require(workload.mode == .frameCancel || workload.mode == .reservationDenied)
            receivedExpectedError = true
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        var after = rusage()
        getrusage(RUSAGE_SELF, &after)
        try #require(receivedExpectedError == (workload.mode != .normal))
        let buffer = try #require(packet.pointer?.pointee.buf)
        let refcount = Int(av_buffer_get_ref_count(buffer))
        withExtendedLifetime(packet) {}
        return Observation(probe: probe, frame: frame, packetRefcount: refcount,
                           outputCount: outputCount, timestampSum: timestampSum,
                           wallNanoseconds: elapsed,
                           cpuNanoseconds: cpuTime(after) - cpuTime(before))
    }

    private func cpuTime(_ usage: rusage) -> Double {
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000_000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1_000
    }

    private func digest(_ frame: NativeDecodedVideoFrame?) throws -> String? {
        guard let frame else { return nil }
        return SHA256.hash(data: try VideoScratchFrameFixture.pixelBytes(frame))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func metadata(_ frame: NativeDecodedVideoFrame?) -> Any {
        guard let frame else { return NSNull() }
        return [
            "pts_value": frame.presentationTime.value,
            "pts_timescale": frame.presentationTime.timescale,
            "duration_value": frame.duration.value,
            "duration_timescale": frame.duration.timescale,
            "generation": frame.generation,
            "width": CVPixelBufferGetWidth(frame.pixelBuffer),
            "height": CVPixelBufferGetHeight(frame.pixelBuffer),
            "pixel_format": CVPixelBufferGetPixelFormatType(frame.pixelBuffer),
            "source_format": frame.ffmpegPixelFormat,
            "filtered": frame.usesDeinterlacingFilter,
            "hardware": frame.isHardwareDecoded,
        ] as [String: Any]
    }
}
