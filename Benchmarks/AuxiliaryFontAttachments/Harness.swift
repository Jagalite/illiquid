import CFFmpeg
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
@testable import AuxiliaryAttachmentInputs

private func failure(_ message: String) -> NSError {
    NSError(domain: "AuxiliaryFontAttachments", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
}
private func nullable<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
private func bits(_ value: Double) -> String { String(value.bitPattern, radix: 16) }
private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private func encoded(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}
private func size(_ value: CGSize?) -> Any {
    guard let value else { return NSNull() }
    return [bits(Double(value.width)), bits(Double(value.height))]
}
private func timeline(_ value: FFmpegMediaInfo.TimelineValue) -> [String: Any] {
    switch value {
    case .valid(let seconds): ["status": "valid", "seconds_bits": bits(seconds)]
    case .unknown: ["status": "unknown"]
    case .invalid: ["status": "invalid"]
    }
}

// Every stored media-info/stream field except attachments, whose inventory is
// recorded separately. Exact float bits avoid a lossy decimal comparison.
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
         "interlace_mode": stream.interlaceMode.rawValue]
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
            "selected_subtitle_index": nullable(info.selectedSubtitleIndex)]
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

private struct MemorySample {
    let resident: UInt64, footprint: UInt64, heap: UInt64
    let maximumRSS: Int64

    static func capture() throws -> Self {
        var basic = mach_task_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: basic) / MemoryLayout<natural_t>.size)
        let basicStatus = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / MemoryLayout<natural_t>.size)
        let vmStatus = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        guard basicStatus == KERN_SUCCESS, vmStatus == KERN_SUCCESS else {
            throw failure("task_info failed: basic=\(basicStatus), vm=\(vmStatus)")
        }
        var allocation = malloc_statistics_t()
        // A nil zone aggregates statistics across all malloc zones.
        malloc_zone_statistics(nil, &allocation)
        return Self(resident: UInt64(basic.resident_size), footprint: UInt64(vm.phys_footprint),
                    heap: UInt64(allocation.size_in_use), maximumRSS: Int64(try usage().ru_maxrss))
    }

    var json: [String: Any] {
        ["resident_bytes": resident, "phys_footprint_bytes": footprint,
         "heap_in_use_bytes": heap, "max_rss_bytes": maximumRSS]
    }
}

private enum Reader {
    case direct(FFmpegDemuxer), executor(FFmpegInputExecutor)

    static func open(url: URL, backend: String, primary: Bool) throws -> Self {
        // Primary controls deliberately omit the new argument to exercise its
        // default. BASELINE changes only how the auxiliary request is expressed.
        if primary {
            return backend == "direct" ? .direct(try FFmpegDemuxer(url: url))
                : .executor(try FFmpegInputExecutor(url: url))
        }
        #if BASELINE
        return backend == "direct" ? .direct(try FFmpegDemuxer(url: url))
            : .executor(try FFmpegInputExecutor(url: url))
        #else
        return backend == "direct" ? .direct(try FFmpegDemuxer(url: url, includeFontAttachments: false))
            : .executor(try FFmpegInputExecutor(url: url, includeFontAttachments: false))
        #endif
    }
    var object: AnyObject {
        switch self { case .direct(let value): value; case .executor(let value): value }
    }
    var info: FFmpegMediaInfo {
        switch self { case .direct(let value): value.mediaInfo; case .executor(let value): value.mediaInfo }
    }
    func read(generation: Int) throws -> FFmpegPacket? {
        switch self {
        case .direct(let value): try value.readPacket(generation: generation)
        case .executor(let value): try value.readPacket(generation: generation)
        }
    }
    func seek() throws {
        switch self {
        case .direct(let value): try value.seek(to: 0, exact: false)
        case .executor(let value): try value.seek(to: 0, exact: false)
        }
    }
    func codecPrivateData(_ index: Int32) -> Data? {
        switch self {
        case .direct(let value): value.codecPrivateData(streamIndex: index)
        case .executor(let value): value.codecPrivateData(streamIndex: index)
        }
    }
}

private final class LifetimeProbe {
    weak var object: AnyObject?
    init(_ object: AnyObject) { self.object = object }
}

// Fixtures are short. Record their complete initial and post-seek packet streams;
// fail instead of silently truncating output when a fixture exceeds the bound.
private func packets(_ reader: Reader, generation: Int) throws -> [[String: Any]] {
    var result: [[String: Any]] = []
    while let packet = try reader.read(generation: generation) {
        guard result.count < 4_096 else { throw failure("Fixture exceeded packet trace bound") }
        let payload = packet.data
        result.append(["stream_index": packet.streamIndex,
            "pts": packet.presentationTimestamp, "dts": packet.decodeTimestamp,
            "duration": packet.duration, "generation": packet.generation,
            "time_base": [packet.timeBase.numerator, packet.timeBase.denominator],
            "is_corrupt": packet.isCorrupt, "is_keyframe": packet.isKeyframe,
            "byte_count": packet.byteCount, "sha256": nullable(payload.map(digest))])
    }
    guard !result.isEmpty else { throw failure("Fixture produced no packets") }
    return result
}

