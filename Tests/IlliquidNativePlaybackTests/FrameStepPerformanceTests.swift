import CoreMedia
import Darwin
import Foundation
import Testing
@testable import IlliquidNativePlayback

/// Opt-in native measurements. The runner builds this identical harness against
/// the baseline and candidate and alternates fresh processes on one macOS host.
@Suite("Frame step performance", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_FRAME_STEP_BENCHMARK"] == "1"
                || ProcessInfo.processInfo.environment["ILLIQUID_FRAME_STEP_PARITY"] == "1"))
struct FrameStepPerformanceTests {
    private struct Workload: Decodable {
        let name: String
        let filename: String
        let position: Double
        let direction: Int
        let iterations: Int
        let fullDecode: Bool
    }

    private struct FixtureManifest: Decodable {
        struct Fixture: Decodable {
            let filename: String
            let normalizedPTS: [Double]
        }
        let schemaVersion: Int
        let fixtures: [Fixture]
    }

    /// The runner compares records from the real reader in both revisions.
    /// Some containers expose a different packet sequence after seeking than
    /// after opening sequentially; equivalence must include that existing
    /// demuxer behavior instead of assuming every container has an exact index.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_FRAME_STEP_PARITY"] == "1"))
    func recordReaderParity() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["ILLIQUID_FRAME_STEP_FIXTURE_DIR"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let manifest = try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf:
            directory.appendingPathComponent("fixture-manifest.json")))
        try #require(manifest.schemaVersion == 1)
        try #require(!manifest.fixtures.isEmpty)
        let reader = NativeFrameStepReader()
        var records: [[String: Any]] = []
        for fixture in manifest.fixtures.sorted(by: { $0.filename < $1.filename }) {
            let times = fixture.normalizedPTS
            let first = try #require(times.first)
            let last = try #require(times.last)
            let middle = times[times.count / 2]
            let between = times.count > 1 ? (times[0] + times[1]) / 2 : first + 0.01
            let positions = Set([0, first, middle, between, last, last + 0.125]).sorted()
            let url = directory.appendingPathComponent(fixture.filename)
            try #require(FileManager.default.fileExists(atPath: url.path))
            for position in positions {
                for direction in [-1, 1] {
                    let target = try await reader.target(url: url, position: position, direction: direction)
                    records.append([
                        "filename": fixture.filename,
                        "position": position,
                        "direction": direction,
                        "target": target.map { $0 as Any } ?? NSNull(),
                    ])
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["records": records], options: [.sortedKeys])
        print("FRAME_STEP_READER_PARITY " + String(decoding: data, as: UTF8.self))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_FRAME_STEP_BENCHMARK"] == "1"))
    func measureNativeRequest() async throws {
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
