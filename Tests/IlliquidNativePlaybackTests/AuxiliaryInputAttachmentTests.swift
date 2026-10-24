import CFFmpeg
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Auxiliary input attachment ownership", .serialized)
struct AuxiliaryInputAttachmentTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE"] != nil,
                   "Generate the mixed Matroska attachment fixture"))
    func defaultInputKeepsIndependentFontBytesAfterClosing() throws {
        let url = try fixtureURL()
        let info = try {
            let primary = try FFmpegDemuxer(url: url)
            return primary.mediaInfo
        }()

        #expect(info.audioStreams.count == 1)
        #expect(info.streams.filter { $0.kind == .attachment }.count == 3)
        #expect(info.attachments == [
            FontAttachment(filename: "embedded.TTF", mimeType: "application/x-truetype-font",
                           data: Data([0x00, 0x01, 0x02, 0xFE, 0xFF])),
            FontAttachment(filename: "glyphs.bin", mimeType: "font/otf",
                           data: Data([0x46, 0x4F, 0x4E, 0x54, 0x00, 0x80])),
        ])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE"] != nil,
                   "Generate the mixed Matroska attachment fixture"))
    func omittedFontsPreserveMetadataAndNativeCodecPrivateBytes() throws {
        let url = try fixtureURL()
        let primary = try FFmpegDemuxer(url: url)
        let auxiliary = try FFmpegDemuxer(url: url, fontAttachmentLoading: .omit)

        #expect(primary.mediaInfo.attachments.count == 2)
        #expect(auxiliary.mediaInfo.attachments.isEmpty)
        expectSameMetadata(primary.mediaInfo, auxiliary.mediaInfo)
        let audioIndex = try #require(primary.mediaInfo.selectedAudioIndex)
        #expect(primary.codecPrivateData(streamIndex: audioIndex)?.isEmpty == false)
        // Omission controls Swift-owned font copies. Native codec parameters,
        // including attachment extradata, must remain intact and accessible.
        for stream in primary.mediaInfo.streams {
            let expected = primary.codecPrivateData(streamIndex: stream.index)
            #expect(auxiliary.codecPrivateData(streamIndex: stream.index) == expected)
            let primaryParameters = try #require(primary.codecParameters(streamIndex: stream.index))
            let auxiliaryParameters = try #require(auxiliary.codecParameters(streamIndex: stream.index))
            #expect(CodecSnapshot(primaryParameters) == CodecSnapshot(auxiliaryParameters))
        }
        #expect(auxiliary.codecPrivateData(streamIndex: -1) == nil)
        #expect(auxiliary.codecParameters(streamIndex: Int32.max) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE"] != nil,
                   "Generate the mixed Matroska attachment fixture"))
    func omittedFontsPreserveCompletePacketStreamsAndSeeking() throws {
        let url = try fixtureURL()
        let primary = try FFmpegDemuxer(url: url)
        let auxiliary = try FFmpegDemuxer(url: url, fontAttachmentLoading: .omit)

        let original = try packets { try primary.readPacket(generation: 7) }
        #expect(try packets { try auxiliary.readPacket(generation: 7) } == original)
        #expect(original.allSatisfy { $0.streamIndex == primary.mediaInfo.selectedAudioIndex })

        for (target, exact, generation) in [(0.0, false, 8), (0.125, true, 9), (0.0, true, 10)] {
            try primary.seek(to: target, exact: exact)
            try auxiliary.seek(to: target, exact: exact)
            let expected = try packets { try primary.readPacket(generation: generation) }
            let actual = try packets { try auxiliary.readPacket(generation: generation) }
            #expect(actual == expected)
            #expect(actual.allSatisfy { $0.generation == generation })
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE"] != nil,
                   "Generate the mixed Matroska attachment fixture"))
    func executorForwardsOmissionWithoutChangingMetadataOrInputOperations() throws {
        let url = try fixtureURL()
        let primary = try FFmpegInputExecutor(url: url)
        let auxiliary = try FFmpegInputExecutor(url: url, fontAttachmentLoading: .omit)

        #expect(primary.mediaInfo.attachments.map(\.data) == [
            Data([0x00, 0x01, 0x02, 0xFE, 0xFF]),
            Data([0x46, 0x4F, 0x4E, 0x54, 0x00, 0x80]),
        ])
        #expect(auxiliary.mediaInfo.attachments.isEmpty)
        expectSameMetadata(primary.mediaInfo, auxiliary.mediaInfo)
        for stream in primary.mediaInfo.streams {
            #expect(auxiliary.codecPrivateData(streamIndex: stream.index)
                    == primary.codecPrivateData(streamIndex: stream.index))
        }
        let expected = try packets { try primary.readPacket(generation: 11) }
        #expect(try packets { try auxiliary.readPacket(generation: 11) } == expected)

        try primary.seek(to: 0, exact: true)
        try auxiliary.seek(to: 0, exact: true)
        let expectedAfterSeek = try packets { try primary.readPacket(generation: 12) }
        #expect(try packets { try auxiliary.readPacket(generation: 12) } == expectedAfterSeek)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE"] != nil,
                   "Generate the mixed Matroska attachment fixture"))
    func omittedInputStillCopiesOwnedCodecParametersThatOutliveIt() throws {
        let url = try fixtureURL()
        let retained: [(OwnedCodecParameters, CodecSnapshot)] = try {
            let primary = try FFmpegInputExecutor(url: url)
            let auxiliary = try FFmpegInputExecutor(url: url, fontAttachmentLoading: .omit)
            #expect(auxiliary.mediaInfo.attachments.isEmpty)
            return try primary.mediaInfo.streams.map { stream in
                let expectedCopy = try #require(try primary.copyCodecParameters(streamIndex: stream.index))
                let expected = try #require(expectedCopy.withUnsafePointer { CodecSnapshot($0) })
                let copy = try #require(try auxiliary.copyCodecParameters(streamIndex: stream.index))
                return (copy, expected)
            }
        }()

        #expect(retained.count == 4)
        // Both executors and their AVFormatContexts have closed. Decoder-owned
        // configurations must continue to own every byte of codec-private data.
        for (copy, expected) in retained {
            let actual = try #require(copy.withUnsafePointer { CodecSnapshot($0) })
            #expect(actual == expected)
        }
    }

    private func fixtureURL() throws -> URL {
        let path = try #require(ProcessInfo.processInfo.environment["ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE"])
        try #require(FileManager.default.fileExists(atPath: path))
        return URL(fileURLWithPath: path)
    }

    private func expectSameMetadata(_ primary: FFmpegMediaInfo, _ auxiliary: FFmpegMediaInfo) {
        #expect(auxiliary.url == primary.url)
        #expect(auxiliary.containerName == primary.containerName)
        #expect(auxiliary.duration == primary.duration)
        #expect(auxiliary.startTime == primary.startTime)
        #expect(auxiliary.durationStatus == primary.durationStatus)
        #expect(auxiliary.startTimeStatus == primary.startTimeStatus)
        #expect(auxiliary.streams == primary.streams)
        #expect(auxiliary.chapters.map(\.title) == primary.chapters.map(\.title))
        #expect(auxiliary.chapters.map(\.start) == primary.chapters.map(\.start))
        #expect(auxiliary.chapters.map(\.end) == primary.chapters.map(\.end))
        #expect(auxiliary.selectedVideoIndex == primary.selectedVideoIndex)
        #expect(auxiliary.selectedAudioIndex == primary.selectedAudioIndex)
        #expect(auxiliary.selectedSubtitleIndex == primary.selectedSubtitleIndex)
    }

    private func packets(_ read: () throws -> FFmpegPacket?) throws -> [PacketSnapshot] {
        var result: [PacketSnapshot] = []
        for _ in 0..<64 {
            guard let packet = try read() else {
                #expect(!result.isEmpty, "The short audio fixture must produce packets before EOF")
                return result
            }
            result.append(PacketSnapshot(packet))
        }
        Issue.record("The 0.25-second fixture did not reach EOF within 64 packets")
        return result
    }

    private struct PacketSnapshot: Equatable {
        let streamIndex: Int32
        let presentationTimestamp: Int64
        let decodeTimestamp: Int64
        let duration: Int64
        let timeBase: FFmpegRational
        let generation: Int
        let isCorrupt: Bool
        let isKeyframe: Bool
        let data: Data?

        init(_ packet: FFmpegPacket) {
            streamIndex = packet.streamIndex
            presentationTimestamp = packet.presentationTimestamp
            decodeTimestamp = packet.decodeTimestamp
            duration = packet.duration
            timeBase = packet.timeBase
            generation = packet.generation
            isCorrupt = packet.isCorrupt
            isKeyframe = packet.isKeyframe
            data = packet.data
        }
    }

    private struct CodecSnapshot: Equatable {
        let codecType: Int32
        let codecID: Int32
        let codecTag: UInt32
        let format: Int32
        let sampleRate: Int32
        let channelCount: Int32
        let bitRate: Int64
        let width: Int32
        let height: Int32
        let extraData: Data?

        init(_ parameters: UnsafePointer<AVCodecParameters>) {
            let value = parameters.pointee
            codecType = Int32(value.codec_type.rawValue)
            codecID = Int32(value.codec_id.rawValue)
            codecTag = value.codec_tag
            format = value.format
            sampleRate = value.sample_rate
            channelCount = value.ch_layout.nb_channels
            bitRate = value.bit_rate
            width = value.width
            height = value.height
            extraData = value.extradata.flatMap { pointer in
                value.extradata_size > 0 ? Data(bytes: pointer, count: Int(value.extradata_size)) : nil
            }
        }
    }
}
