import AudioToolbox
import CAudioPCMProbe
import CoreMedia
import CryptoKit
import Foundation

private struct Workload {
    let name: String
    let channels: Int
    let samples: Int
    let rate: Int
    let storage: String

    init(name: String, channels: Int, samples: Int, rate: Int, storage: String = "owned") {
        self.name = name
        self.channels = channels
        self.samples = samples
        self.rate = rate
        self.storage = storage
    }

    var bytes: Int { channels * samples * MemoryLayout<Float>.size }
}

private let ownedWorkloads: [Workload] = [1, 2, 6, 8].flatMap { channels in
    [1, 128, 1_024, 8_192].map { samples in
        Workload(name: "c\(channels)-s\(samples)", channels: channels, samples: samples, rate: 48_000)
    }
}

private let workloads: [Workload] = ownedWorkloads + [1, 2, 6, 8].flatMap { channels in
    [1_024, 8_192].flatMap { samples in
        ["resampler-spare", "trimmed"].map { storage in
            Workload(name: "c\(channels)-s\(samples)-\(storage)", channels: channels,
                     samples: samples, rate: 48_000, storage: storage)
        }
    }
} + [Workload(name: "c2-s1024-huge-parent", channels: 2, samples: 1_024,
              rate: 48_000, storage: "huge-parent")]

private struct HarnessFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw HarnessFailure(message) }
}

private func emit(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// Fixture construction only. The complete production makeSampleBuffer method
// receives an actual native format description; its own format checks still run.
// Decoder channel-label mapping is qualified by the app tests, not this fixture.
private func formatDescription(channels: Int, rate: Int = 48_000) throws -> CMAudioFormatDescription {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(channels * MemoryLayout<Float>.size),
        mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * MemoryLayout<Float>.size),
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0
    )
    var format: CMAudioFormatDescription?
    try checkOSStatus(CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format), operation: "Create benchmark audio format")
    guard let format else { throw HarnessFailure("Missing benchmark audio format") }
    return format
}

private func payload(_ workload: Workload, ordinal: Int = 0) -> Data {
    let offset: Int
    let capacity: Int
    switch workload.storage {
    case "resampler-spare":
        offset = 0
        capacity = workload.bytes + max(workload.bytes / 4, workload.channels * 256 * 4)
    case "trimmed":
        offset = workload.bytes * 3
        capacity = offset + workload.bytes
    case "huge-parent":
        offset = 4_096
        capacity = 8 * 1_024 * 1_024
    default:
        offset = 0
        capacity = workload.bytes
    }
    var data = Data(count: capacity)
    data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
        for index in 0..<(workload.bytes / MemoryLayout<Float>.size) {
            // Authored finite IEEE-754 samples. Every frame differs, preventing
            // identical-payload sharing from masquerading as an allocation win.
            let word = UInt32(0x3e00_0000) | UInt32((index &* 257 &+ ordinal &* 17) & 0x007f_ffff)
            bytes.storeBytes(of: word, toByteOffset: offset + index * 4, as: UInt32.self)
        }
    }
    switch workload.storage {
    case "resampler-spare":
        // AudioDecoder allocates capacity from swr_get_out_samples then shrinks
        // the Data count after conversion; the allocator can retain slack.
        data.count = workload.bytes
        return data
    case "trimmed":
        // This spelling matches NativeDecodedAudioFrame.trimmingSamples.
        return Data(data.dropFirst(offset))
    case "huge-parent":
        // Pathological diagnostic: source view is 8 KiB of an 8 MiB parent.
        return data[offset..<(offset + workload.bytes)]
    default: return data
    }
}

private func frame(_ workload: Workload, data: Data, ordinal: Int = 0) -> NativeDecodedAudioFrame {
    NativeDecodedAudioFrame(
        interleavedFloatPCM: data,
        presentationTime: CMTime(value: Int64(123 + ordinal * workload.samples), timescale: Int32(workload.rate)),
        duration: CMTime(value: Int64(workload.samples), timescale: Int32(workload.rate)),
        generation: 7, sampleRate: workload.rate, channelCount: workload.channels,
        sampleCount: workload.samples, sourceSampleRate: workload.rate,
        sourceChannelCount: workload.channels, sourceChannelLayout: "fixture",
        downmixOccurred: false, conversionOccurred: false
    )
}

@inline(never)
private func frames(_ workload: Workload, count: Int) -> [NativeDecodedAudioFrame] {
    (0..<count).map { frame(workload, data: payload(workload, ordinal: $0), ordinal: $0) }
}

@inline(never)
private func samples(_ frames: [NativeDecodedAudioFrame], format: CMAudioFormatDescription) throws -> [CMSampleBuffer] {
    try frames.map { frame in
        try autoreleasepool {
            try SampleBufferAudioPresenter.makeSampleBuffer(frame, formatDescription: format)
        }
    }
}

