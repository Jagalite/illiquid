import Foundation
#if canImport(CoreMedia)
import CoreMedia
#endif

private enum Number: Decodable {
    case finite(Double), special(String)
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Double.self) { self = .finite(number) }
        else { self = .special(try value.decode(String.self)) }
    }
    var value: Double {
        switch self {
        case .finite(let number): return number
        case .special("nan"): return .nan
        case .special("inf"): return .infinity
        case .special("-inf"): return -.infinity
        default: preconditionFailure("Unknown numeric fixture")
        }
    }
}

private struct FrameSpec: Decodable {
    let time: Double
    let samples: Int
    let channels: Int
    let rate: Int
    let generation: Int
    let revision: UInt64
    let seed: Int
    let source_rate: Int
    let source_channels: Int
    let layout: String
    let downmix: Bool
    let conversion: Bool

    func frame() -> NativeDecodedAudioFrame {
        var data = Data(count: samples * channels * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { bytes in
            for index in 0..<(samples * channels) {
                let sample = Float((index &* 31 &+ seed) % 251 - 125) / 128
                bytes.storeBytes(of: sample, toByteOffset: index * 4, as: Float.self)
            }
        }
        return NativeDecodedAudioFrame(
            interleavedFloatPCM: data,
            presentationTime: CMTime(seconds: time, preferredTimescale: Int32(rate)),
            duration: CMTime(value: Int64(samples), timescale: Int32(rate)),
            generation: generation, sampleRate: rate, channelCount: channels,
            sampleCount: samples, sourceSampleRate: source_rate,
            sourceChannelCount: source_channels, sourceChannelLayout: layout,
            downmixOccurred: downmix, conversionOccurred: conversion, formatRevision: revision
        )
    }
}

private struct Operation: Decodable {
    let kind: String
    let frame: FrameSpec?
    let duration: Number?
    let reject_at: Int?
}

private struct Scenario: Decodable {
    let name: String
    let delay: Number
    let target: Double
    let fallback: FrameSpec
    let operations: [Operation]
}

private func timeRecord(_ time: CMTime) -> [String: Any] {
    ["value": String(time.value), "timescale": time.timescale,
     "flags": time.flags.rawValue, "epoch": String(time.epoch)]
}

private func frameRecord(_ frame: NativeDecodedAudioFrame) -> [String: Any] {
    ["pts": timeRecord(frame.presentationTime), "duration": timeRecord(frame.duration),
     "generation": frame.generation, "sample_rate": frame.sampleRate,
     "channels": frame.channelCount, "samples": frame.sampleCount,
     "source_sample_rate": frame.sourceSampleRate, "source_channels": frame.sourceChannelCount,
     "source_layout": frame.sourceChannelLayout, "downmix": frame.downmixOccurred,
     "conversion": frame.conversionOccurred, "revision": String(frame.formatRevision)]
}

// Each record is a little-endian UInt64 byte length followed by its bytes.
// Metadata uses canonical JSON; PCM remains raw bytes, compared exactly by run.py.
private func appendRecord(_ data: Data, to output: inout Data) {
    var length = UInt64(data.count).littleEndian
    withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
    output.append(data)
}

private func appendJSON(_ value: [String: Any], to output: inout Data) {
    appendRecord(try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), to: &output)
}

private func trace(_ cases: [Scenario], destination: String) throws -> [String: Any] {
    _ = FileManager.default.createFile(atPath: destination, contents: nil)
    let file = try FileHandle(forWritingTo: URL(fileURLWithPath: destination))
    defer { try? file.close() }
    var frameCount = 0
    var pcmBytes = 0
    var operationCount = 0
    for scenario in cases {
        var timeline = AudioDelayTimeline(delay: scenario.delay.value, target: scenario.target)
        let fallback = scenario.fallback.frame()
        var output = Data()
        appendJSON(["case": scenario.name, "bounded_delay_bits": String(timeline.delay.bitPattern)], to: &output)
        for (index, operation) in scenario.operations.enumerated() {
            var calls = 0
            let emit: (NativeDecodedAudioFrame) -> Bool = { frame in
                calls += 1
                let accepted = calls != operation.reject_at
                appendJSON(["operation": index, "callback": calls, "accepted": accepted,
                            "frame": frameRecord(frame)], to: &output)
                appendRecord(frame.interleavedFloatPCM, to: &output)
                frameCount += 1
                pcmBytes += frame.interleavedFloatPCM.count
                return accepted
            }
            let accepted: Bool
            switch operation.kind {
            case "consume": accepted = timeline.consume(operation.frame!.frame(), emit: emit)
            case "finish": accepted = timeline.finish(duration: operation.duration?.value,
                                                       fallback: fallback, emit: emit)
            default: preconditionFailure("Unknown operation")
            }
            appendJSON(["operation_end": index, "returned": accepted, "callbacks": calls,
                        "cursor_bits": String(timeline.cursor.bitPattern)], to: &output)
            operationCount += 1
        }
        try file.write(contentsOf: output)
    }
    return ["cases": cases.count, "operations": operationCount,
            "emitted_frames_including_rejected": frameCount, "pcm_bytes_compared": pcmBytes]
}

