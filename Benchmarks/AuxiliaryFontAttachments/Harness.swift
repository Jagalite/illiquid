import CFFmpeg
import CAuxiliaryFontHeap
import CryptoKit
import Darwin
import Foundation
@testable import AttachmentProjection

private func fail(_ message: String) -> NSError {
    NSError(domain: "AuxiliaryFontAttachmentsBenchmark", code: 1,
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


private func encoded(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}
private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private enum Reader {
    case direct(FFmpegDemuxer)
    case executor(FFmpegInputExecutor)

    init(url: URL, api: String, auxiliary: Bool) throws {
        #if AUXILIARY_FONT_CANDIDATE
        if auxiliary {
            if api == "direct" {
                self = .direct(try FFmpegDemuxer(url: url, includeFontAttachments: false))
            } else {
                self = .executor(try FFmpegInputExecutor(url: url, includeFontAttachments: false))
            }
            return
        }
        #endif
        // Exercise the default primary call in both variants, and the original
        // unqualified auxiliary call in the historical baseline.
        if api == "direct" { self = .direct(try FFmpegDemuxer(url: url)) }
        else { self = .executor(try FFmpegInputExecutor(url: url)) }
    }

    var info: FFmpegMediaInfo {
        switch self { case .direct(let value): value.mediaInfo; case .executor(let value): value.mediaInfo }
    }
    func packet(generation: Int) throws -> FFmpegPacket? {
        switch self {
        case .direct(let value): try value.readPacket(generation: generation)
        case .executor(let value): try value.readPacket(generation: generation)
        }
    }
    func seek(_ time: Double) throws {
        switch self {
        case .direct(let value): try value.seek(to: time, exact: true)
        case .executor(let value): try value.seek(to: time, exact: true)
        }
    }
    func extra(_ stream: Int32) -> Data? {
        switch self {
        case .direct(let value): value.codecPrivateData(streamIndex: stream)
        case .executor(let value): value.codecPrivateData(streamIndex: stream)
        }
    }
}

private func roles(_ scenario: String) -> [Bool] {
    switch scenario {
    case "primary": [false]
    case "auxiliary": [true]
    default: [false, true, true]
    }
}

@inline(never)
private func openReaders(_ url: URL, api: String, scenario: String) throws -> [Reader] {
    try roles(scenario).map { try Reader(url: url, api: api, auxiliary: $0) }
}

@inline(never)
private func payloadBytes(_ readers: [Reader]) -> Int {
    readers.reduce(0) { sum, reader in
        sum + reader.info.attachments.reduce(0) { $0 + $1.data.count }
    }
}

private func usage() throws -> rusage {
    var result = rusage()
    guard getrusage(RUSAGE_SELF, &result) == 0 else { throw fail("getrusage failed") }
    return result
}
private func cpuSeconds(_ value: rusage) -> Double {
    Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
        + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
}

@inline(never)
private func measure(_ url: URL, api: String, scenario: String) throws -> [String: Any] {
    // One identical default primary open/close warms shared runtime and codec
    // initialization in each variant. No font payload survives this scope.
    try autoreleasepool {
        let warm = try Reader(url: url, api: api, auxiliary: false)
        guard !warm.info.streams.isEmpty else { throw fail("Empty warm-up input") }
        withExtendedLifetime(warm) {}
    }
    _ = auxiliary_font_live_bytes()
    _ = try usage()
    var readers: [Reader] = []
    let beforeBytes = auxiliary_font_live_bytes()
    let before = try usage()
    let start = DispatchTime.now().uptimeNanoseconds
    readers = try autoreleasepool { try openReaders(url, api: api, scenario: scenario) }
    let wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    let after = try usage()
    // Keep every native context and owning media-info Data alive across the
    // sample, after temporary/autoreleased objects have left scope.
    let retainedBytes = withExtendedLifetime(readers) { auxiliary_font_live_bytes() }
    let payload = payloadBytes(readers)
    let count = readers.count
    autoreleasepool { readers.removeAll(keepingCapacity: false) }
    let releasedBytes = auxiliary_font_live_bytes()
    return [
        "reader_count": count, "retained_font_payload_bytes": payload,
        "allocator_before_bytes": beforeBytes, "allocator_retained_bytes": retainedBytes,
        "allocator_after_release_bytes": releasedBytes,
        "retained_allocator_delta_bytes": Int64(retainedBytes) - Int64(beforeBytes),
        "after_release_allocator_delta_bytes": Int64(releasedBytes) - Int64(beforeBytes),
        "setup_wall_seconds": wall, "setup_cpu_seconds": cpuSeconds(after) - cpuSeconds(before),
        "process_peak_rss_before_bytes": before.ru_maxrss,
        "process_peak_rss_after_open_bytes": after.ru_maxrss,
    ]
}

private func packets(_ reader: Reader, generation: Int) throws -> [[String: Any]] {
    var result: [[String: Any]] = []
    while let packet = try reader.packet(generation: generation) {
        guard result.count < 2048, let pointer = packet.pointer else {
            throw fail("Packet validation did not reach bounded EOF")
        }
        var sideData: [[String: Any]] = []
        if pointer.pointee.side_data_elems > 0, let values = pointer.pointee.side_data {
            for index in 0..<Int(pointer.pointee.side_data_elems) {
                let value = values[index]
                let bytes = value.data.map { Data(bytes: $0, count: Int(value.size)) } ?? Data()
                sideData.append(["type": value.type.rawValue, "bytes": value.size,
                                 "sha256": digest(bytes)])
            }
        }
        result.append([
            "stream_index": packet.streamIndex,
            "pts": packet.presentationTimestamp, "dts": packet.decodeTimestamp,
            "duration": packet.duration,
            "time_base": [packet.timeBase.numerator, packet.timeBase.denominator],
            "generation": packet.generation, "corrupt": packet.isCorrupt,
            "keyframe": packet.isKeyframe, "flags": pointer.pointee.flags,
            "position": pointer.pointee.pos, "bytes": packet.byteCount,
            "sha256": nullable(packet.data.map(digest)), "side_data": sideData,
            "presentation_seconds_bits": nullable(packet.presentationSeconds.map(bits)),
            "decode_seconds_bits": nullable(packet.decodeSeconds.map(bits)),
            "duration_seconds_bits": nullable(packet.durationSeconds.map(bits)),
        ])
    }
    guard !result.isEmpty else { throw fail("Fixture yielded no packets") }
    return result
}

@inline(never)
private func verify(_ url: URL, api: String, scenario: String,
                    expectedBytes: Int) throws -> [[String: Any]] {
    var readers = try openReaders(url, api: api, scenario: scenario)
    let auxiliaryRoles = roles(scenario)
    var retainedInfos: [FFmpegMediaInfo] = []
    var records: [[String: Any]] = []
    for (index, reader) in readers.enumerated() {
        let info = reader.info
        let bytes = info.attachments.reduce(0) { $0 + $1.data.count }
        #if AUXILIARY_FONT_CANDIDATE
        let expected = auxiliaryRoles[index] ? 0 : expectedBytes
        #else
        let expected = expectedBytes
        #endif
        guard bytes == expected else { throw fail("Unexpected retained attachment payload") }
        let extra: [[String: Any]] = info.streams.map { stream in
            let data = reader.extra(stream.index)
            return ["stream_index": stream.index,
                    "bytes": nullable(data?.count), "sha256": nullable(data.map(digest))]
        }
        let initialPackets = try packets(reader, generation: 71)
        try reader.seek(info.startTime + min(0.125, info.duration / 2))
        let soughtPackets = try packets(reader, generation: 72)
        records.append(["auxiliary": auxiliaryRoles[index], "info": snapshot(info),
                        "codec_private": extra, "initial_packets": initialPackets,
                        "sought_packets": soughtPackets, "observed_eof_twice": true])
        retainedInfos.append(info)
    }
    // These copies must remain valid after every demuxer/input worker closes.
    autoreleasepool { readers.removeAll(keepingCapacity: false) }
    for (index, info) in retainedInfos.enumerated() {
        guard try encoded(snapshot(info)) == encoded(records[index]["info"]!) else {
            throw fail("Owned media metadata or font bytes changed after input destruction")
        }
        records[index]["owned_lifetime_verified"] = true
    }
    return records
}

@main
private enum AuxiliaryFontAttachmentsHarness {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 5, ["direct", "executor"].contains(args[2]),
              ["primary", "auxiliary", "primary-two-auxiliary"].contains(args[3]),
              let expected = Int(args[4]), expected >= 0 else {
            throw fail("Usage: harness FIXTURE direct|executor primary|auxiliary|primary-two-auxiliary ACCEPTED_BYTES")
        }
        av_log_set_level(AV_LOG_QUIET)
        let url = URL(fileURLWithPath: args[1]).standardizedFileURL
        var result = try measure(url, api: args[2], scenario: args[3])
        // Verification and hashing happen only after all memory samples above.
        result["readers"] = try autoreleasepool {
            try verify(url, api: args[2], scenario: args[3], expectedBytes: expected)
        }
        result["api"] = args[2]
        result["scenario"] = args[3]
        result["accepted_bytes_per_reader"] = expected
        result["ffmpeg_version"] = String(cString: av_version_info())
        result["avformat_version"] = avformat_version()
        result["avcodec_version"] = avcodec_version()
        result["avutil_version"] = avutil_version()
        result["allocator_metric"] = "malloc_zone_statistics(NULL).size_in_use"
        print(String(decoding: try encoded(result), as: UTF8.self))
    }
}
