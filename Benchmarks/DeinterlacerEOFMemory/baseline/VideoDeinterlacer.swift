import CFFmpeg
import CoreVideo
import Foundation

/// Decoder-owned temporal filtering. Outputs are consumed synchronously through
/// the existing capacity/queue admission; this object owns no clock or workers.
final class VideoDeinterlacer {
    struct Output {
        let frame: UnsafeMutablePointer<AVFrame>
        let timeBase: FFmpegRational
        let filtered: Bool
        let copiedHardware: Bool
    }

    private struct Format: Equatable {
        let width: Int32
        let height: Int32
        let pixelFormat: Int32
        let aspectNumerator: Int32
        let aspectDenominator: Int32
        let colorSpace: Int32
        let colorRange: Int32
        let copiedHardware: Bool
    }

    private let timeBase: FFmpegRational
    private let frameRate: AVRational
    private var graph: UnsafeMutablePointer<AVFilterGraph>?
    private var source: UnsafeMutablePointer<AVFilterContext>?
    private var sink: UnsafeMutablePointer<AVFilterContext>?
    private var format: Format?
    private var outputFrame: UnsafeMutablePointer<AVFrame>?
    private var hardwareTransferFrame: UnsafeMutablePointer<AVFrame>?
    private var ended = false

    init(timeBase: FFmpegRational, nominalFrameRate: Double? = nil) throws {
        self.timeBase = timeBase
        let rate = nominalFrameRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 30
        frameRate = av_d2q(rate, 1_000_000)
        outputFrame = av_frame_alloc()
        hardwareTransferFrame = av_frame_alloc()
        guard outputFrame != nil, hardwareTransferFrame != nil else {
            av_frame_free(&outputFrame)
            av_frame_free(&hardwareTransferFrame)
            throw PresentationError("Could not allocate deinterlacing frame storage")
        }
    }

    deinit {
        avfilter_graph_free(&graph)
        av_frame_free(&outputFrame)
        av_frame_free(&hardwareTransferFrame)
    }

    func reset() {
        avfilter_graph_free(&graph)
        source = nil
        sink = nil
        format = nil
        ended = false
        if let outputFrame { av_frame_unref(outputFrame) }
        if let hardwareTransferFrame { av_frame_unref(hardwareTransferFrame) }
    }

    func process(_ input: UnsafeMutablePointer<AVFrame>, while shouldContinue: () -> Bool,
                 emit: (Output) throws -> Void) throws {
        guard shouldContinue() else { throw SoftwarePixelBufferPoolError.cancelled }
        let interlaced = input.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0
        guard graph != nil || interlaced else {
            try emit(Output(frame: input, timeBase: timeBase, filtered: false, copiedHardware: false))
            return
        }
        let copiedHardware = illiquid_frame_pixel_format(input) == AV_PIX_FMT_VIDEOTOOLBOX
        let frame: UnsafeMutablePointer<AVFrame>
        if copiedHardware {
            guard let buffer = illiquid_videotoolbox_pixel_buffer(input)?.takeUnretainedValue(),
                  CVPixelBufferGetDataSize(buffer) <= 32 * 1_024 * 1_024 else {
                throw PresentationError("Interlaced hardware frame exceeds the transfer limit")
            }
            guard let hardwareTransferFrame else { throw PresentationError("No hardware transfer storage") }
            av_frame_unref(hardwareTransferFrame)
            try checkFFmpeg(av_hwframe_transfer_data(hardwareTransferFrame, input, 0), operation: "Transfer interlaced hardware frame")
            try checkFFmpeg(av_frame_copy_props(hardwareTransferFrame, input), operation: "Preserve interlaced frame metadata")
            frame = hardwareTransferFrame
        } else { frame = input }
        defer { if copiedHardware, let hardwareTransferFrame { av_frame_unref(hardwareTransferFrame) } }
        let aspect = frame.pointee.sample_aspect_ratio
        let next = Format(width: frame.pointee.width, height: frame.pointee.height, pixelFormat: frame.pointee.format,
                          aspectNumerator: aspect.num > 0 ? aspect.num : 1,
                          aspectDenominator: aspect.den > 0 ? aspect.den : 1,
                          colorSpace: Int32(frame.pointee.colorspace.rawValue),
                          colorRange: Int32(frame.pointee.color_range.rawValue), copiedHardware: copiedHardware)
        if next != format {
            try drain(while: shouldContinue, emit: emit)
            reset()
            try configure(next)
        }
        guard !ended, let source else { throw PresentationError("Deinterlacer is not accepting frames") }
        // Filter timing uses pts, not the decoder's best-effort field. Preserve
        // the decoded fallback timestamp explicitly before retaining the frame.
        if frame.pointee.pts == illiquid_nopts_value() {
            frame.pointee.pts = illiquid_frame_best_effort_timestamp(frame)
        }
        if frame.pointee.duration <= 0 {
            frame.pointee.duration = max(1, av_rescale_q(1, av_inv_q(frameRate), .init(num: timeBase.numerator, den: timeBase.denominator)))
        }
        try checkFFmpeg(av_buffersrc_add_frame_flags(source, frame, Int32(AV_BUFFERSRC_FLAG_KEEP_REF)), operation: "Submit deinterlacing frame")
        try receive(while: shouldContinue, emit: emit)
    }

