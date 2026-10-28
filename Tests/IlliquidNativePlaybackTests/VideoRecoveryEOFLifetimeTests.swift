import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Video recovery EOF lifetime", .serialized, .enabled(
    if: ProcessInfo.processInfo.environment["ILLIQUID_RECOVERY_EOF_FIXTURE"] != nil,
    "Supply the dedicated single-frame H.264 fixture"
))
struct VideoRecoveryEOFLifetimeTests {
    @Test @MainActor
    func completedDrainReleasesPacketsWhileFramesRemainQueuedAcrossSeeks() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["ILLIQUID_RECOVERY_EOF_FIXTURE"])
        try #require(FileManager.default.fileExists(atPath: path))
        // The same observation test is staged into the baseline checkout by
        // the experiment runner. Ordinary candidate tests always expect zero.
        let expectedValue = environment["ILLIQUID_RECOVERY_EOF_EXPECT_RETAINED"] ?? "0"
        try #require(["0", "1"].contains(expectedValue))
        let expectedRetained = expectedValue == "1" ? 1 : 0
        let url = URL(fileURLWithPath: path)
        let probe = try RecoveryEOFPacketProbe(url: url)
        try #require(probe.videoStreamCount == 1)
        try #require(probe.audioStreamCount == 0)

        let presentation = try NativePresentationCoordinator()
        defer { presentation.terminate() }
        let subtitles = try SubtitlePipeline(
            overlay: SubtitleOverlayView(headless: true), presentsOverlay: false
        )
        defer { subtitles.terminate() }
        let session = try MediaSession(
            url: url, presentation: presentation, subtitles: subtitles,
            preferHardware: false,
            onFailureObserved: { _ in probe.recordFailure() },
            demuxPacketReader: { generation in try probe.read(generation: generation) }
        )
        defer {
            session.stop()
            _ = session.waitForShutdown(timeout: .now() + 3)
        }

        // Preparation runs the real demux/decode workers but no presentation
        // consumer. One decoded frame plus its EOF marker remain queued, so
        // packet lifetime is observed before session or output-frame teardown.
        try #require(session.prepareForCommit())
        var phases: [RecoveryEOFPhase] = []
        for iteration in 0..<3 {
            let generation = iteration == 0
                ? session.currentGeneration
                : session.seek(to: 0, exact: true, resumeRate: 0)
            try #require(generation == iteration)
            try #require(try await waitUntil {
                let state = session.snapshot()
                return state.generation == generation && state.videoFrameDepth == 2
                    && probe.snapshot(generation: generation).eofReads == 1
            }, "The one-frame stream must finish decoder drain and enqueue its EOF marker.")
            try #require(try await waitUntil {
                probe.snapshot(generation: generation).retainedPackets == expectedRetained
            }, "Compressed packet ownership must match the completed-drain policy.")

            let packets = probe.snapshot(generation: generation)
            let state = session.snapshot()
            #expect(packets.packetsRead == 1)
            #expect(packets.keyframesRead == 1)
            #expect(packets.payloadBytesRead > 0)
            #expect(packets.retainedPayloadBytes
                == (expectedRetained == 0 ? 0 : packets.payloadBytesRead))
            #expect(session.isPreparedForCommit)
            #expect(state.videoPacketDepth == 0)
            #expect(state.videoFrameDepth == 2)
            #expect(state.framesSubmitted == 0)
            #expect(state.rendererFailure == nil)
            #expect(probe.failureCount == 0)
            for previousGeneration in 0..<generation {
                #expect(probe.snapshot(generation: previousGeneration).retainedPackets == 0)
            }
            phases.append(RecoveryEOFPhase(
                phase: iteration == 0 ? "initial_eof" : "seek_\(iteration)_eof",
                packets: packets, queuedVideoItems: state.videoFrameDepth,
                prepared: session.isPreparedForCommit
            ))

            // Re-observe the same completed generation before the next seek.
            // The demux EOF wait must not manufacture another packet/EOF pair,
            // nor should release depend on a presentation worker consuming it.
            for _ in 0..<10 { await Task.yield() }
            #expect(probe.snapshot(generation: generation) == packets)
            #expect(session.snapshot().videoFrameDepth == 2)
        }

        session.stop()
        try #require(session.waitForShutdown(timeout: .now() + 3))
        try #require(try await waitUntil { probe.totalRetainedPackets == 0 })
        #expect(probe.failureCount == 0)
        if let receiptPath = environment["ILLIQUID_RECOVERY_EOF_RECEIPT"] {
            let receipt = RecoveryEOFReceipt(
                expectedRetainedPacketsAtEOF: expectedRetained,
                phases: phases, retainedPacketsAfterStop: probe.totalRetainedPackets,
                failureCount: probe.failureCount
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let outputURL = URL(fileURLWithPath: receiptPath)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try encoder.encode(receipt).write(to: outputURL, options: .atomic)
        }
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}

