import AVFoundation
import Foundation
import IlliquidCore
import IlliquidPlayback
import IlliquidPlaybackModel
import Testing
@testable import IlliquidNativePlayback

/// Plays streams whose format changes mid-stream through the real runtime and
/// renderer, with `FormatChangeResponder` standing in for the playback core.
///
/// Set ILLIQUID_VIDEO_PROCESSING_FIXTURE_DIR to a directory holding:
/// - resolution-change.ts: 3 s, 24 fps H.264 in MPEG-TS; 36 frames at
///   640x360 then 36 at 480x360 (new SPS/PPS on an IDR at 1.5 s), with one
///   continuous 48 kHz stereo AAC tone; one continuous timeline.
/// - audio-layout-change.ts: 3 s, 24 fps 640x360 H.264 throughout; AAC at
///   48 kHz, stereo for the first ~1.536 s, then mono; one continuous timeline.
///
/// Media times below are relative to the file's start (the demuxer removes
/// the MPEG-TS start offset).
extension RealRendererPlayback {
    @Suite("Mid-stream format change playback", .serialized)
    struct MidstreamFormatChangePlaybackTests {
        private static let frameRate = 24.0
        private static let frameDuration = 1.0 / frameRate
        private static let fileFrameCount = 72
        private static let fileDuration = 3.0
        /// The first 480x360 frame is at 1.5 s.
        private static let resolutionChangeTime = 1.5
        private static let wideSize = CGSize(width: 640, height: 360)
        private static let narrowSize = CGSize(width: 480, height: 360)

        private static func fixture(_ name: String) -> URL? {
            guard let directory = ProcessInfo.processInfo.environment["ILLIQUID_VIDEO_PROCESSING_FIXTURE_DIR"] else {
                return nil
            }
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        private static func seconds(_ duration: Duration) -> Double {
            let components = duration.components
            return Double(components.seconds) + Double(components.attoseconds) / 1e18
        }

        private static func format(_ value: Double?) -> String {
            value.map { String(format: "%.3f", $0) } ?? "nil"
        }

        // MARK: - Helpers (copied from VideoPictureControlsPlaybackTests)

        @MainActor
        private func waitFor(timeout: Duration, _ predicate: () -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if predicate() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return predicate()
        }

        @MainActor
        private func loadMedia(_ backend: NativePlaybackRuntime, _ url: URL) async throws {
            let source = MediaSource.localFile(url)
            let request = try #require(MediaLoadRequest(source: source, origin: .userSelected))
            try backend.load(PlaybackRuntimeLoadRequest(
                media: request, identity: PlayerSessionIdentity(source: source, generation: 1)
            ))
            #expect(await waitFor(timeout: .seconds(5)) {
                backend.sessionSnapshotForDiagnostics?.isPrerolled == true
            })
        }

        @MainActor
        private func isSettledPaused(_ backend: NativePlaybackRuntime) -> Bool {
            guard let snapshot = backend.sessionSnapshotForDiagnostics else { return false }
            let readback = backend.pausedReadbackDiagnostic()
            return readback.rendererRate == 0 && !readback.seekInProgress
                && snapshot.isPrerolled && snapshot.rendererFailure == nil
        }

