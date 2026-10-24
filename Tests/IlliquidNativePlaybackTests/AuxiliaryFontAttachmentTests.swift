import CFFmpeg
import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import IlliquidNativePlayback

private enum AuxiliaryFontFixtures {
    static let names = [
        "none", "fonts-2mib", "fonts-16mib", "fonts-64mib", "unsupported-only", "mixed",
    ]
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_FONT_FIXTURES"] != nil
    }
}

/// The dedicated workflow requires the generated fixtures. Ordinary test runs
/// explicitly skip this suite; an invalid configured directory is a failure.
@Suite("Auxiliary readers omit unused font payloads", .serialized,
       .enabled(if: AuxiliaryFontFixtures.enabled,
                "Generate Benchmarks/AuxiliaryFontAttachments fixtures"))
struct AuxiliaryFontAttachmentTests {
    private struct Attachment: Decodable {
        let filename: String
        let mime_type: String
        let size_bytes: Int
        let sha256: String
        let accepted: Bool
    }

    private struct Fixture: Decodable {
        let name: String
        let filename: String
        let accepted_payload_bytes: Int
        let font_count: Int
        let rejected_payload_bytes: Int
        let size_bytes: Int
        let attachments: [Attachment]
    }

    private struct SideData: Equatable {
        let kind: Int32
        let bytes: Data
    }

    private struct Packet: Equatable {
        let stream: Int32
        let pts: Int64
        let dts: Int64
        let duration: Int64
        let timeBase: FFmpegRational
        let generation: Int
        let flags: Int32
        let bytes: Data?
        let sideData: [SideData]

        init(_ packet: FFmpegPacket) throws {
            let pointer = try #require(packet.pointer)
            stream = packet.streamIndex
            pts = packet.presentationTimestamp
            dts = packet.decodeTimestamp
            duration = packet.duration
            timeBase = packet.timeBase
            generation = packet.generation
            flags = pointer.pointee.flags
            bytes = packet.data
            var copied: [SideData] = []
            for index in 0..<Int(pointer.pointee.side_data_elems) {
                let value = try #require(pointer.pointee.side_data)[index]
                let bytes: Data
                if value.size == 0 {
                    bytes = Data()
                } else {
                    bytes = Data(bytes: try #require(value.data), count: Int(value.size))
                }
                copied.append(SideData(kind: Int32(value.type.rawValue),
                                       bytes: bytes))
            }
            sideData = copied
        }
    }

    private struct CodecConfiguration: Equatable {
        let codec: Int32
        let kind: Int32
        let width: Int32
        let height: Int32
        let sampleRate: Int32
        let channels: Int32
        let extra: Data?

        init(_ pointer: UnsafePointer<AVCodecParameters>) {
            let value = pointer.pointee
            codec = Int32(value.codec_id.rawValue)
            kind = Int32(value.codec_type.rawValue)
            width = value.width
            height = value.height
            sampleRate = value.sample_rate
            channels = value.ch_layout.nb_channels
            extra = value.extradata.flatMap {
                value.extradata_size > 0 ? Data(bytes: $0, count: Int(value.extradata_size)) : nil
            }
        }
    }

