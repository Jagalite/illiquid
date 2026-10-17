import CoreGraphics
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Thumbnail completion deadlines")
struct ThumbnailDeadlineCompletionTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        func read() -> ContinuousClock.Instant { lock.withLock { instant } }
        func advance(seconds: Int) {
            lock.withLock { instant = instant.advanced(by: .seconds(seconds)) }
        }
    }

    @Test(arguments: [0, 60, 61])
    func metadataCompletionChecksTimeWithoutWaitingForTimer(_ elapsed: Int) async {
        let clock = Clock()
        // The real timer is a minute away. Advancing the injected monotonic
        // clock simulates its callback being delayed without a timing race.
        let reader = ThumbnailBlockingReader<Int>(timeout: 60, now: { clock.read() })
        let result = await reader.read {
            clock.advance(seconds: elapsed)
            return 7
        }
        #expect(result == (elapsed < 60 ? 7 : nil))
        // Rejecting an expired result must still release physical admission.
        #expect(await reader.read { 8 } == 8)
    }

    @Test(arguments: [0, 60, 61])
    func decodeCompletionChecksTimeWithoutWaitingForTimer(_ elapsed: Int) async throws {
        let clock = Clock()
        let expected = try makeImage()
        let worker = TimelineThumbnailWorker(requestTimeout: 60, now: { clock.read() }) { input, _ in
            if input.seconds == 1 { clock.advance(seconds: elapsed) }
            return expected
        }
        let result = await worker.image(for: input(1))
        if elapsed < 60 { #expect(result === expected) }
        else { #expect(result == nil) }
        // Each later request receives its own deadline, not the expired one.
        #expect(await worker.image(for: input(2)) === expected)
    }

    @Test func expiredPendingRequestDoesNotStartNativeDecode() async throws {
        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Double] = []
            func append(_ value: Double) { lock.withLock { values.append(value) } }
            var snapshot: [Double] { lock.withLock { values } }
        }
        let clock = Clock(), calls = Calls()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let worker = TimelineThumbnailWorker(requestTimeout: 60, now: { clock.read() }) { input, _ in
            calls.append(input.seconds)
            if input.seconds == 1 {
                started.signal()
                release.wait()
            }
            return nil
        }
        defer { release.signal(); worker.cancelAll() }
        let first = Task { await worker.image(for: input(1)) }
        let didStart = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: started.wait(timeout: .now() + 3) == .success)
            }
        }
        try #require(didStart)
        let pending = Task { await worker.image(for: input(2)) }
        let deadline = ContinuousClock.now + .seconds(3)
        while worker.pendingPosition != 2, ContinuousClock.now < deadline { await Task.yield() }
        try #require(worker.pendingPosition == 2)
        clock.advance(seconds: 61)
        release.signal()
        #expect(await first.value == nil)
        #expect(await pending.value == nil)
        #expect(calls.snapshot == [1])
    }

    private func input(_ seconds: Double) -> TimelineThumbnailWorker.Input {
        .init(url: URL(fileURLWithPath: "/tmp/thumbnail-deadline.mkv"), seconds: seconds,
              size: CGSize(width: 2, height: 2))
    }

    private func makeImage() throws -> CGImage {
        try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
    }
}
