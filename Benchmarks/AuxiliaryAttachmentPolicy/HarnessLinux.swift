import CFFmpeg
import Glibc
import Foundation
@testable import AttachmentProjection

private func failure(_ message: String) -> NSError {
    NSError(domain: "AuxiliaryAttachmentProjectionLinux", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
}

private func nullable<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
private func bits(_ value: Double) -> String { String(value.bitPattern, radix: 16) }
private func sha256(_ data: Data) -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = data.withUnsafeBytes { input in
        auxiliary_study_sha256(input.baseAddress?.assumingMemoryBound(to: UInt8.self), input.count, &bytes)
    }
    precondition(status == 0, "SHA-256 allocation failed")
    return bytes.map { String(format: "%02x", $0) }.joined()
}
private func encoded(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

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

// Every stored media-info/stream field other than the deliberately optional
// attachment copies. Float fields retain exact bits. Validation is untimed and
// runs only after the measured cohort has closed and its counters are captured.
private func metadataSnapshot(_ info: FFmpegMediaInfo) -> [String: Any] {
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
    let chapters: [[String: Any]] = info.chapters.map {
        ["title": nullable($0.title), "start_bits": bits($0.start), "end_bits": bits($0.end)]
    }
    return ["url": info.url.absoluteString, "container_name": info.containerName,
            "duration_bits": bits(info.duration), "start_time_bits": bits(info.startTime),
            "duration_status": timeline(info.durationStatus), "start_time_status": timeline(info.startTimeStatus),
            "streams": streams, "chapters": chapters,
            "selected_video_index": nullable(info.selectedVideoIndex),
            "selected_audio_index": nullable(info.selectedAudioIndex),
            "selected_subtitle_index": nullable(info.selectedSubtitleIndex),
            "video_stream_indices": info.videoStreams.map(\.index),
            "audio_stream_indices": info.audioStreams.map(\.index),
            "subtitle_stream_indices": info.subtitleStreams.map(\.index)]
}

private func attachmentSnapshot(_ attachments: [FontAttachment]) -> [[String: Any]] {
    attachments.map {
        ["filename": $0.filename, "mime_type": nullable($0.mimeType),
         "bytes": $0.data.count, "sha256": sha256($0.data), "supported_font": $0.isSupportedFont]
    }
}

private func snapshotCodecParameters(
    _ pointer: UnsafePointer<AVCodecParameters>, index: Int32
) -> [String: Any] {
    let value = pointer.pointee
    let extra = if let bytes = value.extradata, value.extradata_size > 0 {
        Data(bytesNoCopy: UnsafeMutableRawPointer(bytes), count: Int(value.extradata_size), deallocator: .none)
    } else { Data() }
    // Hash the original extradata while its owner is alive. No codec-header or
    // attachment payload copies survive this validation snapshot.
    return ["index": index, "codec_type": value.codec_type.rawValue,
            "codec_id": value.codec_id.rawValue, "codec_tag": value.codec_tag,
            "format": value.format, "bit_rate": value.bit_rate,
            "bits_per_coded_sample": value.bits_per_coded_sample,
            "bits_per_raw_sample": value.bits_per_raw_sample,
            "profile": value.profile, "level": value.level,
            "width": value.width, "height": value.height,
            "sample_aspect_ratio": [value.sample_aspect_ratio.num, value.sample_aspect_ratio.den],
            "sample_rate": value.sample_rate, "channel_count": value.ch_layout.nb_channels,
            "block_align": value.block_align, "frame_size": value.frame_size,
            "initial_padding": value.initial_padding, "trailing_padding": value.trailing_padding,
            "seek_preroll": value.seek_preroll,
            "extradata_bytes": extra.count, "extradata_sha256": sha256(extra)]
}

// This is a real FFmpeg open/probe plus the exact extracted production
// projection. It does not stand in for the full demuxer or input executor.
private final class ProjectedInput {
    private var context: UnsafeMutablePointer<AVFormatContext>?
    let mediaInfo: FFmpegMediaInfo

    init(url: URL, auxiliary: Bool) throws {
        var opened: UnsafeMutablePointer<AVFormatContext>?
        let result = url.path.withCString { avformat_open_input(&opened, $0, nil, nil) }
        guard result >= 0, let ready = opened else {
            avformat_close_input(&opened)
            throw failure("FFmpeg open failed: \(result)")
        }
        let probe = avformat_find_stream_info(ready, nil)
        guard probe >= 0 else {
            avformat_close_input(&opened)
            throw failure("FFmpeg stream probe failed: \(probe)")
        }
        context = ready
        #if OMIT_AUXILIARY_ATTACHMENTS
        mediaInfo = FFmpegProjection.makeMediaInfo(url: url, context: ready,
                                                   attachmentPolicy: auxiliary ? .none : .supportedFonts)
        #else
        mediaInfo = FFmpegProjection.makeMediaInfo(url: url, context: ready)
        #endif
    }

    deinit { avformat_close_input(&context) }

    func codecSnapshots() throws -> [[String: Any]] {
        guard let context else { throw failure("Closed input") }
        return try mediaInfo.streams.map { stream in
            guard let input = context.pointee.streams[Int(stream.index)],
                  let parameters = input.pointee.codecpar else {
                throw failure("Missing codec parameters for stream \(stream.index)")
            }
            return snapshotCodecParameters(UnsafePointer(parameters), index: stream.index)
        }
    }

    func packetSnapshot() throws -> [String: Any] {
        guard let context else { throw failure("Closed input") }
        var packet = av_packet_alloc()
        guard let buffer = packet else { throw failure("Packet allocation failed") }
        defer { av_packet_free(&packet) }
        var packets: [[String: Any]] = []
        var streamCounts: [String: Int] = [:]
        while true {
            let result = av_read_frame(context, buffer)
            if result == auxiliary_study_averror_eof() { break }
            guard result >= 0 else { throw failure("Read packet failed: \(result)") }
            guard packets.count < 100_000 else { throw failure("Packet validation bound exceeded") }
            let value = buffer.pointee
            guard value.stream_index >= 0, value.stream_index < context.pointee.nb_streams,
                  let stream = context.pointee.streams[Int(value.stream_index)] else {
                throw failure("Invalid packet stream")
            }
            let payload = if let bytes = value.data, value.size > 0 {
                Data(bytesNoCopy: UnsafeMutableRawPointer(bytes), count: Int(value.size), deallocator: .none)
            } else { Data() }
            packets.append(["stream_index": value.stream_index, "pts": value.pts,
                            "dts": value.dts, "duration": value.duration,
                            "time_base": [stream.pointee.time_base.num, stream.pointee.time_base.den],
                            "flags": value.flags, "bytes": value.size, "sha256": sha256(payload)])
            streamCounts[String(value.stream_index), default: 0] += 1
            av_packet_unref(buffer)
        }
        guard !packets.isEmpty else { throw failure("Fixture yielded no packets") }
        return ["count": packets.count, "stream_counts": streamCounts,
                "trace_sha256": sha256(try encoded(packets))]
    }
}

private func usage() throws -> rusage {
    var result = rusage()
    guard getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &result) == 0 else {
        throw failure("getrusage failed")
    }
    return result
}

