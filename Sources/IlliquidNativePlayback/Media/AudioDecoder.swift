import CFFmpeg
import CoreMedia
import Foundation

struct AudioSampleSanitizationResult: Equatable, Sendable {
    let replacedNonFiniteSamples: Int
    let replacedSubnormalSamples: Int

    var totalReplacements: Int {
        replacedNonFiniteSamples + replacedSubnormalSamples
    }
}

@discardableResult
func sanitizeInterleavedFloatPCM(_ data: inout Data) -> AudioSampleSanitizationResult {
    var nonFinite = 0
    var subnormal = 0
    data.withUnsafeMutableBytes { bytes in
        let samples = bytes.bindMemory(to: Float.self)
        for index in samples.indices {
            let sample = samples[index]
            if !sample.isFinite {
                samples[index] = 0
                nonFinite += 1
            } else if sample.isSubnormal {
                samples[index] = 0
                subnormal += 1
            }
        }
    }
    return AudioSampleSanitizationResult(
        replacedNonFiniteSamples: nonFinite,
        replacedSubnormalSamples: subnormal
    )
}

struct AudioDecoderNoProgressError: Error, Equatable, Sendable {
    let consecutiveErrors: Int
}

struct NativeDecodedAudioFrame: Sendable {
    let interleavedFloatPCM: Data
    let presentationTime: CMTime
    let duration: CMTime
    let generation: Int
    let sampleRate: Int
    let channelCount: Int
    let sampleCount: Int
    let sourceSampleRate: Int
    let sourceChannelCount: Int
    let sourceChannelLayout: String
    let downmixOccurred: Bool
    let conversionOccurred: Bool
    var formatRevision: UInt64 = 1
}

extension NativeDecodedAudioFrame {
    func trimmingSamples(before targetSeconds: Double) -> NativeDecodedAudioFrame? {
        let start = presentationTime.seconds
        guard targetSeconds > start else { return self }
        let samplesToDrop = Int(ceil((targetSeconds - start) * Double(sampleRate)))
        guard samplesToDrop > 0 else { return self }
        guard samplesToDrop < sampleCount else { return nil }
        let bytesPerSampleFrame = channelCount * MemoryLayout<Float>.size
        let byteOffset = samplesToDrop * bytesPerSampleFrame
        guard byteOffset < interleavedFloatPCM.count else { return nil }
        let retainedSamples = sampleCount - samplesToDrop
        let adjustedTime = CMTimeAdd(
            presentationTime,
            CMTime(value: Int64(samplesToDrop), timescale: Int32(sampleRate))
        )
        return NativeDecodedAudioFrame(
            interleavedFloatPCM: Data(interleavedFloatPCM.dropFirst(byteOffset)),
            presentationTime: adjustedTime,
            duration: CMTime(value: Int64(retainedSamples), timescale: Int32(sampleRate)),
            generation: generation,
            sampleRate: sampleRate,
            channelCount: channelCount,
            sampleCount: retainedSamples,
            sourceSampleRate: sourceSampleRate,
            sourceChannelCount: sourceChannelCount,
            sourceChannelLayout: sourceChannelLayout,
            downmixOccurred: downmixOccurred,
            conversionOccurred: conversionOccurred,
            formatRevision: formatRevision
        )
    }
}

/// Maps decoded source timestamps onto the sample clock produced by the
/// resampler. Source packet timestamps describe the input clock; using them on
/// every converted buffer creates small gaps and overlaps whenever the input
/// and output sample rates differ.
struct ResampledAudioTimeline {
    private var expectedSourceTime: CMTime?
    private var nextOutputTime: CMTime?

    mutating func reset() {
        expectedSourceTime = nil
        nextOutputTime = nil
    }

    mutating func drainPresentationTime(sampleCount: Int, sampleRate: Int) -> CMTime {
        let time = nextOutputTime ?? .invalid
        if time.isNumeric {
            nextOutputTime = CMTimeAdd(time, CMTime(value: Int64(sampleCount), timescale: Int32(sampleRate)))
        }
        return time
    }

