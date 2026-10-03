import CFFmpeg
import CoreVideo
import CryptoKit
import Foundation
import Testing
@testable import SuperplayrNativePlayback

@Suite("Bounded software seek acceleration", .serialized)
struct SoftwareSeekAccelerationTests {
    @Test func limitsAccelerationToExpensiveQualified4KTargets() {
        func decide(_ target: Double?, _ packet: Double?, width: Int = 3_840,
                    height: Int = 2_160, eligible: Bool = true) -> Bool {
            SoftwareSeekAccelerationPolicy.shouldAccelerate(target: target, packetTime: packet,
                width: width, height: height, eligible: eligible)
        }
        #expect(decide(8.5, 0))
        #expect(!decide(10.03, 10))
        #expect(!decide(1.17, 0))
        #expect(!decide(8.5, 0, eligible: false))
        #expect(!decide(8.5, 0, width: 1_920, height: 1_080))
        #expect(!decide(8.5, 0, width: 7_680, height: 4_320))
        #expect(!decide(.nan, 0))
        #expect(!decide(8.5, nil))
        #expect(!decide(8.5, .infinity))
    }

    @Test func idrBoundaryRejectsContainerFlagsWithoutValidAccessUnits() throws {
        let parameters = try #require(avcodec_parameters_alloc())
        let packet = try #require(av_packet_alloc())
        defer {
            var p: UnsafeMutablePointer<AVCodecParameters>? = parameters
            var q: UnsafeMutablePointer<AVPacket>? = packet
            avcodec_parameters_free(&p)
            av_packet_free(&q)
        }
        parameters.pointee.codec_id = AV_CODEC_ID_H264
        parameters.pointee.extradata = av_mallocz(7 + Int(AV_INPUT_BUFFER_PADDING_SIZE))?.assumingMemoryBound(to: UInt8.self)
        parameters.pointee.extradata_size = 7
        let extra = try #require(parameters.pointee.extradata)
        extra[0] = 1
        extra[4] = 0xFF
        func check(_ bytes: [UInt8], key: Bool = true, corrupt: Bool = false) throws -> Bool {
            av_packet_unref(packet)
            try checkFFmpeg(av_new_packet(packet, Int32(bytes.count)), operation: "Test access unit")
            bytes.withUnsafeBytes { raw in
                packet.pointee.data.update(from: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: bytes.count)
            }
            packet.pointee.flags = (key ? Int32(AV_PKT_FLAG_KEY) : 0) | (corrupt ? Int32(AV_PKT_FLAG_CORRUPT) : 0)
            return superplayr_packet_is_h264_idr(packet, parameters) != 0
        }
        #expect(try check([0, 0, 0, 2, 0x65, 0]))
        #expect(try !check([0, 0, 0, 2, 0x41, 0]))
        #expect(try !check([0, 0, 0, 2, 0x65, 0], key: false))
        #expect(try !check([0, 0, 0, 2, 0x65, 0], corrupt: true))
        #expect(try !check([0, 0, 0, 8, 0x65, 0]))
        #expect(try !check([0, 0, 0, 2, 0x65, 0, 1]))
        #expect(try !check([0, 0, 0, 0]))
    }

    @Test(arguments: [1.17, 2.5, 8.5, 9.93, 10.03, 18.5])
    func exactFramesAndHardwareHandoffMatchFullHardwareDecode(target: Double) throws {
        guard let url = fixture else { return }
        let crossesIDR = target == 8.5 || target == 9.93
        let through = crossesIDR ? 10.2 : target + 0.1
        let usesBurst = target.truncatingRemainder(dividingBy: 10) >= 2
        let baseline = try capture(url, target: target, through: through, accelerated: false)
        let candidate = try capture(url, target: target, through: through, accelerated: true)
        #expect(baseline.frames.count >= 3)
        #expect(candidate.frames == baseline.frames)
        #expect(baseline.hardware.allSatisfy { $0 })
        #expect(candidate.hardware.first == !usesBurst)
        #expect(candidate.hardware.last == (crossesIDR || !usesBurst))
        #expect(candidate.bursts == (usesBurst ? 1 : 0))
        #expect(candidate.restorations == (crossesIDR ? 1 : 0))
    }

