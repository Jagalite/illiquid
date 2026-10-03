import AppKit
import CoreVideo
import Foundation
import SuperplayrCore
import SuperplayrPlayback
import Testing
@testable import SuperplayrNativePlayback

/// Opt-in measurements. Ordinary test runs do not generate performance media,
/// change cache policy, launch the application or require external storage.
@Suite("Seek performance qualification", .serialized)
struct SeekPerformanceQualificationTests {
    private var fixture: URL? {
        ProcessInfo.processInfo.environment["SUPERPLAYR_SEEK_PROFILE_FIXTURE"]
            .map { URL(fileURLWithPath: $0) }
    }
    private var targets: [Double] {
        ProcessInfo.processInfo.environment["SUPERPLAYR_SEEK_PROFILE_TARGETS"]?
            .split(separator: ",").compactMap { Double($0) }
            ?? [1.5, 8.5, 9.0, 9.5, 10.5, 18.5, 2.0, 2.5, 3.0]
    }
    private func save(_ value: Any, suffix: String) throws {
        guard let prefix = ProcessInfo.processInfo.environment["SUPERPLAYR_SEEK_PROFILE_RESULT"] else { return }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: prefix + suffix), options: .atomic)
    }

    private final class Observations: @unchecked Sendable {
        let lock = NSLock()
        private var values: [ThumbnailDecodeObservation] = []
        func append(_ value: ThumbnailDecodeObservation) { lock.withLock { values.append(value) } }
        func snapshot() -> [ThumbnailDecodeObservation] { lock.withLock { values } }
    }

    @Test func thumbnailContinuesFromPartialDecodeWithoutCachingAnEarlierFrame() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SUPERPLAYR_NATIVE_FIXTURE_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("h264-aac.mp4")
        let observations = Observations()
        let generator = NativeTimelineThumbnailGenerator(maximumPackets: 100) { observations.append($0) }
        let incomplete = await generator.thumbnail(for: url, at: 2.5,
            maximumPixelSize: CGSize(width: 160, height: 90))
        #expect(incomplete == nil)
        #expect(observations.snapshot().last?.failure == "decode-budget-exhausted")
        let continued = try #require(await generator.thumbnail(for: url, at: 1.5,
            maximumPixelSize: CGSize(width: 160, height: 90)))
        let fresh = try #require(await NativeTimelineThumbnailGenerator().thumbnail(for: url, at: 1.5,
            maximumPixelSize: CGSize(width: 160, height: 90)))
        #expect(continued.dataProvider?.data == fresh.dataProvider?.data)
        #expect(observations.snapshot().last?.continuedForward == true)
        #expect(observations.snapshot().last?.selectedFrameSeconds == 1.5)
    }

    @Test(arguments: ["h264-aac.mp4", "interlaced-tff.mpg", "nonzero-start.mkv"])
    func deferredThumbnailEOFFrameMatchesBaselineAndRetires(filename: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SUPERPLAYR_NATIVE_FIXTURE_DIR"] else { return }
        let demuxer = try FFmpegDemuxer(url: URL(fileURLWithPath: directory).appendingPathComponent(filename))
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let baseline = try VideoDecoder(parameters: parameters, stream: stream, preferHardware: false,
            timelineOriginSeconds: demuxer.mediaInfo.startTime, softwareOutputMode: .planarPreferred(rendererAttributes: [:]))
        let deferred = try VideoDecoder(parameters: parameters, stream: stream, preferHardware: false,
            timelineOriginSeconds: demuxer.mediaInfo.startTime, softwareOutputMode: .planarPreferred(rendererAttributes: [:]))
        deferred.retainsSeekPrerollFallback = true
        deferred.seekOutputFloor = (1, 100)
        var last: NativeDecodedVideoFrame?
        var unexpectedOutputs = 0
        while let packet = try demuxer.readPacket(generation: 1) {
            guard packet.streamIndex == stream.index else { continue }
            try baseline.decode(packet, while: { true }) { last = $0 }
            try deferred.decode(packet, while: { true }) { _ in unexpectedOutputs += 1 }
        }
        try baseline.drain(generation: 1, while: { true }) { last = $0 }
        try deferred.drain(generation: 1, while: { true }) { _ in unexpectedOutputs += 1 }
        #expect(unexpectedOutputs == 0)
        #expect(deferred.planarOutputDiagnostics?.checkouts ?? 0 == 0)
        #expect(try deferred.takeSeekPrerollFallback(generation: 0, while: { true }) == nil)
        let restored = try #require(try deferred.takeSeekPrerollFallback(generation: 1, while: { true }))
        let reference = try #require(last)
        #expect(restored.presentationTime == reference.presentationTime)
        #expect(restored.usesDeinterlacingFilter == reference.usesDeinterlacingFilter)
        #expect(lumaBytes(restored.pixelBuffer) == lumaBytes(reference.pixelBuffer))
        #expect(deferred.planarOutputDiagnostics?.checkouts == 1)
        #expect(try deferred.takeSeekPrerollFallback(generation: 1, while: { true }) == nil)
        deferred.flush()
        #expect(try deferred.takeSeekPrerollFallback(generation: 1, while: { true }) == nil)
    }

    private func lumaBytes(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return Data() }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var bytes = Data()
        for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 0) {
            bytes.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: width)
        }
        return bytes
    }

    @Test func profileThumbnailStages() async throws {
        guard let fixture else { return }
        let observations = Observations()
        let optimized = ProcessInfo.processInfo.environment["SUPERPLAYR_SEEK_PROFILE_BASELINE"] != "1"
        let generator = NativeTimelineThumbnailGenerator(optimized: optimized) { observations.append($0) }
        var callers: [[String: Any]] = []
        for target in targets {
            let start = ProcessInfo.processInfo.systemUptime
            let image = await generator.thumbnail(for: fixture, at: target,
                maximumPixelSize: CGSize(width: 320, height: 180))
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            callers.append(["target": target, "caller_ms": elapsed, "available": image != nil])
            print("thumbnail-profile target=\(target) caller-ms=\(elapsed) available=\(image != nil)")
        }
        // An expired caller can precede native completion. Bound observation
        // collection too, and preserve any missing records in the artifact.
        let deadline = ContinuousClock.now + .seconds(2)
        while observations.snapshot().count < targets.count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let records = observations.snapshot()
        for record in records { print("thumbnail-stage \(record.summary)") }
        let stages = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records))
        try save(["fixture": fixture.lastPathComponent, "callers": callers, "stages": stages], suffix: "-thumbnail.json")
    }

    @Test(arguments: ["h264-aac.mp4", "hevc-10bit-aac.mkv", "vp9-opus.mkv", "interlaced-tff.mpg", "nonzero-start.mkv"])
    func thumbnailForwardContinuationMatchesFreshSeek(filename: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["SUPERPLAYR_NATIVE_FIXTURE_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(filename)
        let observations = Observations()
        let generator = NativeTimelineThumbnailGenerator { observations.append($0) }
        let isInterlaced = filename == "interlaced-tff.mpg"
        let positions = isInterlaced ? [0.0, 0.5, 1.0, 1.5, 0.5] : [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 0.5]
        for target in positions {
            let sequential = try #require(await generator.thumbnail(for: url, at: target,
                maximumPixelSize: CGSize(width: 160, height: 90)))
            let reference = try #require(await NativeTimelineThumbnailGenerator().thumbnail(for: url, at: target,
                maximumPixelSize: CGSize(width: 160, height: 90)))
            #expect(sequential.width == reference.width)
            #expect(sequential.height == reference.height)
            #expect(sequential.dataProvider?.data == reference.dataProvider?.data)
        }
        #expect(observations.snapshot().contains { $0.continuedForward } == !isInterlaced)
        await generator.removeAllCachedThumbnails()
        _ = await generator.thumbnail(for: url, at: 1, maximumPixelSize: CGSize(width: 160, height: 90))
        #expect(observations.snapshot().last?.continuedForward == false)
        #expect(observations.snapshot().last?.reusedContext == false)
    }

    @Test @MainActor func profileNativeSeekStages() async throws {
        guard let fixture else { return }
        let backend = try NativePlaybackRuntime(softwareVideoOutputPolicy: .planarPreferred,
            seekPrerollFrameSkippingEnabled: ProcessInfo.processInfo.environment["SUPERPLAYR_SEEK_PROFILE_DISABLE_NONREF"] != "1",
            softwareSeekAccelerationEnabled: ProcessInfo.processInfo.environment["SUPERPLAYR_SEEK_PROFILE_DISABLE_SOFTWARE_BURST"] != "1")
        let host = try backend.makeSurfaceHost()
        host.view.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        host.view.layoutSubtreeIfNeeded()
        let observeRenderer = ProcessInfo.processInfo.environment["SUPERPLAYR_SEEK_PROFILE_OBSERVE_RENDERER"] == "1"
        var window: NSWindow?
        if ProcessInfo.processInfo.environment["SUPERPLAYR_SEEK_PROFILE_SHOW_WINDOW"] == "1" {
            let owned = NSWindow(contentRect: host.view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
            owned.isReleasedWhenClosed = false
            owned.title = "Platinum seek qualification"
            // Explicit visible-output qualification must remain visible while
            // other applications are active. Only this owned test window floats.
            owned.level = .floating
            owned.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            owned.contentView = host.view
            owned.orderFrontRegardless()
            window = owned
        }
        defer {
            window?.orderOut(nil)
            window?.contentView = nil
            window?.close()
        }
        backend.setMuted(true)
        var records: [[String: Any]] = []
        do {
            let source = MediaSource.localFile(fixture)
            let request = try #require(MediaLoadRequest(source: source, origin: .userSelected))
            try backend.load(.init(media: request, identity: PlayerSessionIdentity(source: source, generation: 1)))
            let loaded = await waitUntil(seconds: 12) { backend.sessionSnapshotForDiagnostics?.isPrerolled == true }
            try #require(loaded)
            backend.pause()
            for target in targets {
                // Reference decoding is outside the timed interval and warms
                // filesystem pages. This is expressly not a cold-disk trial.
                let expected = observeRenderer ? try referenceSignature(fixture, target: target) : nil
                let before = try #require(backend.sessionSnapshotForDiagnostics)
                let start = ProcessInfo.processInfo.systemUptime
                backend.seek(to: target, mode: .absoluteExact)
                let generation = try #require(backend.sessionSnapshotForDiagnostics?.generation)
                let completed = await waitUntil(seconds: 12) {
                    guard let snapshot = backend.sessionSnapshotForDiagnostics else { return false }
                    return snapshot.generation == generation && snapshot.seekTimings?.milliseconds[.prerollCompleted] != nil
                }
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                let snapshot = try #require(backend.sessionSnapshotForDiagnostics)
                var record: [String: Any] = ["target": target, "completed": completed,
                    "command_to_observed_preroll_ms": elapsed, "hardware": snapshot.isHardwareDecoded,
                    "previous_video_horizon": before.videoPTS, "previous_audio_horizon": before.audioPTS,
                    "previous_video_frame_depth": before.videoFrameDepth,
                    "previous_audio_frame_depth": before.audioFrameDepth]
                if let timings = snapshot.seekTimings {
                    for (stage, ms) in timings.milliseconds { record[stage.rawValue + "_ms"] = ms }
                    print("seek-profile target=\(target) command-ms=\(elapsed) \(timings.summary)")
                }
                record["first_video_pts"] = snapshot.firstEnqueuedVideoPTS
                record["discarded_preroll_frames"] = snapshot.discardedSeekPrerollFrames
                record["nonref_decode_packets"] = snapshot.seekPrerollNonReferencePackets
                record["software_seek_bursts"] = snapshot.softwareSeekAccelerationCount
                record["hardware_seek_restorations"] = snapshot.hardwareSeekRestorationCount
                if let expected {
                    record["renderer_readback"] = "unobserved"
                    // Static regions can match across different frames. Fence the
                    // actual displayed buffer by generation and presentation time
                    // before accepting the independent pixel reference.
                    let verified = await waitUntil(seconds: 3) {
                        let presenter = backend.presentation.video
                        record["window_visible"] = window?.isVisible ?? false
                        record["window_unoccluded"] = window?.occlusionState.contains(.visible) ?? false
                        record["renderer_status"] = presenter.renderer.status.rawValue
                        record["surface_bound_to_current_presenter"] =
                            (host.view as? NativePlayerNSView)?.videoLayer === presenter.displayLayer
                        let buffer = presenter.renderer.displayedPixelBuffer()
                        record["readback_pixel_buffer_available"] = buffer != nil
                        guard let buffer else { return false }
                        let identity = presenter.identity(for: buffer)
                        record["readback_generation"] = identity?.generation
                        record["readback_pts"] = identity?.time
                        guard let identity, let actual = Self.signature(buffer) else { return false }
                        let pixelsMatch = Self.matches(actual, expected)
                        record["readback_matches_reference"] = pixelsMatch
                        return identity.generation == generation
                            && snapshot.firstEnqueuedVideoPTS.map { abs(identity.time - $0) < 0.001 } == true
                            && pixelsMatch
                    }
                    if verified {
                        record["renderer_readback"] = "matched-current-generation-reference"
                        record["command_to_verified_readback_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                    }
                    #expect(verified, "The displayed frame must match the current seek generation and reference")
                }
                records.append(record)
                #expect(completed)
                #expect(snapshot.rendererFailure == nil)
                if completed {
                    let first = try #require(snapshot.firstEnqueuedVideoPTS)
                    #expect(first + 0.001 >= target)
                }
            }
            try save(["fixture": fixture.lastPathComponent, "samples": records,
                      "endpoint": "native command to observed preroll and optional reference-matched renderer readback; physical output unmeasured",
                      "reference_decode_warms_cache": observeRenderer], suffix: "-seek.json")
        } catch {
            await backend.shutdown()
            throw error
        }
        await backend.shutdown()
    }

    private func referenceSignature(_ url: URL, target: Double) throws -> [UInt16]? {
        let demuxer = try FFmpegDemuxer(url: url)
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(parameters: parameters, stream: stream, preferHardware: false,
            timelineOriginSeconds: demuxer.mediaInfo.startTime, softwareOutputMode: .planarPreferred(rendererAttributes: [:]))
        decoder.seekOutputFloor = (1, target)
        try demuxer.seek(to: target + demuxer.mediaInfo.startTime, exact: true)
        var result: [UInt16]?
        func receive(_ frame: NativeDecodedVideoFrame) {
            if result == nil { result = Self.signature(frame.pixelBuffer) }
        }
        while result == nil, let packet = try demuxer.readPacket(generation: 1) {
            if packet.streamIndex == stream.index { try decoder.decode(packet, while: { true }, emit: receive) }
        }
        if result == nil { try decoder.drain(generation: 1, while: { true }, emit: receive) }
        return result
    }

    // A sparse luma signature verifies changing generated-fixture content,
    // never a universal identity for arbitrary/static scenes or physical pixels.
    private static func signature(_ buffer: CVPixelBuffer) -> [UInt16]? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
            format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        guard tenBit || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width > 0, height > 0 else { return nil }
        var values: [UInt16] = []
        for y in 0..<16 {
            let row = base.advanced(by: ((2 * y + 1) * height / 32) * stride)
            for x in 0..<16 {
                let column = (2 * x + 1) * width / 32
                values.append(tenBit ? row.assumingMemoryBound(to: UInt16.self)[column] >> 6
                    : UInt16(row.assumingMemoryBound(to: UInt8.self)[column]) * 4)
            }
        }
        return values
    }

    private static func matches(_ lhs: [UInt16], _ rhs: [UInt16]) -> Bool {
        guard lhs.count == 256, rhs.count == lhs.count else { return false }
        return zip(lhs, rhs).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } <= lhs.count * 4
    }

    @MainActor private func waitUntil(seconds: Double, _ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return predicate()
    }
}
