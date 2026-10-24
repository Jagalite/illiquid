import CFFmpeg
import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Auxiliary reader font payload ownership", .serialized)
struct AuxiliaryFontPayloadTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE"] != nil,
                   "Generate the mixed Matroska attachment fixture"))
    func demuxerOmissionPreservesMetadataNativePayloadsAndPackets() throws {
        let url = try fixtureURL("ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE")
        let retainedInfo = try {
            let primary = try FFmpegDemuxer(url: url)
            let auxiliary = try FFmpegDemuxer(url: url, includesFontAttachments: false)
            expectSameMetadata(primary.mediaInfo, auxiliary.mediaInfo)
            #expect(auxiliary.mediaInfo.attachments.isEmpty)
            #expect(primary.mediaInfo.streams.filter { $0.kind == .attachment }.count == 3)

            for stream in primary.mediaInfo.streams {
                let expected = primary.codecPrivateData(streamIndex: stream.index)
                let actual = auxiliary.codecPrivateData(streamIndex: stream.index)
                #expect(actual == expected)
                if stream.kind == .attachment {
                    #expect(actual?.isEmpty == false)
                }
            }
            let primaryPackets = try readPackets { try primary.readPacket(generation: 7) }
            let auxiliaryPackets = try readPackets { try auxiliary.readPacket(generation: 7) }
            #expect(!primaryPackets.isEmpty)
            #expect(auxiliaryPackets == primaryPackets)

            try primary.seek(to: 0, exact: true)
            try auxiliary.seek(to: 0, exact: true)
            let primaryAfterSeek = try readPackets { try primary.readPacket(generation: 8) }
            let auxiliaryAfterSeek = try readPackets { try auxiliary.readPacket(generation: 8) }
            #expect(!primaryAfterSeek.isEmpty)
            #expect(auxiliaryAfterSeek == primaryAfterSeek)
            return (primary.mediaInfo, auxiliary.mediaInfo)
        }()

        // Both native contexts have closed. Default projection still owns the
        // exact supported bytes in source order; omitted projection owns none.
        expectMixedFonts(retainedInfo.0.attachments)
        #expect(retainedInfo.1.attachments.isEmpty)
        expectSameMetadata(retainedInfo.0, retainedInfo.1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE"] != nil,
                   "Generate the mixed Matroska attachment fixture"))
    func executorForwardsOmissionWithoutChangingCodecCopiesOrReads() throws {
        let url = try fixtureURL("ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE")
        let primary = try FFmpegInputExecutor(url: url)
        let auxiliary = try FFmpegInputExecutor(url: url, includesFontAttachments: false)
        expectMixedFonts(primary.mediaInfo.attachments)
        #expect(auxiliary.mediaInfo.attachments.isEmpty)
        expectSameMetadata(primary.mediaInfo, auxiliary.mediaInfo)

        for stream in primary.mediaInfo.streams {
            let expected = primary.codecPrivateData(streamIndex: stream.index)
            #expect(auxiliary.codecPrivateData(streamIndex: stream.index) == expected)
            let owned = try auxiliary.copyCodecParameters(streamIndex: stream.index)
            let parameters = try #require(owned)
            let copied = parameters.withUnsafePointer { source -> Data? in
                guard let data = source.pointee.extradata,
                      source.pointee.extradata_size > 0 else { return nil }
                return Data(bytes: data, count: Int(source.pointee.extradata_size))
            }
            let copiedBytes = try #require(copied)
            #expect(copiedBytes == expected)
        }
        let primaryPackets = try readPackets { try primary.readPacket(generation: 9) }
        let auxiliaryPackets = try readPackets { try auxiliary.readPacket(generation: 9) }
        #expect(!primaryPackets.isEmpty)
        #expect(auxiliaryPackets == primaryPackets)

        try primary.seek(to: 0, exact: false)
        try auxiliary.seek(to: 0, exact: false)
        let primaryAfterSeek = try readPackets { try primary.readPacket(generation: 10) }
        let auxiliaryAfterSeek = try readPackets { try auxiliary.readPacket(generation: 10) }
        #expect(!primaryAfterSeek.isEmpty)
        #expect(auxiliaryAfterSeek == primaryAfterSeek)
    }

    @Test(arguments: [true, false])
    func cancellationBeforeOpenIsPreserved(includesFontAttachments: Bool) {
        let cancellation = FFmpegInputCancellationSignal()
        cancellation.requestCancellation()
        #expect(throws: FFmpegInputExecutorError.operationCancelled) {
            _ = try FFmpegInputExecutor(
                url: URL(fileURLWithPath: "/unused-cancelled-font-input.mkv"),
                cancellationSignal: cancellation,
                includesFontAttachments: includesFontAttachments
            )
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_REAL_FONT_FIXTURE"] != nil,
                   "Generate the real attached-font subtitle fixture"))
    @MainActor
    func primaryFontsRemainOwnedAndRenderInMainAndPiPPipelines() throws {
        let url = try fixtureURL("ILLIQUID_AUXILIARY_REAL_FONT_FIXTURE")
        let fontURL = try fixtureURL("ILLIQUID_AUXILIARY_REAL_FONT_FILE")
        let expectedFont = try Data(contentsOf: fontURL)
        let primaryInfo = try {
            let primary = try FFmpegInputExecutor(url: url)
            return primary.mediaInfo
        }()
        // Registration happens after the primary native input has closed.
        #expect(primaryInfo.attachments.count == 1)
        #expect(primaryInfo.attachments.first?.filename == "NotoSans-Regular.ttf")
        #expect(primaryInfo.attachments.first?.data == expectedFont)

        let auxiliary = try FFmpegInputExecutor(url: url, includesFontAttachments: false)
        #expect(auxiliary.mediaInfo.attachments.isEmpty)
        expectSameMetadata(primaryInfo, auxiliary.mediaInfo)
        let stream = try #require(primaryInfo.subtitleStreams.first)
        let codecPrivate = auxiliary.codecPrivateData(streamIndex: stream.index)
        #expect(codecPrivate?.isEmpty == false)
        let owned = try auxiliary.copyCodecParameters(streamIndex: stream.index)
        let parameters = try #require(owned)
        let created = try parameters.withUnsafePointer {
            try SubtitleDecoder(parameters: $0, stream: stream)
        }
        let decoder = try #require(created)

        let main = try SubtitlePipeline(
            overlay: SubtitleOverlayView(headless: true), presentsOverlay: false
        )
        let pip = try SubtitlePipeline(
            overlay: SubtitleOverlayView(headless: true), presentsOverlay: false,
            memoryOwner: .pictureInPictureLibass
        )
        let size = CGSize(width: 640, height: 360)
        for pipeline in [main, pip] {
            let registered = try pipeline.configure(
                codecPrivate: codecPrivate,
                codecName: stream.codecName,
                attachments: primaryInfo.attachments,
                frameSize: size,
                storageSize: size
            )
            #expect(registered == ["NotoSans-Regular.ttf"])
        }
        var decodedEvents = 0
        var reachedEOF = false
        for _ in 0..<1_024 {
            guard let packet = try auxiliary.readPacket(generation: 1) else {
                reachedEOF = true
                break
            }
            guard packet.streamIndex == stream.index else { continue }
            for event in try decoder.decode(packet) {
                decodedEvents += 1
                #expect(main.process(event: event))
                #expect(pip.process(event: event))
            }
        }
        #expect(reachedEOF)
        #expect(decodedEvents > 0)
        let time = CMTime(seconds: 0.1, preferredTimescale: 1_000)
        let viewport = CGRect(origin: .zero, size: size)
        let mainRegions = main.renderedRegions(at: time, viewport: viewport, videoSize: size)
        let pipRegions = pip.renderedRegions(at: time, viewport: viewport, videoSize: size)
        #expect(!mainRegions.isEmpty)
        #expect(mainRegions.allSatisfy { !$0.bitmap.isEmpty })
        #expect(pipRegions.count == mainRegions.count)
        for (expected, actual) in zip(mainRegions, pipRegions) {
            #expect(actual.bitmap == expected.bitmap)
            #expect(actual.color == expected.color)
            #expect(actual.frame == expected.frame)
            #expect(actual.stride == expected.stride)
            #expect(actual.bitmapSize == expected.bitmapSize)
            #expect(actual.isPremultipliedBGRA == expected.isPremultipliedBGRA)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_REAL_FONT_FIXTURE"] != nil,
                   "Generate the real attached-font video fixture"))
    func thumbnailReadersPreserveDurationAndPixelsWithEmbeddedFonts() async throws {
        let url = try fixtureURL("ILLIQUID_AUXILIARY_REAL_FONT_FIXTURE")
        // The generator remuxes the same video/audio/subtitle base for both
        // containers, adding only the real font attachment to the first one.
        let control = url.deletingLastPathComponent().appendingPathComponent("none.mkv")
        try #require(FileManager.default.fileExists(atPath: control.path))
        let metadata = NativeThumbnailMetadataReader()
        let duration = try #require(await metadata.duration(of: url))
        let controlDuration = try #require(await metadata.duration(of: control))
        #expect(abs(duration - 0.8) < 0.000_001)
        #expect(duration == controlDuration)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("illiquid-auxiliary-font-thumbnails-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await NativeTimelineThumbnailGenerator.prepareImageRendererForQualification()
        let generator = NativeTimelineThumbnailGenerator(cacheDirectory: directory)
        let size = CGSize(width: 80, height: 45)
        var results: [(CGImage?, CGImage?)] = []
        for time in [0.0, 0.5] {
            let attached = await generator.thumbnail(for: url, at: time, maximumPixelSize: size)
            let unadorned = await generator.thumbnail(for: control, at: time, maximumPixelSize: size)
            results.append((attached, unadorned))
        }
        // All requests have completed. Request worker release and finish cache
        // cleanup before any image assertion can throw.
        await generator.cancelWork()
        await generator.flushPendingCacheWrites()
        let cleared = await generator.removeAllCachedThumbnails()
        #expect(cleared)
        for (attached, control) in results {
            let actual = try #require(attached)
            let expected = try #require(control)
            #expect(actual.width == 80 && actual.height == 45)
            #expect(expected.width == actual.width && expected.height == actual.height)
            let actualPixels = try rgbaPixels(actual)
            let expectedPixels = try rgbaPixels(expected)
            #expect(actualPixels == expectedPixels)
            #expect(Set(actualPixels).count > 2, "The generated test pattern must contain visible color")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_REAL_FONT_FIXTURE"] != nil,
                   "Generate the real attached-font video fixture"))
    func frameStepReaderPreservesAdjacentTimestampsWithEmbeddedFonts() async throws {
        let url = try fixtureURL("ILLIQUID_AUXILIARY_REAL_FONT_FIXTURE")
        let reader = NativeFrameStepReader()
        // Eight FFV1 frames at 10 fps span [0.0, 0.7]. Exercise exact-frame,
        // between-frame, and both endpoint requests through the actual reader.
        let requests: [(Double, Int, Double?)] = [
            (0.0, -1, nil), (0.0, 1, 0.1),
            (0.3, -1, 0.2), (0.3, 1, 0.4),
            (0.35, -1, 0.3), (0.35, 1, 0.4),
            (0.7, -1, 0.6), (0.7, 1, nil),
        ]
        for (position, direction, expected) in requests {
            let actual = try await reader.target(url: url, position: position, direction: direction)
            if let expected {
                let target = try #require(actual)
                #expect(abs(target - expected) < 0.000_001,
                        "Unexpected adjacent timestamp from \(position), direction \(direction)")
            } else {
                #expect(actual == nil)
            }
        }
    }

    private func rgbaPixels(_ image: CGImage) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data)
        return Data(bytes: bytes, count: context.bytesPerRow * context.height)
    }

    private func fixtureURL(_ variable: String) throws -> URL {
        let path = try #require(ProcessInfo.processInfo.environment[variable])
        #expect(FileManager.default.fileExists(atPath: path))
        return URL(fileURLWithPath: path)
    }

    private func expectMixedFonts(_ attachments: [FontAttachment]) {
        #expect(attachments.map(\.filename) == ["embedded.TTF", "glyphs.bin"])
        #expect(attachments.map(\.mimeType) == ["application/x-truetype-font", "font/otf"])
        #expect(attachments.map(\.data) == [
            Data([0x00, 0x01, 0x02, 0xFE, 0xFF]),
            Data([0x46, 0x4F, 0x4E, 0x54, 0x00, 0x80]),
        ])
    }

    private func expectSameMetadata(_ expected: FFmpegMediaInfo, _ actual: FFmpegMediaInfo) {
        #expect(actual.url == expected.url)
        #expect(actual.containerName == expected.containerName)
        #expect(actual.duration == expected.duration)
        #expect(actual.startTime == expected.startTime)
        #expect(actual.durationStatus == expected.durationStatus)
        #expect(actual.startTimeStatus == expected.startTimeStatus)
        #expect(actual.streams == expected.streams)
        #expect(actual.selectedVideoIndex == expected.selectedVideoIndex)
        #expect(actual.selectedAudioIndex == expected.selectedAudioIndex)
        #expect(actual.selectedSubtitleIndex == expected.selectedSubtitleIndex)
        #expect(actual.chapters.count == expected.chapters.count)
        for (left, right) in zip(expected.chapters, actual.chapters) {
            #expect(right.title == left.title)
            #expect(right.start == left.start)
            #expect(right.end == left.end)
        }
    }

    private struct PacketSnapshot: Equatable {
        struct SideData: Equatable {
            let type: Int32
            let bytes: Data
        }
        let streamIndex: Int32
        let presentationTimestamp: Int64
        let decodeTimestamp: Int64
        let duration: Int64
        let timeBase: FFmpegRational
        let generation: Int
        let flags: Int32
        let bytes: Data?
        let sideData: [SideData]
    }

    private func readPackets(_ read: () throws -> FFmpegPacket?) throws -> [PacketSnapshot] {
        var snapshots: [PacketSnapshot] = []
        for _ in 0..<1_024 {
            guard let packet = try read() else { return snapshots }
            let pointer = try #require(packet.pointer)
            var sideData: [PacketSnapshot.SideData] = []
            for index in 0..<Int(pointer.pointee.side_data_elems) {
                let side = pointer.pointee.side_data[index]
                sideData.append(.init(
                    type: Int32(side.type.rawValue),
                    bytes: Data(bytes: side.data, count: Int(side.size))
                ))
            }
            snapshots.append(.init(
                streamIndex: packet.streamIndex,
                presentationTimestamp: packet.presentationTimestamp,
                decodeTimestamp: packet.decodeTimestamp,
                duration: packet.duration,
                timeBase: packet.timeBase,
                generation: packet.generation,
                flags: pointer.pointee.flags,
                bytes: packet.data,
                sideData: sideData
            ))
        }
        Issue.record("The bounded fixture did not reach end of input")
        return snapshots
    }
}