    @Test(arguments: [false, true])
    func cancellationCanFlushAndSeekBackToHardware(duringHandoff: Bool) throws {
        guard let url = fixture else { return }
        let demuxer = try FFmpegDemuxer(url: url)
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(parameters: parameters, stream: stream, preferHardware: true,
            softwareOutputMode: .planarPreferred(rendererAttributes: [:]))
        decoder.seekOutputFloor = (1, 8.5)
        try demuxer.seek(to: 8.5, exact: true)
        var packets = 0
        var cancelled = false
        while let packet = try demuxer.readPacket(generation: 1) {
            guard packet.streamIndex == stream.index else { continue }
            packets += 1
            let handoff = duringHandoff && packets > 1 && packet.isKeyframe
            do {
                try decoder.decode(packet, while: { duringHandoff || packets < 40 }) { _ in
                    if handoff { throw SoftwarePixelBufferPoolError.cancelled }
                }
            } catch SoftwarePixelBufferPoolError.cancelled {
                cancelled = true
                break
            }
        }
        #expect(cancelled)
        #expect(decoder.isAcceleratingSeekInSoftware)
        decoder.flush()
        decoder.seekOutputFloor = (2, 10.03)
        try demuxer.seek(to: 10.03, exact: true)
        var first: NativeDecodedVideoFrame?
        while first == nil, let packet = try demuxer.readPacket(generation: 2) {
            if packet.streamIndex == stream.index {
                try decoder.decode(packet, while: { true }) { if first == nil { first = $0 } }
            }
        }
        let frame = try #require(first)
        #expect(frame.presentationTime.seconds >= 10.03)
        #expect(frame.isHardwareDecoded)
        #expect(decoder.hardwareSeekRestorationCount == 1)
        #expect(!decoder.softwareFallbackActivated)
        #expect(!decoder.isAcceleratingSeekInSoftware)
    }

    private var fixture: URL? {
        guard let path = ProcessInfo.processInfo.environment["SUPERPLAYR_SEEK_PROFILE_FIXTURE"],
              path.hasSuffix("h264-4k-gop10.mp4") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private struct Signature: Equatable {
        let pts: Double
        let duration: Double
        let pixels: SHA256.Digest
    }

    private func capture(_ url: URL, target: Double, through: Double, accelerated: Bool) throws
        -> (frames: [Signature], hardware: [Bool], bursts: Int, restorations: Int) {
        let demuxer = try FFmpegDemuxer(url: url)
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(parameters: parameters, stream: stream, preferHardware: true,
            softwareOutputMode: .planarPreferred(rendererAttributes: [:]),
            softwareSeekAccelerationEnabled: accelerated)
        decoder.seekOutputFloor = (1, target)
        try demuxer.seek(to: target, exact: true)
        var frames: [Signature] = []
        var hardware: [Bool] = []
        var done = false
        func collect(_ frame: NativeDecodedVideoFrame) throws {
            let pts = frame.presentationTime.seconds
            if pts >= through - 0.001 { done = true }
            guard pts <= through + 0.001 else { return }
            let buffer = frame.pixelBuffer
            #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            var hash = SHA256()
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
                let width = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                    hash.update(bufferPointer: UnsafeRawBufferPointer(start: base.advanced(by: row * stride), count: width))
                }
            }
            frames.append(Signature(pts: pts, duration: frame.duration.seconds, pixels: hash.finalize()))
            hardware.append(frame.isHardwareDecoded)
        }
        while !done, let packet = try demuxer.readPacket(generation: 1) {
            if packet.streamIndex == stream.index {
                try decoder.decode(packet, while: { true }, emit: collect)
            }
        }
        return (frames, hardware, decoder.softwareSeekAccelerationCount, decoder.hardwareSeekRestorationCount)
    }
}
