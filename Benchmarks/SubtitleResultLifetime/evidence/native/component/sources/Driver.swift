import CFFmpeg
import CoreGraphics
import CryptoKit
import Foundation
import LifetimeProbe

private struct StudyError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw StudyError(message) }
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct Snapshot: Codable, Equatable {
    let hasOutput: Bool
    let rectangleCount: UInt32
    let indexedPayloadBytes: UInt64
    let textPayloadBytes: UInt64
    let liveMallocBytes: UInt64
    let liveAllocations: UInt32
    let eventBudgetBytes: Int

    init(_ decoder: SubtitleDecoder, budget: SubtitleMemoryBudget) {
        let value = decoder.benchmarkRetainedResult()
        hasOutput = value.has_output != 0
        rectangleCount = value.rectangle_count
        indexedPayloadBytes = value.indexed_payload_bytes
        textPayloadBytes = value.text_payload_bytes
        liveMallocBytes = value.live_malloc_bytes
        liveAllocations = value.live_allocations
        eventBudgetBytes = budget.snapshot.reservedBytes
    }
}

private struct EventMetadata: Codable {
    struct Region: Codable {
        let x: Int, y: Int, width: Int, height: Int
        let forced: Bool
        let byteCount: Int
    }
    let startBits: UInt64
    let durationBits: UInt64
    let generation: Int
    let textBytes: Int
    let bitmapDurationBits: UInt64?
    let canvasWidth: Int?
    let canvasHeight: Int?
    let regions: [Region]?
}

