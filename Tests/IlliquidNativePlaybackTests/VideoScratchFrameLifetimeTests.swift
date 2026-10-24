import CFFmpeg
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import IlliquidNativePlayback

/// Counts destruction of one actual FFmpeg backing allocation. Keeping this
/// probe alive does not keep the bytes or any AVBufferRef alive.
final class VideoScratchAllocationProbe: @unchecked Sendable {
    let payloadByteCount: Int
    /// Bytes requested from av_mallocz, including the required zero padding;
    /// this is not allocator overhead, resident memory, or physical footprint.
    let storageByteCount: Int
    private let lock = NSLock()
    private var releases = 0

    init(payloadByteCount: Int, storageByteCount: Int) {
        self.payloadByteCount = payloadByteCount
        self.storageByteCount = storageByteCount
    }

    var releaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return releases
    }

    fileprivate func recordRelease() {
        lock.lock()
        releases += 1
        lock.unlock()
    }
}

private let videoScratchFixtureBufferFree:
    @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?) -> Void = {
        opaque, bytes in
        av_free(bytes)
        guard let opaque else { return }
        let probe = Unmanaged<VideoScratchAllocationProbe>
            .fromOpaque(opaque).takeRetainedValue()
        probe.recordRelease()
    }

/// Shared by the regression suite and the native memory experiment. Raw BGRA
/// makes libavcodec reference the supplied AVBuffer instead of creating another
/// pixel allocation, so packet/scratch/fallback ownership is directly observable.
enum VideoScratchFrameFixture {
    private enum FixtureError: Error {
        case invalidDimensions
        case unexpectedPixelBuffer
    }

    static func makeDecoder(
        width: Int,
        height: Int,
        deinterlacing: Bool = true
    ) throws -> VideoDecoder {
        guard width > 0, height > 0,
              let encodedWidth = Int32(exactly: width),
              let encodedHeight = Int32(exactly: height)
        else { throw FixtureError.invalidDimensions }
        var parameters = avcodec_parameters_alloc()
        guard let pointer = parameters else {
            throw FFmpegError(operation: "Allocate scratch-frame fixture parameters",
                              code: illiquid_averror_nomem())
        }
        defer { avcodec_parameters_free(&parameters) }
        pointer.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        pointer.pointee.codec_id = AV_CODEC_ID_RAWVIDEO
        pointer.pointee.format = Int32(AV_PIX_FMT_BGRA.rawValue)
        pointer.pointee.width = encodedWidth
        pointer.pointee.height = encodedHeight
        pointer.pointee.bits_per_coded_sample = 32
        pointer.pointee.sample_aspect_ratio = AVRational(num: 1, den: 1)
        pointer.pointee.field_order = AV_FIELD_PROGRESSIVE
        let stream = FFmpegStreamInfo(
            index: 0, kind: .video, codecID: Int32(AV_CODEC_ID_RAWVIDEO.rawValue),
            codecName: "rawvideo", title: nil, language: nil,
            timeBase: .init(numerator: 1, denominator: 1_000),
            duration: nil, disposition: 0,
            codedSize: CGSize(width: width, height: height),
            pixelAspectRatio: CGSize(width: 1, height: 1), averageFrameRate: 25,
            sampleRate: nil, channelCount: nil, channelLayout: nil,
            rotationDegrees: 0, isMirrored: false, interlaceMode: .progressive
        )
        return try VideoDecoder(
            parameters: pointer, stream: stream, preferHardware: false,
            softwareOutputMode: .bgra, softwareDecoderThreadCount: 1,
            deinterlacingEnabled: deinterlacing
        )
    }