private struct Observation {
    let retained: MemorySample
    let wall: Double, cpu: Double
    let readers: [[String: Any]]
    let probes: [LifetimeProbe]
}

@inline(never)
private func observe(url: URL, backend: String, primaryRoles: [Bool], expectedBytes: Int) throws -> Observation {
    let cpuBefore = try usage()
    let started = DispatchTime.now().uptimeNanoseconds
    let readers = try autoreleasepool {
        try primaryRoles.map { try Reader.open(url: url, backend: backend, primary: $0) }
    }
    let wall = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    let cpu = cpuSeconds(try usage()) - cpuSeconds(cpuBefore)
    return try withExtendedLifetime(readers) {
        // No input preflight, warm-up, packet reads, hashing, or output snapshots
        // precede this sample: all original native owners are demonstrably live.
        let retained = try MemorySample.capture()
        let probes = readers.map { LifetimeProbe($0.object) }
        let receipts: [[String: Any]] = try readers.enumerated().map { index, reader in
            let info = reader.info
            #if BASELINE
            let includesFonts = true
            #else
            let includesFonts = primaryRoles[index]
            #endif
            let copied = info.attachments.reduce(0) { $0 + $1.data.count }
            guard copied == (includesFonts ? expectedBytes : 0),
                  info.attachments.allSatisfy(\.isSupportedFont) else {
                throw failure("Reader \(index) attachment admission mismatch")
            }
            let nonFont = metadata(info)
            let attachments: [[String: Any]] = info.attachments.map {
                ["filename": $0.filename, "mime_type": nullable($0.mimeType),
                 "bytes": $0.data.count, "sha256": digest($0.data)]
            }
            // Never request attachment extradata here: that would deliberately
            // recreate the very payload copy excluded from auxiliary readers.
            let codecPrivate: [[String: Any]] = info.streams.filter {
                [.video, .audio, .subtitle].contains($0.kind)
            }.map {
                let data = reader.codecPrivateData($0.index)
                return ["stream_index": $0.index, "bytes": data?.count ?? 0,
                        "sha256": nullable(data.map(digest))]
            }
            let initial = try packets(reader, generation: 1)
            try reader.seek()
            let sought = try packets(reader, generation: 2)
            return ["index": index, "role": primaryRoles[index] ? "primary" : "auxiliary",
                    "includes_font_attachments": includesFonts,
                    "copied_font_bytes": copied, "copied_font_count": info.attachments.count,
                    "metadata": nonFont, "metadata_sha256": digest(try encoded(nonFont)),
                    "attachments": attachments, "codec_private": codecPrivate,
                    "packet_trace": ["initial": initial, "after_seek": sought]]
        }
        return Observation(retained: retained, wall: wall, cpu: cpu, readers: receipts, probes: probes)
    }
}

@main
private enum AuxiliaryFontAttachmentsHarness {
    static func main() throws {
        let args = CommandLine.arguments
        let layouts = ["primary-only": [true], "auxiliary-only": [false],
                       "primary-plus-one": [true, false], "primary-plus-two": [true, false, false]]
        guard args.count == 5, ["direct", "executor"].contains(args[2]),
              let primaryRoles = layouts[args[3]], let expected = Int(args[4]), expected >= 0 else {
            throw failure("Usage: harness FIXTURE direct|executor primary-only|auxiliary-only|primary-plus-one|primary-plus-two EXPECTED_FONT_BYTES")
        }
        av_log_set_level(AV_LOG_QUIET)
        let url = URL(fileURLWithPath: args[1]).standardizedFileURL
        let before = try MemorySample.capture()
        let observation = try autoreleasepool {
            try observe(url: url, backend: args[2], primaryRoles: primaryRoles, expectedBytes: expected)
        }
        guard observation.probes.allSatisfy({ $0.object == nil }) else {
            throw failure("Reader survived the measured ownership scope")
        }
        // Only scalar/hash/string receipts remain. Allocator caching and these
        // receipts can keep this above `before`; no font Data or reader survives.
        let released = try MemorySample.capture()
        #if BASELINE
        let variant = "baseline"
        #else
        let variant = "candidate"
        #endif
        let output: [String: Any] = [
            "variant": variant, "backend": args[2], "layout": args[3],
            "expected_font_bytes": expected, "reader_count": primaryRoles.count,
            "readers_released": true, "open_wall_seconds": observation.wall, "open_cpu_seconds": observation.cpu,
            "memory": ["before": before.json, "retained": observation.retained.json, "after_release": released.json],
            "readers": observation.readers,
            "ffmpeg": ["version": String(cString: av_version_info()), "avformat_version": avformat_version(),
                       "avcodec_version": avcodec_version(), "avutil_version": avutil_version()]
        ]
        print(String(decoding: try encoded(output), as: UTF8.self))
    }
}
