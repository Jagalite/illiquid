import CoreMedia
import Foundation
import Testing
import SuperplayrCore
import SuperplayrPlayback
@testable import SuperplayrNativePlayback

@Suite("Signed audio delay", .serialized)
struct AudioDelayTests {
    private func frame(time: Double = 0, samples: Int = 480, generation: Int = 4) -> NativeDecodedAudioFrame {
        let values = (0..<samples).flatMap { [Float($0 + 1), -Float($0 + 1)] }
        let data = values.withUnsafeBytes { Data($0) }
        return NativeDecodedAudioFrame(interleavedFloatPCM: data,
            presentationTime: CMTime(seconds: time, preferredTimescale: 48_000),
            duration: CMTime(value: Int64(samples), timescale: 48_000), generation: generation,
            sampleRate: 48_000, channelCount: 2, sampleCount: samples,
            sourceSampleRate: 48_000, sourceChannelCount: 2, sourceChannelLayout: "stereo",
            downmixOccurred: false, conversionOccurred: false, formatRevision: 7)
    }

    @Test func positiveDelayAddsBoundedSilenceWithoutChangingSamples() {
        let source = frame()
        var timeline = AudioDelayTimeline(delay: 0.1)
        var output: [NativeDecodedAudioFrame] = []
        #expect(timeline.consume(source) { output.append($0); return true })
        #expect(output.dropLast().reduce(0) { $0 + $1.sampleCount } == 4_800)
        #expect(output.dropLast().allSatisfy { $0.sampleCount <= 1_024 && $0.interleavedFloatPCM.allSatisfy { $0 == 0 } })
        #expect(output.allSatisfy { $0.generation == 4 && $0.formatRevision == 7 })
        #expect(output.last?.interleavedFloatPCM == source.interleavedFloatPCM)
        #expect(abs((output.last?.presentationTime.seconds ?? 0) - 0.1) < 0.000001)
    }

    @Test func negativeDelayTrimsAtSampleBoundaryAndPadsExhaustedTail() {
        var timeline = AudioDelayTimeline(delay: -0.005)
        let source = frame()
        var output: [NativeDecodedAudioFrame] = []
        #expect(timeline.consume(source) { output.append($0); return true })
        #expect(output.count == 1)
        #expect(output.first?.sampleCount == 240)
        #expect(output.first?.presentationTime == .zero)
        #expect(output.first?.interleavedFloatPCM == Data(source.interleavedFloatPCM.dropFirst(240 * 8)))
        #expect(timeline.finish(duration: 0.01, fallback: source) { output.append($0); return true })
        #expect(output.last?.sampleCount == 240)
        #expect(output.last?.interleavedFloatPCM.allSatisfy { $0 == 0 } == true)
        #expect(abs(timeline.cursor - 0.01) < 0.000001)
    }

    @Test func seekUsesMappedSourceSamplesAndCancelsLargeSilence() {
        var timeline = AudioDelayTimeline(delay: 2, target: 5)
        var output: [NativeDecodedAudioFrame] = []
        #expect(timeline.consume(frame(time: 2)) { output.append($0); return true })
        #expect(output.isEmpty)
        #expect(timeline.consume(frame(time: 3)) { output.append($0); return true })
        #expect(output.first?.presentationTime.seconds == 5)
        var initial = AudioDelayTimeline(delay: 10)
        var calls = 0
        #expect(!initial.consume(frame()) { _ in calls += 1; return calls < 3 })
        #expect(calls == 3)
        #expect(AudioDelayTimeline.bounded(.nan) == 0)
        #expect(AudioDelayTimeline.bounded(100) == 10)
        #expect(AudioDelayTimeline.bounded(-100) == -10)
    }

    @Test @MainActor func extremeOffsetsPrepareSeekAndReleaseWithoutVideoBackpressure() async throws {
        guard let root = ProcessInfo.processInfo.environment["SUPERPLAYR_NATIVE_FIXTURE_DIR"] else { return }
        let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("h264-aac.mp4")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        for delay in [-10.0, -0.2, 0.2, 10.0] {
            let presentation = try NativePresentationCoordinator()
            presentation.setVolume(0, muted: true)
            let subtitles = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
            let session = try MediaSession(url: url, presentation: presentation, subtitles: subtitles,
                                           audioDelay: delay, preferHardware: false)
            defer { session.stop(); _ = session.waitForShutdown(timeout: .now() + 3); subtitles.terminate(); presentation.terminate() }
            #expect(session.prepareForCommit())
            let ready = await waitUntil { session.isPreparedForCommit }
            #expect(ready)
            if ready {
                #expect(session.commitPrepared(rate: 0))
                _ = session.seek(to: 1, exact: true, resumeRate: 0)
                #expect(await waitUntil { !session.seekInProgress })
                #expect(session.snapshot().rendererFailure == nil)
            }
            session.stop()
            #expect(session.waitForShutdown(timeout: .now() + 3))
        }
    }

    @Test @MainActor func runtimeDelayReplacementPublishesCommittedValueAndStopWins() async throws {
        guard let root = ProcessInfo.processInfo.environment["SUPERPLAYR_NATIVE_FIXTURE_DIR"] else { return }
        let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("h264-aac.mp4")
        let backend = try NativePlaybackRuntime()
        var observed: [Double] = []
        backend.eventHandler = { event in
            if case let .audioDelayChanged(value) = event.payload { observed.append(value) }
        }
        _ = try backend.makeSurfaceHost()
        backend.setVolume(0)
        let source = MediaSource.localFile(url)
        let request = try #require(MediaLoadRequest(source: source, origin: .userSelected))
        try backend.load(PlaybackRuntimeLoadRequest(media: request,
            identity: PlayerSessionIdentity(source: source, generation: 1)))
        #expect(await waitUntil { backend.sessionSnapshotForDiagnostics?.isPrerolled == true })
        backend.setAudioDelay(-0.25)
        #expect(await waitUntil { observed.last == -0.25 })
        backend.setAudioDelay(10)
        backend.setAudioDelay(0)
        #expect(await waitUntil { observed.last == 0 })
        backend.setAudioDelay(1)
        backend.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(backend.sessionSnapshotForDiagnostics == nil)
        await backend.shutdown()
    }

    @MainActor private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}
