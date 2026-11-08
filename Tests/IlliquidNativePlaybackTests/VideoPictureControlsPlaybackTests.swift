import AVFoundation
import Foundation
import IlliquidCore
import IlliquidPlayback
import IlliquidPlaybackModel
import Testing
@testable import IlliquidNativePlayback

/// Drives the live picture controls (equalizer, filters, rotation) through the
/// real runtime and renderer, while playing and while paused.
///
/// Uses the same fixtures as `VideoFrameProcessingPlaybackTests`: set
/// ILLIQUID_VIDEO_PROCESSING_FIXTURE_DIR to a directory holding
/// film24-h264.mp4 (2 s, 24 fps, 640x360).
extension RealRendererPlayback {
    @Suite("Video picture controls playback", .serialized)
    struct VideoPictureControlsPlaybackTests {
        private static let frameDuration = 1.0 / 24
        private static let sourceSize = CGSize(width: 640, height: 360)

        private static var fixture: URL? {
            ProcessInfo.processInfo.environment["ILLIQUID_VIDEO_PROCESSING_FIXTURE_DIR"].map {
                URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("film24-h264.mp4")
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

        @MainActor
        private func load(_ backend: NativePlaybackRuntime, _ url: URL) async throws {
            let source = MediaSource.localFile(url)
            let request = try #require(MediaLoadRequest(source: source, origin: .userSelected))
            try backend.load(PlaybackRuntimeLoadRequest(
                media: request, identity: PlayerSessionIdentity(source: source, generation: 1)
            ))
            #expect(await waitUntil(timeout: .seconds(5)) {
                backend.sessionSnapshotForDiagnostics?.isPrerolled == true
            })
        }

        /// Paused, no seek in flight, prerolled, and no renderer failure. Does
        /// not look at the displayed pixel buffer: without a window on screen
        /// the renderer never reports one in tests.
        @MainActor
        private func isSettledWhilePaused(_ backend: NativePlaybackRuntime) -> Bool {
            guard let snapshot = backend.sessionSnapshotForDiagnostics else { return false }
            let readback = backend.pausedReadbackDiagnostic()
            return readback.rendererRate == 0 && !readback.seekInProgress
                && snapshot.isPrerolled && snapshot.rendererFailure == nil
        }

