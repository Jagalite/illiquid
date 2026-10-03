import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Testing
@testable import SuperplayrNativePlayback

@Suite("Planar software output benchmark", .serialized)
struct PlanarSoftwareOutputBenchmarkTests {
    @Test @MainActor
    func rendererBackedSoftwareRoute() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modeName = environment["SUPERPLAYR_PLANAR_BENCHMARK_MODE"],
              let fixturePath = environment["SUPERPLAYR_PLANAR_BENCHMARK_FIXTURE"],
              let resultPath = environment["SUPERPLAYR_PLANAR_BENCHMARK_RESULT"],
              let pidPath = environment["SUPERPLAYR_PLANAR_BENCHMARK_PID"]
        else { return }

        try Data("\(getpid())\n".utf8).write(
            to: URL(fileURLWithPath: pidPath),
            options: .atomic
        )
        let duration = Double(environment["SUPERPLAYR_PLANAR_BENCHMARK_DURATION"] ?? "30")
            ?? 30
        let decoderThreadCount = Int(
            environment["SUPERPLAYR_PLANAR_BENCHMARK_DECODER_THREADS"] ?? "0"
        ) ?? 0
        let fixture = URL(fileURLWithPath: fixturePath)
        let presenter = SampleBufferVideoPresenter()
        let window = makeRendererWindow(presenter: presenter)
        defer { window.close() }
        let recommended = presenter.renderer.recommendedPixelBufferAttributes.rawAttributes
            .reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
        let mode: SoftwareVideoOutputMode = modeName == "planar"
            ? .planarExperiment(rendererAttributes: recommended)
            : .bgra
        let demuxer = try FFmpegDemuxer(url: fixture)
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(
            parameters: parameters,
            stream: stream,
            preferHardware: false,
            timelineOriginSeconds: demuxer.mediaInfo.startTime,
            softwareOutputMode: mode,
            softwareDecoderThreadCount: decoderThreadCount
        )
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(presenter.renderer)
        synchronizer.setRate(0, time: .zero)

        var submitted = 0
        var maxTemporaryFrames = 0
        var backpressureEvents = 0
        var backpressureSeconds = 0.0
        var samples: [[String: Any]] = []
        var started = false
        var finishedSubmitting = false
        var lastSubmittedPTS = 0.0
        let wallStart = ProcessInfo.processInfo.systemUptime
        var nextSample = wallStart

        while !finishedSubmitting,
              let packet = try demuxer.readPacket(generation: 1)
        {
            guard packet.streamIndex == stream.index else { continue }
            let frames = try decoder.decode(packet)
            maxTemporaryFrames = max(maxTemporaryFrames, frames.count)
            for frame in frames {
                guard frame.presentationTime.isNumeric else { continue }
                if frame.presentationTime.seconds > duration {
                    finishedSubmitting = true
                    break
                }
                let waitStart = ProcessInfo.processInfo.systemUptime
                var waited = false
                while !presenter.isReady {
                    waited = true
                    RunLoop.current.run(until: Date().addingTimeInterval(0.001))
                    try sampleIfNeeded(
                        mode: modeName,
                        startedAt: wallStart,
                        nextSample: &nextSample,
                        samples: &samples
                    )
                    if presenter.failureDescription != nil { break }
                }
                if waited {
                    backpressureEvents += 1
                    backpressureSeconds += ProcessInfo.processInfo.systemUptime - waitStart
                }
                try presenter.enqueue(frame)
                submitted += 1
                lastSubmittedPTS = frame.presentationTime.seconds
                if !started {
                    synchronizer.setRate(1, time: frame.presentationTime)
                    started = true
                }
                try sampleIfNeeded(
                    mode: modeName,
                    startedAt: wallStart,
                    nextSample: &nextSample,
                    samples: &samples
                )
            }
        }

