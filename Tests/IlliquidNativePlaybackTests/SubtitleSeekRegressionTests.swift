import Foundation
import CFFmpeg
import Testing
@testable import IlliquidNativePlayback

struct SubtitleSeekRegressionTests {
    @Test func seekRecoveryClearsOnlyThePreviousInterruption() {
        for code in [illiquid_averror_exit(), illiquid_averror_invaliddata(), illiquid_averror_eof(), Int32(-5)] {
            var input = AVIOContext()
            input.error = code
            input.eof_reached = 1
            FFmpegDemuxer.clearInterruptedReadState(&input)
            #expect(input.error == (code == illiquid_averror_exit() ? 0 : code))
            #expect(input.eof_reached == (code == illiquid_averror_exit() ? 0 : 1))
        }
    }

    @Test(arguments: ["seek", "disable", "stop"],
          [illiquid_averror_exit(), illiquid_averror_invaliddata()]) @MainActor
    func failedSubtitleReaderHonorsSeekDisableAndStop(action: String, errorCode: Int32) async throws {
        final class Probe: @unchecked Sendable {
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let errorCode: Int32
            private let lock = NSLock()
            private var generations: [Int] = []
            private var failures = 0
            init(errorCode: Int32) { self.errorCode = errorCode }
            func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 2) == .success }
            func read(_ generation: Int) throws -> FFmpegPacket? {
                let first = lock.withLock {
                    generations.append(generation)
                    return generations.count == 1
                }
                if first {
                    started.signal()
                    _ = release.wait(timeout: .now() + 3)
                    throw FFmpegError(operation: "Read media packet", code: errorCode)
                }
                return nil
            }
            func failed() { lock.withLock { failures += 1 } }
            var snapshot: ([Int], Int) { lock.withLock { (generations, failures) } }
        }
        let probe = Probe(errorCode: errorCode)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-seek-\(UUID()).srt")
        try "1\n00:00:00,000 --> 00:00:05,000\nA valid subtitle\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let presentation = try NativePresentationCoordinator()
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        let session = try MediaSession(url: url, presentation: presentation, subtitles: pipeline,
            selectedSubtitleIndex: 0, onFailureObserved: { _ in probe.failed() },
            subtitlePacketReader: { try probe.read($0) })
        defer {
            probe.release.signal()
            session.stop()
            #expect(session.waitForShutdown(timeout: .now() + 3))
            pipeline.terminate()
            presentation.terminate()
        }
        session.start(rate: 0)
        let started = await Task.detached { probe.waitUntilStarted() }.value
        try #require(started)
        let generation: Int?
        switch action {
        case "seek": generation = session.seek(to: 2, exact: true, resumeRate: 0)
        case "disable":
            generation = nil
            #expect(session.disableSubtitleTrackAfterFailure())
        default:
            generation = nil
            session.stop()
        }
        probe.release.signal()
        if let generation {
            let deadline = ContinuousClock.now + .seconds(2)
            while probe.snapshot.0.count < 2, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(probe.snapshot.0 == [0, generation])
        } else {
            // Joining proves the reader has handled its cancellation before
            // checking callbacks, without relying on a fixed sleep.
            session.stop()
            #expect(session.waitForShutdown(timeout: .now() + 3))
            #expect(probe.snapshot.0 == [0])
        }
        #expect(probe.snapshot.1 == 0)
    }

    @Test @MainActor
    func persistentSubtitleReadErrorsStopInsteadOfSpinning() async throws {
        final class ReadProbe: @unchecked Sendable {
            private let lock = NSLock()
            private var reads = 0
            private var failures = 0
            func read() { lock.withLock { reads += 1 } }
            func failed() { lock.withLock { failures += 1 } }
            var snapshot: (reads: Int, failures: Int) { lock.withLock { (reads, failures) } }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-error-\(UUID()).srt")
        try "1\n00:00:00,000 --> 00:00:05,000\nA valid subtitle\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        for code in [illiquid_averror_invaliddata(), illiquid_averror_exit()] {
            let probe = ReadProbe()
            let presentation = try NativePresentationCoordinator()
            let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
            let session = try MediaSession(url: url, presentation: presentation, subtitles: pipeline,
                selectedSubtitleIndex: 0, onFailureObserved: { _ in probe.failed() },
                subtitlePacketReader: { _ in
                    probe.read()
                    throw FFmpegError(operation: "Read media packet", code: code)
                })
            session.start(rate: 0)
            let deadline = ContinuousClock.now + .milliseconds(250)
            while probe.snapshot.failures == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            session.stop()
            #expect(session.waitForShutdown(timeout: .now() + 3))
            let result = probe.snapshot
            print("subtitle-read-error code=\(code) reads=\(result.reads) failures=\(result.failures)")
            #expect(result.reads == 1)
            #expect(result.failures == 1)
            pipeline.terminate()
            presentation.terminate()
        }
    }

    @Test func cancelledSubtitleReadCanSeekAndReadAgain() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-cancel-\(UUID()).srt")
        let text = (0..<200).map { i in
            "\(i + 1)\n00:\(String(format: "%02d", i / 60)):\(String(format: "%02d", i % 60)),000 --> 00:\(String(format: "%02d", (i + 1) / 60)):\(String(format: "%02d", (i + 1) % 60)),000\nCue \(i)\n"
        }.joined(separator: "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let input = try FFmpegInputExecutor(url: url)
        for generation in 1...20 {
            _ = input.cancelActiveOperation()
            do { _ = try input.readPacket(generation: generation - 1) }
            catch let error as FFmpegError { #expect(error.isInterrupted) }
            try input.seek(to: Double(generation), exact: true)
            #expect(try input.readPacket(generation: generation) != nil)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_SUBTITLE_REGRESSION_MEDIA"] != nil))
    func realMediaTextSubtitleSeeksRemainUsable() throws {
        let path = try #require(ProcessInfo.processInfo.environment["ILLIQUID_SUBTITLE_REGRESSION_MEDIA"])
        let input = try FFmpegDemuxer(url: URL(fileURLWithPath: path))
        let stream = try #require(input.mediaInfo.subtitleStreams.first)
        for target in [41.815176, 172.469333, 0, 300, 600, 1200, 41.815176] {
            _ = try input.activeSubtitlePackets(streamIndex: stream.index, at: target, generation: 0)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_SUBTITLE_REGRESSION_MEDIA"] != nil))
    func realMediaCancelledSubtitleReadsRecover() throws {
        let path = try #require(ProcessInfo.processInfo.environment["ILLIQUID_SUBTITLE_REGRESSION_MEDIA"])
        let input = try FFmpegInputExecutor(url: URL(fileURLWithPath: path))
        let stream = try #require(input.mediaInfo.subtitleStreams.first)
        for (generation, target) in [41.815176, 172.469333, 0, 300, 600, 1200, 41.815176].enumerated() {
            _ = input.cancelActiveOperation()
            do { _ = try input.readPacket(generation: generation) }
            catch let error as FFmpegError { #expect(error.isInterrupted) }
            _ = try input.activeSubtitlePackets(streamIndex: stream.index, at: target, generation: generation + 1)
            try input.seek(to: target, exact: true)
            for _ in 0..<100 {
                if try input.readPacket(generation: generation + 1) == nil { break }
            }
        }
    }
}
