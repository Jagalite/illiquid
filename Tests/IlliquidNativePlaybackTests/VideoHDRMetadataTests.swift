import CoreVideo
import Foundation
import Testing
@testable import IlliquidNativePlayback

private enum VideoHDRFixtures {
    static let names = ["hdr10-pq-p010.mkv", "hlg-p010.mkv", "h264-aac.mp4"]

    static var directory: URL {
        URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["ILLIQUID_NATIVE_FIXTURE_DIR"]
                ?? FileManager.default.currentDirectoryPath + "/TestFixtures/Generated",
            isDirectory: true
        )
    }

    static var enabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["ILLIQUID_NATIVE_FIXTURE_DIR"] != nil
            || environment["ILLIQUID_NATIVE_REQUIRE_FIXTURES"] == "1" {
            return true
        }
        return names.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }
}

@Suite("Decoded HDR metadata payloads", .serialized,
       .enabled(if: VideoHDRFixtures.enabled, "Generate the native HDR10, HLG and H.264 fixtures"))
struct VideoHDRMetadataTests {
    enum Route: String, CaseIterable, Sendable {
        case hardware
        case softwareBGRA
        case softwarePlanar
    }

    private struct RetainedFrame {
        let frame: NativeDecodedVideoFrame
        let masteringBytes: [UInt8]?
        let contentLightBytes: [UInt8]?
    }

    // Independent expected bytes for generate-native-fixtures.sh's HDR10 SEI:
    // G(13250,34500) B(7500,3000) R(34000,16000) WP(15635,16450)
    // L(10000000,50), MaxCLL=1000, MaxFALL=400, all big-endian.
    private let expectedMastering = Data([
        0x33, 0xc2, 0x86, 0xc4, 0x1d, 0x4c, 0x0b, 0xb8,
        0x84, 0xd0, 0x3e, 0x80, 0x3d, 0x13, 0x40, 0x42,
        0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x32,
    ])
    private let expectedContentLight = Data([0x03, 0xe8, 0x01, 0x90])

