import CAuxiliaryMemory
import CFFmpeg
import CryptoKit
import Darwin
import Foundation
@testable import AuxiliaryInputs

private func failure(_ message: String) -> NSError {
    NSError(domain: "AuxiliaryFontAttachments", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
}

private enum Policy: String, CaseIterable {
    case `default`, explicit, auxiliary

    var loadsFonts: Bool {
        #if CANDIDATE
        self != .auxiliary
        #else
        true
        #endif
    }
}

private func executor(_ url: URL, policy: Policy) throws -> FFmpegInputExecutor {
    #if CANDIDATE
    switch policy {
    case .default: return try FFmpegInputExecutor(url: url)
    case .explicit: return try FFmpegInputExecutor(url: url, loadFontAttachments: true)
    case .auxiliary: return try FFmpegInputExecutor(url: url, loadFontAttachments: false)
    }
    #else
    return try FFmpegInputExecutor(url: url)
    #endif
}

private func demuxer(_ url: URL, policy: Policy) throws -> FFmpegDemuxer {
    #if CANDIDATE
    switch policy {
    case .default: return try FFmpegDemuxer(url: url)
    case .explicit: return try FFmpegDemuxer(url: url, loadFontAttachments: true)
    case .auxiliary: return try FFmpegDemuxer(url: url, loadFontAttachments: false)
    }
    #else
    return try FFmpegDemuxer(url: url)
    #endif
}

private func nullable<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
private func bits(_ value: Double) -> String { String(value.bitPattern, radix: 16) }
private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func size(_ value: CGSize?) -> Any {
    value.map { [bits(Double($0.width)), bits(Double($0.height))] as Any } ?? NSNull()
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

// Same complete media-info coverage as the prior AttachmentAdmission study.
// All payload hashing and JSON work happens in verification-only processes.
private func metadata(_ info: FFmpegMediaInfo) -> [String: Any] {
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
         "bytes": $0.data.count, "sha256": hash($0.data), "supported_font": $0.isSupportedFont]
    }
    let chapters: [[String: Any]] = info.chapters.map {
        ["title": nullable($0.title), "start_bits": bits($0.start), "end_bits": bits($0.end)]
    }
    return ["url": info.url.absoluteString, "container_name": info.containerName,
            "duration_bits": bits(info.duration), "start_time_bits": bits(info.startTime),
            "duration_status": timeline(info.durationStatus), "start_time_status": timeline(info.startTimeStatus),
            "streams": streams, "chapters": chapters, "attachments": attachments,
            "selected_video_index": nullable(info.selectedVideoIndex),
            "selected_audio_index": nullable(info.selectedAudioIndex),
            "selected_subtitle_index": nullable(info.selectedSubtitleIndex),
            "video_stream_indices": info.videoStreams.map(\.index),
            "audio_stream_indices": info.audioStreams.map(\.index),
            "subtitle_stream_indices": info.subtitleStreams.map(\.index)]
}

private func codec(_ pointer: UnsafePointer<AVCodecParameters>) -> [String: Any] {
    let value = pointer.pointee
    let extra = value.extradata.flatMap { value.extradata_size > 0 ? Data(bytes: $0, count: Int(value.extradata_size)) : nil }
    return ["codec_type": value.codec_type.rawValue, "codec_id": value.codec_id.rawValue,
            "codec_tag": value.codec_tag, "format": value.format, "bit_rate": value.bit_rate,
            "profile": value.profile, "level": value.level,
            "width": value.width, "height": value.height,
            "sample_rate": value.sample_rate, "channel_count": value.ch_layout.nb_channels,
            "extradata_bytes": value.extradata_size, "extradata_sha256": nullable(extra.map(hash))]
}

private func packet(_ value: FFmpegPacket) -> [String: Any] {
    var sideData: [[String: Any]] = []
    if let pointer = value.pointer {
        for index in 0..<Int(pointer.pointee.side_data_elems) {
            let entry = pointer.pointee.side_data[index]
            let bytes = Data(bytes: entry.data, count: entry.size)
            sideData.append(["type": entry.type.rawValue, "bytes": entry.size, "sha256": hash(bytes)])
        }
    }
    return ["stream_index": value.streamIndex, "pts": value.presentationTimestamp,
            "dts": value.decodeTimestamp, "duration": value.duration,
            "time_base": [value.timeBase.numerator, value.timeBase.denominator],
            "generation": value.generation, "corrupt": value.isCorrupt, "keyframe": value.isKeyframe,
            "position": nullable(value.pointer.map { $0.pointee.pos }),
            "flags": nullable(value.pointer.map { $0.pointee.flags }),
            "bytes": value.byteCount, "sha256": nullable(value.data.map(hash)), "side_data": sideData]
}

private enum Input {
    case direct(FFmpegDemuxer)
    case executor(FFmpegInputExecutor)

    var info: FFmpegMediaInfo {
        switch self { case .direct(let input): input.mediaInfo; case .executor(let input): input.mediaInfo }
    }

    func read(_ generation: Int) throws -> FFmpegPacket? {
        switch self {
        case .direct(let input): try input.readPacket(generation: generation)
        case .executor(let input): try input.readPacket(generation: generation)
        }
    }

