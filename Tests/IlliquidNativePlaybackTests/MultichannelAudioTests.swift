import AudioToolbox
import CFFmpeg
import CoreMedia
import Foundation
import IlliquidCore
import Testing
@testable import IlliquidNativePlayback

@Suite("Negotiated multichannel PCM")
struct MultichannelAudioTests {
    @Test @MainActor func pausedMutedSessionSubmitsNegotiatedPCMAndShutsDown() async throws {
        let root = ProcessInfo.processInfo.environment["ILLIQUID_NATIVE_FIXTURE_DIR"]
            ?? FileManager.default.currentDirectoryPath + "/TestFixtures/Generated"
        let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("audio-7.1.flac")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let presentation = try NativePresentationCoordinator()
        defer { presentation.terminate() }
        presentation.setVolume(0, muted: true)
        presentation.audioOutputCapacity.update(channels: 8)
        let subtitles = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        let session = try MediaSession(url: url, presentation: presentation, subtitles: subtitles)
        defer { session.stop() }
        session.start(rate: 0)
        for _ in 0..<300 where session.snapshot().audioOutputChannels == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = session.snapshot()
        #expect(snapshot.audioOutputChannels == 8)
        #expect(snapshot.audioOutputSampleRate == 48_000)
        #expect(snapshot.audioDownmixOccurred == false)
        #expect(snapshot.rendererFailure == nil)
        session.stop()
        #expect(await Task.detached { session.waitForShutdown() }.value)
    }

    @Test func discoveryRequiresBothStreamCapacityAndPreferredSpeakerLayout() {
        #expect(NativeAudioDeviceMonitor.negotiatedChannelCapacity(streamChannels: 8, preferredChannels: 8) == 8)
        #expect(NativeAudioDeviceMonitor.negotiatedChannelCapacity(streamChannels: 8, preferredChannels: 6) == 6)
        #expect(NativeAudioDeviceMonitor.negotiatedChannelCapacity(streamChannels: 2, preferredChannels: 8) == 2)
        #expect(NativeAudioDeviceMonitor.negotiatedChannelCapacity(streamChannels: 8, preferredChannels: nil) == 2)
        #expect(NativeAudioDeviceMonitor.negotiatedChannelCapacity(streamChannels: nil, preferredChannels: 8) == 2)
        #expect(NativeAudioDeviceMonitor.negotiatedChannelCapacity(streamChannels: 4, preferredChannels: 4) == 2)
        let catalog = NativeAudioDeviceCatalog(devices: [
            .init(id: "speakers", name: "Speakers", isDefault: true, isSelected: false),
            .init(id: "receiver", name: "Receiver", isDefault: false, isSelected: false),
        ], channelCapacities: ["speakers": 2, "receiver": 8])
        #expect(catalog.capacity(selectedID: nil) == 2)
        #expect(catalog.capacity(selectedID: "receiver") == 8)
        #expect(catalog.capacity(selectedID: "disconnected") == 2)
    }

    @Test func speakerPositionsDistinguishSurroundFromArbitraryChannelCounts() throws {
        for (tag, expected) in [(kAudioChannelLayoutTag_MPEG_5_1_A, 6), (kAudioChannelLayoutTag_MPEG_7_1_C, 8),
                                (kAudioChannelLayoutTag_Hexagonal, 2), (kAudioChannelLayoutTag_Stereo, 2)] {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = tag
            withUnsafePointer(to: &layout) {
                #expect(NativeAudioDeviceMonitor.preferredSurroundCapacity(UnsafeRawPointer($0), byteCount: MemoryLayout<AudioChannelLayout>.size) == expected)
                #expect(NativeAudioDeviceMonitor.preferredSurroundCapacity(UnsafeRawPointer($0), byteCount: 4) == nil)
            }
        }
        let format = try SampleBufferAudioPresenter.makeFormatDescription(sampleRate: 48_000, channelCount: 8)
        var size = 0
        let layout = try #require(CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size))
        #expect(NativeAudioDeviceMonitor.preferredSurroundCapacity(UnsafeRawPointer(layout), byteCount: size) == 8)
        #expect(NativeAudioDeviceMonitor.preferredSurroundCapacity(UnsafeRawPointer(layout), byteCount: 12) == nil)
    }

    @Test func surroundOutputNeverUpmixesAndUnknownRoutesKeepStereo() {
        let output = NativeAudioOutputCapacity(channels: 8)
        #expect(output.outputChannels(forSourceChannels: 2) == 2)
        #expect(output.outputChannels(forSourceChannels: 6) == 6)
        #expect(output.outputChannels(forSourceChannels: 8) == 8)
        #expect(output.outputChannels(forSourceChannels: 4) == 2)
        #expect(output.update(channels: 2))
        #expect(!output.update(channels: 2))
        #expect(output.outputChannels(forSourceChannels: 8) == 2)
    }

