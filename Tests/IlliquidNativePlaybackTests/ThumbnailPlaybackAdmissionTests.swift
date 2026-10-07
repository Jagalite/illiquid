import CoreGraphics
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Playback takes priority over thumbnail decoding", .serialized)
struct ThumbnailPlaybackAdmissionTests {
    private static func wait(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 5) == .success
    }
    private func image() throws -> CGImage {
        try #require(CGContext(data: nil, width: 2, height: 2,
            bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
    }

    @Test func suspensionCancelsActiveAndPendingButRetainsNativeOwnership() async throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let expected = try image()
        let worker = TimelineThumbnailWorker(requestTimeout: 10) { input, signal in
            if input.seconds == 0 {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
                #expect(signal.cancellationRequested)
            }
            return expected
        }
        let url = URL(fileURLWithPath: "/unused.mkv"), size = CGSize(width: 2, height: 2)
        let active = Task { await worker.image(for: .init(url: url, seconds: 0, size: size)) }
        #expect(await Task.detached { Self.wait(entered) }.value)
        let pending = Task { await worker.image(for: .init(url: url, seconds: 1, size: size)) }
        for _ in 0..<500 where worker.pendingPosition != 1 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(worker.pendingPosition == 1)
        worker.setDecodingSuspended(true)
        #expect(await active.value == nil)
        #expect(await pending.value == nil)
        #expect(await worker.image(for: .init(url: url, seconds: 2, size: size)) == nil)
        worker.setDecodingSuspended(false)
        let resumed = Task { await worker.image(for: .init(url: url, seconds: 3, size: size)) }
        for _ in 0..<500 where worker.pendingPosition != 3 { try await Task.sleep(for: .milliseconds(2)) }
        // A resumed request must queue until the cancelled native call returns.
        #expect(worker.pendingPosition == 3)
        release.signal()
        #expect(await resumed.value === expected)
    }

    @Test func oldAdmissionCannotReviveAfterSeekFinishes() async throws {
        let expected = try image()
        let worker = TimelineThumbnailWorker { _, _ in expected }
        let oldRevision = worker.currentAdmissionRevision
        worker.setDecodingSuspended(false)
        #expect(worker.currentAdmissionRevision == oldRevision)
        worker.setDecodingSuspended(true)
        worker.setDecodingSuspended(false)
        var input = TimelineThumbnailWorker.Input(url: URL(fileURLWithPath: "/unused.mkv"),
            seconds: 0, size: CGSize(width: 2, height: 2), admissionRevision: oldRevision)
        #expect(await worker.image(for: input) == nil)
        input.admissionRevision = worker.currentAdmissionRevision
        #expect(await worker.image(for: input) === expected)
    }

    @Test func suspensionInterruptsAnActiveDecodeWithoutAReplacementRequest() async {
        let entered = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let worker = TimelineThumbnailWorker(requestTimeout: 10) { _, signal in
            let token = signal.register { cancelled.signal() }
            defer { signal.unregister(token) }
            entered.signal()
            _ = Self.wait(release)
            return nil
        }
        let request = Task { await worker.image(for: .init(url: URL(fileURLWithPath: "/unused.mkv"),
            seconds: 0, size: CGSize(width: 2, height: 2))) }
        #expect(await Task.detached { Self.wait(entered) }.value)
        worker.setDecodingSuspended(true)
        #expect(await Task.detached { Self.wait(cancelled) }.value)
        #expect(await request.value == nil)
    }

    @Test func cachedImagesRemainAvailableDuringPlaybackRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.mkv")
        try Data([0]).write(to: url)
        let expected = try image()
        let generator = NativeTimelineThumbnailGenerator(cacheDirectory: directory.appendingPathComponent("cache"),
            worker: TimelineThumbnailWorker { _, _ in expected })
        let size = CGSize(width: 2, height: 2)
        #expect(await generator.thumbnail(for: url, at: 0, maximumPixelSize: size) != nil)
        generator.setDecodingSuspended(true)
        #expect(await generator.thumbnail(for: url, at: 0, maximumPixelSize: size) != nil)
        #expect(await generator.thumbnail(for: url, at: 5, maximumPixelSize: size) == nil)
        generator.setDecodingSuspended(false)
        #expect(await generator.thumbnail(for: url, at: 5, maximumPixelSize: size) != nil)
    }
}