    mutating func presentationTime(
        sourceTime: CMTime,
        sourceSampleCount: Int,
        sourceSampleRate: Int,
        outputSampleCount: Int,
        outputSampleRate: Int
    ) -> CMTime {
        precondition(sourceSampleCount > 0 && sourceSampleRate > 0)
        precondition(outputSampleCount >= 0 && outputSampleRate > 0)

        let sourceDuration = CMTime(
            value: Int64(sourceSampleCount),
            timescale: Int32(sourceSampleRate)
        )
        let outputDuration = CMTime(
            value: Int64(outputSampleCount),
            timescale: Int32(outputSampleRate)
        )

        let isContinuous = sourceTime.isNumeric
            && expectedSourceTime.map {
                let difference = abs(CMTimeSubtract(sourceTime, $0).seconds)
                let tolerance = max(
                    0.005,
                    min(sourceDuration.seconds * 0.5, 0.020)
                )
                return difference.isFinite && difference <= tolerance
            } ?? false

        let outputTime: CMTime
        if let nextOutputTime, isContinuous || !sourceTime.isNumeric {
            outputTime = nextOutputTime
        } else {
            outputTime = sourceTime
        }

        if sourceTime.isNumeric {
            expectedSourceTime = CMTimeAdd(sourceTime, sourceDuration)
        } else if let expectedSourceTime {
            self.expectedSourceTime = CMTimeAdd(expectedSourceTime, sourceDuration)
        }
        nextOutputTime = outputTime.isNumeric
            ? CMTimeAdd(outputTime, outputDuration)
            : nil
        return outputTime
    }
}

enum AudioFrameQueueItem: Sendable {
    case frame(NativeDecodedAudioFrame)
    case flush(generation: Int, target: CMTime, resumeRate: Float)
    case endOfStream(generation: Int)
}

final class AudioDecoder {
    static let outputSampleRate = 48_000
    static let outputChannelCount = 2
    static let maximumConsecutiveDecodeErrors = 32

    private var context: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var resampler: OpaquePointer?
    private let stream: FFmpegStreamInfo
    private let timelineOriginSeconds: Double
    private let outputCapacity: NativeAudioOutputCapacity
    private var sourceFormatSignature: String?
    private var sourceFormatRevision: UInt64 = 0
    private var resampledTimeline = ResampledAudioTimeline()
    private var resamplerFrameMetadata: NativeDecodedAudioFrame?
    private var consecutiveDecodeErrors = 0
    private(set) var droppedDecodeErrors = 0
    private(set) var sanitizedSampleCount = 0

    init(
        parameters: UnsafePointer<AVCodecParameters>,
        stream: FFmpegStreamInfo,
        timelineOriginSeconds: Double = 0,
        outputCapacity: NativeAudioOutputCapacity = NativeAudioOutputCapacity()
    ) throws {
        self.stream = stream
        self.timelineOriginSeconds = timelineOriginSeconds
        self.outputCapacity = outputCapacity
        var createdContext: UnsafeMutablePointer<AVCodecContext>?
        try checkFFmpeg(
            illiquid_create_decoder(parameters, 0, &createdContext, nil),
            operation: "Open \(stream.codecName) audio decoder"
        )
        guard let createdContext, let frame = av_frame_alloc() else {
            avcodec_free_context(&createdContext)
            throw FFmpegError(
                operation: "Allocate audio decoder frame",
                code: illiquid_averror_nomem()
            )
        }
        context = createdContext
        self.frame = frame
    }

    deinit {
        illiquid_free_audio_resampler(resampler)
        av_frame_free(&frame)
        avcodec_free_context(&context)
    }

    func decode(_ packet: FFmpegPacket) throws -> [NativeDecodedAudioFrame] {
        guard let context, let packetPointer = packet.pointer else { return [] }
        var output: [NativeDecodedAudioFrame] = []
        var result = avcodec_send_packet(context, packetPointer)
        if result == illiquid_averror_eagain() {
            output += try receiveFrames(generation: packet.generation)
            result = avcodec_send_packet(context, packetPointer)
        }
        if result < 0, result != illiquid_averror_nomem() {
            try recordDroppedDecodeError()
            return output
        }
        try checkFFmpeg(result, operation: "Submit audio packet")
        output += try receiveFrames(generation: packet.generation)
        return output
    }

    func drain(generation: Int) throws -> [NativeDecodedAudioFrame] {
        guard let context else { return [] }
        var output: [NativeDecodedAudioFrame] = []
        var result = avcodec_send_packet(context, nil)
        if result == illiquid_averror_eagain() {
            output += try receiveFrames(generation: generation)
            result = avcodec_send_packet(context, nil)
        }
        if result != illiquid_averror_eof(),
           result != illiquid_averror_eagain()
        {
            if result < 0, result != illiquid_averror_nomem() {
                try recordDroppedDecodeError()
                return []
            }
            try checkFFmpeg(result, operation: "Drain audio decoder")
        }
        output += try receiveFrames(generation: generation)
        output += try drainResampler(generation: generation)
        return output
    }

