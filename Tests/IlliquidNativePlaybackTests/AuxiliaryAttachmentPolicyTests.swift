import CFFmpeg
import CoreMedia
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Auxiliary attachment payload policy", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE"] != nil,
                "Generate the mixed Matroska attachment fixture"))
struct AuxiliaryAttachmentPolicyTests {
    @Test func defaultAndExplicitCopyPoliciesPreserveOwnedFontPayloads() throws {
        let url = try fixtureURL()
        weak var releasedDefaultReader: FFmpegDemuxer?
        let defaultInfo = try {
            let reader = try FFmpegDemuxer(url: url)
            releasedDefaultReader = reader
            return reader.mediaInfo
        }()
        weak var releasedExplicitReader: FFmpegDemuxer?
        let explicitInfo = try {
            let reader = try FFmpegDemuxer(url: url, attachmentPayloadPolicy: .copyFonts)
            releasedExplicitReader = reader
            return reader.mediaInfo
        }()

        #expect(releasedDefaultReader == nil)
        #expect(releasedExplicitReader == nil)
        expectMetadataEqual(defaultInfo, explicitInfo)
        expectFixtureFonts(defaultInfo.attachments)
        #expect(explicitInfo.attachments == defaultInfo.attachments)
    }

    @Test func omittedPayloadsPreserveStreamInventoryAndCodecPrivateData() throws {
        let url = try fixtureURL()
        let primary = try FFmpegDemuxer(url: url)
        let auxiliary = try FFmpegDemuxer(url: url, attachmentPayloadPolicy: .omit)

        expectMetadataEqual(primary.mediaInfo, auxiliary.mediaInfo)
        expectFixtureFonts(primary.mediaInfo.attachments)
        #expect(auxiliary.mediaInfo.attachments.isEmpty)
        #expect(auxiliary.mediaInfo.audioStreams.count == 1)
        #expect(auxiliary.mediaInfo.streams.filter { $0.kind == .attachment }.count == 3)

        // Omitting the owned media-info copies must not discard the native
        // stream configuration, including the font-labeled attachment streams.
        for stream in primary.mediaInfo.streams {
            let expected = primary.codecPrivateData(streamIndex: stream.index)
            let actual = auxiliary.codecPrivateData(streamIndex: stream.index)
            #expect(actual == expected)
            #expect(auxiliary.codecParameters(streamIndex: stream.index) != nil)
            if stream.kind == .audio || stream.kind == .attachment {
                let payload = try #require(actual)
                #expect(!payload.isEmpty)
            }
        }
        #expect(auxiliary.codecPrivateData(streamIndex: -1) == nil)
        #expect(auxiliary.codecPrivateData(streamIndex: Int32.max) == nil)
    }

