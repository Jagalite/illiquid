import CFFmpeg
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("BWDIF end-of-stream storage lifetime")
struct VideoDeinterlacerLifetimeTests {
    private enum ConsumerFailure: Error { case interrupted }

    /// Keeps one observer reference alive so native refcounts remain safe to
    /// inspect. A count of one means the filter no longer owns this allocation;
    /// it is not a measurement of process memory or physical deallocation.
    private final class BufferObserver {
        private var reference: UnsafeMutablePointer<AVBufferRef>?

        init(_ buffer: UnsafeMutablePointer<AVBufferRef>) throws {
            guard let observer = av_buffer_ref(buffer) else {
                throw PresentationError("Could not retain test input buffer")
            }
            reference = observer
        }

        deinit { av_buffer_unref(&reference) }

        var referenceCount: Int {
            reference.map { Int(av_buffer_get_ref_count($0)) } ?? 0
        }
    }

    private struct FrameSnapshot: Equatable {
        let pts: Int64
        let duration: Int64
        let width: Int32
        let height: Int32
        let flags: Int32
        let colorSpace: AVColorSpace
        let colorRange: AVColorRange
        let bytes: [UInt8]
    }

    @Test(arguments: [true, false])
    func completeDrainReleasesTemporalReferencesBeforeFilterDestruction(topFirst: Bool) throws {
        let filter = try makeFilter()
        var observers: [BufferObserver] = []
        var times: [Double] = []
        for index in 0..<3 {
            try withFrame(index: index, topFirst: topFirst, observers: &observers) { frame in
                try filter.process(frame, while: { true }) { times.append(seconds($0)) }
            }
        }
        #expect(observers.contains { $0.referenceCount > 1 })
        try filter.drain(while: { true }) { times.append(seconds($0)) }
        expectTimes(times, startingAt: 0, count: 6)
        #expect(observers.allSatisfy { $0.referenceCount == 1 })

        try filter.drain(while: { true }) { _ in Issue.record("Repeated drain delivered an extra field") }
        #expect(observers.allSatisfy { $0.referenceCount == 1 })
        withExtendedLifetime(filter) {}
    }

    @Test(arguments: [false, true])
    func retainedOutputSurvivesGraphRetirement(progressiveTail: Bool) throws {
        let filter = try makeFilter()
        var observers: [BufferObserver] = []
        var retained: UnsafeMutablePointer<AVFrame>?
        defer { av_frame_free(&retained) }
        var expected: FrameSnapshot?
        var outputCount = 0
        func accept(_ output: VideoDeinterlacer.Output) throws {
            outputCount += 1
            av_frame_free(&retained)
            guard let clone = av_frame_clone(output.frame) else {
                throw PresentationError("Could not retain test output frame")
            }
            retained = clone
            expected = try snapshot(output.frame)
        }
        for index in 0..<3 {
            try withFrame(index: index, interlaced: index != 2 || !progressiveTail,
                          observers: &observers) { frame in
                try filter.process(frame, while: { true }, emit: accept)
            }
        }
        try filter.drain(while: { true }, emit: accept)
        #expect(outputCount == (progressiveTail ? 5 : 6))
        #expect(try snapshot(#require(retained)) == #require(expected))
        // A progressive tail is forwarded by reference through BWDIF. Only
        // the observer and our retained output may still own that input.
        #expect(observers.dropLast().allSatisfy { $0.referenceCount == 1 })
        #expect(observers.last?.referenceCount == (progressiveTail ? 2 : 1))
        av_frame_free(&retained)
        #expect(observers.allSatisfy { $0.referenceCount == 1 })
        withExtendedLifetime(filter) {}
    }

