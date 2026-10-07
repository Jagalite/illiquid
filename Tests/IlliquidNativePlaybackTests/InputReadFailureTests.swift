import CFFmpeg
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Input read failure bounds", .serialized)
struct InputReadFailureTests {
    private final class Probe: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let blocksFirst: Bool
        let code: Int32
        private let lock = NSLock()
        private var reads: [Int] = []
        private var failures = 0
        init(code: Int32, blocksFirst: Bool = false) {
            self.code = code; self.blocksFirst = blocksFirst
        }
        func read(_ generation: Int) throws -> FFmpegPacket? {
            let first = lock.withLock { reads.append(generation); return reads.count == 1 }
            if first {
                started.signal()
                if blocksFirst { _ = release.wait(timeout: .now() + 5) }
            }
            if blocksFirst && !first { return nil }
            throw FFmpegError(operation: "Injected input read", code: code)
        }
        func awaitStart() -> Bool { started.wait(timeout: .now() + 3) == .success }
        func failed() { lock.withLock { failures += 1 } }
        var snapshot: (reads: [Int], failures: Int) { lock.withLock { (reads, failures) } }
    }

    @Test(arguments: ["demux", "fair", "delayedAudio"],
          [illiquid_averror_exit(), illiquid_averror_invaliddata()]) @MainActor
    func persistentReadFailureTerminates(loop: String, code: Int32) async throws {
        let url = try makeWave()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = Probe(code: code)
        let presentation = try NativePresentationCoordinator()
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        let session = try makeSession(url, loop: loop, probe: probe, presentation: presentation, pipeline: pipeline)
        defer { session.stop(); _ = session.waitForShutdown(); pipeline.terminate(); presentation.terminate() }
        session.start(rate: 0)
        let deadline = ContinuousClock.now + .milliseconds(150)
        while probe.snapshot.failures == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        session.stop()
        #expect(session.waitForShutdown())
        let result = probe.snapshot
        print("input-failure loop=\(loop) code=\(code) reads=\(result.reads.count) failures=\(result.failures)")
        #expect(result.reads.count == 1)
        #expect(result.failures == 1)
    }

    @Test(arguments: ["demux", "fair", "delayedAudio"],
          [illiquid_averror_exit(), illiquid_averror_invaliddata()]) @MainActor
    func supersededReadReachesNewGeneration(loop: String, code: Int32) async throws {
        let url = try makeWave()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = Probe(code: code, blocksFirst: true)
        let presentation = try NativePresentationCoordinator()
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        let session = try makeSession(url, loop: loop, probe: probe, presentation: presentation, pipeline: pipeline)
        defer { probe.release.signal(); session.stop(); _ = session.waitForShutdown(); pipeline.terminate(); presentation.terminate() }
        session.start(rate: 0)
        let started = await Task.detached { probe.awaitStart() }.value
        try #require(started)
        let next = session.seek(to: 0.25, exact: true, resumeRate: 0)
        probe.release.signal()
        let deadline = ContinuousClock.now + .seconds(2)
        while probe.snapshot.reads.count < 2, probe.snapshot.failures == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        session.stop()
        #expect(session.waitForShutdown())
        #expect(probe.snapshot.reads == [0, next])
        #expect(probe.snapshot.failures == 0)
    }

    @Test(arguments: ["demux", "fair", "delayedAudio"]) @MainActor
    func stoppedReadDoesNotReportFailure(loop: String) async throws {
        let url = try makeWave()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = Probe(code: illiquid_averror_exit(), blocksFirst: true)
        let presentation = try NativePresentationCoordinator()
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        let session = try makeSession(url, loop: loop, probe: probe, presentation: presentation, pipeline: pipeline)
        defer { probe.release.signal(); session.stop(); _ = session.waitForShutdown(); pipeline.terminate(); presentation.terminate() }
        session.start(rate: 0)
        let started = await Task.detached { probe.awaitStart() }.value
        try #require(started)
        session.stop()
        probe.release.signal()
        #expect(session.waitForShutdown())
        #expect(probe.snapshot.reads == [0])
        #expect(probe.snapshot.failures == 0)
    }

    @MainActor private func makeSession(_ url: URL, loop: String, probe: Probe,
        presentation: NativePresentationCoordinator, pipeline: SubtitlePipeline) throws -> MediaSession {
        let reader: @Sendable (Int) throws -> FFmpegPacket? = { try probe.read($0) }
        return try MediaSession(url: url, presentation: presentation, subtitles: pipeline,
            audioDelay: loop == "delayedAudio" ? 0.1 : 0,
            usesFairDemuxDispatch: loop == "fair", onFailureObserved: { _ in probe.failed() },
            demuxPacketReader: loop == "delayedAudio" ? nil : reader,
            delayedAudioPacketReader: loop == "delayedAudio" ? reader : nil)
    }

    private func makeWave() throws -> URL {
        var bytes = Data()
        func text(_ value: String) { bytes.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        text("RIFF"); integer(UInt32(96_036)); text("WAVEfmt "); integer(UInt32(16))
        integer(UInt16(1)); integer(UInt16(1)); integer(UInt32(48_000)); integer(UInt32(96_000))
        integer(UInt16(2)); integer(UInt16(16)); text("data"); integer(UInt32(96_000))
        bytes.append(Data(repeating: 0, count: 96_000))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("input-failure-\(UUID()).wav")
        try bytes.write(to: url)
        return url
    }
}
