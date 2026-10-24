import CFFmpeg
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Video decoder scratch-frame lifetime", .serialized)
struct VideoDecoderFrameLifetimeTests {
    enum Interruption: CaseIterable, Sendable {
        case cancelledAfterDelivery
        case throwingConsumer
        case outputCapacityRejected
    }

    private enum ConsumerFailure: Error, Equatable { case requested }

    @Test(arguments: [false, true])
    func normalDeliveryReleasesInputStorageWhileOutputOutlivesDecoder(deinterlacing: Bool) throws {
        let fixture = VideoFrameLifetimeFixture()
        var decoder: VideoDecoder? = try fixture.makeDecoder(deinterlacingEnabled: deinterlacing)
        weak var retiredDecoder = decoder
        let result = try deliver(fixture, through: decoder!, at: 3)
        let frame = try #require(result.frame)
        #expect(result.probe.releaseCount == 1)
        #expect(result.probe.liveBytes == 0)
        #expect(frame.presentationTime.seconds == 0.1)
        #expect(frame.generation == 1)
        #expect(try fixture.pixels(of: frame) == fixture.expectedPixels())

        decoder?.flush()
        decoder = nil
        #expect(retiredDecoder == nil)
        #expect(result.probe.releaseCount == 1)
        #expect(try fixture.pixels(of: frame) == fixture.expectedPixels())
    }

    @Test(arguments: Interruption.allCases, [false, true])
    func interruptedDeliveryReleasesInputStorageBeforeReuseOrFlush(
        interruption: Interruption, deinterlacing: Bool
    ) throws {
        let fixture = VideoFrameLifetimeFixture()
        var decoder: VideoDecoder? = try fixture.makeDecoder(deinterlacingEnabled: deinterlacing)
        weak var retiredDecoder = decoder
        let interrupted = try deliver(fixture, through: decoder!, interruption: interruption)
        // The packet has left scope, but the decoder and any emitted pixel
        // buffer remain alive. This callback proves an allocation was freed,
        // not merely that one AVFrame reference stopped pointing at it.
        #expect(interrupted.probe.releaseCount == 1)
        #expect(interrupted.probe.liveBytes == 0)
        if let frame = interrupted.frame {
            #expect(try fixture.pixels(of: frame) == fixture.expectedPixels())
        }

        let continued = try deliver(fixture, through: decoder!, at: 1, marker: 34)
        #expect(continued.probe.liveBytes == 0)
        #expect(try fixture.pixels(of: #require(continued.frame)) == fixture.expectedPixels(marker: 34))
        decoder?.flush()
        let replayed = try deliver(fixture, through: decoder!, at: 0, generation: 2, marker: 51)
        let replayedFrame = try #require(replayed.frame)
        #expect(replayed.probe.liveBytes == 0)
        #expect(replayedFrame.presentationTime == .zero)
        #expect(replayedFrame.generation == 2)
        #expect(try fixture.pixels(of: replayedFrame) == fixture.expectedPixels(marker: 51))
        decoder = nil
        #expect(retiredDecoder == nil)
        #expect(interrupted.probe.releaseCount == 1)
        if let frame = interrupted.frame {
            #expect(try fixture.pixels(of: frame) == fixture.expectedPixels())
        }
        #expect(try fixture.pixels(of: replayedFrame) == fixture.expectedPixels(marker: 51))
    }

    @Test(arguments: [false, true])
    func interruptedTimestampDiscoveryReleasesInputWithoutAllocatingDisplayBuffers(
        throwingConsumer: Bool
    ) throws {
        let fixture = VideoFrameLifetimeFixture()
        let decoder = try fixture.makeDecoder()
        func discover() throws -> (VideoFrameLifetimeBufferProbe, [CMTime]) {
            let input = try fixture.makePacket(at: 3)
            var times: [CMTime] = []
            var keepDecoding = true
            let operation = {
                try decoder.decodePresentationTimes(input.packet, while: { keepDecoding }) { time in
                    times.append(time)
                    if throwingConsumer { throw ConsumerFailure.requested }
                    keepDecoding = false
                }
            }
            if throwingConsumer {
                #expect(throws: ConsumerFailure.requested) { try operation() }
            } else {
                #expect(throws: SoftwarePixelBufferPoolError.cancelled) { try operation() }
            }
            return (input.probe, times)
        }
        let (probe, times) = try discover()
        #expect(times == [CMTime(value: 3, timescale: 30)])
        #expect(probe.releaseCount == 1)
        #expect(probe.liveBytes == 0)
        #expect(!decoder.hasSoftwareOutputPoolForDiagnostics)
        decoder.flush()
        func replay() throws -> VideoFrameLifetimeBufferProbe {
            let input = try fixture.makePacket(at: 0, generation: 2)
            var replayed: [CMTime] = []
            try decoder.decodePresentationTimes(input.packet, while: { true }) { replayed.append($0) }
            #expect(replayed == [.zero])
            return input.probe
        }
        #expect(try replay().liveBytes == 0)
        #expect(!decoder.hasSoftwareOutputPoolForDiagnostics)
    }