        let drainDeadline = Date().addingTimeInterval(3)
        while synchronizer.currentTime().seconds + 0.05 < lastSubmittedPTS,
              Date() < drainDeadline,
              presenter.failureDescription == nil
        {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            try sampleIfNeeded(
                mode: modeName,
                startedAt: wallStart,
                nextSample: &nextSample,
                samples: &samples
            )
        }
        synchronizer.setRate(0, time: synchronizer.currentTime())
        let displayed = presenter.renderer.displayedPixelBuffer()
        let performanceBox = LockedVideoPerformanceMetrics()
        presenter.renderer.loadVideoPerformanceMetrics { metrics in
            performanceBox.set(metrics.map {
                VideoPerformanceSnapshot(
                    totalFrames: $0.totalNumberOfFrames,
                    droppedFrames: $0.numberOfDroppedFrames,
                    corruptedFrames: $0.numberOfCorruptedFrames,
                    accumulatedDelaySeconds: $0.totalAccumulatedFrameDelay
                )
            })
        }
        let metricsDeadline = Date().addingTimeInterval(1)
        while !performanceBox.completed, Date() < metricsDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let videoPerformance = performanceBox.value
        let wallSeconds = ProcessInfo.processInfo.systemUptime - wallStart
        let rssValues = samples.compactMap { $0["rss_bytes"] as? UInt64 }
        let diagnostics = decoder.planarExperimentDiagnostics
        let output: [String: Any] = [
            "schema_version": 1,
            "mode": modeName,
            "decoder_thread_count": decoderThreadCount,
            "fixture": fixture.path,
            "duration_requested_seconds": duration,
            "wall_seconds": wallSeconds,
            "submitted_samples": submitted,
            "last_submitted_pts_seconds": lastSubmittedPTS,
            "renderer_status": String(describing: presenter.renderer.status),
            "renderer_failure": presenter.failureDescription ?? NSNull(),
            "displayed_pixel_format": displayed.map {
                String(format: "0x%08x", CVPixelBufferGetPixelFormatType($0))
            } ?? NSNull(),
            "renderer_total_frames": videoPerformance?.totalFrames ?? NSNull(),
            "renderer_dropped_frames": videoPerformance?.droppedFrames ?? NSNull(),
            "renderer_corrupted_frames": videoPerformance?.corruptedFrames ?? NSNull(),
            "renderer_accumulated_delay_seconds":
                videoPerformance?.accumulatedDelaySeconds ?? NSNull(),
            "backpressure_events": backpressureEvents,
            "backpressure_seconds": backpressureSeconds,
            "maximum_temporary_decoded_frames": maxTemporaryFrames,
            "mean_rss_bytes": rssValues.isEmpty
                ? 0 : rssValues.reduce(0, +) / UInt64(rssValues.count),
            "peak_rss_bytes": rssValues.max() ?? 0,
            "pool_checkouts": diagnostics?.checkouts ?? 0,
            "pool_unique_buffers": diagnostics?.uniqueBuffers ?? 0,
            "pool_in_use_upper_bound": diagnostics?.inUseUpperBound ?? 0,
            "pool_peak_in_use_upper_bound": diagnostics?.peakInUseUpperBound ?? 0,
            "pool_free_lower_bound": diagnostics?.freeLowerBound ?? 0,
            "pool_free_notifications": diagnostics?.freeNotifications ?? 0,
            "pool_threshold_waits": diagnostics?.thresholdWaits ?? 0,
            "pool_timeouts": diagnostics?.timeouts ?? 0,
            "pool_cancellations": diagnostics?.cancellations ?? 0,
            "samples": samples,
        ]
        let encoded = try JSONSerialization.data(
            withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try encoded.write(to: URL(fileURLWithPath: resultPath), options: .atomic)
        #expect(submitted > 0)
        #expect(presenter.failureDescription == nil)
        #expect(diagnostics?.timeouts ?? 0 == 0)
    }

    @Test @MainActor
    func rendererFlushPoolAvailabilityProbe() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixturePath = environment["SUPERPLAYR_PLANAR_FLUSH_PROBE_FIXTURE"],
              let resultPath = environment["SUPERPLAYR_PLANAR_FLUSH_PROBE_RESULT"]
        else { return }

        let fixture = URL(fileURLWithPath: fixturePath)
        let presenter = SampleBufferVideoPresenter()
        let window = makeRendererWindow(presenter: presenter)
        defer { window.close() }
        let recommended = presenter.renderer.recommendedPixelBufferAttributes.rawAttributes
            .reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
        let demuxer = try FFmpegDemuxer(url: fixture)
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(
            parameters: parameters,
            stream: stream,
            preferHardware: false,
            timelineOriginSeconds: demuxer.mediaInfo.startTime,
            softwareOutputMode: .planarExperiment(rendererAttributes: recommended),
            softwarePlanarOutputMaximumBufferCount: 12
        )
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(presenter.renderer)
        synchronizer.setRate(0, time: .zero)