/// A length-prefixed, complete output stream; never only sampled pixels.
/// The runner compares every byte from the two variants and retains gzip copies.
private func recordEvents(_ events: [NativeDecodedSubtitleEvent], into file: FileHandle) throws -> String {
    var hash = SHA256()
    func write(_ data: Data) throws {
        hash.update(data: data)
        try file.write(contentsOf: data)
    }
    func count(_ value: Int) throws {
        var encoded = UInt64(value).littleEndian
        try withUnsafeBytes(of: &encoded) { try write(Data($0)) }
    }
    try count(events.count)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for event in events {
        let bitmap = event.bitmapComposition
        let metadata = EventMetadata(
            startBits: event.presentationSeconds.bitPattern,
            durationBits: event.durationSeconds.bitPattern,
            generation: event.generation, textBytes: event.assData.count,
            bitmapDurationBits: bitmap?.duration?.bitPattern,
            canvasWidth: bitmap.map { Int($0.canvasSize.width) },
            canvasHeight: bitmap.map { Int($0.canvasSize.height) },
            regions: bitmap?.regions.map { region in
                .init(x: Int(region.frame.minX), y: Int(region.frame.minY),
                      width: Int(region.frame.width), height: Int(region.frame.height),
                      forced: region.isForced, byteCount: region.pixels.count)
            })
        let header = try encoder.encode(metadata)
        try count(header.count)
        try write(header)
        try write(event.assData)
        for region in bitmap?.regions ?? [] { try write(region.pixels) }
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

private struct Fixture {
    let name: String
    let codec: AVCodecID
    let codecName: String
    let payload: [UInt8]
    let expectedWidth: Int?
    let expectedHeight: Int?
    let expectedError: String?
    let budgetLimit: Int

    static let names = ["text", "pgs_tiny", "pgs_1080p", "pgs_large_cropped",
                        "pgs_display_rejected", "pgs_budget_rejected", "pgs_malformed", "dvb_tiny"]

    static func make(_ name: String) throws -> Self {
        switch name {
        case "text":
            return Self(name: name, codec: AV_CODEC_ID_SUBRIP, codecName: "subrip",
                        payload: Array("Owned subtitle text <i>must survive</i> reset".utf8),
                        expectedWidth: nil, expectedHeight: nil, expectedError: nil,
                        budgetLimit: 32 * 1_024 * 1_024)
        case "dvb_tiny":
            let definition = dvb(0x14, [0, 4, 255, 2, 207])
            let page = dvb(0x10, [2, 4, 1, 0, 0, 10, 0, 20])
            let region = dvb(0x11, [1, 8, 0, 2, 0, 2, 12, 0, 1, 0, 0, 1, 0, 0, 0, 0])
            let object = dvb(0x13, [0, 1, 0, 0, 6, 0, 6, 0x12, 1, 1, 0, 0, 0xF0, 0x12, 1, 1, 0, 0, 0xF0])
            let palette = dvb(0x12, [0, 0, 1, 0x21, 235, 128, 128, 0])
            return Self(name: name, codec: AV_CODEC_ID_DVB_SUBTITLE, codecName: "dvb_subtitle",
                        payload: definition + page + region + palette + object + dvb(0x80, []),
                        expectedWidth: 2, expectedHeight: 2, expectedError: nil,
                        budgetLimit: 32 * 1_024 * 1_024)
        default:
            let width: Int
            let height: Int
            let crop: Bool
            let error: String?
            let budget: Int
            switch name {
            case "pgs_tiny": (width, height, crop, error, budget) = (2, 2, false, nil, 32 * 1_024 * 1_024)
            case "pgs_1080p": (width, height, crop, error, budget) = (1_920, 1_080, false, nil, 32 * 1_024 * 1_024)
            case "pgs_large_cropped": (width, height, crop, error, budget) = (4_096, 1_024, true, nil, 32 * 1_024 * 1_024)
            case "pgs_display_rejected":
                (width, height, crop, error, budget) = (4_096, 1_025, false,
                    "Bitmap subtitle display exceeds the byte limit", 32 * 1_024 * 1_024)
            case "pgs_budget_rejected":
                (width, height, crop, error, budget) = (1_920, 1_080, false,
                    "Bitmap subtitle memory budget is exhausted", 1_024)
            case "pgs_malformed":
                return Self(name: name, codec: AV_CODEC_ID_HDMV_PGS_SUBTITLE, codecName: "hdmv_pgs_subtitle",
                            payload: [0x16, 0, 11, 0], expectedWidth: nil, expectedHeight: nil,
                            expectedError: "ffmpeg:Read PGS composition geometry", budgetLimit: 32 * 1_024 * 1_024)
            default: throw StudyError("Unknown fixture: \(name)")
            }
            return Self(name: name, codec: AV_CODEC_ID_HDMV_PGS_SUBTITLE, codecName: "hdmv_pgs_subtitle",
                        payload: pgs(width: width, height: height, crop: crop),
                        expectedWidth: crop ? 1 : width, expectedHeight: crop ? 1 : height,
                        expectedError: error, budgetLimit: budget)
        }
    }

    private static func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 255)] }

    private static func segment(_ kind: UInt8, _ data: [UInt8]) -> [UInt8] {
        precondition(data.count <= 65_535)
        return [kind] + word(data.count) + data
    }

    private static func dvb(_ kind: UInt8, _ data: [UInt8]) -> [UInt8] {
        [0x0F, kind, 0, 1] + word(data.count) + data
    }

    private static func pgs(width: Int, height: Int, crop: Bool) -> [UInt8] {
        let canvasWidth = max(1_280, width)
        let canvasHeight = max(720, height)
        var pcs = word(canvasWidth) + word(canvasHeight)
        pcs += [16, 0, 1, 128, 0, 0, 1, 0, 1, 0, crop ? 0xC0 : 0x40, 0, 0, 0, 0]
        if crop { pcs += word(0) + word(0) + word(1) + word(1) }
        let palette = segment(0x14, [0, 0, 0, 16, 128, 128, 0, 1, 235, 128, 128, 255])
        // PGS run: escape, long colored-run control, low length byte, index 1,
        // then the end-of-line escape. Large decoded output uses a small packet.
        let row: [UInt8] = [0, 0xC0 | UInt8(width >> 8), UInt8(width & 255), 1, 0, 0]
        var rle: [UInt8] = []
        rle.reserveCapacity(row.count * height)
        for _ in 0..<height { rle += row }
        let objectLength = rle.count + 4
        var object: [UInt8] = [0, 1, 0, 0xC0,
                               UInt8(objectLength >> 16), UInt8((objectLength >> 8) & 255), UInt8(objectLength & 255)]
        object += word(width) + word(height) + rle
        return segment(0x16, pcs) + palette + segment(0x15, object) + segment(0x80, [])
    }

    func decoder(budget: SubtitleMemoryBudget) throws -> SubtitleDecoder {
        var owned = avcodec_parameters_alloc()
        guard let parameters = owned else { throw StudyError("No codec parameters") }
        defer { avcodec_parameters_free(&owned) }
        parameters.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        parameters.pointee.codec_id = codec
        if codec == AV_CODEC_ID_DVB_SUBTITLE {
            guard let extra = av_mallocz(4 + Int(AV_INPUT_BUFFER_PADDING_SIZE))?.assumingMemoryBound(to: UInt8.self)
            else { throw StudyError("No DVB extradata") }
            extra[1] = 1
            extra[3] = 2
            parameters.pointee.extradata = extra
            parameters.pointee.extradata_size = 4
        }
        let stream = FFmpegStreamInfo(index: 0, kind: .subtitle, codecID: Int32(codec.rawValue),
            codecName: codecName, title: nil, language: nil, timeBase: .init(numerator: 1, denominator: 1_000_000),
            duration: nil, disposition: 0, codedSize: nil, pixelAspectRatio: nil, averageFrameRate: nil,
            sampleRate: nil, channelCount: nil, channelLayout: nil, rotationDegrees: 0,
            isMirrored: false, interlaceMode: .progressive)
        return try SubtitleDecoder(parameters: parameters, stream: stream, memoryBudget: budget)
    }

    func packet(at seconds: Int64) throws -> FFmpegPacket {
        var owned = av_packet_alloc()
        guard let raw = owned else { throw StudyError("No packet") }
        defer { av_packet_free(&owned) }
        try checkFFmpeg(av_new_packet(raw, Int32(payload.count)), operation: "Allocate lifetime fixture")
        payload.withUnsafeBufferPointer { raw.pointee.data.update(from: $0.baseAddress!, count: $0.count) }
        raw.pointee.pts = seconds * 1_000_000
        raw.pointee.dts = raw.pointee.pts
        raw.pointee.duration = 5_000_000
        return try FFmpegPacket(taking: &owned, timeBase: .init(num: 1, den: 1_000_000), generation: 7)
    }

    func validate(_ events: [NativeDecodedSubtitleEvent], error: String?) throws {
        if let expectedError {
            try require(error?.hasPrefix(expectedError) == true, "Unexpected error for \(name): \(String(describing: error))")
            try require(events.isEmpty, "Rejected output escaped")
            return
        }
        try require(error == nil && events.count == 1, "Expected exactly one event for \(name)")
        let event = events[0]
        try require(event.presentationSeconds == 2 && event.generation == 7, "Timestamp or generation changed")
        if let expectedWidth, let expectedHeight {
            guard let composition = event.bitmapComposition else { throw StudyError("Missing bitmap") }
            try require(composition.regions.count == 1, "Expected one region")
            let region = composition.regions[0]
            try require(Int(region.frame.width) == expectedWidth && Int(region.frame.height) == expectedHeight,
                        "Wrong region dimensions for \(name)")
            try require(region.pixels.count == expectedWidth * expectedHeight * 4, "Incorrect byte count")
            try require(region.pixels.allSatisfy { $0 == 255 }, "Expected fully opaque white decoded pixels")
        } else {
            try require(!event.assData.isEmpty && event.bitmapComposition == nil, "Expected owned ASS text")
            try require(String(decoding: event.assData, as: UTF8.self).contains("Owned subtitle text"), "Missing text")
        }
    }
}

