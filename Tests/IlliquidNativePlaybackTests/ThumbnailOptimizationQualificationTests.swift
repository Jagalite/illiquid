import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import IlliquidCore
import Testing
@testable import IlliquidNativePlayback

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

    private func memoryBytes() -> [String: UInt64] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return [:] }
        return ["resident": info.resident_size, "physical_footprint": info.phys_footprint]
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

    @Test func packetExperimentFallsBackUnderTinyBudgetAndReleasesOnPressureOrInvalidation() async throws {
        guard let path = ProcessInfo.processInfo.environment["ILLIQUID_PACKET_REGRESSION_FIXTURE"] else { return }
        let url = URL(fileURLWithPath: path), size = CGSize(width: 368, height: 208)
        for budget in [1, 32 * 1024 * 1024] {
            let records = Observations()
            let generator = NativeTimelineThumbnailGenerator(packetWindowBytes: budget, packetReadAheadSeconds: 0.5) { records.append($0) }
            for target in [1.5, 0.5] {
                let candidate = try #require(await generator.thumbnail(for: url, at: target, maximumPixelSize: size))
                let fresh = NativeTimelineThumbnailGenerator()
                let reference = try #require(await fresh.thumbnail(for: url, at: target, maximumPixelSize: size))
                #expect(candidate.dataProvider?.data == reference.dataProvider?.data)
                await fresh.releaseIdleResources()
            }
            if budget == 1 { #expect(records.snapshot().allSatisfy { $0.retainedPacketBytes == 0 }) }
            else { #expect(records.snapshot().contains { $0.replayedPacketWindow }) }
            await generator.handleMemoryPressure(critical: true)
            #expect(await generator.thumbnail(for: url, at: 1, maximumPixelSize: size) != nil)
            #expect(records.snapshot().last?.reusedContext == false)
            await generator.invalidate(for: 2)
            #expect(await generator.thumbnail(for: url, at: 3, maximumPixelSize: size) != nil)
            #expect(records.snapshot().last?.reusedContext == false)
            await generator.releaseIdleResources()
        }
    }

    @Test func shortInterlacedEndHoverReturnsFinalFrame() async throws {
        guard let path = ProcessInfo.processInfo.environment["ILLIQUID_PREVIEW_END_FIXTURE"] else { return }
        let url = URL(fileURLWithPath: path)
        let duration = try FFmpegDemuxer(url: url).mediaInfo.duration
        #expect(duration > 0 && duration < 3)
        for target in [duration - 0.01, duration, duration + 0.5, duration + 20] {
            let observations = Observations()
            let generator = NativeTimelineThumbnailGenerator { observations.append($0) }
            let image = await generator.thumbnail(for: url, at: target,
                maximumPixelSize: CGSize(width: 368, height: 208))
            #expect(image != nil)
            let record = try #require(observations.snapshot().last)
            let selected = try #require(record.selectedFrameSeconds)
            #expect(selected >= duration - 0.15 && selected <= duration + 0.01)
            #expect(record.totalMilliseconds < 3_000)
            await generator.releaseIdleResources()
        }
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
        let packetBytes = Int(env["ILLIQUID_PREVIEW_PACKET_BYTES"] ?? "0") ?? 0
        let readAhead = Double(env["ILLIQUID_PREVIEW_READAHEAD_SECONDS"] ?? "0") ?? 0
        let refillDelay = Double(env["ILLIQUID_PREVIEW_REFILL_DELAY_MS"] ?? "0") ?? 0
        let generator = NativeTimelineThumbnailGenerator(softwareThreads: threads, planarOutput: planar,
            prioritizesForeground: foreground, usesKeyframeIndex: indexed, packetWindowBytes: packetBytes,
            packetReadAheadSeconds: readAhead, simulatedRefillDelay: refillDelay / 1000) { observations.append($0) }
        var requests: [(URL, Double)] = [1.5, 2, 2.5, 1.5, 3.5, 4, 3.5].map { (url, $0) }
        if env["ILLIQUID_PREVIEW_PACKET_WORKLOAD"] == "1" {
            // Unique thumbnail buckets force decoding: image-cache hits must not
            // masquerade as packet-cache wins. Mix backward GOP visits and forward continuation.
            requests = [1.5, 1, 0.5, 0, 3.5, 3, 2.5, 2, 5.5, 5, 4.5, 4, 6, 6.5, 7, 18.5, 8].map { (url, $0) }
        }
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
        let prewarm = env["ILLIQUID_PREVIEW_PREWARM"] == "1"
        let memoryBefore = memoryBytes()
        let preparationStart = ProcessInfo.processInfo.systemUptime, preparationCPU = cpuSeconds()
        if prewarm { await NativeTimelineThumbnailGenerator.prepareImageRendererForQualification() }
        let preparationWallMS = (ProcessInfo.processInfo.systemUptime - preparationStart) * 1_000
        let preparationCPUMS = (cpuSeconds() - preparationCPU) * 1_000
        let memoryPrepared = memoryBytes()
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
        let receipt: [String: Any] = ["packet_bytes": packetBytes, "read_ahead_seconds": readAhead, "simulated_refill_delay_ms": refillDelay, "threads": threads, "planar": planar, "foreground_priority": foreground, "keyframe_index": indexed, "requests": callers,
            "stages": stages, "batch_wall_ms": wall, "batch_cpu_ms": cpu,
            "renderer_prewarmed": prewarm, "preparation_wall_ms": preparationWallMS,
            "preparation_cpu_ms": preparationCPUMS, "memory_before": memoryBefore,
            "memory_prepared": memoryPrepared, "memory_after_requests": memoryBytes()]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }
}