        /// Settled twice, 200 ms apart, at the same generation: a refresh queued
        /// behind another starts only when that one completes.
        @MainActor
        private func waitUntilStablyPaused(_ backend: NativePlaybackRuntime) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(6))
            while clock.now < deadline {
                guard await waitUntil(timeout: .seconds(3), { isSettledWhilePaused(backend) }) else {
                    return false
                }
                let generation = backend.sessionSnapshotForDiagnostics?.generation
                try? await Task.sleep(for: .milliseconds(200))
                if isSettledWhilePaused(backend),
                   backend.sessionSnapshotForDiagnostics?.generation == generation {
                    return true
                }
            }
            return false
        }

        @MainActor
        private func expectNoFailures(_ snapshot: MediaSessionSnapshot?, _ phase: String) {
            #expect(snapshot?.rendererFailure == nil, "\(phase): renderer failure")
            #expect(snapshot?.lastRecoveryFailure == nil, "\(phase): recovery failure")
            #expect(snapshot?.videoProcessing?.bypassReason == nil, "\(phase): processing bypassed")
            #expect(snapshot?.videoProcessing?.stageUnavailableReason == nil, "\(phase): stage unavailable")
        }

        // MARK: - 1. Live changes while playing

        @Test
        @MainActor
        func appliesAndRemovesPictureControlsWhilePlaying() async throws {
            guard let url = Self.fixture else { return }
            let backend = try NativePlaybackRuntime(videoFrameProcessing: .disabled)
            let host = try #require(try backend.makeSurfaceHost() as? NativePlaybackSurfaceHost)
            // Rotation is a view transform and must not change the video format;
            // the responder answers any format change so one could not stall
            // silently, and counts them.
            let core = FormatChangeResponder()
            core.attach(to: backend)
            try await load(backend, url)

            backend.play()
            #expect(await waitUntil(timeout: .seconds(5)) {
                (backend.sessionSnapshotForDiagnostics?.framesSubmitted ?? 0) >= 6
            })
            let before = try #require(backend.sessionSnapshotForDiagnostics)
            #expect(before.videoProcessing == nil, "nothing to process before any control changes")
            let surfaceBefore = host.sourceDisplaySize

            var equalizer = VideoAdjustmentState.standard
            equalizer.brightness = 30
            backend.setVideoEqualizer(equalizer)
            try await backend.execute(.addVideoFilter(.sharpen))
            try await backend.execute(.addVideoFilter(.deband))
            backend.setVideoRotation(90)

            let expectedStages = ["deband", "picture-adjust", "sharpen"]
            let effective = backend.effectiveVideoProcessing
            #expect(effective.pictureAdjustments == VideoPictureAdjustments(brightness: 30))
            #expect(effective.filters == [.sharpen, .deband])
            #expect(effective.transform == nil, "rotation is applied by the view, not the GPU pipeline")
            // The intended stages are published at once, before any frame.
            #expect(backend.sessionSnapshotForDiagnostics?.videoProcessing?.stageNames == expectedStages)

            // Frames flow through the new stages and the surface lays out the
            // picture rotated at once.
            #expect(await waitUntil(timeout: .seconds(3)) {
                (backend.sessionSnapshotForDiagnostics?.videoProcessing?.outputFrames ?? 0) >= 5
            })
            let rotatedSize = CGSize(width: Self.sourceSize.height, height: Self.sourceSize.width)
            let surfaceRotated = await waitUntil(timeout: .seconds(3)) { host.sourceDisplaySize == rotatedSize }
            #expect(surfaceRotated, "surface source size \(host.sourceDisplaySize)")
            #expect(host.rotationDegrees == 90, "the view applies the user's rotation")
            #expect(core.videoFormatChanges == 0, "none of these controls changes the video format")

            let firstOutput = backend.sessionSnapshotForDiagnostics?.videoProcessing?.outputFrames ?? 0
            #expect(await waitUntil(timeout: .seconds(3)) {
                backend.sessionSnapshotForDiagnostics?.ended == true
                    || (backend.sessionSnapshotForDiagnostics?.videoProcessing?.outputFrames ?? 0) > firstOutput
            }, "output frames keep increasing")
            let processing = try #require(backend.sessionSnapshotForDiagnostics?.videoProcessing)
            #expect(processing.stageNames == expectedStages)
            expectNoFailures(backend.sessionSnapshotForDiagnostics, "applied")
            let videoChangesWhileApplied = core.videoFormatChanges

            // Switch everything off again: the output returns to the source
            // dimensions, a second format change.
            backend.setVideoEqualizer(.standard)
            backend.setVideoRotation(0)
            try await backend.execute(.removeVideoFilter(.sharpen))
            try await backend.execute(.removeVideoFilter(.deband))
            #expect(!backend.effectiveVideoProcessing.isEnabled)
            #expect(await waitUntil(timeout: .seconds(1)) {
                backend.sessionSnapshotForDiagnostics?.videoProcessing == nil
            })
            let surfaceRestored = await waitUntil(timeout: .seconds(3)) { host.sourceDisplaySize == Self.sourceSize }
            #expect(surfaceRestored, "surface source size \(host.sourceDisplaySize)")
            #expect(host.rotationDegrees == 0)
            #expect(core.videoFormatChanges == videoChangesWhileApplied, "removing the controls changes no format")

            #expect(await waitUntil(timeout: .seconds(6)) {
                backend.sessionSnapshotForDiagnostics?.ended == true
            })
            #expect(await waitUntil(timeout: .seconds(3)) { core.unanswered == 0 })
            #expect(core.failures.isEmpty, "format reconfiguration results \(core.failures)")
            let finished = try #require(backend.sessionSnapshotForDiagnostics)
            expectNoFailures(finished, "removed")
            print("PICTURE_CONTROLS_PLAYBACK test=playing stages=\(processing.stageNames) "
                + "in=\(processing.inputFrames) out=\(processing.outputFrames) "
                + "surface-before=\(surfaceBefore) surface-rotated=\(surfaceRotated) "
                + "surface-restored=\(surfaceRestored) format-changes=\(core.log.joined(separator: ",")) "
                + "removed=\(finished.videoProcessing == nil) ended=\(finished.ended) "
                + "submitted=\(finished.framesSubmitted)")
            backend.eventHandler = nil
            await backend.shutdown()
        }

        // MARK: - 2. Paused refresh

        @Test
        @MainActor
        func repaintsThePausedFrameAndCoalescesDrags() async throws {
            guard let url = Self.fixture else { return }
            let backend = try NativePlaybackRuntime(videoFrameProcessing: .disabled)
            _ = try backend.makeSurfaceHost()
            try await load(backend, url)

            backend.play()
            #expect(await waitUntil(timeout: .seconds(5)) {
                (backend.sessionSnapshotForDiagnostics?.framesSubmitted ?? 0) >= 12
            })
            backend.pause()
            #expect(await waitUntilStablyPaused(backend))
            let paused = try #require(backend.sessionSnapshotForDiagnostics)
            let pausedGeneration = paused.generation
            let pausedPosition = paused.rendererMediaTimeSeconds
            let tolerance = Self.frameDuration + 0.002

            // One change: an internal exact seek at rate zero repaints the frame.
            var equalizer = VideoAdjustmentState.standard
            equalizer.saturation = -100
            backend.setVideoEqualizer(equalizer)
            #expect(await waitUntil(timeout: .seconds(3)) {
                (backend.sessionSnapshotForDiagnostics?.generation ?? 0) > pausedGeneration
                    && isSettledWhilePaused(backend)
            }, "a paused change starts a refresh seek that completes")
            let afterOne = try #require(backend.sessionSnapshotForDiagnostics)
            let refreshGeneration = afterOne.generation
            let refreshedPosition = afterOne.rendererMediaTimeSeconds
            let processingAfterOne = try #require(afterOne.videoProcessing)
            #expect(processingAfterOne.stageNames == ["picture-adjust"])
            #expect(processingAfterOne.inputFrames > 0, "the refresh frame went through the pipeline")
            #expect(backend.pausedReadbackDiagnostic().rendererRate == 0, "the refresh keeps playback paused")
            #expect(abs(refreshedPosition - pausedPosition) <= tolerance,
                    "paused at \(pausedPosition), refreshed at \(refreshedPosition)")
            expectNoFailures(afterOne, "single refresh")

            // A slider drag: values arrive about once per display frame.
            let inputBeforeDrag = processingAfterOne.inputFrames
            let steps = 10
            for step in 1...steps {
                equalizer.saturation = Double(-100 + step * 5)
                backend.setVideoEqualizer(equalizer)
                if step < steps { try await Task.sleep(for: .milliseconds(16)) }
            }
            let finalSaturation = equalizer.saturation
            #expect(await waitUntilStablyPaused(backend), "the drag settles")

            let afterDrag = try #require(backend.sessionSnapshotForDiagnostics)
            let dragRefreshes = afterDrag.generation - refreshGeneration
            #expect(dragRefreshes >= 1, "the drag repainted the picture")
            #expect(dragRefreshes <= steps + 1, "refreshes are bounded by the changes")
            #expect(backend.effectiveVideoProcessing.pictureAdjustments
                    == VideoPictureAdjustments(saturation: finalSaturation))
            #expect(abs(afterDrag.rendererMediaTimeSeconds - pausedPosition) <= tolerance,
                    "paused at \(pausedPosition), settled at \(afterDrag.rendererMediaTimeSeconds)")
            #expect(backend.pausedReadbackDiagnostic().rendererRate == 0, "the drag keeps playback paused")
            let processingAfterDrag = try #require(afterDrag.videoProcessing)
            #expect(processingAfterDrag.inputFrames > inputBeforeDrag)
            expectNoFailures(afterDrag, "drag")

            // An app seek supersedes a refresh in flight; later changes must
            // still repaint.
            let beforeSupersede = afterDrag.generation
            equalizer.saturation = 25
            backend.setVideoEqualizer(equalizer)
            let supersededRefresh = backend.sessionSnapshotForDiagnostics?.generation ?? beforeSupersede
            backend.seek(to: pausedPosition, mode: .absoluteExact)
            let appSeekGeneration = backend.sessionSnapshotForDiagnostics?.generation ?? supersededRefresh
            #expect(supersededRefresh > beforeSupersede, "the change started a refresh")
            #expect(appSeekGeneration > supersededRefresh, "the app seek started a newer generation")
            #expect(await waitUntilStablyPaused(backend), "the app seek settles")
            let afterSupersede = try #require(backend.sessionSnapshotForDiagnostics)
            #expect(afterSupersede.generation >= appSeekGeneration)
            expectNoFailures(afterSupersede, "superseded refresh")

            equalizer.saturation = 40
            backend.setVideoEqualizer(equalizer)
            let repaintedAfterSupersede = await waitUntil(timeout: .seconds(3)) {
                (backend.sessionSnapshotForDiagnostics?.generation ?? 0) > afterSupersede.generation
                    && isSettledWhilePaused(backend)
            }
            #expect(repaintedAfterSupersede, "a change after a superseded refresh still repaints")
            let last = try #require(backend.sessionSnapshotForDiagnostics)
            #expect(backend.pausedReadbackDiagnostic().rendererRate == 0)
            #expect(abs(last.rendererMediaTimeSeconds - pausedPosition) <= tolerance,
                    "paused at \(pausedPosition), finally at \(last.rendererMediaTimeSeconds)")
            #expect(backend.effectiveVideoProcessing.pictureAdjustments == VideoPictureAdjustments(saturation: 40))
            expectNoFailures(last, "after superseded refresh")

            print("PICTURE_CONTROLS_PLAYBACK test=paused paused-pos=\(String(format: "%.3f", pausedPosition)) "
                + "refreshed-pos=\(String(format: "%.3f", refreshedPosition)) "
                + "settled-pos=\(String(format: "%.3f", afterDrag.rendererMediaTimeSeconds)) "
                + "final-pos=\(String(format: "%.3f", last.rendererMediaTimeSeconds)) "
                + "generations=\(pausedGeneration)->\(refreshGeneration)->\(afterDrag.generation)"
                + "->\(afterSupersede.generation)->\(last.generation) drag-refreshes=\(dragRefreshes) "
                + "repainted-after-supersede=\(repaintedAfterSupersede) "
                + "in=\(last.videoProcessing?.inputFrames ?? 0) out=\(last.videoProcessing?.outputFrames ?? 0)")
            await backend.shutdown()
        }

        // MARK: - 3. Interpolation survives live changes

        @Test
        @MainActor
        func keepsInterpolatingAcrossLiveChanges() async throws {
            guard let url = Self.fixture else { return }
            let backend = try NativePlaybackRuntime(videoFrameProcessing: VideoFrameProcessingConfiguration(
                frameRateConversion: VideoFrameRateConversion(targetFrameRate: 60)
            ))
            _ = try backend.makeSurfaceHost()
            // Start with the adjustment stage in place so the interpolator's
            // input format is fixed before it warms up.
            var equalizer = VideoAdjustmentState.standard
            equalizer.brightness = 10
            backend.setVideoEqualizer(equalizer)
            try await load(backend, url)

            // First warm-up, which may load a model.
            backend.play()
            #expect(await waitUntil(timeout: .seconds(10)) {
                guard let processing = backend.sessionSnapshotForDiagnostics?.videoProcessing else { return false }
                return processing.synthesizedFrames >= 10 && !processing.warmingUp
            })
            let warmed = try #require(backend.sessionSnapshotForDiagnostics?.videoProcessing)
            #expect(warmed.stageNames.count == 2)
            #expect(warmed.stageNames.first == "picture-adjust")
            let interpolationStage = warmed.stageNames.last ?? ""

            // Restart from the beginning so the changes happen well before the
            // two-second clip ends.
            backend.pause()
            backend.seek(to: 0, mode: .absoluteExact)
            let restart = try #require(backend.sessionSnapshotForDiagnostics?.generation)
            #expect(await waitUntil(timeout: .seconds(5)) {
                guard let snapshot = backend.sessionSnapshotForDiagnostics else { return false }
                return snapshot.generation == restart && snapshot.isPrerolled
            })
            backend.play()
            #expect(await waitUntil(timeout: .seconds(3)) {
                (backend.sessionSnapshotForDiagnostics?.videoProcessing?.synthesizedFrames ?? 0)
                    >= warmed.synthesizedFrames + 3
            })

            var log: [String] = []
            for brightness in [20.0, 30.0, 40.0] {
                let before = try #require(backend.sessionSnapshotForDiagnostics?.videoProcessing)
                equalizer.brightness = brightness
                backend.setVideoEqualizer(equalizer)
                let rose = await waitUntil(timeout: .seconds(2)) {
                    guard let processing = backend.sessionSnapshotForDiagnostics?.videoProcessing else { return false }
                    return processing.synthesizedFrames >= before.synthesizedFrames + 3
                        && processing.inputFrames > before.inputFrames
                }
                let after = try #require(backend.sessionSnapshotForDiagnostics?.videoProcessing)
                #expect(rose, "brightness \(brightness): synthesized \(before.synthesizedFrames) -> \(after.synthesizedFrames)")
                #expect(!after.warmingUp, "brightness \(brightness): the interpolator warmed up again")
                #expect(!after.synthesisSuspended, "brightness \(brightness): synthesis suspended")
                #expect(after.stageNames == ["picture-adjust", interpolationStage],
                        "brightness \(brightness): stages \(after.stageNames)")
                // Kept stages with unchanged formats are not reconfigured; a
                // model reload would take far longer than this.
                #expect(after.configurationMilliseconds < 100,
                        "brightness \(brightness): reconfiguration took \(after.configurationMilliseconds) ms")
                expectNoFailures(backend.sessionSnapshotForDiagnostics, "brightness \(brightness)")
                log.append("\(Int(brightness)):\(after.synthesizedFrames)"
                    + "/\(String(format: "%.1f", after.configurationMilliseconds))ms")
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(backend.effectiveVideoProcessing.pictureAdjustments == VideoPictureAdjustments(brightness: 40))

            #expect(await waitUntil(timeout: .seconds(6)) {
                backend.sessionSnapshotForDiagnostics?.ended == true
            })
            let finished = try #require(backend.sessionSnapshotForDiagnostics)
            let summary = try #require(finished.videoProcessing)
            expectNoFailures(finished, "ended")
            print("PICTURE_CONTROLS_PLAYBACK test=interpolation stages=\(summary.stageNames) "
                + "warm-configure-ms=\(String(format: "%.1f", warmed.configurationMilliseconds)) "
                + "changes=\(log.joined(separator: ",")) in=\(summary.inputFrames) out=\(summary.outputFrames) "
                + "synthesized=\(summary.synthesizedFrames) overruns=\(summary.overruns) "
                + "suspended=\(summary.synthesisSuspended) warming=\(summary.warmingUp)")
            await backend.shutdown()
        }
    }
}

