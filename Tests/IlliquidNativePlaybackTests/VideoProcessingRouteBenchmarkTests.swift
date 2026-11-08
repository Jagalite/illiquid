import AVFoundation
import Darwin
import Foundation
import IlliquidCore
import IlliquidPlayback
import Testing
@testable import IlliquidNativePlayback

/// Opt-in comparison of the normal presentation route with the Metal
/// processing route, playing real files through the real renderer.
///
/// Set ILLIQUID_VIDEO_PROCESSING_BENCHMARK=1 and ILLIQUID_VIDEO_BENCH_DIR to a
/// directory with bench-1080p-h264.mp4 (1920x1080 24 fps) and
/// bench-2160p-hevc10.mkv (3840x2160 10-bit 24 fps), about 10 s each.
///
/// Measures process CPU and memory footprint over playback, per-frame
/// processing time (sampled), frames submitted, renderer back-pressure, and
/// the display layer's own frame counters. There is no window, so the
/// display layer's dropped/late counts describe its queue, not scanout.
extension RealRendererPlayback {
    @Suite("Video processing route comparison", .serialized)
    struct VideoProcessingRouteBenchmarkTests {
        private static var directory: URL? {
            guard ProcessInfo.processInfo.environment["ILLIQUID_VIDEO_PROCESSING_BENCHMARK"] == "1",
                  let path = ProcessInfo.processInfo.environment["ILLIQUID_VIDEO_BENCH_DIR"]
            else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        private struct Run {
            var cpuPercent = 0.0
            var footprintStartMB = 0.0
            var footprintPeakMB = 0.0
            var wallSeconds = 0.0
            var submitted = 0
            var backpressureEvents = 0
            var starvations = 0
            var processingMedianMs: Double?
            var processingP95Ms: Double?
            var rendererTotal: Int?
            var rendererDropped: Int?
            var rendererDelaySeconds: Double?
            var ended = false
            var failure: String?
        }

        private static func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
            return seconds(usage.ru_utime) + seconds(usage.ru_stime)
        }

        private static func footprintMB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
        }

        @MainActor
        private func play(_ url: URL, configuration: VideoFrameProcessingConfiguration) async throws -> Run {
            let backend = try NativePlaybackRuntime(videoFrameProcessing: configuration)
            _ = try backend.makeSurfaceHost()
            let source = MediaSource.localFile(url)
            let request = try #require(MediaLoadRequest(source: source, origin: .userSelected))
            try backend.load(PlaybackRuntimeLoadRequest(
                media: request, identity: PlayerSessionIdentity(source: source, generation: 1)
            ))
            let clock = ContinuousClock()
            let loadDeadline = clock.now.advanced(by: .seconds(10))
            while clock.now < loadDeadline, backend.sessionSnapshotForDiagnostics?.isPrerolled != true {
                try await Task.sleep(for: .milliseconds(10))
            }
            var run = Run()
            run.footprintStartMB = Self.footprintMB()
            run.footprintPeakMB = run.footprintStartMB
            let cpuStart = Self.cpuSeconds()
            let started = clock.now
            backend.play()
            var processing: [Double] = []
            let deadline = clock.now.advanced(by: .seconds(25))
            while clock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
                run.footprintPeakMB = max(run.footprintPeakMB, Self.footprintMB())
                guard let snapshot = backend.sessionSnapshotForDiagnostics else { continue }
                if let last = snapshot.videoProcessing?.lastProcessingMilliseconds, last > 0 {
                    processing.append(last)
                }
                if snapshot.ended { run.ended = true; break }
            }
            let elapsed = clock.now - started
            run.wallSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            run.cpuPercent = (Self.cpuSeconds() - cpuStart) / run.wallSeconds * 100
            if let snapshot = backend.sessionSnapshotForDiagnostics {
                run.submitted = snapshot.framesSubmitted
                run.backpressureEvents = snapshot.rendererBackpressureEvents
                run.starvations = snapshot.rendererStarvations
                run.failure = snapshot.rendererFailure ?? snapshot.lastRecoveryFailure?.stableCode
                    ?? snapshot.videoProcessing?.bypassReason
            }
            if let metrics = await backend.presentation.video.renderer.videoPerformanceMetrics {
                run.rendererTotal = metrics.totalNumberOfFrames
                run.rendererDropped = metrics.numberOfDroppedFrames
                run.rendererDelaySeconds = metrics.totalAccumulatedFrameDelay
            }
            processing.sort()
            if !processing.isEmpty {
                run.processingMedianMs = processing[processing.count / 2]
                run.processingP95Ms = processing[Int(Double(processing.count - 1) * 0.95)]
            }
            await backend.shutdown()
            return run
        }

        private static func text(_ value: Double?, _ digits: Int = 2) -> String {
            value.map { String(format: "%.\(digits)f", $0) } ?? "n/a"
        }

        @Test(arguments: [
            ("bench-1080p-h264.mp4", 1920, 1080),
            ("bench-2160p-hevc10.mkv", 3840, 2160),
        ])
        @MainActor
        func compareRoutes(file: String, width: Int, height: Int) async throws {
            guard let directory = Self.directory else { return }
            let url = directory.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let routes: [(String, VideoFrameProcessingConfiguration)] = [
                ("normal", .disabled),
                // A same-size resample: every frame goes through the GPU
                // pipeline and comes out unchanged. Isolates the Metal hop.
                ("metal-passthrough", VideoFrameProcessingConfiguration(
                    transform: VideoFrameTransform(outputSize: .exact(width: width, height: height))
                )),
                ("metal-all-filters", VideoFrameProcessingConfiguration(
                    pictureAdjustments: VideoPictureAdjustments(contrast: 15, saturation: 10),
                    filters: [.denoise, .deband, .sharpen]
                )),
            ]
            // Two rounds in alternating order to spread warm-up and thermal
            // drift across routes.
            for round in 0..<2 {
                let ordered = round == 0 ? routes : routes.reversed()
                for (name, configuration) in ordered {
                    let run = try await play(url, configuration: configuration)
                    #expect(run.ended, "\(name) did not reach the end")
                    #expect(run.failure == nil, "\(name): \(run.failure ?? "")")
                    print("ROUTE_BENCH file=\(file) round=\(round) route=\(name) "
                        + "cpu-pct=\(Self.text(run.cpuPercent, 1)) "
                        + "footprint-mb=\(Self.text(run.footprintStartMB, 0))->peak \(Self.text(run.footprintPeakMB, 0)) "
                        + "wall-s=\(Self.text(run.wallSeconds)) submitted=\(run.submitted) "
                        + "processing-ms=median \(Self.text(run.processingMedianMs)) p95 \(Self.text(run.processingP95Ms)) "
                        + "backpressure=\(run.backpressureEvents) starvations=\(run.starvations) "
                        + "renderer=total \(run.rendererTotal.map(String.init) ?? "n/a") "
                        + "dropped \(run.rendererDropped.map(String.init) ?? "n/a") "
                        + "delay-s \(Self.text(run.rendererDelaySeconds, 3)) "
                        + "ended=\(run.ended) failure=\(run.failure ?? "none")")
                }
            }
        }
    }
}