private func decode(_ decoder: SubtitleDecoder, packet: FFmpegPacket) -> ([NativeDecodedSubtitleEvent], String?) {
    do { return (try decoder.decode(packet), nil) }
    catch let error as FFmpegError { return ([], "ffmpeg:\(error.operation):\(error.code)") }
    catch let error as PresentationError { return ([], error.message) }
    catch { return ([], String(describing: error)) }
}

private struct Observation: Codable {
    let workload: String
    let ffmpegVersion: String
    let packetSHA256: String
    let packetBytes: Int
    let idleMilliseconds: Int
    let snapshots: [String: Snapshot]
    let semantic: [String: String]
}

@main
private enum Driver {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { throw StudyError("usage: benchmark WORKLOAD OUTPUT.bin") }
        let fixture = try Fixture.make(arguments[1])
        let destination = URL(fileURLWithPath: arguments[2])
        try require(FileManager.default.createFile(atPath: destination.path, contents: nil), "Cannot create output")
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        let budget = SubtitleMemoryBudget(limitBytes: fixture.budgetLimit)
        let decoder = try fixture.decoder(budget: budget)
        var snapshots: [String: Snapshot] = ["initial": Snapshot(decoder, budget: budget)]
        var semantic: [String: String] = [:]
        var (events, error) = decode(decoder, packet: try fixture.packet(at: 2))
        snapshots["after_return"] = Snapshot(decoder, budget: budget)
        Thread.sleep(forTimeInterval: 0.050)
        snapshots["after_idle"] = Snapshot(decoder, budget: budget)
        try require(snapshots["after_return"] == snapshots["after_idle"], "Output lifetime changed while idle")
        try fixture.validate(events, error: error)
        semantic["first_error"] = error ?? "none"
        semantic["first_events"] = try recordEvents(events, into: file)

