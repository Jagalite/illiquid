import CoreMedia
import Foundation

/// A sample mapping owned by the audio decode worker, not another clock.
/// Positive offsets present audio later. Silence is emitted in bounded chunks;
/// advancing audio trims pre-target samples and pads the exhausted tail.
struct AudioDelayTimeline {
    let delay: TimeInterval
    private(set) var cursor: TimeInterval
    private var hasOutput = false
    private var template: NativeDecodedAudioFrame?

    init(delay: TimeInterval, target: TimeInterval = 0) {
        self.delay = Self.bounded(delay)
        cursor = max(0, target)
    }

    static func bounded(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? min(10, max(-10, value)) : 0
    }

    mutating func consume(_ source: NativeDecodedAudioFrame,
                          emit: (NativeDecodedAudioFrame) -> Bool) -> Bool {
        template = source
        let shifted = source.replacing(time: CMTimeAdd(source.presentationTime,
            CMTime(seconds: delay, preferredTimescale: 60_000)))
        guard let frame = shifted.trimmingSamples(before: cursor) else { return true }
        if !hasOutput, delay > cursor {
            guard silence(until: min(delay, frame.presentationTime.seconds), like: source, emit: emit) else { return false }
        }
        guard emit(frame) else { return false }
        hasOutput = true
        cursor = frame.presentationTime.seconds + frame.duration.seconds
        return true
    }

    mutating func finish(duration: TimeInterval?, fallback: NativeDecodedAudioFrame,
                         emit: (NativeDecodedAudioFrame) -> Bool) -> Bool {
        let format = template ?? fallback
        if delay < 0, let duration, duration.isFinite, duration > cursor {
            return silence(until: duration, like: format, emit: emit)
        }
        // Empty streams and offsets beyond a short clip must still complete
        // preroll. A single silent sample buffer supplies the format contract.
        if !hasOutput {
            return silence(until: cursor + 1 / Double(format.sampleRate), like: format, emit: emit)
        }
        return true
    }

    private mutating func silence(until end: TimeInterval, like frame: NativeDecodedAudioFrame,
                                  emit: (NativeDecodedAudioFrame) -> Bool) -> Bool {
        let endSample = Int64((end * Double(frame.sampleRate)).rounded())
        var nextSample = Int64((cursor * Double(frame.sampleRate)).rounded())
        while nextSample < endSample {
            let count = Int(min(1_024, endSample - nextSample))
            let duration = CMTime(value: Int64(count), timescale: Int32(frame.sampleRate))
            let silent = frame.replacing(
                time: CMTime(value: nextSample, timescale: Int32(frame.sampleRate)),
                data: Data(count: count * frame.channelCount * MemoryLayout<Float>.size),
                sampleCount: count, duration: duration)
            guard emit(silent) else { return false }
            hasOutput = true
            nextSample += Int64(count)
            cursor = CMTime(value: nextSample, timescale: Int32(frame.sampleRate)).seconds
        }
        return true
    }
}

extension NativeDecodedAudioFrame {
    func replacing(time: CMTime, data: Data? = nil, sampleCount: Int? = nil,
                   duration: CMTime? = nil) -> Self {
        Self(interleavedFloatPCM: data ?? interleavedFloatPCM, presentationTime: time,
             duration: duration ?? self.duration, generation: generation,
             sampleRate: sampleRate, channelCount: channelCount,
             sampleCount: sampleCount ?? self.sampleCount, sourceSampleRate: sourceSampleRate,
             sourceChannelCount: sourceChannelCount, sourceChannelLayout: sourceChannelLayout,
             downmixOccurred: downmixOccurred, conversionOccurred: conversionOccurred,
             formatRevision: formatRevision)
    }
}
