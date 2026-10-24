import CoreMedia
import Foundation
@testable import IlliquidNativePlayback

private struct TimeReceipt: Codable, Equatable {
    let value: Int64
    let timescale: Int32
    init(_ time: CMTime) { value = time.value; timescale = time.timescale }
}

private struct FrameReceipt: Codable, Equatable {
    let time: TimeReceipt
    let duration: TimeReceipt
    let generation: Int
    let sampleRate: Int
    let channelCount: Int
    let sampleCount: Int
    let sourceSampleRate: Int
    let sourceChannelCount: Int
    let sourceChannelLayout: String
    let downmixOccurred: Bool
    let conversionOccurred: Bool
    let formatRevision: UInt64
    let pcmBytes: Int
    let pcmFNV1a64: String
    let allZero: Bool

    init(_ frame: NativeDecodedAudioFrame) {
        time = TimeReceipt(frame.presentationTime)
        duration = TimeReceipt(frame.duration)
        generation = frame.generation
        sampleRate = frame.sampleRate
        channelCount = frame.channelCount
        sampleCount = frame.sampleCount
        sourceSampleRate = frame.sourceSampleRate
        sourceChannelCount = frame.sourceChannelCount
        sourceChannelLayout = frame.sourceChannelLayout
        downmixOccurred = frame.downmixOccurred
        conversionOccurred = frame.conversionOccurred
        formatRevision = frame.formatRevision
        pcmBytes = frame.interleavedFloatPCM.count
        var hash: UInt64 = 0xcbf29ce484222325
        var zero = true
        frame.interleavedFloatPCM.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes {
                hash = (hash ^ UInt64(byte)) &* 0x100000001b3
                zero = zero && byte == 0
            }
        }
        pcmFNV1a64 = String(hash, radix: 16)
        allZero = zero
    }
}

private struct BatchReceipt: Codable {
    let frames: Int
    let logicalPCMBytes: Int
    let uniqueBorrowedPCMBytes: Int
    let uniqueBorrowedRanges: Int
}

/// All Data borrows remain active until the deepest closure finishes. Raw
/// pointers never escape their withUnsafeBytes calls. The union measures the
/// backing payload covered by the retained frames, excluding allocator headers,
/// Data objects, spare capacity, renderer copies, and unrelated process memory.
private func backingStorage(_ frames: [NativeDecodedAudioFrame]) -> BatchReceipt {
    var ranges: [Range<UInt>] = []
    func borrow(_ index: Int) -> BatchReceipt {
        if index < frames.count {
            return frames[index].interleavedFloatPCM.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress, !bytes.isEmpty {
                    let address = UInt(bitPattern: base)
                    ranges.append(address..<(address + UInt(bytes.count)))
                    defer { ranges.removeLast() }
                    return borrow(index + 1)
                }
                return borrow(index + 1)
            }
        }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<UInt>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return BatchReceipt(frames: frames.count,
            logicalPCMBytes: frames.reduce(0) { $0 + $1.interleavedFloatPCM.count },
            uniqueBorrowedPCMBytes: merged.reduce(0) { $0 + Int($1.upperBound - $1.lowerBound) },
            uniqueBorrowedRanges: merged.count)
    }
    return borrow(0)
}

private final class Collector {
    var frames: [FrameReceipt] = []
    var batches: [BatchReceipt] = []
    private var retained: [NativeDecodedAudioFrame] = []
    private let rejectAt: Int?
    private(set) var attemptedFrames = 0
    init(rejectAt: Int? = nil) { self.rejectAt = rejectAt }
    func emit(_ frame: NativeDecodedAudioFrame) -> Bool {
        attemptedFrames += 1
        if attemptedFrames == rejectAt { return false }
        frames.append(FrameReceipt(frame))
        retained.append(frame)
        if retained.count == 48 { flush() }
        return true
    }
    func flush() {
        guard !retained.isEmpty else { return }
        batches.append(backingStorage(retained))
        retained.removeAll(keepingCapacity: true)
    }
}

private func frame(channels: Int = 2, samples: Int = 0, time: Double = 0,
                   sampleRate: Int = 48_000, revision: UInt64 = 17) -> NativeDecodedAudioFrame {
    var pcm = Data(count: samples * channels * MemoryLayout<Float>.size)
    pcm.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
        for index in 0..<(samples * channels) {
            let value = Float(index % 2_000 - 1_000) / 1_000
            bytes.storeBytes(of: value, toByteOffset: index * MemoryLayout<Float>.size, as: Float.self)
        }
    }
    return NativeDecodedAudioFrame(interleavedFloatPCM: pcm,
        presentationTime: CMTime(seconds: time, preferredTimescale: Int32(sampleRate)),
        duration: CMTime(value: Int64(samples), timescale: Int32(sampleRate)),
        generation: 9, sampleRate: sampleRate, channelCount: channels, sampleCount: samples,
        sourceSampleRate: 44_100, sourceChannelCount: 8, sourceChannelLayout: "7.1",
        downmixOccurred: channels < 8, conversionOccurred: true, formatRevision: revision)
}

private struct SemanticReceipt: Codable, Equatable {
    let scenario: String
    let operationResults: [Bool]
    let cursor: Double
    let attemptedFrames: Int
    let frames: [FrameReceipt]
}

