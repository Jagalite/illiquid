import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Recovery GOP lifetime at native session EOF", .serialized)
struct VideoRecoveryPacketSessionLifetimeTests {
    private struct PacketObservation {
        weak var packet: FFmpegPacket?
        let bytes: Int
        let keyframe: Bool
    }

    /// The injected reader demuxes the same fixture as the session. Its input
    /// is serialized separately from the weak-observation metadata, and it
    /// never retains a returned Swift packet owner for the test itself.
    private final class PacketProbe: @unchecked Sendable {
        private let input: FFmpegDemuxer
        private let videoIndex: Int32
        private let inputLock = NSLock()
        private let observationLock = NSLock()
        private var packets: [PacketObservation] = []
        private var reachedEOF = false
        private var failures: [String] = []

        struct Snapshot {
            let packetCount: Int
            let keyframes: Int
            let payloadBytes: Int
            let livePackets: Int
            let livePayloadBytes: Int
            let reachedEOF: Bool
            let failures: [String]
        }

        init(url: URL) throws {
            input = try FFmpegDemuxer(url: url, loadFontAttachments: false)
            videoIndex = try #require(input.mediaInfo.videoStreams.first).index
        }

        func read(generation: Int) throws -> FFmpegPacket? {
            let packet = try inputLock.withLock { try input.readPacket(generation: generation) }
            observationLock.withLock {
                if let packet, packet.streamIndex == videoIndex {
                    packets.append(PacketObservation(packet: packet, bytes: packet.byteCount,
                                                     keyframe: packet.isKeyframe))
                } else if packet == nil {
                    reachedEOF = true
                }
            }
            return packet
        }

        func recordFailure(_ code: String) {
            observationLock.withLock { failures.append(code) }
        }

        var snapshot: Snapshot {
            observationLock.withLock {
                var livePackets = 0
                var liveBytes = 0
                for observation in packets where observation.packet != nil {
                    livePackets += 1
                    liveBytes += observation.bytes
                }
                return Snapshot(
                    packetCount: packets.count,
                    keyframes: packets.filter(\.keyframe).count,
                    payloadBytes: packets.reduce(0) { $0 + $1.bytes },
                    livePackets: livePackets,
                    livePayloadBytes: liveBytes,
                    reachedEOF: reachedEOF,
                    failures: failures
                )
            }
        }
    }

    @Test @MainActor
    func completedSessionReleasesItsFinalGOPBeforeStop() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: environment["ILLIQUID_NATIVE_FIXTURE_DIR"]
            ?? FileManager.default.currentDirectoryPath + "/TestFixtures/Generated", isDirectory: true)
        let fixture = directory.appendingPathComponent("timestamp-cfr-bframes.mkv")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            if environment["ILLIQUID_RECOVERY_PACKET_REQUIRE_FIXTURE"] == "1" {
                Issue.record("Required recovery-GOP fixture is missing: \(fixture.path)")
            } else {
                print("NOT RUN: native recovery-GOP session test requires timestamp-cfr-bframes.mkv")
            }
            return
        }

        let probe = try PacketProbe(url: fixture)
        let presentation = try NativePresentationCoordinator()
        let subtitles = try SubtitlePipeline(
            overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        let session = try MediaSession(
            url: fixture,
            presentation: presentation,
            subtitles: subtitles,
            preferHardware: false,
            onFailureObserved: { probe.recordFailure($0.stableCode) },
            demuxPacketReader: { try probe.read(generation: $0) }
        )
        defer {
            session.stop()
            _ = session.waitForShutdown()
            subtitles.terminate()
            presentation.terminate()
        }

        session.start(rate: 1)
        #expect(session.requestTransport(playing: true))
        let deadline = ContinuousClock.now + .seconds(15)
        var state = session.snapshot()
        while !state.decoderDrainComplete, probe.snapshot.failures.isEmpty,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            state = session.snapshot()
        }
        try #require(state.decoderDrainComplete,
                     "The actual session did not consume its video EOS marker before the deadline")

        let ownership = probe.snapshot
        #expect(ownership.failures.isEmpty)
        #expect(ownership.reachedEOF)
        // The existing frame-step generator creates 48 video-only H.264
        // frames, including B-frames, in one bounded GOP. This makes retained
        // final-GOP ownership distinguishable from a trivially empty stream.
        #expect(ownership.packetCount == 48)
        #expect(ownership.keyframes == 1)
        #expect(ownership.payloadBytes > 0)
        #expect(ownership.payloadBytes < VideoRecoveryPacketBuffer.maximumByteCount)
        #expect(state.framesSubmitted == 48)
        #expect(state.videoPacketDepth == 0)
        #expect(state.videoFrameDepth == 0)
        #expect(state.rendererFailure == nil)
        #expect(!state.isHardwareDecoded)
        #expect(ownership.livePackets == 0)
        #expect(ownership.livePayloadBytes == 0)
        print("recovery-gop-session packets=\(ownership.packetCount) payload-bytes=\(ownership.payloadBytes) "
            + "live-packets-at-eos=\(ownership.livePackets) live-payload-bytes-at-eos=\(ownership.livePayloadBytes) "
            + "submitted-frames=\(state.framesSubmitted)")
        // Stop/destruction must not be what made the preceding ownership
        // assertions pass. The finished session remains alive at this point.
        #expect(session.snapshot().decoderDrainComplete)
        withExtendedLifetime(session) {}

        session.stop()
        #expect(await Task.detached { session.waitForShutdown() }.value)
    }
}