    func flush() {
        guard let context else { return }
        avcodec_flush_buffers(context)
        illiquid_reset_audio_resampler(resampler)
        resampledTimeline.reset()
        resamplerFrameMetadata = nil
        consecutiveDecodeErrors = 0
    }

    private func receiveFrames(generation: Int) throws -> [NativeDecodedAudioFrame] {
        guard let context, let frame else { return [] }
        var output: [NativeDecodedAudioFrame] = []
        while true {
            av_frame_unref(frame)
            let result = avcodec_receive_frame(context, frame)
            if result == illiquid_averror_eagain()
                || result == illiquid_averror_eof()
            {
                break
            }
            if result < 0, result != illiquid_averror_nomem() {
                try recordDroppedDecodeError()
                break
            }
            try checkFFmpeg(result, operation: "Decode audio frame")
            output += try convert(frame, generation: generation)
            consecutiveDecodeErrors = 0
        }
        return output
    }

    private func convert(
        _ frame: UnsafeMutablePointer<AVFrame>,
        generation: Int
    ) throws -> [NativeDecodedAudioFrame] {
        var output: [NativeDecodedAudioFrame] = []
        let sourceRate = illiquid_audio_frame_sample_rate(frame)
        let sourceChannels = illiquid_audio_frame_channel_count(frame)
        var channelLayoutBuffer = [CChar](repeating: 0, count: 128)
        let channelLayoutResult = illiquid_audio_frame_channel_layout_name(
            frame,
            &channelLayoutBuffer,
            channelLayoutBuffer.count
        )
        let sourceChannelLayout = channelLayoutResult >= 0
            ? stringFromCStringBuffer(channelLayoutBuffer)
            : "unknown"
        let inputSamples = illiquid_audio_frame_sample_count(frame)
        guard sourceRate > 0, sourceChannels > 0, inputSamples > 0 else {
            throw FFmpegError(operation: "Decode audio format", code: -22)
        }

        let sampleFormat = illiquid_frame_sample_format(frame)
        let outputChannels = outputCapacity.outputChannels(forSourceChannels: Int(sourceChannels))
        let signature = "\(sourceRate)|\(sourceChannels)|\(sourceChannelLayout)|\(sampleFormat)|out=\(outputChannels)"
        if sourceFormatSignature != signature {
            // Preserve the old format's buffered output before replacing it.
            // Seek flushes intentionally discard this output instead.
            output += try drainResampler(generation: generation)
            illiquid_free_audio_resampler(resampler)
            resampler = nil
            resampledTimeline.reset()
            sourceFormatSignature = signature
            precondition(sourceFormatRevision < UInt64.max, "audio format revision exhausted")
            sourceFormatRevision += 1
        }
        if resampler == nil {
            guard let created = illiquid_create_audio_resampler(
                frame,
                Int32(Self.outputSampleRate),
                Int32(outputChannels)
            ) else {
                throw FFmpegError(operation: "Create audio resampler", code: -12)
            }
            resampler = created
        }
        guard let resampler else {
            throw FFmpegError(operation: "Access audio resampler", code: -22)
        }
        let capacity = illiquid_audio_resampler_output_capacity(
            resampler,
            inputSamples
        )
        guard capacity > 0 else {
            throw FFmpegError(operation: "Calculate audio output capacity", code: -22)
        }

        let bytesPerSample = MemoryLayout<Float>.size
        var data = Data(
            count: Int(capacity)
                * outputChannels
                * bytesPerSample
        )
        let convertedSamples: Int32 = data.withUnsafeMutableBytes { bytes in
            guard let address = bytes.bindMemory(to: UInt8.self).baseAddress else {
                return -22
            }
            return illiquid_convert_audio_frame(
                resampler,
                frame,
                address,
                capacity
            )
        }
        try checkFFmpeg(convertedSamples, operation: "Convert decoded audio")
        data.count = Int(convertedSamples)
            * outputChannels
            * bytesPerSample
        sanitizedSampleCount += sanitizeInterleavedFloatPCM(&data).totalReplacements

        let sourcePresentationTime = MediaTime.cmTime(
            illiquid_frame_best_effort_timestamp(frame),
            timeBase: stream.timeBase
        )
        let normalizedSourceTime = sourcePresentationTime.isNumeric
            ? CMTimeSubtract(
                sourcePresentationTime,
                CMTime(seconds: timelineOriginSeconds, preferredTimescale: 60_000)
            )
            : sourcePresentationTime
        let duration = CMTime(
            value: Int64(convertedSamples),
            timescale: Int32(Self.outputSampleRate)
        )
        let presentationTime = resampledTimeline.presentationTime(
            sourceTime: normalizedSourceTime,
            sourceSampleCount: Int(inputSamples),
            sourceSampleRate: Int(sourceRate),
            outputSampleCount: Int(convertedSamples),
            outputSampleRate: Self.outputSampleRate
        )
        let converted = NativeDecodedAudioFrame(
            interleavedFloatPCM: data,
            presentationTime: presentationTime,
            duration: duration,
            generation: generation,
            sampleRate: Self.outputSampleRate,
            channelCount: outputChannels,
            sampleCount: Int(convertedSamples),
            sourceSampleRate: Int(sourceRate),
            sourceChannelCount: Int(sourceChannels),
            sourceChannelLayout: sourceChannelLayout,
            downmixOccurred: sourceChannels > outputChannels,
            conversionOccurred: sourceRate != Self.outputSampleRate
                || sourceChannels != outputChannels
                || sampleFormat != AV_SAMPLE_FMT_FLT,
            formatRevision: sourceFormatRevision
        )
        // Retain only format/timing metadata, not another copy of PCM storage.
        let metadata = NativeDecodedAudioFrame(
            interleavedFloatPCM: Data(), presentationTime: converted.presentationTime,
            duration: .zero, generation: generation, sampleRate: converted.sampleRate,
            channelCount: converted.channelCount, sampleCount: 0,
            sourceSampleRate: converted.sourceSampleRate, sourceChannelCount: converted.sourceChannelCount,
            sourceChannelLayout: converted.sourceChannelLayout, downmixOccurred: converted.downmixOccurred,
            conversionOccurred: converted.conversionOccurred, formatRevision: converted.formatRevision
        )
        resamplerFrameMetadata = metadata
        if convertedSamples > 0 { output.append(converted) }
        return output
    }