private struct ScenarioReceipt: Codable {
    let semantic: SemanticReceipt
    let batches: [BatchReceipt]
}

private func runScenario(_ name: String) -> ScenarioReceipt {
    let channels = name.hasSuffix("8ch") ? 8 : 2
    let sink = Collector(rejectAt: name == "backpressure" ? 3 : nil)
    var timeline = AudioDelayTimeline(delay: -10)
    var results: [Bool] = []
    switch name {
    case "padding_10s_stereo", "padding_10s_8ch":
        results.append(timeline.finish(duration: 10, fallback: frame(channels: channels), emit: sink.emit))
    case "short_tail_stereo", "short_tail_8ch":
        results.append(timeline.finish(duration: 2_055.0 / 48_000, fallback: frame(channels: channels), emit: sink.emit))
    case "short_only_stereo", "short_only_8ch":
        results.append(timeline.finish(duration: 7.0 / 48_000, fallback: frame(channels: channels), emit: sink.emit))
    case "empty_fallback_stereo", "empty_fallback_8ch":
        timeline = AudioDelayTimeline(delay: 0)
        results.append(timeline.finish(duration: nil, fallback: frame(channels: channels), emit: sink.emit))
    case "positive_delay":
        timeline = AudioDelayTimeline(delay: 0.05)
        results.append(timeline.consume(frame(samples: 2_048), emit: sink.emit))
        results.append(timeline.finish(duration: 1, fallback: frame(), emit: sink.emit))
    case "negative_trim":
        timeline = AudioDelayTimeline(delay: -0.01)
        results.append(timeline.consume(frame(samples: 1_024), emit: sink.emit))
        results.append(timeline.consume(frame(samples: 513, time: 1_024.0 / 48_000), emit: sink.emit))
        results.append(timeline.finish(duration: 1_537.0 / 48_000, fallback: frame(), emit: sink.emit))
    case "format_change":
        timeline = AudioDelayTimeline(delay: -0.005)
        results.append(timeline.consume(frame(samples: 882, sampleRate: 44_100), emit: sink.emit))
        results.append(timeline.consume(frame(channels: 8, samples: 960, time: 0.02, revision: 18), emit: sink.emit))
        results.append(timeline.finish(duration: 0.08, fallback: frame(), emit: sink.emit))
    case "backpressure":
        timeline = AudioDelayTimeline(delay: 10)
        results.append(timeline.consume(frame(samples: 480), emit: sink.emit))
    default: preconditionFailure("Unknown scenario")
    }
    sink.flush()
    return ScenarioReceipt(semantic: SemanticReceipt(scenario: name,
        operationResults: results, cursor: timeline.cursor,
        attemptedFrames: sink.attemptedFrames, frames: sink.frames), batches: sink.batches)
}

private final class ReleaseTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    var releases: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@inline(never)
private func consumeOwnedPCM(_ timeline: inout AudioDelayTimeline, tracker: ReleaseTracker) -> Bool {
    let count = 4_096 * 8 * MemoryLayout<Float>.size
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
    pointer.initializeMemory(as: UInt8.self, repeating: 0x3f, count: count)
    let data = Data(bytesNoCopy: pointer, count: count, deallocator: .custom { pointer, _ in
        pointer.deallocate()
        tracker.record()
    })
    let source = frame(channels: 8).replacing(time: .zero, data: data,
        sampleCount: 4_096, duration: CMTime(value: 4_096, timescale: 48_000))
    return timeline.consume(source) { _ in preconditionFailure("Fixture must be fully trimmed") }
}

private struct LifetimeReceipt: Codable {
    let sourcePCMBytes: Int
    let consumeSucceeded: Bool
    let releasesWhileTimelineIsAlive: Int
    let releasesAfterTimelineReset: Int
}

private func sourceLifetime() -> LifetimeReceipt {
    let tracker = ReleaseTracker()
    var timeline = AudioDelayTimeline(delay: -10)
    let result = consumeOwnedPCM(&timeline, tracker: tracker)
    let alive = withExtendedLifetime(timeline) { tracker.releases }
    timeline = AudioDelayTimeline(delay: 0)
    let released = withExtendedLifetime(timeline) { tracker.releases }
    return LifetimeReceipt(sourcePCMBytes: 4_096 * 8 * MemoryLayout<Float>.size,
        consumeSucceeded: result, releasesWhileTimelineIsAlive: alive, releasesAfterTimelineReset: released)
}

private struct Report: Codable {
    let timingPlatform: String
    let scenarios: [ScenarioReceipt]
    let sourceLifetime: LifetimeReceipt
}

@main
private enum Main {
    static func main() throws {
        #if os(Linux)
        let platform = "Linux CoreMedia shim: component ownership/output comparison only"
        #else
        let platform = "Native Apple CoreMedia"
        #endif
        let names = ["padding_10s_stereo", "padding_10s_8ch", "short_tail_stereo", "short_tail_8ch",
                     "short_only_stereo", "short_only_8ch", "empty_fallback_stereo", "empty_fallback_8ch",
                     "positive_delay", "negative_trim", "format_change", "backpressure"]
        let report = Report(timingPlatform: platform, scenarios: names.map(runScenario), sourceLifetime: sourceLifetime())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([10]))
    }
}
