import CFFmpeg
import CoreGraphics
import Foundation

struct NativeDecodedSubtitleEvent: Sendable {
    let assData: Data
    let presentationSeconds: Double
    let durationSeconds: Double
    let generation: Int
    var bitmapComposition: NativeBitmapSubtitleComposition? = nil
}

/// Text codecs become ASS events; bitmap codecs retain display-set semantics
/// and become bounded premultiplied BGRA regions. Libass typesets text only.
final class SubtitleDecoder {
    private var context: UnsafeMutablePointer<AVCodecContext>?
    private var result: UnsafeMutablePointer<superplayr_subtitle_result>?
    private let stream: FFmpegStreamInfo
    private let memoryBudget: SubtitleMemoryBudget?
    private let fallbackCanvasSize: CGSize?
    private let bitmapParameters: OwnedCodecParameters?
    private var pgsPresentation: PGSSubtitlePresentation?

    init(
        parameters: UnsafePointer<AVCodecParameters>,
        stream: FFmpegStreamInfo,
        memoryBudget: SubtitleMemoryBudget? = nil,
        fallbackCanvasSize: CGSize? = nil
    ) throws {
        self.stream = stream
        self.memoryBudget = memoryBudget
        self.fallbackCanvasSize = fallbackCanvasSize
        bitmapParameters = stream.subtitleCapability == .bitmap ? try OwnedCodecParameters(copying: parameters) : nil
        var createdContext: UnsafeMutablePointer<AVCodecContext>?
        try checkFFmpeg(
            superplayr_create_decoder(parameters, 0, &createdContext, nil),
            operation: "Open \(stream.codecName) subtitle decoder"
        )
        guard let createdContext,
              let createdResult = superplayr_subtitle_result_alloc()
        else {
            avcodec_free_context(&createdContext)
            throw FFmpegError(
                operation: "Allocate subtitle decoder output",
                code: superplayr_averror_nomem()
            )
        }
        context = createdContext
        createdContext.pointee.pkt_timebase = AVRational(num: stream.timeBase.numerator, den: stream.timeBase.denominator)
        result = createdResult
    }

    deinit {
        superplayr_subtitle_result_free(result)
        result = nil
        avcodec_free_context(&context)
    }

    func decode(_ packet: FFmpegPacket) throws -> [NativeDecodedSubtitleEvent] {
        guard let context, let result, let packetPointer = packet.pointer else {
            return []
        }
        if stream.codecID == Int32(AV_CODEC_ID_HDMV_PGS_SUBTITLE.rawValue),
           let data = packet.data, let presentation = try PGSSubtitlePresentation.update(in: data) {
            pgsPresentation = presentation
        }
        try checkFFmpeg(
            superplayr_decode_subtitle(context, packetPointer, result),
            operation: "Decode \(stream.codecName) subtitle packet"
        )
        guard superplayr_subtitle_result_has_output(result) != 0 else {
            return []
        }

        let packetStart = packet.presentationSeconds ?? packet.decodeSeconds ?? 0
        let decodedPTS = superplayr_subtitle_result_pts(result)
        let baseSeconds = decodedPTS == superplayr_nopts_value()
            ? packetStart
            : Double(decodedPTS) / Double(AV_TIME_BASE)
        let relativeStart = Double(superplayr_subtitle_result_start_ms(result)) / 1_000
        let relativeEnd = Double(superplayr_subtitle_result_end_ms(result)) / 1_000
        let start = baseSeconds + relativeStart
        let decodedDuration = relativeEnd - relativeStart
        let duration = decodedDuration > 0
            ? decodedDuration
            : max(packet.durationSeconds ?? 5, 0.01)

        if stream.subtitleCapability == .bitmap {
            let composition = try bitmapComposition(result, context: context,
                duration: superplayr_subtitle_result_end_ms(result) == UInt32.max ? nil : duration)
            return [NativeDecodedSubtitleEvent(assData: Data(), presentationSeconds: start,
                durationSeconds: duration, generation: packet.generation, bitmapComposition: composition)]
        }

        var events: [NativeDecodedSubtitleEvent] = []
        let count = Int(superplayr_subtitle_result_rect_count(result))
        guard count <= 256 else { throw PresentationError("Subtitle region limit exceeded") }
        events.reserveCapacity(count)
        for index in 0..<count {
            guard let ass = superplayr_subtitle_result_ass(result, UInt32(index)) else {
                continue
            }
            events.append(NativeDecodedSubtitleEvent(
                assData: Data(String(cString: ass).utf8),
                presentationSeconds: start,
                durationSeconds: duration,
                generation: packet.generation
            ))
        }
        return events
    }

