import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Hardware video output equivalence", .serialized)
struct HardwareVideoOutputTests {
    private struct Output: Equatable {
        let time: CMTime
        let duration: CMTime
        let size: CGSize
        let depth: Int
        let fullRange: Bool
        let primaries: Int32?
        let transfer: Int32?
        let matrix: Int32?
        let pixelFormat: OSType
        let planes: [Data]
    }

    @Test(arguments: ["h264-aac.mp4", "hevc-10bit-aac.mkv", "vp9-opus.mkv", "vp9-10bit-video-only.mkv"])
    func hardwarePreservesPixelsTimingAndMetadataIncludingSeek(filename: String) throws {
        guard let path = ProcessInfo.processInfo.environment["ILLIQUID_NATIVE_FIXTURE_DIR"] else {
            print("[hardware-output] unqualified: no fixture directory")
            return
        }
        let url = URL(fileURLWithPath: path).appendingPathComponent(filename)
        let probe = try FFmpegDemuxer(url: url)
        let stream = try #require(probe.mediaInfo.videoStreams.first)
        guard VideoDecoder.platformSupportsHardwareDecode(codecName: stream.codecName,
            registerSupplementalVP9: true) else {
            print("[hardware-output] unqualified: host has no hardware decoder for \(stream.codecName)")
            return
        }
        for target: Double? in [nil, 1.25] {
            let software = try decode(url, hardware: false, target: target)
            let hardware = try decode(url, hardware: true, target: target)
            let identical = hardware == software
            if !identical {
                print("[hardware-output] hardware-depth=\(hardware.first?.depth ?? -1) software-depth=\(software.first?.depth ?? -1) planes-equal=\(hardware.map(\.planes) == software.map(\.planes))")
            }
            #expect(identical)
            print("[hardware-output] fixture=\(filename) target=\(target ?? 0) frames=\(hardware.count) exact-pixels-timing-metadata=\(hardware == software)")
        }
    }

    private func decode(_ url: URL, hardware: Bool, target: Double?) throws -> [Output] {
        let demuxer = try FFmpegDemuxer(url: url)
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(
            parameters: parameters, stream: stream, preferHardware: hardware,
            timelineOriginSeconds: demuxer.mediaInfo.startTime,
            softwareOutputMode: .planarExperiment(rendererAttributes: [:]),
            softwareSeekAccelerationEnabled: false
        )
        if let target {
            try demuxer.seek(to: target, exact: true)
            decoder.flush()
            decoder.seekOutputFloor = (1, target)
        }
        var frames: [Output] = []
        while frames.count < 12, let packet = try demuxer.readPacket(generation: 1) {
            guard packet.streamIndex == stream.index else { continue }
            try decoder.decode(packet, while: { true }) { frame in
                #expect(frame.isHardwareDecoded == hardware)
                let buffer = frame.pixelBuffer
                let format = CVPixelBufferGetPixelFormatType(buffer)
                try #require([
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                    kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                ].contains(format))
                try #require(CVPixelBufferGetPlaneCount(buffer) == 2)
                try #require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                // Inspect the actual storage independently of the depth metadata
                // being tested, so incorrect metadata cannot truncate this check.
                let bytesPerComponent = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                    kCVPixelFormatType_420YpCbCr10BiPlanarFullRange].contains(format) ? 2 : 1
                var planes: [Data] = []
                for plane in 0..<2 {
                    let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
                    let rowBytes = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2) * bytesPerComponent
                    var bytes = Data()
                    for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                        bytes.append(base.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)).assumingMemoryBound(to: UInt8.self), count: rowBytes)
                    }
                    planes.append(bytes)
                }
                frames.append(Output(time: frame.presentationTime, duration: frame.duration,
                    size: frame.codedSize, depth: frame.sourceComponentDepth,
                    fullRange: frame.isFullRange, primaries: frame.colorPrimaries,
                    transfer: frame.transferCharacteristic, matrix: frame.matrixCoefficients,
                    pixelFormat: format, planes: planes))
            }
        }
        try #require(frames.count >= 12)
        return Array(frames.prefix(12))
    }
}