    @Test(arguments: [6, 8])
    func decoderAndSampleBufferPreserveEachCanonicalChannel(channels: Int) throws {
        let decoder = try makeDecoder(channels: channels, capacity: .init(channels: channels))
        let decoded = try #require(decoder.decode(packet(channels: channels, start: 0)).first)
        #expect(decoded.channelCount == channels)
        #expect(!decoded.downmixOccurred)
        let samples = decoded.interleavedFloatPCM.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        for index in samples.indices { #expect(samples[index] == Float(index % channels + 1) / 32) }
        let description = try SampleBufferAudioPresenter.makeFormatDescription(sampleRate: decoded.sampleRate, channelCount: channels)
        var layoutSize = 0
        let layout = try #require(CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize))
        #expect(layout.pointee.mNumberChannelDescriptions == UInt32(channels))
        let header = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        let descriptions = UnsafeRawPointer(layout).advanced(by: header).assumingMemoryBound(to: AudioChannelDescription.self)
        let expected: [AudioChannelLabel] = channels == 6
            ? [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
               kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
            : [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
               kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
               kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
        #expect((0..<channels).map { descriptions[$0].mChannelLabel } == expected)
        let sampleBuffer = try SampleBufferAudioPresenter.makeSampleBuffer(decoded, formatDescription: description)
        #expect(CMSampleBufferGetNumSamples(sampleBuffer) == decoded.sampleCount)
        #expect(CMSampleBufferGetPresentationTimeStamp(sampleBuffer) == decoded.presentationTime)
        let backing = try #require(CMSampleBufferGetDataBuffer(sampleBuffer))
        var copy = Data(count: decoded.interleavedFloatPCM.count)
        #expect(copy.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(backing, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        } == noErr)
        #expect(copy == decoded.interleavedFloatPCM)
    }

    @Test func routeCapacityChangeRevisesFormatAndRetainsTheMediaTimeFloor() throws {
        let capacity = NativeAudioOutputCapacity(channels: 8)
        let decoder = try makeDecoder(channels: 8, capacity: capacity)
        let first = try #require(decoder.decode(packet(channels: 8, start: 0)).first)
        #expect(capacity.update(channels: 2))
        let second = try #require(decoder.decode(packet(channels: 8, start: 256)).first)
        #expect(second.channelCount == 2)
        #expect(second.downmixOccurred)
        #expect(second.formatRevision > first.formatRevision)
        #expect(second.presentationTime.seconds >= 256.0 / 48_000)
        #expect(second.interleavedFloatPCM.count == second.sampleCount * 2 * MemoryLayout<Float>.size)
        let trimmed = try #require(second.trimmingSamples(before: 300.0 / 48_000))
        #expect(trimmed.channelCount == 2)
        #expect(trimmed.presentationTime.seconds >= 300.0 / 48_000)
        let wrong = try SampleBufferAudioPresenter.makeFormatDescription(sampleRate: 48_000, channelCount: 8)
        #expect(throws: PresentationError.self) { try SampleBufferAudioPresenter.makeSampleBuffer(second, formatDescription: wrong) }
    }

    private func makeDecoder(channels: Int, capacity: NativeAudioOutputCapacity) throws -> AudioDecoder {
        var allocated = avcodec_parameters_alloc()
        let parameters = try #require(allocated)
        defer { avcodec_parameters_free(&allocated) }
        parameters.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        parameters.pointee.codec_id = AV_CODEC_ID_PCM_F32LE
        parameters.pointee.sample_rate = 48_000
        av_channel_layout_default(&parameters.pointee.ch_layout, Int32(channels))
        let stream = FFmpegStreamInfo(index: 0, kind: .audio, codecID: Int32(AV_CODEC_ID_PCM_F32LE.rawValue),
            codecName: "pcm_f32le", title: nil, language: nil, timeBase: .init(numerator: 1, denominator: 48_000),
            duration: nil, disposition: 0, codedSize: nil, pixelAspectRatio: nil, averageFrameRate: nil,
            sampleRate: 48_000, channelCount: channels, channelLayout: nil, rotationDegrees: 0, isMirrored: false, interlaceMode: .progressive)
        return try AudioDecoder(parameters: parameters, stream: stream, outputCapacity: capacity)
    }

    private func packet(channels: Int, start: Int64) throws -> FFmpegPacket {
        let samples = (0..<(256 * channels)).map { Float($0 % channels + 1) / 32 }
        var allocated = av_packet_alloc()
        let raw = try #require(allocated)
        defer { av_packet_free(&allocated) }
        #expect(av_new_packet(raw, Int32(samples.count * MemoryLayout<Float>.size)) >= 0)
        samples.withUnsafeBytes { raw.pointee.data.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count) }
        raw.pointee.pts = start
        raw.pointee.dts = start
        raw.pointee.duration = 256
        return try FFmpegPacket(moving: raw, timeBase: .init(num: 1, den: 48_000), generation: 0)
    }
}