    func drain(while shouldContinue: () -> Bool, emit: (Output) throws -> Void) throws {
        guard !ended, let source else { return }
        try checkFFmpeg(av_buffersrc_add_frame_flags(source, nil, 0), operation: "Drain deinterlacer")
        ended = true
        try receive(while: shouldContinue, emit: emit)
    }

    private func configure(_ format: Format) throws {
        guard format.width >= 3, format.height >= 3, timeBase.numerator > 0, timeBase.denominator > 0 else {
            throw PresentationError("Unsupported deinterlacing geometry or time base")
        }
        let supported = [AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_YUV422P, AV_PIX_FMT_YUVJ422P,
                         AV_PIX_FMT_YUV444P, AV_PIX_FMT_YUVJ444P, AV_PIX_FMT_YUV420P10LE,
                         AV_PIX_FMT_YUV422P10LE, AV_PIX_FMT_YUV444P10LE, AV_PIX_FMT_NV12, AV_PIX_FMT_P010LE]
        guard supported.contains(AVPixelFormat(rawValue: format.pixelFormat)) else {
            throw PresentationError("Interlaced source format is outside the supported YUV filter contract")
        }
        let bytes = av_image_get_buffer_size(AVPixelFormat(rawValue: format.pixelFormat), format.width, format.height, 1)
        guard bytes > 0, bytes <= 32 * 1_024 * 1_024 else {
            throw PresentationError("Deinterlacing frame exceeds the 32 MiB input limit")
        }
        graph = avfilter_graph_alloc()
        guard let graph else { throw PresentationError("Could not allocate deinterlacing graph") }
        // BWDIF retains a small temporal window; never create an unbounded
        // native thread team in addition to the codec's existing workers.
        graph.pointee.nb_threads = 2
        let args = "video_size=\(format.width)x\(format.height):pix_fmt=\(format.pixelFormat)"
            + ":time_base=\(timeBase.numerator)/\(timeBase.denominator)"
            + ":pixel_aspect=\(format.aspectNumerator)/\(format.aspectDenominator)"
            + ":frame_rate=\(frameRate.num)/\(frameRate.den)"
            + ":colorspace=\(format.colorSpace):range=\(format.colorRange)"
        var filter: UnsafeMutablePointer<AVFilterContext>?
        guard let bufferFilter = avfilter_get_by_name("buffer"), let fieldFilter = avfilter_get_by_name("bwdif"),
              let sinkFilter = avfilter_get_by_name("buffersink") else {
            throw PresentationError("The native FFmpeg build lacks BWDIF deinterlacing")
        }
        try checkFFmpeg(avfilter_graph_create_filter(&source, bufferFilter, "input", args, nil, graph), operation: "Create deinterlacing input")
        try checkFFmpeg(avfilter_graph_create_filter(&filter, fieldFilter, "fields",
            "mode=send_field:parity=auto:deint=interlaced", nil, graph), operation: "Create BWDIF filter")
        try checkFFmpeg(avfilter_graph_create_filter(&sink, sinkFilter, "output", nil, nil, graph), operation: "Create deinterlacing output")
        try checkFFmpeg(avfilter_link(source, 0, filter, 0), operation: "Link deinterlacing input")
        try checkFFmpeg(avfilter_link(filter, 0, sink, 0), operation: "Link deinterlacing output")
        try checkFFmpeg(avfilter_graph_config(graph, nil), operation: "Configure deinterlacing")
        self.format = format
    }

    private func receive(while shouldContinue: () -> Bool, emit: (Output) throws -> Void) throws {
        guard let sink, let outputFrame, let format else { return }
        while true {
            guard shouldContinue() else { throw SoftwarePixelBufferPoolError.cancelled }
            av_frame_unref(outputFrame)
            let result = av_buffersink_get_frame(sink, outputFrame)
            if result == illiquid_averror_eagain() || result == illiquid_averror_eof() { return }
            try checkFFmpeg(result, operation: "Receive deinterlaced field")
            defer { av_frame_unref(outputFrame) }
            try emit(Output(frame: outputFrame, timeBase: FFmpegRational(av_buffersink_get_time_base(sink)),
                            filtered: true, copiedHardware: format.copiedHardware))
        }
    }
}