private func cpuSeconds(_ value: rusage) -> Double {
    Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
        + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
}

private func expectedAuxiliaryBytes(_ fontBytes: Int, count: Int) -> Int {
    #if OMIT_AUXILIARY_ATTACHMENTS
    return 0
    #else
    return fontBytes * count
    #endif
}

private struct OpeningMeasurement {
    let wallSeconds: Double
    let cpuSeconds: Double
    let live: auxiliary_study_heap_statistics
    let maxRSSBytes: Int
    let primaryBytes: Int
    let auxiliaryBytes: Int
}

@inline(never)
private func measureOpening(_ url: URL, auxiliaries: Int, expectedFontBytes: Int) throws -> OpeningMeasurement {
    var inputs: [ProjectedInput] = []
    inputs.reserveCapacity(auxiliaries + 1)
    let before = try usage()
    let start = DispatchTime.now().uptimeNanoseconds
    inputs.append(try ProjectedInput(url: url, auxiliary: false))
    for _ in 0..<auxiliaries { inputs.append(try ProjectedInput(url: url, auxiliary: true)) }
    let wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    let after = try usage()
    let live = withExtendedLifetime(inputs) { auxiliary_study_heap() }
    let primaryBytes = inputs[0].mediaInfo.attachments.reduce(0) { $0 + $1.data.count }
    let auxiliaryBytes = inputs.dropFirst().reduce(0) { total, input in
        total + input.mediaInfo.attachments.reduce(0) { $0 + $1.data.count }
    }
    guard primaryBytes == expectedFontBytes,
          auxiliaryBytes == expectedAuxiliaryBytes(expectedFontBytes, count: auxiliaries) else {
        throw failure("Retained-byte mismatch: primary=\(primaryBytes), auxiliary=\(auxiliaryBytes)")
    }
    // The returned value contains only scalar measurements. No projected info,
    // Data payload or AVFormatContext outlives this function's cohort.
    return withExtendedLifetime(inputs) {
        OpeningMeasurement(wallSeconds: wall, cpuSeconds: cpuSeconds(after) - cpuSeconds(before),
                           live: live, maxRSSBytes: Int(after.ru_maxrss) * 1024,
                           primaryBytes: primaryBytes, auxiliaryBytes: auxiliaryBytes)
    }
}

