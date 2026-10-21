import CoreMedia
import Foundation
import Testing
@testable import IlliquidNativePlayback

private enum TimestampFixtures {
    static let names = [
        "timestamp-cfr-bframes.mkv", "timestamp-vfr.mkv", "timestamp-nonzero.mkv",
        "timestamp-single.mp4", "timestamp-tff.mpg", "timestamp-bff.mpg",
    ]
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["ILLIQUID_FRAME_STEP_FIXTURE_DIR"] != nil
            || ProcessInfo.processInfo.environment["ILLIQUID_FRAME_STEP_REQUIRE_FIXTURES"] == "1"
    }
}

/// The dedicated macOS workflow generates and requires these tiny fixtures.
/// Ordinary test runs explicitly skip the suite when no fixture path is set.
@Suite("Timestamp discovery without presentation buffers", .serialized,
       .enabled(if: TimestampFixtures.enabled, "Generate Benchmarks/FrameStepTimestamps fixtures"))
struct VideoTimestampDiscoveryTests {
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let fixtures: [Fixture]
    }

    private struct Fixture: Decodable {
        let filename: String
        let sourceFrameCount: Int
        let fieldOrder: String?
        let streamStartSeconds: Double
        let sourceContainsBFrames: Bool
        let normalizedPTS: [Double]
        let sourceNormalizedPTS: [Double]
    }

    private enum OutputMode { case frames, timestamps }

    private struct Decoded {
        var times: [CMTime] = []
        var filteredFrames = 0
        var drainedFrames = 0
        var hasOutputPool = false
    }

    private enum DeliveryFailure: Error, Equatable { case requested }

    private var directory: URL {
        get throws {
            let path = try #require(
                ProcessInfo.processInfo.environment["ILLIQUID_FRAME_STEP_FIXTURE_DIR"],
                "The required timestamp fixtures must be generated before qualification"
            )
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    private func fixture(_ name: String) throws -> (URL, Fixture) {
        let directory = try directory
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("fixture-manifest.json"))
        )
        #expect(manifest.schemaVersion == 1)
        let record = try #require(manifest.fixtures.first { $0.filename == name })
        let url = directory.appendingPathComponent(name)
        #expect(FileManager.default.fileExists(atPath: url.path), "Missing generated fixture: \(name)")
        return (url, record)
    }

    private func open(
        _ url: URL,
        deinterlacing: Bool = true,
        outputMode: SoftwareVideoOutputMode = .bgra
    ) throws -> (FFmpegDemuxer, VideoDecoder, Int32) {
        let input = try FFmpegDemuxer(url: url)
        let stream = try #require(input.mediaInfo.videoStreams.first {
            $0.index == input.mediaInfo.selectedVideoIndex
        })
        let parameters = try #require(input.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(
            parameters: parameters, stream: stream, preferHardware: false,
            timelineOriginSeconds: input.mediaInfo.startTime,
            softwareOutputMode: outputMode, softwareDecoderThreadCount: 2,
            softwarePlanarOutputMaximumBufferCount: 2,
            deinterlacingEnabled: deinterlacing
        )
        #expect(!decoder.hasSoftwareOutputPoolForDiagnostics)
        return (input, decoder, stream.index)
    }

    private func consume(
        input: FFmpegDemuxer, decoder: VideoDecoder, streamIndex: Int32,
        mode: OutputMode, generation: Int = 1
    ) throws -> Decoded {
        var result = Decoded()
        func acceptFrame(_ frame: NativeDecodedVideoFrame) {
            #expect(frame.generation == generation)
            #expect(frame.deinterlacingFailure == nil)
            result.times.append(frame.presentationTime)
            if frame.usesDeinterlacingFilter { result.filteredFrames += 1 }
        }
        while let packet = try input.readPacket(generation: generation) {
            guard packet.streamIndex == streamIndex else { continue }
            switch mode {
            case .frames:
                try decoder.decode(packet, while: { true }, emit: acceptFrame)
            case .timestamps:
                try decoder.decodePresentationTimes(packet, while: { true }) { result.times.append($0) }
            }
        }
        let beforeDrain = result.times.count
        switch mode {
        case .frames:
            try decoder.drain(generation: generation, while: { true }, emit: acceptFrame)
            result.drainedFrames = result.times.count - beforeDrain
            try decoder.drain(generation: generation, while: { true }) { _ in
                Issue.record("A second EOF drain repeated a video frame")
            }
        case .timestamps:
            try decoder.drainPresentationTimes(generation: generation, while: { true }) {
                result.times.append($0)
            }
            result.drainedFrames = result.times.count - beforeDrain
            try decoder.drainPresentationTimes(generation: generation, while: { true }) { _ in
                Issue.record("A second EOF drain repeated a presentation time")
            }
        }
        #expect(decoder.droppedSoftwareDecodeErrors == 0)
        #expect(decoder.droppedCorruptSoftwareFrames == 0)
        result.hasOutputPool = decoder.hasSoftwareOutputPoolForDiagnostics
        return result
    }

    private func decode(
        _ url: URL, mode: OutputMode, deinterlacing: Bool = true,
        seek: Double? = nil, floor: (generation: Int, seconds: Double)? = nil
    ) throws -> Decoded {
        let (input, decoder, index) = try open(url, deinterlacing: deinterlacing)
        if let seek { try input.seek(to: seek + input.mediaInfo.startTime, exact: false) }
        decoder.seekOutputFloor = floor
        return try consume(input: input, decoder: decoder, streamIndex: index, mode: mode)
    }

    @Test(arguments: TimestampFixtures.names)
    func acceptedTimesMatchFullFramesAndIndependentFFmpeg(filename: String) throws {
        let (url, oracle) = try fixture(filename)
        let full = try decode(url, mode: .frames)
        let timestamps = try decode(url, mode: .timestamps)
        #expect(timestamps.times == full.times)
        #expect(timestamps.drainedFrames == full.drainedFrames)
        #expect(full.drainedFrames > 0, "Fixtures must exercise delayed decoder/filter output")
        #expect(full.hasOutputPool)
        #expect(!timestamps.hasOutputPool)
        #expect(full.times.count == oracle.normalizedPTS.count)
        for (actual, expected) in zip(timestamps.times, oracle.normalizedPTS) {
            #expect(actual.isNumeric)
            #expect(abs(actual.seconds - expected) < 0.000_001,
                    "\(filename): independent FFmpeg timing differs")
        }
        if oracle.fieldOrder != nil {
            #expect(full.filteredFrames == full.times.count)
            #expect(full.times.count == 2 * oracle.sourceFrameCount)
            let unfiltered = try decode(url, mode: .timestamps, deinterlacing: false)
            #expect(unfiltered.times.count == oracle.sourceFrameCount)
            for (actual, expected) in zip(unfiltered.times, oracle.sourceNormalizedPTS) {
                #expect(abs(actual.seconds - expected) < 0.000_001)
            }
        } else {
            #expect(full.filteredFrames == 0)
        }
        if filename.contains("nonzero") {
            #expect(oracle.streamStartSeconds >= 1.5)
            #expect(abs(try #require(timestamps.times.first).seconds) < 0.000_001)
        }
        if filename.contains("bframes") { #expect(oracle.sourceContainsBFrames) }
    }

    @Test(arguments: ["timestamp-cfr-bframes.mkv", "timestamp-vfr.mkv", "timestamp-tff.mpg"])
    func flushDropsOldDecoderAndFilterStateBeforeRepeatedSeeks(filename: String) throws {
        let (url, _) = try fixture(filename)
        let (input, decoder, index) = try open(url)
        var primed = 0
        while primed < 3, let packet = try input.readPacket(generation: 0) {
            if packet.streamIndex == index {
                try decoder.decodePresentationTimes(packet, while: { true }) { _ in primed += 1 }
            }
        }
        #expect(primed >= 3)
        for (offset, target) in [0.9, 0.0, 1.3].enumerated() {
            decoder.flush()
            try input.seek(to: target + input.mediaInfo.startTime, exact: false)
            let actual = try consume(input: input, decoder: decoder, streamIndex: index,
                                     mode: .timestamps, generation: offset + 2)
            let expected = try decode(url, mode: .frames, seek: target)
            #expect(actual.times == expected.times, "\(filename), seek \(target)")
            #expect(!actual.hasOutputPool)
        }
    }

    @Test(arguments: ["timestamp-cfr-bframes.mkv", "timestamp-vfr.mkv", "timestamp-bff.mpg"])
    func seekFloorPreservesFullDecoderAdmissionAndGenerationFence(filename: String) throws {
        let (url, _) = try fixture(filename)
        for generation in [1, 99] {
            let floor = (generation: generation, seconds: 0.65)
            let full = try decode(url, mode: .frames, floor: floor)
            let actual = try decode(url, mode: .timestamps, floor: floor)
            #expect(!actual.times.isEmpty)
            #expect(actual.times == full.times)
            #expect(!actual.hasOutputPool)
            if generation == 1 {
                #expect(actual.times.allSatisfy { $0.seconds + 0.001 >= floor.seconds })
            } else {
                #expect(try #require(actual.times.first).seconds < floor.seconds)
            }
        }
    }

    @Test(arguments: ["timestamp-cfr-bframes.mkv", "timestamp-tff.mpg"])
    func cancellationStopsBeforeAndDuringOutputAndFlushAllowsReuse(filename: String) throws {
        let (url, _) = try fixture(filename)
        let (input, decoder, index) = try open(url)
        var first: FFmpegPacket?
        while first == nil, let packet = try input.readPacket(generation: 1) {
            if packet.streamIndex == index { first = packet }
        }
        let packet = try #require(first)
        #expect(throws: SoftwarePixelBufferPoolError.cancelled) {
            try decoder.decodePresentationTimes(packet, while: { false }) { _ in
                Issue.record("Cancelled input emitted a timestamp")
            }
        }
        decoder.flush()
        try input.seek(to: input.mediaInfo.startTime, exact: false)
        var delivered = 0
        var cancelled = false
        do {
            while let next = try input.readPacket(generation: 2) {
                guard next.streamIndex == index else { continue }
                try decoder.decodePresentationTimes(next, while: { delivered == 0 }) { _ in
                    delivered += 1
                }
            }
            try decoder.drainPresentationTimes(generation: 2, while: { delivered == 0 }) { _ in
                delivered += 1
            }
        } catch SoftwarePixelBufferPoolError.cancelled {
            cancelled = true
        }
        #expect(cancelled)
        #expect(delivered == 1)
        #expect(!decoder.hasSoftwareOutputPoolForDiagnostics)
        decoder.flush()
        try input.seek(to: input.mediaInfo.startTime, exact: false)
        let replay = try consume(input: input, decoder: decoder, streamIndex: index,
                                 mode: .timestamps, generation: 3)
        #expect(replay.times == (try decode(url, mode: .frames)).times)
    }

    @Test(arguments: ["timestamp-cfr-bframes.mkv", "timestamp-bff.mpg"])
    func consumerErrorPropagatesWithoutBecomingDeinterlacingFallback(filename: String) throws {
        let (url, _) = try fixture(filename)
        let (input, decoder, index) = try open(url)
        var delivered = 0
        var caught = false
        do {
            while let packet = try input.readPacket(generation: 1) {
                guard packet.streamIndex == index else { continue }
                try decoder.decodePresentationTimes(packet, while: { true }) { _ in
                    delivered += 1
                    throw DeliveryFailure.requested
                }
            }
            try decoder.drainPresentationTimes(generation: 1, while: { true }) { _ in
                delivered += 1
                throw DeliveryFailure.requested
            }
        } catch DeliveryFailure.requested {
            caught = true
        }
        #expect(caught)
        #expect(delivered == 1)
        #expect(!decoder.hasSoftwareOutputPoolForDiagnostics)
        // Continue this exact decoder without flushing: a consumer failure
        // must not disable BWDIF or pin the source-frame fallback for later
        // output. Full-frame delivery exposes the filter/failure metadata.
        let remaining = try consume(input: input, decoder: decoder, streamIndex: index, mode: .frames)
        #expect(!remaining.times.isEmpty)
        #expect(remaining.hasOutputPool)
        if filename.hasSuffix(".mpg") {
            #expect(remaining.filteredFrames == remaining.times.count)
        }
    }

    @Test func timestampDiscoveryAlsoBypassesPlanarOutputStorage() throws {
        let (url, _) = try fixture("timestamp-cfr-bframes.mkv")
        let (input, decoder, index) = try open(url, outputMode: .planarExperiment(rendererAttributes: [:]))
        let result = try consume(input: input, decoder: decoder, streamIndex: index, mode: .timestamps)
        #expect(!result.times.isEmpty)
        #expect(!result.hasOutputPool)
        #expect(decoder.planarExperimentDiagnostics == nil)
    }

    @Test(arguments: TimestampFixtures.names)
    func frameStepReaderChoosesAdjacentDisplayedTimeAtBoundariesAndBetweenFrames(filename: String) async throws {
        let (url, _) = try fixture(filename)
        let times = try decode(url, mode: .frames).times.map(\.seconds)
        let first = try #require(times.first)
        let last = try #require(times.last)
        let middle = times[times.count / 2]
        let between = times.count > 1 ? (times[0] + times[1]) / 2 : first + 0.01
        let positions = Set([0, first, middle, between, last, last + 0.125]).sorted()
        let reader = NativeFrameStepReader()
        for position in positions {
            for direction in [-1, 1] {
                let expected = direction > 0
                    ? times.first { $0 > position + 0.000001 }
                    : times.last { $0 < position - 0.000001 }
                let actual = try await reader.target(url: url, position: position, direction: direction)
                if let expected {
                    #expect(abs(try #require(actual) - expected) < 0.000_001,
                            "\(filename), position \(position), direction \(direction)")
                } else {
                    #expect(actual == nil, "\(filename), position \(position), direction \(direction)")
                }
            }
        }
    }
}