    private func fixture(_ name: String) throws -> (url: URL, record: Fixture) {
        let path = try #require(ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_FONT_FIXTURES"])
        try #require(!path.isEmpty, "The configured fixture directory must not be empty")
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let records = try JSONDecoder().decode(
            [Fixture].self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        try #require(records.count == AuxiliaryFontFixtures.names.count)
        try #require(Set(records.map(\.name)) == Set(AuxiliaryFontFixtures.names))
        let record = try #require(records.first { $0.name == name })
        try #require(record.filename == name + ".mkv")
        let url = directory.appendingPathComponent(record.filename)
        try #require(FileManager.default.fileExists(atPath: url.path), "Missing required fixture: \(record.filename)")
        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        try #require(size == record.size_bytes && size > 0)
        #expect(record.font_count == record.attachments.filter(\.accepted).count)
        #expect(record.accepted_payload_bytes == record.attachments.filter(\.accepted).reduce(0) { $0 + $1.size_bytes })
        #expect(record.rejected_payload_bytes == record.attachments.filter { !$0.accepted }.reduce(0) { $0 + $1.size_bytes })
        return (url, record)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func assertFonts(_ actual: [FontAttachment], match fixture: Fixture) {
        let expected = fixture.attachments.filter(\.accepted)
        #expect(actual.count == fixture.font_count)
        #expect(actual.reduce(0) { $0 + $1.data.count } == fixture.accepted_payload_bytes)
        for (actual, expected) in zip(actual, expected) {
            #expect(actual.filename == expected.filename)
            #expect(actual.mimeType == expected.mime_type)
            #expect(actual.isSupportedFont)
            #expect(actual.data.count == expected.size_bytes)
            #expect(digest(actual.data) == expected.sha256)
        }
    }

    private func assertMetadata(_ actual: FFmpegMediaInfo, matches expected: FFmpegMediaInfo) {
        #expect(actual.url == expected.url)
        #expect(actual.containerName == expected.containerName)
        #expect(actual.duration.bitPattern == expected.duration.bitPattern)
        #expect(actual.startTime.bitPattern == expected.startTime.bitPattern)
        #expect(actual.durationStatus == expected.durationStatus)
        #expect(actual.startTimeStatus == expected.startTimeStatus)
        // FFmpegStreamInfo's synthesized equality includes every stored field.
        #expect(actual.streams == expected.streams)
        #expect(actual.selectedVideoIndex == expected.selectedVideoIndex)
        #expect(actual.selectedAudioIndex == expected.selectedAudioIndex)
        #expect(actual.selectedSubtitleIndex == expected.selectedSubtitleIndex)
        #expect(actual.chapters.count == expected.chapters.count)
        for (actual, expected) in zip(actual.chapters, expected.chapters) {
            #expect(actual.title == expected.title)
            #expect(actual.start.bitPattern == expected.start.bitPattern)
            #expect(actual.end.bitPattern == expected.end.bitPattern)
        }
    }

    private func packets(_ read: () throws -> FFmpegPacket?) throws -> [Packet] {
        var result: [Packet] = []
        // The fixture has 48 video frames, a short FLAC track and two ASS cues.
        // A bound makes an unexpected nonterminating demux path fail promptly.
        for _ in 0..<512 {
            guard let packet = try read() else {
                try #require(!result.isEmpty, "The generated fixture must yield packets")
                return result
            }
            result.append(try Packet(packet))
        }
        throw PresentationError("Auxiliary attachment fixture exceeded the packet test bound")
    }

    @Test(arguments: AuxiliaryFontFixtures.names)
    func defaultAndExplicitInclusionKeepOwnedFontBytes(name: String) throws {
        let fixture = try fixture(name)
        weak var lifetime: FFmpegDemuxer?
        let info = try {
            let input = try FFmpegDemuxer(url: fixture.url)
            lifetime = input
            return input.mediaInfo
        }()
        #expect(lifetime == nil)
        // The FFmpeg context has closed; default payloads must still own their
        // complete bytes. Hashing avoids allocating another expected payload.
        assertFonts(info.attachments, match: fixture.record)
        let explicit = try FFmpegDemuxer(url: fixture.url, includeFontAttachments: true)
        assertMetadata(explicit.mediaInfo, matches: info)
        assertFonts(explicit.mediaInfo.attachments, match: fixture.record)
        #expect(explicit.mediaInfo.attachments == info.attachments)
    }

    @Test(arguments: AuxiliaryFontFixtures.names)
    func omissionPreservesMetadataPacketsSeeksAndCodecPrivateData(name: String) throws {
        let fixture = try fixture(name)
        let reference = try FFmpegDemuxer(url: fixture.url)
        let auxiliary = try FFmpegDemuxer(url: fixture.url, includeFontAttachments: false)
        assertMetadata(auxiliary.mediaInfo, matches: reference.mediaInfo)
        #expect(auxiliary.mediaInfo.attachments.isEmpty)
        #expect(reference.mediaInfo.attachments.count == fixture.record.font_count)
        #expect(auxiliary.mediaInfo.streams.filter { $0.kind == .attachment }.count == fixture.record.attachments.count)
        #expect(auxiliary.mediaInfo.videoStreams.count == 1)
        #expect(auxiliary.mediaInfo.audioStreams.count == 1)
        #expect(auxiliary.mediaInfo.subtitleStreams.count == 1)
        #expect(auxiliary.mediaInfo.chapters.count == 2)
        for stream in reference.mediaInfo.streams where stream.kind != .attachment {
            #expect(auxiliary.codecPrivateData(streamIndex: stream.index)
                == reference.codecPrivateData(streamIndex: stream.index))
            let expected = CodecConfiguration(try #require(reference.codecParameters(streamIndex: stream.index)))
            let actual = CodecConfiguration(try #require(auxiliary.codecParameters(streamIndex: stream.index)))
            #expect(actual == expected)
        }
        let subtitle = try #require(auxiliary.mediaInfo.selectedSubtitleIndex)
        #expect(auxiliary.codecPrivateData(streamIndex: subtitle)?.isEmpty == false)
        let initialReference = try packets { try reference.readPacket(generation: 1) }
        let initialAuxiliary = try packets { try auxiliary.readPacket(generation: 1) }
        #expect(initialAuxiliary == initialReference)
        for target in [0.75, 0.0, 1.5] {
            try reference.seek(to: target + reference.mediaInfo.startTime, exact: true)
            try auxiliary.seek(to: target + auxiliary.mediaInfo.startTime, exact: true)
            let expected = try packets { try reference.readPacket(generation: 2) }
            let actual = try packets { try auxiliary.readPacket(generation: 2) }
            #expect(actual == expected)
        }
        let expectedActive = try reference.activeSubtitlePackets(streamIndex: subtitle, at: 0.75, generation: 3)
        let actualActive = try auxiliary.activeSubtitlePackets(streamIndex: subtitle, at: 0.75, generation: 3)
        #expect(!expectedActive.isEmpty)
        #expect(try actualActive.map(Packet.init) == expectedActive.map(Packet.init))
    }

    @Test(arguments: AuxiliaryFontFixtures.names)
    func executorForwardsOmissionAndKeepsSubtitleAndAudioOperations(name: String) throws {
        let fixture = try fixture(name)
        let reference = try FFmpegInputExecutor(url: fixture.url)
        let auxiliary = try FFmpegInputExecutor(url: fixture.url, includeFontAttachments: false)
        assertMetadata(auxiliary.mediaInfo, matches: reference.mediaInfo)
        #expect(reference.mediaInfo.attachments.count == fixture.record.font_count)
        #expect(auxiliary.mediaInfo.attachments.isEmpty)
        for stream in reference.mediaInfo.streams where stream.kind != .attachment {
            #expect(auxiliary.codecPrivateData(streamIndex: stream.index)
                == reference.codecPrivateData(streamIndex: stream.index))
            let expected = try #require(try reference.copyCodecParameters(streamIndex: stream.index))
            let actual = try #require(try auxiliary.copyCodecParameters(streamIndex: stream.index))
            #expect(actual.withUnsafePointer(CodecConfiguration.init)
                == expected.withUnsafePointer(CodecConfiguration.init))
        }
        let initialReference = try packets { try reference.readPacket(generation: 1) }
        let initialAuxiliary = try packets { try auxiliary.readPacket(generation: 1) }
        #expect(initialAuxiliary == initialReference)
        try reference.seek(to: 0.75 + reference.mediaInfo.startTime, exact: false)
        try auxiliary.seek(to: 0.75 + auxiliary.mediaInfo.startTime, exact: false)
        let expected = try packets { try reference.readPacket(generation: 2) }
        let actual = try packets { try auxiliary.readPacket(generation: 2) }
        #expect(actual == expected)
        let subtitle = try #require(auxiliary.mediaInfo.selectedSubtitleIndex)
        #expect(auxiliary.codecPrivateData(streamIndex: subtitle)?.isEmpty == false)
        let expectedActive = try reference.activeSubtitlePackets(streamIndex: subtitle, at: 0.75, generation: 3)
        let actualActive = try auxiliary.activeSubtitlePackets(streamIndex: subtitle, at: 0.75, generation: 3)
        #expect(!expectedActive.isEmpty)
        #expect(try actualActive.map(Packet.init) == expectedActive.map(Packet.init))
    }

    @Test
    func metadataReaderAndFrameStepReaderIgnoreUnneededFonts() async throws {
        let plain = try fixture("none").url
        let attached = try fixture("fonts-2mib").url
        let metadata = NativeThumbnailMetadataReader()
        let expectedDuration = try #require(await metadata.duration(of: plain))
        let actualDuration = try #require(await metadata.duration(of: attached))
        #expect(actualDuration.bitPattern == expectedDuration.bitPattern)
        let reader = NativeFrameStepReader()
        for position in [0.0, 0.5, 1.95] {
            for direction in [-1, 1] {
                let expected = try await reader.target(url: plain, position: position, direction: direction)
                let actual = try await reader.target(url: attached, position: position, direction: direction)
                #expect(actual == expected)
                if position == 0.5 { #expect(actual != nil) }
            }
        }
    }

    @Test
    func thumbnailPixelsMatchTheSameStreamsWithoutAttachments() async throws {
        let plain = try fixture("none").url
        let attached = try fixture("fonts-2mib").url
        await NativeTimelineThumbnailGenerator.prepareImageRendererForQualification()
        for target in [0.0, 0.5, 1.5] {
            let expected = try await thumbnail(plain, at: target)
            let actual = try await thumbnail(attached, at: target)
            #expect(actual.width == expected.width)
            #expect(actual.height == expected.height)
            let expectedBytes = try #require(expected.dataProvider?.data)
            let actualBytes = try #require(actual.dataProvider?.data)
            #expect(actualBytes == expectedBytes)
        }
    }

    private func thumbnail(_ url: URL, at seconds: Double) async throws -> CGImage {
        let generator = NativeTimelineThumbnailGenerator()
        let image = await generator.thumbnail(for: url, at: seconds,
                                              maximumPixelSize: CGSize(width: 160, height: 90))
        await generator.releaseIdleResources()
        return try #require(image)
    }
}