/// Observes the actual packet wrappers passed into MediaSession. Neither a
/// weak reference nor the recorded byte count keeps a packet/AVBuffer alive.
private final class RecoveryEOFPacketProbe: @unchecked Sendable {
    let videoStreamCount: Int
    let audioStreamCount: Int
    private let videoStreamIndex: Int32
    private let demuxer: FFmpegDemuxer
    private let lock = NSLock()
    private var readerGeneration: Int?
    private var packets: [WeakPacket] = []
    private var eofReads: [Int: Int] = [:]
    private var failures = 0

    init(url: URL) throws {
        let demuxer = try FFmpegDemuxer(url: url)
        self.demuxer = demuxer
        videoStreamCount = demuxer.mediaInfo.videoStreams.count
        audioStreamCount = demuxer.mediaInfo.audioStreams.count
        videoStreamIndex = try #require(demuxer.mediaInfo.selectedVideoIndex)
    }

    func read(generation: Int) throws -> FFmpegPacket? {
        try lock.withLock {
            if let readerGeneration, readerGeneration != generation {
                // MediaSession seeks its primary input. Keep the injected
                // observer's independent real demuxer at the same target.
                try demuxer.seek(to: 0, exact: true)
            }
            readerGeneration = generation
            guard let packet = try demuxer.readPacket(generation: generation) else {
                eofReads[generation, default: 0] += 1
                return nil
            }
            if packet.streamIndex == videoStreamIndex {
                packets.append(WeakPacket(packet))
            }
            return packet
        }
    }

    func snapshot(generation: Int) -> RecoveryEOFPacketSnapshot {
        lock.withLock {
            let current = packets.filter { $0.generation == generation }
            let retained = current.filter { $0.packet != nil }
            return RecoveryEOFPacketSnapshot(
                generation: generation, packetsRead: current.count,
                keyframesRead: current.filter(\.isKeyframe).count,
                payloadBytesRead: current.reduce(0) { $0 + $1.payloadBytes },
                eofReads: eofReads[generation, default: 0],
                retainedPackets: retained.count,
                retainedPayloadBytes: retained.reduce(0) { $0 + $1.payloadBytes }
            )
        }
    }

    var totalRetainedPackets: Int {
        lock.withLock { packets.filter { $0.packet != nil }.count }
    }

    var failureCount: Int { lock.withLock { failures } }

    func recordFailure() {
        lock.withLock { failures += 1 }
    }

    private final class WeakPacket {
        weak var packet: FFmpegPacket?
        let generation: Int
        let isKeyframe: Bool
        let payloadBytes: Int

        init(_ packet: FFmpegPacket) {
            self.packet = packet
            generation = packet.generation
            isKeyframe = packet.isKeyframe
            payloadBytes = packet.byteCount
        }
    }
}

private struct RecoveryEOFPacketSnapshot: Encodable, Equatable {
    let generation: Int
    let packetsRead: Int
    let keyframesRead: Int
    let payloadBytesRead: Int
    let eofReads: Int
    let retainedPackets: Int
    let retainedPayloadBytes: Int
}

private struct RecoveryEOFPhase: Encodable {
    let phase: String
    let packets: RecoveryEOFPacketSnapshot
    let queuedVideoItems: Int
    let prepared: Bool
}

private struct RecoveryEOFReceipt: Encodable {
    let schemaVersion = 1
    let measurement = "Live FFmpegPacket wrappers and their compressed payload sizes; not RSS or allocator footprint"
    let expectedRetainedPacketsAtEOF: Int
    let phases: [RecoveryEOFPhase]
    let retainedPacketsAfterStop: Int
    let failureCount: Int
}
