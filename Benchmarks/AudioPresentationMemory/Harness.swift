import AudioToolbox
import CoreMedia
import CryptoKit
import Darwin
import Foundation

private struct Scenario {
    let name: String
    let samples: Int
    let channels: Int
    let buffers: Int
    let shared: Bool

    static let all = [
        Scenario(name: "mono-inline", samples: 1, channels: 1, buffers: 48, shared: false),
        Scenario(name: "stereo-small", samples: 16, channels: 2, buffers: 48, shared: false),
        Scenario(name: "stereo-1024", samples: 1_024, channels: 2, buffers: 48, shared: false),
        Scenario(name: "surround6-1024", samples: 1_024, channels: 6, buffers: 48, shared: false),
        Scenario(name: "surround8-1024", samples: 1_024, channels: 8, buffers: 48, shared: false),
        Scenario(name: "stereo-4096", samples: 4_096, channels: 2, buffers: 48, shared: false),
        Scenario(name: "surround8-4096", samples: 4_096, channels: 8, buffers: 48, shared: false),
        Scenario(name: "stereo-silence", samples: 1_024, channels: 2, buffers: 48, shared: true),
        Scenario(name: "surround8-silence", samples: 1_024, channels: 8, buffers: 48, shared: true),
        Scenario(name: "surround8-delay-stress", samples: 1_024, channels: 8, buffers: 469, shared: true),
    ]
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw PresentationError(message) }
}

private func makeFormat(rate: Int, channels: Int) throws -> CMAudioFormatDescription {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(channels * 4), mChannelsPerFrame: UInt32(channels),
        mBitsPerChannel: 32, mReserved: 0
    )
    var format: CMAudioFormatDescription?
    try checkOSStatus(CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format
    ), operation: "Create component format")
    guard let format else { throw PresentationError("Missing component format") }
    return format
}

private func makePCM(samples: Int, channels: Int, seed: Int) -> Data {
    var data = Data(count: samples * channels * 4)
    data.withUnsafeMutableBytes { raw in
        let values = raw.bindMemory(to: Float.self)
        for index in values.indices {
            values[index] = Float(((index + seed) % 257) - 128) / 256
        }
    }
    return data
}

private func frame(_ data: Data, samples: Int, channels: Int, index: Int = 0,
                   rate: Int = 48_000) -> NativeDecodedAudioFrame {
    NativeDecodedAudioFrame(
        interleavedFloatPCM: data,
        presentationTime: CMTime(value: Int64(index * samples - 137), timescale: Int32(rate)),
        duration: CMTime(value: Int64(samples), timescale: Int32(rate)),
        generation: 1, sampleRate: rate, channelCount: channels, sampleCount: samples,
        sourceSampleRate: rate, sourceChannelCount: channels,
        sourceChannelLayout: "component", downmixOccurred: false, conversionOccurred: false
    )
}

private func fixtures(_ scenario: Scenario) -> [NativeDecodedAudioFrame] {
    let silence = Data(count: scenario.samples * scenario.channels * 4)
    return (0..<scenario.buffers).map {
        frame(scenario.shared ? silence : makePCM(samples: scenario.samples, channels: scenario.channels, seed: $0),
              samples: scenario.samples, channels: scenario.channels, index: $0)
    }
}

private func block(_ sample: CMSampleBuffer) throws -> CMBlockBuffer {
    guard let result = CMSampleBufferGetDataBuffer(sample) else {
        throw PresentationError("Missing PCM block")
    }
    return result
}

private func payload(_ sample: CMSampleBuffer) throws -> Data {
    let block = try block(sample)
    var data = Data(count: CMBlockBufferGetDataLength(block))
    let status = data.withUnsafeMutableBytes { bytes in
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count,
                                   destination: bytes.baseAddress!)
    }
    try checkOSStatus(status, operation: "Read PCM for verification")
    return data
}

private func pointer(_ sample: CMSampleBuffer) throws -> (UInt, Int) {
    var contiguous = 0
    var total = 0
    var address: UnsafeMutablePointer<CChar>?
    try checkOSStatus(CMBlockBufferGetDataPointer(
        try block(sample), atOffset: 0, lengthAtOffsetOut: &contiguous,
        totalLengthOut: &total, dataPointerOut: &address
    ), operation: "Read PCM address")
    guard let address, contiguous == total, total > 0 else {
        throw PresentationError("Expected contiguous PCM")
    }
    return (UInt(bitPattern: address), total)
}

private func timeReceipt(_ time: CMTime) -> [String: Any] {
    ["value": time.value, "timescale": time.timescale,
     "flags": time.flags.rawValue, "epoch": time.epoch]
}

