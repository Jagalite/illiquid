import CFFmpeg
import Foundation

enum FFmpegDemuxReadRetryDecision: Equatable {
    case retry
    case fail
}

/// Bounded no-progress policy for `av_read_frame`. A successful packet creates
/// a fresh policy through the next `readPacket` call, so sparse errors never
/// consume a lifetime budget.
struct FFmpegDemuxReadRetryPolicy {
    static let maximumConsecutiveInvalidDataReads = 256
    static let maximumConsecutiveOtherErrors = 10
    static let maximumNoProgressSeconds = 1.0

    private(set) var invalidDataReads = 0
    private(set) var otherErrors = 0

    mutating func decision(
        for code: Int32,
        elapsedNoProgressSeconds: TimeInterval
    ) -> FFmpegDemuxReadRetryDecision {
        guard elapsedNoProgressSeconds < Self.maximumNoProgressSeconds else {
            return .fail
        }
        if code == superplayr_averror_invaliddata() {
            guard invalidDataReads < Self.maximumConsecutiveInvalidDataReads else {
                return .fail
            }
            invalidDataReads += 1
            return .retry
        }
        guard code != superplayr_averror_exit(),
              otherErrors < Self.maximumConsecutiveOtherErrors
        else {
            return .fail
        }
        otherErrors += 1
        return .retry
    }
}

final class FFmpegDemuxer {
    private var terminalPacketWasCorrupt = false
    private var context: UnsafeMutablePointer<AVFormatContext>?
    private let interruptState: AnyObject?
    let mediaInfo: FFmpegMediaInfo

    init(url: URL, interruptState: AnyObject? = nil) throws {
        guard url.isFileURL else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        self.interruptState = interruptState
        var openedContext: UnsafeMutablePointer<AVFormatContext>?
        if let interruptState {
            openedContext = superplayr_alloc_interruptible_format_context(
                ffmpegInputInterruptCallback,
                Unmanaged.passUnretained(interruptState).toOpaque()
            )
            guard openedContext != nil else {
                throw FFmpegError(
                    operation: "Allocate interruptible input context",
                    code: superplayr_averror_nomem()
                )
            }
        }
        let openResult = url.path.withCString {
            avformat_open_input(&openedContext, $0, nil, nil)
        }
        try checkFFmpeg(openResult, operation: "Open \(url.lastPathComponent)")
        guard let openedContext else {
            throw FFmpegError(operation: "Open media", code: superplayr_averror_unknown())
        }

        do {
            try checkFFmpeg(
                avformat_find_stream_info(openedContext, nil),
                operation: "Read stream metadata"
            )
            context = openedContext
            mediaInfo = Self.makeMediaInfo(url: url, context: openedContext)
        } catch {
            var temporary: UnsafeMutablePointer<AVFormatContext>? = openedContext
            avformat_close_input(&temporary)
            throw error
        }
    }

    deinit {
        avformat_close_input(&context)
    }

