import CFFmpeg
import CryptoKit
import Darwin
import Foundation
@testable import AuxiliaryFontInputs
import HeapProbe

private func fail(_ message: String) -> NSError {
    NSError(domain: "AuxiliaryFontPayloads", code: 1,
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

private func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func borrowedHash(_ pointer: UnsafeMutablePointer<UInt8>?, count: Int) -> String {
    guard let pointer, count > 0 else { return hash(Data()) }
    return hash(Data(bytesNoCopy: pointer, count: count, deallocator: .none))
}

private func roles(_ scenario: String) throws -> [Bool] {
    switch scenario {
    case "primary": return [true]
    case "auxiliary": return [false]
    case "primary-plus-one": return [true, false]
    case "primary-plus-two": return [true, false, false]
    default: throw fail("Unknown scenario")
    }
}

@inline(never)
private func openInputs(_ url: URL, primaryRoles: [Bool]) throws -> [FFmpegInputExecutor] {
    try primaryRoles.map { primary in
        // Primary calls intentionally omit the argument to test the public default.
        #if CANDIDATE
        return primary ? try FFmpegInputExecutor(url: url)
            : try FFmpegInputExecutor(url: url, includesFontAttachments: false)
        #else
        return try FFmpegInputExecutor(url: url)
        #endif
    }
}

private struct Measurement {
    let before: UInt64
    let retained: UInt64
    let released: UInt64
    let ownedFontBytes: Int
    let ownedFontCount: Int
    let openWallNanoseconds: UInt64
    let openCPUNanoseconds: UInt64
}

private final class WeakInput {
    weak var value: FFmpegInputExecutor?
    init(_ value: FFmpegInputExecutor) { self.value = value }
}

// Hashing, packet reads, copied codec parameters, and JSON diagnostics run in a
// separate untimed fixture after this function returns. Only actual open inputs
// and their production-owned metadata are alive at the retained sample.
@inline(never)
private func measure(_ url: URL, primaryRoles: [Bool]) throws -> Measurement {
    let before = auxiliary_font_live_heap_bytes()
    let cpuStart = auxiliary_font_cpu_nanoseconds()
    let start = DispatchTime.now().uptimeNanoseconds
    var inputs: [FFmpegInputExecutor]? = try autoreleasepool {
        try openInputs(url, primaryRoles: primaryRoles)
    }
    // The initializer's semaphore is signaled before its opening closure ends.
    // A barrier on that same serial queue proves the opening body has returned.
    for input in inputs! { input.waitForBenchmarkOpeningToFinish() }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let cpu = auxiliary_font_cpu_nanoseconds() - cpuStart
    let (retained, ownedBytes, ownedCount) = withExtendedLifetime(inputs) {
        (auxiliary_font_live_heap_bytes(),
         inputs!.reduce(0) { $0 + $1.mediaInfo.attachments.reduce(0) { $0 + $1.data.count } },
         inputs!.reduce(0) { $0 + $1.mediaInfo.attachments.count })
    }
    inputs = nil
    let released = auxiliary_font_live_heap_bytes()
    return Measurement(before: before, retained: retained, released: released,
                       ownedFontBytes: ownedBytes, ownedFontCount: ownedCount,
                       openWallNanoseconds: elapsed, openCPUNanoseconds: cpu)
}

private func nativeInventory(_ input: FFmpegInputExecutor) throws -> [[String: Any]] {
    guard let inventory = try input.withBenchmarkFormatContext({ context in
        (0..<Int(context.pointee.nb_streams)).compactMap { index -> [String: Any]? in
            guard let stream = context.pointee.streams[index],
                  let parameters = stream.pointee.codecpar else { return nil }
            func metadata(_ key: String) -> String? {
                key.withCString { illiquid_metadata_value(stream.pointee.metadata, $0).map(String.init(cString:)) }
            }
            let count = max(0, Int(parameters.pointee.extradata_size))
            return ["index": index, "media_type": parameters.pointee.codec_type.rawValue,
                    "codec_id": parameters.pointee.codec_id.rawValue,
                    "filename": nullable(metadata("filename")), "mime_type": nullable(metadata("mimetype")),
                    "extradata_bytes": count, "extradata_sha256": borrowedHash(parameters.pointee.extradata, count: count)]
        }
    }) else { throw fail("Native format context unexpectedly missing") }
    return inventory
}

private func codecSnapshot(_ input: FFmpegInputExecutor) throws -> [[String: Any]] {
    try input.mediaInfo.streams.map { stream in
        // Exercise both real executor paths, including attachment streams. These
        // temporary owned copies are created only in the untimed verification run.
        guard let parameters = try input.copyCodecParameters(streamIndex: stream.index),
              let receipt = parameters.withUnsafePointer({ pointer -> [String: Any] in
            let count = max(0, Int(pointer.pointee.extradata_size))
            return ["index": stream.index, "codec_id": pointer.pointee.codec_id.rawValue,
                    "media_type": pointer.pointee.codec_type.rawValue,
                    "extradata_bytes": count,
                    "extradata_sha256": borrowedHash(pointer.pointee.extradata, count: count)]
        }) else { throw fail("Owned codec parameters missing") }
        let direct = input.codecPrivateData(streamIndex: stream.index)
        let count = receipt["extradata_bytes"] as! Int
        guard (direct?.count ?? 0) == count,
              hash(direct ?? Data()) == receipt["extradata_sha256"] as? String else {
            throw fail("Owned codec parameters and direct codec-private bytes differ")
        }
        return receipt
    }
}

private func packetSnapshot(_ input: FFmpegInputExecutor) throws -> [[String: Any]] {
    var records: [[String: Any]] = []
    while let packet = try input.readPacket(generation: 17) {
        guard records.count < 4096, let pointer = packet.pointer else {
            throw fail("Unexpected packet count or missing owned packet")
        }
        let sideData: [[String: Any]] = (0..<Int(pointer.pointee.side_data_elems)).map { index in
            let entry = pointer.pointee.side_data[index]
            return ["type": entry.type.rawValue, "bytes": entry.size,
                    "sha256": borrowedHash(entry.data, count: Int(entry.size))]
        }
        records.append(["stream_index": packet.streamIndex, "pts": packet.presentationTimestamp,
                        "dts": packet.decodeTimestamp, "duration": packet.duration,
                        "time_base": [packet.timeBase.numerator, packet.timeBase.denominator],
                        "generation": packet.generation, "corrupt": packet.isCorrupt,
                        "keyframe": packet.isKeyframe, "bytes": packet.byteCount,
                        "sha256": borrowedHash(pointer.pointee.data, count: packet.byteCount),
                        "flags": pointer.pointee.flags, "position": pointer.pointee.pos,
                        "side_data": sideData])
    }
    guard !records.isEmpty else { throw fail("Fixture has no demuxed packets") }
    return records
}

@inline(never)
private func verify(_ url: URL, primaryRoles: [Bool]) throws -> [String: Any] {
    var inputs: [FFmpegInputExecutor]? = try openInputs(url, primaryRoles: primaryRoles)
    let witnesses = inputs!.map(WeakInput.init)
    // These snapshots intentionally outlive their inputs to verify Swift Data
    // ownership after AVFormatContext and its native extradata are destroyed.
    let projected = inputs!.map(\.mediaInfo)
    let before = projected.map(snapshot)
    var records: [[String: Any]] = []
    for input in inputs! {
        let native = try nativeInventory(input)
        let parameters = try codecSnapshot(input)
        let packets = try packetSnapshot(input)
        try input.seek(to: 0, exact: true)
        let replay = try packetSnapshot(input)
        records.append(["native_streams": native, "owned_codec_parameters": parameters,
                        "packets": packets, "packets_after_seek": replay,
                        "open_was_main_thread": input.openWasPerformedOnMainThread])
    }
    inputs = nil
    guard witnesses.allSatisfy({ $0.value == nil }) else {
        throw fail("Input executor survived explicit close; ownership was not qualified")
    }
    let after = projected.map(snapshot)
    guard try encoded(["values": before]) == encoded(["values": after]) else {
        throw fail("Owned projection changed after input destruction")
    }
    return ["media_info": before, "inputs": records,
            "input_destruction_verified": true, "projection_survives_input_close": true]
}

@main
private enum AuxiliaryFontPayloadHarness {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 5, let expectedFontBytes = Int(arguments[4]) else {
            throw fail("Usage: harness FIXTURE NO_FONT_WARMUP SCENARIO FONT_PAYLOAD_BYTES")
        }
        av_log_set_level(AV_LOG_QUIET)
        let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let warmup = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        let primaryRoles = try roles(arguments[3])
        _ = auxiliary_font_live_heap_bytes()
        _ = auxiliary_font_cpu_nanoseconds()
        try autoreleasepool {
            let warm = try openInputs(warmup, primaryRoles: [true, false, false])
            for input in warm {
                input.waitForBenchmarkOpeningToFinish()
                _ = try input.readPacket(generation: 0)
            }
        }
        let measured = try measure(url, primaryRoles: primaryRoles)
        #if CANDIDATE
        let expectedCopies = primaryRoles.filter { $0 }.count
        #else
        let expectedCopies = primaryRoles.count
        #endif
        guard measured.ownedFontBytes == expectedFontBytes * expectedCopies else {
            throw fail("Measured Swift font payload does not match the input-role contract")
        }
        let verification = try autoreleasepool { try verify(url, primaryRoles: primaryRoles) }
        let result: [String: Any] = [
            "scenario": arguments[3], "input_count": primaryRoles.count,
            "primary_count": primaryRoles.filter { $0 }.count,
            "font_payload_bytes_per_input": expectedFontBytes,
            "owned_swift_font_payload_bytes": measured.ownedFontBytes,
            "owned_swift_font_count": measured.ownedFontCount,
            "live_allocator_before_bytes": measured.before,
            "live_allocator_retained_bytes": measured.retained,
            "live_allocator_released_bytes": measured.released,
            "retained_allocator_delta_bytes": Int64(measured.retained) - Int64(measured.before),
            "released_allocator_delta_bytes": Int64(measured.released) - Int64(measured.before),
            "open_wall_nanoseconds": measured.openWallNanoseconds,
            "open_cpu_nanoseconds": measured.openCPUNanoseconds,
            "allocator_metric": "malloc_zone_statistics(NULL).size_in_use",
            "ffmpeg_version": String(cString: av_version_info()),
            "avformat_version": avformat_version(), "avcodec_version": avcodec_version(),
            "avutil_version": avutil_version(), "verification": verification]
        print(String(decoding: try encoded(result), as: UTF8.self))
    }
}