private func contents(_ sample: CMSampleBuffer) throws -> Data {
    guard let block = CMSampleBufferGetDataBuffer(sample) else {
        throw HarnessFailure("Missing audio data block")
    }
    var bytes = Data(count: CMBlockBufferGetDataLength(block))
    let status = bytes.withUnsafeMutableBytes { destination in
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: destination.count,
                                  destination: destination.baseAddress!)
    }
    try checkOSStatus(status, operation: "Read benchmark audio sample")
    return bytes
}

private func timeReceipt(_ time: CMTime) -> [String: Any] {
    ["value": time.value, "timescale": time.timescale,
     "flags": time.flags.rawValue, "epoch": time.epoch]
}

private func receipt(_ sample: CMSampleBuffer, expected: NativeDecodedAudioFrame) throws -> [String: Any] {
    let actual = try contents(sample)
    try require(actual == expected.interleavedFloatPCM, "PCM bytes differ")
    try require(CMSampleBufferGetNumSamples(sample) == expected.sampleCount, "Sample count differs")
    try require(CMSampleBufferGetPresentationTimeStamp(sample) == expected.presentationTime, "Presentation time differs")
    try require(CMSampleBufferGetSampleSize(sample, at: 0) == expected.channelCount * 4, "Sample size differs")
    var timing = CMSampleTimingInfo()
    try checkOSStatus(CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing),
                      operation: "Read benchmark sample timing")
    try require(timing.duration == CMTime(value: 1, timescale: Int32(expected.sampleRate)), "Sample duration differs")
    guard let format = CMSampleBufferGetFormatDescription(sample),
          let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
        throw HarnessFailure("Missing returned audio format")
    }
    try require(description.mSampleRate == Double(expected.sampleRate), "Returned rate differs")
    try require(description.mChannelsPerFrame == UInt32(expected.channelCount), "Returned channels differ")
    return ["pcm_sha256": digest(actual), "byte_count": actual.count,
            "sample_count": CMSampleBufferGetNumSamples(sample),
            "sample_size": CMSampleBufferGetSampleSize(sample, at: 0),
            "presentation_time": timeReceipt(timing.presentationTimeStamp),
            "decode_time": timeReceipt(timing.decodeTimeStamp),
            "sample_duration": timeReceipt(timing.duration),
            "sample_rate": description.mSampleRate,
            "channels": description.mChannelsPerFrame,
            "format_id": description.mFormatID, "format_flags": description.mFormatFlags]
}

private func sharesBacking(_ sample: CMSampleBuffer, frame: NativeDecodedAudioFrame) throws -> Bool {
    guard let block = CMSampleBufferGetDataBuffer(sample) else { throw HarnessFailure("Missing block") }
    var pointer: UnsafeMutablePointer<Int8>?
    var length = 0
    try checkOSStatus(CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                                totalLengthOut: &length, dataPointerOut: &pointer),
                      operation: "Inspect benchmark sample address")
    return frame.interleavedFloatPCM.withUnsafeBytes { bytes in
        length == bytes.count && UnsafeRawPointer(pointer) == bytes.baseAddress
    }
}

private func verify() throws {
    var records: [[String: Any]] = []
    for workload in workloads {
        let format = try formatDescription(channels: workload.channels)
        for storage in ["original", "slice", "copied-from-mutable"] {
            let expected = payload(workload)
            var original: Data
            switch storage {
            case "slice":
                var padded = Data(repeating: 0xAA, count: workload.bytes + 13)
                padded.replaceSubrange(5..<(5 + workload.bytes), with: expected)
                original = padded[5..<(5 + workload.bytes)]
            case "copied-from-mutable":
                let mutable = NSMutableData(data: expected)
                original = mutable as Data
            default: original = expected
            }
            let input = frame(workload, data: original)
            let sample = try autoreleasepool {
                try SampleBufferAudioPresenter.makeSampleBuffer(input, formatDescription: format)
            }
            let before = try receipt(sample, expected: input)
            original[original.startIndex] ^= 0xFF
            try require(try contents(sample) == expected, "Mutating original Data changes retained sample")
            records.append(["case": workload.name, "storage": storage, "result": before])
        }

        // Let every source frame and its Data disappear before checking output.
        // Expected bytes are reconstructed independently after that boundary.
        let retained: CMSampleBuffer = try autoreleasepool {
            let source = frame(workload, data: payload(workload, ordinal: 19), ordinal: 19)
            return try SampleBufferAudioPresenter.makeSampleBuffer(source, formatDescription: format)
        }
        records.append(["case": workload.name, "storage": "source-released",
                        "result": try receipt(retained, expected: frame(workload, data: payload(workload, ordinal: 19), ordinal: 19))])
    }

    let good = Workload(name: "validation", channels: 2, samples: 128, rate: 48_000)
    let format = try formatDescription(channels: 2)
    let malformed: [(String, Workload, Data, CMAudioFormatDescription)] = [
        ("zero-samples", Workload(name: "", channels: 2, samples: 0, rate: 48_000), Data(), format),
        ("wrong-byte-count", good, Data(count: 3), format),
        ("unsupported-channels", Workload(name: "", channels: 3, samples: 128, rate: 48_000), Data(count: 1_536), format),
        ("mismatched-format-channels", good, payload(good), try formatDescription(channels: 1)),
        ("mismatched-format-rate", good, payload(good), try formatDescription(channels: 2, rate: 44_100))
    ]
    var errors: [[String: String]] = []
    for (name, workload, data, description) in malformed {
        do {
            _ = try SampleBufferAudioPresenter.makeSampleBuffer(frame(workload, data: data), formatDescription: description)
            throw HarnessFailure("Invalid frame was accepted: \(name)")
        } catch let failure as HarnessFailure {
            throw failure
        } catch {
            errors.append(["case": name, "error": error.localizedDescription])
        }
    }
    try emit(["outputs": records, "errors": errors, "authored_cases": records.count + errors.count])
}