    @Test func cancellationBeforeSubmissionDoesNotRetainInput() throws {
        let fixture = VideoFrameLifetimeFixture()
        let decoder = try fixture.makeDecoder()
        func cancel() throws -> VideoFrameLifetimeBufferProbe {
            let input = try fixture.makePacket()
            #expect(throws: SoftwarePixelBufferPoolError.cancelled) {
                try decoder.decode(input.packet, while: { false }) { _ in
                    Issue.record("A cancelled request delivered a frame")
                }
            }
            return input.probe
        }
        let probe = try cancel()
        #expect(probe.liveBytes == 0)
        #expect(probe.releaseCount == 1)
        #expect(!decoder.hasSoftwareOutputPoolForDiagnostics)
    }

    private func deliver(
        _ fixture: VideoFrameLifetimeFixture,
        through decoder: VideoDecoder,
        interruption: Interruption? = nil,
        at timestamp: Int64 = 0,
        generation: Int = 1,
        marker: UInt8 = 17
    ) throws -> (frame: NativeDecodedVideoFrame?, probe: VideoFrameLifetimeBufferProbe) {
        let input = try fixture.makePacket(at: timestamp, generation: generation, marker: marker)
        var output: NativeDecodedVideoFrame?
        var keepDecoding = true
        var capacityRequests = 0
        let reserve: (() -> VideoFrameCapacityPermit?)?
        if interruption == .outputCapacityRejected {
            reserve = { capacityRequests += 1; return nil }
        } else {
            reserve = nil
        }
        let operation = {
            try decoder.decode(input.packet, while: { keepDecoding }, reserveSoftwareOutput: reserve) { frame in
                #expect(output == nil, "Rawvideo must emit exactly one frame")
                output = frame
                if interruption == .throwingConsumer { throw ConsumerFailure.requested }
                if interruption == .cancelledAfterDelivery { keepDecoding = false }
            }
        }
        switch interruption {
        case .throwingConsumer:
            #expect(throws: ConsumerFailure.requested) { try operation() }
        case .cancelledAfterDelivery, .outputCapacityRejected:
            #expect(throws: SoftwarePixelBufferPoolError.cancelled) { try operation() }
        case nil:
            try operation()
        }
        if interruption == .outputCapacityRejected {
            #expect(output == nil)
            #expect(capacityRequests == 1)
            #expect(!decoder.hasSoftwareOutputPoolForDiagnostics)
        } else {
            _ = try #require(output)
        }
        return (output, input.probe)
    }
}

/// Tracks the lifetime of one real av_malloc allocation. The callback owns the
/// probe, but the probe owns no bytes and cannot prolong their native lifetime.
final class VideoFrameLifetimeBufferProbe: @unchecked Sendable {
    let allocatedBytes: Int
    private let lock = NSLock()
    private var releases = 0

    init(allocatedBytes: Int) { self.allocatedBytes = allocatedBytes }

    var releaseCount: Int { lock.withLock { releases } }
    var liveBytes: Int { lock.withLock { releases == 0 ? allocatedBytes : 0 } }

    fileprivate func didFree() { lock.withLock { releases += 1 } }
}

/// RAWVIDEO references the packet's AVBuffer for BGRA input. Software display
/// output copies those pixels, letting a free callback isolate scratch-frame
/// ownership from output buffers, codec reference history, and allocator RSS.
struct VideoFrameLifetimeFixture {
    let width: Int
    let height: Int
    var payloadBytes: Int { width * height * 4 }
    var allocatedBytes: Int { payloadBytes + Int(AV_INPUT_BUFFER_PADDING_SIZE) }