private func validate(_ url: URL, auxiliaries: Int, expectedFontBytes: Int) throws -> [String: Any] {
    let primary = try ProjectedInput(url: url, auxiliary: false)
    let info = primary.mediaInfo
    guard !info.videoStreams.isEmpty, !info.audioStreams.isEmpty, !info.subtitleStreams.isEmpty else {
        throw failure("Fixture lacks expected video/audio/subtitle streams")
    }
    let fonts = try FontAttachmentValidator.validated(info.attachments)
    guard fonts.reduce(0, { $0 + $1.data.count }) == expectedFontBytes,
          fonts.allSatisfy({ !$0.data.isEmpty }), (expectedFontBytes == 0) == fonts.isEmpty else {
        throw failure("Primary fonts did not match fixture")
    }
    let metadata = metadataSnapshot(info)
    let metadataBytes = try encoded(metadata)
    let attachments = attachmentSnapshot(fonts)
    let attachmentBytes = try encoded(attachments)
    let codecs = try primary.codecSnapshots()
    let codecBytes = try encoded(codecs)
    let packets = try primary.packetSnapshot()
    let packetBytes = try encoded(packets)
    for _ in 0..<auxiliaries {
        let auxiliary = try ProjectedInput(url: url, auxiliary: true)
        let auxiliaryInfo = auxiliary.mediaInfo
        guard try encoded(metadataSnapshot(auxiliaryInfo)) == metadataBytes else {
            throw failure("Auxiliary metadata differs")
        }
        #if OMIT_AUXILIARY_ATTACHMENTS
        guard auxiliaryInfo.attachments.isEmpty else { throw failure("Auxiliary retained attachments under .none") }
        #else
        guard try encoded(attachmentSnapshot(auxiliaryInfo.attachments)) == attachmentBytes else {
            throw failure("Baseline auxiliary font contents differ")
        }
        #endif
        guard try encoded(auxiliary.codecSnapshots()) == codecBytes,
              try encoded(auxiliary.packetSnapshot()) == packetBytes else {
            throw failure("Auxiliary codec/extradata/packet output differs")
        }
    }
    return ["input_count": auxiliaries + 1, "metadata": metadata,
            "primary_attachments": attachments, "primary_attachments_sha256": sha256(attachmentBytes),
            "codec_parameters": codecs, "packets": packets,
            "auxiliary_policy_verified": true, "auxiliary_metadata_codec_packet_parity": true]
}

@main
private enum AuxiliaryAttachmentProjectionLinuxHarness {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, let auxiliaries = Int(arguments[2]), (0...16).contains(auxiliaries),
              let fontBytes = Int(arguments[3]), (0...(64 * 1024 * 1024)).contains(fontBytes) else {
            throw failure("Usage: harness FIXTURE AUXILIARIES EXPECTED_FONT_BYTES")
        }
        av_log_set_level(AV_LOG_QUIET)
        let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        _ = auxiliary_study_heap()
        let before = try usage()
        let liveBefore = auxiliary_study_heap()
        let opened = try measureOpening(url, auxiliaries: auxiliaries, expectedFontBytes: fontBytes)
        let liveAfterRelease = auxiliary_study_heap()
        let afterRelease = try usage()
        #if OMIT_AUXILIARY_ATTACHMENTS
        let variant = "candidate"
        #else
        let variant = "baseline"
        #endif
        let validation = try validate(url, auxiliaries: auxiliaries, expectedFontBytes: fontBytes)
        let result: [String: Any] = [
            "scope": "actual_ffmpeg_open_probe_plus_extracted_production_projection",
            "variant": variant, "auxiliary_count": auxiliaries, "expected_font_bytes": fontBytes,
            "opening_wall_seconds": opened.wallSeconds, "opening_cpu_seconds": opened.cpuSeconds,
            "allocator_before_bytes": liveBefore.total_bytes,
            "allocator_while_open_bytes": opened.live.total_bytes,
            "allocator_after_release_bytes": liveAfterRelease.total_bytes,
            "allocator_while_open_arena_bytes": opened.live.arena_used_bytes,
            "allocator_while_open_mmap_bytes": opened.live.mmap_bytes,
            "allocator_open_delta_bytes": Int64(opened.live.total_bytes) - Int64(liveBefore.total_bytes),
            "allocator_release_delta_bytes": Int64(liveAfterRelease.total_bytes) - Int64(liveBefore.total_bytes),
            "process_max_rss_before_bytes": before.ru_maxrss * 1024,
            "process_max_rss_while_open_bytes": opened.maxRSSBytes,
            "process_max_rss_after_release_bytes": afterRelease.ru_maxrss * 1024,
            "primary_retained_payload_bytes": opened.primaryBytes,
            "auxiliary_retained_payload_bytes": opened.auxiliaryBytes,
            "total_retained_payload_bytes": opened.primaryBytes + opened.auxiliaryBytes,
            "validation": validation,
        ]
        FileHandle.standardOutput.write(try encoded(result))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