        // Re-enter the actual stateful codec while retaining the first result's
        // application events. Their complete output must survive another decode.
        var second = decode(decoder, packet: try fixture.packet(at: 7))
        snapshots["after_second_return"] = Snapshot(decoder, budget: budget)
        semantic["second_error"] = second.1 ?? "none"
        semantic["second_events"] = try recordEvents(second.0, into: file)
        semantic["first_after_second"] = try recordEvents(events, into: file)
        try require(semantic["first_events"] == semantic["first_after_second"], "Events changed after another packet")

        // Dropping application-owned copies must not be confused with freeing
        // the separate FFmpeg result. Observe the two ownership domains apart.
        events.removeAll(keepingCapacity: false)
        second.0.removeAll(keepingCapacity: false)
        snapshots["after_events_dropped"] = Snapshot(decoder, budget: budget)
        try require(budget.snapshot.reservedBytes == 0, "Application events leaked their memory budget")
        try decoder.flush()
        snapshots["after_flush"] = Snapshot(decoder, budget: budget)
        try require(snapshots["after_flush"]?.liveMallocBytes == 0, "Explicit flush did not release output")

        // Decode after a full reset and retain copied events across another reset.
        (events, error) = decode(decoder, packet: try fixture.packet(at: 2))
        snapshots["after_redecode"] = Snapshot(decoder, budget: budget)
        try fixture.validate(events, error: error)
        semantic["redecode_error"] = error ?? "none"
        semantic["redecode_events"] = try recordEvents(events, into: file)
        try decoder.flush()
        semantic["events_after_flush"] = try recordEvents(events, into: file)
        try require(semantic["redecode_events"] == semantic["events_after_flush"], "Events changed after flush")
        events.removeAll(keepingCapacity: false)
        snapshots["final"] = Snapshot(decoder, budget: budget)
        try require(budget.snapshot.reservedBytes == 0, "Final application events retained memory")
        let observation = Observation(workload: fixture.name, ffmpegVersion: String(cString: av_version_info()),
            packetSHA256: digest(Data(fixture.payload)), packetBytes: fixture.payload.count,
            idleMilliseconds: 50, snapshots: snapshots, semantic: semantic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(observation)
        print(String(decoding: json, as: UTF8.self))
    }
}
