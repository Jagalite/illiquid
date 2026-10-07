import CoreGraphics
import CoreMedia
import AVFoundation
import Darwin
import Foundation
import IlliquidCore
import IlliquidPlayback
import Testing
@testable import IlliquidNativePlayback

/// Opt-in component observations on a shared host. These do not qualify visible
/// playback, physical output, whole-app energy, or current-build nonregression.
@Suite("Efficiency component observations", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_EFFICIENCY_OUTPUT"] != nil))
struct EfficiencyInvestigationTests {
    @Test @MainActor func headlessPlaybackContention() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["ILLIQUID_EFFICIENCY_CODEC_FIXTURES"])
        var rows: [[String: Any]] = []
        for name in ["hevc-10bit-1080p60.mkv", "vp9-1080p60.mkv"] {
            let backend = try NativePlaybackRuntime(softwareVideoOutputPolicy: .planarPreferred)
            let host = try backend.makeSurfaceHost()
            host.view.frame = CGRect(x: 0, y: 0, width: 960, height: 540)
            host.view.layoutSubtreeIfNeeded()
            backend.setMuted(true)
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            let previews = NativeTimelineThumbnailGenerator()
            do {
                let source = MediaSource.localFile(url)
                let request = try #require(MediaLoadRequest(source: source, origin: .userSelected))
                try backend.load(.init(media: request, identity: PlayerSessionIdentity(source: source, generation: 1)))
                let deadline = ContinuousClock.now + .seconds(12)
                while backend.sessionSnapshotForDiagnostics?.isPrerolled != true, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                try #require(backend.sessionSnapshotForDiagnostics?.isPrerolled == true)
                for phase in ["steady", "previews"] {
                    backend.play()
                    let start = ProcessInfo.processInfo.systemUptime, cpu = cpuSeconds()
                    let before = try #require(backend.sessionSnapshotForDiagnostics)
                    let task = Task { () -> Int in
                        guard phase == "previews" else { return 0 }
                        var completed = 0
                        for target in [1.5, 8.5, 2, 14] {
                            guard !Task.isCancelled else { break }
                            if await previews.thumbnail(for: url, at: target,
                                maximumPixelSize: CGSize(width: 368, height: 208)) != nil { completed += 1 }
                        }
                        return completed
                    }
                    try await Task.sleep(for: .seconds(4))
                    let after = try #require(backend.sessionSnapshotForDiagnostics)
                    let elapsed = ProcessInfo.processInfo.systemUptime-start
                    let cpuMS = (cpuSeconds()-cpu)*1000
                    backend.pause()
                    task.cancel(); await previews.cancelWork()
                    let previewCount = await task.value
                    rows.append(["fixture": name, "phase": phase, "wall_seconds": elapsed,
                        "cpu_ms": cpuMS, "cpu_percent_one_core": cpuMS/elapsed/10,
                        "renderer_clock_advance": after.rendererMediaTimeSeconds-before.rendererMediaTimeSeconds,
                        "submitted_delta": after.framesSubmitted-before.framesSubmitted,
                        "starvation_delta": after.rendererStarvations-before.rendererStarvations,
                        "completed_previews": previewCount, "footprint_bytes": footprint() as Any? ?? NSNull(),
                        "hardware": after.isHardwareDecoded,
                        "renderer_failure": after.rendererFailure as Any? ?? NSNull()])
                    #expect(after.rendererFailure == nil)
                    #expect(after.rendererMediaTimeSeconds > before.rendererMediaTimeSeconds)
                }
            } catch {
                await previews.cancelWork(); await previews.releaseIdleResources()
                await backend.shutdown()
                throw error
            }
            await previews.releaseIdleResources()
            await backend.shutdown()
        }
        try save("headless-contention", ["records": rows, "visible_window": false,
            "limitations": "One debug sample per phase; unpresented renderer; no display/drop/energy qualification"])
    }

    @Test func previewMemoryLifecycle() async throws {
        let fixture = try #require(ProcessInfo.processInfo.environment["ILLIQUID_EFFICIENCY_MEMORY_FIXTURE"])
        let url = URL(fileURLWithPath: fixture)
        let initial = footprint()
        var rows: [[String: Any]] = []
        for cycle in 0..<8 {
            var row = try await previewMemoryCycle(url)
            try await Task.sleep(for: .milliseconds(100))
            row["cycle"] = cycle
            row["after_owner_release_bytes"] = footprint() as Any? ?? NSNull()
            rows.append(row)
        }
        try save("preview-memory", ["fixture": fixture, "initial_bytes": initial as Any? ?? NSNull(),
            "records": rows, "limitations": "Component footprint includes allocator and process caches; no window resizing or active playback"])
    }

    private func previewMemoryCycle(_ url: URL) async throws -> [String: Any] {
        let generator = NativeTimelineThumbnailGenerator()
        for target in [1.5, 8.5, 2.0] {
            #expect(await generator.thumbnail(for: url, at: target,
                maximumPixelSize: CGSize(width: 368, height: 208)) != nil)
        }
        let working = footprint()
        await generator.releaseIdleResources()
        let idle = footprint()
        await generator.handleMemoryPressure(critical: true)
        return ["after_decode_bytes": working as Any? ?? NSNull(),
                "after_idle_release_bytes": idle as Any? ?? NSNull(),
                "after_pressure_bytes": footprint() as Any? ?? NSNull()]
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    @Test func decoderRouteCosts() throws {
        let directory = try #require(ProcessInfo.processInfo.environment["ILLIQUID_EFFICIENCY_CODEC_FIXTURES"])
        var rows: [[String: Any]] = []
        for name in ["hevc-10bit-1080p60.mkv", "vp9-1080p60.mkv"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            let metadata = try FFmpegDemuxer(url: url)
            let stream = try #require(metadata.mediaInfo.videoStreams.first)
            let hardwareAvailable = VideoDecoder.platformSupportsHardwareDecode(codecName: stream.codecName,
                registerSupplementalVP9: true)
            for repeatIndex in 0..<3 {
                for hardware in (repeatIndex % 2 == 0 ? [false, true] : [true, false]) {
                    if hardware && !hardwareAvailable { continue }
                    let start = ProcessInfo.processInfo.systemUptime, cpu = cpuSeconds()
                    let demuxer = try FFmpegDemuxer(url: url)
                    let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
                    let decoder = try VideoDecoder(parameters: parameters, stream: stream, preferHardware: hardware,
                        timelineOriginSeconds: demuxer.mediaInfo.startTime,
                        softwareOutputMode: .planarPreferred(rendererAttributes: [:]), softwareSeekAccelerationEnabled: false)
                    let constructionMS = (ProcessInfo.processInfo.systemUptime-start)*1000
                    for target: Double? in [nil, 8.5, 2] {
                        let phaseStart = ProcessInfo.processInfo.systemUptime, phaseCPU = cpuSeconds()
                        if let target {
                            try demuxer.seek(to: target + demuxer.mediaInfo.startTime, exact: true)
                            decoder.flush(); decoder.seekOutputFloor = (1, target)
                        }
                        var frames = 0, actualHardware = true
                        var firstMS: Double?
                        while frames < 60, let packet = try demuxer.readPacket(generation: 1) {
                            guard packet.streamIndex == stream.index else { continue }
                            try decoder.decode(packet, while: { true }) { frame in
                                frames += 1
                                actualHardware = actualHardware && frame.isHardwareDecoded
                                if firstMS == nil { firstMS = (ProcessInfo.processInfo.systemUptime-phaseStart)*1000 }
                            }
                        }
                        #expect(frames >= 60)
                        #expect(actualHardware == hardware)
                        rows.append(["fixture": name, "repeat": repeatIndex, "hardware": hardware,
                            "phase": target.map { "seek-\($0)" } ?? "initial", "frames": frames,
                            "construction_ms": constructionMS, "first_frame_ms": firstMS as Any? ?? NSNull(),
                            "decode_wall_ms": (ProcessInfo.processInfo.systemUptime-phaseStart)*1000,
                            "decode_cpu_ms": (cpuSeconds()-phaseCPU)*1000,
                            "route_total_cpu_ms": (cpuSeconds()-cpu)*1000,
                            "footprint_bytes": footprint() as Any? ?? NSNull()])
                    }
                }
            }
        }
        try save("decoder-routes", ["records": rows, "presentation": false,
            "supplemental_vp9_registration": "this isolated test process only"])
    }

    private func save(_ name: String, _ value: [String: Any]) throws {
        let directory = try #require(ProcessInfo.processInfo.environment["ILLIQUID_EFFICIENCY_OUTPUT"])
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".json"))
    }

    @Test func cachedImageDependsOnSourceMetadata() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cache-identity-\(UUID()).mkv")
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = NativeThumbnailCache()
        let size = CGSize(width: 16, height: 16)
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let key = try #require(await cache.makeKey(url: url, time: 1.5, size: size))
        await cache.insert(image, for: key, background: false)
        var direct: [Double] = [], identity: [Double] = []
        for _ in 0..<50 {
            var start = ProcessInfo.processInfo.systemUptime
            #expect(await cache.image(for: key, background: false) != nil)
            direct.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            start = ProcessInfo.processInfo.systemUptime
            let refreshed = try #require(await cache.makeKey(url: url, time: 1.5, size: size))
            #expect(await cache.image(for: refreshed, background: false) != nil)
            identity.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        try FileManager.default.removeItem(at: url)
        let retained = await cache.image(for: key, background: false) != nil
        let canResolve = await cache.makeKey(url: url, time: 1.5, size: size) != nil
        #expect(retained && !canResolve)
        try save("cache-identity", ["direct_ram_ms": direct, "identity_plus_ram_ms": identity,
            "owned_source_removed": true, "resident_image_retained": retained,
            "source_identity_resolves": canResolve])
    }

    private final class RenderProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func rendered() { lock.withLock { count += 1 } }
        var completed: Int { lock.withLock { count } }
    }

    @Test @MainActor func subtitleRenderLockWaits() async throws {
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        defer { pipeline.terminate() }
        let header = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,32,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        """
        let events = (0..<40).map { index in
            "Dialogue: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,{\\move(100,\(20+index*25),1500,\(20+index*25))\\blur2}Moving caption line \(index) with several distinct glyphs"
        }.joined(separator: "\n")
        try pipeline.installExternal(data: Data((header + "\n" + events + "\n").utf8))
        let progress = RenderProgress()
        let worker = Task.detached(priority: .utility) {
            for index in 0..<40 {
                _ = pipeline.renderedRegions(at: CMTime(seconds: Double(index)/60, preferredTimescale: 60_000),
                    viewport: CGRect(x: 0, y: 0, width: 1920, height: 1080), videoSize: CGSize(width: 1920, height: 1080))
                progress.rendered()
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        var waits: [Double] = []
        while progress.completed < 40 {
            let start = ProcessInfo.processInfo.systemUptime
            _ = pipeline.eventCount
            waits.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            try await Task.sleep(for: .milliseconds(1))
        }
        await worker.value
        try save("subtitle-lock", ["main_actor_event_count_wait_ms": waits,
            "rendered_frames": progress.completed, "authored_simultaneous_cues": 40,
            "physical_presentation": false])
    }

    @Test @MainActor func sessionConstructionAndRelease() throws {
        let fixture = try #require(ProcessInfo.processInfo.environment["ILLIQUID_EFFICIENCY_SUBTITLE_FIXTURE"])
        let url = URL(fileURLWithPath: fixture)
        let presentation = try NativePresentationCoordinator()
        defer { presentation.terminate() }
        var rows: [[String: Any]] = []
        for cycle in 0..<12 {
            let mode = cycle % 3
            let start = ProcessInfo.processInfo.systemUptime
            do {
                let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
                defer { pipeline.terminate() }
                let session = try MediaSession(url: url, presentation: presentation, subtitles: pipeline,
                    audioDelay: mode == 2 ? 0.1 : 0, subtitleSource: mode == 0 ? .off : .automaticEmbedded)
                #expect((session.activeSubtitleStream != nil) == (mode != 0))
                rows.append(["cycle": cycle, "mode": mode == 0 ? "av" : mode == 1 ? "av-subtitles" : "av-subtitles-delay",
                    "construction_ms": (ProcessInfo.processInfo.systemUptime-start)*1000,
                    "selected_subtitle": session.activeSubtitleStream != nil,
                    "footprint_during_bytes": footprint() as Any? ?? NSNull()])
                session.stop()
            }
            rows[rows.count-1]["footprint_after_release_bytes"] = footprint() as Any? ?? NSNull()
        }
        try save("session-construction", ["fixture": fixture, "cycles": rows, "playback_started": false])
    }

    private func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
