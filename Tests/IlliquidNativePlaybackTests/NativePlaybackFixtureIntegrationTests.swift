import AppKit
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import IlliquidCore
import IlliquidPlayback
import IlliquidPlaybackCore
import Testing
@testable import IlliquidNativePlayback

@Suite("Native playback generated fixture integration", .serialized)
struct NativePlaybackFixtureIntegrationTests {
    private var fixtureDirectory: URL? {
        ProcessInfo.processInfo.environment["ILLIQUID_NATIVE_FIXTURE_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    @MainActor
    private func trackSnapshots(
        recordedBy recorder: NativeBackendEventRecorder
    ) -> [PlayerTrackSnapshot] {
        recorder.events.compactMap { event in
            guard case let .tracksChanged(snapshot) = event.payload else {
                return nil
            }
            return snapshot
        }
    }

    @MainActor
    private func hasRuntimeFailure(
        recordedBy recorder: NativeBackendEventRecorder
    ) -> Bool {
        recorder.events.contains { event in
            switch event.payload {
            case .typedFailure, .failed:
                true
            default:
                false
            }
        }
    }

    @MainActor
    private func allRuntimeLeasesArePhysicallyReleased(
        _ backend: NativePlaybackRuntime
    ) -> Bool {
        let leases = backend.runtimeLeaseSnapshotsForTesting
        return !leases.isEmpty && leases.allSatisfy {
            $0.disposition == .released && $0.activeBorrows.isEmpty
        }
    }

    @Test func requiredFixtureManifestIsCompleteInQualificationMode() throws {
        guard ProcessInfo.processInfo.environment["ILLIQUID_NATIVE_REQUIRE_FIXTURES"] == "1"
        else { return }
        let directory = try #require(
            fixtureDirectory,
            "ILLIQUID_NATIVE_FIXTURE_DIR is required in qualification mode"
        )
        let required = [
            "audio-5.1.flac", "audio-7.1.flac", "audio-only-pcm.wav",
            "audio-only-vorbis.ogg", "audio-only.mp3", "av1-video-only.mkv",
            "av1-10bit-video-only.mkv", "audio-rate-layout-change.ts",
            "anamorphic-sar.mkv", "cfr-control.mkv",
            "chroma-center.mkv", "chroma-left.mkv",
            "color-bt601-full.mkv", "color-bt601-limited.mkv",
            "color-bt709-full.mkv", "color-bt709-limited.mkv",
            "embedded-ass-font.mkv", "embedded-srt.mkv", "external.ass", "external.srt",
            "external.ssa", "external.vtt", "fixture-matrix.json",
            "corrupt-packets.mkv", "delayed-audio-tail.mkv", "fixture-manifest.json",
            "h264-aac.mkv", "h264-aac.mp4", "hdr10-pq-p010.mkv", "heavy-animated.ass",
            "hevc-10bit-aac.mkv", "hevc-flac.mkv", "hlg-p010.mkv",
            "interlaced-bff.mpg", "interlaced-tff.mpg", "missing-glyph.ass",
            "long-h264-av-sync.mkv", "long-hevc-p010-av-sync.mkv", "long-vfr-av-sync.mkv", "long-caption.mkv",
            "midstream-pixel-color-change.ts", "midstream-resolution-change.ts",
            "multiple-audio-flags.mkv", "multiple-audio.mkv", "negative-origin.mpg",
            "nonzero-start.mkv", "rotated-90.mp4", "rotated-180.mp4",
            "rotated-270.mp4", "mirrored-horizontal.mp4", "sdr-bt2020.mkv",
            "truncated-h264.mp4", "single-frame-h264.mp4",
            "unknown-duration.h264", "variable-frame-rate.mkv", "video-only.mp4",
            "vp9-10bit-video-only.mkv", "vp9-opus.mkv",
        ]
        for filename in required {
            #expect(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(filename).path
                ),
                "Required generated fixture is missing: \(filename)"
            )
        }
    }

    @Test func prioritizedFixtureTruthAndProvenanceAreSelfVerifying() throws {
        guard let fixtureDirectory else { return }
        let manifest = try JSONDecoder().decode(
            DifferentialFixtureManifest.self,
            from: Data(contentsOf: fixtureDirectory.appendingPathComponent("fixture-manifest.json"))
        )
        let requiredAssertions: [String: Set<String>] = [
            "variable-frame-rate.mkv": ["irregular-video-pts-deltas"],
            "nonzero-start.mkv": [
                "positive-timeline-origin", "chapters-retain-positive-source-origin",
            ],
            "negative-origin.mpg": [
                "negative-packet-origin", "negative-origin-retains-all-frames",
            ],
            "unknown-duration.h264": ["duration-remains-unknown"],
            "corrupt-packets.mkv": ["decode-error-observed"],
            "truncated-h264.mp4": ["decode-error-observed"],
            "delayed-audio-tail.mkv": ["audio-tail-after-video"],
            "midstream-resolution-change.ts": ["multiple-decoded-resolutions"],
            "cfr-control.mkv": ["uniform-video-pts-deltas", "fixed-gop"],
            "discontinuous-timestamps.mkv": ["nonmonotonic-video-pts"],
            "midstream-pixel-color-change.ts": ["multiple-pixel-or-color-configurations"],
            "audio-rate-layout-change.ts": ["multiple-audio-configurations"],
            "multiple-audio-flags.mkv": ["audio-selection-flags"],
            "anamorphic-sar.mkv": ["anamorphic-sample-aspect-ratio"],
            "sdr-bt2020.mkv": ["bt2020-sdr-transfer"],
            "interlaced-tff.mpg": ["top-field-first"],
            "interlaced-bff.mpg": ["bottom-field-first"],
            "mirrored-horizontal.mp4": ["reflected-display-matrix"],
        ]
        for (name, assertionNames) in requiredAssertions {
            let fixture = try #require(manifest.fixture(named: name))
            _ = try DifferentialFixtureVerifier.verify(fixture, in: fixtureDirectory)
            #expect(Set(fixture.assertions.map(\.name)).isSuperset(of: assertionNames))
        }
    }

    @Test func fixtureMatrixAccountsForEveryRequiredPlanCase() throws {
        guard let fixtureDirectory else { return }
        let matrix = try JSONDecoder().decode(
            DifferentialFixtureMatrix.self,
            from: Data(contentsOf: fixtureDirectory.appendingPathComponent("fixture-matrix.json"))
        )
        try DifferentialFixtureMatrixVerifier.verify(matrix)
        #expect(Set(matrix.cases.map(\.id)) == Set(DifferentialFixtureCaseID.allCases))
        #expect(matrix.cases.allSatisfy { fixtureCase in
            switch fixtureCase.status {
            case .generated: return !(fixtureCase.fixturePaths ?? []).isEmpty
            case .adapterCovered: return !(fixtureCase.evidence ?? "").isEmpty
            case .environmentBlocked, .deferred: return !(fixtureCase.blocker ?? "").isEmpty
            }
        })
    }

    @Test func unknownDurationRemainsExplicitWhileInputIsPlayable() throws {
        guard let fixtureDirectory else { return }
        let demuxer = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("unknown-duration.h264")
        )
        #expect(demuxer.mediaInfo.durationStatus == .unknown)
        #expect(demuxer.mediaInfo.duration == 0)
        #expect(demuxer.mediaInfo.videoStreams.count == 1)
        #expect(try demuxer.readPacket(generation: 1) != nil)
    }

    @Test func unknownDurationDifferentialReportsSeekCapabilityWithoutAborting() throws {
        guard let fixtureDirectory else { return }
        let run = try NativeDifferentialRunner.runHeadlessSemanticSmoke(
            fixtureURL: fixtureDirectory.appendingPathComponent("unknown-duration.h264"),
            seekTarget: 1.25
        )
        #expect(run.result.opened)
        #expect(run.result.seek?.completionReason == "unsupported-by-input")
        #expect(run.result.eof == .clean)
    }

    @Test func timelineOriginsNormalizeDecodedAudioAndRetainNegativeOriginPackets() throws {
        guard let fixtureDirectory else { return }
        let nonzero = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("nonzero-start.mkv")
        )
        #expect(nonzero.mediaInfo.startTime >= 1.5)
        #expect(nonzero.mediaInfo.chapters.count == 2)
        #expect(abs(nonzero.mediaInfo.chapters[0].start - 0) < 0.001)
        #expect(abs(nonzero.mediaInfo.chapters[1].start - 1) < 0.001)
        let audio = try #require(nonzero.mediaInfo.audioStreams.first)
        let parameters = try #require(nonzero.codecParameters(streamIndex: audio.index))
        let decoder = try AudioDecoder(
            parameters: parameters,
            stream: audio,
            timelineOriginSeconds: nonzero.mediaInfo.startTime
        )
        var firstAudio: NativeDecodedAudioFrame?
        while firstAudio == nil, let packet = try nonzero.readPacket(generation: 1) {
            guard packet.streamIndex == audio.index else { continue }
            firstAudio = try decoder.decode(packet).first
        }
        let normalized = try #require(firstAudio)
        #expect(normalized.presentationTime.seconds >= 0)
        #expect(normalized.presentationTime.seconds < 0.05)

        let negative = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("negative-origin.mpg")
        )
        var minimumDecodeTime = Double.infinity
        var packetCount = 0
        while let packet = try negative.readPacket(generation: 1) {
            if let dts = packet.decodeSeconds { minimumDecodeTime = min(minimumDecodeTime, dts) }
            packetCount += 1
        }
        #expect(minimumDecodeTime < 0)
        #expect(packetCount >= 90)
    }

    @Test func bitmapSubtitleCapabilitiesAreExplicitAndNeverClaimTextPlayback() {
        #expect(NativeSubtitleCapability.classify(codecName: "ass").isPlayable)
        #expect(NativeSubtitleCapability.classify(codecName: "hdmv_pgs_subtitle").isPlayable)
        #expect(NativeSubtitleCapability.classify(codecName: "dvd_subtitle").isPlayable)
        #expect(NativeSubtitleCapability.classify(codecName: "dvb_subtitle").isPlayable)
        #expect(!NativeSubtitleCapability.classify(codecName: "xsub").isPlayable)
    }

    @Test func mirroredAndInterlacedMetadataHaveExplicitProductPolicy() throws {
        guard let fixtureDirectory else { return }
        let mirrored = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("mirrored-horizontal.mp4")
        )
        let mirroredStream = try #require(mirrored.mediaInfo.videoStreams.first)
        #expect(mirroredStream.isMirrored)
        #expect(abs(mirroredStream.rotationDegrees) < 0.1)

        let tff = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("interlaced-tff.mpg")
        )
        let bff = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("interlaced-bff.mpg")
        )
        #expect(try #require(tff.mediaInfo.videoStreams.first).interlaceMode == .topFieldFirst)
        #expect(try #require(bff.mediaInfo.videoStreams.first).interlaceMode == .bottomFieldFirst)
        #expect(try #require(tff.mediaInfo.videoStreams.first).interlaceMode
            .requiresDeinterlacing)
    }

    @Test func nativeTrackIDsRejectMalformedAndOverflowingValuesWithoutNarrowingTrap() {
        #expect(NativeTrackIDMapping.streamIndex(for: Int64.min) == nil)
        #expect(NativeTrackIDMapping.streamIndex(for: -1) == nil)
        #expect(NativeTrackIDMapping.streamIndex(for: 0) == nil)
        #expect(NativeTrackIDMapping.streamIndex(for: 1) == 0)
        #expect(NativeTrackIDMapping.streamIndex(for: Int64(Int32.max) + 1) == Int32.max)
        #expect(NativeTrackIDMapping.streamIndex(for: Int64(Int32.max) + 2) == nil)
        #expect(NativeTrackIDMapping.streamIndex(for: Int64.max) == nil)
    }

    @Test func cleanAndTruncatedDemuxOutcomesRemainDistinct() throws {
        guard let fixtureDirectory else { return }
        func outcome(_ name: String) throws -> DifferentialEOFOutcome {
            let demuxer = try FFmpegDemuxer(url: fixtureDirectory.appendingPathComponent(name))
            do {
                while try demuxer.readPacket(generation: 1) != nil {}
                return .clean
            } catch {
                return .readFailure
            }
        }
        #expect(try outcome("h264-aac.mp4") == .clean)
        #expect(try outcome("delayed-audio-tail.mkv") == .clean)
        #expect(try outcome("truncated-h264.mp4") == .readFailure)
        let damaged = try FFmpegDemuxer(url: fixtureDirectory.appendingPathComponent("truncated-h264.mp4"))
        #expect(throws: FFmpegError.self) {
            while try damaged.readPacket(generation: 1) != nil {}
        }
        try damaged.seek(to: 0, exact: true)
        #expect(try damaged.readPacket(generation: 2) != nil)
    }

    @Test @MainActor func inputExecutorOpensOffMainAndCopiesCodecConfiguration() throws {
        guard let fixtureDirectory else { return }
        let input = try FFmpegInputExecutor(
            url: fixtureDirectory.appendingPathComponent("h264-aac.mp4")
        )
        #expect(!input.openWasPerformedOnMainThread)
        let videoIndex = try #require(input.mediaInfo.selectedVideoIndex)
        let copied = try input.copyCodecParameters(streamIndex: videoIndex)
        let owned = try #require(copied)
        let codecID = owned.withUnsafePointer { Int32($0.pointee.codec_id.rawValue) }
        #expect(codecID != nil)
    }

    @Test func timelineThumbnailDecodesWithoutUsingThePlaybackSession() async throws {
        guard let fixtureDirectory else { return }
        let generator = NativeTimelineThumbnailGenerator()
        let url = fixtureDirectory.appendingPathComponent("h264-aac.mp4")
        let image = await generator.thumbnail(
            for: url,
            at: 1.25,
            maximumPixelSize: CGSize(width: 320, height: 180)
        )
        let thumbnail = try #require(image)

        #expect(thumbnail.width > 0)
        #expect(thumbnail.height > 0)
        #expect(thumbnail.width <= 320)
        #expect(thumbnail.height <= 180)

        let clock = ContinuousClock()
        let cacheLookupStartedAt = clock.now
        let cached = await generator.thumbnail(
            for: url,
            at: 1.26,
            maximumPixelSize: CGSize(width: 320, height: 180),
            delayBeforeDecoding: .seconds(1)
        )
        #expect(cached === thumbnail)
        #expect(clock.now - cacheLookupStartedAt < .milliseconds(500))

        // A cache miss reuses the serial decoder and can seek backwards after
        // an earlier request has already decoded farther into the file.
        let earlier = await generator.thumbnail(
            for: url, at: 0.25, maximumPixelSize: CGSize(width: 320, height: 180)
        )
        #expect(earlier != nil)
    }

    @Test func timelineThumbnailDrainsTheOnlyFrameAtEndOfFile() async throws {
        guard let fixtureDirectory else { return }
        let generator = NativeTimelineThumbnailGenerator()
        let image = await generator.thumbnail(
            for: fixtureDirectory.appendingPathComponent("single-frame-h264.mp4"),
            at: 0, maximumPixelSize: CGSize(width: 64, height: 64)
        )
        let thumbnail = try #require(image)
        #expect(thumbnail.width == 64)
        #expect(thumbnail.height == 64)
    }

    @Test func clearingThumbnailCacheReopensReplacedContentAtTheSamePath() async throws {
        guard let fixtureDirectory else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("replaceable.mp4")
        try FileManager.default.copyItem(at: fixtureDirectory.appendingPathComponent("single-frame-h264.mp4"), to: file)
        let generator = NativeTimelineThumbnailGenerator()
        let first = await generator.thumbnail(for: file, at: 0, maximumPixelSize: CGSize(width: 320, height: 180))
        #expect(first?.width == 64)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: fixtureDirectory.appendingPathComponent("h264-aac.mp4"), to: file)
        await generator.removeAllCachedThumbnails()
        let replacement = await generator.thumbnail(for: file, at: 0, maximumPixelSize: CGSize(width: 320, height: 180))
        #expect(replacement?.width == 320)
        #expect(replacement?.height == 180)
    }

    @Test func retiredThumbnailSourceCannotInvalidateOrReuseTheCurrentCache() async throws {
        guard let fixtureDirectory else { return }
        let generator = NativeTimelineThumbnailGenerator()
        let url = fixtureDirectory.appendingPathComponent("h264-aac.mp4")
        let current = try #require(await generator.thumbnail(for: url, at: 1,
            maximumPixelSize: CGSize(width: 320, height: 180), sourceRevision: 2))
        await generator.invalidate(for: 1)
        #expect(await generator.thumbnail(for: url, at: 1,
            maximumPixelSize: CGSize(width: 320, height: 180), sourceRevision: 1) == nil)
        #expect(await generator.thumbnail(for: url, at: 1,
            maximumPixelSize: CGSize(width: 320, height: 180), sourceRevision: 2) === current)
    }

    @Test func demuxSeekRejectsUnrepresentableTimestampsWithoutChangingInput() throws {
        guard let fixtureDirectory else { return }
        let demuxer = try FFmpegDemuxer(url: fixtureDirectory.appendingPathComponent("h264-aac.mp4"))
        for seconds in [Double(Int64.max) / 1_000_000, Double.greatestFiniteMagnitude, .infinity, .nan] {
            #expect(throws: FFmpegError.self) { try demuxer.seek(to: seconds, exact: true) }
        }
        #expect(try demuxer.readPacket(generation: 1) != nil)
    }

    @Test(arguments: ["h264-aac.mp4", "hevc-10bit-aac.mkv", "vp9-opus.mkv"])
    @MainActor
    func seekStageMatrixRecordsFirstAndRepeatedNativeTransactions(filename: String) async throws {
        guard let fixtureDirectory else { return }
        let backend = try NativePlaybackRuntime()
        _ = try backend.makeSurfaceHost()
        let source = MediaSource.localFile(fixtureDirectory.appendingPathComponent(filename))
        let request = try #require(MediaLoadRequest(source: source, origin: .userSelected))
        try backend.load(PlaybackRuntimeLoadRequest(media: request,
            identity: PlayerSessionIdentity(source: source, generation: 1)))
        #expect(await waitUntil(timeout: .seconds(5)) {
            backend.sessionSnapshotForDiagnostics?.isPrerolled == true
        })
        backend.pause()
        for target in [0.25, 1.5, 2.25, 0.5, 2.0, 1.0] {
            backend.seek(to: target, mode: .absoluteExact)
            let generation = try #require(backend.sessionSnapshotForDiagnostics?.generation)
            #expect(await waitUntil(timeout: .seconds(5)) {
                guard let snapshot = backend.sessionSnapshotForDiagnostics else { return false }
                return snapshot.generation == generation && snapshot.seekTimings?.milliseconds[.prerollCompleted] != nil
            })
            let snapshot = try #require(backend.sessionSnapshotForDiagnostics)
            let timings = try #require(snapshot.seekTimings)
            let firstVideoPTS = try #require(snapshot.firstEnqueuedVideoPTS)
            #expect(snapshot.rendererFailure == nil)
            #expect(firstVideoPTS + 0.001 >= target)
            print("seek-matrix fixture=\(filename) target=\(target) first-video-pts=\(firstVideoPTS) hardware=\(snapshot.isHardwareDecoded) \(timings.summary)")
        }
        await backend.shutdown()
    }

    @Test(arguments: ["h264-aac.mp4", "interlaced-tff.mpg", "nonzero-start.mkv"])
    func seekPrerollSkipsOutputConversionWithoutChangingTargetFrames(filename: String) throws {
        guard let fixtureDirectory else { return }
        let target = filename == "nonzero-start.mkv" ? 0.5 : 1.0
        func decode(earlyDiscard: Bool) throws -> (times: [Double], firstLuma: Data, checkouts: Int, discarded: Int) {
            let demuxer = try FFmpegDemuxer(url: fixtureDirectory.appendingPathComponent(filename))
            let stream = try #require(demuxer.mediaInfo.videoStreams.first)
            let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
            let decoder = try VideoDecoder(parameters: parameters, stream: stream,
                preferHardware: false, timelineOriginSeconds: demuxer.mediaInfo.startTime,
                softwareOutputMode: .planarExperiment(rendererAttributes: [:]),
                // This test counts conversion avoidance only. Decoder-level
                // skipping has separate pixel/PTS equivalence qualification.
                seekPrerollFrameSkippingEnabled: false)
            if earlyDiscard { decoder.seekOutputFloor = (1, target) }
            var times: [Double] = []
            var firstLuma = Data()
            func receive(_ frame: NativeDecodedVideoFrame) throws {
                guard frame.presentationTime.seconds + 0.001 >= target else { return }
                times.append(frame.presentationTime.seconds)
                if firstLuma.isEmpty {
                    let buffer = frame.pixelBuffer
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                    let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
                    for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 0) {
                        firstLuma.append(base.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
                            .assumingMemoryBound(to: UInt8.self), count: CVPixelBufferGetWidthOfPlane(buffer, 0))
                    }
                }
            }
            while let packet = try demuxer.readPacket(generation: 1) {
                if packet.streamIndex == stream.index {
                    try decoder.decode(packet, while: { true }, emit: receive)
                }
            }
            try decoder.drain(generation: 1, while: { true }, emit: receive)
            return (times, firstLuma, decoder.planarOutputDiagnostics?.checkouts ?? 0,
                    decoder.discardedSeekPrerollFrames)
        }
        let baseline = try decode(earlyDiscard: false)
        let optimized = try decode(earlyDiscard: true)
        #expect(!baseline.times.isEmpty)
        #expect(optimized.times == baseline.times)
        #expect(optimized.firstLuma == baseline.firstLuma)
        #expect(optimized.discarded > 0)
        #expect(baseline.checkouts - optimized.checkouts == optimized.discarded)
        print("seek-preroll \(filename): output-checkouts \(baseline.checkouts) -> \(optimized.checkouts); pre-target-discarded=\(optimized.discarded)")
    }

    private func firstVideoFrame(
        filename: String,
        preferHardware: Bool = true
    ) throws -> (FFmpegStreamInfo, NativeDecodedVideoFrame) {
        let directory = try #require(fixtureDirectory)
        let demuxer = try FFmpegDemuxer(url: directory.appendingPathComponent(filename))
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(
            parameters: parameters,
            stream: stream,
            preferHardware: preferHardware
        )
        for _ in 0..<500 {
            guard let packet = try demuxer.readPacket(generation: 1) else { break }
            guard packet.streamIndex == stream.index else { continue }
            if let frame = try decoder.decode(packet).first { return (stream, frame) }
        }
        throw PresentationError("No video frame decoded from \(filename)")
    }

    private func firstAudioFrame(
        filename: String
    ) throws -> (FFmpegStreamInfo, NativeDecodedAudioFrame) {
        let directory = try #require(fixtureDirectory)
        let demuxer = try FFmpegDemuxer(url: directory.appendingPathComponent(filename))
        let stream = try #require(demuxer.mediaInfo.audioStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try AudioDecoder(parameters: parameters, stream: stream)
        for _ in 0..<500 {
            guard let packet = try demuxer.readPacket(generation: 1) else { break }
            guard packet.streamIndex == stream.index else { continue }
            if let frame = try decoder.decode(packet).first { return (stream, frame) }
        }
        throw PresentationError("No audio frame decoded from \(filename)")
    }

    @Test func discoversContainerStreamsAndDecodesAudioVideo() throws {
        guard let fixtureDirectory else { return }
        let demuxer = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("h264-aac.mp4")
        )
        #expect(!demuxer.mediaInfo.videoStreams.isEmpty)
        #expect(!demuxer.mediaInfo.audioStreams.isEmpty)
        #expect(demuxer.mediaInfo.duration > 2.5)

        let videoStream = try #require(demuxer.mediaInfo.videoStreams.first)
        let audioStream = try #require(demuxer.mediaInfo.audioStreams.first)
        let videoParameters = try #require(
            demuxer.codecParameters(streamIndex: videoStream.index)
        )
        let audioParameters = try #require(
            demuxer.codecParameters(streamIndex: audioStream.index)
        )
        let videoDecoder = try VideoDecoder(
            parameters: videoParameters,
            stream: videoStream,
            preferHardware: true
        )
        let audioDecoder = try AudioDecoder(parameters: audioParameters, stream: audioStream)

        var videoFrames: [NativeDecodedVideoFrame] = []
        var audioFrames: [NativeDecodedAudioFrame] = []
        while videoFrames.isEmpty || audioFrames.isEmpty {
            guard let packet = try demuxer.readPacket(generation: 7) else { break }
            if packet.streamIndex == videoStream.index {
                videoFrames += try videoDecoder.decode(packet)
            } else if packet.streamIndex == audioStream.index {
                audioFrames += try audioDecoder.decode(packet)
            }
        }
        let video = try #require(videoFrames.first)
        let audio = try #require(audioFrames.first)
        #expect(video.generation == 7)
        #expect(video.presentationTime.isNumeric)
        #expect(video.codedSize == CGSize(width: 640, height: 360))
        #expect(video.isHardwareDecoded)
        #expect(video.isNearZeroCopy)
        #expect(!video.isCopiedHardwarePath)
        #expect(audio.sampleRate == 48_000)
        #expect(audio.channelCount == 2)
        #expect(audio.sampleCount > 0)
        #expect(audio.conversionOccurred)
    }

    @Test func corruptVideoPacketsAreDroppedWithoutTerminatingSoftwareDecode() throws {
        guard let fixtureDirectory else { return }
        let demuxer = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("corrupt-packets.mkv")
        )
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(
            demuxer.codecParameters(streamIndex: stream.index)
        )
        let decoder = try VideoDecoder(
            parameters: parameters,
            stream: stream,
            preferHardware: false
        )
        var decodedFrameCount = 0
        var lastPresentationSeconds: Double?

        while let packet = try demuxer.readPacket(generation: 1) {
            guard packet.streamIndex == stream.index else { continue }
            for frame in try decoder.decode(packet) {
                decodedFrameCount += 1
                if frame.presentationTime.isNumeric {
                    lastPresentationSeconds = frame.presentationTime.seconds
                }
            }
        }

        #expect(decodedFrameCount > 1)
        #expect((lastPresentationSeconds ?? 0) > 2)
        #expect(decoder.droppedSoftwareDecodeErrors > 0)
    }

    @Test func videoRecoveryPacketBufferReplaysFromAKeyframeOnce() throws {
        guard let fixtureDirectory else { return }
        let demuxer = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("h264-aac.mp4")
        )
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let recoveryPackets = VideoRecoveryPacketBuffer()
        var recorded: [FFmpegPacket] = []

        while recorded.count < 12,
              let packet = try demuxer.readPacket(generation: 7)
        {
            guard packet.streamIndex == stream.index else { continue }
            recoveryPackets.record(packet)
            recorded.append(packet)
        }

        #expect(try #require(recorded.first).isKeyframe)
        let replay = recoveryPackets.takeReplayPackets(generation: 7)
        #expect(replay.count == recorded.count)
        #expect(replay.first?.isKeyframe == true)
        #expect(
            replay.map(\.presentationTimestamp)
                == recorded.map(\.presentationTimestamp)
        )
        #expect(recoveryPackets.takeReplayPackets(generation: 7).isEmpty)
    }

    @Test func recreatesSoftwareDecoderAfterHardwarePathFailure() throws {
        guard let fixtureDirectory else { return }
        let demuxer = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("h264-aac.mp4")
        )
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(
            demuxer.codecParameters(streamIndex: stream.index)
        )
        let decoder = try VideoDecoder(
            parameters: parameters,
            stream: stream,
            preferHardware: true
        )

        var hardwareFrame: NativeDecodedVideoFrame?
        for _ in 0..<300 where hardwareFrame == nil {
            guard let packet = try demuxer.readPacket(generation: 1) else { break }
            guard packet.streamIndex == stream.index else { continue }
            hardwareFrame = try decoder.decode(packet).first
        }
        #expect(try #require(hardwareFrame).isHardwareDecoded)
        #expect(try decoder.switchToSoftware())
        #expect(decoder.softwareFallbackActivated)
        #expect(!decoder.hardwareWasConfigured)
        #expect(try !decoder.switchToSoftware())

        try demuxer.seek(to: 0, exact: false)
        var softwareFrame: NativeDecodedVideoFrame?
        for _ in 0..<300 where softwareFrame == nil {
            guard let packet = try demuxer.readPacket(generation: 2) else { break }
            guard packet.streamIndex == stream.index else { continue }
            softwareFrame = try decoder.decode(packet).first
        }
        let recovered = try #require(softwareFrame)
        #expect(recovered.generation == 2)
        #expect(!recovered.isHardwareDecoded)
        #expect(!recovered.isNearZeroCopy)
        #expect(!recovered.isCopiedHardwarePath)
    }

    @Test func recreatesSoftwareDecoderFromBufferedGOPWithoutSeeking() throws {
        guard let fixtureDirectory else { return }
        let demuxer = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("h264-aac.mp4")
        )
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(
            demuxer.codecParameters(streamIndex: stream.index)
        )
        let decoder = try VideoDecoder(
            parameters: parameters,
            stream: stream,
            preferHardware: true
        )
        let recoveryPackets = VideoRecoveryPacketBuffer()
        var videoPacketCount = 0

        while videoPacketCount < 48,
              let packet = try demuxer.readPacket(generation: 9)
        {
            guard packet.streamIndex == stream.index else { continue }
            recoveryPackets.record(packet)
            _ = try decoder.decode(packet)
            videoPacketCount += 1
        }

        #expect(try decoder.switchToSoftware())
        let replay = recoveryPackets.takeReplayPackets(generation: 9)
        #expect(replay.first?.isKeyframe == true)
        var recoveredFrameCount = 0
        for packet in replay {
            // Consume each output immediately: retaining a whole GOP would
            // exhaust the production pool before the test can release it.
            try decoder.decode(packet, while: { true }) { frame in
                recoveredFrameCount += 1
                #expect(!frame.isHardwareDecoded)
            }
        }
        #expect(recoveredFrameCount > 0)
    }

    @Test(arguments: [
        ("hdr10-pq-p010.mkv", Int32(16), true),
        ("hlg-p010.mkv", Int32(18), false),
    ])
    func preservesHDRColorMetadataAndP010(
        filename: String,
        expectedTransfer: Int32,
        expectsStaticMetadata: Bool
    ) throws {
        guard let fixtureDirectory,
              FileManager.default.fileExists(
                atPath: fixtureDirectory.appendingPathComponent(filename).path
              )
        else { return }
        let (_, frame) = try firstVideoFrame(filename: filename)
        let pixelFormat = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        #expect(frame.isHardwareDecoded)
        #expect(pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(frame.colorPrimaries == 9)
        #expect(frame.transferCharacteristic == expectedTransfer)
        #expect(frame.matrixCoefficients == 9)
        if expectsStaticMetadata {
            #expect(frame.hasMasteringDisplayMetadata)
            #expect(frame.hasContentLightMetadata)
        }
    }

    @Test @MainActor func appliesRotationAndUsesRotatedSubtitleViewport() throws {
        guard let fixtureDirectory,
              FileManager.default.fileExists(
                atPath: fixtureDirectory.appendingPathComponent("rotated-90.mp4").path
              )
        else { return }
        let (stream, _) = try firstVideoFrame(filename: "rotated-90.mp4")
        #expect(abs(abs(stream.rotationDegrees) - 90) < 0.1)
        #expect(stream.displaySize == CGSize(width: 360, height: 640))

        let presenter = SampleBufferVideoPresenter()
        let overlay = SubtitleOverlayView()
        let view = NativePlayerNSView(
            videoLayer: presenter.displayLayer,
            subtitleOverlay: overlay,
            rotationDegrees: stream.rotationDegrees
        )
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        #expect(presenter.displayLayer.bounds.size == CGSize(width: 600, height: 800))
        let viewport = VideoViewport.aspectFit(
            displaySize: try #require(stream.displaySize),
            in: view.bounds
        )
        #expect(abs(viewport.width - 337.5) < 0.1)
        #expect(abs(viewport.height - 600) < 0.1)
        #expect(overlay.frame == view.bounds)
    }

    @Test @MainActor func nativeSurfaceSurvivesRepeatedWindowResizing() {
        let presenter = SampleBufferVideoPresenter()
        let overlay = SubtitleOverlayView()
        let view = NativePlayerNSView(
            videoLayer: presenter.displayLayer,
            subtitleOverlay: overlay,
            rotationDegrees: 0
        )

        for iteration in 0..<250 {
            let width = 720 + CGFloat((iteration * 47) % 720)
            let height = 440 + CGFloat((iteration * 31) % 440)
            view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            view.layoutSubtreeIfNeeded()
            #expect(presenter.displayLayer.bounds.size == view.bounds.size)
            #expect(overlay.frame == view.bounds)
            #expect(view.bounds.width.isFinite)
            #expect(view.bounds.height.isFinite)
        }
    }

    @Test @MainActor func nativeSurfaceResolvesOnlyTheWindowVisibleRegion() {
        let viewBounds = CGRect(x: 0, y: 0, width: 2_560, height: 1_440)
        let windowVisibleRect = CGRect(x: 0, y: 0, width: 1_200, height: 760)

        #expect(
            NativePlayerNSView.resolvePresentationBounds(
                viewBounds: viewBounds,
                visibleRect: windowVisibleRect,
                isAttachedToWindow: true
            ) == windowVisibleRect
        )
        #expect(
            NativePlayerNSView.resolvePresentationBounds(
                viewBounds: viewBounds,
                visibleRect: CGRect(
                    x: 0,
                    y: 0,
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                isAttachedToWindow: false
            ) == viewBounds
        )
    }

    @Test func libassBitmapCacheOverrideRequiresBenchmarkGate() {
        #expect(LibassContext.bitmapCacheMegabytes(environment: [:]) == 32)
        #expect(
            LibassContext.bitmapCacheMegabytes(environment: [
                "ILLIQUID_BENCHMARK_ASS_BITMAP_CACHE_MB": "64",
            ]) == 32
        )
        #expect(
            LibassContext.bitmapCacheMegabytes(environment: [
                "ILLIQUID_ENABLE_BENCHMARK_OVERRIDES": "1",
                "ILLIQUID_BENCHMARK_ASS_BITMAP_CACHE_MB": "64",
            ]) == 64
        )
        #expect(
            LibassContext.bitmapCacheMegabytes(environment: [
                "ILLIQUID_ENABLE_BENCHMARK_OVERRIDES": "1",
                "ILLIQUID_BENCHMARK_ASS_BITMAP_CACHE_MB": "512",
            ]) == 32
        )
    }

    @Test(arguments: [
        ("audio-5.1.flac", 6, "5.1"),
        ("audio-7.1.flac", 8, "7.1"),
    ])
    func safelyDownmixesMultichannelAudio(
        filename: String,
        sourceChannels: Int,
        expectedLayout: String
    ) throws {
        guard let fixtureDirectory,
              FileManager.default.fileExists(
                atPath: fixtureDirectory.appendingPathComponent(filename).path
              )
        else { return }
        let (stream, frame) = try firstAudioFrame(filename: filename)
        #expect(stream.channelCount == sourceChannels)
        #expect(stream.channelLayout?.contains(expectedLayout) == true)
        #expect(frame.sourceChannelCount == sourceChannels)
        #expect(frame.sourceChannelLayout.contains(expectedLayout))
        #expect(frame.channelCount == 2)
        #expect(frame.downmixOccurred)
        let samples = frame.interleavedFloatPCM.withUnsafeBytes {
            Array($0.bindMemory(to: Float.self))
        }
        #expect(!samples.isEmpty)
        #expect(samples.allSatisfy { $0.isFinite })
        #expect(samples.map { abs($0) }.max().map { $0 <= 1.001 } == true)
        #expect(samples.contains { abs($0) > 0.001 })
    }

    @Test @MainActor func heavyAnimatedASSAndFontRegistrationRemainBounded() async throws {
        guard let fixtureDirectory else { return }
        let heavyURL = fixtureDirectory.appendingPathComponent("heavy-animated.ass")
        guard FileManager.default.fileExists(atPath: heavyURL.path) else { return }

        let embedded = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("embedded-ass-font.mkv")
        )
        let context = try LibassContext()
        for _ in 0..<20 {
            for attachment in embedded.mediaInfo.attachments {
                #expect(context.register(attachment))
            }
        }
        #expect(context.registeredFonts.count == embedded.mediaInfo.attachments.count)

        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView())
        try pipeline.loadExternal(url: heavyURL)
        let baselineHeap = ProcessHeapMemory.bytesInUse()
        var maximumRegions = 0
        var renderedBytesBySize: [CGSize: Int] = [:]
        for size in [CGSize(width: 1_920, height: 1_080), CGSize(width: 3_840, height: 2_160)] {
            try autoreleasepool {
                let packer = ASSSubtitleFramePacker()
                let clock = ContinuousClock()
                let start = clock.now
                var finalRegions: [ASSRenderedRegion] = []
                for frameIndex in 0..<45 {
                    try autoreleasepool {
                        let regions = pipeline.renderedRegions(
                            at: CMTime(
                                seconds: Double(frameIndex) / 20,
                                preferredTimescale: 1_000
                            ),
                            viewport: CGRect(origin: .zero, size: size),
                            videoSize: size
                        )
                        maximumRegions = max(maximumRegions, regions.count)
                        finalRegions = regions
                        let frame = try #require(packer.prepare(
                            regions: regions,
                            canvasSize: size,
                            strategy: .metalR8Atlas
                        ))
                        // Pixel equivalence and GPU upload are covered by the
                        // compositor matrix. This gate measures the heavy ASS
                        // libass/packing path without folding disposable
                        // full-canvas test readbacks into playback memory.
                        #expect(frame.metrics.imageCount == regions.count)
                    }
                }
                let elapsed = start.duration(to: clock.now)
                #expect(elapsed < .seconds(30))
                let renderedByteCount = finalRegions.reduce(0) {
                    $0 + $1.bitmap.count
                }
                renderedBytesBySize[size] = renderedByteCount
                print(
                    "native ASS compositor: \(Int(size.width))x\(Int(size.height)) "
                        + "regions=\(finalRegions.count) elapsed=\(elapsed) "
                        + "bitmapBytes=\(renderedByteCount)"
                )
                #expect(
                    packer.retainedStorageByteCountForTesting
                        <= 128 * 1_024 * 1_024
                )
                packer.retireSource()
                #expect(packer.retainedStorageByteCountForTesting == 0)
            }
        }
        let finalHeap = ProcessHeapMemory.bytesInUse()
        #expect(maximumRegions >= 20)
        #expect((renderedBytesBySize[CGSize(width: 3_840, height: 2_160)] ?? 0)
            > (renderedBytesBySize[CGSize(width: 1_920, height: 1_080)] ?? 0))
        #expect(finalHeap <= baselineHeap + 128 * 1_024 * 1_024)

        let fixedTime = CMTime(seconds: 1, preferredTimescale: 1_000)
        let hdViewport = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let uhdViewport = CGRect(x: 0, y: 0, width: 3_840, height: 2_160)
        let hdFrames = pipeline.renderedRegions(
            at: fixedTime,
            viewport: hdViewport,
            videoSize: hdViewport.size
        ).map(\.frame)
        let uhdFrames = pipeline.renderedRegions(
            at: fixedTime,
            viewport: uhdViewport,
            videoSize: uhdViewport.size
        ).map(\.frame)
        let postScaleCounters = pipeline.counters()
        print(
            "native ASS post-scale frames hd=\(hdFrames.count) uhd=\(uhdFrames.count) "
                + "limitRejections=\(postScaleCounters.resourceLimitRejections) "
                + "images=\(postScaleCounters.assImages) "
                + "maskBytes=\(postScaleCounters.maskBytes)"
        )
        #expect(!hdFrames.isEmpty)
        #expect(uhdFrames.count == hdFrames.count)
        #expect(uhdFrames != hdFrames)
    }

    @Test @MainActor func staticASSReusesUnchangedBitmapsAndSuppressesOverlayCommits() async throws {
        guard let fixtureDirectory else { return }
        let staticURL = fixtureDirectory.appendingPathComponent("external.ass")
        guard FileManager.default.fileExists(atPath: staticURL.path) else { return }

        let size = CGSize(width: 640, height: 360)
        let viewport = CGRect(origin: .zero, size: size)
        let overlay = SubtitleOverlayView(frame: viewport)
        overlay.updateDrawableSize(backingScale: 1)
        let pipeline = try SubtitlePipeline(overlay: overlay)
        try pipeline.loadExternal(url: staticURL)

        pipeline.render(
            at: CMTime(seconds: 0.5, preferredTimescale: 1_000),
            viewport: viewport,
            videoSize: size
        )
        #expect(await waitUntil {
            pipeline.counters().metalFramesSubmitted == 1
        })
        let first = pipeline.counters()
        #expect(first.requests == 1)
        #expect(first.libassFrames == 1)
        #expect(first.bitmapCopies > 0)
        #expect(first.overlayCommits == 1)
        #expect(first.metalFailures == 0)

        pipeline.render(
            at: CMTime(seconds: 0.51, preferredTimescale: 1_000),
            viewport: viewport,
            videoSize: size
        )
        #expect(await waitUntil {
            pipeline.counters().libassFrames == 2
        })
        let unchanged = pipeline.counters()
        #expect(unchanged.requests == 2)
        #expect(unchanged.libassFrames == 2)
        #expect(unchanged.libassChangedFrames == first.libassChangedFrames)
        #expect(unchanged.bitmapCopies == first.bitmapCopies)
        #expect(unchanged.overlayCommits == first.overlayCommits)

        let larger = CGSize(width: 1_280, height: 720)
        pipeline.render(
            at: CMTime(seconds: 0.51, preferredTimescale: 1_000),
            viewport: CGRect(origin: .zero, size: larger),
            videoSize: larger
        )
        #expect(await waitUntil {
            pipeline.counters().overlayCommits == unchanged.overlayCommits + 1
        })
        let resized = pipeline.counters()
        #expect(resized.bitmapCopies > unchanged.bitmapCopies)
        #expect(resized.overlayCommits == unchanged.overlayCommits + 1)
    }

    @Test @MainActor func sleepWakeAndRepeatedTeardownRemainSafe() async throws {
        guard let fixtureDirectory else { return }
        let mediaURL = fixtureDirectory.appendingPathComponent("h264-aac.mp4")
        let backend = try NativePlaybackRuntime()
        let recorder = NativeBackendEventRecorder()
        backend.eventHandler = { [weak recorder] event in recorder?.events.append(event) }
        _ = try backend.makeSurfaceHost()
        let source = MediaSource.localFile(mediaURL)
        let request = try #require(MediaLoadRequest(source: source, origin: .userSelected))
        let identity = PlayerSessionIdentity(source: source, generation: 1)
        try backend.load(PlaybackRuntimeLoadRequest(media: request, identity: identity))
        #expect(await waitUntil { recorder.events.contains { $0.payload == .loaded } })
        let loadedIndex = try #require(recorder.events.firstIndex { $0.payload == .loaded })
        let durationIndex = try #require(recorder.events.firstIndex {
            if case let .durationChanged(duration) = $0.payload { duration > 0 } else { false }
        })
        #expect(loadedIndex < durationIndex)
        backend.play()
        try await Task.sleep(for: .milliseconds(250))
        backend.pause()
        #expect(recorder.events.contains { $0.payload == .pauseChanged(true) })
        backend.resumeAfterWake(position: 0, playing: true)
        #expect(recorder.events.contains { $0.payload == .pauseChanged(false) })
        try await Task.sleep(for: .milliseconds(350))
        let presentationSnapshot = try #require(backend.sessionSnapshotForDiagnostics)
        #expect(presentationSnapshot.videoPipelineCapacity == 7)
        #expect(presentationSnapshot.videoSubmissionAttempts > 0)
        #expect(
            presentationSnapshot.videoEnqueueReturnedWithoutImmediateFailure
                == presentationSnapshot.videoSubmissionAttempts
        )
        #expect(presentationSnapshot.firstVisibleFrameSeconds == nil)
        #expect(presentationSnapshot.rendererLateFrames == nil)
        #expect(presentationSnapshot.rendererDroppedFrames == nil)
        #expect(recorder.events.contains { $0.payload == .firstFrameSubmitted })
        #expect(recorder.events.contains { event in
            if case let .diagnostic(message) = event.payload {
                return message.contains("[native-presentation]")
                    && message.contains("first-visible=unmeasured")
            }
            return false
        })
        let observationMetrics = backend.observationMetricsForDiagnostics
        #expect(observationMetrics.totalRequests > 0)
        #expect(observationMetrics.requestsBySource[.videoEnqueue, default: 0] > 0)
        #expect(observationMetrics.requestsBySource[.preroll, default: 0] > 0)
        #expect(!recorder.events.contains {
            if case .failed = $0.payload { true } else { false }
        })
        await backend.shutdown()
        #expect(recorder.events.contains { $0.payload == .shutdownCompleted })

        let baseline = ProcessResidentMemory.bytes()
        for _ in 0..<12 {
            let presentation = try NativePresentationCoordinator()
            let subtitles = try SubtitlePipeline(overlay: SubtitleOverlayView())
            let session = try MediaSession(
                url: mediaURL,
                presentation: presentation,
                subtitles: subtitles
            )
            session.start(rate: 0)
            try await Task.sleep(for: .milliseconds(35))
            session.stop()
            #expect(session.waitForShutdown(timeout: .now() + 3))
        }
        if let baseline, let finalMemory = ProcessResidentMemory.bytes() {
            #expect(finalMemory <= baseline + 160 * 1_024 * 1_024)
        }
    }

    @Test @MainActor func nativeRuntimeCoalescesPreviewSeeksBeforeFinalExactSeek() async throws {
        guard let fixtureDirectory else { return }
        let mediaURL = fixtureDirectory.appendingPathComponent("h264-aac.mp4")
        let backend = try NativePlaybackRuntime()
        _ = try backend.makeSurfaceHost()
        let source = MediaSource.localFile(mediaURL)
        let request = try #require(MediaLoadRequest(source: source, origin: .userSelected))
        let identity = PlayerSessionIdentity(source: source, generation: 1)
        try backend.load(PlaybackRuntimeLoadRequest(media: request, identity: identity))
        #expect(await waitUntil { backend.sessionSnapshotForDiagnostics != nil })
        backend.pause()

        for target in [0.2, 2.5, 0.6, 2.2, 0.9, 1.9, 0.1, 2.7] {
            backend.seek(to: target, mode: .absolutePreview)
        }
        let previewSnapshot = try #require(backend.sessionSnapshotForDiagnostics)
        #expect(previewSnapshot.seekCount == 1)
        #expect(previewSnapshot.generation == 1)

        try await Task.sleep(for: .milliseconds(700))
        let coalescedSnapshot = try #require(backend.sessionSnapshotForDiagnostics)
        #expect(coalescedSnapshot.seekCount == 2)
        #expect(coalescedSnapshot.generation == 2)

        backend.seek(to: 1.5, mode: .absoluteExact)
        let finalSnapshot = try #require(backend.sessionSnapshotForDiagnostics)
        #expect(finalSnapshot.seekCount == 3)
        #expect(finalSnapshot.generation == 3)
        #expect(await waitUntil {
            backend.sessionSnapshotForDiagnostics?.seekTimings?.milliseconds[.prerollCompleted] != nil
        })
        let timings = try #require(backend.sessionSnapshotForDiagnostics?.seekTimings)
        let demuxStarted = try #require(timings.milliseconds[.demuxStarted])
        let demuxCompleted = try #require(timings.milliseconds[.demuxCompleted])
        let decoded = try #require(timings.milliseconds[.targetVideoDecoded])
        let videoEnqueued = try #require(timings.milliseconds[.videoEnqueued])
        let audioEnqueued = try #require(timings.milliseconds[.audioEnqueued])
        let completed = try #require(timings.milliseconds[.prerollCompleted])
        #expect(timings.generation == 3)
        #expect(demuxStarted <= demuxCompleted)
        #expect(demuxCompleted <= decoded)
        #expect(decoded <= videoEnqueued)
        #expect(completed >= max(videoEnqueued, audioEnqueued))
        #expect(timings.milliseconds[.rendererClockAdvanced] == nil)
        print("paused exact seek: \(timings.summary)")
        await backend.shutdown()
    }

    @Test @MainActor
    func delayedAudioTailReachesEOFOnlyAfterRendererDrain() async throws {
        guard let fixtureDirectory else { return }
        let mediaURL = fixtureDirectory.appendingPathComponent("delayed-audio-tail.mkv")
        let backend = try NativePlaybackRuntime()
        let recorder = NativeBackendEventRecorder()
        backend.eventHandler = { [weak recorder] event in
            recorder?.events.append(event)
        }
        _ = try backend.makeSurfaceHost()
        let source = MediaSource.localFile(mediaURL)
        let request = try #require(MediaLoadRequest(source: source, origin: .userSelected))
        let identity = PlayerSessionIdentity(source: source, generation: 1)
        try backend.load(PlaybackRuntimeLoadRequest(media: request, identity: identity))
        #expect(await waitUntil { recorder.events.contains { $0.payload == .loaded } })

        backend.play()
        #expect(await waitUntil(timeout: .seconds(5)) {
            recorder.events.contains { $0.payload == .endOfFile }
        })
        let snapshot = try #require(backend.sessionSnapshotForDiagnostics)
        #expect(snapshot.decoderDrainComplete)
        #expect(snapshot.rendererDrainEvidence)
        #expect(snapshot.ended)
        await backend.shutdown()
    }

    @Test @MainActor
    func coalescedPreviewAcknowledgesOnlyItsOriginatingEffect() async throws {
        guard let fixtureDirectory else { return }
        let mediaURL = fixtureDirectory.appendingPathComponent("h264-aac.mp4")
        let backend = try NativePlaybackRuntime()
        _ = try backend.makeSurfaceHost()
        let source = MediaSource.localFile(mediaURL)
        let request = try #require(MediaLoadRequest(source: source, origin: .userSelected))
        let identity = PlayerSessionIdentity(source: source, generation: 1)
        try backend.load(PlaybackRuntimeLoadRequest(media: request, identity: identity))
        #expect(await waitUntil {
            backend.sessionSnapshotForDiagnostics?.isPrerolled == true
        })
        backend.pause()

        var resultKinds: [PlaybackEffectID: EffectResultKind] = [:]
        var generationAtResult: [PlaybackEffectID: Int] = [:]
        backend.eventHandler = { [weak backend] event in
            guard case let .effectResult(result) = event.payload else { return }
            resultKinds[result.context.effectID] = result.token.kind
            generationAtResult[result.context.effectID] =
                backend?.sessionSnapshotForDiagnostics?.generation
        }

        func previewEffect(
            effectID: UInt64,
            operationID: UInt64,
            generation: UInt64,
            seconds: Double
        ) throws -> PlaybackEffect {
            let time = try #require(ValidMediaTime(
                value: Int64((seconds * 1_000_000).rounded()),
                timescale: 1_000_000
            ))
            return PlaybackEffect(
                executor: .input,
                context: PlaybackEffectContext(
                    authority: .playback(
                        sessionID: PlaybackSessionID(rawValue: 1),
                        generation: PlaybackGenerationID(rawValue: generation),
                        revisions: PlaybackRevisionSet()
                    ),
                    operationID: PlaybackOperationID(rawValue: operationID),
                    effectID: PlaybackEffectID(rawValue: effectID)
                ),
                kind: .seekPipeline(target: .valid(time), mode: .preview)
            )
        }

        let first = try previewEffect(
            effectID: 1,
            operationID: 1,
            generation: 1,
            seconds: 0.2
        )
        let second = try previewEffect(
            effectID: 2,
            operationID: 2,
            generation: 2,
            seconds: 2.5
        )
        backend.execute(PlaybackRuntimeEffectRequest(effect: first))
        backend.execute(PlaybackRuntimeEffectRequest(effect: second))

        #expect(await waitUntil {
            resultKinds[second.context.effectID] == .succeeded
        })
        #expect(resultKinds[first.context.effectID] == .cancelled)
        #expect(
            generationAtResult[second.context.effectID] == 2,
            "The second preview effect must not succeed on the first preview's native callback."
        )
        backend.eventHandler = nil
        await backend.shutdown()
    }

    @Test @MainActor
    func wakeEffectReappliesRequestedPresentationRateAfterPreroll() async throws {
        guard let fixtureDirectory else { return }
        let mediaURL = fixtureDirectory.appendingPathComponent("h264-aac.mp4")
        let backend = try NativePlaybackRuntime()
        _ = try backend.makeSurfaceHost()
        let source = MediaSource.localFile(mediaURL)
        let request = try #require(MediaLoadRequest(source: source, origin: .userSelected))
        let identity = PlayerSessionIdentity(source: source, generation: 1)
        try backend.load(PlaybackRuntimeLoadRequest(media: request, identity: identity))
        #expect(await waitUntil {
            backend.sessionSnapshotForDiagnostics?.isPrerolled == true
        })
        backend.pause()

        let position = MediaTimestamp.valid(
            try #require(ValidMediaTime(value: 0, timescale: 1_000))
        )
        let effect = PlaybackEffect(
            executor: .presentation,
            context: PlaybackEffectContext(
                authority: .playback(
                    sessionID: PlaybackSessionID(rawValue: 1),
                    generation: PlaybackGenerationID(rawValue: 2),
                    revisions: PlaybackRevisionSet()
                ),
                operationID: PlaybackOperationID(rawValue: 3),
                effectID: PlaybackEffectID(rawValue: 3)
            ),
            kind: .resumeAfterWake(position: position, milliRate: 1_000)
        )
        var resultKind: EffectResultKind?
        backend.eventHandler = { event in
            guard case let .effectResult(result) = event.payload,
                  result.context.effectID == effect.context.effectID
            else { return }
            resultKind = result.token.kind
        }
        backend.execute(PlaybackRuntimeEffectRequest(effect: effect))

        #expect(await waitUntil { resultKind == .succeeded })
        #expect(backend.diagnosticSnapshot?.rendererRate == 1)
        let initialTime = backend.diagnosticSnapshot?.rendererMediaTimeSeconds ?? 0
        try await Task.sleep(for: .milliseconds(150))
        #expect(
            (backend.diagnosticSnapshot?.rendererMediaTimeSeconds ?? 0)
                > initialTime
        )
        backend.eventHandler = nil
        await backend.shutdown()
    }

    @Test(arguments: [
        "long-h264-av-sync.mkv",
        "long-hevc-p010-av-sync.mkv",
        "long-vfr-av-sync.mkv",
    ])
    @MainActor func optionalLongDurationAVSyncAndMemoryGate(filename: String) async throws {
        guard let rawDuration = ProcessInfo.processInfo.environment[
            "ILLIQUID_NATIVE_LONG_RUN_SECONDS"
        ], let requestedDuration = Double(rawDuration), requestedDuration > 0
        else {
            print("NOT RUN: optional long native playback gate (duration not configured)")
            return
        }
        guard let fixtureDirectory else {
            print("NOT RUN: optional long native playback gate (fixtures not configured)")
            return
        }
        if let selectedFixture = ProcessInfo.processInfo.environment[
            "ILLIQUID_NATIVE_LONG_RUN_FIXTURE"
        ], selectedFixture != filename {
            return
        }
        let url = fixtureDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let presentation = try NativePresentationCoordinator()
        let subtitles = try SubtitlePipeline(overlay: SubtitleOverlayView())
        let session = try MediaSession(
            url: url,
            presentation: presentation,
            subtitles: subtitles
        )
        session.start(rate: 1)
        #expect(session.requestTransport(playing: true))
        let clock = ContinuousClock()
        let start = clock.now
        var sync = AVSyncStabilityMetrics()
        var baselineMemory: UInt64?
        var peakMemory: UInt64 = 0
        var failure: String?
        var maximumVideoPacketDepth = 0
        var maximumAudioPacketDepth = 0
        var maximumVideoFrameDepth = 0
        var maximumAudioFrameDepth = 0
        var lastSnapshot = MediaSessionSnapshot()
        while start.duration(to: clock.now) < .seconds(requestedDuration) {
            try await Task.sleep(for: .milliseconds(250))
            let snapshot = session.snapshot()
            lastSnapshot = snapshot
            sync.record(audioPTS: snapshot.audioPTS, videoPTS: snapshot.videoPTS)
            failure = snapshot.rendererFailure
            maximumVideoPacketDepth = max(maximumVideoPacketDepth, snapshot.videoPacketDepth)
            maximumAudioPacketDepth = max(maximumAudioPacketDepth, snapshot.audioPacketDepth)
            maximumVideoFrameDepth = max(maximumVideoFrameDepth, snapshot.videoFrameDepth)
            maximumAudioFrameDepth = max(maximumAudioFrameDepth, snapshot.audioFrameDepth)
            if baselineMemory == nil,
               start.duration(to: clock.now) > .seconds(2)
            {
                baselineMemory = ProcessResidentMemory.bytes()
            }
            if let memory = ProcessResidentMemory.bytes() {
                peakMemory = max(peakMemory, memory)
            }
            if failure != nil { break }
        }
        let finalTime = presentation.currentTime.seconds
        session.stop()
        #expect(session.waitForShutdown(timeout: .now() + 3))
        #expect(failure == nil)
        #expect(finalTime >= requestedDuration * 0.85)
        #expect(sync.sampleCount >= Int(requestedDuration))
        #expect(lastSnapshot.framesSubmitted > 0)
        #expect(maximumVideoPacketDepth <= 96)
        #expect(maximumAudioPacketDepth <= 192)
        #expect(maximumVideoFrameDepth <= 12)
        #expect(maximumAudioFrameDepth <= 48)
        // PTS values are submission horizons rather than renderer playheads;
        // queue backpressure can keep their absolute difference above a frame.
        // Compare one-minute steady-state windows while excluding preroll and
        // the final drain instead of treating endpoint queue phases as drift.
        #expect(sync.maximumAbsoluteDifference < 2.0)
        #expect(abs(sync.steadyStateDrift()) < 0.25)
        if let baselineMemory {
            #expect(peakMemory <= baselineMemory + 96 * 1_024 * 1_024)
        }
        if filename.contains("hevc-p010") {
            #expect(lastSnapshot.isHardwareDecoded)
            #expect(lastSnapshot.pixelBufferFormat == "x420")
            #expect(lastSnapshot.transferCharacteristic == 16)
            #expect(lastSnapshot.hasMasteringDisplayMetadata)
            #expect(lastSnapshot.hasContentLightMetadata)
        }
        print(
            "native long run \(filename): requested=\(requestedDuration)s "
                + "presented=\(finalTime)s "
                + "horizonMax=\(sync.maximumAbsoluteDifference)s "
                + "steadyDrift=\(sync.steadyStateDrift())s "
                + "endpointDrainDelta=\(sync.drift)s "
                + "memoryGrowth=\(baselineMemory.map { Int64(peakMemory) - Int64($0) } ?? 0) "
                + "queuePeaks=v\(maximumVideoPacketDepth)/a\(maximumAudioPacketDepth) "
                + "framePeaks=v\(maximumVideoFrameDepth)/a\(maximumAudioFrameDepth) "
                + "submitted=\(lastSnapshot.framesSubmitted) dropped=unmeasured"
        )
    }

    @Test func detectsSubtitleAndFontAttachment() throws {
        guard let fixtureDirectory else { return }
        let url = fixtureDirectory.appendingPathComponent("embedded-ass-font.mkv")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let demuxer = try FFmpegDemuxer(url: url)
        #expect(!demuxer.mediaInfo.subtitleStreams.isEmpty)
        #expect(demuxer.mediaInfo.attachments.contains { $0.isSupportedFont })
    }

    @Test func seekInvalidatesPreSeekGeneration() throws {
        guard let fixtureDirectory else { return }
        let demuxer = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("h264-aac.mp4")
        )
        let generation = PlaybackGeneration()
        let old = generation.current
        _ = try demuxer.readPacket(generation: old)
        let current = generation.advance()
        try demuxer.seek(to: 1.5, exact: true)
        let packet = try #require(try demuxer.readPacket(generation: current))
        #expect(!generation.accepts(old))
        #expect(generation.accepts(packet.generation))
    }

    @Test func convertsMultipleAudioStreamMetadata() throws {
        guard let fixtureDirectory else { return }
        let demuxer = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("multiple-audio.mkv")
        )
        #expect(demuxer.mediaInfo.audioStreams.count == 2)
        #expect(demuxer.mediaInfo.audioStreams.map(\.language) == ["eng", "jpn"])
        #expect(demuxer.mediaInfo.audioStreams.allSatisfy { $0.codecName == "aac" })
    }

    @Test func catalogSelectionHonorsDefaultAndRetainsCommentaryMetadata() throws {
        guard let fixtureDirectory else { return }
        let demuxer = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("multiple-audio-flags.mkv")
        )
        let audio = demuxer.mediaInfo.audioStreams
        #expect(audio.count == 3)
        #expect(demuxer.mediaInfo.selectedAudioIndex == audio[0].index)
        #expect(audio[0].disposition & 1 != 0)
        #expect(audio[2].disposition & 8 != 0)
        #expect(audio.map(\.title) == ["Main", "Alternate", "Commentary"])
    }

    @Test func audioFormatChangeRebuildsResamplerAndPreservesOutputClock() throws {
        guard let fixtureDirectory else { return }
        let demuxer = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("audio-rate-layout-change.ts")
        )
        let stream = try #require(demuxer.mediaInfo.audioStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try AudioDecoder(parameters: parameters, stream: stream)
        var frames: [NativeDecodedAudioFrame] = []
        while let packet = try demuxer.readPacket(generation: 1) {
            guard packet.streamIndex == stream.index else { continue }
            frames += try decoder.decode(packet)
        }
        frames += try decoder.drain(generation: 1)
        #expect(Set(frames.map(\.sourceSampleRate)) == [44_100, 48_000])
        #expect(Set(frames.map(\.sourceChannelCount)) == [1, 2])
        #expect(Set(frames.map(\.formatRevision)) == [1, 2])
        #expect(zip(frames.dropFirst(), frames).allSatisfy { current, previous in
            current.presentationTime >= previous.presentationTime
        })
    }

    @Test(arguments: [
        ("vp9-opus.mkv", "vp9"),
        ("vp9-10bit-video-only.mkv", "vp9"),
        ("av1-video-only.mkv", "av1"),
        ("av1-10bit-video-only.mkv", "av1"),
    ])
    func codecCapabilityFixturesExposeStableDemuxIdentity(
        filename: String,
        codec: String
    ) throws {
        guard let fixtureDirectory else { return }
        let demuxer = try FFmpegDemuxer(url: fixtureDirectory.appendingPathComponent(filename))
        #expect(demuxer.mediaInfo.videoStreams.first?.codecName == codec)
        #expect(demuxer.mediaInfo.selectedVideoIndex == demuxer.mediaInfo.videoStreams.first?.index)
    }

    @Test(arguments: [
        ("rotated-90.mp4", 90.0),
        ("rotated-180.mp4", 180.0),
        ("rotated-270.mp4", 270.0),
    ])
    func rotationMatrixRetainsContainerTransforms(filename: String, degrees: Double) throws {
        guard let fixtureDirectory else { return }
        let demuxer = try FFmpegDemuxer(url: fixtureDirectory.appendingPathComponent(filename))
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let equivalentRotation = (stream.rotationDegrees - degrees)
            .truncatingRemainder(dividingBy: 360)
        #expect(abs(equivalentRotation) < 0.1)
        if degrees == 180 {
            #expect(stream.displaySize == CGSize(width: 640, height: 360))
        } else {
            #expect(stream.displaySize == CGSize(width: 360, height: 640))
        }
    }

    @Test func anamorphicFixtureUsesDisplayAspectInsteadOfCodedAspect() throws {
        guard let fixtureDirectory else { return }
        let demuxer = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("anamorphic-sar.mkv")
        )
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        #expect(stream.codedSize == CGSize(width: 720, height: 480))
        #expect(stream.pixelAspectRatio == CGSize(width: 40, height: 33))
        #expect(abs((stream.displaySize?.width ?? 0) - 872.727) < 0.01)

        let (_, frame) = try firstVideoFrame(
            filename: "anamorphic-sar.mkv",
            preferHardware: false
        )
        let pixelAspect = CVBufferCopyAttachment(
            frame.pixelBuffer,
            kCVImageBufferPixelAspectRatioKey,
            nil
        ) as? [CFString: Any]
        #expect(
            pixelAspect?[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? Int
                == 40
        )
        #expect(
            pixelAspect?[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? Int
                == 33
        )

        var description: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescriptionOut: &description
        ) == noErr)
        let presentationSize = CMVideoFormatDescriptionGetPresentationDimensions(
            try #require(description),
            usePixelAspectRatio: true,
            useCleanAperture: true
        )
        #expect(abs(presentationSize.width - 872.727) < 0.01)
        #expect(presentationSize.height == 480)
    }

    @Test(arguments: [
        "h264-aac.mp4",
        "hevc-flac.mkv",
        "vp9-opus.mkv",
        "audio-only-vorbis.ogg",
        "audio-only.mp3",
        "audio-only-pcm.wav",
    ])
    func decodesAudioFixtureMatrix(filename: String) throws {
        guard let fixtureDirectory else { return }
        let demuxer = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent(filename)
        )
        let stream = try #require(demuxer.mediaInfo.audioStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try AudioDecoder(parameters: parameters, stream: stream)
        var decoded: NativeDecodedAudioFrame?
        for _ in 0..<300 where decoded == nil {
            guard let packet = try demuxer.readPacket(generation: 1) else { break }
            guard packet.streamIndex == stream.index else { continue }
            decoded = try decoder.decode(packet).first
        }
        let frame = try #require(decoded, "No audio decoded from \(filename)")
        #expect(frame.sampleRate == 48_000)
        #expect(frame.channelCount == 2)
        #expect(frame.sampleCount > 0)
        #expect(!frame.interleavedFloatPCM.isEmpty)
    }

    @Test func resampled44100AudioFramesHaveContiguousPresentationTimes() throws {
        guard let fixtureDirectory else { return }
        let demuxer = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("audio-only.mp3")
        )
        let stream = try #require(demuxer.mediaInfo.audioStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try AudioDecoder(parameters: parameters, stream: stream)
        var previousEnd: CMTime?
        var decodedFrameCount = 0

        while decodedFrameCount < 40,
              let packet = try demuxer.readPacket(generation: 1)
        {
            guard packet.streamIndex == stream.index else { continue }
            for frame in try decoder.decode(packet) {
                // The MP3 fixture begins with encoder-delay skip metadata. Its
                // first short decoded frame and the following full frame have
                // intentionally discontinuous source timestamps; steady-state
                // resampled buffers after that boundary must be contiguous.
                if decodedFrameCount >= 2, let previousEnd {
                    #expect(CMTimeCompare(frame.presentationTime, previousEnd) == 0)
                }
                previousEnd = CMTimeAdd(frame.presentationTime, frame.duration)
                decodedFrameCount += 1
            }
        }

        #expect(decodedFrameCount >= 20)
    }

    @Test @MainActor func embeddedSRTRendersThroughLibassPipeline() throws {
        guard let fixtureDirectory else { return }
        let demuxer = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("embedded-srt.mkv")
        )
        let stream = try #require(demuxer.mediaInfo.subtitleStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try SubtitleDecoder(parameters: parameters, stream: stream)
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView())
        _ = try pipeline.configure(
            codecPrivate: demuxer.codecPrivateData(streamIndex: stream.index),
            codecName: stream.codecName,
            attachments: demuxer.mediaInfo.attachments,
            frameSize: CGSize(width: 640, height: 360),
            storageSize: CGSize(width: 640, height: 360)
        )
        for _ in 0..<300 {
            guard let packet = try demuxer.readPacket(generation: 1) else { break }
            guard packet.streamIndex == stream.index else { continue }
            for event in try decoder.decode(packet) {
                pipeline.process(event: event)
            }
        }
        let regions = pipeline.renderedRegions(
            at: CMTime(seconds: 0.8, preferredTimescale: 1_000),
            viewport: CGRect(x: 0, y: 0, width: 640, height: 360),
            videoSize: CGSize(width: 640, height: 360)
        )
        #expect(!regions.isEmpty)
        let laterRegions = pipeline.renderedRegions(
            at: CMTime(seconds: 2.0, preferredTimescale: 1_000),
            viewport: CGRect(x: 0, y: 0, width: 640, height: 360),
            videoSize: CGSize(width: 640, height: 360)
        )
        #expect(!laterRegions.isEmpty)
    }

    @Test func ffmpegSubRipDecoderNormalizesMarkupIntoASS() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "illiquid-subtitle-decoder-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("markup.srt")
        try Data("""
        1
        00:00:00,000 --> 00:00:01,000
        <i>Hello</i> <font color="#ff0000">red</font>

        2
        00:00:01,100 --> 00:00:02,000
        <b>Second cue</b>
        """.utf8).write(to: url)

        let demuxer = try FFmpegDemuxer(url: url)
        let stream = try #require(demuxer.mediaInfo.subtitleStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try SubtitleDecoder(parameters: parameters, stream: stream)
        var events: [NativeDecodedSubtitleEvent] = []
        while let packet = try demuxer.readPacket(generation: 7) {
            guard packet.streamIndex == stream.index else { continue }
            events.append(contentsOf: try decoder.decode(packet))
        }

        #expect(events.count == 2)
        let first = try #require(String(data: events[0].assData, encoding: .utf8))
        let second = try #require(String(data: events[1].assData, encoding: .utf8))
        #expect(first.contains("{\\i1}Hello{\\i0}"))
        #expect(first.contains("{\\c&HFF&}red{\\c}"))
        #expect(!first.contains("<i>"))
        #expect(!first.contains("<font"))
        #expect(second.contains("{\\b1}Second cue{\\b0}"))
        #expect(events[0].generation == 7)
        #expect(events[0].presentationSeconds == 0)
        #expect(events[0].durationSeconds == 1)
        #expect(abs(events[1].presentationSeconds - 1.1) < 0.0001)
    }

    @Test @MainActor func subtitlePacketInvalidatesEmptyPausedSeekRender() throws {
        guard let fixtureDirectory else { return }
        let demuxer = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("embedded-srt.mkv")
        )
        let stream = try #require(demuxer.mediaInfo.subtitleStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try SubtitleDecoder(parameters: parameters, stream: stream)
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView())
        let size = CGSize(width: 640, height: 360)
        let viewport = CGRect(origin: .zero, size: size)
        _ = try pipeline.configure(
            codecPrivate: demuxer.codecPrivateData(streamIndex: stream.index),
            codecName: stream.codecName,
            attachments: demuxer.mediaInfo.attachments,
            frameSize: size,
            storageSize: size
        )
        let pausedTarget = CMTime(seconds: 0.8, preferredTimescale: 1_000)

        #expect(pipeline.renderedRegions(
            at: pausedTarget,
            viewport: viewport,
            videoSize: size
        ).isEmpty)

        for _ in 0..<300 {
            guard let packet = try demuxer.readPacket(generation: 1) else { break }
            if packet.streamIndex == stream.index {
                for event in try decoder.decode(packet) {
                    pipeline.process(event: event)
                }
                break
            }
        }

        #expect(!pipeline.renderedRegions(
            at: pausedTarget,
            viewport: viewport,
            videoSize: size
        ).isEmpty)
    }

    @Test(arguments: [
        "external.ass", "external.srt", "external.ssa", "external.vtt", "missing-glyph.ass",
    ])
    @MainActor
    func libassRendersExternalSubtitleAndRegistersEmbeddedFont(
        filename: String
    ) throws {
        guard let fixtureDirectory else { return }
        let external = fixtureDirectory.appendingPathComponent(filename)
        let embedded = try FFmpegDemuxer(
            url: fixtureDirectory.appendingPathComponent("embedded-ass-font.mkv")
        )
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView())
        let registered = try pipeline.configure(
            codecPrivate: nil,
            codecName: nil,
            attachments: embedded.mediaInfo.attachments,
            frameSize: CGSize(width: 640, height: 360),
            storageSize: CGSize(width: 640, height: 360)
        )
        #expect(registered.count == embedded.mediaInfo.attachments.count)
        try pipeline.loadExternal(url: external)
        let regions = pipeline.renderedRegions(
            at: CMTime(seconds: 1, preferredTimescale: 1_000),
            viewport: CGRect(x: 0, y: 0, width: 640, height: 360),
            videoSize: CGSize(width: 640, height: 360)
        )
        #expect(!regions.isEmpty)
        #expect(regions.allSatisfy { !$0.bitmap.isEmpty })
    }

    @Test @MainActor func rapidSeekingAndShutdownKeepLatestGeneration() async throws {
        guard let fixtureDirectory else { return }
        let presentation = try NativePresentationCoordinator()
        let subtitles = try SubtitlePipeline(overlay: SubtitleOverlayView())
        let session = try MediaSession(
            url: fixtureDirectory.appendingPathComponent("h264-aac.mp4"),
            presentation: presentation,
            subtitles: subtitles
        )
        session.start(rate: 0)
        let targets = [0.2, 2.5, 0.6, 2.2, 0.9, 1.9, 0.1, 2.7, 1.2, 0.4, 2.0, 1.5]
        for (index, target) in targets.enumerated() {
            session.seek(
                to: target,
                exact: index == targets.indices.last,
                resumeRate: 0
            )
        }
        try await Task.sleep(for: .milliseconds(700))
        let snapshot = session.snapshot()
        #expect(snapshot.hardwareFallbackCount <= 1)
        #expect(snapshot.generation == targets.count + snapshot.hardwareFallbackCount)
        #expect(snapshot.seekCount == targets.count + snapshot.hardwareFallbackCount)
        #expect(snapshot.rendererFailure == nil)
        session.stop()
        #expect(session.waitForShutdown(timeout: .now() + 3))
    }

    @Test @MainActor func fileAndAudioTrackReplacementTearsDownOldSession() async throws {
        guard let fixtureDirectory else { return }
        let presentation = try NativePresentationCoordinator()
        let subtitles = try SubtitlePipeline(overlay: SubtitleOverlayView())
        let first = try MediaSession(
            url: fixtureDirectory.appendingPathComponent("h264-aac.mp4"),
            presentation: presentation,
            subtitles: subtitles
        )
        first.start(rate: 0)
        try await Task.sleep(for: .milliseconds(100))
        first.stop()

        let multiAudioURL = fixtureDirectory.appendingPathComponent("multiple-audio.mkv")
        let metadata = try FFmpegDemuxer(url: multiAudioURL).mediaInfo
        let secondTrack = try #require(metadata.audioStreams.last)
        let replacement = try MediaSession(
            url: multiAudioURL,
            presentation: presentation,
            subtitles: subtitles,
            selectedAudioIndex: secondTrack.index
        )
        #expect(replacement.activeAudioStream?.index == secondTrack.index)
        replacement.start(rate: 0)
        try await Task.sleep(for: .milliseconds(400))
        #expect(replacement.snapshot().rendererFailure == nil)
        replacement.stop()
        #expect(first.waitForShutdown(timeout: .now() + 3))
        #expect(replacement.waitForShutdown(timeout: .now() + 3))
    }

    @Test @MainActor
    func candidateDecodePrerollLeavesCommittedSessionAndSubtitleContextActive() async throws {
        guard let fixtureDirectory else { return }
        let mediaURL = fixtureDirectory.appendingPathComponent("h264-aac.mp4")
        let presentation = try NativePresentationCoordinator()
        let overlay = SubtitleOverlayView()
        let committedSubtitles = try SubtitlePipeline(overlay: overlay)
        let committed = try MediaSession(
            url: mediaURL,
            presentation: presentation,
            subtitles: committedSubtitles
        )
        committed.start(rate: 0)
        #expect(await waitUntil {
            committed.snapshot().isPrerolled
        })
        let committedContext = committedSubtitles.libassContextIdentityForTesting()
        let committedFence = committed.snapshot().presentationFence

        let candidateSubtitles = try SubtitlePipeline(overlay: overlay)
        candidateSubtitles.setPresentationAuthorityEnabled(false)
        let candidate = try MediaSession(
            url: mediaURL,
            presentation: presentation,
            subtitles: candidateSubtitles
        )
        #expect(
            committedSubtitles.libassContextIdentityForTesting()
                == committedContext,
            "Candidate construction must not reconfigure the committed libass context."
        )
        #expect(candidate.prepareForCommit())
        #expect(await waitUntil {
            candidate.isPreparedForCommit
        })
        #expect(committed.snapshot().isPrerolled)
        #expect(committed.snapshot().presentationFence == committedFence)
        #expect(candidate.snapshot().framesSubmitted == 0)

        committed.suspendPresentationForReplacement()
        committed.setSubtitlePresentationAuthorityEnabled(false)
        candidate.setSubtitlePresentationAuthorityEnabled(true)
        let fence = presentation.configureMembership(
            hasVideo: true,
            hasAudio: true
        )
        candidate.adoptPresentationFence(fence)
        #expect(candidate.commitPrepared(rate: 0))
        #expect(await waitUntil {
            candidate.snapshot().isPrerolled
        })

        committed.stop(releasesPresentation: false)
        candidate.stop()
        #expect(committed.waitForShutdown(timeout: .now() + 3))
        #expect(candidate.waitForShutdown(timeout: .now() + 3))
    }

    @Test @MainActor
    func externalSubtitleSourceRejectsEmbeddedIngressAndSurvivesAudioCandidate() async throws {
        guard let fixtureDirectory else { return }
        let embeddedURL = fixtureDirectory.appendingPathComponent("embedded-srt.mkv")
        let mediaURL = fixtureDirectory.appendingPathComponent("multiple-audio.mkv")
        let externalURL = fixtureDirectory.appendingPathComponent("external.srt")
        let mediaInfo = try FFmpegDemuxer(url: mediaURL).mediaInfo
        let secondAudio = try #require(mediaInfo.audioStreams.last)
        let presentation = try NativePresentationCoordinator()
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView())
        pipeline.setPresentationAuthorityEnabled(false)
        let source = NativeSubtitleSource.external(url: externalURL)
        let candidate = try MediaSession(
            url: embeddedURL,
            presentation: presentation,
            subtitles: pipeline,
            subtitleSource: source
        )
        try pipeline.installExternal(
            data: SubtitlePipeline.prepareExternalData(url: externalURL)
        )

        #expect(candidate.activeSubtitleSource == source)
        #expect(candidate.activeSubtitleStream == nil)
        #expect(candidate.prepareForCommit())
        #expect(await waitUntil {
            candidate.isPreparedForCommit
        })
        try await Task.sleep(for: .milliseconds(100))
        #expect(
            pipeline.eventCount == 0,
            "External authority must prevent embedded packets entering its libass context."
        )
        candidate.stop(releasesPresentation: false)
        #expect(candidate.waitForShutdown(timeout: .now() + 3))

        let audioCandidatePipeline = try SubtitlePipeline(
            overlay: SubtitleOverlayView()
        )
        audioCandidatePipeline.setPresentationAuthorityEnabled(false)
        let audioCandidate = try MediaSession(
            url: mediaURL,
            presentation: presentation,
            subtitles: audioCandidatePipeline,
            selectedAudioIndex: secondAudio.index,
            subtitleSource: source
        )
        #expect(audioCandidate.activeAudioStream?.index == secondAudio.index)
        #expect(audioCandidate.activeSubtitleSource == source)
        #expect(audioCandidate.activeSubtitleStream == nil)
        #expect(audioCandidate.waitForShutdown(timeout: .now() + 3))
    }

    @Test @MainActor
    func stopDuringInFlightAudioTrackCandidateCannotResurrectSession() async throws {
        guard let fixtureDirectory else { return }
        let mediaURL = fixtureDirectory.appendingPathComponent(
            "multiple-audio-flags.mkv"
        )
        let mediaInfo = try FFmpegDemuxer(url: mediaURL).mediaInfo
        let replacementTrack = try #require(mediaInfo.audioStreams.last)
        let backend = try NativePlaybackRuntime()
        let recorder = NativeBackendEventRecorder()
        backend.eventHandler = { [weak recorder] event in
            recorder?.events.append(event)
        }
        _ = try backend.makeSurfaceHost()
        let source = MediaSource.localFile(mediaURL)
        let request = try #require(MediaLoadRequest(
            source: source,
            origin: .userSelected
        ))
        try backend.load(PlaybackRuntimeLoadRequest(
            media: request,
            identity: PlayerSessionIdentity(source: source, generation: 1)
        ))
        #expect(await waitUntil(timeout: .seconds(8)) {
            backend.sessionSnapshotForDiagnostics?.isPrerolled == true
        })

        backend.selectAudioTrack(
            NativeTrackIDMapping.trackID(for: replacementTrack.index)
        )
        #expect(
            backend.runtimeLeaseSnapshotsForTesting.filter {
                $0.provenance.kind == .playbackSessionWorkers
            }.count >= 2,
            "Track selection must have admitted a replacement candidate before stop."
        )
        let eventCountBeforeStop = recorder.events.count
        backend.stop()

        try await Task.sleep(for: .milliseconds(1_200))
        #expect(backend.sessionSnapshotForDiagnostics == nil)
        #expect(backend.diagnosticSnapshot?.hasInstalledMediaSession == false)
        #expect(recorder.events.dropFirst(eventCountBeforeStop).contains {
            $0.payload == .stopped
        })
        #expect(!recorder.events.dropFirst(eventCountBeforeStop).contains { event in
            switch event.payload {
            case .loaded, .prerollReady, .tracksChanged:
                true
            default:
                false
            }
        })

        await backend.shutdown()
        #expect(allRuntimeLeasesArePhysicallyReleased(backend))
    }

    @Test @MainActor
    func shutdownDuringAudioTrackCandidatePreparationReleasesEveryRuntimeLease() async throws {
        guard let fixtureDirectory else { return }
        let mediaURL = fixtureDirectory.appendingPathComponent(
            "multiple-audio-flags.mkv"
        )
        let mediaInfo = try FFmpegDemuxer(url: mediaURL).mediaInfo
        let replacementTrack = try #require(mediaInfo.audioStreams.last)
        let backend = try NativePlaybackRuntime()
        let recorder = NativeBackendEventRecorder()
        backend.eventHandler = { [weak recorder] event in
            recorder?.events.append(event)
        }
        _ = try backend.makeSurfaceHost()
        let source = MediaSource.localFile(mediaURL)
        let request = try #require(MediaLoadRequest(
            source: source,
            origin: .userSelected
        ))
        try backend.load(PlaybackRuntimeLoadRequest(
            media: request,
            identity: PlayerSessionIdentity(source: source, generation: 1)
        ))
        #expect(await waitUntil(timeout: .seconds(8)) {
            backend.sessionSnapshotForDiagnostics?.isPrerolled == true
        })

        backend.selectAudioTrack(
            NativeTrackIDMapping.trackID(for: replacementTrack.index)
        )
        let workerLeasesBeforeShutdown =
            backend.runtimeLeaseSnapshotsForTesting.filter {
                $0.provenance.kind == .playbackSessionWorkers
            }
        #expect(
            workerLeasesBeforeShutdown.count >= 2,
            "Shutdown must overlap an admitted candidate, not a rejected selection."
        )

        await backend.shutdown()

        #expect(backend.sessionSnapshotForDiagnostics == nil)
        #expect(recorder.events.contains { $0.payload == .shutdownCompleted })
        #expect(allRuntimeLeasesArePhysicallyReleased(backend))
    }

    @Test @MainActor
    func rapidRepeatedAudioTrackReplacementsConvergeToLatestSelectionAndReleaseLeases()
        async throws
    {
        guard let fixtureDirectory else { return }
        let mediaURL = fixtureDirectory.appendingPathComponent(
            "multiple-audio-flags.mkv"
        )
        let mediaInfo = try FFmpegDemuxer(url: mediaURL).mediaInfo
        let audioTrackIDs = mediaInfo.audioStreams.map {
            NativeTrackIDMapping.trackID(for: $0.index)
        }
        #expect(audioTrackIDs.count >= 3)
        let selections = (0..<12).map {
            audioTrackIDs[($0 + 1) % audioTrackIDs.count]
        }
        let expectedTrackID = try #require(selections.last)
        let backend = try NativePlaybackRuntime()
        let recorder = NativeBackendEventRecorder()
        backend.eventHandler = { [weak recorder] event in
            recorder?.events.append(event)
        }
        _ = try backend.makeSurfaceHost()
        let source = MediaSource.localFile(mediaURL)
        let request = try #require(MediaLoadRequest(
            source: source,
            origin: .userSelected
        ))
        try backend.load(PlaybackRuntimeLoadRequest(
            media: request,
            identity: PlayerSessionIdentity(source: source, generation: 1)
        ))
        #expect(await waitUntil(timeout: .seconds(8)) {
            backend.sessionSnapshotForDiagnostics?.isPrerolled == true
        })

        for selection in selections {
            backend.selectAudioTrack(selection)
            try await Task.sleep(for: .milliseconds(2))
        }

        #expect(await waitUntil(timeout: .seconds(12)) {
            trackSnapshots(recordedBy: recorder).last?.selectedAudioID
                == expectedTrackID
                && backend.sessionSnapshotForDiagnostics?.isPrerolled == true
        })
        try await Task.sleep(for: .milliseconds(250))
        #expect(
            trackSnapshots(recordedBy: recorder).last?.selectedAudioID
                == expectedTrackID
        )
        #expect(backend.sessionSnapshotForDiagnostics?.rendererFailure == nil)
        #expect(!hasRuntimeFailure(recordedBy: recorder))
        #expect(
            backend.runtimeLeaseSnapshotsForTesting.filter {
                $0.provenance.kind == .playbackSessionWorkers
            }.count >= 2,
            "The initial session and a replacement candidate must be represented."
        )
        #expect(
            backend.deferredReplacementAdmissionCountForTesting > 0,
            "Rapid supersession must coalesce behind the bounded candidate slot."
        )
        #expect(
            backend.subtitleMemoryBudgetSnapshotForTesting.rejectedAcquisitions == 0,
            "Candidate admission must wait instead of exhausting the subtitle budget."
        )

        await backend.shutdown()
        #expect(allRuntimeLeasesArePhysicallyReleased(backend))
    }

    @Test @MainActor
    func nativeRuntimePreservesAuthoritativeSubtitleSourceAcrossEmbeddedExternalOffEmbeddedSwitches()
        async throws
    {
        guard let fixtureDirectory else { return }
        let mediaURL = fixtureDirectory.appendingPathComponent("embedded-srt.mkv")
        let externalURL = fixtureDirectory.appendingPathComponent("external.srt")
        let mediaInfo = try FFmpegDemuxer(url: mediaURL).mediaInfo
        let embeddedStream = try #require(mediaInfo.subtitleStreams.first {
            $0.subtitleCapability?.isPlayable == true
        })
        let embeddedTrackID = NativeTrackIDMapping.trackID(
            for: embeddedStream.index
        )
        let backend = try NativePlaybackRuntime()
        let recorder = NativeBackendEventRecorder()
        backend.eventHandler = { [weak recorder] event in
            recorder?.events.append(event)
        }
        _ = try backend.makeSurfaceHost()
        let source = MediaSource.localFile(mediaURL)
        let request = try #require(MediaLoadRequest(
            source: source,
            origin: .userSelected
        ))
        try backend.load(PlaybackRuntimeLoadRequest(
            media: request,
            identity: PlayerSessionIdentity(source: source, generation: 1)
        ))
        #expect(await waitUntil(timeout: .seconds(8)) {
            trackSnapshots(recordedBy: recorder).last?.selectedSubtitleID
                == embeddedTrackID
                && backend.sessionSnapshotForDiagnostics?.isPrerolled == true
        })

        var priorTrackSnapshotCount = trackSnapshots(recordedBy: recorder).count
        backend.selectSubtitleTrack(embeddedTrackID)
        // Reselecting the active embedded track is synchronous and intentionally
        // does not rebuild the session or emit a replacement track snapshot.
        #expect(trackSnapshots(recordedBy: recorder).count == priorTrackSnapshotCount)
        #expect(backend.sessionSnapshotForDiagnostics?.isPrerolled == true)
        var authoritative = try #require(trackSnapshots(
            recordedBy: recorder
        ).last)
        #expect(authoritative.selectedSubtitleID == embeddedTrackID)
        #expect(authoritative.tracks.first {
            $0.id == authoritative.selectedSubtitleID
        }?.isExternal == false)

        priorTrackSnapshotCount = trackSnapshots(recordedBy: recorder).count
        backend.loadExternalSubtitle(externalURL, select: true)
        #expect(await waitUntil(timeout: .seconds(10)) {
            let snapshots = trackSnapshots(recordedBy: recorder)
            guard snapshots.count > priorTrackSnapshotCount,
                  let latest = snapshots.last,
                  let selectedID = latest.selectedSubtitleID,
                  let selected = latest.tracks.first(where: {
                      $0.id == selectedID
                  })
            else { return false }
            return selected.isExternal
                && selected.externalFilename == externalURL.lastPathComponent
                && backend.sessionSnapshotForDiagnostics?.isPrerolled == true
        })
        authoritative = try #require(trackSnapshots(recordedBy: recorder).last)
        let externalTrack = try #require(authoritative.tracks.first {
            $0.id == authoritative.selectedSubtitleID
        })
        #expect(externalTrack.isExternal)
        #expect(externalTrack.externalFilename == externalURL.lastPathComponent)

        priorTrackSnapshotCount = trackSnapshots(recordedBy: recorder).count
        backend.selectSubtitleTrack(nil)
        #expect(await waitUntil(timeout: .seconds(10)) {
            let snapshots = trackSnapshots(recordedBy: recorder)
            return snapshots.count > priorTrackSnapshotCount
                && snapshots.last?.selectedSubtitleID == nil
                && backend.sessionSnapshotForDiagnostics?.isPrerolled == true
        })
        authoritative = try #require(trackSnapshots(recordedBy: recorder).last)
        #expect(authoritative.selectedSubtitleID == nil)

        priorTrackSnapshotCount = trackSnapshots(recordedBy: recorder).count
        backend.selectSubtitleTrack(embeddedTrackID)
        #expect(await waitUntil(timeout: .seconds(10)) {
            let snapshots = trackSnapshots(recordedBy: recorder)
            return snapshots.count > priorTrackSnapshotCount
                && snapshots.last?.selectedSubtitleID == embeddedTrackID
                && backend.sessionSnapshotForDiagnostics?.isPrerolled == true
        })
        authoritative = try #require(trackSnapshots(recordedBy: recorder).last)
        let finalTrack = try #require(authoritative.tracks.first {
            $0.id == authoritative.selectedSubtitleID
        })
        #expect(authoritative.selectedSubtitleID == embeddedTrackID)
        #expect(!finalTrack.isExternal)
        #expect(backend.sessionSnapshotForDiagnostics?.rendererFailure == nil)
        #expect(!hasRuntimeFailure(recordedBy: recorder))

        await backend.shutdown()
        #expect(allRuntimeLeasesArePhysicallyReleased(backend))
    }

    @Test(arguments: [
        "h264-aac.mkv",
        "hevc-flac.mkv",
        "hevc-10bit-aac.mkv",
        "vp9-opus.mkv",
        "av1-video-only.mkv",
        "variable-frame-rate.mkv",
        "nonzero-start.mkv",
    ])
    func decodesVideoFixtureMatrix(filename: String) throws {
        guard let fixtureDirectory else { return }
        let url = fixtureDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let demuxer = try FFmpegDemuxer(url: url)
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(
            parameters: parameters,
            stream: stream,
            preferHardware: true
        )
        var decoded: NativeDecodedVideoFrame?
        for _ in 0..<300 where decoded == nil {
            guard let packet = try demuxer.readPacket(generation: 1) else { break }
            guard packet.streamIndex == stream.index else { continue }
            decoded = try decoder.decode(packet).first
        }
        let frame = try #require(decoded, "No frame decoded from \(filename)")
        #expect(CVPixelBufferGetWidth(frame.pixelBuffer) > 0)
        #expect(CVPixelBufferGetHeight(frame.pixelBuffer) > 0)
        print(
            "native fixture \(filename): ffmpeg=\(frame.ffmpegPixelFormat) "
                + "hardware=\(frame.isHardwareDecoded) nearZeroCopy=\(frame.isNearZeroCopy)"
        )
    }

}

@MainActor
private final class NativeBackendEventRecorder {
    var events: [PlaybackRuntimeEvent] = []
}
