import CFFmpeg
import CryptoKit
import Darwin
import Foundation
@testable import AttachmentProjection

private func failure(_ message: String) -> NSError {
    NSError(domain: "AuxiliaryAttachmentPolicyBenchmark", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
}

private func nullable<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
private func bits(_ value: Double) -> String { String(value.bitPattern, radix: 16) }
private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

private enum ReaderKind: String {
    case demuxer
    case executor
}

// Both variants compile this same driver against separately compiled production
// sources. Only auxiliary constructors opt out, and only in the candidate build.
private enum Reader {
    case demuxer(FFmpegDemuxer)
    case executor(FFmpegInputExecutor)

    init(url: URL, kind: ReaderKind, auxiliary: Bool) throws {
        switch kind {
        case .demuxer:
            #if OMIT_AUXILIARY_ATTACHMENTS
            if auxiliary {
                self = .demuxer(try FFmpegDemuxer(url: url, attachmentPolicy: .none))
                return
            }
            #endif
            self = .demuxer(try FFmpegDemuxer(url: url))
        case .executor:
            #if OMIT_AUXILIARY_ATTACHMENTS
            if auxiliary {
                self = .executor(try FFmpegInputExecutor(url: url, attachmentPolicy: .none))
                return
            }
            #endif
            self = .executor(try FFmpegInputExecutor(url: url))
        }
    }

    var mediaInfo: FFmpegMediaInfo {
        switch self {
        case .demuxer(let input): input.mediaInfo
        case .executor(let input): input.mediaInfo
        }
    }

    func readPacket() throws -> FFmpegPacket? {
        switch self {
        case .demuxer(let input): try input.readPacket(generation: 7)
        case .executor(let input): try input.readPacket(generation: 7)
        }
    }

    func codecSnapshot(index: Int32) throws -> [String: Any] {
        switch self {
        case .demuxer(let input):
            guard let parameters = input.codecParameters(streamIndex: index) else {
                throw failure("Missing primary codec parameters for stream \(index)")
            }
            return snapshotCodecParameters(parameters, index: index)
        case .executor(let input):
            guard let parameters = try input.copyCodecParameters(streamIndex: index),
                  let snapshot = parameters.withUnsafePointer({ snapshotCodecParameters($0, index: index) }) else {
                throw failure("Missing copied codec parameters for stream \(index)")
            }
            return snapshot
        }
    }
}

private func usage() throws -> rusage {
    var value = rusage()
    guard getrusage(RUSAGE_SELF, &value) == 0 else { throw failure("getrusage failed") }
    return value
}

private func cpuSeconds(_ value: rusage) -> Double {
    Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
        + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
}

private func liveAllocatorBytes() -> UInt64 {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return UInt64(statistics.size_in_use)
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
    let liveBytes: UInt64
    let maxRSSBytes: Int
    let primaryBytes: Int
    let auxiliaryBytes: Int
}

@inline(never)
private func measureOpening(
    _ url: URL, kind: ReaderKind, auxiliaries: Int, expectedFontBytes: Int
) throws -> OpeningMeasurement {
    // All readers coexist through the sample. Returning only scalar observations
    // releases every reader and its FFmpeg context before the caller's next sample.
    try autoreleasepool {
        var readers: [Reader] = []
        readers.reserveCapacity(auxiliaries + 1)
        let before = try usage()
        let start = DispatchTime.now().uptimeNanoseconds
        readers.append(try Reader(url: url, kind: kind, auxiliary: false))
        for _ in 0..<auxiliaries {
            readers.append(try Reader(url: url, kind: kind, auxiliary: true))
        }
        let wallSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let after = try usage()
        let liveBytes = withExtendedLifetime(readers) { liveAllocatorBytes() }
        let primaryBytes = readers[0].mediaInfo.attachments.reduce(0) { $0 + $1.data.count }
        let auxiliaryBytes = readers.dropFirst().reduce(0) { total, reader in
            total + reader.mediaInfo.attachments.reduce(0) { $0 + $1.data.count }
        }
        guard primaryBytes == expectedFontBytes,
              auxiliaryBytes == expectedAuxiliaryBytes(expectedFontBytes, count: auxiliaries) else {
            throw failure("Unexpected retained attachment bytes: primary \(primaryBytes), auxiliaries \(auxiliaryBytes)")
        }
        return withExtendedLifetime(readers) {
            OpeningMeasurement(wallSeconds: wallSeconds,
                               cpuSeconds: cpuSeconds(after) - cpuSeconds(before),
                               liveBytes: liveBytes, maxRSSBytes: Int(after.ru_maxrss),
                               primaryBytes: primaryBytes, auxiliaryBytes: auxiliaryBytes)
        }
    }
}

private func packetSnapshot(_ reader: Reader) throws -> [String: Any] {
    var packets: [[String: Any]] = []
    var streamCounts: [String: Int] = [:]
    while let packet = try reader.readPacket() {
        guard packets.count < 100_000 else { throw failure("Fixture exceeded the 100,000-packet validation bound") }
        let data = packet.data ?? Data()
        packets.append(["stream_index": packet.streamIndex,
                        "pts": packet.presentationTimestamp, "dts": packet.decodeTimestamp,
                        "duration": packet.duration,
                        "time_base": [packet.timeBase.numerator, packet.timeBase.denominator],
                        "generation": packet.generation, "corrupt": packet.isCorrupt,
                        "keyframe": packet.isKeyframe,
                        "bytes": packet.byteCount, "sha256": sha256(data)])
        streamCounts[String(packet.streamIndex), default: 0] += 1
    }
    guard !packets.isEmpty else { throw failure("Fixture did not yield any packets") }
    return ["count": packets.count, "stream_counts": streamCounts,
            "trace_sha256": sha256(try encoded(packets))]
}

private func validate(
    _ url: URL, kind: ReaderKind, auxiliaries: Int, expectedFontBytes: Int
) throws -> [String: Any] {
    try autoreleasepool {
        let primary = try Reader(url: url, kind: kind, auxiliary: false)
        let info = primary.mediaInfo
        guard !info.videoStreams.isEmpty, !info.audioStreams.isEmpty, !info.subtitleStreams.isEmpty else {
            throw failure("Expected video, audio and subtitle streams in the generated fixture")
        }
        let fonts = try FontAttachmentValidator.validated(info.attachments)
        guard fonts.reduce(0, { $0 + $1.data.count }) == expectedFontBytes,
              fonts.allSatisfy({ !$0.data.isEmpty }),
              (expectedFontBytes == 0) == fonts.isEmpty else {
            throw failure("Primary attachment admission did not match the fixture")
        }
        let metadata = metadataSnapshot(info)
        let metadataBytes = try encoded(metadata)
        let attachments = attachmentSnapshot(fonts)
        let attachmentBytes = try encoded(attachments)
        let codecs = try info.streams.map { try primary.codecSnapshot(index: $0.index) }
        let codecBytes = try encoded(codecs)
        let packets = try packetSnapshot(primary)
        let packetBytes = try encoded(packets)
        for _ in 0..<auxiliaries {
            try autoreleasepool {
                let auxiliary = try Reader(url: url, kind: kind, auxiliary: true)
                let auxiliaryInfo = auxiliary.mediaInfo
                guard try encoded(metadataSnapshot(auxiliaryInfo)) == metadataBytes else {
                    throw failure("Auxiliary media metadata differs from the primary")
                }
                #if OMIT_AUXILIARY_ATTACHMENTS
                guard auxiliaryInfo.attachments.isEmpty else {
                    throw failure("Auxiliary reader retained Swift attachment payloads under .none")
                }
                #else
                guard try encoded(attachmentSnapshot(auxiliaryInfo.attachments)) == attachmentBytes else {
                    throw failure("Baseline auxiliary fonts differ from the primary")
                }
                #endif
                let auxiliaryCodecs = try auxiliaryInfo.streams.map { try auxiliary.codecSnapshot(index: $0.index) }
                guard try encoded(auxiliaryCodecs) == codecBytes,
                      try encoded(packetSnapshot(auxiliary)) == packetBytes else {
                    throw failure("Auxiliary codec parameters, extradata or complete packet trace changed")
                }
            }
        }
        // Preserve the primary attachment digest even in the candidate; output
        // equality across builds proves the default rendering inputs are intact.
        return ["input_count": auxiliaries + 1, "metadata": metadata,
                "primary_attachments": attachments,
                "primary_attachments_sha256": sha256(attachmentBytes),
                "codec_parameters": codecs, "packets": packets,
                "auxiliary_policy_verified": true,
                "auxiliary_metadata_codec_packet_parity": true]
    }
}

@main
private enum AuxiliaryAttachmentPolicyHarness {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 5, let kind = ReaderKind(rawValue: arguments[2]),
              let auxiliaries = Int(arguments[3]), (0...16).contains(auxiliaries),
              let expectedFontBytes = Int(arguments[4]), (0...(64 * 1024 * 1024)).contains(expectedFontBytes) else {
            throw failure("Usage: harness FIXTURE demuxer|executor AUXILIARIES(0...16) EXPECTED_FONT_BYTES(0...67108864)")
        }
        av_log_set_level(AV_LOG_QUIET)
        let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        // Initialize measurement entry points before the before-open sample,
        // without opening a fixture or warming FFmpeg's parsing path.
        _ = liveAllocatorBytes()
        let before = try usage()
        let liveBefore = liveAllocatorBytes()
        let opened = try measureOpening(url, kind: kind, auxiliaries: auxiliaries,
                                        expectedFontBytes: expectedFontBytes)
        let liveAfterRelease = liveAllocatorBytes()
        let afterRelease = try usage()
        #if OMIT_AUXILIARY_ATTACHMENTS
        let variant = "candidate"
        #else
        let variant = "baseline"
        #endif
        // Hashing, JSON construction and a fresh validation cohort all happen
        // after every reported allocator/RSS observation and timed interval.
        let validation = try validate(url, kind: kind, auxiliaries: auxiliaries,
                                      expectedFontBytes: expectedFontBytes)
        let result: [String: Any] = [
            "variant": variant, "reader": kind.rawValue, "auxiliary_count": auxiliaries,
            "expected_font_bytes": expectedFontBytes,
            "opening_wall_seconds": opened.wallSeconds, "opening_cpu_seconds": opened.cpuSeconds,
            "allocator_before_bytes": liveBefore,
            "allocator_while_open_bytes": opened.liveBytes,
            "allocator_after_release_bytes": liveAfterRelease,
            "allocator_open_delta_bytes": Int64(opened.liveBytes) - Int64(liveBefore),
            "allocator_release_delta_bytes": Int64(liveAfterRelease) - Int64(liveBefore),
            "process_max_rss_before_bytes": before.ru_maxrss,
            "process_max_rss_while_open_bytes": opened.maxRSSBytes,
            "process_max_rss_after_release_bytes": afterRelease.ru_maxrss,
            "primary_retained_payload_bytes": opened.primaryBytes,
            "auxiliary_retained_payload_bytes": opened.auxiliaryBytes,
            "total_retained_payload_bytes": opened.primaryBytes + opened.auxiliaryBytes,
            "validation": validation,
        ]
        FileHandle.standardOutput.write(try encoded(result))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
