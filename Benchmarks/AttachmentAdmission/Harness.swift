import CFFmpeg
import CryptoKit
import Darwin
import Foundation
@testable import AttachmentProjection

private func fail(_ message: String) -> NSError {
    NSError(domain: "AttachmentAdmissionBenchmark", code: 1,
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

private func open(_ url: URL) throws -> UnsafeMutablePointer<AVFormatContext> {
    var context: UnsafeMutablePointer<AVFormatContext>?
    let result = url.path.withCString { avformat_open_input(&context, $0, nil, nil) }
    guard result >= 0, let opened = context else {
        avformat_close_input(&context)
        throw fail("avformat_open_input failed: \(result)")
    }
    let probe = avformat_find_stream_info(opened, nil)
    guard probe >= 0 else {
        avformat_close_input(&context)
        throw fail("avformat_find_stream_info failed: \(probe)")
    }
    return opened
}

private func close(_ context: UnsafeMutablePointer<AVFormatContext>) {
    var optional: UnsafeMutablePointer<AVFormatContext>? = context
    avformat_close_input(&optional)
}

private struct Inventory {
    let acceptedBytes: Int
    let rejectedBytes: Int
    let acceptedCount: Int
    let entries: [[String: Any]]
}

private func inventory(_ context: UnsafeMutablePointer<AVFormatContext>) -> Inventory {
    var accepted = 0
    var rejected = 0
    var count = 0
    var entries: [[String: Any]] = []
    for index in 0..<Int(context.pointee.nb_streams) {
        guard let stream = context.pointee.streams[index], let parameters = stream.pointee.codecpar,
              parameters.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT,
              parameters.pointee.extradata != nil, parameters.pointee.extradata_size > 0 else { continue }
        func metadata(_ key: String) -> String? {
            key.withCString { illiquid_metadata_value(stream.pointee.metadata, $0).map(String.init(cString:)) }
        }
        let filename = metadata("filename") ?? metadata("title") ?? "attachment-\(index)"
        let mime = metadata("mimetype")
        // This calls the unchanged production instance predicate in both variants.
        let supported = FontAttachment(filename: filename, mimeType: mime, data: Data()).isSupportedFont
        let bytes = Int(parameters.pointee.extradata_size)
        if supported { accepted += bytes; count += 1 } else { rejected += bytes }
        entries.append(["index": index, "filename": filename, "mime_type": nullable(mime),
                        "bytes": bytes, "supported_font": supported])
    }
    return Inventory(acceptedBytes: accepted, rejectedBytes: rejected, acceptedCount: count, entries: entries)
}

// The production projection is compiled separately, without cross-module
// optimization. Consume its output on every iteration without hashing entire
// retained font payloads inside the timed interval.
@inline(never)
private func consume(_ info: FFmpegMediaInfo) -> UInt64 {
    var value = info.duration.bitPattern ^ info.startTime.bitPattern
    value &+= UInt64(info.streams.count) &* 31 &+ UInt64(info.chapters.count)
    value &+= UInt64(info.selectedVideoIndex.map { Int64($0) + 1 } ?? 0)
    value &+= UInt64(info.selectedAudioIndex.map { Int64($0) + 1 } ?? 0) &* 17
    value &+= UInt64(info.selectedSubtitleIndex.map { Int64($0) + 1 } ?? 0) &* 19
    for stream in info.streams {
        value &+= UInt64(bitPattern: Int64(stream.index)) &* 7
        value &+= UInt64(bitPattern: Int64(stream.codecID)) &* 13
    }
    for attachment in info.attachments {
        value &+= UInt64(attachment.data.count) &* 37
        value &+= UInt64(attachment.data.first ?? 0) &* 41
        value &+= UInt64(attachment.data.last ?? 0) &* 43
    }
    return value
}

@inline(never)
private func setup(_ url: URL) throws -> FFmpegMediaInfo {
    let demuxer = try FFmpegDemuxer(url: url)
    return demuxer.mediaInfo
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

@main
private enum AttachmentAdmissionHarness {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 6, ["projection", "setup"].contains(arguments[2]),
              let iterations = Int(arguments[3]), iterations > 0,
              let acceptedBytes = Int(arguments[4]), acceptedBytes >= 0,
              let rejectedBytes = Int(arguments[5]), rejectedBytes >= 0 else {
            throw fail("Usage: harness FIXTURE projection|setup ITERATIONS ACCEPTED_BYTES REJECTED_BYTES")
        }
        av_log_set_level(AV_LOG_QUIET)
        let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let mode = arguments[2]
        let prepared = try open(url)
        let input = inventory(prepared)
        guard input.acceptedBytes == acceptedBytes, input.rejectedBytes == rejectedBytes else {
            close(prepared)
            throw fail("Fixture inventory mismatch: accepted \(input.acceptedBytes)/\(acceptedBytes), rejected \(input.rejectedBytes)/\(rejectedBytes)")
        }
        if mode == "setup" { close(prepared) }
        defer { if mode == "projection" { close(prepared) } }
        let (expectedChecksum, expectedSnapshot) = try autoreleasepool {
            let warm: FFmpegMediaInfo
            if mode == "projection" {
                warm = FFmpegDemuxer.makeMediaInfo(url: url, context: prepared)
            } else {
                warm = try setup(url)
            }
            guard warm.attachments.count == input.acceptedCount,
                  warm.attachments.reduce(0, { $0 + $1.data.count }) == acceptedBytes,
                  warm.attachments.allSatisfy(\.isSupportedFont) else {
                throw fail("Projection violated attachment admission invariants")
            }
            return (consume(warm), try encoded(snapshot(warm)))
        }

        var checksum: UInt64 = 0
        var last: FFmpegMediaInfo?
        let before = try usage()
        let start = DispatchTime.now().uptimeNanoseconds
        for iteration in 0..<iterations {
            try autoreleasepool {
                let info: FFmpegMediaInfo
                if mode == "projection" {
                    info = FFmpegDemuxer.makeMediaInfo(url: url, context: prepared)
                } else {
                    info = try setup(url)
                }
                checksum &+= consume(info)
                if iteration == iterations - 1 { last = info }
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let after = try usage()
        guard let last, checksum == expectedChecksum &* UInt64(iterations) else {
            throw fail("Timed output consumption did not match warm-up result")
        }
        let finalSnapshot = snapshot(last)
        guard try encoded(finalSnapshot) == expectedSnapshot else {
            throw fail("Final media-info snapshot changed during repeated projection")
        }
        let result: [String: Any] = [
            "mode": mode, "iterations": iterations, "wall_seconds": elapsed,
            "cpu_seconds": cpuSeconds(after) - cpuSeconds(before),
            "process_max_rss_bytes": after.ru_maxrss,
            "process_max_rss_before_bytes": before.ru_maxrss,
            "checksum": String(checksum), "checksum_per_iteration": String(expectedChecksum),
            "accepted_payload_bytes": acceptedBytes, "rejected_payload_bytes": rejectedBytes,
            "accepted_attachment_count": input.acceptedCount, "input_attachments": input.entries,
            "snapshot": finalSnapshot,
            "ffmpeg_version": String(cString: av_version_info()),
            "avformat_version": avformat_version(), "avcodec_version": avcodec_version(),
            "avutil_version": avutil_version()
        ]
        print(String(decoding: try encoded(result), as: UTF8.self))
    }
}
