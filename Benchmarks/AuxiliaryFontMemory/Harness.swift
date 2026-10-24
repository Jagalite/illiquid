// Metadata serialization follows Benchmarks/AttachmentAdmission/Harness.swift.
import CFFmpeg
import CMemoryProbe
import CryptoKit
import Darwin
import Foundation
@testable import AuxiliaryFontInput

private func fail(_ message: String) -> NSError {
    NSError(domain: "AuxiliaryFontMemoryBenchmark", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
}

private func nullable<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
private func bits(_ value: Double) -> String { String(value.bitPattern, radix: 16) }
private func size(_ value: CGSize?) -> Any {
    guard let value else { return NSNull() }
    return [bits(Double(value.width)), bits(Double(value.height))]
}

private func timeline(_ value: FFmpegMediaInfo.TimelineValue) -> [String: Any] {
    switch value {
    case .valid(let seconds): return ["status": "valid", "seconds_bits": bits(seconds)]
    case .unknown: return ["status": "unknown"]
    case .invalid: return ["status": "invalid"]
    }
}

private func capability(_ value: NativeSubtitleCapability?) -> Any {
    guard let value else { return NSNull() }
    switch value {
    case .text: return ["kind": "text"]
    case .bitmap: return ["kind": "bitmap"]
    case .bitmapUnsupported(let codec): return ["kind": "bitmapUnsupported", "codec": codec]
    case .unsupported(let codec): return ["kind": "unsupported", "codec": codec]
    }
}

// Serialize every stored media-info/stream field, plus useful derived properties.
// Floating values retain their exact bit patterns; payload hashing is untimed.
private func snapshot(_ info: FFmpegMediaInfo) -> [String: Any] {
    let streams: [[String: Any]] = info.streams.map { stream in
        ["index": stream.index, "kind": stream.kind.rawValue,
         "codec_id": stream.codecID, "codec_name": stream.codecName,
         "title": nullable(stream.title), "language": nullable(stream.language),
         "time_base": [stream.timeBase.numerator, stream.timeBase.denominator],
         "duration_bits": nullable(stream.duration.map(bits)),
         "disposition": stream.disposition, "coded_size_bits": size(stream.codedSize),
         "pixel_aspect_bits": size(stream.pixelAspectRatio),
         "average_frame_rate_bits": nullable(stream.averageFrameRate.map(bits)),
         "sample_rate": nullable(stream.sampleRate), "channel_count": nullable(stream.channelCount),
         "channel_layout": nullable(stream.channelLayout),
         "rotation_bits": bits(stream.rotationDegrees), "mirrored": stream.isMirrored,
         "interlace_mode": stream.interlaceMode.rawValue,
         "display_size_bits": size(stream.displaySize), "display_name": stream.displayName,
         "subtitle_capability": capability(stream.subtitleCapability)]
    }
    let attachments: [[String: Any]] = info.attachments.map {
        ["filename": $0.filename, "mime_type": nullable($0.mimeType),
         "bytes": $0.data.count,
         "sha256": SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined(),
         "supported_font": $0.isSupportedFont]
    }
    let chapters: [[String: Any]] = info.chapters.map {
        ["title": nullable($0.title), "start_bits": bits($0.start), "end_bits": bits($0.end)]
    }
    return ["url": info.url.absoluteString, "container_name": info.containerName,
            "duration_bits": bits(info.duration), "start_time_bits": bits(info.startTime),
            "duration_status": timeline(info.durationStatus), "start_time_status": timeline(info.startTimeStatus),
            "streams": streams,
            "chapters": chapters,
            "attachments": attachments,
            "selected_video_index": nullable(info.selectedVideoIndex),
            "selected_audio_index": nullable(info.selectedAudioIndex),
            "selected_subtitle_index": nullable(info.selectedSubtitleIndex),
            "video_stream_indices": info.videoStreams.map(\.index),
            "audio_stream_indices": info.audioStreams.map(\.index),
            "subtitle_stream_indices": info.subtitleStreams.map(\.index)]
}

private func encoded(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func payload(_ data: Data?) -> Any {
    guard let data else { return NSNull() }
    return ["bytes": data.count,
            "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
}

private enum Input {
    case demuxer(FFmpegDemuxer)
    case executor(FFmpegInputExecutor)

    var mediaInfo: FFmpegMediaInfo {
        switch self {
        case .demuxer(let input): input.mediaInfo
        case .executor(let input): input.mediaInfo
        }
    }

    func read(generation: Int) throws -> FFmpegPacket? {
        switch self {
        case .demuxer(let input): try input.readPacket(generation: generation)
        case .executor(let input): try input.readPacket(generation: generation)
        }
    }

    func seek() throws {
        switch self {
        case .demuxer(let input): try input.seek(to: 0, exact: true)
        case .executor(let input): try input.seek(to: 0, exact: true)
        }
    }

    func codecData(_ index: Int32) -> Data? {
        switch self {
        case .demuxer(let input): input.codecPrivateData(streamIndex: index)
        case .executor(let input): input.codecPrivateData(streamIndex: index)
        }
    }

    // A serialized no-payload operation places the executor's opening closure
    // entirely before the retained-memory sample. The invalid stream returns
    // nil in production; it never reads packets or creates payload storage.
    func settle() { _ = codecData(-1) }
}

@inline(never)
private func openInput(_ url: URL, owner: String, role: String) throws -> Input {
    #if AUXILIARY_FONT_CANDIDATE
    if role == "auxiliary" {
        if owner == "demuxer" {
            return .demuxer(try FFmpegDemuxer(url: url, includeFontAttachments: false))
        }
        return .executor(try FFmpegInputExecutor(url: url, includeFontAttachments: false))
    }
    #endif
    // The baseline and both primary controls exercise the exact default API.
    if owner == "demuxer" { return .demuxer(try FFmpegDemuxer(url: url)) }
    return .executor(try FFmpegInputExecutor(url: url))
}

private func packets(_ input: Input, generation: Int) throws -> [[String: Any]] {
    var result: [[String: Any]] = []
    while let packet = try input.read(generation: generation) {
        guard result.count < 1_000, let native = packet.pointer else {
            throw fail("Fixture packet limit exceeded or a packet lost its header")
        }
        var sideData: [[String: Any]] = []
        for index in 0..<Int(native.pointee.side_data_elems) {
            guard let source = native.pointee.side_data else {
                throw fail("Packet side-data count without storage")
            }
            let item = source[index]
            let bytes: Data
            if item.size == 0 {
                bytes = Data()
            } else {
                guard let pointer = item.data else {
                    throw fail("Packet side-data length without payload")
                }
                bytes = Data(bytes: pointer, count: item.size)
            }
            sideData.append(["type": item.type.rawValue, "payload": payload(bytes)])
        }
        result.append([
            "stream_index": packet.streamIndex,
            "pts": String(packet.presentationTimestamp),
            "dts": String(packet.decodeTimestamp),
            "duration": String(packet.duration), "generation": packet.generation,
            "time_base": [packet.timeBase.numerator, packet.timeBase.denominator],
            "keyframe": packet.isKeyframe, "corrupt": packet.isCorrupt,
            "flags": native.pointee.flags, "position": String(native.pointee.pos),
            "payload": payload(packet.data), "side_data": sideData,
        ])
    }
    guard !result.isEmpty else { throw fail("Fixture did not produce packets") }
    return result
}

// All expensive observation happens after the retained-memory sample. This
// captures complete public metadata plus full payload/codec-data SHA-256
// receipts and complete packet sequences before and after a real seek.
private func receipt(_ input: Input) throws -> [String: Any] {
    let info = input.mediaInfo
    let metadata = snapshot(info)
    let privateData: [[String: Any]] = info.streams.map {
        ["stream_index": $0.index, "payload": payload(input.codecData($0.index))]
    }
    let initial = try packets(input, generation: 1)
    try input.seek()
    let afterSeek = try packets(input, generation: 2)
    return ["metadata": metadata, "codec_private_data": privateData,
            "initial_packets": initial, "packets_after_seek": afterSeek]
}

private final class HeldInputs {
    var values: [Input] = []
    init(capacity: Int) { values.reserveCapacity(capacity) }

    @inline(never)
    func open(_ url: URL, count: Int, owner: String, role: String) throws {
        for _ in 0..<count {
            let input = try openInput(url, owner: owner, role: role)
            input.settle()
            values.append(input)
        }
    }
}

@main
private enum AuxiliaryFontMemoryHarness {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 6, ["demuxer", "executor"].contains(args[2]),
              let count = Int(args[3]), [1, 3].contains(count),
              ["primary", "auxiliary"].contains(args[4]) else {
            throw fail("Usage: harness FIXTURE demuxer|executor 1|3 primary|auxiliary NO_ATTACHMENT_FIXTURE")
        }
        av_log_set_level(AV_LOG_QUIET)
        let url = URL(fileURLWithPath: args[1]).standardizedFileURL
        let owner = args[2]
        let role = args[4]
        let warmURL = URL(fileURLWithPath: args[5]).standardizedFileURL
        try autoreleasepool {
            let warm = try openInput(warmURL, owner: owner, role: role)
            warm.settle()
            guard warm.mediaInfo.attachments.isEmpty else {
                throw fail("Warm-up input unexpectedly contains font payloads")
            }
            _ = illiquid_auxiliary_allocator_live_bytes()
        }
        let held = HeldInputs(capacity: count)
        let before = illiquid_auxiliary_allocator_live_bytes()
        try autoreleasepool { try held.open(url, count: count, owner: owner, role: role) }
        let retained = withExtendedLifetime(held) { illiquid_auxiliary_allocator_live_bytes() }

        // The inputs remain strongly owned throughout sampling and all checks.
        let retainedPayload = held.values.reduce(0) { total, input in
            total + input.mediaInfo.attachments.reduce(0) { $0 + $1.data.count }
        }
        let attachmentCount = held.values.reduce(0) { $0 + $1.mediaInfo.attachments.count }
        var receipts: [[String: Any]] = []
        for input in held.values {
            receipts.append(try autoreleasepool { try receipt(input) })
        }
        let first = try encoded(receipts[0])
        guard try receipts.allSatisfy({ try encoded($0) == first }) else {
            throw fail("Concurrent input instances returned different media/packet receipts")
        }
        #if AUXILIARY_FONT_CANDIDATE
        let includesFonts = role == "primary"
        #else
        let includesFonts = true
        #endif
        guard includesFonts || retainedPayload == 0 && attachmentCount == 0 else {
            throw fail("An auxiliary input retained a font payload")
        }
        let result: [String: Any] = [
            "schema": 1, "owner": owner, "role": role, "input_count": count,
            "include_font_attachments": includesFonts,
            "allocator_metric": "malloc_zone_statistics(NULL).size_in_use",
            "allocator_before_bytes": before, "allocator_retained_bytes": retained,
            "allocator_retained_delta_bytes": Int64(retained) - Int64(before),
            "retained_font_payload_bytes": retainedPayload,
            "retained_font_attachment_count": attachmentCount,
            "input_receipt": receipts[0], "verified_inputs": receipts.count,
            "ffmpeg_version": String(cString: av_version_info()),
            "avformat_version": avformat_version(), "avcodec_version": avcodec_version(),
            "avutil_version": avutil_version(),
        ]
        // Serialization cannot affect the already-recorded allocator sample.
        let output = try withExtendedLifetime(held) { try encoded(result) }
        print(String(decoding: output, as: UTF8.self))
    }
}
