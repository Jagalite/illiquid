import Foundation
import IlliquidCore
import IlliquidPlayback
import Testing
@testable import IlliquidNativePlayback

/// Plays real files through the runtime and renderer with processing on.
///
/// Set ILLIQUID_VIDEO_PROCESSING_FIXTURE_DIR to a directory holding 24 fps
/// clips about two seconds long:
///   ffmpeg -f lavfi -i testsrc2=size=640x360:rate=24 \
///     -f lavfi -i sine=frequency=440:sample_rate=48000 -t 2 -shortest \
///     -c:v libx264 -pix_fmt yuv420p -c:a aac film24-h264.mp4
///   (and the same with -c:v libx265 -pix_fmt yuv420p10le into film24-hevc10.mkv)
extension RealRendererPlayback {
    @Suite("Video frame processing playback", .serialized)
    struct VideoFrameProcessingPlaybackTests {
        private static var fixtureDirectory: URL? {
            ProcessInfo.processInfo.environment["ILLIQUID_VIDEO_PROCESSING_FIXTURE_DIR"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
        }

        @MainActor
        private func waitUntil(timeout: Duration, _ predicate: () -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if predicate() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return predicate()
        }

        @Test(arguments: [
            "film24-h264.mp4|interpolate",
            "film24-h264.mp4|transform",
            "film24-h264.mp4|transform+interpolate",
            "film24-hevc10.mkv|transform+interpolate",
        ])
        @MainActor
        func playsSeeksAndEndsWithProcessing(fixture: String) async throws {
            guard let directory = Self.fixtureDirectory else { return }
            let parts = fixture.split(separator: "|").map(String.init)
            let configuration = VideoFrameProcessingConfiguration(
                transform: parts[1].contains("transform")
                    ? VideoFrameTransform(outputSize: .scale(0.5), flipsHorizontally: true)
                    : nil,
                frameRateConversion: parts[1].contains("interpolate")
                    ? VideoFrameRateConversion(targetFrameRate: 60)
                    : nil
            )
            let expectsSynthesis = configuration.frameRateConversion != nil
            let backend = try NativePlaybackRuntime(videoFrameProcessing: configuration)
            _ = try backend.makeSurfaceHost()
            let source = MediaSource.localFile(directory.appendingPathComponent(parts[0]))
            let request = try #require(MediaLoadRequest(source: source, origin: .userSelected))
            try backend.load(PlaybackRuntimeLoadRequest(
                media: request, identity: PlayerSessionIdentity(source: source, generation: 1)
            ))
            #expect(await waitUntil(timeout: .seconds(5)) {
                backend.sessionSnapshotForDiagnostics?.isPrerolled == true
            })

            backend.play()
            #expect(await waitUntil(timeout: .seconds(10)) {
                guard let processing = backend.sessionSnapshotForDiagnostics?.videoProcessing else { return false }
                return expectsSynthesis ? processing.synthesizedFrames >= 10 : processing.outputFrames >= 10
            })
            let playing = try #require(backend.sessionSnapshotForDiagnostics)
            let processing = try #require(playing.videoProcessing)
            #expect(processing.bypassReason == nil)
            #expect(playing.rendererFailure == nil)
            #expect(playing.lastRecoveryFailure == nil)

            backend.pause()
            backend.seek(to: 0.5, mode: .absoluteExact)
            let generation = try #require(backend.sessionSnapshotForDiagnostics?.generation)
            #expect(await waitUntil(timeout: .seconds(5)) {
                guard let snapshot = backend.sessionSnapshotForDiagnostics else { return false }
                return snapshot.generation == generation && snapshot.isPrerolled
            })
            let seeked = try #require(backend.sessionSnapshotForDiagnostics)
            #expect((seeked.firstEnqueuedVideoPTS ?? 0) + 0.001 >= 0.5)
            #expect(seeked.rendererFailure == nil)

            backend.play()
            #expect(await waitUntil(timeout: .seconds(6)) {
                backend.sessionSnapshotForDiagnostics?.ended == true
            })
            let finished = try #require(backend.sessionSnapshotForDiagnostics)
            let summary = try #require(finished.videoProcessing)
            print("VIDEO_PROCESSING_PLAYBACK fixture=\(fixture) stages=\(summary.stageNames) "
                + "in=\(summary.inputFrames) out=\(summary.outputFrames) synthesized=\(summary.synthesizedFrames) "
                + "overruns=\(summary.overruns) suspended=\(summary.synthesisSuspended) "
                + "configure-ms=\(String(format: "%.1f", summary.configurationMilliseconds)) "
                + "last-ms=\(String(format: "%.2f", summary.lastProcessingMilliseconds)) "
                + "pixel-buffer=\(finished.pixelBufferFormat) hardware=\(finished.isHardwareDecoded) "
                + "submitted=\(finished.framesSubmitted) bypass=\(summary.bypassReason ?? "none")")
            #expect(summary.bypassReason == nil)
            #expect(finished.rendererFailure == nil)
            #expect(finished.lastRecoveryFailure == nil)
            await backend.shutdown()
        }
    }
}