private func verify() throws -> [String: Any] {
    var cases: [[String: Any]] = []
    for channels in [1, 2, 6, 8] {
        for rate in [44_100, 48_000, 96_000] {
            for samples in [1, 257, 1_024] {
                for prefix in [0, 3] {
                    let data = makePCM(samples: samples, channels: channels, seed: 7)
                    let backing = Data(repeating: 0xa5, count: prefix) + data + Data([0x5a])
                    let input = frame(backing[prefix..<(prefix + data.count)],
                                      samples: samples, channels: channels, rate: rate)
                    let format = try makeFormat(rate: rate, channels: channels)
                    let sample = try SampleBufferAudioPresenter.makeSampleBuffer(input, formatDescription: format)
                    let output = try payload(sample)
                    try require(output == data, "PCM payload changed")
                    try require(CMSampleBufferGetNumSamples(sample) == samples, "Sample count changed")
                    try require(CMSampleBufferGetTotalSampleSize(sample) == data.count, "PCM size changed")
                    try require(CMSampleBufferGetPresentationTimeStamp(sample) == input.presentationTime,
                                "Presentation timestamp changed")
                    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid,
                                                    decodeTimeStamp: .invalid)
                    try checkOSStatus(CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing),
                                      operation: "Read sample timing")
                    try require(timing.duration == CMTime(value: 1, timescale: Int32(rate)),
                                "Sample duration changed")
                    try require(!timing.decodeTimeStamp.isValid, "Decode timestamp changed")
                    cases.append([
                        "channels": channels, "rate": rate, "samples": samples, "prefix": prefix,
                        "bytes": output.count,
                        "sha256": SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined(),
                        "pts": timeReceipt(CMSampleBufferGetPresentationTimeStamp(sample)),
                        "duration": timeReceipt(CMSampleBufferGetDuration(sample)),
                        "sample_duration": timeReceipt(timing.duration),
                    ])
                }
            }
        }
    }
    return ["passed": true, "cases": cases]
}

private func usage() -> rusage {
    var value = rusage()
    _ = getrusage(RUSAGE_SELF, &value)
    return value
}

private func cpuNS(_ value: rusage) -> UInt64 {
    UInt64(value.ru_utime.tv_sec + value.ru_stime.tv_sec) * 1_000_000_000
        + UInt64(value.ru_utime.tv_usec + value.ru_stime.tv_usec) * 1_000
}

private func retained(_ scenario: Scenario, frames: [NativeDecodedAudioFrame],
                      format: CMAudioFormatDescription) throws -> [String: Any] {
    try withExtendedLifetime(frames) {
        var sources: [UInt: Int] = [:]
        for frame in frames {
            frame.interleavedFloatPCM.withUnsafeBytes { bytes in
                sources[UInt(bitPattern: bytes.baseAddress!)] = bytes.count
            }
        }
        let before = usage()
        let buffers = try frames.map { try SampleBufferAudioPresenter.makeSampleBuffer($0, formatDescription: format) }
        return try withExtendedLifetime(buffers) {
            var outputs: [UInt: Int] = [:]
            for (frame, sample) in zip(frames, buffers) {
                let (address, count) = try pointer(sample)
                try require(count == frame.interleavedFloatPCM.count, "Retained payload size changed")
                outputs[address] = count
            }
            let after = usage()
            // Validate bytes after recording RSS so verification copies do not affect it.
            for (frame, sample) in zip(frames, buffers) {
                try require(try payload(sample) == frame.interleavedFloatPCM, "Retained payload changed")
            }
            return [
                "scenario": scenario.name, "buffers": frames.count,
                "logical_pcm_bytes": frames.reduce(0) { $0 + $1.interleavedFloatPCM.count },
                "distinct_source_payloads": sources.count,
                "distinct_output_payloads": outputs.count,
                "source_payload_bytes": sources.values.reduce(0, +),
                "output_payload_bytes": outputs.values.reduce(0, +),
                "additional_output_payload_bytes": outputs.reduce(0) {
                    $0 + (sources[$1.key] == nil ? $1.value : 0)
                },
                "maxrss_before_bytes": before.ru_maxrss, "maxrss_after_bytes": after.ru_maxrss,
                "scope": "Live logical payload spans, excluding wrappers and allocator overhead; not player RSS",
            ]
        }
    }
}

@inline(never)
private func presentBatch(_ frames: [NativeDecodedAudioFrame],
                          format: CMAudioFormatDescription) throws -> UInt64 {
    try autoreleasepool {
        let buffers = try frames.map { try SampleBufferAudioPresenter.makeSampleBuffer($0, formatDescription: format) }
        return buffers.reduce(0) {
            $0 &+ UInt64(CMSampleBufferGetTotalSampleSize($1)) &+ UInt64(CMSampleBufferGetNumSamples($1))
        }
    }
}

private func measure(_ scenario: Scenario, frames: [NativeDecodedAudioFrame],
                     format: CMAudioFormatDescription, iterations: Int) throws -> [String: Any] {
    var checksum: UInt64 = 0
    for _ in 0..<8 { checksum &+= try presentBatch(frames, format: format) }
    let before = usage()
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { checksum &+= try presentBatch(frames, format: format) }
    let wall = DispatchTime.now().uptimeNanoseconds - start
    let after = usage()
    return ["scenario": scenario.name, "iterations": iterations, "operations": iterations * frames.count,
            "wall_ns": wall, "cpu_ns": cpuNS(after) - cpuNS(before), "checksum": checksum]
}

@main
private enum AudioPresentationBenchmark {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let result: [String: Any]
        if arguments == ["--verify"] {
            result = try verify()
        } else {
            guard arguments.count >= 2,
                  let scenario = Scenario.all.first(where: { $0.name == arguments[1] }) else {
                throw PresentationError("Expected --verify, --retained SCENARIO, or --time SCENARIO ITERATIONS")
            }
            let frames = fixtures(scenario)
            let format = try makeFormat(rate: 48_000, channels: scenario.channels)
            switch arguments[0] {
            case "--retained":
                result = try retained(scenario, frames: frames, format: format)
            case "--time":
                guard arguments.count == 3, let count = Int(arguments[2]), (1...1_000_000).contains(count) else {
                    throw PresentationError("Invalid iteration count")
                }
                result = try measure(scenario, frames: frames, format: format, iterations: count)
            default:
                throw PresentationError("Unknown mode")
            }
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