    func readPacket(generation: Int) throws -> FFmpegPacket? {
        guard let context else { return nil }
        guard let temporary = av_packet_alloc() else {
            throw FFmpegError(
                operation: "Allocate demux packet",
                code: superplayr_averror_nomem()
            )
        }
        defer {
            var packet: UnsafeMutablePointer<AVPacket>? = temporary
            av_packet_free(&packet)
        }

        var retryPolicy = FFmpegDemuxReadRetryPolicy()
        let noProgressStart = ProcessInfo.processInfo.systemUptime
        while true {
            let result = av_read_frame(context, temporary)
            if result == superplayr_averror_eof() {
                if let input = context.pointee.pb,
                   input.pointee.error < 0,
                   input.pointee.error != superplayr_averror_eof()
                {
                    try checkFFmpeg(input.pointee.error, operation: "Read media input")
                }
                if terminalPacketWasCorrupt {
                    throw FFmpegError(operation: "Read truncated media packet", code: superplayr_averror_invaliddata())
                }
                return nil
            }
            if result < 0,
               retryPolicy.decision(
                for: result,
                elapsedNoProgressSeconds:
                    ProcessInfo.processInfo.systemUptime - noProgressStart
               ) == .retry
            {
                // Matroska resynchronization commonly reports INVALIDDATA, while
                // custom and remote AVIO sources can transiently report EAGAIN or
                // another read error. Keep all retries bounded by both a count and
                // elapsed no-progress time, and never retry interruption.
                av_packet_unref(temporary)
                if result == superplayr_averror_eagain() {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                continue
            }
            try checkFFmpeg(result, operation: "Read media packet")

            let index = Int(temporary.pointee.stream_index)
            guard index >= 0, index < Int(context.pointee.nb_streams),
                  let stream = context.pointee.streams[index]
            else {
                av_packet_unref(temporary)
                continue
            }
            // Some demuxers return a partial packet followed by EOF with no
            // AVIO error. Preserve FFmpeg's explicit corruption signal only
            // at physical input EOF; a later healthy packet clears it.
            terminalPacketWasCorrupt = temporary.pointee.flags & AV_PKT_FLAG_CORRUPT != 0
                && (context.pointee.pb?.pointee.eof_reached ?? 0) != 0
            let packet = try FFmpegPacket(
                moving: temporary,
                timeBase: stream.pointee.time_base,
                generation: generation
            )
            return packet
        }
    }

    func seek(to seconds: Double, exact: Bool) throws {
        guard let context else { return }
        guard let target = Int64(exactly: (seconds * Double(AV_TIME_BASE)).rounded()) else {
            throw FFmpegError(operation: "Seek timestamp outside supported range", code: -22)
        }
        // Both preview and final seeks restart at a keyframe. Exact seeks become
        // exact by decoding forward and rejecting output before the target.
        let flags = AVSEEK_FLAG_BACKWARD
        let result = avformat_seek_file(
            context,
            -1,
            Int64.min,
            target,
            Int64.max,
            flags
        )
        try checkFFmpeg(result, operation: "Seek media")
        avformat_flush(context)
        terminalPacketWasCorrupt = false
    }

    /// Resolves subtitle packets that are already active at a seek target.
    ///
    /// A normal video-keyframe seek can land after the subtitle packet whose
    /// duration spans the requested time. This bounded, stream-indexed lookup
    /// runs on the independent subtitle input. PGS reconstruction starts at an
    /// acquisition/epoch packet, and retains intervening palette/object updates.
    func activeSubtitlePackets(
        streamIndex: Int32,
        at seconds: Double,
        generation: Int
    ) throws -> [FFmpegPacket] {
        guard let context,
              streamIndex >= 0,
              streamIndex < Int32(context.pointee.nb_streams),
              let stream = context.pointee.streams[Int(streamIndex)]
        else {
            return []
        }

        let timeBase = stream.pointee.time_base
        guard timeBase.num > 0, timeBase.den > 0 else { return [] }
        let codec = stream.pointee.codecpar?.pointee.codec_id
        let isPGS = codec == AV_CODEC_ID_HDMV_PGS_SUBTITLE
        let isDVB = codec == AV_CODEC_ID_DVB_SUBTITLE
        let needsAcquisition = isPGS || isDVB
        let isBitmap = needsAcquisition || codec == AV_CODEC_ID_DVD_SUBTITLE
        var compositionPageID: UInt16?
        if isDVB, let parameters = stream.pointee.codecpar,
           let extra = parameters.pointee.extradata,
           parameters.pointee.extradata_size >= 4,
           parameters.pointee.extradata_size == 4 || parameters.pointee.extradata_size % 5 == 0 {
            compositionPageID = UInt16(extra[0]) * 256 + UInt16(extra[1])
        }
        var inspectedPackets = 0
        var inspectedBytes = 0
        let beginning = min(mediaInfo.startTime, seconds)
        var searchTime = seconds
        for attempt in 0..<(needsAcquisition ? 6 : 1) {
            let ticks = (searchTime * Double(timeBase.den) / Double(timeBase.num)).rounded()
            guard ticks.isFinite, ticks > Double(Int64.min), ticks < Double(Int64.max) else {
                throw PresentationError("Subtitle seek timestamp is outside the supported range")
            }
            let target = Int64(ticks)
            try checkFFmpeg(avformat_seek_file(context, streamIndex, Int64.min, target, target, AVSEEK_FLAG_BACKWARD),
                            operation: "Seek subtitle stream")
            avformat_flush(context)
            terminalPacketWasCorrupt = false
            var active: [FFmpegPacket] = []
            var foundAcquisition = !needsAcquisition
            while inspectedPackets < 4_096, inspectedBytes < 32 * 1_024 * 1_024 {
                guard let packet = try readPacket(generation: generation) else { break }
                inspectedPackets += 1
                inspectedBytes += packet.byteCount
                guard packet.streamIndex == streamIndex else { continue }
                if let start = packet.presentationSeconds ?? packet.decodeSeconds {
                    if start > seconds + 0.001 { break }
                    if !isBitmap {
                        let duration = max(packet.durationSeconds ?? 5, 0.01)
                        if start + duration > seconds { active.append(packet) }
                        continue
                    }
                } else if !isBitmap { continue }
                let acquisition = needsAcquisition && packet.data.map { data in
                    isPGS ? PGSSubtitlePacket.isAcquisition(data)
                        : DVBSubtitlePacket.isAcquisition(data, compositionPageID: compositionPageID)
                } == true
                if acquisition {
                    active.removeAll()
                    foundAcquisition = true
                }
                active.append(packet)
            }
            guard inspectedPackets < 4_096, inspectedBytes < 32 * 1_024 * 1_024 else {
                // Text cues are self-contained. Sparse captions (and imperfect
                // container indexes) can exhaust this look-back budget while
                // scanning unrelated audio/video packets. Keep the active cues
                // found so far; the caller still seeks to the target and resumes
                // normal reading. Only bitmap acquisition requires a complete
                // reconstructed display set before decoding can continue.
                if !isBitmap { return active }
                throw PresentationError("Subtitle seek reconstruction exceeded its bounded packet/byte search")
            }
            if foundAcquisition { return active }
            if searchTime <= beginning {
                if active.isEmpty { return [] }
                break
            }
            // Most indexed bitmap seeks already land on an acquisition. If the
            // nearest packet reuses old objects, widen the existing input's
            // search, retaining one cumulative packet/byte budget.
            searchTime = max(beginning, seconds - 30 * pow(2, Double(attempt)))
        }
        throw PresentationError("Bitmap subtitle seek could not reconstruct a complete display set within its bounded search")
    }

    func codecParameters(
        streamIndex: Int32
    ) -> UnsafePointer<AVCodecParameters>? {
        guard let context,
              streamIndex >= 0,
              streamIndex < Int32(context.pointee.nb_streams),
              let stream = context.pointee.streams[Int(streamIndex)],
              let parameters = stream.pointee.codecpar
        else { return nil }
        return UnsafePointer(parameters)
    }

    func codecPrivateData(streamIndex: Int32) -> Data? {
        guard let parameters = codecParameters(streamIndex: streamIndex),
              let data = parameters.pointee.extradata,
              parameters.pointee.extradata_size > 0
        else { return nil }
        return Data(bytes: data, count: Int(parameters.pointee.extradata_size))
    }

    private static func makeMediaInfo(
        url: URL,
        context: UnsafeMutablePointer<AVFormatContext>
    ) -> FFmpegMediaInfo {
        var streams: [FFmpegStreamInfo] = []
        var attachments: [FontAttachment] = []

        for index in 0..<Int(context.pointee.nb_streams) {
            guard let stream = context.pointee.streams[index],
                  let parameters = stream.pointee.codecpar
            else { continue }

            let mediaType = parameters.pointee.codec_type
            let kind: NativeStreamKind = switch mediaType {
            case AVMEDIA_TYPE_VIDEO: .video
            case AVMEDIA_TYPE_AUDIO: .audio
            case AVMEDIA_TYPE_SUBTITLE: .subtitle
            case AVMEDIA_TYPE_ATTACHMENT: .attachment
            default: .other
            }
            let codecName = avcodec_get_name(parameters.pointee.codec_id)
                .map(String.init(cString:)) ?? "unknown"
            let title = metadataValue(stream.pointee.metadata, key: "title")
            let language = metadataValue(stream.pointee.metadata, key: "language")
            let timeBase = FFmpegRational(stream.pointee.time_base)
            let duration = stream.pointee.duration == superplayr_nopts_value()
                ? nil
                : MediaTime.seconds(stream.pointee.duration, timeBase: timeBase)

            let codedSize: CGSize? = parameters.pointee.width > 0 && parameters.pointee.height > 0
                ? CGSize(
                    width: Int(parameters.pointee.width),
                    height: Int(parameters.pointee.height)
                )
                : nil
            let sampleAspect = stream.pointee.sample_aspect_ratio
            let pixelAspect: CGSize? = sampleAspect.num > 0 && sampleAspect.den > 0
                ? CGSize(width: Int(sampleAspect.num), height: Int(sampleAspect.den))
                : nil
            let averageRate = stream.pointee.avg_frame_rate
            let framesPerSecond: Double? = averageRate.num > 0 && averageRate.den > 0
                ? Double(averageRate.num) / Double(averageRate.den)
                : nil
            let channelCount = parameters.pointee.ch_layout.nb_channels > 0
                ? Int(parameters.pointee.ch_layout.nb_channels)
                : nil
            var channelLayoutBuffer = [CChar](repeating: 0, count: 128)
            let channelLayoutResult = superplayr_codecpar_channel_layout_name(
                parameters,
                &channelLayoutBuffer,
                channelLayoutBuffer.count
            )
            let channelLayout = channelLayoutResult >= 0
                ? stringFromCStringBuffer(channelLayoutBuffer)
                : nil
            let rotation = superplayr_codecpar_rotation_degrees(parameters)
            let isMirrored = superplayr_codecpar_display_matrix_is_mirrored(parameters) != 0
            let interlaceMode = NativeInterlaceMode(
                ffmpegFieldOrder: Int32(superplayr_codecpar_field_order(parameters))
            )

            let info = FFmpegStreamInfo(
                index: Int32(index),
                kind: kind,
                codecID: Int32(parameters.pointee.codec_id.rawValue),
                codecName: codecName,
                title: title,
                language: language,
                timeBase: timeBase,
                duration: duration,
                disposition: stream.pointee.disposition,
                codedSize: codedSize,
                pixelAspectRatio: pixelAspect,
                averageFrameRate: framesPerSecond,
                sampleRate: parameters.pointee.sample_rate > 0
                    ? Int(parameters.pointee.sample_rate)
                    : nil,
                channelCount: channelCount,
                channelLayout: channelLayout,
                rotationDegrees: rotation,
                isMirrored: isMirrored,
                interlaceMode: interlaceMode
            )
            streams.append(info)

            if kind == .attachment,
               let data = parameters.pointee.extradata,
               parameters.pointee.extradata_size > 0
            {
                attachments.append(FontAttachment(
                    filename: metadataValue(stream.pointee.metadata, key: "filename")
                        ?? title
                        ?? "attachment-\(index)",
                    mimeType: metadataValue(stream.pointee.metadata, key: "mimetype"),
                    data: Data(bytes: data, count: Int(parameters.pointee.extradata_size))
                ))
            }
        }

        let timelineOrigin = context.pointee.start_time == superplayr_nopts_value()
            ? 0
            : Double(context.pointee.start_time) / Double(AV_TIME_BASE)
        let chapters = (0..<Int(superplayr_chapter_count(context))).compactMap { index
            -> (title: String?, start: Double, end: Double)? in
            guard let chapter = superplayr_chapter_at(context, UInt32(index)) else { return nil }
            let timeBase = FFmpegRational(chapter.pointee.time_base)
            let sourceStart = MediaTime.seconds(chapter.pointee.start, timeBase: timeBase)
            let sourceEnd = MediaTime.seconds(chapter.pointee.end, timeBase: timeBase)
            return (
                metadataValue(chapter.pointee.metadata, key: "title"),
                max(sourceStart - timelineOrigin, 0),
                max(sourceEnd - timelineOrigin, 0)
            )
        }

        let inputFormatName = context.pointee.iformat.pointee.name
            .map(String.init(cString:)) ?? "unknown"
        let durationStatus: FFmpegMediaInfo.TimelineValue
        if context.pointee.duration == superplayr_nopts_value() {
            durationStatus = .unknown
        } else {
            let value = Double(context.pointee.duration) / Double(AV_TIME_BASE)
            durationStatus = value.isFinite && value >= 0 ? .valid(value) : .invalid
        }
        let startStatus: FFmpegMediaInfo.TimelineValue
        if context.pointee.start_time == superplayr_nopts_value() {
            startStatus = .unknown
        } else {
            let value = Double(context.pointee.start_time) / Double(AV_TIME_BASE)
            startStatus = value.isFinite ? .valid(value) : .invalid
        }
        let duration = if case .valid(let value) = durationStatus { value } else { 0.0 }
        let start = if case .valid(let value) = startStatus { value } else { 0.0 }

        return FFmpegMediaInfo(
            url: url,
            containerName: inputFormatName,
            duration: max(0, duration),
            startTime: start,
            durationStatus: durationStatus,
            startTimeStatus: startStatus,
            streams: streams,
            chapters: chapters,
            attachments: attachments.filter(\.isSupportedFont),
            selectedVideoIndex: bestStream(
                context,
                type: AVMEDIA_TYPE_VIDEO
            ),
            selectedAudioIndex: bestStream(
                context,
                type: AVMEDIA_TYPE_AUDIO
            ),
            selectedSubtitleIndex: bestPlayableSubtitleIndex(context, streams: streams)
        )
    }

    private static func bestPlayableSubtitleIndex(
        _ context: UnsafeMutablePointer<AVFormatContext>,
        streams: [FFmpegStreamInfo]
    ) -> Int32? {
        let playable = streams.filter {
            $0.kind == .subtitle && $0.subtitleCapability?.isPlayable == true
        }
        guard !playable.isEmpty else { return nil }
        let preferred = bestStream(context, type: AVMEDIA_TYPE_SUBTITLE)
        return playable.first(where: { $0.index == preferred })?.index ?? playable.first?.index
    }

    private static func bestStream(
        _ context: UnsafeMutablePointer<AVFormatContext>,
        type: AVMediaType
    ) -> Int32? {
        let index = av_find_best_stream(context, type, -1, -1, nil, 0)
        return index >= 0 ? index : nil
    }

    private static func metadataValue(
        _ dictionary: OpaquePointer?,
        key: String
    ) -> String? {
        key.withCString { keyPointer in
            superplayr_metadata_value(dictionary, keyPointer).map(String.init(cString:))
        }
    }
}