    @Test(arguments: [0, 1, 2])
    func cancelledDrainKeepsPendingFieldsUntilResumed(cancelAfterFields: Int) throws {
        let filter = try makeFilter()
        var observers: [BufferObserver] = []
        var times: [Double] = []
        for index in 0..<3 {
            try withFrame(index: index, observers: &observers) { frame in
                try filter.process(frame, while: { true }) { times.append(seconds($0)) }
            }
        }
        #expect(times.count == 4)
        var drainedFields = 0
        #expect(throws: SoftwarePixelBufferPoolError.cancelled) {
            try filter.drain(while: { drainedFields < cancelAfterFields }) { output in
                drainedFields += 1
                times.append(seconds(output))
            }
        }
        #expect(drainedFields == cancelAfterFields)
        // Even cancellation after the last field must not be mistaken for an
        // observed sink EOF. A resumed drain reaches EOF and retires the graph.
        #expect(observers.contains { $0.referenceCount > 1 })
        try filter.drain(while: { true }) { times.append(seconds($0)) }
        expectTimes(times, startingAt: 0, count: 6)
        #expect(observers.allSatisfy { $0.referenceCount == 1 })
        withExtendedLifetime(filter) {}
    }

    @Test(arguments: [1, 2])
    func throwingConsumerCanResumeWithoutDuplicateFields(throwAfterFields: Int) throws {
        let filter = try makeFilter()
        var observers: [BufferObserver] = []
        var times: [Double] = []
        for index in 0..<3 {
            try withFrame(index: index, observers: &observers) { frame in
                try filter.process(frame, while: { true }) { times.append(seconds($0)) }
            }
        }
        var drainedFields = 0
        #expect(throws: ConsumerFailure.self) {
            try filter.drain(while: { true }) { output in
                // The throwing callback has consumed this field. Retrying
                // must deliver only later fields, not duplicate this one.
                times.append(seconds(output))
                drainedFields += 1
                if drainedFields == throwAfterFields { throw ConsumerFailure.interrupted }
            }
        }
        #expect(drainedFields == throwAfterFields)
        #expect(observers.contains { $0.referenceCount > 1 })
        try filter.drain(while: { true }) { times.append(seconds($0)) }
        expectTimes(times, startingAt: 0, count: 6)
        #expect(observers.allSatisfy { $0.referenceCount == 1 })
        withExtendedLifetime(filter) {}
    }

    @Test func resetReleasesUndrainedInputAndAllowsReuse() throws {
        let filter = try makeFilter()
        var observers: [BufferObserver] = []
        try withFrame(index: 0, observers: &observers) { frame in
            try filter.process(frame, while: { true }) { _ in Issue.record("First input should await its neighbor") }
        }
        #expect(observers.contains { $0.referenceCount > 1 })
        #expect(throws: SoftwarePixelBufferPoolError.cancelled) {
            try filter.drain(while: { false }) { _ in Issue.record("Cancelled drain delivered a field") }
        }
        filter.reset()
        #expect(observers.allSatisfy { $0.referenceCount == 1 })
        var times: [Double] = []
        for index in 4..<7 {
            try withFrame(index: index, observers: &observers) { frame in
                try filter.process(frame, while: { true }) { times.append(seconds($0)) }
            }
        }
        try filter.drain(while: { true }) { times.append(seconds($0)) }
        expectTimes(times, startingAt: 4.0 / 25, count: 6)
        #expect(observers.allSatisfy { $0.referenceCount == 1 })
        withExtendedLifetime(filter) {}
    }

    @Test(arguments: [false, true])
    func sameFormatAfterDrainRequiresReset(interlaced: Bool) throws {
        let filter = try makeFilter()
        var observers: [BufferObserver] = []
        try withFrame(index: 0, observers: &observers) { frame in
            try filter.process(frame, while: { true }) { _ in }
        }
        try filter.drain(while: { true }) { _ in }
        #expect(observers.allSatisfy { $0.referenceCount == 1 })
        try withFrame(index: 1, interlaced: interlaced, observers: &observers) { frame in
            #expect(throws: PresentationError.self) {
                try filter.process(frame, while: { true }) { _ in Issue.record("Same format reopened a drained graph") }
            }
        }
        filter.reset()
        var count = 0
        try withFrame(index: 2, interlaced: false, observers: &observers) { frame in
            try filter.process(frame, while: { true }) { output in
                #expect(!output.filtered)
                #expect(output.frame == frame)
                count += 1
            }
        }
        #expect(count == 1)
        #expect(observers.allSatisfy { $0.referenceCount == 1 })
        withExtendedLifetime(filter) {}
    }

    @Test(arguments: [false, true])
    func changedFormatAfterDrainStillStartsANewGraph(interlaced: Bool) throws {
        let filter = try makeFilter()
        var observers: [BufferObserver] = []
        try withFrame(index: 0, observers: &observers) { frame in
            try filter.process(frame, while: { true }) { _ in }
        }
        try filter.drain(while: { true }) { _ in }
        #expect(observers.allSatisfy { $0.referenceCount == 1 })
        var times: [Double] = []
        func accept(_ output: VideoDeinterlacer.Output) {
            #expect(output.filtered)
            #expect(output.frame.pointee.width == 64)
            times.append(seconds(output))
        }
        for index in 1..<3 {
            try withFrame(index: index, width: 64, interlaced: interlaced,
                          observers: &observers) { frame in
                try filter.process(frame, while: { true }, emit: accept)
            }
        }
        try filter.drain(while: { true }, emit: accept)
        #expect(times.count == (interlaced ? 4 : 2))
        for (index, time) in times.enumerated() {
            #expect(abs(time - (1.0 / 25 + Double(index) / (interlaced ? 50 : 25))) < 0.000_001)
        }
        #expect(observers.allSatisfy { $0.referenceCount == 1 })
        withExtendedLifetime(filter) {}
    }

    @Test func destructionReleasesAnInterruptedDrain() throws {
        var filter: VideoDeinterlacer? = try makeFilter()
        var observers: [BufferObserver] = []
        try withFrame(index: 0, observers: &observers) { frame in
            try #require(filter).process(frame, while: { true }) { _ in }
        }
        #expect(throws: SoftwarePixelBufferPoolError.cancelled) {
            try #require(filter).drain(while: { false }) { _ in Issue.record("Cancelled drain delivered a field") }
        }
        #expect(observers.contains { $0.referenceCount > 1 })
        filter = nil
        #expect(observers.allSatisfy { $0.referenceCount == 1 })
    }

    private func makeFilter() throws -> VideoDeinterlacer {
        try VideoDeinterlacer(timeBase: .init(numerator: 1, denominator: 25), nominalFrameRate: 25)
    }

    private func seconds(_ output: VideoDeinterlacer.Output) -> Double {
        Double(output.frame.pointee.pts) * Double(output.timeBase.numerator) / Double(output.timeBase.denominator)
    }

    private func expectTimes(_ times: [Double], startingAt first: Double, count: Int) {
        #expect(times.count == count)
        for (index, value) in times.enumerated() {
            #expect(abs(value - (first + Double(index) / 50)) < 0.000_001)
        }
    }

    private func withFrame(index: Int, width: Int32 = 32, interlaced: Bool = true, topFirst: Bool = true,
                           observers: inout [BufferObserver],
                           body: (UnsafeMutablePointer<AVFrame>) throws -> Void) throws {
        var allocated = av_frame_alloc()
        let frame = try #require(allocated)
        defer { av_frame_free(&allocated) }
        frame.pointee.width = width
        frame.pointee.height = 32
        frame.pointee.format = Int32(AV_PIX_FMT_YUV420P.rawValue)
        frame.pointee.pts = Int64(index)
        frame.pointee.duration = 1
        frame.pointee.sample_aspect_ratio = .init(num: 1, den: 1)
        frame.pointee.flags = interlaced ? AV_FRAME_FLAG_INTERLACED | (topFirst ? AV_FRAME_FLAG_TOP_FIELD_FIRST : 0) : 0
        frame.pointee.colorspace = AVCOL_SPC_BT709
        frame.pointee.color_range = AVCOL_RANGE_MPEG
        #expect(av_frame_get_buffer(frame, 32) >= 0)
        let buffer = try #require(frame.pointee.buf.0)
        observers.append(try BufferObserver(buffer))
        let luma = try #require(frame.pointee.data.0)
        let u = try #require(frame.pointee.data.1)
        let v = try #require(frame.pointee.data.2)
        for row in 0..<32 {
            for column in 0..<Int(width) {
                luma[row * Int(frame.pointee.linesize.0) + column] = UInt8((31 + index * 17 + row * 3 + column) & 255)
            }
        }
        for row in 0..<16 {
            memset(u.advanced(by: row * Int(frame.pointee.linesize.1)), 96, Int(width) / 2)
            memset(v.advanced(by: row * Int(frame.pointee.linesize.2)), 160, Int(width) / 2)
        }
        try body(frame)
    }

    private func snapshot(_ pointer: UnsafeMutablePointer<AVFrame>) throws -> FrameSnapshot {
        let frame = pointer.pointee
        let width = Int(frame.width), height = Int(frame.height)
        let planes = [
            (frame.data.0, Int(frame.linesize.0), width, height),
            (frame.data.1, Int(frame.linesize.1), width / 2, height / 2),
            (frame.data.2, Int(frame.linesize.2), width / 2, height / 2),
        ]
        var bytes: [UInt8] = []
        for (plane, stride, columns, rows) in planes {
            let data = try #require(plane)
            for row in 0..<rows {
                bytes.append(contentsOf: UnsafeBufferPointer(start: data.advanced(by: row * stride), count: columns))
            }
        }
        return FrameSnapshot(pts: frame.pts, duration: frame.duration, width: frame.width, height: frame.height,
                             flags: frame.flags, colorSpace: frame.colorspace, colorRange: frame.color_range, bytes: bytes)
    }
}
