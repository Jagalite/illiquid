import CFFmpeg
import CAuxiliaryHeap
import CryptoKit
import Darwin
import Foundation
@testable import AuxiliaryAttachmentProjection

private func fail(_ message: String) -> NSError {
    NSError(domain: "AuxiliaryAttachmentBenchmark", code: 1,
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
private func snapshot(_ info: FFmpegMediaInfo, includeAttachments: Bool = true) -> [String: Any] {
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
    let attachments: [[String: Any]] = includeAttachments ? info.attachments.map {
        ["filename": $0.filename, "mime_type": nullable($0.mimeType),
         "bytes": $0.data.count,
         "sha256": SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined(),
         "supported_font": $0.isSupportedFont]
    } : []
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

private enum Input {
    case executor(FFmpegInputExecutor)
    case direct(FFmpegDemuxer)

    var info: FFmpegMediaInfo {
        switch self {
        case .executor(let input): input.mediaInfo
        case .direct(let input): input.mediaInfo
        }
    }

    func read() throws -> FFmpegPacket? {
        switch self {
        case .executor(let input): try input.readPacket(generation: 17)
        case .direct(let input): try input.readPacket(generation: 17)
        }
    }

    func seekToStart() throws {
        switch self {
        case .executor(let input): try input.seek(to: info.startTime, exact: false)
        case .direct(let input): try input.seek(to: info.startTime, exact: false)
        }
    }

    func privateData(streamIndex: Int32) -> Data? {
        switch self {
        case .executor(let input): input.codecPrivateData(streamIndex: streamIndex)
        case .direct(let input): input.codecPrivateData(streamIndex: streamIndex)
        }
    }
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// Called after all memory and setup-time samples. Verification intentionally
// reads/hashes the C-owned attachment data, which must remain available even
// when the auxiliary Swift payload copies were omitted.
private func readReceipt(_ input: Input) throws -> [String: Any] {
    func packets(_ count: Int) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for _ in 0..<count {
            guard let packet = try input.read() else { break }
            let data = packet.data ?? Data()
            result.append([
                "stream_index": packet.streamIndex,
                "pts": packet.presentationTimestamp,
                "dts": packet.decodeTimestamp,
                "duration": packet.duration,
                "time_base": [packet.timeBase.numerator, packet.timeBase.denominator],
                "generation": packet.generation,
                "corrupt": packet.isCorrupt,
                "keyframe": packet.isKeyframe,
                "bytes": packet.byteCount,
                "sha256": digest(data),
            ])
        }
        return result
    }
    let first = try packets(8)
    guard !first.isEmpty else { throw fail("Fixture must produce media packets") }
    try input.seekToStart()
    let afterSeek = try packets(4)
    guard !afterSeek.isEmpty else { throw fail("Seek must preserve packet access") }
    let privateData: [[String: Any]] = input.info.streams.map { stream in
        let data = input.privateData(streamIndex: stream.index)
        return ["stream_index": stream.index, "present": data != nil,
                "bytes": data?.count ?? 0, "sha256": data.map(digest) ?? ""]
    }
    return ["first_packets": first, "packets_after_seek": afterSeek,
            "codec_private_data": privateData]
}

@inline(never)
private func openAuxiliary(_ url: URL, executor: Bool) throws -> Input {
    // The baseline has no policy parameter. The candidate uses exactly the
    // opt-out selected by production's auxiliary input call sites.
    #if CANDIDATE
    if executor {
        return .executor(try FFmpegInputExecutor(url: url, attachmentPayloadPolicy: .omit))
    }
    return .direct(try FFmpegDemuxer(url: url, attachmentPayloadPolicy: .omit))
    #else
    if executor { return .executor(try FFmpegInputExecutor(url: url)) }
    return .direct(try FFmpegDemuxer(url: url))
    #endif
}

@main
private enum AuxiliaryAttachmentHarness {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 5,
              let executorCount = Int(args[2]), (0...4).contains(executorCount),
              let directCount = Int(args[3]), (0...4).contains(directCount),
              let fontBytes = Int(args[4]), fontBytes >= 0 else {
            throw fail("Usage: harness FIXTURE AUX_EXECUTOR_COUNT AUX_DIRECT_COUNT EXPECTED_FONT_BYTES")
        }
        let url = URL(fileURLWithPath: args[1]).standardizedFileURL
        av_log_set_level(AV_LOG_QUIET)
        // Initialize measurement/serialization machinery before the retained
        // delta. No media input is opened or held by this warm-up.
        _ = auxiliary_heap_bytes()
        _ = auxiliary_resident_bytes()
        _ = auxiliary_cpu_nanoseconds()
        _ = try encoded(["warmup": true])

        let observation: [String: Any] = try autoreleasepool {
            let heapBefore = auxiliary_heap_bytes()
            let residentBefore = auxiliary_resident_bytes()
            let cpuBefore = auxiliary_cpu_nanoseconds()
            let wallBefore = DispatchTime.now().uptimeNanoseconds

            let (primary, auxiliaries): (Input, [Input]) = try autoreleasepool {
                let primary = Input.executor(try FFmpegInputExecutor(url: url))
                var auxiliaries: [Input] = []
                auxiliaries.reserveCapacity(executorCount + directCount)
                for _ in 0..<executorCount {
                    auxiliaries.append(try openAuxiliary(url, executor: true))
                }
                for _ in 0..<directCount {
                    auxiliaries.append(try openAuxiliary(url, executor: false))
                }
                return (primary, auxiliaries)
            }

            let wallAfter = DispatchTime.now().uptimeNanoseconds
            let cpuAfter = auxiliary_cpu_nanoseconds()
            let (heapRetained, residentRetained) = withExtendedLifetime((primary, auxiliaries)) {
                (auxiliary_heap_bytes(), auxiliary_resident_bytes())
            }
            guard residentBefore > 0, residentRetained > 0 else {
                throw fail("Current resident-memory query failed")
            }
            guard cpuBefore > 0, cpuAfter >= cpuBefore else {
                throw fail("Process CPU clock query failed")
            }

            let primaryBytes = primary.info.attachments.reduce(0) { $0 + $1.data.count }
            let auxiliaryBytes = auxiliaries.reduce(0) { total, input in
                total + input.info.attachments.reduce(0) { $0 + $1.data.count }
            }
            guard primaryBytes == fontBytes else { throw fail("Primary font payload changed") }
            #if CANDIDATE
            guard auxiliaryBytes == 0 else { throw fail("Auxiliary input still copies fonts") }
            #else
            guard auxiliaryBytes == fontBytes * (executorCount + directCount) else {
                throw fail("Baseline does not reproduce eager auxiliary font copies")
            }
            #endif

            let receipt: [String: Any] = [
                "primary": snapshot(primary.info),
                "auxiliary_metadata": auxiliaries.map { snapshot($0.info, includeAttachments: false) },
                "primary_reads": try readReceipt(primary),
                "auxiliary_reads": try auxiliaries.map(readReceipt),
                "ffmpeg_version": String(cString: av_version_info()),
                "avformat_version": avformat_version(),
            ]
            return [
                "receipt": receipt,
                "primary_font_bytes": primaryBytes,
                "auxiliary_font_bytes": auxiliaryBytes,
                "heap_before_bytes": heapBefore,
                "heap_retained_bytes": heapRetained,
                "heap_delta_bytes": Int64(heapRetained) - Int64(heapBefore),
                "resident_before_bytes": residentBefore,
                "resident_retained_bytes": residentRetained,
                "resident_delta_bytes": Int64(residentRetained) - Int64(residentBefore),
                "wall_seconds": Double(wallAfter - wallBefore) / 1_000_000_000,
                "cpu_seconds": Double(cpuAfter - cpuBefore) / 1_000_000_000,
            ]
        }
        print(String(decoding: try encoded(observation), as: UTF8.self))
    }
}
