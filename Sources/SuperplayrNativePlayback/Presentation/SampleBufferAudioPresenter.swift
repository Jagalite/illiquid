import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import CNativeAudio
import CFFmpeg

final class SampleBufferAudioPresenter: @unchecked Sendable {
    let renderer = AVSampleBufferAudioRenderer()
    private var formatDescription: CMAudioFormatDescription

    init(sampleRate: Int, channelCount: Int) throws {
        formatDescription = try Self.makeFormatDescription(sampleRate: sampleRate, channelCount: channelCount)
        renderer.audioTimePitchAlgorithm = .spectral
    }

    static func makeFormatDescription(sampleRate: Int, channelCount: Int) throws -> CMAudioFormatDescription {
        guard (1...384_000).contains(sampleRate), [1, 2, 6, 8].contains(channelCount) else {
            throw PresentationError("Unsupported PCM sample rate or channel layout")
        }
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channelCount * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channelCount * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        // Match swresample's canonical output order explicitly, including the
        // distinction between rear and side surround channels in 7.1.
        let header = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        let layoutSize = header + channelCount * MemoryLayout<AudioChannelDescription>.stride
        let storage = UnsafeMutableRawPointer.allocate(byteCount: layoutSize, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: layoutSize)
        let layout = storage.assumingMemoryBound(to: AudioChannelLayout.self)
        layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        layout.pointee.mNumberChannelDescriptions = UInt32(channelCount)
        let descriptions = storage.advanced(by: header).assumingMemoryBound(to: AudioChannelDescription.self)
        for index in 0..<channelCount {
            let label: AudioChannelLabel
            switch superplayr_output_audio_channel(Int32(channelCount), Int32(index)) {
            case AV_CHAN_FRONT_LEFT: label = kAudioChannelLabel_Left
            case AV_CHAN_FRONT_RIGHT: label = kAudioChannelLabel_Right
            case AV_CHAN_FRONT_CENTER: label = kAudioChannelLabel_Center
            case AV_CHAN_LOW_FREQUENCY: label = kAudioChannelLabel_LFEScreen
            case AV_CHAN_BACK_LEFT: label = kAudioChannelLabel_RearSurroundLeft
            case AV_CHAN_BACK_RIGHT: label = kAudioChannelLabel_RearSurroundRight
            case AV_CHAN_SIDE_LEFT: label = kAudioChannelLabel_LeftSurround
            case AV_CHAN_SIDE_RIGHT: label = kAudioChannelLabel_RightSurround
            default: throw PresentationError("Unsupported PCM speaker position")
            }
            descriptions[index].mChannelLabel = label
        }
        var created: CMAudioFormatDescription?
        try checkOSStatus(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &streamDescription,
                layoutSize: layoutSize,
                layout: layout,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &created
            ),
            operation: "Create audio format description"
        )
        guard let created else {
            throw PresentationError("Audio format description was not created")
        }
        return created
    }

    var isReady: Bool { renderer.isReadyForMoreMediaData }
    var failureDescription: String? {
        guard renderer.status == .failed else { return nil }
        return renderer.error?.localizedDescription ?? "Audio renderer failed"
    }
    var volume: Float {
        get { renderer.volume }
        set { renderer.volume = newValue }
    }
    var isMuted: Bool {
        get { renderer.isMuted }
        set { renderer.isMuted = newValue }
    }

    func requestMediaDataWhenReady(
        on queue: DispatchQueue,
        using block: @escaping @Sendable () -> Void
    ) {
        renderer.requestMediaDataWhenReady(on: queue, using: block)
    }

    func stopRequestingMediaData() {
        renderer.stopRequestingMediaData()
    }

    func enqueue(_ frame: NativeDecodedAudioFrame) throws {
        if let failureDescription {
            throw PresentationError(failureDescription)
        }
        guard [1, 2, 6, 8].contains(frame.channelCount) else {
            throw PresentationError("Unsupported PCM channel count")
        }
        let current = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        if current?.mSampleRate != Double(frame.sampleRate) || current?.mChannelsPerFrame != UInt32(frame.channelCount) {
            formatDescription = try Self.makeFormatDescription(sampleRate: frame.sampleRate, channelCount: frame.channelCount)
        }
        renderer.enqueue(try Self.makeSampleBuffer(frame, formatDescription: formatDescription))
    }

    static func makeSampleBuffer(_ frame: NativeDecodedAudioFrame,
                                 formatDescription: CMAudioFormatDescription) throws -> CMSampleBuffer {
        guard frame.sampleCount > 0, frame.sampleRate > 0, [1, 2, 6, 8].contains(frame.channelCount),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              description.mSampleRate == Double(frame.sampleRate), description.mChannelsPerFrame == UInt32(frame.channelCount)
        else { throw PresentationError("PCM frame does not match its presentation format") }
        let (bytes, overflow) = frame.sampleCount.multipliedReportingOverflow(by: frame.channelCount * MemoryLayout<Float>.size)
        guard !overflow, frame.interleavedFloatPCM.count == bytes else {
            throw PresentationError("PCM sample count does not match its backing bytes")
        }
        var blockBuffer: CMBlockBuffer?
        try checkOSStatus(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: frame.interleavedFloatPCM.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: frame.interleavedFloatPCM.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            ),
            operation: "Create audio block buffer"
        )
        guard let blockBuffer else {
            throw PresentationError("Audio block buffer was not created")
        }
        let copyStatus = frame.interleavedFloatPCM.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: bytes.count
            )
        }
        try checkOSStatus(copyStatus, operation: "Copy decoded audio")

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(frame.sampleRate)),
            presentationTimeStamp: frame.presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = frame.channelCount * MemoryLayout<Float>.size
        var sampleBuffer: CMSampleBuffer?
        try checkOSStatus(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: frame.sampleCount,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            ),
            operation: "Create audio sample buffer"
        )
        guard let sampleBuffer else {
            throw PresentationError("Audio sample buffer was not created")
        }
        return sampleBuffer
    }

    func flush() { renderer.flush() }

    func setOutputDevice(_ id: String?) throws {
        guard renderer.audioOutputDeviceUniqueID != id else { return }
        if let error = SPSetAudioOutputDevice(
            Unmanaged.passUnretained(renderer).toOpaque(), id.map { $0 as CFString }
        ) {
            throw PresentationError(error as String)
        }
    }
}