    init(width: Int = 64, height: Int = 48) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
    }

    func makeDecoder(deinterlacingEnabled: Bool = true) throws -> VideoDecoder {
        var allocation = avcodec_parameters_alloc()
        let parameters = try #require(allocation)
        defer { avcodec_parameters_free(&allocation) }
        parameters.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        parameters.pointee.codec_id = AV_CODEC_ID_RAWVIDEO
        parameters.pointee.format = AV_PIX_FMT_BGRA.rawValue
        parameters.pointee.width = Int32(width)
        parameters.pointee.height = Int32(height)
        parameters.pointee.bits_per_coded_sample = 32
        parameters.pointee.field_order = AV_FIELD_PROGRESSIVE
        let stream = FFmpegStreamInfo(
            index: 0, kind: .video, codecID: Int32(AV_CODEC_ID_RAWVIDEO.rawValue), codecName: "rawvideo",
            title: nil, language: nil, timeBase: .init(numerator: 1, denominator: 30),
            duration: nil, disposition: 0, codedSize: CGSize(width: width, height: height),
            pixelAspectRatio: CGSize(width: 1, height: 1), averageFrameRate: 30,
            sampleRate: nil, channelCount: nil, channelLayout: nil, rotationDegrees: 0,
            isMirrored: false, interlaceMode: .progressive
        )
        return try VideoDecoder(
            parameters: parameters, stream: stream, preferHardware: false,
            softwareOutputMode: .bgra, softwareDecoderThreadCount: 1,
            deinterlacingEnabled: deinterlacingEnabled,
            seekPrerollFrameSkippingEnabled: false, softwareSeekAccelerationEnabled: false
        )
    }

    func makePacket(at timestamp: Int64 = 0, generation: Int = 1, marker: UInt8 = 17) throws
        -> (packet: FFmpegPacket, probe: VideoFrameLifetimeBufferProbe) {
        var allocation = av_packet_alloc()
        let packet = try #require(allocation)
        defer { av_packet_free(&allocation) }
        let data = try #require(av_mallocz(allocatedBytes)).assumingMemoryBound(to: UInt8.self)
        fill(data, marker: marker)
        let probe = VideoFrameLifetimeBufferProbe(allocatedBytes: allocatedBytes)
        let owner = Unmanaged.passRetained(probe)
        let reference = av_buffer_create(data, allocatedBytes, { opaque, bytes in
            av_free(bytes)
            if let opaque {
                Unmanaged<VideoFrameLifetimeBufferProbe>.fromOpaque(opaque).takeRetainedValue().didFree()
            }
        }, owner.toOpaque(), 0)
        guard let reference else {
            av_free(data)
            owner.release()
            throw FFmpegError(operation: "Allocate tracked rawvideo buffer", code: illiquid_averror_nomem())
        }
        packet.pointee.buf = reference
        packet.pointee.data = data
        packet.pointee.size = Int32(payloadBytes)
        packet.pointee.pts = timestamp
        packet.pointee.dts = timestamp
        packet.pointee.duration = 1
        packet.pointee.stream_index = 0
        packet.pointee.flags |= AV_PKT_FLAG_KEY
        return (try FFmpegPacket(taking: &allocation, timeBase: .init(num: 1, den: 30), generation: generation), probe)
    }

    func expectedPixels(marker: UInt8 = 17) -> Data {
        var bytes = Data(count: payloadBytes)
        bytes.withUnsafeMutableBytes { raw in
            fill(raw.bindMemory(to: UInt8.self).baseAddress!, marker: marker)
        }
        return bytes
    }

    func pixels(of frame: NativeDecodedVideoFrame) throws -> Data {
        let buffer = frame.pixelBuffer
        try #require(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        try #require(CVPixelBufferGetWidth(buffer) == width && CVPixelBufferGetHeight(buffer) == height)
        try #require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var result = Data()
        result.reserveCapacity(payloadBytes)
        for y in 0..<height {
            result.append(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: width * 4)
        }
        return result
    }

    private func fill(_ data: UnsafeMutablePointer<UInt8>, marker: UInt8) {
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                data[index] = marker
                data[index + 1] = UInt8(truncatingIfNeeded: x)
                data[index + 2] = UInt8(truncatingIfNeeded: y)
                data[index + 3] = 255
            }
        }
    }
}
