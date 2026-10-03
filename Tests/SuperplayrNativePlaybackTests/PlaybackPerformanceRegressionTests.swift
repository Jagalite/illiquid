import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import SuperplayrNativePlayback

@Suite("Playback performance boundaries")
struct PlaybackPerformanceRegressionTests {
    @Test func expiredThumbnailCanRecoverAfterTheBlockedNativeCallReturns() async throws {
        let expected = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let worker = TimelineThumbnailWorker { input, _ in
            if input.seconds == 1 {
                started.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            return expected
        }
        func input(_ position: Double) -> TimelineThumbnailWorker.Input {
            .init(url: URL(fileURLWithPath: "/tmp/thumbnail-recovery.mkv"), seconds: position,
                size: CGSize(width: 320, height: 180))
        }
        let expired = Task { await worker.image(for: input(1)) }
        #expect(await Task.detached { Self.wait(started) }.value)
        // Let the real caller deadline expire while native ownership is held.
        #expect(await expired.value == nil)
        let retry = Task { await worker.image(for: input(2)) }
        await waitForPending(worker, position: 2)
        release.signal()
        #expect(await retry.value === expected)
    }

    @Test func thumbnailInvalidationRetainsThePhysicalSlotUntilNativeReturns() async {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let worker = TimelineThumbnailWorker { input, _ in
            if input.seconds == 1 {
                started.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            return nil
        }
        func input(_ seconds: Double) -> TimelineThumbnailWorker.Input {
            .init(url: URL(fileURLWithPath: "/tmp/retired-thumbnail.mkv"), seconds: seconds,
                  size: CGSize(width: 320, height: 180))
        }
        let first = Task { await worker.image(for: input(1)) }
        #expect(await Task.detached { Self.wait(started) }.value)
        let oldPending = Task { await worker.image(for: input(2)) }
        await waitForPending(worker, position: 2)
        worker.cancelAll()
        #expect(await first.value == nil)
        #expect(await oldPending.value == nil)
        let newPending = Task { await worker.image(for: input(3)) }
        await waitForPending(worker, position: 3)
        release.signal()
        #expect(await newPending.value == nil)
    }

    @Test func pendingThumbnailDeadlineIncludesTimeBehindBlockedDecode() async {
        final class Completion: @unchecked Sendable {
            private let lock = NSLock()
            private var finished = false
            var isFinished: Bool { lock.withLock { finished } }
            func finish() { lock.withLock { finished = true } }
        }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completion = Completion()
        let worker = TimelineThumbnailWorker { input, _ in
            if input.seconds == 1 {
                started.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            return nil
        }
        func input(_ seconds: Double) -> TimelineThumbnailWorker.Input {
            .init(url: URL(fileURLWithPath: "/tmp/blocked-thumbnail.mkv"), seconds: seconds,
                  size: CGSize(width: 320, height: 180))
        }
        let first = Task { await worker.image(for: input(1)) }
        #expect(await Task.detached { Self.wait(started) }.value)
        let pending = Task {
            _ = await worker.image(for: input(2))
            completion.finish()
        }
        await waitForPending(worker, position: 2)
        let deadline = ContinuousClock.now + .seconds(2)
        while !completion.isFinished, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(completion.isFinished, "Pending caller must expire while the active C call still owns the worker")
        release.signal()
        _ = await first.value
        await pending.value
    }

    @Test func seekTimingsKeepFirstEvidenceAndRejectRetiredGenerations() {
        var timings = SeekPerformanceTimings(generation: 3, requestedUptime: 10)
        timings.record(.demuxStarted, generation: 2, at: 11)
        timings.record(.demuxStarted, generation: 3, at: 9)
        #expect(timings.milliseconds.isEmpty)
        timings.record(.demuxStarted, generation: 3, at: 10.25)
        timings.record(.demuxStarted, generation: 3, at: 11)
        #expect(timings.milliseconds[.demuxStarted] == 250)
        #expect(timings.milliseconds[.videoEnqueued] == nil)
        #expect(timings.summary.contains("videoEnqueued-ms=unobserved"))
    }

    @Test func thumbnailRejectsNonrepresentableTimesAndSizesWithoutTrapping() async {
        let generator = NativeTimelineThumbnailGenerator()
        let url = URL(fileURLWithPath: "/tmp/unused-thumbnail-input.mp4")
        for seconds in [Double.infinity, .nan, .greatestFiniteMagnitude, -1] {
            #expect(await generator.thumbnail(
                for: url, at: seconds, maximumPixelSize: CGSize(width: 320, height: 180)
            ) == nil)
        }
        for width in [CGFloat.infinity, .nan, .greatestFiniteMagnitude, 0, -1, 0.1] {
            #expect(await generator.thumbnail(
                for: url, at: 0, maximumPixelSize: CGSize(width: width, height: 180)
            ) == nil)
            #expect(await generator.thumbnail(
                for: url, at: 0, maximumPixelSize: CGSize(width: 320, height: width)
            ) == nil)
        }
    }

    private static func wait(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 2) == .success
    }

    @Test @MainActor func prunedEmbeddedCuesCanBeDecodedAgainAfterSeekingBackward() throws {
        let pipeline = try SubtitlePipeline(
            overlay: SubtitleOverlayView(), presentsOverlay: false, deduplicatesPackets: true
        )
        let size = CGSize(width: 640, height: 360)
        _ = try pipeline.configure(codecPrivate: nil, codecName: "subrip", attachments: [],
                                   frameSize: size, storageSize: size)
        let first = NativeDecodedSubtitleEvent(
            assData: Data("0,0,Default,,0,0,0,,First cue".utf8),
            presentationSeconds: 0, durationSeconds: 1, generation: 0
        )
        pipeline.process(event: first)
        pipeline.process(event: NativeDecodedSubtitleEvent(
            assData: Data("1,0,Default,,0,0,0,,Future cue".utf8),
            presentationSeconds: 100, durationSeconds: 1, generation: 0
        ))
        func hasCue(_ seconds: Double) -> Bool {
            !pipeline.renderedRegions(at: CMTime(seconds: seconds, preferredTimescale: 1000),
                                      viewport: CGRect(origin: .zero, size: size), videoSize: size).isEmpty
        }
        #expect(hasCue(0.5))
        pipeline.pruneEmbeddedEvents(before: 50)
        pipeline.clear() // The seek clears the visible render cache.
        #expect(!hasCue(0.5))
        #expect(hasCue(100.5))
        pipeline.process(event: first)
        #expect(hasCue(0.5))
    }
    @Test func ringBufferWrapsPrependsAndReleasesRemovedEntries() {
        final class Value {}
        var ring = FixedRingBuffer<Value>(capacity: 3)
        var first: Value? = Value()
        weak var released = first
        ring.append(first!)
        first = nil
        ring.append(Value())
        _ = ring.removeFirst()
        #expect(released == nil)
        let tail = Value()
        let head = Value()
        ring.append(tail)
        _ = ring.removeFirst()
        ring.prepend(head)
        #expect(ring.removeFirst() === head)
        #expect(ring.removeFirst() === tail)
        ring.append(Value())
        ring.removeAll()
        #expect(ring.isEmpty)
    }

    @Test func subtitleReaderWaitsForProgressAndSeekInvalidatesOldRead() {
        let gate = MediaReadAheadGate(lookahead: 10)
        let completion = DispatchSemaphore(value: 0)
        DispatchQueue(label: "test.readahead").async {
            #expect(gate.wait(until: 40, generation: 0))
            completion.signal()
        }
        #expect(gate.waitForBlockedReader(timeout: 2))
        gate.update(position: 30)
        #expect(completion.wait(timeout: .now() + 2) == .success)
        DispatchQueue(label: "test.eof").async {
            #expect(!gate.wait(until: nil, generation: 0))
            completion.signal()
        }
        #expect(gate.waitForBlockedReader(timeout: 2))
        gate.reset(generation: 1, position: 5)
        #expect(completion.wait(timeout: .now() + 2) == .success)
        #expect(gate.wait(until: 15, generation: 1))
    }

    @Test func closingReadAheadWakesBlockedInput() {
        let gate = MediaReadAheadGate()
        let completion = DispatchSemaphore(value: 0)
        DispatchQueue(label: "test.close").async {
            #expect(!gate.wait(until: nil, generation: 0))
            completion.signal()
        }
        #expect(gate.waitForBlockedReader(timeout: 2))
        gate.close()
        #expect(completion.wait(timeout: .now() + 2) == .success)
    }

    @Test func thumbnailWorkerKeepsOneActiveAndOnlyTheLatestPendingRequest() async {
        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            var values: [Double] = []
            func append(_ value: Double) { lock.withLock { values.append(value) } }
            var snapshot: [Double] { lock.withLock { values } }
        }
        let calls = Calls()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let worker = TimelineThumbnailWorker { input, _ in
            calls.append(input.seconds)
            if input.seconds == 1 {
                started.signal()
                // Simulate a C call that has not returned after cancellation.
                _ = release.wait(timeout: .now() + 3)
            }
            return nil
        }
        func input(_ seconds: Double) -> TimelineThumbnailWorker.Input {
            .init(url: URL(fileURLWithPath: "/tmp/video.mkv"), seconds: seconds,
                  size: CGSize(width: 320, height: 180))
        }
        let first = Task { await worker.image(for: input(1)) }
        // Blocking here would prevent first from starting on a serial executor.
        #expect(await Task.detached { Self.wait(started) }.value)
        let second = Task { await worker.image(for: input(2)) }
        await waitForPending(worker, position: 2)
        let third = Task { await worker.image(for: input(3)) }
        await waitForPending(worker, position: 3)
        #expect(await first.value == nil)
        #expect(await second.value == nil)
        #expect(calls.snapshot == [1])
        release.signal()
        _ = await third.value
        #expect(calls.snapshot == [1, 3])
    }

    private func waitForPending(_ worker: TimelineThumbnailWorker, position: Double) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while worker.pendingPosition != position, clock.now < deadline { await Task.yield() }
        #expect(worker.pendingPosition == position)
    }
}
