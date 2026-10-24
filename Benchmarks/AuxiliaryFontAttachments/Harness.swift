import CFFmpeg
import CryptoKit
import Darwin
import Foundation
@testable import AuxiliaryFontInputs

private func failure(_ message: String) -> NSError {
    NSError(domain: "AuxiliaryFontAttachments", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
}

private func bits(_ value: Double) -> String { String(value.bitPattern, radix: 16) }
private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct SizeReceipt: Encodable, Equatable {
    let widthBits: String
    let heightBits: String
    init(_ value: CGSize) {
        widthBits = bits(Double(value.width))
        heightBits = bits(Double(value.height))
    }
}

private struct TimelineReceipt: Encodable, Equatable {
    let status: String
    let secondsBits: String?
    init(_ value: FFmpegMediaInfo.TimelineValue) {
        switch value {
        case .valid(let seconds): status = "valid"; secondsBits = bits(seconds)
        case .unknown: status = "unknown"; secondsBits = nil
        case .invalid: status = "invalid"; secondsBits = nil
        }
    }
}

private struct CapabilityReceipt: Encodable, Equatable {
    let kind: String
    let codec: String?
    init(_ value: NativeSubtitleCapability) {
        switch value {
        case .text: kind = "text"; codec = nil
        case .bitmap: kind = "bitmap"; codec = nil
        case .bitmapUnsupported(let name): kind = "bitmapUnsupported"; codec = name
        case .unsupported(let name): kind = "unsupported"; codec = name
        }
    }
}

private struct StreamReceipt: Encodable, Equatable {
    let index: Int32
    let kind: String
    let codecID: Int32
    let codecName: String
    let title: String?
    let language: String?
    let timeBase: [Int32]
    let durationBits: String?
    let disposition: Int32
    let codedSize: SizeReceipt?
    let pixelAspect: SizeReceipt?
    let averageFrameRateBits: String?
    let sampleRate: Int?
    let channelCount: Int?
    let channelLayout: String?
    let rotationBits: String
    let mirrored: Bool
    let interlaceMode: String
    let displaySize: SizeReceipt?
    let displayName: String
    let subtitleCapability: CapabilityReceipt?

    init(_ value: FFmpegStreamInfo) {
        index = value.index
        kind = value.kind.rawValue
        codecID = value.codecID
        codecName = value.codecName
        title = value.title
        language = value.language
        timeBase = [value.timeBase.numerator, value.timeBase.denominator]
        durationBits = value.duration.map(bits)
        disposition = value.disposition
        codedSize = value.codedSize.map(SizeReceipt.init)
        pixelAspect = value.pixelAspectRatio.map(SizeReceipt.init)
        averageFrameRateBits = value.averageFrameRate.map(bits)
        sampleRate = value.sampleRate
        channelCount = value.channelCount
        channelLayout = value.channelLayout
        rotationBits = bits(value.rotationDegrees)
        mirrored = value.isMirrored
        interlaceMode = value.interlaceMode.rawValue
        displaySize = value.displaySize.map(SizeReceipt.init)
        displayName = value.displayName
        subtitleCapability = value.subtitleCapability.map(CapabilityReceipt.init)
    }
}

private struct AttachmentReceipt: Encodable, Equatable {
    let filename: String
    let mimeType: String?
    let bytes: Int
    let sha256: String
    let supportedFont: Bool
    init(_ value: FontAttachment) {
        filename = value.filename
        mimeType = value.mimeType
        bytes = value.data.count
        sha256 = digest(value.data)
        supportedFont = value.isSupportedFont
    }
}

private struct ChapterReceipt: Encodable, Equatable {
    let title: String?
    let startBits: String
    let endBits: String
}

private struct MediaReceipt: Encodable, Equatable {
    let url: String
    let containerName: String
    let durationBits: String
    let startTimeBits: String
    let durationStatus: TimelineReceipt
    let startTimeStatus: TimelineReceipt
    let streams: [StreamReceipt]
    let chapters: [ChapterReceipt]
    var attachments: [AttachmentReceipt]
    let selectedVideoIndex: Int32?
    let selectedAudioIndex: Int32?
    let selectedSubtitleIndex: Int32?
    let videoStreamIndices: [Int32]
    let audioStreamIndices: [Int32]
    let subtitleStreamIndices: [Int32]

    init(_ value: FFmpegMediaInfo) {
        url = value.url.absoluteString
        containerName = value.containerName
        durationBits = bits(value.duration)
        startTimeBits = bits(value.startTime)
        durationStatus = TimelineReceipt(value.durationStatus)
        startTimeStatus = TimelineReceipt(value.startTimeStatus)
        streams = value.streams.map(StreamReceipt.init)
        chapters = value.chapters.map {
            ChapterReceipt(title: $0.title, startBits: bits($0.start), endBits: bits($0.end))
        }
        attachments = value.attachments.map(AttachmentReceipt.init)
        selectedVideoIndex = value.selectedVideoIndex
        selectedAudioIndex = value.selectedAudioIndex
        selectedSubtitleIndex = value.selectedSubtitleIndex
        videoStreamIndices = value.videoStreams.map(\.index)
        audioStreamIndices = value.audioStreams.map(\.index)
        subtitleStreamIndices = value.subtitleStreams.map(\.index)
    }
}

private struct PacketReceipt: Encodable, Equatable {
    let streamIndex: Int32
    let presentationTimestamp: Int64
    let decodeTimestamp: Int64
    let duration: Int64
    let timeBase: [Int32]
    let generation: Int
    let isCorrupt: Bool
    let isKeyframe: Bool
    let byteCount: Int
    let sha256: String
    let presentationSecondsBits: String?
    let decodeSecondsBits: String?
    let durationSecondsBits: String?

    init(_ packet: FFmpegPacket) {
        streamIndex = packet.streamIndex
        presentationTimestamp = packet.presentationTimestamp
        decodeTimestamp = packet.decodeTimestamp
        duration = packet.duration
        timeBase = [packet.timeBase.numerator, packet.timeBase.denominator]
        generation = packet.generation
        isCorrupt = packet.isCorrupt
        isKeyframe = packet.isKeyframe
        byteCount = packet.byteCount
        sha256 = digest(packet.data ?? Data())
        presentationSecondsBits = packet.presentationSeconds.map(bits)
        decodeSecondsBits = packet.decodeSeconds.map(bits)
        durationSecondsBits = packet.durationSeconds.map(bits)
    }
}

private struct CodecReceipt: Encodable, Equatable {
    let streamIndex: Int32
    let codecType: Int32
    let codecID: Int32
    let codecTag: UInt32
    let format: Int32
    let width: Int32
    let height: Int32
    let sampleRate: Int32
    let channelCount: Int32
    let bitRate: Int64
    let profile: Int32
    let level: Int32
    let extraDataBytes: Int
    let extraDataSHA256: String
    let codecPrivateBytes: Int
    let codecPrivateSHA256: String
}

private struct PlaybackReceipt: Encodable, Equatable {
    let initialPackets: [PacketReceipt]
    let seekSecondsBits: String
    let seekPackets: [PacketReceipt]
    let codecParameters: [CodecReceipt]
}

private func readPackets(_ input: FFmpegInputExecutor, generation: Int) throws -> [PacketReceipt] {
    var packets: [PacketReceipt] = []
    while let packet = try input.readPacket(generation: generation) {
        guard packets.count < 4096 else { throw failure("Fixture exceeds the bounded packet receipt limit") }
        packets.append(PacketReceipt(packet))
    }
    return packets
}

// Receipt generation occurs after all memory/time snapshots. It deliberately
// exercises the real executor's codec, packet, and seek APIs in both variants.
private func playbackReceipt(_ input: FFmpegInputExecutor) throws -> PlaybackReceipt {
    let codecs = try input.mediaInfo.streams.filter {
        $0.kind == .video || $0.kind == .audio || $0.kind == .subtitle
    }.map { stream -> CodecReceipt in
        guard let owned = try input.copyCodecParameters(streamIndex: stream.index) else {
            throw failure("Missing codec parameters for stream \(stream.index)")
        }
        let codecPrivate = input.codecPrivateData(streamIndex: stream.index) ?? Data()
        guard let receipt = owned.withUnsafePointer({ parameters -> CodecReceipt in
            let value = parameters.pointee
            let extra: Data
            if let bytes = value.extradata, value.extradata_size > 0 {
                extra = Data(bytes: bytes, count: Int(value.extradata_size))
            } else {
                extra = Data()
            }
            return CodecReceipt(
                streamIndex: stream.index, codecType: Int32(value.codec_type.rawValue),
                codecID: Int32(value.codec_id.rawValue), codecTag: value.codec_tag,
                format: value.format, width: value.width, height: value.height,
                sampleRate: value.sample_rate, channelCount: value.ch_layout.nb_channels,
                bitRate: value.bit_rate, profile: value.profile, level: value.level,
                extraDataBytes: extra.count, extraDataSHA256: digest(extra),
                codecPrivateBytes: codecPrivate.count, codecPrivateSHA256: digest(codecPrivate)
            )
        }) else { throw failure("Owned codec parameters disappeared") }
        guard receipt.extraDataBytes == receipt.codecPrivateBytes,
              receipt.extraDataSHA256 == receipt.codecPrivateSHA256 else {
            throw failure("Codec-private data differs from the owned parameter copy")
        }
        return receipt
    }
    let initial = try readPackets(input, generation: 7)
    let seekSeconds = 1.0
    try input.seek(to: seekSeconds, exact: true)
    let afterSeek = try readPackets(input, generation: 8)
    guard !initial.isEmpty, !afterSeek.isEmpty else { throw failure("Fixture has no packet or seek coverage") }
    return PlaybackReceipt(initialPackets: initial, seekSecondsBits: bits(seekSeconds),
                           seekPackets: afterSeek, codecParameters: codecs)
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

private struct MemoryReceipt: Encodable {
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
    let peakRSSBytes: Int64

    static func capture(usage: rusage) throws -> Self {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw failure("TASK_VM_INFO failed: \(result)") }
        return Self(residentBytes: info.resident_size, physicalFootprintBytes: info.phys_footprint,
                    peakRSSBytes: Int64(usage.ru_maxrss))
    }
}

private struct Observation: Encodable {
    let schemaVersion = 1
    let mode = "executor-group"
    let auxiliaryCount: Int
    let auxiliaryFontOmissionEnabled: Bool
    let primaryAttachmentBytes: Int
    let auxiliaryAttachmentBytes: Int
    let totalSwiftAttachmentBytes: Int
    let openWallSeconds: Double
    let openCPUSeconds: Double
    let before: MemoryReceipt
    let after: MemoryReceipt
    let metadata: [MediaReceipt]
    let playbackReceipts: [PlaybackReceipt]
    let ffmpegVersion: String
    let avformatVersion: UInt32
    let avcodecVersion: UInt32
    let avutilVersion: UInt32
}

@main
private enum AuxiliaryFontAttachmentHarness {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, let auxiliaryCount = Int(arguments[2]), (0...2).contains(auxiliaryCount) else {
            throw failure("Usage: harness FIXTURE AUXILIARY_COUNT (0...2)")
        }
        av_log_set_level(AV_LOG_QUIET)
        let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        #if AUXILIARY_FONT_OMISSION
        let omissionEnabled = true
        #else
        let omissionEnabled = false
        #endif

        // No warm-up opens: the first snapshot precedes every native input.
        let beforeUsage = try usage()
        let before = try MemoryReceipt.capture(usage: beforeUsage)
        let startUsage = try usage()
        let started = DispatchTime.now().uptimeNanoseconds
        var inputs: [FFmpegInputExecutor] = [try FFmpegInputExecutor(url: url)]
        for _ in 0..<auxiliaryCount {
            #if AUXILIARY_FONT_OMISSION
            inputs.append(try FFmpegInputExecutor(url: url, includeFontAttachments: false))
            #else
            inputs.append(try FFmpegInputExecutor(url: url))
            #endif
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        let afterUsage = try usage()

        let observation = try withExtendedLifetime(inputs) {
            // The complete group, including FFmpeg's own attachment extradata,
            // is still live here. Hashing/parity work starts only after capture.
            let after = try MemoryReceipt.capture(usage: afterUsage)
            let counts = inputs.map { $0.mediaInfo.attachments.reduce(0) { $0 + $1.data.count } }
            let auxiliaryBytes = counts.dropFirst().reduce(0, +)
            if omissionEnabled, auxiliaryBytes != 0 { throw failure("Auxiliary font bytes were retained") }
            let metadata = inputs.map { MediaReceipt($0.mediaInfo) }
            var comparablePrimary = metadata[0]
            comparablePrimary.attachments = []
            for auxiliary in metadata.dropFirst() {
                var comparableAuxiliary = auxiliary
                comparableAuxiliary.attachments = []
                guard comparablePrimary == comparableAuxiliary else {
                    throw failure("Auxiliary metadata differs beyond omitted font attachments")
                }
            }
            let playback = try inputs.map(playbackReceipt)
            guard playback.dropFirst().allSatisfy({ $0 == playback[0] }) else {
                throw failure("Auxiliary codec/packet/seek receipts differ from the primary input")
            }
            return Observation(
                auxiliaryCount: auxiliaryCount, auxiliaryFontOmissionEnabled: omissionEnabled,
                primaryAttachmentBytes: counts[0], auxiliaryAttachmentBytes: auxiliaryBytes,
                totalSwiftAttachmentBytes: counts.reduce(0, +), openWallSeconds: elapsed,
                openCPUSeconds: cpuSeconds(afterUsage) - cpuSeconds(startUsage), before: before, after: after,
                metadata: metadata, playbackReceipts: playback,
                ffmpegVersion: String(cString: av_version_info()), avformatVersion: avformat_version(),
                avcodecVersion: avcodec_version(), avutilVersion: avutil_version()
            )
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(observation), as: UTF8.self))
    }
}