@inline(never)
private func oneOperation(_ frame: NativeDecodedAudioFrame, format: CMAudioFormatDescription) throws -> UInt64 {
    try autoreleasepool {
        let sample = try SampleBufferAudioPresenter.makeSampleBuffer(frame, formatDescription: format)
        return UInt64(CMSampleBufferGetNumSamples(sample))
            &+ UInt64(CMSampleBufferGetTotalSampleSize(sample))
    }
}

private func memoryObservation(_ workload: Workload, format: CMAudioFormatDescription, count: Int) throws -> [String: Any] {
    let initial = audio_pcm_heap_bytes()
    var source: [NativeDecodedAudioFrame]? = autoreleasepool { frames(workload, count: count) }
    let withSource = withExtendedLifetime(source) { audio_pcm_heap_bytes() }
    var retained: [CMSampleBuffer]? = try autoreleasepool { try samples(source!, format: format) }
    let withBoth = withExtendedLifetime(source) {
        withExtendedLifetime(retained) { audio_pcm_heap_bytes() }
    }
    var shared = 0
    for index in 0..<count {
        if try sharesBacking(retained![index], frame: source![index]) { shared += 1 }
    }
    source = nil
    let sampleOnly = withExtendedLifetime(retained) { audio_pcm_heap_bytes() }
    // Read all bytes after originals disappear. These allocations occur after
    // the sample-only reading and are released before the final heap reading.
    try autoreleasepool {
        for index in 0..<count {
            let actual = try contents(retained![index])
            try require(actual == payload(workload, ordinal: index), "Retained memory fixture differs after source release")
        }
    }
    retained = nil
    let released = audio_pcm_heap_bytes()
    return ["metric": "malloc_zone_statistics(NULL).size_in_use", "retained_frames": count,
            "source_storage": workload.storage,
            "payload_bytes_per_frame": workload.bytes,
            "initial_bytes": initial, "with_source_bytes": withSource,
            "with_source_and_samples_bytes": withBoth,
            "samples_only_bytes": sampleOnly, "released_bytes": released,
            "overlap_increment_bytes": Int64(withBoth) - Int64(withSource),
            "source_increment_bytes": Int64(withSource) - Int64(initial),
            "samples_only_increment_bytes": Int64(sampleOnly) - Int64(initial),
            "released_increment_bytes": Int64(released) - Int64(initial),
            "samples_sharing_source_address": shared]
}

private func observe(_ workload: Workload, iterations: Int, retainedCount: Int) throws {
    let format = try formatDescription(channels: workload.channels)
    let input = frames(workload, count: 16)
    var warmup: UInt64 = 0
    for index in 0..<512 {
        warmup &+= try oneOperation(input[index % input.count], format: format)
    }
    var checksum: UInt64 = 0
    let startCPU = audio_pcm_process_cpu_ns()
    let startWall = DispatchTime.now().uptimeNanoseconds
    for index in 0..<iterations {
        checksum &+= try oneOperation(input[index % input.count], format: format)
    }
    let wall = DispatchTime.now().uptimeNanoseconds - startWall
    let cpu = audio_pcm_process_cpu_ns() - startCPU
    let expected = UInt64(iterations) * UInt64(workload.samples + workload.bytes)
    try require(checksum == expected, "Timed output checksum differs")
    let memory = try memoryObservation(workload, format: format, count: retainedCount)
    try emit(["case": workload.name, "channels": workload.channels, "samples": workload.samples,
              "source_storage": workload.storage,
              "iterations": iterations, "wall_ns": wall, "cpu_ns": cpu,
              "checksum": checksum, "warmup_checksum": warmup, "memory": memory])
    withExtendedLifetime(input) {}
}

@main
private enum Main {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["verify"] { try verify(); return }
        guard args.count == 4, args[0] == "observe",
              let workload = workloads.first(where: { $0.name == args[1] }),
              let iterations = Int(args[2]), iterations > 0,
              let count = Int(args[3]), count > 0 else {
            throw HarnessFailure("Usage: benchmark verify | observe CASE ITERATIONS RETAINED_COUNT")
        }
        try observe(workload, iterations: iterations, retainedCount: count)
    }
}