        /// Settled, at or after `generation`, and still settled at the same
        /// generation 200 ms later.
        @MainActor
        private func waitUntilSettledPaused(_ backend: NativePlaybackRuntime, atLeast generation: Int = 0) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(6))
            while clock.now < deadline {
                guard await waitFor(timeout: .seconds(3), {
                    isSettledPaused(backend)
                        && (backend.sessionSnapshotForDiagnostics?.generation ?? 0) >= generation
                }) else { return false }
                let settledGeneration = backend.sessionSnapshotForDiagnostics?.generation
                try? await Task.sleep(for: .milliseconds(200))
                if isSettledPaused(backend), backend.sessionSnapshotForDiagnostics?.generation == settledGeneration {
                    return true
                }
            }
            return false
        }

        @MainActor
        private func expectHealthy(_ snapshot: MediaSessionSnapshot?, _ phase: String) {
            #expect(snapshot?.rendererFailure == nil, "\(phase): renderer failure \(snapshot?.rendererFailure ?? "")")
            #expect(snapshot?.lastRecoveryFailure == nil, "\(phase): recovery failure")
        }

        // MARK: - Playback trace

        /// What happened while playing to the end, sampled every 10 ms.
        private struct PlaybackTrace {
            var ended = false
            var samples = 0
            /// Longest wall-clock time the renderer clock stayed constant after
            /// it first advanced, before `ended` and before `stallCutoff`.
            var longestStallSeconds = 0.0
            /// Media time at which that longest stall happened.
            var longestStallAt: Double?
            /// Stalls longer than `gapThreshold`, as "media-time:seconds".
            var gaps: [String] = []
            /// Renderer clock and enqueue horizon when the surface first showed
            /// `switchTarget`.
            var switchMediaTime: Double?
            var switchVideoPTS: Double?
            var finalMediaTime = 0.0
        }

        /// Samples the renderer clock until the session ends or `timeout`
        /// elapses. Nothing here pauses, so a constant clock before the end is a
        /// stall. Stalls are ignored once the clock is within `stallCutoff` of the
        /// end, where the renderer may legitimately stop before `ended` is set.
        @MainActor
        private func trace(
            _ backend: NativePlaybackRuntime,
            host: NativePlaybackSurfaceHost,
            switchTarget: CGSize?,
            timeout: Duration,
            stallCutoff: Double = Self.fileDuration - 0.2,
            gapThreshold: Double = 0.2
        ) async -> PlaybackTrace {
            var result = PlaybackTrace()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            var lastClockValue: Double?
            var lastClockChange = clock.now
            var clockStarted = false
            var currentStall = 0.0
            var currentStallAt = 0.0

            func closeStall() {
                if currentStall > gapThreshold {
                    result.gaps.append("\(Self.format(currentStallAt)):\(Self.format(currentStall))")
                }
                currentStall = 0
            }

            while clock.now < deadline {
                guard let snapshot = backend.sessionSnapshotForDiagnostics else {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                }
                result.samples += 1
                let now = clock.now
                let mediaTime = snapshot.rendererMediaTimeSeconds
                result.finalMediaTime = mediaTime

                if let target = switchTarget, result.switchMediaTime == nil, host.sourceDisplaySize == target {
                    result.switchMediaTime = mediaTime
                    result.switchVideoPTS = snapshot.videoPTS
                }

                if let last = lastClockValue, last != mediaTime {
                    clockStarted = true
                    closeStall()
                    lastClockChange = now
                } else if lastClockValue == nil {
                    lastClockChange = now
                } else if clockStarted, !snapshot.ended, mediaTime < stallCutoff {
                    currentStall = Self.seconds(now - lastClockChange)
                    currentStallAt = mediaTime
                    if currentStall > result.longestStallSeconds {
                        result.longestStallSeconds = currentStall
                        result.longestStallAt = mediaTime
                    }
                }
                lastClockValue = mediaTime

                if snapshot.ended {
                    result.ended = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            closeStall()
            return result
        }

        // MARK: - 1. Video resolution change while playing

        @Test
        @MainActor
        func videoResolutionChangeKeepsPlaying() async throws {
            guard let url = Self.fixture("resolution-change.ts") else { return }
            let backend = try NativePlaybackRuntime(videoFrameProcessing: .disabled)
            let host = try #require(try backend.makeSurfaceHost() as? NativePlaybackSurfaceHost)
            let core = FormatChangeResponder()
            core.attach(to: backend)
            try await loadMedia(backend, url)

            let startsWide = await waitFor(timeout: .seconds(2)) { host.sourceDisplaySize == Self.wideSize }
            #expect(startsWide, "surface at load \(host.sourceDisplaySize)")
            let surfaceAtLoad = host.sourceDisplaySize

            backend.play()
            let played = await trace(backend, host: host, switchTarget: Self.narrowSize, timeout: .seconds(6))
            #expect(played.ended, "ended within 6 s; clock reached \(Self.format(played.finalMediaTime))")

            #expect(await waitFor(timeout: .seconds(3)) { core.unanswered == 0 }, "unanswered \(core.unanswered)")
            #expect(core.videoFormatChanges >= 1, "format changes \(core.log)")
            #expect(core.failures.isEmpty, "format reconfiguration results \(core.failures)")
            let finished = try #require(backend.sessionSnapshotForDiagnostics)
            expectHealthy(finished, "ended")

            #expect(host.sourceDisplaySize == Self.narrowSize, "surface at end \(host.sourceDisplaySize)")
            // A video format change no longer flushes or pauses: the clock keeps
            // moving through it.
            let stallMessage = "renderer clock stalled \(Self.format(played.longestStallSeconds)) s "
                + "at \(Self.format(played.longestStallAt)); gaps \(played.gaps)"
            #expect(played.longestStallSeconds <= 0.5, "\(stallMessage)")
            let minimumFrames = Int((Double(Self.fileFrameCount) * 0.9).rounded(.up))
            #expect(finished.framesSubmitted >= minimumFrames,
                    "submitted \(finished.framesSubmitted) of \(Self.fileFrameCount)")

            // The surface must follow presentation, not decode: the decoder sees
            // the new SPS well ahead of the clock (the enqueue horizon runs ahead
            // by the renderer's buffer). The first 480x360 frame is at 1.5 s; the
            // bound is 1.2 s rather than 1.3 s because the 10 ms sampling, the
            // main-actor hop that updates the surface, and timebase read-out
            // jitter can make the observed clock lag or lead the real switch by a
            // few frames.
            let switchTime = try #require(played.switchMediaTime, "surface never switched to 480x360")
            let switchMessage = "surface switched at media time \(Self.format(switchTime)) "
                + "(enqueue horizon \(Self.format(played.switchVideoPTS)))"
            #expect(switchTime >= 1.2, "\(switchMessage)")

            print("MIDSTREAM_FORMAT_CHANGE test=video-resolution "
                + "surface-load=\(surfaceAtLoad) surface-end=\(host.sourceDisplaySize) "
                + "switch-media-time=\(Self.format(played.switchMediaTime)) "
                + "switch-video-pts=\(Self.format(played.switchVideoPTS)) "
                + "longest-stall=\(Self.format(played.longestStallSeconds))@\(Self.format(played.longestStallAt)) "
                + "gaps=\(played.gaps) samples=\(played.samples) ended=\(played.ended) "
                + "final-clock=\(Self.format(played.finalMediaTime)) submitted=\(finished.framesSubmitted) "
                + "video-pts=\(Self.format(finished.videoPTS)) audio-pts=\(Self.format(finished.audioPTS)) "
                + "format-changes=\(core.log.joined(separator: ",")) unanswered=\(core.unanswered) "
                + "failures=\(core.failures) generation=\(finished.generation)")
            backend.eventHandler = nil
            await backend.shutdown()
        }

        // MARK: - 2. Seeking across the resolution change

        @Test
        @MainActor
        func seekAcrossResolutionChangeUpdatesSurface() async throws {
            guard let url = Self.fixture("resolution-change.ts") else { return }
            let backend = try NativePlaybackRuntime(videoFrameProcessing: .disabled)
            // Software decoding: seeking straight into the second SPS makes
            // VideoToolbox report invalid data and ask for a software
            // fallback, which only the playback core performs. This test is
            // about the surface following the session's geometry after a seek.
            backend.setHardwareDecodingPolicy(.off)
            let host = try #require(try backend.makeSurfaceHost() as? NativePlaybackSurfaceHost)
            let core = FormatChangeResponder()
            core.attach(to: backend)
            try await loadMedia(backend, url)
            #expect(await waitFor(timeout: .seconds(2)) { host.sourceDisplaySize == Self.wideSize },
                    "surface at load \(host.sourceDisplaySize)")

            backend.play()
            #expect(await waitFor(timeout: .seconds(4)) {
                (backend.sessionSnapshotForDiagnostics?.rendererMediaTimeSeconds ?? 0) >= 0.5
            })
            backend.pause()
            #expect(await waitUntilSettledPaused(backend), "paused before the change")
            #expect(host.sourceDisplaySize == Self.wideSize, "surface before the change \(host.sourceDisplaySize)")
            let pausedAt = backend.sessionSnapshotForDiagnostics?.rendererMediaTimeSeconds ?? 0

            // Forward across the change: the keyframe before 2.2 s (2.0 s) is
            // already 480x360.
            backend.seek(to: 2.2, mode: .absoluteExact)
            let forwardGeneration = backend.sessionSnapshotForDiagnostics?.generation ?? 0
            let forwardSettled = await waitUntilSettledPaused(backend, atLeast: forwardGeneration)
            #expect(forwardSettled, "seek to 2.2 settles")
            let forward = try #require(backend.sessionSnapshotForDiagnostics)
            let forwardNarrow = await waitFor(timeout: .seconds(3)) { host.sourceDisplaySize == Self.narrowSize }
            #expect(forwardNarrow, "surface after seek to 2.2: \(host.sourceDisplaySize)")
            #expect(abs(forward.rendererMediaTimeSeconds - 2.2) <= Self.frameDuration + 0.002,
                    "seek to 2.2 landed at \(Self.format(forward.rendererMediaTimeSeconds))")
            expectHealthy(forward, "after seek to 2.2")

            // Back before the change.
            backend.seek(to: 0.3, mode: .absoluteExact)
            let backGeneration = backend.sessionSnapshotForDiagnostics?.generation ?? 0
            let backSettled = await waitUntilSettledPaused(backend, atLeast: backGeneration)
            #expect(backSettled, "seek to 0.3 settles")
            let back = try #require(backend.sessionSnapshotForDiagnostics)
            let backWide = await waitFor(timeout: .seconds(3)) { host.sourceDisplaySize == Self.wideSize }
            #expect(backWide, "surface after seek to 0.3: \(host.sourceDisplaySize)")
            #expect(abs(back.rendererMediaTimeSeconds - 0.3) <= Self.frameDuration + 0.002,
                    "seek to 0.3 landed at \(Self.format(back.rendererMediaTimeSeconds))")
            expectHealthy(back, "after seek to 0.3")

            #expect(await waitFor(timeout: .seconds(3)) { core.unanswered == 0 }, "unanswered \(core.unanswered)")
            #expect(core.failures.isEmpty, "format reconfiguration results \(core.failures)")

            print("MIDSTREAM_FORMAT_CHANGE test=seek-across paused-at=\(Self.format(pausedAt)) "
                + "forward-settled=\(forwardSettled) forward-pos=\(Self.format(forward.rendererMediaTimeSeconds)) "
                + "forward-narrow=\(forwardNarrow) back-settled=\(backSettled) "
                + "back-pos=\(Self.format(back.rendererMediaTimeSeconds)) back-wide=\(backWide) "
                + "surface-final=\(host.sourceDisplaySize) generations=\(forward.generation)->\(back.generation) "
                + "format-changes=\(core.log.joined(separator: ",")) unanswered=\(core.unanswered) "
                + "failures=\(core.failures)")
            backend.eventHandler = nil
            await backend.shutdown()
        }

        // MARK: - 3. Audio channel layout change while playing

        @Test
        @MainActor
        func audioLayoutChangeKeepsPlaying() async throws {
            guard let url = Self.fixture("audio-layout-change.ts") else { return }
            let backend = try NativePlaybackRuntime(videoFrameProcessing: .disabled)
            let host = try #require(try backend.makeSurfaceHost() as? NativePlaybackSurfaceHost)
            let core = FormatChangeResponder()
            core.attach(to: backend)
            try await loadMedia(backend, url)

            backend.play()
            let played = await trace(backend, host: host, switchTarget: nil, timeout: .seconds(7))
            #expect(played.ended, "ended within 7 s; clock reached \(Self.format(played.finalMediaTime))")

            #expect(await waitFor(timeout: .seconds(3)) { core.unanswered == 0 }, "unanswered \(core.unanswered)")
            #expect(core.audioFormatChanges >= 1, "format changes \(core.log)")
            #expect(core.failures.isEmpty, "format reconfiguration results \(core.failures)")
            let finished = try #require(backend.sessionSnapshotForDiagnostics)
            expectHealthy(finished, "ended")

            // An audio format change still flushes, which may hold the clock
            // briefly once; playback must then resume.
            let stallMessage = "renderer clock stalled \(Self.format(played.longestStallSeconds)) s "
                + "at \(Self.format(played.longestStallAt)); gaps \(played.gaps)"
            #expect(played.longestStallSeconds <= 0.6, "\(stallMessage)")
            #expect(played.gaps.count <= 1, "more than one clock gap: \(played.gaps)")
            // Audio was still being enqueued well after the change at ~1.54 s.
            #expect(finished.audioPTS > 2.5, "audio enqueue horizon \(Self.format(finished.audioPTS))")
            #expect(host.sourceDisplaySize == Self.wideSize, "surface \(host.sourceDisplaySize)")

            print("MIDSTREAM_FORMAT_CHANGE test=audio-layout "
                + "longest-stall=\(Self.format(played.longestStallSeconds))@\(Self.format(played.longestStallAt)) "
                + "gaps=\(played.gaps) samples=\(played.samples) ended=\(played.ended) "
                + "final-clock=\(Self.format(played.finalMediaTime)) audio-pts=\(Self.format(finished.audioPTS)) "
                + "video-pts=\(Self.format(finished.videoPTS)) submitted=\(finished.framesSubmitted) "
                + "audio-channels=\(finished.audioOutputChannels.map { "\($0)" } ?? "nil") "
                + "audio-rate=\(finished.audioOutputSampleRate.map { "\($0)" } ?? "nil") "
                + "format-changes=\(core.log.joined(separator: ",")) unanswered=\(core.unanswered) "
                + "failures=\(core.failures) generation=\(finished.generation)")
            backend.eventHandler = nil
            await backend.shutdown()
        }
    }
}