    func seek(_ seconds: Double) throws {
        switch self {
        case .direct(let input): try input.seek(to: seconds, exact: true)
        case .executor(let input): try input.seek(to: seconds, exact: true)
        }
    }

    func activeSubtitle(_ stream: Int32) throws -> [FFmpegPacket] {
        switch self {
        case .direct(let input): try input.activeSubtitlePackets(streamIndex: stream, at: 0.75, generation: 13)
        case .executor(let input): try input.activeSubtitlePackets(streamIndex: stream, at: 0.75, generation: 13)
        }
    }

    func codecs() throws -> [[String: Any]] {
        try info.streams.map { stream in
            var result: [String: Any]
            switch self {
            case .direct(let input):
                guard let pointer = input.codecParameters(streamIndex: stream.index) else { throw failure("Missing codec parameters") }
                result = codec(UnsafePointer(pointer))
                result["private_data_sha256"] = nullable(input.codecPrivateData(streamIndex: stream.index).map(hash))
            case .executor(let input):
                guard let owned = try input.copyCodecParameters(streamIndex: stream.index),
                      let copied = owned.withUnsafePointer(codec) else { throw failure("Missing owned codec parameters") }
                result = copied
                result["private_data_sha256"] = nullable(input.codecPrivateData(streamIndex: stream.index).map(hash))
            }
            result["index"] = stream.index
            return result
        }
    }

    func packets(_ generation: Int) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for _ in 0..<1_000 {
            guard let next = try read(generation) else { return result }
            result.append(packet(next))
        }
        throw failure("Two-second fixture did not reach EOF in 1,000 packets")
    }
}

private func verification(_ url: URL) throws -> [String: Any] {
    var result: [String: Any] = [:]
    for backend in ["direct", "executor"] {
        var policies: [String: Any] = [:]
        for policy in Policy.allCases {
            policies[policy.rawValue] = try autoreleasepool {
                let input = backend == "direct"
                    ? Input.direct(try demuxer(url, policy: policy))
                    : Input.executor(try executor(url, policy: policy))
                _ = try FontAttachmentValidator.validated(input.info.attachments)
                let initial = try input.packets(11)
                try input.seek(0.75)
                let sought = try input.packets(12)
                guard !initial.isEmpty, !sought.isEmpty,
                      let subtitleIndex = input.info.selectedSubtitleIndex else {
                    throw failure("Expected nonempty packets and a selected subtitle")
                }
                let active = try input.activeSubtitle(subtitleIndex).map(packet)
                guard !active.isEmpty else { throw failure("Expected an active subtitle at 0.75 seconds") }
                return ["metadata": metadata(input.info), "codecs": try input.codecs(),
                        "initial_packets": initial, "seek_packets": sought,
                        "active_subtitle_packets": active] as [String: Any]
            }
        }
        result[backend] = policies
    }
    return result
}

private struct MemorySample {
    let allocator: UInt64
    let resident: UInt64
    let peak: UInt64
    let cpu: UInt64

    init() throws {
        let value = auxiliary_memory_sample()
        guard value.valid != 0, value.allocator_bytes > 0 else { throw failure("Native memory probe failed") }
        allocator = value.allocator_bytes; resident = value.resident_bytes
        peak = value.peak_resident_bytes; cpu = value.cpu_nanoseconds
    }

    var json: [String: Any] {
        ["allocator_bytes": allocator, "resident_bytes": resident,
         "peak_resident_bytes": peak, "cpu_nanoseconds": cpu]
    }
}

private func attachmentBytes(_ info: FFmpegMediaInfo) -> Int {
    info.attachments.reduce(0) { $0 + $1.data.count }
}

@inline(never)
private func consume(_ info: FFmpegMediaInfo) -> UInt64 {
    var value = info.duration.bitPattern ^ info.startTime.bitPattern
    value &+= UInt64(info.streams.count) &* 31 &+ UInt64(info.chapters.count)
    for stream in info.streams {
        value &+= UInt64(bitPattern: Int64(stream.index)) &* 7
        value &+= UInt64(bitPattern: Int64(stream.codecID)) &* 13
    }
    return value
}

@inline(never)
private func retainedInput(_ url: URL, policy: Policy) throws -> FFmpegInputExecutor {
    try autoreleasepool { try executor(url, policy: policy) }
}

@inline(never)
private func validateInputs(_ inputs: [FFmpegInputExecutor], policy: Policy,
                            fontBytes: Int, expectedChecksum: UInt64) throws -> Int {
    var retainedFontBytes = 0
    for input in inputs {
        let bytes = attachmentBytes(input.mediaInfo)
        guard bytes == (policy.loadsFonts ? fontBytes : 0), consume(input.mediaInfo) == expectedChecksum,
              !input.openWasPerformedOnMainThread else { throw failure("Input inventory or executor invariant failed") }
        retainedFontBytes += bytes
    }
    return retainedFontBytes
}

