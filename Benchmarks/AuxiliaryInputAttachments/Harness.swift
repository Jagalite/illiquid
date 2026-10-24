import CFFmpeg
import CryptoKit
import Darwin
import Foundation
@testable import AuxiliaryInput
import AuxiliaryHeap

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

private enum Input {
    case direct(FFmpegDemuxer)
    case executor(FFmpegInputExecutor)

    var info: FFmpegMediaInfo {
        switch self {
        case .direct(let input): input.mediaInfo
        case .executor(let input): input.mediaInfo
        }
    }

    func read() throws -> FFmpegPacket? {
        switch self {
        case .direct(let input): try input.readPacket(generation: 7)
        case .executor(let input): try input.readPacket(generation: 7)
        }
    }

    func seek() throws {
        switch self {
        case .direct(let input): try input.seek(to: 0.5, exact: true)
        case .executor(let input): try input.seek(to: 0.5, exact: true)
        }
    }

    func codecPrivate(_ index: Int32) throws -> Data? {
        switch self {
        case .direct(let input): input.codecPrivateData(streamIndex: index)
        case .executor(let input): input.codecPrivateData(streamIndex: index)
        }
    }
}

@inline(never)
private func openGroup(_ url: URL, mode: String, auxiliaryCount: Int) throws -> [Input] {
    var inputs: [Input] = [.executor(try FFmpegInputExecutor(url: url))]
    for _ in 0..<auxiliaryCount {
        #if CANDIDATE
        if mode == "executor" {
            inputs.append(.executor(try FFmpegInputExecutor(url: url, fontAttachmentLoading: .omit)))
        } else {
            inputs.append(.direct(try FFmpegDemuxer(url: url, fontAttachmentLoading: .omit)))
        }
        #else
        if mode == "executor" {
            inputs.append(.executor(try FFmpegInputExecutor(url: url)))
        } else {
            inputs.append(.direct(try FFmpegDemuxer(url: url)))
        }
        #endif
    }
    return inputs
}

private func packetSnapshot(_ input: Input) throws -> [[String: Any]] {
    var packets: [[String: Any]] = []
    for _ in 0..<4096 {
        guard let packet = try input.read() else { return packets }
        let data = packet.data ?? Data()
        packets.append(["stream": packet.streamIndex, "pts": packet.presentationTimestamp,
                        "dts": packet.decodeTimestamp, "duration": packet.duration,
                        "time_base": [packet.timeBase.numerator, packet.timeBase.denominator],
                        "generation": packet.generation, "keyframe": packet.isKeyframe,
                        "corrupt": packet.isCorrupt, "bytes": data.count,
                        "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
    }
    throw fail("Fixture did not reach EOF within its packet bound")
}

private func inputSnapshot(_ input: Input) throws -> [String: Any] {
    var result = snapshot(input.info)
    result["codec_private"] = try input.info.streams.map { stream -> [String: Any] in
        let bytes = try input.codecPrivate(stream.index)
        return ["stream": stream.index, "bytes": nullable(bytes?.count),
                "sha256": nullable(bytes.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() })]
    }
    result["packets"] = try packetSnapshot(input)
    try input.seek()
    result["seek_packets"] = try packetSnapshot(input)
    return result
}

private func cpuSeconds() -> Double {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
}

@main
private enum Main {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 6, let count = Int(arguments[3]), (0...2).contains(count),
              ["executor", "direct"].contains(arguments[2]), let expectedBytes = Int(arguments[5])
        else { throw fail("usage: harness fixture mode auxiliary-count warmup-fixture font-bytes") }
        let url = URL(fileURLWithPath: arguments[1])
        let warmup = URL(fileURLWithPath: arguments[4])
        // Initialize Foundation, FFmpeg, dispatch queues and the probes using
        // the no-attachment control. No font-heavy workload is warmed here.
        try autoreleasepool {
            let inputs = try openGroup(warmup, mode: arguments[2], auxiliaryCount: count)
            withExtendedLifetime(inputs) {
                _ = auxiliary_heap_bytes()
                _ = auxiliary_resident_bytes()
                _ = cpuSeconds()
            }
        }
        let before = auxiliary_heap_bytes()
        let residentBefore = auxiliary_resident_bytes()
        let wallStart = ProcessInfo.processInfo.systemUptime
        let cpuStart = cpuSeconds()
        // Retain the live inputs while draining temporary Objective-C objects
        // created during open. The following probes measure the surviving graph.
        let inputs = try autoreleasepool {
            try openGroup(url, mode: arguments[2], auxiliaryCount: count)
        }
        let cpu = cpuSeconds() - cpuStart
        let wall = ProcessInfo.processInfo.systemUptime - wallStart
        // Sample retained allocations before any payload hashing, packet reads,
        // codec-private copying or diagnostic serialization.
        let retained = withExtendedLifetime(inputs) { auxiliary_heap_bytes() }
        let resident = withExtendedLifetime(inputs) { auxiliary_resident_bytes() }
        guard before > 0, retained > 0, residentBefore > 0, resident > 0 else {
            throw fail("Native heap or resident-memory probe failed")
        }
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        let primaryBytes = inputs[0].info.attachments.reduce(0) { $0 + $1.data.count }
        let auxiliaryBytes = inputs.dropFirst().reduce(0) { result, input in
            result + input.info.attachments.reduce(0) { $0 + $1.data.count }
        }
        guard primaryBytes == expectedBytes else { throw fail("Primary font-byte mismatch") }
        #if CANDIDATE
        guard auxiliaryBytes == 0 else { throw fail("Candidate retained auxiliary fonts") }
        #else
        guard auxiliaryBytes == count * expectedBytes else { throw fail("Baseline font-byte mismatch") }
        #endif
        let snapshots = try inputs.map(inputSnapshot)
        let result: [String: Any] = [
            "mode": arguments[2], "auxiliary_count": count,
            "primary_font_bytes": primaryBytes, "auxiliary_font_bytes": auxiliaryBytes,
            "heap_before_bytes": before, "heap_retained_bytes": retained,
            "heap_delta_bytes": Int64(retained) - Int64(before),
            "resident_before_bytes": residentBefore, "resident_retained_bytes": resident,
            "resident_delta_bytes": Int64(resident) - Int64(residentBefore),
            "peak_rss_bytes": usage.ru_maxrss,
            "open_wall_seconds": wall, "open_cpu_seconds": cpu,
            "inputs": snapshots,
        ]
        FileHandle.standardOutput.write(try encoded(result))
        FileHandle.standardOutput.write(Data([10]))
        withExtendedLifetime(inputs) {}
    }
}

