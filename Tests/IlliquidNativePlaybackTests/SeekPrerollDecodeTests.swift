import CoreVideo
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Exact seek preroll decode", .serialized)
struct SeekPrerollDecodeTests {
    @Test func restoresFullDecodeBeforeTargetAndKeepsItForReorderedPackets() {
        var policy = SeekPrerollDecodePolicy()
        func decide(_ pts: Double?, generation: Int = 1, dts: Double? = nil, eligible: Bool = true) -> Bool {
            policy.shouldSkipNonReference(generation: generation, target: 8.5,
                presentationTime: pts, decodeTime: dts, frameRate: 30, eligible: eligible)
        }
        #expect(decide(1))
        #expect(decide(8.3) == false)
        #expect(decide(8.1) == false)
        #expect(decide(1, generation: 2))
        #expect(decide(nil, generation: 2) == false)
        #expect(decide(1, generation: 2) == false)
        #expect(decide(1, generation: 3, dts: 1))
        #expect(decide(2, generation: 3, dts: 0.5) == false)
        #expect(decide(3, generation: 3, dts: 2) == false)
        #expect(decide(1, generation: 4, eligible: false) == false)
        #expect(decide(1, generation: 4) == false)
    }

    @Test func unknownCadenceOptsOutAndNewTargetResetsTheFrontier() {
        for rate: Double? in [nil, .nan, .infinity, 0, -1] {
            var policy = SeekPrerollDecodePolicy()
            let skips = policy.shouldSkipNonReference(generation: 1, target: 8.5,
                presentationTime: 1, decodeTime: 0.9, frameRate: rate, eligible: true)
            #expect(skips == false)
        }
        var policy = SeekPrerollDecodePolicy()
        let nearTarget = policy.shouldSkipNonReference(generation: 1, target: 1,
            presentationTime: 1, decodeTime: 0.9, frameRate: 30, eligible: true)
        #expect(nearTarget == false)
        let newTarget = policy.shouldSkipNonReference(generation: 1, target: 8.5,
            presentationTime: 1, decodeTime: 0.9, frameRate: 30, eligible: true)
        #expect(newTarget)
    }

    @Test(arguments: ["h264-aac.mp4", "hevc-10bit-aac.mkv", "nonzero-start.mkv", "interlaced-tff.mpg", "long-vfr-av-sync.mkv"])
    func targetAndFollowingFramesMatchFullDecode(filename: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["ILLIQUID_NATIVE_FIXTURE_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(filename)
        let targets = filename == "nonzero-start.mkv" ? [0.0, 0.25, 0.67]
            : filename == "interlaced-tff.mpg" ? [0.0, 0.25, 1.17, 1.5] : [0.0, 0.25, 1.17, 2.5]
        for target in targets {
            let baseline = try frames(url, target: target, optimized: false)
            let candidate = try frames(url, target: target, optimized: true)
            #expect(!baseline.isEmpty)
            #expect(candidate == baseline, "\(filename) target \(target)")
        }
    }

    @Test(arguments: [false, true]) func longGOPTargetsMatchFullDecode(hardware: Bool) throws {
        guard let path = ProcessInfo.processInfo.environment["ILLIQUID_SEEK_PROFILE_FIXTURE"] else { return }
        let url = URL(fileURLWithPath: path)
        for target in [0.03, 1.17, 8.5, 9.93, 10.03, 18.5] {
            let baseline = try frames(url, target: target, optimized: false, hardware: hardware)
            let candidate = try frames(url, target: target, optimized: true, hardware: hardware)
            #expect(!baseline.isEmpty)
            #expect(candidate == baseline, "\(url.lastPathComponent) target \(target)")
        }
    }

    private struct Frame: Equatable {
        let seconds: Double
        let duration: Double
        let filtered: Bool
        let planes: [Data]
    }

    private func frames(_ url: URL, target: Double, optimized: Bool, hardware: Bool = false) throws -> [Frame] {
        let demuxer = try FFmpegDemuxer(url: url)
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(parameters: parameters, stream: stream, preferHardware: hardware,
            timelineOriginSeconds: demuxer.mediaInfo.startTime,
            softwareOutputMode: .planarPreferred(rendererAttributes: [:]),
            seekPrerollFrameSkippingEnabled: optimized,
            softwareSeekAccelerationEnabled: false)
        decoder.seekOutputFloor = (1, target)
        try demuxer.seek(to: target + demuxer.mediaInfo.startTime, exact: true)
        var frames: [Frame] = []
        func collect(_ frame: NativeDecodedVideoFrame) throws {
            guard frames.count < 3 else { return }
            let buffer = frame.pixelBuffer
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let planar = CVPixelBufferIsPlanar(buffer)
            let tenBit = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            var planes: [Data] = []
            for plane in 0..<(planar ? CVPixelBufferGetPlaneCount(buffer) : 1) {
                let base = try #require(planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, plane) : CVPixelBufferGetBaseAddress(buffer))
                let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
                let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
                let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) : CVPixelBufferGetBytesPerRow(buffer)
                let bytesPerElement = planar ? (plane == 0 ? 1 : 2) * (tenBit ? 2 : 1) : 4
                var data = Data()
                for row in 0..<height {
                    data.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: width * bytesPerElement)
                }
                planes.append(data)
            }
            frames.append(Frame(seconds: frame.presentationTime.seconds, duration: frame.duration.seconds,
                filtered: frame.usesDeinterlacingFilter, planes: planes))
        }
        while frames.count < 3, let packet = try demuxer.readPacket(generation: 1) {
            if packet.streamIndex == stream.index {
                try decoder.decode(packet, while: { true }, emit: collect)
            }
        }
        if frames.count < 3 { try decoder.drain(generation: 1, while: { true }, emit: collect) }
        if optimized, url.lastPathComponent.hasPrefix("h264-"),
           url.lastPathComponent.contains("gop10") {
            if target.truncatingRemainder(dividingBy: 10) > 1 {
                #expect(decoder.seekPrerollNonReferencePackets > 0, "target \(target)")
            } else if target.truncatingRemainder(dividingBy: 10) < 0.25 {
                #expect(decoder.seekPrerollNonReferencePackets == 0, "keyframe-adjacent target \(target)")
            }
        }
        return frames
    }
}
