import CoreMedia
import Foundation
import Testing
@testable import SuperplayrNativePlayback

@Suite("Presentation timeline observation", .serialized)
struct PresentationTimeObservationTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Double] = []
        func append(_ time: CMTime) { lock.withLock { times.append(time.seconds) } }
        var count: Int { lock.withLock { times.count } }
        var values: [Double] { lock.withLock { times } }
    }

    @Test func pausedTimelineDoesNotKeepWakingAndSeekStillPublishes() async throws {
        let presentation = try NativePresentationCoordinator()
        defer { presentation.terminate() }
        let recorder = Recorder()
        presentation.setPresentationTimeHandler { recorder.append($0) }
        #expect(presentation.setRate(0, at: CMTime(seconds: 3, preferredTimescale: 600), fence: presentation.currentFence))
        for _ in 0..<100 where !recorder.values.contains(where: { abs($0 - 3) < 0.01 }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.values.contains(where: { abs($0 - 3) < 0.01 }))
        let baseline = recorder.count
        try await Task.sleep(for: .milliseconds(300))
        let pausedCallbacks = recorder.count - baseline
        print("[presentation-observation] paused-callbacks-in-300ms=\(pausedCallbacks)")
        #expect(pausedCallbacks == 0)
        #expect(presentation.setRate(0, at: CMTime(seconds: 6, preferredTimescale: 600), fence: presentation.currentFence))
        for _ in 0..<100 where !recorder.values.contains(where: { abs($0 - 6) < 0.01 }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.values.contains(where: { abs($0 - 6) < 0.01 }))
        presentation.terminate()
        let terminatedCount = recorder.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.count == terminatedCount)
    }

    @Test(arguments: [24.0, 30.0, 60.0])
    func activeClockCadenceAndEOFObservation(frameRate: Double) async throws {
        let presentation = try NativePresentationCoordinator()
        defer { presentation.terminate() }
        let recorder = Recorder()
        presentation.setPresentationTimeHandler { recorder.append($0) }
        let interval = NativeSubtitleRenderPolicy.observationInterval(hasSubtitles: true, frameRate: frameRate)
        #expect(abs(interval.seconds - 1 / frameRate) < 0.00001)
        presentation.setPresentationTimeObservationInterval(interval)
        // No samples or player: use the synchronizer's host clock to exercise
        // observation lifetime. This does not measure displayed subtitle timing.
        presentation.synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        #expect(presentation.setRate(1, at: .zero))
        try await Task.sleep(for: .milliseconds(400))
        let activeCount = recorder.count
        #expect(recorder.values.contains(where: { $0 > 0.2 }))
        presentation.setPresentationTimeObservationInterval(
            NativeSubtitleRenderPolicy.observationInterval(hasSubtitles: false, frameRate: frameRate)
        )
        let offBaseline = recorder.count
        try await Task.sleep(for: .milliseconds(600))
        let offCount = recorder.count - offBaseline
        #expect(offCount > 0) // EOF can continue observing the clock with subtitles Off.
        print("[presentation-observation] requested-fps=\(frameRate) callbacks-in-400ms=\(activeCount) off-callbacks-in-600ms=\(offCount)")
    }

    @Test @MainActor func busyMainActorCoalescesClockCallbacks() async throws {
        let coalescer = RuntimeObservationCoalescer()
        var deliveries = 0
        for _ in 0..<1_000 {
            coalescer.request(.init(source: .presentationClock, urgency: .routine)) { deliveries += 1 }
        }
        #expect(coalescer.snapshot().scheduledDeliveries == 1)
        #expect(coalescer.snapshot().coalescedRequests == 999)
        // Drain the batch before asserting the retained delivery policy.
        for _ in 0..<100 { await Task.yield() }
        #expect(deliveries == 2)
        #expect(coalescer.snapshot().followUpDeliveries == 1)
    }

    @Test @MainActor func requestDuringDeliveryStillGetsAFollowUp() async {
        let coalescer = RuntimeObservationCoalescer()
        var revision = 0
        var observed: [Int] = []
        coalescer.request(.init(source: .videoEnqueue, urgency: .routine)) {
            observed.append(revision)
            if revision == 0 {
                revision = 1
                coalescer.request(.init(source: .preroll, urgency: .urgent)) {
                    // The scheduled operation owns the batch, as before.
                    Issue.record("Unexpected replacement of the pending operation")
                }
            }
        }
        for _ in 0..<100 where observed.count < 2 { await Task.yield() }
        #expect(observed == [0, 1])
        #expect(coalescer.snapshot().followUpDeliveries == 1)

        // Once the batch drains, a fresh request must schedule a new operation.
        coalescer.request(.init(source: .decoderDrain, urgency: .urgent)) {
            observed.append(2)
        }
        for _ in 0..<100 where observed.count < 3 { await Task.yield() }
        #expect(observed == [0, 1, 2])
        #expect(coalescer.snapshot().scheduledDeliveries == 2)
    }

    @Test func invalidFrameRatesStayBounded() {
        for rate in [Double.nan, .infinity, -1, 0] {
            #expect(NativeSubtitleRenderPolicy.observationInterval(hasSubtitles: true, frameRate: rate).seconds == 1.0 / 30)
        }
        #expect(NativeSubtitleRenderPolicy.observationInterval(hasSubtitles: true, frameRate: 1).seconds == 1.0 / 24)
        #expect(NativeSubtitleRenderPolicy.observationInterval(hasSubtitles: true, frameRate: 1_000).seconds == 1.0 / 120)
        #expect(NativeSubtitleRenderPolicy.observationInterval(hasSubtitles: false, frameRate: 60).seconds == 0.25)
    }

    @Test @MainActor func pausedGeometryChangesRequestPresentationWithoutPolling() {
        let overlay = SubtitleOverlayView(frame: .init(x: 0, y: 0, width: 100, height: 80))
        var changes = 0
        overlay.onPresentationInvalidated = { changes += 1 }
        overlay.updateDrawableSize(backingScale: 1)
        let initialChanges = changes
        overlay.updateDrawableSize(backingScale: 1)
        #expect(changes == initialChanges)
        overlay.frame.size.width = 200
        overlay.updateDrawableSize(backingScale: 1)
        overlay.updateDrawableSize(backingScale: 2)
        #expect(changes == initialChanges + 2)
    }

    @Test @MainActor func pausedExposureCanRetryTheSameSubtitleTimestamp() async throws {
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true))
        let viewport = CGRect(x: 0, y: 0, width: 320, height: 180)
        _ = try pipeline.configure(codecPrivate: nil, codecName: "subrip", attachments: [],
                                   frameSize: viewport.size, storageSize: viewport.size)
        pipeline.process(event: .init(assData: Data("0,0,Default,,0,0,0,,Paused caption".utf8),
                                     presentationSeconds: 0, durationSeconds: 10, generation: 0))
        pipeline.render(at: .zero, viewport: viewport, videoSize: viewport.size)
        for _ in 0..<100 where pipeline.counters().overlayCommits < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pipeline.counters().overlayCommits == 1)
        pipeline.invalidatePresentationRequest()
        pipeline.render(at: .zero, viewport: viewport, videoSize: viewport.size)
        for _ in 0..<100 where pipeline.counters().overlayCommits < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pipeline.counters().overlayCommits == 2)
        #expect(pipeline.counters().libassFrames == 1)
    }
}