/// Stands in for the playback core. In the app, IlliquidPlaybackModel (via
/// PlaybackRuntimeDriver) answers the runtime's
/// `.synchronization(.formatChanged)` with a `reconfigureMediaFormat` effect;
/// a bare runtime has nobody to answer, so every mid-stream format change
/// would wait until it times out. This answers only those events, the way
/// the core's synchronization rules do (video changes on the video-decode
/// executor, audio on audio-decode), and records the effect results.
@MainActor
final class FormatChangeResponder {
    private(set) var log: [String] = []
    private(set) var videoFormatChanges = 0
    var audioFormatChanges: Int { log.filter { $0.hasPrefix("audio") }.count }
    private(set) var failures: [String] = []
    private var outstanding: Set<PlaybackEffectID> = []
    private var nextID: UInt64 = 10_000

    var unanswered: Int { outstanding.count }

    func attach(to backend: NativePlaybackRuntime) {
        backend.eventHandler = { [weak self, weak backend] event in
            guard let self, let backend else { return }
            self.handle(event, backend: backend)
        }
    }

    private func handle(_ event: PlaybackRuntimeEvent, backend: NativePlaybackRuntime) {
        switch event.payload {
        case let .synchronization(.formatChanged(stream: stream, revision: revision)):
            if stream == .video { videoFormatChanges += 1 }
            log.append("\(stream.rawValue)#\(revision.rawValue)")
            nextID += 1
            let effect = PlaybackEffect(
                executor: stream == .video ? .videoDecode : .audioDecode,
                context: PlaybackEffectContext(
                    authority: .playback(
                        sessionID: PlaybackSessionID(rawValue: 1),
                        generation: PlaybackGenerationID(rawValue: 1),
                        revisions: PlaybackRevisionSet()
                    ),
                    operationID: PlaybackOperationID(rawValue: nextID),
                    effectID: PlaybackEffectID(rawValue: nextID)
                ),
                kind: .reconfigureMediaFormat(stream: stream, revision: revision)
            )
            outstanding.insert(effect.context.effectID)
            backend.execute(PlaybackRuntimeEffectRequest(effect: effect))
        case let .effectResult(result):
            guard outstanding.remove(result.context.effectID) != nil else { return }
            if result.token.kind != .succeeded {
                failures.append("\(result.context.effectID.rawValue):\(result.token.kind)"
                    + (result.failure.map { ":\($0.stableCode)" } ?? ""))
            }
        default:
            break
        }
    }
}