    static func makePacket(
        width: Int,
        height: Int,
        timestamp: Int64 = 0,
        generation: Int = 1
    ) throws -> (FFmpegPacket, VideoScratchAllocationProbe) {
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (payloadBytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        let (storageBytes, paddingOverflow) = payloadBytes.addingReportingOverflow(
            Int(AV_INPUT_BUFFER_PADDING_SIZE)
        )
        guard width > 0, height > 0, !pixelOverflow, !byteOverflow, !paddingOverflow,
              let encodedSize = Int32(exactly: payloadBytes)
        else { throw FixtureError.invalidDimensions }
        var rawPacket = av_packet_alloc()
        guard let packet = rawPacket else {
            throw FFmpegError(operation: "Allocate scratch-frame fixture packet",
                              code: illiquid_averror_nomem())
        }
        defer { av_packet_free(&rawPacket) }
        guard let storage = av_mallocz(storageBytes) else {
            throw FFmpegError(operation: "Allocate scratch-frame fixture pixels",
                              code: illiquid_averror_nomem())
        }
        let bytes = storage.assumingMemoryBound(to: UInt8.self)
        for offset in stride(from: 0, to: payloadBytes, by: 4) {
            bytes[offset] = 17
            bytes[offset + 1] = 65
            bytes[offset + 2] = 131
            bytes[offset + 3] = 255
        }
        let probe = VideoScratchAllocationProbe(
            payloadByteCount: payloadBytes, storageByteCount: storageBytes
        )
        let opaque = Unmanaged.passRetained(probe).toOpaque()
        guard let buffer = av_buffer_create(
            bytes, storageBytes, videoScratchFixtureBufferFree, opaque, 0
        ) else {
            // av_buffer_create takes ownership only on success and does not
            // invoke the free callback on allocation failure.
            Unmanaged<VideoScratchAllocationProbe>.fromOpaque(opaque).release()
            av_free(storage)
            throw FFmpegError(operation: "Own scratch-frame fixture pixels",
                              code: illiquid_averror_nomem())
        }
        packet.pointee.buf = buffer
        packet.pointee.data = bytes
        packet.pointee.size = encodedSize
        packet.pointee.stream_index = 0
        packet.pointee.pts = timestamp
        packet.pointee.dts = timestamp
        packet.pointee.duration = 40
        packet.pointee.flags = Int32(AV_PKT_FLAG_KEY)
        return (
            try FFmpegPacket(taking: &rawPacket,
                             timeBase: AVRational(num: 1, den: 1_000),
                             generation: generation),
            probe
        )
    }

    /// Copies just the visible BGRA rows, independently of CoreVideo padding.
    static func pixelBytes(_ frame: NativeDecodedVideoFrame) throws -> Data {
        let buffer = frame.pixelBuffer
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(buffer)
        else { throw FixtureError.unexpectedPixelBuffer }
        try checkOSStatus(CVPixelBufferLockBaseAddress(buffer, .readOnly),
                          operation: "Lock scratch-frame fixture output")
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw FixtureError.unexpectedPixelBuffer
        }
        let rowBytes = CVPixelBufferGetWidth(buffer) * 4
        let rowStride = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard rowStride >= rowBytes else { throw FixtureError.unexpectedPixelBuffer }
        var result = Data(capacity: rowBytes * height)
        for row in 0..<height {
            result.append(base.advanced(by: row * rowStride)
                .assumingMemoryBound(to: UInt8.self), count: rowBytes)
        }
        return result
    }
}

@Suite("Video decoder scratch-frame lifetime", .serialized)
struct VideoScratchFrameLifetimeTests {
    private enum ConsumerFailure: Error, Equatable { case requested }
    enum FallbackDisposition: CaseIterable, Sendable { case take, flush }

