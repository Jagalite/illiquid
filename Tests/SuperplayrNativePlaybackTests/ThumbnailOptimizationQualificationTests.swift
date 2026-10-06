import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import SuperplayrCore
import Testing
@testable import SuperplayrNativePlayback

/// Opt-in, same-process work accounting; each CLI invocation owns its decoder/cache.
@Suite("Thumbnail optimization measurements", .serialized)
struct ThumbnailOptimizationQualificationTests {
    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ThumbnailDecodeObservation] = []
        func append(_ value: ThumbnailDecodeObservation) { lock.withLock { values.append(value) } }
        func snapshot() -> [ThumbnailDecodeObservation] { lock.withLock { values } }
    }
    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    @Test func indexedKeyframeAvoidsRedundantForwardDecodeWithoutChangingPixels() async throws {
        guard let path = ProcessInfo.processInfo.environment["ILLIQUID_PREVIEW_INDEX_REGRESSION_FIXTURE"] else { return }
        let url = URL(fileURLWithPath: path)
        let oldRecords = Observations(), newRecords = Observations()
        let old = NativeTimelineThumbnailGenerator(usesKeyframeIndex: false) { oldRecords.append($0) }
        let new = NativeTimelineThumbnailGenerator(usesKeyframeIndex: true) { newRecords.append($0) }
        for target in [1.5, 2.0, 2.5, 3.5, 4.0, 4.5, 0.5] {
            let baseline = try #require(await old.thumbnail(for: url, at: target,
                maximumPixelSize: CGSize(width: 368, height: 208)))
            let candidate = try #require(await new.thumbnail(for: url, at: target,
                maximumPixelSize: CGSize(width: 368, height: 208)))
            let fresh = NativeTimelineThumbnailGenerator()
            let reference = try #require(await fresh.thumbnail(for: url, at: target,
                maximumPixelSize: CGSize(width: 368, height: 208)))
            #expect(candidate.dataProvider?.data == baseline.dataProvider?.data)
            #expect(candidate.dataProvider?.data == reference.dataProvider?.data)
            await fresh.releaseIdleResources()
        }
        let before = try #require(oldRecords.snapshot().first { $0.target == 4 })
        let after = try #require(newRecords.snapshot().first { $0.target == 4 })
        #expect(before.continuedForward && !after.continuedForward)
        #expect(after.discardedBeforeOutput < before.discardedBeforeOutput)
        #expect(after.selectedFrameSeconds == before.selectedFrameSeconds)
        let demuxer = try FFmpegDemuxer(url: url)
        #expect(demuxer.indexedKeyframeTime(at: .nan, streamIndex: 0) == nil)
        #expect(demuxer.indexedKeyframeTime(at: 2, streamIndex: -1) == nil)
        await old.releaseIdleResources(); await new.releaseIdleResources()
    }

    @Test func measure() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["ILLIQUID_PREVIEW_FIXTURE"], let output = env["ILLIQUID_PREVIEW_RECEIPT"] else { return }
        let url = URL(fileURLWithPath: path)
        let observations = Observations()
        let threads = Int(env["ILLIQUID_PREVIEW_THREADS"] ?? "2") ?? 2
        let planar = env["ILLIQUID_PREVIEW_PLANAR"] == "1"
        let foreground = env["ILLIQUID_PREVIEW_FOREGROUND_PRIORITY"] == "1"
        let indexed = env["ILLIQUID_PREVIEW_KEYFRAME_INDEX"] == "1"
        let generator = NativeTimelineThumbnailGenerator(softwareThreads: threads, planarOutput: planar, prioritizesForeground: foreground, usesKeyframeIndex: indexed) { observations.append($0) }
        var requests: [(URL, Double)] = [1.5, 2, 2.5, 1.5, 3.5, 4, 3.5].map { (url, $0) }
        if let second = env["ILLIQUID_PREVIEW_SECOND_FIXTURE"] {
            let urls = [url, URL(fileURLWithPath: second)]
            let plans = try urls.map { file in
                ThumbnailPolicy.samples(duration: try FFmpegDemuxer(url: file).mediaInfo.duration, focus: 0, count: 12)
            }
            requests = urls.indices.map { (urls[$0], plans[$0][0]) }
            let chunk = max(1, Int(env["ILLIQUID_PREVIEW_BATCH_SIZE"] ?? "1") ?? 1)
            for request in ThumbnailPolicy.refinementOrder(plans.map { Array($0.dropFirst()) }, maximumPerVisit: chunk) {
                requests.append((urls[request.video], request.position))
            }
        }
        var callers: [[String: Any]] = []
        let batchWall = ProcessInfo.processInfo.systemUptime, batchCPU = cpuSeconds()
        for (index, request) in requests.enumerated() {
            let start = ProcessInfo.processInfo.systemUptime, cpu = cpuSeconds()
            let image = await generator.thumbnail(for: request.0, at: request.1,
                maximumPixelSize: CGSize(width: 368, height: 208), background: env["ILLIQUID_PREVIEW_SECOND_FIXTURE"] != nil)
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            let cpuMS = (cpuSeconds() - cpu) * 1_000
            var record: [String: Any] = ["file": request.0.lastPathComponent, "target": request.1,
                "wall_ms": elapsed, "cpu_ms": cpuMS, "available": image != nil]
            if let image {
                record["width"] = image.width; record["height"] = image.height
                if let data = image.dataProvider?.data {
                    record["sha256"] = SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
                }
                if env["ILLIQUID_PREVIEW_IMAGES"] == "1" {
                    let imageURL = URL(fileURLWithPath: output + "-\(index).png")
                    let destination = try #require(CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil))
                    CGImageDestinationAddImage(destination, image, nil)
                    #expect(CGImageDestinationFinalize(destination))
                }
            }
            callers.append(record)
            #expect(image != nil)
        }
        let wall = (ProcessInfo.processInfo.systemUptime - batchWall) * 1_000
        let cpu = (cpuSeconds() - batchCPU) * 1_000
        await generator.releaseIdleResources()
        let stages = try JSONSerialization.jsonObject(with: JSONEncoder().encode(observations.snapshot()))
        let receipt: [String: Any] = ["threads": threads, "planar": planar, "foreground_priority": foreground, "keyframe_index": indexed, "requests": callers,
            "stages": stages, "batch_wall_ms": wall, "batch_cpu_ms": cpu]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }
}