    @Test(arguments: Route.allCases)
    func hdrPayloadsMatchAttachmentsAndOutliveDecoder(route: Route) throws {
        let retained = try decode("hdr10-pq-p010.mkv", route: route, expectsHDR: true)
        let frame = retained.frame
        #expect(retained.masteringBytes == Array(expectedMastering))
        #expect(retained.contentLightBytes == Array(expectedContentLight))
        #expect(frame.masteringDisplayMetadata == expectedMastering)
        #expect(frame.contentLightMetadata == expectedContentLight)
        #expect(attachment(kCVImageBufferMasteringDisplayColorVolumeKey, from: frame)
            == expectedMastering)
        #expect(attachment(kCVImageBufferContentLightLevelInfoKey, from: frame)
            == expectedContentLight)

        // Mutating a value-semantic copy must not alter the retained frame or
        // the CoreVideo attachment sharing its original payload.
        var copiedMastering = try #require(frame.masteringDisplayMetadata)
        var copiedContentLight = try #require(frame.contentLightMetadata)
        copiedMastering[copiedMastering.startIndex] ^= 0xff
        copiedContentLight[copiedContentLight.startIndex] ^= 0xff
        #expect(copiedMastering != expectedMastering)
        #expect(copiedContentLight != expectedContentLight)
        #expect(frame.masteringDisplayMetadata == expectedMastering)
        #expect(frame.contentLightMetadata == expectedContentLight)
        #expect(attachment(kCVImageBufferMasteringDisplayColorVolumeKey, from: frame)
            == expectedMastering)
        #expect(attachment(kCVImageBufferContentLightLevelInfoKey, from: frame)
            == expectedContentLight)
    }

    @Test(arguments: ["h264-aac.mp4", "hlg-p010.mkv"], Route.allCases)
    func absentStaticMetadataRemainsAbsent(filename: String, route: Route) throws {
        let retained = try decode(filename, route: route, expectsHDR: false)
        #expect(retained.masteringBytes == nil)
        #expect(retained.contentLightBytes == nil)
        #expect(retained.frame.masteringDisplayMetadata == nil)
        #expect(retained.frame.contentLightMetadata == nil)
        #expect(attachment(kCVImageBufferMasteringDisplayColorVolumeKey, from: retained.frame) == nil)
        #expect(attachment(kCVImageBufferContentLightLevelInfoKey, from: retained.frame) == nil)
    }

    private func decode(
        _ filename: String,
        route: Route,
        expectsHDR: Bool
    ) throws -> RetainedFrame {
        let url = VideoHDRFixtures.directory.appendingPathComponent(filename)
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "Required native fixture is missing: \(filename)")
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try #require(size > 0, "Required native fixture is empty: \(filename)")
        let demuxer = try FFmpegDemuxer(url: url)
        let stream = try #require(demuxer.mediaInfo.videoStreams.first)
        let parameters = try #require(demuxer.codecParameters(streamIndex: stream.index))
        let decoder = try VideoDecoder(
            parameters: parameters,
            stream: stream,
            preferHardware: route == .hardware,
            timelineOriginSeconds: demuxer.mediaInfo.startTime,
            softwareOutputMode: route == .softwarePlanar
                ? .planarExperiment(rendererAttributes: [:]) : .bgra,
            softwareDecoderThreadCount: 2
        )
        if route == .hardware {
            try #require(decoder.hardwareWasConfigured,
                         "The hardware fixture route must exercise VideoToolbox")
        }

        var retained: RetainedFrame?
        var count = 0
        func accept(_ frame: NativeDecodedVideoFrame) {
            count += 1
            #expect(frame.isHardwareDecoded == (route == .hardware))
            if route == .softwareBGRA {
                #expect(CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_32BGRA)
            } else if route == .softwarePlanar {
                #expect(CVPixelBufferIsPlanar(frame.pixelBuffer))
            }
            let mastering = attachment(kCVImageBufferMasteringDisplayColorVolumeKey, from: frame)
            let light = attachment(kCVImageBufferContentLightLevelInfoKey, from: frame)
            // Hardware buffers may inherit static attachments even when this
            // AVFrame carries no source side data. Compare present payloads;
            // the retained first frame is required to contain the golden SEI.
            if let payload = frame.masteringDisplayMetadata {
                #expect(payload == mastering)
            }
            if let payload = frame.contentLightMetadata {
                #expect(payload == light)
            }
            #expect(frame.hasMasteringDisplayMetadata == (mastering != nil))
            #expect(frame.hasContentLightMetadata == (light != nil))
            #expect(mastering == (expectsHDR ? expectedMastering : nil))
            #expect(light == (expectsHDR ? expectedContentLight : nil))
            if retained == nil {
                retained = RetainedFrame(
                    frame: frame,
                    masteringBytes: frame.masteringDisplayMetadata.map { Array($0) },
                    contentLightBytes: frame.contentLightMetadata.map { Array($0) }
                )
            }
        }

        // Keep only the first frame while later AVFrames/pool buffers are
        // reused, so the test cannot fill the bounded software output pool.
        for _ in 0..<1_000 where count < 12 {
            guard let packet = try demuxer.readPacket(generation: 1) else { break }
            guard packet.streamIndex == stream.index else { continue }
            try decoder.decode(packet, while: { true }, emit: accept)
        }
        if count < 12 { try decoder.drain(generation: 1, while: { true }, emit: accept) }
        try #require(count >= 12, "The fixture must exercise multiple decoded frames")
        decoder.flush()
        // The caller rechecks the first frame after this decoder is released.
        return try #require(retained)
    }

    private func attachment(_ key: CFString, from frame: NativeDecodedVideoFrame) -> Data? {
        var mode = CVAttachmentMode.shouldNotPropagate
        guard let value = CVBufferCopyAttachment(frame.pixelBuffer, key, &mode) else { return nil }
        #expect(mode == .shouldPropagate)
        let data = value as? Data
        #expect(data != nil, "HDR attachments must contain byte payloads")
        return data
    }
}
