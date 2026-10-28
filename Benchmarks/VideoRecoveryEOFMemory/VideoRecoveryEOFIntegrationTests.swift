import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import IlliquidPlaybackCore
import Testing
@testable import IlliquidNativePlayback

/// Harness-only integration coverage. The benchmark runner copies this file
/// into an isolated test target and appends read-only recovery probes plus a
/// prepared-queue consumer to the staged production source files.
@Suite("Video recovery GOP EOF session lifetime", .serialized)
struct VideoRecoveryEOFIntegrationTests {
    private static let frameCount = 4
    private static let queuedItemCount = frameCount + 1

    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func record(_ value: String) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var snapshot: [String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private struct TimeReceipt: Codable, Equatable {
        let value: Int64
        let timescale: Int32
        let flags: UInt32
        let epoch: Int64
        let seconds: Double

        init(_ time: CMTime) {
            value = time.value
            timescale = time.timescale
            flags = time.flags.rawValue
            epoch = time.epoch
            seconds = time.seconds
        }
    }

    private struct FrameOutput: Codable, Equatable {
        let presentationTime: TimeReceipt
        let duration: TimeReceipt
        let width: Int
        let height: Int
        let pixelFormat: UInt32
        let activePixelBytes: Int
        let activePixelSHA256: String
        let ffmpegPixelFormat: String
        let colorPrimaries: Int32?
        let transferCharacteristic: Int32?
        let matrixCoefficients: Int32?
        let isFullRange: Bool
        let isHardwareDecoded: Bool
        let usesDeinterlacingFilter: Bool
    }

    private struct FrameReceipt: Codable {
        let generation: Int
        let output: FrameOutput
    }

    private struct RecoveryReceipt: Codable {
        let generation: Int?
        let packetCount: Int
        /// Sum of compressed payload sizes owned by the replay buffer. This is
        /// not final native deallocation, allocated capacity, or process RSS.
        let payloadBytes: Int
    }

    private struct PassReceipt: Codable {
        let generation: Int
        let queuedItemCount: Int
        let recoveryBeforeQueueConsumption: RecoveryReceipt
        let frames: [FrameReceipt]
        let endOfStreamGenerations: [Int]
    }

    private struct Receipt: Codable {
        let schemaVersion: Int
        let completed: Bool
        let expectedReleased: Bool
        let fixtureSHA256: String
        let expectedFrameCount: Int
        let first: PassReceipt
        let afterSeek: PassReceipt
        let heldFrameAfterSeek: FrameOutput
        let heldFrameAfterShutdown: FrameOutput
        let shutdownCompleted: Bool
        let qualification: String
    }

    private enum HarnessError: Error {
        case timedOutWaitingForPreparedEOF(generation: Int, lastDepth: Int)
        case unexpectedFlushMarker
    }

    @Test @MainActor
    func completedVideoDrainReleasesReplayAndSeekPreservesOutput() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixturePath = try #require(
            environment["ILLIQUID_RECOVERY_EOF_FIXTURE"],
            "This harness requires its generated four-frame H.264 fixture."
        )
        let expectation = try #require(
            environment["ILLIQUID_RECOVERY_EOF_EXPECT_RELEASED"],
            "Specify 0 for the baseline or 1 for the candidate."
        )
        let outputPath = try #require(
            environment["ILLIQUID_RECOVERY_EOF_OUTPUT"],
            "This harness requires an explicit JSON receipt path."
        )
        try #require(fixturePath.hasPrefix("/") && outputPath.hasPrefix("/"))
        try #require(expectation == "0" || expectation == "1")
        try #require(FileManager.default.fileExists(atPath: fixturePath))
        try #require(
            !FileManager.default.fileExists(atPath: outputPath),
            "Use a fresh receipt path for each test process."
        )
        let expectReleased = expectation == "1"
        let fixture = URL(fileURLWithPath: fixturePath)
        let fixtureSHA256 = hexadecimal(SHA256.hash(data: try Data(contentsOf: fixture)))
        let failures = Failures()
        let presentation = try NativePresentationCoordinator()
        let subtitles = try SubtitlePipeline(
            overlay: SubtitleOverlayView(headless: true),
            presentsOverlay: false
        )
        defer {
            subtitles.terminate()
            presentation.terminate()
        }
        let session = try MediaSession(
            url: fixture,
            presentation: presentation,
            subtitles: subtitles,
            preferHardware: false,
            onSeekFailed: { generation, failure in
                failures.record("seek \(generation): \(failure.stableCode)")
            },
            onFailureObserved: { failure in
                failures.record(failure.stableCode)
            }
        )
        var shutdownCompleted = false
        defer {
            if !shutdownCompleted {
                session.stop()
                #expect(session.waitForShutdown(timeout: .now() + 5))
            }
        }

        try #require(session.mediaInfo.videoStreams.count == 1)
        try #require(session.mediaInfo.audioStreams.isEmpty)
        try #require(session.mediaInfo.subtitleStreams.isEmpty)

        // Actual demux/decode workers run, but no renderer consumes the queue.
        // Four decoded frames and one EOF marker fit without backpressure.
        try #require(session.currentGeneration == 0)
        try #require(session.prepareForCommit())
        try await waitForPreparedEOF(session, generation: 0, failures: failures)
        let first = try consumePreparedPass(
            session,
            generation: 0,
            expectReleased: expectReleased,
            keepFirstFrame: true
        )
        let held = try #require(first.heldFrame)
        let originalHeldOutput = try #require(first.receipt.frames.first).output

        // The helper returns only one frame object, not the complete first
        // output array. Its one held permit plus four new frames fit the
        // normal seven-frame software pipeline capacity.
        let nextGeneration = session.seek(to: 0, exact: true, resumeRate: 0)
        try #require(nextGeneration > 0)
        try await waitForPreparedEOF(
            session,
            generation: nextGeneration,
            failures: failures
        )
        let second = try consumePreparedPass(
            session,
            generation: nextGeneration,
            expectReleased: expectReleased,
            keepFirstFrame: false
        )
        try #require(
            first.receipt.frames.map(\.output)
                == second.receipt.frames.map(\.output),
            "Seeking back from EOF changed decoded pixels or timestamps."
        )
        let heldAfterSeek = try frameOutput(held)
        try #require(heldAfterSeek == originalHeldOutput)
        try #require(held.generation == 0)
        try #require(failures.snapshot.isEmpty)

        session.stop()
        shutdownCompleted = session.waitForShutdown(timeout: .now() + 5)
        try #require(shutdownCompleted)
        let heldAfterShutdown = try frameOutput(held)
        try #require(heldAfterShutdown == originalHeldOutput)
        try #require(failures.snapshot.isEmpty)
        let afterStop = session.recoveryEOFResearchState()
        try #require(afterStop.packetCount == 0 && afterStop.payloadBytes == 0)

        let receipt = Receipt(
            schemaVersion: 1,
            completed: true,
            expectedReleased: expectReleased,
            fixtureSHA256: fixtureSHA256,
            expectedFrameCount: Self.frameCount,
            first: first.receipt,
            afterSeek: second.receipt,
            heldFrameAfterSeek: heldAfterSeek,
            heldFrameAfterShutdown: heldAfterShutdown,
            shutdownCompleted: shutdownCompleted,
            qualification: "Real native session demux/decode and EOF/seek; prepared output only, no renderer or live UI qualification."
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(receipt)
        data.append(0x0a)
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: output, options: .atomic)
        withExtendedLifetime((session, held)) {}
    }

    @MainActor
    private func waitForPreparedEOF(
        _ session: MediaSession,
        generation: Int,
        failures: Failures
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        var lastDepth = 0
        while ContinuousClock.now < deadline {
            let snapshot = session.snapshot()
            try #require(failures.snapshot.isEmpty)
            try #require(snapshot.rendererFailure == nil)
            try #require(snapshot.generation == generation)
            lastDepth = snapshot.videoFrameDepth
            try #require(lastDepth <= Self.queuedItemCount)
            if lastDepth == Self.queuedItemCount {
                try #require(snapshot.videoPacketDepth == 0)
                try #require(snapshot.framesSubmitted == 0)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw HarnessError.timedOutWaitingForPreparedEOF(
            generation: generation,
            lastDepth: lastDepth
        )
    }

    private func consumePreparedPass(
        _ session: MediaSession,
        generation: Int,
        expectReleased: Bool,
        keepFirstFrame: Bool
    ) throws -> (receipt: PassReceipt, heldFrame: NativeDecodedVideoFrame?) {
        let state = session.recoveryEOFResearchState()
        try #require(state.generation == generation)
        if expectReleased {
            try #require(state.packetCount == 0)
            try #require(state.payloadBytes == 0)
        } else {
            try #require(state.packetCount > 0 && state.packetCount <= Self.frameCount)
            try #require(state.payloadBytes > 0)
        }
        let recovery = RecoveryReceipt(
            generation: state.generation,
            packetCount: state.packetCount,
            payloadBytes: state.payloadBytes
        )
        let items = session.takePreparedVideoForRecoveryEOFResearch()
        try #require(items.count == Self.queuedItemCount)
        var frames: [FrameReceipt] = []
        var endOfStreamGenerations: [Int] = []
        var held: NativeDecodedVideoFrame?
        for item in items {
            switch item {
            case let .frame(frame):
                try #require(endOfStreamGenerations.isEmpty)
                try #require(frame.generation == generation)
                let output = try frameOutput(frame)
                try #require(!output.isHardwareDecoded)
                frames.append(FrameReceipt(generation: frame.generation, output: output))
                if keepFirstFrame, held == nil { held = frame }
            case let .endOfStream(candidate):
                try #require(candidate == generation)
                try #require(frames.count == Self.frameCount)
                endOfStreamGenerations.append(candidate)
            case .flush:
                throw HarnessError.unexpectedFlushMarker
            }
        }
        try #require(frames.count == Self.frameCount)
        try #require(endOfStreamGenerations == [generation])
        let times = frames.map { $0.output.presentationTime.seconds }
        try #require(zip(times, times.dropFirst()).allSatisfy { pair in
            pair.0 < pair.1
        })
        try #require(frames.allSatisfy { $0.output.duration.seconds > 0 })
        let receipt = PassReceipt(
            generation: generation,
            queuedItemCount: items.count,
            recoveryBeforeQueueConsumption: recovery,
            frames: frames,
            endOfStreamGenerations: endOfStreamGenerations
        )
        return (receipt: receipt, heldFrame: held)
    }

    private func frameOutput(_ frame: NativeDecodedVideoFrame) throws -> FrameOutput {
        try #require(frame.presentationTime.isNumeric)
        try #require(frame.duration.isNumeric)
        try #require(frame.presentationTime.seconds.isFinite)
        try #require(frame.duration.seconds.isFinite)
        let buffer = frame.pixelBuffer
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        try #require(pixelFormat == kCVPixelFormatType_32BGRA)
        try #require(!CVPixelBufferIsPlanar(buffer))
        try #require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = width * 4
        let rowStride = CVPixelBufferGetBytesPerRow(buffer)
        try #require(width > 0 && height > 0 && rowStride >= rowBytes)
        var activePixels = Data(capacity: rowBytes * height)
        for row in 0..<height {
            activePixels.append(
                base.advanced(by: row * rowStride).assumingMemoryBound(to: UInt8.self),
                count: rowBytes
            )
        }
        return FrameOutput(
            presentationTime: TimeReceipt(frame.presentationTime),
            duration: TimeReceipt(frame.duration),
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            activePixelBytes: activePixels.count,
            activePixelSHA256: hexadecimal(SHA256.hash(data: activePixels)),
            ffmpegPixelFormat: frame.ffmpegPixelFormat,
            colorPrimaries: frame.colorPrimaries,
            transferCharacteristic: frame.transferCharacteristic,
            matrixCoefficients: frame.matrixCoefficients,
            isFullRange: frame.isFullRange,
            isHardwareDecoded: frame.isHardwareDecoded,
            usesDeinterlacingFilter: frame.usesDeinterlacingFilter
        )
    }

    private func hexadecimal(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
