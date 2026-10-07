import CFFmpeg
import CoreMedia
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Audio resampler completion")
struct AudioResamplerDrainTests {
    @Test(arguments: [32_000, 44_100, 48_000, 96_000])
    func eofPreservesAFullSecond(rate: Int) throws {
        let decoder = try decoder(rate: rate)
        var frames = try decoder.decode(packet(rate: rate, samples: rate))
        frames += try decoder.drain(generation: 1)
        #expect(frames.reduce(0) { $0 + $1.sampleCount } == 48_000)
        #expect(frames.allSatisfy { $0.sampleCount > 0 && $0.generation == 1 })
        assertContinuous(frames)
        #expect(try decoder.drain(generation: 1).isEmpty)
    }

    @Test func outputFormatChangePreservesBothTailsAndRevisions() throws {
        let capacity = NativeAudioOutputCapacity(channels: 6)
        let decoder = try decoder(rate: 44_100, channels: 6, capacity: capacity)
        var frames = try decoder.decode(packet(rate: 44_100, samples: 44_100, channels: 6))
        capacity.update(channels: 2)
        frames += try decoder.decode(packet(rate: 44_100, samples: 44_100, channels: 6, start: 44_100))
        frames += try decoder.drain(generation: 1)
        for revision in [UInt64(1), 2] {
            let segment = frames.filter { $0.formatRevision == revision }
            #expect(segment.reduce(0) { $0 + $1.sampleCount } == 48_000)
            #expect(segment.allSatisfy { $0.channelCount == (revision == 1 ? 6 : 2) })
        }
        assertContinuous(frames)
    }

    @Test func seekFlushDiscardsOldTailAndRestartsGeneration() throws {
        let decoder = try decoder(rate: 44_100)
        _ = try decoder.decode(packet(rate: 44_100, samples: 441))
        decoder.flush()
        #expect(try decoder.drain(generation: 2).isEmpty)
        decoder.flush()
        var frames = try decoder.decode(packet(rate: 44_100, samples: 44_100, start: 88_200, generation: 2))
        frames += try decoder.drain(generation: 2)
        #expect(frames.reduce(0) { $0 + $1.sampleCount } == 48_000)
        #expect(frames.allSatisfy { $0.generation == 2 })
        #expect(frames.first?.presentationTime.seconds == 2)
        assertContinuous(frames)
    }

    private func assertContinuous(_ frames: [NativeDecodedAudioFrame]) {
        for (previous, next) in zip(frames, frames.dropFirst()) {
            #expect(abs(CMTimeSubtract(next.presentationTime,
                CMTimeAdd(previous.presentationTime, previous.duration)).seconds) < 1e-8)
        }
    }

    private func decoder(rate: Int, channels: Int = 2,
                         capacity: NativeAudioOutputCapacity = .init()) throws -> AudioDecoder {
        var allocated = avcodec_parameters_alloc()
        let parameters = try #require(allocated)
        defer { avcodec_parameters_free(&allocated) }
        parameters.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        parameters.pointee.codec_id = AV_CODEC_ID_PCM_F32LE
        parameters.pointee.sample_rate = Int32(rate)
        av_channel_layout_default(&parameters.pointee.ch_layout, Int32(channels))
        let stream = FFmpegStreamInfo(index: 0, kind: .audio,
            codecID: Int32(AV_CODEC_ID_PCM_F32LE.rawValue), codecName: "pcm_f32le",
            title: nil, language: nil, timeBase: .init(numerator: 1, denominator: Int32(rate)),
            duration: nil, disposition: 0, codedSize: nil, pixelAspectRatio: nil,
            averageFrameRate: nil, sampleRate: rate, channelCount: channels, channelLayout: nil,
            rotationDegrees: 0, isMirrored: false, interlaceMode: .progressive)
        return try AudioDecoder(parameters: parameters, stream: stream, outputCapacity: capacity)
    }

    private func packet(rate: Int, samples: Int, channels: Int = 2,
                        start: Int64 = 0, generation: Int = 1) throws -> FFmpegPacket {
        let values = [Float](repeating: 0.25, count: samples * channels)
        var allocated = av_packet_alloc()
        let raw = try #require(allocated)
        defer { av_packet_free(&allocated) }
        try checkFFmpeg(av_new_packet(raw, Int32(values.count * 4)), operation: "Test PCM packet")
        values.withUnsafeBytes { raw.pointee.data.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count) }
        raw.pointee.pts = start
        raw.pointee.dts = start
        raw.pointee.duration = Int64(samples)
        return try FFmpegPacket(moving: raw, timeBase: .init(num: 1, den: Int32(rate)), generation: generation)
    }
}
