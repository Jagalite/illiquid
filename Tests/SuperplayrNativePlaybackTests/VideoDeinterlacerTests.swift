import CFFmpeg
import Foundation
import CoreMedia
import Testing
@testable import SuperplayrNativePlayback

@Suite("Decoder-owned BWDIF deinterlacing")
struct VideoDeinterlacerTests {
    private var fixtures: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUPERPLAYR_NATIVE_FIXTURE_DIR"]
            ?? FileManager.default.currentDirectoryPath + "/TestFixtures/Generated", isDirectory: true)
    }
    private struct Output {
        let seconds: Double
        let duration: Double
        let interlaced: Bool
        let filtered: Bool
        let rows: [UInt8]
    }

    @Test(arguments: ["interlaced-tff.mpg", "interlaced-bff.mpg"])
    func generatedContainerDoublesCadenceWithoutChangingDuration(name: String) throws {
        let url = fixtures.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        func decode(enabled: Bool) throws -> [(Double, Double)] {
            let input = try FFmpegDemuxer(url: url)
            let stream = try #require(input.mediaInfo.videoStreams.first)
            let parameters = try #require(input.codecParameters(streamIndex: stream.index))
            let decoder = try VideoDecoder(parameters: parameters, stream: stream, preferHardware: false,
                timelineOriginSeconds: input.mediaInfo.startTime, deinterlacingEnabled: enabled)
            var times: [(Double, Double)] = []
            func accept(_ frame: NativeDecodedVideoFrame) {
                #expect(frame.usesDeinterlacingFilter == enabled)
                #expect(frame.deinterlacingFailure == nil)
                times.append((frame.presentationTime.seconds, frame.duration.seconds))
            }
            while let packet = try input.readPacket(generation: 0) {
                if packet.streamIndex == stream.index { try decoder.decode(packet, while: { true }, emit: accept) }
            }
            try decoder.drain(generation: 0, while: { true }, emit: accept)
            return times
        }
        let source = try decode(enabled: false), fields = try decode(enabled: true)
        #expect(!source.isEmpty)
        #expect(fields.count == source.count * 2)
        #expect(abs(source.reduce(0) { $0 + $1.1 } - fields.reduce(0) { $0 + $1.1 }) < 0.000_001)
        for index in fields.indices {
            #expect(abs(fields[index].1 - 0.02) < 0.000_001)
            #expect(abs(fields[index].0 - source[0].0 - Double(index) * 0.02) < 0.000_001)
        }
    }

    @Test @MainActor func pausedNativeSeeksDiscardOldFieldsAndRespectExactVideoFloor() async throws {
        let url = fixtures.appendingPathComponent("interlaced-tff.mpg")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let presentation = try NativePresentationCoordinator()
        defer { presentation.terminate() }
        let subtitles = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        let session = try MediaSession(url: url, presentation: presentation, subtitles: subtitles, preferHardware: false)
        defer { session.stop() }
        session.start(rate: 0)
        for (index, target) in [0.74, 0.2, 1.2].enumerated() {
            _ = session.seek(to: target, exact: true, resumeRate: 0)
            for _ in 0..<300 where session.snapshot().firstEnqueuedVideoPTS == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            let snapshot = session.snapshot()
            #expect(snapshot.generation == index + 1)
            #expect(try #require(snapshot.firstEnqueuedVideoPTS) + 0.001 >= target)
            #expect(snapshot.usesDeinterlacingFilter)
            #expect(snapshot.deinterlacingFailure == nil)
            #expect(snapshot.peakTemporaryDecodedVideoFrames <= 1)
            #expect(snapshot.peakVideoPipelineCapacityInUse <= snapshot.videoPipelineCapacity)
        }
        session.stop()
        #expect(await Task.detached { session.waitForShutdown() }.value)
    }

    @Test func rejectsOversizedTemporalInputBeforeAllocatingItsPixelStorage() throws {
        var allocated = av_frame_alloc()
        let frame = try #require(allocated)
        defer { av_frame_free(&allocated) }
        frame.pointee.width = 8_192
        frame.pointee.height = 8_192
        frame.pointee.format = Int32(AV_PIX_FMT_YUV420P10LE.rawValue)
        frame.pointee.flags = AV_FRAME_FLAG_INTERLACED
        let filter = try VideoDeinterlacer(timeBase: .init(numerator: 1, denominator: 25))
        #expect(throws: PresentationError.self) {
            try filter.process(frame, while: { true }) { _ in Issue.record("Oversized input produced output") }
        }
    }

    @Test(arguments: [true, false])
    func reconstructsFieldOrderAndDrainsEveryHalfFrame(topFirst: Bool) throws {
        let filter = try VideoDeinterlacer(timeBase: .init(numerator: 1, denominator: 25))
        var output: [Output] = []
        for index in 0..<3 {
            try withFrame(index: index, interlaced: true, topFirst: topFirst) { frame in
                try filter.process(frame, while: { true }) { output.append(snapshot($0)) }
            }
        }
        try filter.drain(while: { true }) { output.append(snapshot($0)) }
        #expect(output.count == 6)
        for (index, frame) in output.enumerated() {
            #expect(abs(frame.seconds - Double(index) / 50) < 0.000_001)
            #expect(abs(frame.duration - 1.0 / 50) < 0.000_001)
            #expect(!frame.interlaced)
            #expect(frame.filtered)
            let parity = (index % 2) ^ (topFirst ? 0 : 1)
            let expected = UInt8(32 + (index / 2) * 20 + parity * 60)
            for row in stride(from: parity, to: 16, by: 2) { #expect(frame.rows[row] == expected) }
        }
    }

    @Test func progressiveFramesKeepTheirFullDurationAcrossAnInterlacedTransition() throws {
        let filter = try VideoDeinterlacer(timeBase: .init(numerator: 1, denominator: 25))
        var output: [Output] = []
        for index in 0..<4 {
            try withFrame(index: index, interlaced: index < 3, topFirst: true) { frame in
                try filter.process(frame, while: { true }) { output.append(snapshot($0)) }
            }
        }
        try filter.drain(while: { true }) { output.append(snapshot($0)) }
        #expect(output.count == 7)
        let last = try #require(output.last)
        #expect(last.seconds == 3.0 / 25)
        #expect(last.duration == 1.0 / 25)
        let expectedRows: [UInt8] = (0..<16).map { UInt8(92 + ($0 % 2) * 60) }
        #expect(last.rows == expectedRows)
    }

    @Test func resetDropsBufferedOldFieldsAndCancellationPropagates() throws {
        let filter = try VideoDeinterlacer(timeBase: .init(numerator: 1, denominator: 25))
        var output: [Output] = []
        try withFrame(index: 0, interlaced: true, topFirst: true) { frame in
            try filter.process(frame, while: { true }) { output.append(snapshot($0)) }
        }
        #expect(output.isEmpty)
        filter.reset()
        for index in 3..<6 {
            try withFrame(index: index, interlaced: true, topFirst: false) { frame in
                try filter.process(frame, while: { true }) { output.append(snapshot($0)) }
            }
        }
        try filter.drain(while: { true }) { output.append(snapshot($0)) }
        #expect(output.count == 6)
        #expect(output.allSatisfy { $0.seconds >= 3.0 / 25 })
        filter.reset()
        try withFrame(index: 0, interlaced: false, topFirst: false) { frame in
            #expect(throws: SoftwarePixelBufferPoolError.cancelled) {
                try filter.process(frame, while: { false }) { _ in Issue.record("Cancelled filter delivered a frame") }
            }
        }
    }

    @Test func formatChangesDrainOldFieldsAndPreserveColorMetadata() throws {
        let filter = try VideoDeinterlacer(timeBase: .init(numerator: 1, denominator: 25), nominalFrameRate: 25)
        var records: [(Double, Int32, AVColorSpace, AVColorRange, AVColorPrimaries, AVColorTransferCharacteristic)] = []
        func accept(_ output: VideoDeinterlacer.Output) {
            let frame = output.frame.pointee
            records.append((Double(frame.pts) * Double(output.timeBase.numerator) / Double(output.timeBase.denominator),
                            frame.width, frame.colorspace, frame.color_range, frame.color_primaries, frame.color_trc))
        }
        for index in 0..<4 {
            try withFrame(index: index, interlaced: true, topFirst: true, width: index < 2 ? 16 : 32) { frame in
                frame.pointee.duration = 0 // Use the declared source cadence when the codec omits duration.
                frame.pointee.colorspace = index < 2 ? AVCOL_SPC_BT709 : AVCOL_SPC_BT2020_NCL
                frame.pointee.color_range = index < 2 ? AVCOL_RANGE_MPEG : AVCOL_RANGE_JPEG
                frame.pointee.color_primaries = index < 2 ? AVCOL_PRI_BT709 : AVCOL_PRI_BT2020
                frame.pointee.color_trc = index < 2 ? AVCOL_TRC_BT709 : AVCOL_TRC_SMPTE2084
                try filter.process(frame, while: { true }, emit: accept)
            }
        }
        try filter.drain(while: { true }, emit: accept)
        #expect(records.count == 8)
        for (index, record) in records.enumerated() {
            #expect(abs(record.0 - Double(index) / 50) < 0.000_001)
            #expect(record.1 == (index < 4 ? 16 : 32))
            #expect(record.2 == (index < 4 ? AVCOL_SPC_BT709 : AVCOL_SPC_BT2020_NCL))
            #expect(record.3 == (index < 4 ? AVCOL_RANGE_MPEG : AVCOL_RANGE_JPEG))
            #expect(record.4 == (index < 4 ? AVCOL_PRI_BT709 : AVCOL_PRI_BT2020))
            #expect(record.5 == (index < 4 ? AVCOL_TRC_BT709 : AVCOL_TRC_SMPTE2084))
        }
    }

    private func snapshot(_ output: VideoDeinterlacer.Output) -> Output {
        let frame = output.frame.pointee
        let timeBase = Double(output.timeBase.numerator) / Double(output.timeBase.denominator)
        return Output(seconds: Double(frame.pts) * timeBase, duration: Double(frame.duration) * timeBase,
            interlaced: frame.flags & AV_FRAME_FLAG_INTERLACED != 0, filtered: output.filtered,
            rows: (0..<Int(frame.height)).map { frame.data.0![Int(frame.linesize.0) * $0 + 8] })
    }

    private func withFrame(index: Int, interlaced: Bool, topFirst: Bool, width: Int32 = 16,
                           body: (UnsafeMutablePointer<AVFrame>) throws -> Void) throws {
        var allocated = av_frame_alloc()
        let frame = try #require(allocated)
        defer { av_frame_free(&allocated) }
        frame.pointee.width = width
        frame.pointee.height = 16
        frame.pointee.format = Int32(AV_PIX_FMT_YUV420P.rawValue)
        frame.pointee.pts = Int64(index)
        frame.pointee.duration = 1
        frame.pointee.flags = interlaced ? AV_FRAME_FLAG_INTERLACED | (topFirst ? AV_FRAME_FLAG_TOP_FIELD_FIRST : 0) : 0
        #expect(av_frame_get_buffer(frame, 32) >= 0)
        let luma = try #require(frame.pointee.data.0)
        let u = try #require(frame.pointee.data.1), v = try #require(frame.pointee.data.2)
        for row in 0..<16 { memset(luma.advanced(by: row * Int(frame.pointee.linesize.0)), Int32(32 + index * 20 + (row % 2) * 60), Int(width)) }
        for row in 0..<8 {
            memset(u.advanced(by: row * Int(frame.pointee.linesize.1)), 128, Int(width) / 2)
            memset(v.advanced(by: row * Int(frame.pointee.linesize.2)), 128, Int(width) / 2)
        }
        try body(frame)
    }
}
