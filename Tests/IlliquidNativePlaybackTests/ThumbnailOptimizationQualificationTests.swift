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
        return ["resident": info.resident_size, "physical_footprint": info.phys_footprint,
                "physical_footprint_peak": UInt64(max(0, info.ledger_phys_footprint_peak))]
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

    /// Non-reference preroll skipping must only remove work: every selected
    /// frame, and therefore every image, must match a full-preroll decode.
    @Test func nonReferencePrerollSkippingPreservesPixels() async throws {
        guard let path = ProcessInfo.processInfo.environment["ILLIQUID_PREVIEW_NONREF_FIXTURE"] else { return }
        let url = URL(fileURLWithPath: path), size = CGSize(width: 368, height: 208)
        let duration = try FFmpegDemuxer(url: url).mediaInfo.duration
        let fullRecords = Observations(), skipRecords = Observations()
        let full = NativeTimelineThumbnailGenerator(skipsNonReferencePreroll: false, reducedFidelity: []) { fullRecords.append($0) }
        let skip = NativeTimelineThumbnailGenerator(skipsNonReferencePreroll: true, reducedFidelity: []) { skipRecords.append($0) }
        // Backward, forward-continuation, far-jump and near-EOF targets.
        let targets = [duration * 0.6, duration * 0.3, duration * 0.3 + 1, duration * 0.9, 0.5, duration]
        for target in targets {
            let reference = try #require(await full.thumbnail(for: url, at: target, maximumPixelSize: size))
            let candidate = try #require(await skip.thumbnail(for: url, at: target, maximumPixelSize: size))
            #expect(candidate.dataProvider?.data == reference.dataProvider?.data)
        }
        let fullStages = fullRecords.snapshot(), skipStages = skipRecords.snapshot()
        #expect(fullStages.count == skipStages.count)
        for (before, after) in zip(fullStages, skipStages) {
            #expect(after.selectedFrameSeconds == before.selectedFrameSeconds)
            #expect(before.skippedNonReferencePackets == 0)
        }
        #expect(skipStages.contains { $0.skippedNonReferencePackets > 0 })
        // The final-frame request keeps full decode for the EOF fallback.
        #expect(skipStages.last?.skippedNonReferencePackets == 0)
        await full.releaseIdleResources(); await skip.releaseIdleResources()
    }

    @Test func scaledBGRAOutputCoversRequestedPreviewInEitherOrientation() {
        let size = { VideoDecoder.scaledBGRAOutputSize(width: $0, height: $1, maximum: $2) }
        #expect(size(3840, 2160, (368, 208)) == (656, 368))
        #expect(size(2160, 3840, (368, 208)) == (368, 656))
        #expect(size(1920, 1080, nil) == (1920, 1080))
        // Never upscale small sources.
        #expect(size(320, 240, (368, 208)) == (320, 240))
        #expect(size(1920, 1080, (0, 208)) == (1920, 1080))
    }

    private func difference(_ lhs: CGImage, _ rhs: CGImage, width: Int = 368, height: Int = 208) -> (psnr: Double, meanAbsolute: Double)? {
        func pixels(_ image: CGImage) -> [UInt8]? {
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            return drawn ? data : nil
        }
        guard let a = pixels(lhs), let b = pixels(rhs) else { return nil }
        var squared = 0.0, absolute = 0.0, count = 0.0
        for index in a.indices where index % 4 != 3 {
            let delta = Double(a[index]) - Double(b[index])
            squared += delta * delta; absolute += abs(delta); count += 1
        }
        let mse = squared / max(count, 1)
        return (mse == 0 ? .infinity : 10 * log10(255 * 255 / mse), absolute / max(count, 1))
    }

    /// Reduced-fidelity previews may differ from an exact decode, but must
    /// select the same frame and stay visually close at preview size. PSNR is
    /// reported only: the two downscalers place hard synthetic edges at
    /// different subpixel offsets, so mean absolute difference is the bound.
    @Test func reducedFidelityPreviewStaysCloseToExactDecode() async throws {
        guard let path = ProcessInfo.processInfo.environment["ILLIQUID_PREVIEW_REDUCED_FIXTURE"] else { return }
        let url = URL(fileURLWithPath: path), size = CGSize(width: 368, height: 208)
        let duration = try FFmpegDemuxer(url: url).mediaInfo.duration
        let exactRecords = Observations(), reducedRecords = Observations()
        let exact = NativeTimelineThumbnailGenerator(reducedFidelity: []) { exactRecords.append($0) }
        let mode: NativeTimelineThumbnailGenerator.ReducedFidelity = switch ProcessInfo.processInfo.environment["ILLIQUID_PREVIEW_REDUCED_MODE"] {
        case "loop": .skipLoopFilter
        case "scale": .scaledConversion
        default: .all
        }
        let imageDirectory = ProcessInfo.processInfo.environment["ILLIQUID_PREVIEW_REDUCED_IMAGES"]
        let reduced = NativeTimelineThumbnailGenerator(reducedFidelity: mode) { reducedRecords.append($0) }
        var worst = 0.0
        for target in [duration * 0.6, duration * 0.3, duration * 0.3 + 1, duration * 0.9, 0.5, duration] {
            let reference = try #require(await exact.thumbnail(for: url, at: target, maximumPixelSize: size))
            let candidate = try #require(await reduced.thumbnail(for: url, at: target, maximumPixelSize: size))
            #expect(abs(candidate.width - reference.width) <= 2 && abs(candidate.height - reference.height) <= 2)
            let value = try #require(difference(candidate, reference))
            worst = max(worst, value.meanAbsolute)
            if let imageDirectory {
                for (name, image) in [("exact", reference), ("reduced", candidate)] {
                    let imageURL = URL(fileURLWithPath: imageDirectory).appendingPathComponent("\(name)-\(Int(target * 10)).png")
                    if let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(destination, image, nil); _ = CGImageDestinationFinalize(destination)
                    }
                }
            }
            print("reduced-fidelity target=\(target) psnr=\(value.psnr) mean-abs=\(value.meanAbsolute) size=\(candidate.width)x\(candidate.height)")
        }
        #expect(worst <= 6)
        for (before, after) in zip(exactRecords.snapshot(), reducedRecords.snapshot()) {
            #expect(after.selectedFrameSeconds == before.selectedFrameSeconds)
        }
        await exact.releaseIdleResources(); await reduced.releaseIdleResources()
    }

    @Test func previewDecodeRouteFollowsSourceSize() {
        #expect(!NativeTimelineThumbnailGenerator.previewUsesHardware(width: 1_920, height: 1_080, preference: nil))
        #expect(!NativeTimelineThumbnailGenerator.previewUsesHardware(width: 1_920, height: 1_088, preference: nil))
        #expect(NativeTimelineThumbnailGenerator.previewUsesHardware(width: 2_560, height: 1_440, preference: nil))
        #expect(NativeTimelineThumbnailGenerator.previewUsesHardware(width: 3_840, height: 2_160, preference: nil))
        #expect(NativeTimelineThumbnailGenerator.previewUsesHardware(width: 640, height: 360, preference: true))
        #expect(!NativeTimelineThumbnailGenerator.previewUsesHardware(width: 3_840, height: 2_160, preference: false))
    }

    /// Hardware and software previews take different decode and scaling routes;
    /// require them to stay visually equivalent at preview size.
    @Test func hardwarePreviewStaysCloseToSoftwarePreview() async throws {
        guard let path = ProcessInfo.processInfo.environment["ILLIQUID_PREVIEW_HARDWARE_FIXTURE"] else { return }
        let url = URL(fileURLWithPath: path)
        let codec = try #require(FFmpegDemuxer(url: url).mediaInfo.videoStreams.first).codecName
        guard VideoDecoder.platformSupportsHardwareDecode(codecName: codec) else {
            print("[preview-hardware] unqualified: host has no hardware decoder for \(codec)")
            return
        }
        let hardwareRecords = Observations()
        let software = NativeTimelineThumbnailGenerator(prefersHardware: false) { _ in }
        let hardware = NativeTimelineThumbnailGenerator(prefersHardware: true) { hardwareRecords.append($0) }
        let size = CGSize(width: 368, height: 208)
        for target in [0.5, 1.5, 2.25] {
            let expected = try #require(await software.thumbnail(for: url, at: target, maximumPixelSize: size, background: false))
            let actual = try #require(await hardware.thumbnail(for: url, at: target, maximumPixelSize: size, background: false))
            #expect(actual.width == expected.width && actual.height == expected.height)
            let delta = try #require(difference(actual, expected))
            print("[preview-hardware] target=\(target) psnr=\(delta.psnr) mean-absolute=\(delta.meanAbsolute)")
            // swscale and Core Image resample differently, so synthetic noise and
            // hairlines keep PSNR near 26 dB while flat colors agree within two
            // levels and no geometric offset exists. A decode-route color mismatch
            // (untagged BT.601 vs Core Image's default) measured 10.7 here.
            #expect(delta.meanAbsolute <= 4)
        }
        // prefersHardware permits software fallback; a fallback would compare
        // software with software and prove nothing about the hardware route.
        let records = hardwareRecords.snapshot()
        #expect(records.contains { $0.hardwareDecodedFrames > 0 })
        #expect(records.allSatisfy { $0.hardwareDecodedFrames == $0.frames })
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
        let skipsNonReference = env["ILLIQUID_PREVIEW_NONREF_SKIP"] != "0"
        let reducedFidelity: NativeTimelineThumbnailGenerator.ReducedFidelity = switch env["ILLIQUID_PREVIEW_REDUCED"] {
        case "0": []
        case "loop": .skipLoopFilter
        case "scale": .scaledConversion
        default: .all
        }
        let packetBytes = Int(env["ILLIQUID_PREVIEW_PACKET_BYTES"] ?? "0") ?? 0
        let readAhead = Double(env["ILLIQUID_PREVIEW_READAHEAD_SECONDS"] ?? "0") ?? 0
        let refillDelay = Double(env["ILLIQUID_PREVIEW_REFILL_DELAY_MS"] ?? "0") ?? 0
        let generator = NativeTimelineThumbnailGenerator(softwareThreads: threads, planarOutput: planar,
            prioritizesForeground: foreground, usesKeyframeIndex: indexed,
            skipsNonReferencePreroll: skipsNonReference, reducedFidelity: reducedFidelity, packetWindowBytes: packetBytes,
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
        let receipt: [String: Any] = ["packet_bytes": packetBytes, "read_ahead_seconds": readAhead, "simulated_refill_delay_ms": refillDelay, "threads": threads, "planar": planar, "foreground_priority": foreground, "keyframe_index": indexed, "nonref_skip": skipsNonReference, "reduced_fidelity": reducedFidelity.rawValue, "requests": callers,
            "stages": stages, "batch_wall_ms": wall, "batch_cpu_ms": cpu,
            "renderer_prewarmed": prewarm, "preparation_wall_ms": preparationWallMS,
            "preparation_cpu_ms": preparationCPUMS, "memory_before": memoryBefore,
            "memory_prepared": memoryPrepared, "memory_after_requests": memoryBytes()]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }
}