    @Test(arguments: [false, true])
    func throwingFrameConsumerReleasesScratchReference(deinterlacing: Bool) throws {
        let decoder = try VideoScratchFrameFixture.makeDecoder(
            width: 32, height: 24, deinterlacing: deinterlacing
        )
        var tracked: (FFmpegPacket, VideoScratchAllocationProbe)? =
            try VideoScratchFrameFixture.makePacket(width: 32, height: 24, timestamp: 2_000)
        let probe = tracked!.1
        var delivered = 0
        #expect(throws: ConsumerFailure.requested) {
            try decoder.decode(tracked!.0, while: { true }) { frame in
                delivered += 1
                #expect(try referenceCount(tracked!.0) == 2)
                #expect(frame.presentationTime.seconds == 2)
                #expect(frame.deinterlacingFailure == nil)
                #expect(try VideoScratchFrameFixture.pixelBytes(frame)
                    == expectedBytes(width: 32, height: 24))
                throw ConsumerFailure.requested
            }
        }
        #expect(delivered == 1)
        #expect(try referenceCount(tracked!.0) == 1)
        #expect(probe.releaseCount == 0)
        tracked = nil
        #expect(probe.releaseCount == 1)
        withExtendedLifetime(decoder) {}
    }

    @Test(arguments: [false, true])
    func cancellationAfterDeliveryReleasesScratchReference(deinterlacing: Bool) throws {
        let decoder = try VideoScratchFrameFixture.makeDecoder(
            width: 32, height: 24, deinterlacing: deinterlacing
        )
        var tracked: (FFmpegPacket, VideoScratchAllocationProbe)? =
            try VideoScratchFrameFixture.makePacket(width: 32, height: 24)
        let probe = tracked!.1
        var delivered = 0
        #expect(throws: SoftwarePixelBufferPoolError.cancelled) {
            try decoder.decode(tracked!.0, while: { delivered == 0 }) { _ in
                delivered += 1
            }
        }
        #expect(delivered == 1)
        #expect(try referenceCount(tracked!.0) == 1)
        tracked = nil
        #expect(probe.releaseCount == 1)
        withExtendedLifetime(decoder) {}
    }

    @Test(arguments: [false, true])
    func deniedOutputReservationReleasesScratchReference(deinterlacing: Bool) throws {
        let decoder = try VideoScratchFrameFixture.makeDecoder(
            width: 32, height: 24, deinterlacing: deinterlacing
        )
        var tracked: (FFmpegPacket, VideoScratchAllocationProbe)? =
            try VideoScratchFrameFixture.makePacket(width: 32, height: 24)
        let probe = tracked!.1
        var reservations = 0
        var delivered = 0
        #expect(throws: SoftwarePixelBufferPoolError.cancelled) {
            try decoder.decode(tracked!.0, while: { true }, reserveSoftwareOutput: {
                reservations += 1
                return nil
            }) { _ in delivered += 1 }
        }
        #expect(reservations == 1)
        #expect(delivered == 0)
        #expect(!decoder.hasSoftwareOutputPoolForDiagnostics)
        #expect(try referenceCount(tracked!.0) == 1)
        tracked = nil
        #expect(probe.releaseCount == 1)
        withExtendedLifetime(decoder) {}
    }

    @Test(arguments: [false, true])
    func throwingTimestampConsumerReleasesScratchReference(deinterlacing: Bool) throws {
        let decoder = try VideoScratchFrameFixture.makeDecoder(
            width: 32, height: 24, deinterlacing: deinterlacing
        )
        var tracked: (FFmpegPacket, VideoScratchAllocationProbe)? =
            try VideoScratchFrameFixture.makePacket(width: 32, height: 24, timestamp: 2_000)
        let probe = tracked!.1
        var delivered = 0
        #expect(throws: ConsumerFailure.requested) {
            try decoder.decodePresentationTimes(tracked!.0, while: { true }) { time in
                delivered += 1
                #expect(time.seconds == 2)
                #expect(try referenceCount(tracked!.0) == 2)
                throw ConsumerFailure.requested
            }
        }
        #expect(delivered == 1)
        #expect(!decoder.hasSoftwareOutputPoolForDiagnostics)
        #expect(try referenceCount(tracked!.0) == 1)
        tracked = nil
        #expect(probe.releaseCount == 1)
        withExtendedLifetime(decoder) {}
    }

    @Test(arguments: [false, true])
    func normalDecodeAndDrainKeepOnlyCallerOwnedOutput(deinterlacing: Bool) throws {
        let decoder = try VideoScratchFrameFixture.makeDecoder(
            width: 32, height: 24, deinterlacing: deinterlacing
        )
        var tracked: (FFmpegPacket, VideoScratchAllocationProbe)? =
            try VideoScratchFrameFixture.makePacket(width: 32, height: 24,
                                                   timestamp: 120, generation: 7)
        let probe = tracked!.1
        var output: [NativeDecodedVideoFrame] = []
        try decoder.decode(tracked!.0, while: { true }) { output.append($0) }
        #expect(output.count == 1)
        #expect(try referenceCount(tracked!.0) == 1)
        tracked = nil
        #expect(probe.releaseCount == 1)
        try decoder.drain(generation: 7, while: { true }) { _ in
            Issue.record("The single raw frame was emitted again during drain")
        }
        let frame = try #require(output.first)
        #expect(frame.generation == 7)
        #expect(frame.presentationTime == CMTime(value: 120, timescale: 1_000))
        #expect(try VideoScratchFrameFixture.pixelBytes(frame)
            == expectedBytes(width: 32, height: 24))
        withExtendedLifetime(decoder) {}
    }

    @Test(arguments: [false, true])
    func heldOutputSurvivesErrorReuseFlushAndDecoderDestruction(deinterlacing: Bool) throws {
        var decoder: VideoDecoder? = try VideoScratchFrameFixture.makeDecoder(
            width: 32, height: 24, deinterlacing: deinterlacing
        )
        weak var retiredDecoder = decoder
        var tracked: (FFmpegPacket, VideoScratchAllocationProbe)? =
            try VideoScratchFrameFixture.makePacket(width: 32, height: 24,
                                                   timestamp: 120, generation: 7)
        let firstProbe = tracked!.1
        var held: [NativeDecodedVideoFrame] = []
        #expect(throws: ConsumerFailure.requested) {
            try decoder!.decode(tracked!.0, while: { true }) { frame in
                held.append(frame)
                throw ConsumerFailure.requested
            }
        }
        #expect(held.count == 1)
        #expect(try referenceCount(tracked!.0) == 1)
        tracked = nil
        #expect(firstProbe.releaseCount == 1)

        // The same decoder must accept another packet without a flush, and a
        // different pixel pattern detects accidental aliasing of held output.
        tracked = try VideoScratchFrameFixture.makePacket(width: 32, height: 24,
                                                         timestamp: 160, generation: 7)
        let secondProbe = tracked!.1
        try overwriteColor(tracked!.0, with: [211, 97, 33, 255])
        try decoder!.decode(tracked!.0, while: { true }) { held.append($0) }
        #expect(try referenceCount(tracked!.0) == 1)
        tracked = nil
        #expect(secondProbe.releaseCount == 1)

        decoder!.flush()
        tracked = try VideoScratchFrameFixture.makePacket(width: 32, height: 24,
                                                         timestamp: 0, generation: 8)
        let thirdProbe = tracked!.1
        try overwriteColor(tracked!.0, with: [7, 19, 241, 255])
        var delivered = 0
        #expect(throws: SoftwarePixelBufferPoolError.cancelled) {
            try decoder!.decode(tracked!.0, while: { delivered == 0 }) { frame in
                delivered += 1
                held.append(frame)
            }
        }
        #expect(delivered == 1)
        #expect(try referenceCount(tracked!.0) == 1)
        tracked = nil
        #expect(thirdProbe.releaseCount == 1)
        decoder!.flush()
        decoder = nil
        #expect(retiredDecoder == nil)

        try #require(held.count == 3)
        #expect(held.map(\.generation) == [7, 7, 8])
        #expect(held.map(\.presentationTime) == [
            CMTime(value: 120, timescale: 1_000),
            CMTime(value: 160, timescale: 1_000), .zero,
        ])
        #expect(try VideoScratchFrameFixture.pixelBytes(held[0])
            == expectedBytes(width: 32, height: 24))
        #expect(try VideoScratchFrameFixture.pixelBytes(held[1])
            == expectedBytes(width: 32, height: 24, color: [211, 97, 33, 255]))
        #expect(try VideoScratchFrameFixture.pixelBytes(held[2])
            == expectedBytes(width: 32, height: 24, color: [7, 19, 241, 255]))
    }

    @Test(arguments: [false, true])
    func repeatedCancellationsReleaseEachSourceBeforeTheNextDecode(deinterlacing: Bool) throws {
        let decoder = try VideoScratchFrameFixture.makeDecoder(
            width: 16, height: 16, deinterlacing: deinterlacing
        )
        var probes: [VideoScratchAllocationProbe] = []
        for iteration in 0..<24 {
            var tracked: (FFmpegPacket, VideoScratchAllocationProbe)? =
                try VideoScratchFrameFixture.makePacket(width: 16, height: 16,
                                                       timestamp: Int64(iteration) * 40)
            probes.append(tracked!.1)
            var delivered = 0
            #expect(throws: SoftwarePixelBufferPoolError.cancelled) {
                try decoder.decode(tracked!.0, while: { delivered == 0 }) { _ in
                    delivered += 1
                }
            }
            #expect(delivered == 1)
            #expect(try referenceCount(tracked!.0) == 1)
            tracked = nil
            #expect(probes.allSatisfy { $0.releaseCount == 1 })
        }
        decoder.flush()
        #expect(probes.allSatisfy { $0.releaseCount == 1 })
        withExtendedLifetime(decoder) {}
    }

    @Test(arguments: [false, true], FallbackDisposition.allCases)
    func seekFallbackKeepsItsOwnReferenceUntilTakenOrFlushed(
        deinterlacing: Bool, disposition: FallbackDisposition
    ) throws {
        let decoder = try VideoScratchFrameFixture.makeDecoder(
            width: 32, height: 24, deinterlacing: deinterlacing
        )
        decoder.retainsSeekPrerollFallback = true
        decoder.seekOutputFloor = (generation: 1, seconds: 1)
        var tracked: (FFmpegPacket, VideoScratchAllocationProbe)? =
            try VideoScratchFrameFixture.makePacket(width: 32, height: 24)
        let probe = tracked!.1
        try decoder.decode(tracked!.0, while: { true }) { _ in
            Issue.record("A frame below the seek floor escaped preroll filtering")
        }
        #expect(decoder.discardedSeekPrerollFrames == 1)
        #expect(decoder.seekPrerollFallbackProgress?.seconds == 0)
        #expect(!decoder.hasSoftwareOutputPoolForDiagnostics)
        // The scratch frame is empty, but the intentional fallback clone still
        // owns the same AVBuffer independently of the caller's packet.
        #expect(try referenceCount(tracked!.0) == 2)
        tracked = nil
        #expect(probe.releaseCount == 0)
        #expect(try decoder.takeSeekPrerollFallback(generation: 2, while: { true }) == nil)
        #expect(probe.releaseCount == 0)
        switch disposition {
        case .take:
            let fallback = try #require(
                try decoder.takeSeekPrerollFallback(generation: 1, while: { true })
            )
            #expect(probe.releaseCount == 1)
            #expect(fallback.generation == 1)
            #expect(fallback.presentationTime == .zero)
            decoder.flush()
            #expect(try VideoScratchFrameFixture.pixelBytes(fallback)
                == expectedBytes(width: 32, height: 24))
        case .flush:
            decoder.flush()
            #expect(probe.releaseCount == 1)
        }
        #expect(decoder.seekPrerollFallbackProgress == nil)
        #expect(try decoder.takeSeekPrerollFallback(generation: 1, while: { true }) == nil)
        #expect(probe.releaseCount == 1)
        withExtendedLifetime(decoder) {}
    }

    @Test func cancellingAfterPrerollRetentionDoesNotReleaseTheFallbackClone() throws {
        let decoder = try VideoScratchFrameFixture.makeDecoder(width: 32, height: 24)
        decoder.retainsSeekPrerollFallback = true
        decoder.seekOutputFloor = (generation: 1, seconds: 1)
        var tracked: (FFmpegPacket, VideoScratchAllocationProbe)? =
            try VideoScratchFrameFixture.makePacket(width: 32, height: 24)
        let probe = tracked!.1
        #expect(throws: SoftwarePixelBufferPoolError.cancelled) {
            try decoder.decode(tracked!.0, while: {
                decoder.seekPrerollFallbackProgress == nil
            }) { _ in Issue.record("A preroll frame was unexpectedly emitted") }
        }
        #expect(try referenceCount(tracked!.0) == 2)
        tracked = nil
        #expect(probe.releaseCount == 0)
        let fallback = try #require(
            try decoder.takeSeekPrerollFallback(generation: 1, while: { true })
        )
        #expect(probe.releaseCount == 1)
        #expect(try VideoScratchFrameFixture.pixelBytes(fallback)
            == expectedBytes(width: 32, height: 24))
        withExtendedLifetime(decoder) {}
    }

    private func referenceCount(_ packet: FFmpegPacket) throws -> Int {
        let buffer = try #require(packet.pointer?.pointee.buf)
        return Int(av_buffer_get_ref_count(buffer))
    }

    private func expectedBytes(
        width: Int, height: Int, color: [UInt8] = [17, 65, 131, 255]
    ) -> Data {
        Data((0..<(width * height)).flatMap { _ in color })
    }

    private func overwriteColor(_ packet: FFmpegPacket, with color: [UInt8]) throws {
        try #require(color.count == 4)
        let raw = try #require(packet.pointer)
        let bytes = try #require(raw.pointee.data)
        for offset in stride(from: 0, to: Int(raw.pointee.size), by: 4) {
            for component in 0..<4 { bytes[offset + component] = color[component] }
        }
    }
}