    @Test func omittedPayloadsPreservePacketsAndSeekResults() throws {
        let url = try fixtureURL()
        let primary = try FFmpegDemuxer(url: url)
        let auxiliary = try FFmpegDemuxer(url: url, attachmentPayloadPolicy: .omit)

        let initialPrimary = try packetReceipts { try primary.readPacket(generation: 1) }
        let initialAuxiliary = try packetReceipts { try auxiliary.readPacket(generation: 1) }
        #expect(!initialPrimary.isEmpty)
        #expect(initialAuxiliary == initialPrimary)
        #expect(initialAuxiliary.allSatisfy {
            $0.streamIndex == auxiliary.mediaInfo.selectedAudioIndex && !$0.data.isEmpty
        })

        for (index, target) in [0.0, 0.12, 0.0].enumerated() {
            let generation = index + 2
            let exact = index != 1
            try primary.seek(to: target, exact: exact)
            try auxiliary.seek(to: target, exact: exact)
            let expected = try packetReceipts { try primary.readPacket(generation: generation) }
            let actual = try packetReceipts { try auxiliary.readPacket(generation: generation) }
            #expect(!expected.isEmpty)
            #expect(actual == expected)
            #expect(actual.allSatisfy { $0.generation == generation })
        }
    }

    @Test func executorForwardsPolicyAndPreservesCodecOwnershipAndPacketReads() throws {
        let url = try fixtureURL()
        let primary = try FFmpegInputExecutor(url: url)
        var auxiliary: FFmpegInputExecutor? = try FFmpegInputExecutor(
            url: url,
            attachmentPayloadPolicy: .omit
        )
        weak var releasedAuxiliary = auxiliary
        var retainedParameters: [(OwnedCodecParameters, Data?)] = []

        try {
            let reader = try #require(auxiliary)
            #expect(!primary.openWasPerformedOnMainThread)
            #expect(!reader.openWasPerformedOnMainThread)
            expectMetadataEqual(primary.mediaInfo, reader.mediaInfo)
            expectFixtureFonts(primary.mediaInfo.attachments)
            #expect(reader.mediaInfo.attachments.isEmpty)

            for stream in primary.mediaInfo.streams {
                let expected = primary.codecPrivateData(streamIndex: stream.index)
                #expect(reader.codecPrivateData(streamIndex: stream.index) == expected)
                let copied = try reader.copyCodecParameters(streamIndex: stream.index)
                let owned = try #require(copied)
                let codecID = owned.withUnsafePointer { Int32($0.pointee.codec_id.rawValue) }
                #expect(codecID == stream.codecID)
                retainedParameters.append((owned, expected))
            }

            let expectedInitial = try packetReceipts { try primary.readPacket(generation: 4) }
            let actualInitial = try packetReceipts { try reader.readPacket(generation: 4) }
            #expect(!expectedInitial.isEmpty)
            #expect(actualInitial == expectedInitial)
            try primary.seek(to: 0, exact: true)
            try reader.seek(to: 0, exact: true)
            let expectedAfterSeek = try packetReceipts { try primary.readPacket(generation: 5) }
            let actualAfterSeek = try packetReceipts { try reader.readPacket(generation: 5) }
            #expect(!expectedAfterSeek.isEmpty)
            #expect(actualAfterSeek == expectedAfterSeek)
        }()

        auxiliary = nil
        #expect(releasedAuxiliary == nil)
        // Explicit codec-parameter copies remain valid after the auxiliary
        // executor has closed its AVFormatContext.
        for (owned, expected) in retainedParameters {
            let bytes = owned.withUnsafePointer { parameters -> Data? in
                guard let data = parameters.pointee.extradata,
                      parameters.pointee.extradata_size > 0 else { return nil }
                return Data(bytes: data, count: Int(parameters.pointee.extradata_size))
            }
            let retainedBytes = try #require(bytes)
            #expect(retainedBytes == expected)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_REAL_FONT_FIXTURE"] != nil,
                   "Generate the real-font Matroska fixture"))
    @MainActor
    func primaryFontsReachBothSubtitlePipelinesAfterAuxiliaryInputsClose() throws {
        let path = try #require(ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_REAL_FONT_FIXTURE"])
        try #require(FileManager.default.fileExists(atPath: path))
        let url = URL(fileURLWithPath: path)
        weak var releasedPrimary: FFmpegInputExecutor?
        weak var releasedAuxiliary: FFmpegInputExecutor?
        var prepared = try { () -> (
            fonts: [FontAttachment],
            codecPrivate: Data,
            codecName: String,
            events: [NativeDecodedSubtitleEvent]
        ) in
            let primary = try FFmpegInputExecutor(url: url)
            let auxiliary = try FFmpegInputExecutor(url: url, attachmentPayloadPolicy: .omit)
            releasedPrimary = primary
            releasedAuxiliary = auxiliary
            expectMetadataEqual(primary.mediaInfo, auxiliary.mediaInfo)
            #expect(auxiliary.mediaInfo.attachments.isEmpty)
            #expect(primary.mediaInfo.attachments.map(\.filename) == ["NotoSans-Regular.ttf"])
            let stream = try #require(auxiliary.mediaInfo.subtitleStreams.first)
            let codecPrivate = try #require(auxiliary.codecPrivateData(streamIndex: stream.index))
            #expect(!codecPrivate.isEmpty)
            #expect(codecPrivate == primary.codecPrivateData(streamIndex: stream.index))
            let copied = try auxiliary.copyCodecParameters(streamIndex: stream.index)
            let owned = try #require(copied)
            let createdDecoder = try owned.withUnsafePointer {
                try SubtitleDecoder(parameters: $0, stream: stream)
            }
            let decoder = try #require(createdDecoder)
            var events: [NativeDecodedSubtitleEvent] = []
            var packetCount = 0
            while let packet = try auxiliary.readPacket(generation: 1) {
                try #require(packetCount < 1_024)
                packetCount += 1
                if packet.streamIndex == stream.index {
                    events.append(contentsOf: try decoder.decode(packet))
                }
            }
            #expect(!events.isEmpty)
            #expect(events.allSatisfy { !$0.assData.isEmpty })
            return (primary.mediaInfo.attachments, codecPrivate, stream.codecName, events)
        }()

        #expect(releasedPrimary == nil)
        #expect(releasedAuxiliary == nil)
        // The generated fixture embeds the repository's actual licensed font,
        // rather than the deliberately invalid admission-only payloads.
        let fontURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TestFixtures/Fonts/NotoSans-Regular.ttf")
        let expectedFont = try Data(contentsOf: fontURL)
        #expect(prepared.fonts.map(\.data) == [expectedFont])

        let main = try SubtitlePipeline(
            overlay: SubtitleOverlayView(headless: true),
            presentsOverlay: false,
            memoryOwner: .mainLibass
        )
        let pictureInPicture = try SubtitlePipeline(
            overlay: SubtitleOverlayView(headless: true),
            presentsOverlay: false,
            memoryOwner: .pictureInPictureLibass
        )
        defer {
            main.terminate()
            pictureInPicture.terminate()
        }
        let size = CGSize(width: 640, height: 360)
        for pipeline in [main, pictureInPicture] {
            let registered = try pipeline.configure(
                codecPrivate: prepared.codecPrivate,
                codecName: prepared.codecName,
                attachments: prepared.fonts,
                frameSize: size,
                storageSize: size
            )
            #expect(registered == ["NotoSans-Regular.ttf"])
            for event in prepared.events {
                #expect(pipeline.process(event: event))
            }
            #expect(pipeline.eventCount == prepared.events.count)
        }
        prepared.fonts.removeAll()

        // Both independently owned libass contexts can still render the
        // decoded cue after the native inputs and Swift attachment copies die.
        let time = CMTime(seconds: 0.1, preferredTimescale: 1_000)
        let viewport = CGRect(origin: .zero, size: size)
        let mainRegions = main.renderedRegions(at: time, viewport: viewport, videoSize: size)
        let pipRegions = pictureInPicture.pictureInPictureSubtitleSnapshot(
            at: time, viewport: viewport, videoSize: size
        ).regions
        #expect(!mainRegions.isEmpty)
        #expect(mainRegions.contains { $0.bitmap.contains { $0 != 0 } })
        #expect(pipRegions.map(\.bitmap) == mainRegions.map(\.bitmap))
        #expect(pipRegions.map(\.frame) == mainRegions.map(\.frame))
        #expect(pipRegions.map(\.color) == mainRegions.map(\.color))
        #expect(pipRegions.map(\.stride) == mainRegions.map(\.stride))
    }

    private func fixtureURL() throws -> URL {
        let path = try #require(ProcessInfo.processInfo.environment["ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE"])
        try #require(FileManager.default.fileExists(atPath: path))
        return URL(fileURLWithPath: path)
    }

    private func expectFixtureFonts(_ fonts: [FontAttachment]) {
        #expect(fonts.map(\.filename) == ["embedded.TTF", "glyphs.bin"])
        #expect(fonts.map(\.mimeType) == ["application/x-truetype-font", "font/otf"])
        #expect(fonts.map(\.data) == [
            Data([0x00, 0x01, 0x02, 0xFE, 0xFF]),
            Data([0x46, 0x4F, 0x4E, 0x54, 0x00, 0x80]),
        ])
    }

    private func expectMetadataEqual(_ expected: FFmpegMediaInfo, _ actual: FFmpegMediaInfo) {
        #expect(actual.url == expected.url)
        #expect(actual.containerName == expected.containerName)
        #expect(actual.duration.bitPattern == expected.duration.bitPattern)
        #expect(actual.startTime.bitPattern == expected.startTime.bitPattern)
        #expect(actual.durationStatus == expected.durationStatus)
        #expect(actual.startTimeStatus == expected.startTimeStatus)
        #expect(actual.streams == expected.streams)
        #expect(actual.selectedVideoIndex == expected.selectedVideoIndex)
        #expect(actual.selectedAudioIndex == expected.selectedAudioIndex)
        #expect(actual.selectedSubtitleIndex == expected.selectedSubtitleIndex)
        #expect(actual.chapters.map { $0.title } == expected.chapters.map { $0.title })
        #expect(actual.chapters.map { $0.start.bitPattern } == expected.chapters.map { $0.start.bitPattern })
        #expect(actual.chapters.map { $0.end.bitPattern } == expected.chapters.map { $0.end.bitPattern })
    }

    private func packetReceipts(
        read: () throws -> FFmpegPacket?
    ) throws -> [PacketReceipt] {
        var receipts: [PacketReceipt] = []
        // The required fixture has 0.25 seconds of FLAC. Fail a runaway read
        // rather than letting a broken EOF contract hang the native suite.
        while let packet = try read() {
            try #require(receipts.count < 1_024)
            receipts.append(try PacketReceipt(packet))
        }
        return receipts
    }

    private struct PacketReceipt: Equatable {
        let streamIndex: Int32
        let presentationTimestamp: Int64
        let decodeTimestamp: Int64
        let duration: Int64
        let timeBase: FFmpegRational
        let generation: Int
        let flags: Int32
        let position: Int64
        let data: Data
        let sideData: [SideDataReceipt]

        init(_ packet: FFmpegPacket) throws {
            let pointer = try #require(packet.pointer)
            streamIndex = packet.streamIndex
            presentationTimestamp = packet.presentationTimestamp
            decodeTimestamp = packet.decodeTimestamp
            duration = packet.duration
            timeBase = packet.timeBase
            generation = packet.generation
            flags = pointer.pointee.flags
            position = pointer.pointee.pos
            data = packet.data ?? Data()
            var entries: [SideDataReceipt] = []
            if pointer.pointee.side_data_elems > 0 {
                let sideData = try #require(pointer.pointee.side_data)
                for index in 0..<Int(pointer.pointee.side_data_elems) {
                    let entry = sideData[index]
                    entries.append(SideDataReceipt(
                        type: Int32(entry.type.rawValue),
                        data: entry.size > 0
                            ? Data(bytes: try #require(entry.data), count: entry.size)
                            : Data()
                    ))
                }
            }
            sideData = entries
        }
    }

    private struct SideDataReceipt: Equatable {
        let type: Int32
        let data: Data
    }
}
