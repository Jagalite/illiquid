import CoreMedia
import Darwin
import Foundation
import Testing
@testable import IlliquidNativePlayback

/// Opt-in native measurements. The runner builds this identical harness against
/// the baseline and candidate and alternates fresh processes on one macOS host.
@Suite("Frame step performance", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_FRAME_STEP_BENCHMARK"] == "1"))
struct FrameStepPerformanceTests {
    private struct Workload: Decodable {
        let name: String
        let filename: String
        let position: Double
        let direction: Int
        let iterations: Int
        let fullDecode: Bool
    }

    @Test func measureNativeRequest() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = try #require(environment["ILLIQUID_FRAME_STEP_FIXTURE_DIR"])
        let specification = try #require(environment["ILLIQUID_FRAME_STEP_WORKLOAD"])
        let workload = try JSONDecoder().decode(Workload.self, from: Data(specification.utf8))
        let url = URL(fileURLWithPath: directory).appendingPathComponent(workload.filename)
        try #require(FileManager.default.fileExists(atPath: url.path))
        try #require((1...20).contains(workload.iterations))

        // Warm filesystem/framework state once. Every timed request still opens
        // and closes its own demuxer and decoder, exactly as the real reader does.
        let reader = NativeFrameStepReader()
        if workload.fullDecode {
            _ = try decodeAll(url)
        } else {
            _ = try await reader.target(url: url, position: workload.position,
                                        direction: workload.direction)
        }
        var targets: [Double?] = []
        var frameCounts: [Int] = []
        var timestampSums: [Double] = []
        targets.reserveCapacity(workload.iterations)
        frameCounts.reserveCapacity(workload.iterations)
        timestampSums.reserveCapacity(workload.iterations)
        var usageBefore = rusage()
        getrusage(RUSAGE_SELF, &usageBefore)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<workload.iterations {
            if workload.fullDecode {
                let result = try decodeAll(url)
                frameCounts.append(result.count)
                timestampSums.append(result.sum)
            } else {
                targets.append(try await reader.target(url: url, position: workload.position,
                                                       direction: workload.direction))
            }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        var usageAfter = rusage()
        getrusage(RUSAGE_SELF, &usageAfter)
        let cpuNanoseconds = cpuTime(usageAfter) - cpuTime(usageBefore)
        let row: [String: Any] = [
            "scenario": workload.name,
            "iterations": workload.iterations,
            "wall_ns_per_request": Double(elapsed) / Double(workload.iterations),
            "cpu_ns_per_request": cpuNanoseconds / Double(workload.iterations),
            "peak_process_rss_bytes": usageAfter.ru_maxrss,
            "targets": targets.map { $0.map { $0 as Any } ?? NSNull() },
            "frame_counts": frameCounts,
            "timestamp_sums": timestampSums,
        ]
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        print("FRAME_STEP_MEASUREMENT " + String(decoding: data, as: UTF8.self))
    }

    private func cpuTime(_ usage: rusage) -> Double {
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000_000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1_000
    }

    private func decodeAll(_ url: URL) throws -> (count: Int, sum: Double) {
        try autoreleasepool {
            let demuxer = try FFmpegDemuxer(url: url)
            let stream = try #require(demuxer.mediaInfo.videoStreams.first {
                $0.index == demuxer.mediaInfo.selectedVideoIndex
            })
            let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
            let decoder = try VideoDecoder(parameters: parameters, stream: stream,
                preferHardware: false, timelineOriginSeconds: demuxer.mediaInfo.startTime,
                softwareOutputMode: .bgra, softwareDecoderThreadCount: 2,
                softwarePlanarOutputMaximumBufferCount: 2)
            var count = 0
            var sum = 0.0
            func receive(_ frame: NativeDecodedVideoFrame) {
                count += 1
                sum += frame.presentationTime.seconds
            }
            while let packet = try demuxer.readPacket(generation: 1) {
                if packet.streamIndex == stream.index {
                    try decoder.decode(packet, while: { true }, emit: receive)
                }
            }
            try decoder.drain(generation: 1, while: { true }, emit: receive)
            return (count, sum)
        }
    }
}