@inline(never)
private func memory(_ url: URL, policy: Policy, count: Int, fontBytes: Int) throws -> [String: Any] {
    _ = try MemorySample() // Initialize probe machinery before the first checkpoint.
    let beforeMain = try MemorySample()
    var main: FFmpegInputExecutor? = try retainedInput(url, policy: .default)
    guard attachmentBytes(main!.mediaInfo) == fontBytes else { throw failure("Main input lost fonts") }
    let expectedChecksum = consume(main!.mediaInfo)
    let afterMain = try withExtendedLifetime(main) { try MemorySample() }
    var inputs: [FFmpegInputExecutor] = []
    for _ in 0..<count { inputs.append(try retainedInput(url, policy: policy)) }
    let afterInputs = try withExtendedLifetime(main) {
        try withExtendedLifetime(inputs) { try MemorySample() }
    }
    let retainedFontBytes = try validateInputs(inputs, policy: policy, fontBytes: fontBytes,
                                              expectedChecksum: expectedChecksum)
    inputs.removeAll(keepingCapacity: false)
    let afterInputRelease = try withExtendedLifetime(main) { try MemorySample() }
    main = nil
    let afterAllRelease = try MemorySample()
    return ["before_main": beforeMain.json, "after_main": afterMain.json,
            "after_inputs": afterInputs.json, "after_input_release": afterInputRelease.json,
            "after_all_release": afterAllRelease.json,
            "retained_allocator_delta_bytes": Int64(afterInputs.allocator) - Int64(afterMain.allocator),
            "retained_resident_delta_bytes": Int64(afterInputs.resident) - Int64(afterMain.resident),
            "released_allocator_delta_bytes": Int64(afterInputRelease.allocator) - Int64(afterMain.allocator),
            "main_font_bytes": fontBytes, "auxiliary_font_bytes": retainedFontBytes,
            "metadata_checksum": String(expectedChecksum),
            "allocator_metric": "malloc_zone_statistics(NULL).size_in_use",
            "resident_metric": "task_info(MACH_TASK_BASIC_INFO).resident_size",
            "peak_metric": "getrusage(RUSAGE_SELF).ru_maxrss; captured before verification"]
}

@inline(never)
private func openAndClose(_ url: URL, policy: Policy, count: Int, fontBytes: Int) throws -> UInt64 {
    try autoreleasepool {
        var inputs: [FFmpegInputExecutor] = []
        for _ in 0..<count { inputs.append(try executor(url, policy: policy)) }
        var checksum: UInt64 = 0
        for input in inputs {
            guard attachmentBytes(input.mediaInfo) == (policy.loadsFonts ? fontBytes : 0) else {
                throw failure("Timed input inventory differs")
            }
            checksum &+= consume(input.mediaInfo)
        }
        return checksum
    }
}

private func timing(_ url: URL, policy: Policy, count: Int, iterations: Int, fontBytes: Int) throws -> [String: Any] {
    let main = try executor(url, policy: .default)
    let expected = consume(main.mediaInfo) &* UInt64(count)
    guard try openAndClose(url, policy: policy, count: count, fontBytes: fontBytes) == expected else {
        throw failure("Warmup metadata mismatch")
    }
    let before = try MemorySample()
    let started = DispatchTime.now().uptimeNanoseconds
    var checksum: UInt64 = 0
    for _ in 0..<iterations {
        checksum &+= try openAndClose(url, policy: policy, count: count, fontBytes: fontBytes)
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - started
    let after = try withExtendedLifetime(main) { try MemorySample() }
    guard checksum == expected &* UInt64(iterations) else { throw failure("Timed metadata checksum mismatch") }
    return ["wall_seconds": Double(elapsed) / 1_000_000_000,
            "cpu_seconds": Double(after.cpu - before.cpu) / 1_000_000_000,
            "checksum": String(checksum), "checksum_per_iteration": String(expected)]
}

@main
private enum AuxiliaryFontAttachmentHarness {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 7, ["verify", "memory", "timing"].contains(arguments[1]),
              let policy = Policy(rawValue: arguments[3]),
              let count = Int(arguments[4]), (1...3).contains(count),
              let iterations = Int(arguments[5]), iterations > 0,
              let fontBytes = Int(arguments[6]), fontBytes >= 0 else {
            throw failure("Usage: harness verify|memory|timing FIXTURE default|explicit|auxiliary INPUTS ITERATIONS FONT_BYTES")
        }
        av_log_set_level(AV_LOG_QUIET)
        let url = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        let mode = arguments[1]
        let payload: [String: Any]
        switch mode {
        case "verify": payload = ["traces": try verification(url)]
        case "memory": payload = try memory(url, policy: policy, count: count, fontBytes: fontBytes)
        default: payload = try timing(url, policy: policy, count: count, iterations: iterations, fontBytes: fontBytes)
        }
        var result = payload
        result.merge(["mode": mode, "policy": policy.rawValue, "inputs": count,
                      "iterations": iterations, "accepted_payload_bytes": fontBytes,
                      "loads_fonts": policy.loadsFonts,
                      "ffmpeg_version": String(cString: av_version_info()),
                      "avformat_version": avformat_version(), "avcodec_version": avcodec_version(),
                      "avutil_version": avutil_version()]) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