    private func drainResampler(generation: Int) throws -> [NativeDecodedAudioFrame] {
        guard let resampler, let metadata = resamplerFrameMetadata else { return [] }
        var output: [NativeDecodedAudioFrame] = []
        while true {
            let capacity = illiquid_audio_resampler_output_capacity(resampler, 0)
            try checkFFmpeg(capacity, operation: "Calculate audio drain capacity")
            guard capacity > 0 else { break }
            var data = Data(count: Int(capacity) * metadata.channelCount * MemoryLayout<Float>.size)
            let count = data.withUnsafeMutableBytes { bytes in
                illiquid_drain_audio_resampler(resampler,
                    bytes.bindMemory(to: UInt8.self).baseAddress!, capacity)
            }
            try checkFFmpeg(count, operation: "Drain audio resampler")
            guard count > 0 else { break }
            data.count = Int(count) * metadata.channelCount * MemoryLayout<Float>.size
            sanitizedSampleCount += sanitizeInterleavedFloatPCM(&data).totalReplacements
            output.append(NativeDecodedAudioFrame(
                interleavedFloatPCM: data,
                presentationTime: resampledTimeline.drainPresentationTime(
                    sampleCount: Int(count), sampleRate: metadata.sampleRate),
                duration: CMTime(value: Int64(count), timescale: Int32(metadata.sampleRate)),
                generation: generation, sampleRate: metadata.sampleRate,
                channelCount: metadata.channelCount, sampleCount: Int(count),
                sourceSampleRate: metadata.sourceSampleRate, sourceChannelCount: metadata.sourceChannelCount,
                sourceChannelLayout: metadata.sourceChannelLayout, downmixOccurred: metadata.downmixOccurred,
                conversionOccurred: metadata.conversionOccurred, formatRevision: metadata.formatRevision
            ))
        }
        resamplerFrameMetadata = nil
        return output
    }

    private func recordDroppedDecodeError() throws {
        droppedDecodeErrors += 1
        consecutiveDecodeErrors += 1
        if consecutiveDecodeErrors >= Self.maximumConsecutiveDecodeErrors {
            throw AudioDecoderNoProgressError(consecutiveErrors: consecutiveDecodeErrors)
        }
    }
}