    private func bitmapComposition(
        _ result: UnsafePointer<superplayr_subtitle_result>,
        context: UnsafePointer<AVCodecContext>, duration: Double?
    ) throws -> NativeBitmapSubtitleComposition {
        let count = Int(superplayr_subtitle_result_rect_count(result))
        guard count <= 64 else { throw PresentationError("Bitmap subtitle region limit exceeded") }
        let fallback = fallbackCanvasSize.flatMap { size -> CGSize? in
            guard size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0, size.width <= 8_192, size.height <= 8_192 else { return nil }
            return size
        }
        let width = context.pointee.width > 0 ? Int(context.pointee.width) : Int(fallback?.width ?? 0)
        let height = context.pointee.height > 0 ? Int(context.pointee.height) : Int(fallback?.height ?? 0)
        guard width > 0, height > 0, width <= 8_192, height <= 8_192 else {
            throw PresentationError("Bitmap subtitle canvas is unavailable or exceeds the size limit")
        }
        var rectangles: [AVSubtitleRect] = []
        var byteCount = 0
        for index in 0..<count {
            guard let rect = superplayr_subtitle_result_rect(result, UInt32(index)),
                  rect.pointee.w > 0, rect.pointee.h > 0,
                  rect.pointee.w <= 8_192, rect.pointee.h <= 8_192 else {
                throw PresentationError("Invalid bitmap subtitle rectangle")
            }
            let rectangle = try pgsPresentation?.rectangle(rect.pointee, index: index, count: count) ?? rect.pointee
            if rectangle.w == 0 || rectangle.h == 0 { continue }
            byteCount += Int(rectangle.w) * Int(rectangle.h) * 4
            guard byteCount <= 16 * 1_024 * 1_024 else {
                throw PresentationError("Bitmap subtitle display exceeds the byte limit")
            }
            rectangles.append(rectangle)
        }
        let lease = memoryBudget?.acquire(owner: .bitmapEvents, bytes: byteCount)
        guard memoryBudget == nil || lease != nil else {
            throw PresentationError("Bitmap subtitle memory budget is exhausted")
        }
        var regions: [NativeBitmapSubtitleRegion] = []
        for var rect in rectangles {
            var data = Data(count: Int(rect.w) * Int(rect.h) * 4)
            let status = data.withUnsafeMutableBytes { bytes in
                superplayr_subtitle_rect_copy_bgra(&rect, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
            try checkFFmpeg(status, operation: "Convert bitmap subtitle palette")
            regions.append(NativeBitmapSubtitleRegion(pixels: data,
                frame: CGRect(x: Int(rect.x), y: Int(rect.y), width: Int(rect.w), height: Int(rect.h)),
                isForced: rect.flags & AV_SUBTITLE_FLAG_FORCED != 0))
        }
        return NativeBitmapSubtitleComposition(regions: regions, canvasSize: CGSize(width: width, height: height),
                                               duration: duration, memoryLease: lease)
    }

    func flush() throws {
        pgsPresentation = nil
        superplayr_subtitle_result_reset(result)
        if let bitmapParameters {
            // Stateful subtitle codecs can make avcodec_flush_buffers a no-op.
            // Reopen from owned configuration so page/object versions and canvas
            // metadata cannot survive a seek into an earlier display epoch.
            avcodec_free_context(&context)
            try bitmapParameters.withUnsafePointer { parameters in
                try checkFFmpeg(superplayr_create_decoder(parameters, 0, &context, nil),
                                operation: "Reset bitmap subtitle decoder")
            }
            guard let context else { throw PresentationError("Bitmap decoder reset produced no context") }
            context.pointee.pkt_timebase = AVRational(num: stream.timeBase.numerator, den: stream.timeBase.denominator)
        } else if let context {
            avcodec_flush_buffers(context)
        }
    }
}