private func simpleFrame(channels: Int, data: Data? = nil) -> NativeDecodedAudioFrame {
    NativeDecodedAudioFrame(
        interleavedFloatPCM: data ?? Data(count: 480 * channels * 4),
        presentationTime: .zero, duration: CMTime(value: 480, timescale: 48_000),
        generation: 4, sampleRate: 48_000, channelCount: channels, sampleCount: 480,
        sourceSampleRate: 44_100, sourceChannelCount: channels, sourceChannelLayout: "fixture",
        downmixOccurred: false, conversionOccurred: true, formatRevision: 7
    )
}

private func residency(channels: Int, count: Int) -> [String: Any] {
    var timeline = AudioDelayTimeline(delay: 10)
    var frames: [NativeDecodedAudioFrame] = []
    frames.reserveCapacity(count)
    let accepted = timeline.consume(simpleFrame(channels: channels)) { frame in
        guard frames.count < count else { return false }
        frames.append(frame)
        return true
    }
    precondition(!accepted && frames.count == count)
    precondition(frames.allSatisfy { $0.sampleCount <= 1_024 && $0.interleavedFloatPCM.allSatisfy { $0 == 0 } })
    var payloads: [UInt: Int] = [:]
    // Hold every owner alive throughout inspection: allocator address recycling
    // must not be mistaken for payload sharing. All buffers here are heap-sized.
    withExtendedLifetime(frames) {
        for frame in frames {
            frame.interleavedFloatPCM.withUnsafeBytes { bytes in
                let address = UInt(bitPattern: bytes.baseAddress!)
                if let old = payloads[address] { precondition(old == bytes.count) }
                payloads[address] = bytes.count
            }
        }
    }
    return ["channels": channels, "retained_chunks": frames.count,
            "logical_pcm_bytes": frames.reduce(0) { $0 + $1.interleavedFloatPCM.count },
            "distinct_payload_addresses": payloads.count,
            "unique_payload_bytes": payloads.values.reduce(0, +),
            "all_full_chunks": frames.allSatisfy { $0.sampleCount == 1_024 },
            "scope": count == 48 ? "48 queued silence chunks" : "retained complete 10-second silence stress case"]
}

private final class ReleaseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func released() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@inline(never)
private func consumeOwned(timeline: inout AudioDelayTimeline, probe: ReleaseProbe) {
    let byteCount = 480 * 8 * 4
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
    pointer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
    let data = Data(bytesNoCopy: pointer, count: byteCount, deallocator: .custom { pointer, _ in
        pointer.deallocate()
        probe.released()
    })
    precondition(timeline.consume(simpleFrame(channels: 8, data: data)) { _ in true })
}

private func lifetime(delay: Double) -> [String: Any] {
    let probe = ReleaseProbe()
    var timeline = AudioDelayTimeline(delay: delay)
    consumeOwned(timeline: &timeline, probe: probe)
    let releasesWhileAlive = probe.count
    // Keep the timeline observably usable after the lifetime observation.
    precondition(timeline.finish(duration: 0.1, fallback: simpleFrame(channels: 2)) { _ in true })
    withExtendedLifetime(timeline) {}
    return ["delay": delay, "source_pcm_bytes": 480 * 8 * 4,
            "source_releases_while_timeline_alive": releasesWhileAlive]
}

private func measure(_ scenario: Scenario, iterations: Int) -> [String: Any] {
    let fallback = scenario.fallback.frame()
    let sources = scenario.operations.map { $0.frame?.frame() }
    var ring = [NativeDecodedAudioFrame?](repeating: nil, count: 48)
    var writes = 0
    var checksum: UInt64 = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        var timeline = AudioDelayTimeline(delay: scenario.delay.value, target: scenario.target)
        for (index, operation) in scenario.operations.enumerated() {
            var calls = 0
            let emit: (NativeDecodedAudioFrame) -> Bool = { frame in
                calls += 1
                let accepted = calls != operation.reject_at
                checksum &+= UInt64(frame.sampleCount + frame.interleavedFloatPCM.count)
                checksum &+= UInt64(frame.interleavedFloatPCM.first ?? 0)
                if accepted {
                    ring[writes % ring.count] = frame
                    writes += 1
                }
                return accepted
            }
            if operation.kind == "consume" {
                _ = timeline.consume(sources[index]!, emit: emit)
            } else {
                _ = timeline.finish(duration: operation.duration?.value, fallback: fallback, emit: emit)
            }
        }
        checksum &+= timeline.cursor.bitPattern
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    // Observe stored output after the measured loop so queue writes remain live.
    for frame in ring.compactMap({ $0 }) { checksum &+= UInt64(frame.interleavedFloatPCM.last ?? 0) }
    return ["case": scenario.name, "iterations": iterations, "elapsed_ns": elapsed,
            "ns_per_iteration": Double(elapsed) / Double(iterations),
            "emitted_frames": writes, "checksum": String(checksum)]
}

@main
private enum Main {
    static func main() throws {
        let args = CommandLine.arguments
        let result: [String: Any]
        switch args[1] {
        case "trace":
            let cases = try JSONDecoder().decode([Scenario].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            result = try trace(cases, destination: args[3])
        case "residency": result = residency(channels: Int(args[2])!, count: Int(args[3])!)
        case "lifetime": result = lifetime(delay: Double(args[2])!)
        case "measure":
            let cases = try JSONDecoder().decode([Scenario].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            result = measure(cases[Int(args[3])!], iterations: Int(args[4])!)
        default: preconditionFailure("Expected trace, residency, lifetime, or measure")
        }
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(encoded)
        FileHandle.standardOutput.write(Data([10]))
    }
}