        var queue: [NativeDecodedVideoFrame] = []
        var started = false
        var exhausted = false
        var packets = 0
        let deadline = Date().addingTimeInterval(15)
        while !exhausted, Date() < deadline, packets < 20_000 {
            while queue.count < 6, !exhausted,
                  let packet = try demuxer.readPacket(generation: 1)
            {
                packets += 1
                guard packet.streamIndex == stream.index else { continue }
                do {
                    let decoded = try decoder.decode(packet)
                    decoded.forEach {
                        $0.planarOwnershipToken?.transition(to: .queued)
                    }
                    queue += decoded
                } catch SoftwarePixelBufferPoolError.exhausted {
                    exhausted = true
                }
            }
            guard !exhausted else { break }
            guard presenter.isReady, !queue.isEmpty else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
                continue
            }
            let frame = queue.removeFirst()
            frame.planarOwnershipToken?.transition(to: .presenting)
            try presenter.enqueue(frame)
            if !started {
                synchronizer.setRate(1, time: frame.presentationTime)
                started = true
            }
        }

        let atPressure = decoder.planarOwnershipSnapshot(activeGeneration: 1)
        let availableAtPressure =
            decoder.planarPoolImmediateAvailabilityForDiagnostics() ?? -1
        queue.removeAll()
        let afterQueueRelease = decoder.planarOwnershipSnapshot(activeGeneration: 1)
        let availableAfterQueueRelease =
            decoder.planarPoolImmediateAvailabilityForDiagnostics() ?? -1

        synchronizer.setRate(0, time: synchronizer.currentTime())
        let flushStarted = ProcessInfo.processInfo.systemUptime
        let flushCompleted = LockedBenchmarkFlag()
        presenter.flush(removeDisplayedImage: true) { flushCompleted.set() }
        let flushDeadline = Date().addingTimeInterval(2)
        while !flushCompleted.value, Date() < flushDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        let flushCompletionMilliseconds = flushCompleted.value
            ? (ProcessInfo.processInfo.systemUptime - flushStarted) * 1_000
            : -1
        let afterFlush = decoder.planarOwnershipSnapshot(activeGeneration: 1)
        let availableAtFlushCompletion =
            decoder.planarPoolImmediateAvailabilityForDiagnostics() ?? -1
        var maximumAvailableAfterFlush = availableAtFlushCompletion
        let recycleStarted = ProcessInfo.processInfo.systemUptime
        var fullAvailabilityMilliseconds: Double? = availableAtFlushCompletion == 12
            ? 0 : nil
        let recycleDeadline = Date().addingTimeInterval(1)
        while maximumAvailableAfterFlush < 12, Date() < recycleDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            maximumAvailableAfterFlush = max(
                maximumAvailableAfterFlush,
                decoder.planarPoolImmediateAvailabilityForDiagnostics() ?? -1
            )
            if maximumAvailableAfterFlush == 12, fullAvailabilityMilliseconds == nil {
                fullAvailabilityMilliseconds =
                    (ProcessInfo.processInfo.systemUptime - recycleStarted) * 1_000
            }
        }

        let output: [String: Any] = [
            "schema_version": 1,
            "fixture": fixture.path,
            "pool_cap": 12,
            "queue_target": 6,
            "exhausted": exhausted,
            "packets": packets,
            "pool_timeouts": decoder.planarExperimentDiagnostics?.timeouts ?? 0,
            "pressure_known_buffers": atPressure.knownOutstandingBuffers,
            "pressure_application_frames": atPressure.applicationFrames,
            "pressure_queued_frames": atPressure.queuedFrames,
            "pressure_renderer_samples": atPressure.rendererSampleAttachments,
            "available_at_pressure": availableAtPressure,
            "known_after_queue_release": afterQueueRelease.knownOutstandingBuffers,
            "renderer_samples_after_queue_release":
                afterQueueRelease.rendererSampleAttachments,
            "available_after_queue_release": availableAfterQueueRelease,
            "flush_completed": flushCompleted.value,
            "flush_completion_milliseconds": flushCompletionMilliseconds,
            "known_at_flush_completion": afterFlush.knownOutstandingBuffers,
            "renderer_samples_at_flush_completion":
                afterFlush.rendererSampleAttachments,
            "available_at_flush_completion": availableAtFlushCompletion,
            "maximum_available_within_one_second_after_flush":
                maximumAvailableAfterFlush,
            "full_availability_milliseconds_after_flush_completion":
                fullAvailabilityMilliseconds ?? NSNull(),
            "reuse_while_known_owned": afterFlush.reuseWhileKnownOwned,
            "renderer_failure": presenter.failureDescription ?? NSNull(),
        ]
        let encoded = try JSONSerialization.data(
            withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try encoded.write(to: URL(fileURLWithPath: resultPath), options: .atomic)
        #expect(availableAtPressure == 0)
        #expect(flushCompleted.value)
        #expect(maximumAvailableAfterFlush == 12)
        #expect(presenter.failureDescription == nil)
    }

    private func sampleIfNeeded(
        mode: String,
        startedAt: TimeInterval,
        nextSample: inout TimeInterval,
        samples: inout [[String: Any]]
    ) throws {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextSample else { return }
        samples.append([
            "mode": mode,
            "elapsed_seconds": now - startedAt,
            "rss_bytes": ProcessResidentMemory.bytes() ?? 0,
        ])
        nextSample = now + 1
    }

    @MainActor
    private func makeRendererWindow(
        presenter: SampleBufferVideoPresenter
    ) -> NSWindow {
        let frame = NSRect(x: 20, y: 20, width: 960, height: 540)
        let view = NSView(frame: frame)
        view.wantsLayer = true
        presenter.displayLayer.frame = view.bounds
        view.layer?.addSublayer(presenter.displayLayer)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }
}

private struct VideoPerformanceSnapshot: Sendable {
    let totalFrames: Int
    let droppedFrames: Int
    let corruptedFrames: Int
    let accumulatedDelaySeconds: TimeInterval
}

private final class LockedVideoPerformanceMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: VideoPerformanceSnapshot?
    private var didComplete = false

    var completed: Bool { lock.withLock { didComplete } }
    var value: VideoPerformanceSnapshot? { lock.withLock { storage } }

    func set(_ value: VideoPerformanceSnapshot?) {
        lock.withLock {
            storage = value
            didComplete = true
        }
    }
}

private final class LockedBenchmarkFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.withLock { storage } }

    func set() { lock.withLock { storage = true } }
}
