#ifndef ILLIQUID_FFMPEG_SHIM_H
#define ILLIQUID_FFMPEG_SHIM_H

#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavcodec/codec.h>
#include <libavcodec/packet.h>
#include <libavformat/avformat.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersrc.h>
#include <libavfilter/buffersink.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/display.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/imgutils.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libavutil/pixfmt.h>
#include <libavutil/samplefmt.h>
#include <libavutil/time.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

static inline int illiquid_averror_eagain(void) {
    return AVERROR(EAGAIN);
}

static inline int illiquid_averror_eof(void) {
    return AVERROR_EOF;
}

static inline int illiquid_averror_nomem(void) {
    return AVERROR(ENOMEM);
}

static inline int illiquid_averror_unknown(void) {
    return AVERROR_UNKNOWN;
}

static inline int illiquid_averror_invaliddata(void) {
    return AVERROR_INVALIDDATA;
}

static inline int illiquid_averror_exit(void) {
    return AVERROR_EXIT;
}

static inline int illiquid_packet_is_corrupt(const AVPacket *packet) {
    return packet && (packet->flags & AV_PKT_FLAG_CORRUPT) != 0;
}

static inline int illiquid_packet_is_keyframe(const AVPacket *packet) {
    return packet && (packet->flags & AV_PKT_FLAG_KEY) != 0;
}

// A container keyframe flag alone does not establish a closed H.264 decoder
// boundary. Only accept a complete length-prefixed access unit containing IDR.
static inline int illiquid_packet_is_h264_idr(
    const AVPacket *packet, const AVCodecParameters *parameters
) {
    if (!packet || !parameters || parameters->codec_id != AV_CODEC_ID_H264
        || !illiquid_packet_is_keyframe(packet) || illiquid_packet_is_corrupt(packet)
        || !parameters->extradata || parameters->extradata_size < 7
        || parameters->extradata[0] != 1 || !packet->data || packet->size <= 0)
        return 0;
    size_t side_size = 0;
    if (av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &side_size))
        return 0;
    int length_size = (parameters->extradata[4] & 3) + 1;
    if (length_size == 3)
        return 0;
    size_t offset = 0, size = (size_t)packet->size;
    int has_idr = 0;
    while (offset < size) {
        if (size - offset < (size_t)length_size)
            return 0;
        uint32_t length = 0;
        for (int i = 0; i < length_size; i++)
            length = (length << 8) | packet->data[offset++];
        if (!length || length > size - offset || (packet->data[offset] & 0x80))
            return 0;
        has_idr |= (packet->data[offset] & 31) == 5;
        offset += length;
    }
    return has_idr;
}

static inline int illiquid_frame_is_corrupt(const AVFrame *frame) {
    return frame && (frame->flags & AV_FRAME_FLAG_CORRUPT) != 0;
}

typedef int (*illiquid_interrupt_callback)(void *opaque);

static inline AVFormatContext *illiquid_alloc_interruptible_format_context(
    illiquid_interrupt_callback callback,
    void *opaque
) {
    AVFormatContext *context = avformat_alloc_context();
    if (!context)
        return NULL;
    context->interrupt_callback.callback = callback;
    context->interrupt_callback.opaque = opaque;
    return context;
}

static inline int64_t illiquid_nopts_value(void) {
    return AV_NOPTS_VALUE;
}

static inline unsigned int illiquid_chapter_count(const AVFormatContext *context) {
    return context ? context->nb_chapters : 0;
}

static inline AVChapter *illiquid_chapter_at(
    const AVFormatContext *context,
    unsigned int index
) {
    return context && index < context->nb_chapters ? context->chapters[index] : NULL;
}

static inline const char *illiquid_metadata_value(
    AVDictionary *dictionary,
    const char *key
) {
    AVDictionaryEntry *entry = av_dict_get(dictionary, key, NULL, 0);
    return entry ? entry->value : NULL;
}

static inline enum AVMediaType illiquid_codecpar_type(const AVCodecParameters *parameters) {
    return parameters->codec_type;
}

static inline enum AVCodecID illiquid_codecpar_id(const AVCodecParameters *parameters) {
    return parameters->codec_id;
}

static inline int illiquid_codecpar_width(const AVCodecParameters *parameters) {
    return parameters->width;
}

static inline int illiquid_codecpar_height(const AVCodecParameters *parameters) {
    return parameters->height;
}

static inline double illiquid_codecpar_rotation_degrees(
    const AVCodecParameters *parameters
) {
    if (!parameters)
        return 0.0;
    const AVPacketSideData *side_data = av_packet_side_data_get(
        parameters->coded_side_data,
        parameters->nb_coded_side_data,
        AV_PKT_DATA_DISPLAYMATRIX
    );
    if (!side_data || side_data->size < 9 * sizeof(int32_t))
        return 0.0;
    const int32_t *matrix = (const int32_t *)side_data->data;
    const int64_t determinant =
        (int64_t)matrix[0] * matrix[4] - (int64_t)matrix[1] * matrix[3];
    double rotation;
    if (determinant < 0) {
        // av_display_rotation_get() intentionally assumes a proper rotation
        // matrix. A reflection therefore appears as a spurious 180-degree
        // rotation. Decompose reflected matrices as horizontal-flip followed
        // by rotation so the Swift layer can apply both operations explicitly.
        rotation = atan2((double)matrix[3], (double)matrix[4]) * 180.0 / M_PI;
    } else {
        rotation = av_display_rotation_get(matrix);
    }
    return isnan(rotation) ? 0.0 : rotation;
}

static inline int illiquid_codecpar_display_matrix_is_mirrored(
    const AVCodecParameters *parameters
) {
    if (!parameters)
        return 0;
    const AVPacketSideData *side_data = av_packet_side_data_get(
        parameters->coded_side_data,
        parameters->nb_coded_side_data,
        AV_PKT_DATA_DISPLAYMATRIX
    );
    if (!side_data || side_data->size < 9 * sizeof(int32_t))
        return 0;
    const int32_t *matrix = (const int32_t *)side_data->data;
    const int64_t determinant =
        (int64_t)matrix[0] * matrix[4] - (int64_t)matrix[1] * matrix[3];
    return determinant < 0;
}

static inline int illiquid_codecpar_field_order(
    const AVCodecParameters *parameters
) {
    return parameters ? (int)parameters->field_order : (int)AV_FIELD_UNKNOWN;
}

static inline int illiquid_codecpar_channel_layout_name(
    const AVCodecParameters *parameters,
    char *output,
    size_t output_size
) {
    if (!parameters || !output || output_size == 0)
        return AVERROR(EINVAL);
    return av_channel_layout_describe(&parameters->ch_layout, output, output_size);
}

static inline enum AVPixelFormat illiquid_frame_pixel_format(const AVFrame *frame) {
    return (enum AVPixelFormat)frame->format;
}

static inline enum AVSampleFormat illiquid_frame_sample_format(const AVFrame *frame) {
    return (enum AVSampleFormat)frame->format;
}

static inline CVPixelBufferRef illiquid_videotoolbox_pixel_buffer(const AVFrame *frame) {
    return frame && frame->format == AV_PIX_FMT_VIDEOTOOLBOX
        ? (CVPixelBufferRef)frame->data[3]
        : NULL;
}

static enum AVPixelFormat illiquid_videotoolbox_get_format(
    AVCodecContext *context,
    const enum AVPixelFormat *formats
) {
    const enum AVPixelFormat *format = formats;
    while (context && context->hw_device_ctx && *format != AV_PIX_FMT_NONE) {
        if (*format == AV_PIX_FMT_VIDEOTOOLBOX)
            return *format;
        format++;
    }
    format = formats;
    while (*format != AV_PIX_FMT_NONE) {
        const AVPixFmtDescriptor *descriptor = av_pix_fmt_desc_get(*format);
        if (descriptor && !(descriptor->flags & AV_PIX_FMT_FLAG_HWACCEL))
            return *format;
        format++;
    }
    return AV_PIX_FMT_NONE;
}

static inline int illiquid_decoder_supports_videotoolbox(
    const AVCodecParameters *parameters
) {
    if (!parameters || parameters->codec_type != AVMEDIA_TYPE_VIDEO)
        return 0;
    const AVCodec *codec = avcodec_find_decoder(parameters->codec_id);
    if (!codec)
        return 0;
    for (int index = 0; ; index++) {
        const AVCodecHWConfig *config = avcodec_get_hw_config(codec, index);
        if (!config)
            return 0;
        if (config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX
            && config->pix_fmt == AV_PIX_FMT_VIDEOTOOLBOX)
            return 1;
    }
}

static inline int illiquid_create_decoder_with_thread_count(
    const AVCodecParameters *parameters,
    int prefer_hardware,
    int software_thread_count,
    AVCodecContext **output_context,
    int *hardware_configured
) {
    if (!parameters || !output_context)
        return AVERROR(EINVAL);

    const AVCodec *codec = avcodec_find_decoder(parameters->codec_id);
    if (!codec)
        return AVERROR_DECODER_NOT_FOUND;

    AVCodecContext *context = avcodec_alloc_context3(codec);
    if (!context)
        return AVERROR(ENOMEM);

    int result = avcodec_parameters_to_context(context, parameters);
    if (result < 0) {
        avcodec_free_context(&context);
        return result;
    }
    if (software_thread_count > 0)
        context->thread_count = software_thread_count;
    if (parameters->codec_type == AVMEDIA_TYPE_SUBTITLE)
        context->flags2 |= AV_CODEC_FLAG2_RO_FLUSH_NOOP;
    if (parameters->codec_id == AV_CODEC_ID_DVB_SUBTITLE
        && parameters->extradata && parameters->extradata_size >= 4
        && (parameters->extradata_size == 4 || parameters->extradata_size % 5 == 0)) {
        // Match the demux stream's first composition/ancillary page pair.
        result = av_opt_set_int(context->priv_data, "dvb_substream", 0, 0);
        if (result < 0) {
            avcodec_free_context(&context);
            return result;
        }
    }

    int using_hardware = 0;
    if (prefer_hardware
        && parameters->codec_type == AVMEDIA_TYPE_VIDEO
        && illiquid_decoder_supports_videotoolbox(parameters)) {
        AVBufferRef *device = NULL;
        result = av_hwdevice_ctx_create(
            &device,
            AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
            NULL,
            NULL,
            0
        );
        if (result >= 0) {
            context->hw_device_ctx = device;
            context->get_format = illiquid_videotoolbox_get_format;
            using_hardware = 1;
        }
    }

    result = avcodec_open2(context, codec, NULL);
    if (result < 0 && using_hardware) {
        avcodec_free_context(&context);
        context = avcodec_alloc_context3(codec);
        if (!context)
            return AVERROR(ENOMEM);
        result = avcodec_parameters_to_context(context, parameters);
        if (result >= 0 && software_thread_count > 0)
            context->thread_count = software_thread_count;
        if (result >= 0 && parameters->codec_type == AVMEDIA_TYPE_SUBTITLE)
            context->flags2 |= AV_CODEC_FLAG2_RO_FLUSH_NOOP;
        if (result >= 0)
            result = avcodec_open2(context, codec, NULL);
        using_hardware = 0;
    }

    if (result < 0) {
        avcodec_free_context(&context);
        return result;
    }

    *output_context = context;
    if (hardware_configured)
        *hardware_configured = using_hardware;
    return 0;
}

typedef struct illiquid_subtitle_result {
    AVSubtitle subtitle;
    int has_subtitle;
} illiquid_subtitle_result;

static inline illiquid_subtitle_result *illiquid_subtitle_result_alloc(void) {
    return av_mallocz(sizeof(illiquid_subtitle_result));
}

static inline void illiquid_subtitle_result_reset(
    illiquid_subtitle_result *result
) {
    if (!result)
        return;
    if (result->has_subtitle)
        avsubtitle_free(&result->subtitle);
    memset(&result->subtitle, 0, sizeof(result->subtitle));
    result->has_subtitle = 0;
}

static inline void illiquid_subtitle_result_free(
    illiquid_subtitle_result *result
) {
    if (!result)
        return;
    illiquid_subtitle_result_reset(result);
    av_free(result);
}

static inline int illiquid_decode_subtitle(
    AVCodecContext *context,
    const AVPacket *packet,
    illiquid_subtitle_result *result
) {
    if (!context || !packet || !result)
        return AVERROR(EINVAL);
    illiquid_subtitle_result_reset(result);
    int got_subtitle = 0;
    int decode_result = avcodec_decode_subtitle2(
        context,
        &result->subtitle,
        &got_subtitle,
        packet
    );
    result->has_subtitle = got_subtitle;
    return decode_result;
}

static inline int illiquid_subtitle_result_has_output(
    const illiquid_subtitle_result *result
) {
    return result ? result->has_subtitle : 0;
}

static inline unsigned int illiquid_subtitle_result_rect_count(
    const illiquid_subtitle_result *result
) {
    return result && result->has_subtitle ? result->subtitle.num_rects : 0;
}

static inline const char *illiquid_subtitle_result_ass(
    const illiquid_subtitle_result *result,
    unsigned int index
) {
    if (!result || !result->has_subtitle || index >= result->subtitle.num_rects)
        return NULL;
    AVSubtitleRect *rect = result->subtitle.rects[index];
    return rect ? rect->ass : NULL;
}

static inline const char *illiquid_subtitle_result_text(
    const illiquid_subtitle_result *result,
    unsigned int index
) {
    if (!result || !result->has_subtitle || index >= result->subtitle.num_rects)
        return NULL;
    AVSubtitleRect *rect = result->subtitle.rects[index];
    return rect ? rect->text : NULL;
}

static inline int illiquid_subtitle_result_rect_type(
    const illiquid_subtitle_result *result,
    unsigned int index
) {
    if (!result || !result->has_subtitle || index >= result->subtitle.num_rects)
        return SUBTITLE_NONE;
    AVSubtitleRect *rect = result->subtitle.rects[index];
    return rect ? rect->type : SUBTITLE_NONE;
}

static inline int64_t illiquid_subtitle_result_pts(
    const illiquid_subtitle_result *result
) {
    return result && result->has_subtitle ? result->subtitle.pts : AV_NOPTS_VALUE;
}

static inline const AVSubtitleRect *illiquid_subtitle_result_rect(
    const illiquid_subtitle_result *result, unsigned int index
) {
    if (!result || !result->has_subtitle || index >= result->subtitle.num_rects)
        return NULL;
    return result->subtitle.rects[index];
}

/* FFmpeg subtitle palettes contain native-endian 0xAARRGGBB entries.
 * Convert to premultiplied BGRA for the existing Metal composition path. */
static inline int illiquid_subtitle_rect_copy_bgra(
    const AVSubtitleRect *rect, uint8_t *output, size_t output_size
) {
    if (!rect || rect->type != SUBTITLE_BITMAP || !output ||
        rect->w <= 0 || rect->h <= 0 || rect->w > 8192 || rect->h > 8192 ||
        rect->linesize[0] < rect->w || !rect->data[0] || !rect->data[1] ||
        rect->nb_colors <= 0 || rect->nb_colors > 256 ||
        (size_t)rect->w * rect->h > output_size / 4)
        return AVERROR_INVALIDDATA;
    for (int y = 0; y < rect->h; ++y) {
        const uint8_t *row = rect->data[0] + (size_t)y * rect->linesize[0];
        for (int x = 0; x < rect->w; ++x) {
            if (row[x] >= rect->nb_colors)
                return AVERROR_INVALIDDATA;
            uint32_t color;
            memcpy(&color, rect->data[1] + (size_t)row[x] * 4, sizeof(color));
            const unsigned int alpha = color >> 24;
            uint8_t *pixel = output + ((size_t)y * rect->w + x) * 4;
            pixel[0] = ((color & 255) * alpha + 127) / 255;
            pixel[1] = (((color >> 8) & 255) * alpha + 127) / 255;
            pixel[2] = (((color >> 16) & 255) * alpha + 127) / 255;
            pixel[3] = alpha;
        }
    }
    return 0;
}

static inline uint32_t illiquid_subtitle_result_start_ms(
    const illiquid_subtitle_result *result
) {
    return result && result->has_subtitle
        ? result->subtitle.start_display_time
        : 0;
}

static inline uint32_t illiquid_subtitle_result_end_ms(
    const illiquid_subtitle_result *result
) {
    return result && result->has_subtitle
        ? result->subtitle.end_display_time
        : 0;
}

static inline int illiquid_create_decoder(
    const AVCodecParameters *parameters,
    int prefer_hardware,
    AVCodecContext **output_context,
    int *hardware_configured
) {
    return illiquid_create_decoder_with_thread_count(
        parameters,
        prefer_hardware,
        0,
        output_context,
        hardware_configured
    );
}

static inline const char *illiquid_frame_pixel_format_name(const AVFrame *frame) {
    if (!frame)
        return NULL;
    return av_get_pix_fmt_name((enum AVPixelFormat)frame->format);
}

static inline int64_t illiquid_frame_best_effort_timestamp(const AVFrame *frame) {
    return frame ? frame->best_effort_timestamp : AV_NOPTS_VALUE;
}

static inline int64_t illiquid_frame_duration(const AVFrame *frame) {
    return frame ? frame->duration : 0;
}

static inline int illiquid_frame_width(const AVFrame *frame) {
    return frame ? frame->width : 0;
}

static inline int illiquid_frame_height(const AVFrame *frame) {
    return frame ? frame->height : 0;
}

static inline enum AVColorPrimaries illiquid_frame_color_primaries(const AVFrame *frame) {
    return frame ? frame->color_primaries : AVCOL_PRI_UNSPECIFIED;
}

static inline enum AVColorTransferCharacteristic illiquid_frame_color_transfer(
    const AVFrame *frame
) {
    return frame ? frame->color_trc : AVCOL_TRC_UNSPECIFIED;
}

static inline enum AVColorSpace illiquid_frame_color_space(const AVFrame *frame) {
    return frame ? frame->colorspace : AVCOL_SPC_UNSPECIFIED;
}

static inline enum AVColorRange illiquid_frame_color_range(const AVFrame *frame) {
    return frame ? frame->color_range : AVCOL_RANGE_UNSPECIFIED;
}

static inline enum AVChromaLocation illiquid_frame_chroma_location(
    const AVFrame *frame
) {
    return frame ? frame->chroma_location : AVCHROMA_LOC_UNSPECIFIED;
}

static inline int illiquid_frame_sample_aspect_ratio_num(const AVFrame *frame) {
    return frame ? frame->sample_aspect_ratio.num : 0;
}

static inline int illiquid_frame_sample_aspect_ratio_den(const AVFrame *frame) {
    return frame ? frame->sample_aspect_ratio.den : 0;
}

static inline size_t illiquid_frame_crop_left(const AVFrame *frame) {
    return frame ? frame->crop_left : 0;
}

static inline size_t illiquid_frame_crop_top(const AVFrame *frame) {
    return frame ? frame->crop_top : 0;
}

static inline size_t illiquid_frame_crop_right(const AVFrame *frame) {
    return frame ? frame->crop_right : 0;
}

static inline size_t illiquid_frame_crop_bottom(const AVFrame *frame) {
    return frame ? frame->crop_bottom : 0;
}

static inline double illiquid_frame_rotation_degrees(const AVFrame *frame) {
    if (!frame)
        return NAN;
    const AVFrameSideData *side_data = av_frame_get_side_data(
        frame,
        AV_FRAME_DATA_DISPLAYMATRIX
    );
    if (!side_data || side_data->size < 9 * sizeof(int32_t))
        return NAN;
    return av_display_rotation_get((const int32_t *)side_data->data);
}

static inline int illiquid_frame_source_component_depth(const AVFrame *frame) {
    if (!frame)
        return 0;
    const AVPixFmtDescriptor *descriptor = av_pix_fmt_desc_get(
        (enum AVPixelFormat)frame->format
    );
    // Hardware wrapper formats have no components of their own. Preserve the
    // decoded component depth (also used by PiP eligibility) from FFmpeg's
    // backing software format rather than reporting every VT frame as depth 0.
    if (descriptor && (descriptor->flags & AV_PIX_FMT_FLAG_HWACCEL)
        && frame->hw_frames_ctx && frame->hw_frames_ctx->data) {
        const AVHWFramesContext *frames =
            (const AVHWFramesContext *)frame->hw_frames_ctx->data;
        descriptor = av_pix_fmt_desc_get(frames->sw_format);
    }
    return descriptor && descriptor->nb_components > 0
        ? descriptor->comp[0].depth
        : 0;
}

// The legacy sws_scale API receives planes, not AVFrame color metadata.
// Preserve its BT.601 fallback for unspecified/unsupported matrix metadata.
static inline int illiquid_sws_colorspace(enum AVColorSpace colorspace) {
    switch (colorspace) {
    case AVCOL_SPC_BT709: return SWS_CS_ITU709;
    case AVCOL_SPC_FCC: return SWS_CS_FCC;
    case AVCOL_SPC_BT470BG:
    case AVCOL_SPC_SMPTE170M: return SWS_CS_ITU601;
    case AVCOL_SPC_SMPTE240M: return SWS_CS_SMPTE240M;
    case AVCOL_SPC_BT2020_NCL: return SWS_CS_BT2020;
    default: return SWS_CS_DEFAULT;
    }
}

static inline int illiquid_frame_is_full_range(const AVFrame *frame) {
    if (frame->color_range != AVCOL_RANGE_UNSPECIFIED)
        return frame->color_range == AVCOL_RANGE_JPEG;
    const AVPixFmtDescriptor *descriptor = av_pix_fmt_desc_get(frame->format);
    if (descriptor && (descriptor->flags & AV_PIX_FMT_FLAG_RGB))
        return 1;
    switch (frame->format) {
    case AV_PIX_FMT_YUVJ420P:
    case AV_PIX_FMT_YUVJ422P:
    case AV_PIX_FMT_YUVJ444P:
    case AV_PIX_FMT_YUVJ440P:
    case AV_PIX_FMT_YUVJ411P: return 1;
    default: return 0;
    }
}

static inline int illiquid_copy_frame_to_bgra_pixel_buffer(
    const AVFrame *frame,
    CVPixelBufferRef pixel_buffer,
    struct SwsContext **conversion_context
) {
    if (!frame || !pixel_buffer || !conversion_context)
        return AVERROR(EINVAL);

    const int width = (int)CVPixelBufferGetWidth(pixel_buffer);
    const int height = (int)CVPixelBufferGetHeight(pixel_buffer);
    *conversion_context = sws_getCachedContext(
        *conversion_context,
        frame->width,
        frame->height,
        (enum AVPixelFormat)frame->format,
        width,
        height,
        AV_PIX_FMT_BGRA,
        SWS_BILINEAR,
        NULL,
        NULL,
        NULL
    );
    if (!*conversion_context)
        return AVERROR(ENOMEM);

    // Reapply on every frame: sws_getCachedContext can reuse a context when
    // matrix/range changes without changing the dimensions or pixel format.
    const int *coefficients = sws_getCoefficients(
        illiquid_sws_colorspace(frame->colorspace)
    );
    int color_result = sws_setColorspaceDetails(
        *conversion_context, coefficients, illiquid_frame_is_full_range(frame),
        coefficients, 1, 0, 1 << 16, 1 << 16
    );
    if (color_result < 0)
        return color_result;

    CVReturn lock_result = CVPixelBufferLockBaseAddress(pixel_buffer, 0);
    if (lock_result != kCVReturnSuccess)
        return AVERROR_EXTERNAL;

    uint8_t *destination_data[4] = {
        CVPixelBufferGetBaseAddress(pixel_buffer),
        NULL,
        NULL,
        NULL
    };
    int destination_linesize[4] = {
        (int)CVPixelBufferGetBytesPerRow(pixel_buffer),
        0,
        0,
        0
    };
    int result = sws_scale(
        *conversion_context,
        (const uint8_t *const *)frame->data,
        frame->linesize,
        0,
        frame->height,
        destination_data,
        destination_linesize
    );
    CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);
    return result < 0 ? result : 0;
}

static inline enum AVPixelFormat illiquid_biplanar_av_pixel_format(
    OSType pixel_format
) {
    switch (pixel_format) {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        return AV_PIX_FMT_NV12;
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
        return AV_PIX_FMT_P010LE;
    default:
        return AV_PIX_FMT_NONE;
    }
}

static inline int illiquid_set_sws_ranges(
    struct SwsContext *context,
    int source_full_range,
    int destination_full_range
) {
    if (!context)
        return AVERROR(EINVAL);
    int *inverse_table = NULL;
    int *forward_table = NULL;
    int existing_source_range = 0;
    int existing_destination_range = 0;
    int brightness = 0;
    int contrast = 0;
    int saturation = 0;
    int result = sws_getColorspaceDetails(
        context,
        &inverse_table,
        &existing_source_range,
        &forward_table,
        &existing_destination_range,
        &brightness,
        &contrast,
        &saturation
    );
    if (result < 0)
        return result;
    return sws_setColorspaceDetails(
        context,
        inverse_table,
        source_full_range,
        forward_table,
        destination_full_range,
        brightness,
        contrast,
        saturation
    );
}

static inline int illiquid_copy_frame_to_biplanar_pixel_buffer(
    const AVFrame *frame,
    CVPixelBufferRef pixel_buffer,
    struct SwsContext **conversion_context
) {
    if (!frame || !pixel_buffer || !conversion_context)
        return AVERROR(EINVAL);
    if (!CVPixelBufferIsPlanar(pixel_buffer) || CVPixelBufferGetPlaneCount(pixel_buffer) != 2)
        return AVERROR(EINVAL);

    enum AVPixelFormat destination_format = illiquid_biplanar_av_pixel_format(
        CVPixelBufferGetPixelFormatType(pixel_buffer)
    );
    if (destination_format == AV_PIX_FMT_NONE)
        return AVERROR(EINVAL);

    const int width = (int)CVPixelBufferGetWidth(pixel_buffer);
    const int height = (int)CVPixelBufferGetHeight(pixel_buffer);
    *conversion_context = sws_getCachedContext(
        *conversion_context,
        frame->width,
        frame->height,
        (enum AVPixelFormat)frame->format,
        width,
        height,
        destination_format,
        SWS_BILINEAR,
        NULL,
        NULL,
        NULL
    );
    if (!*conversion_context)
        return AVERROR(ENOMEM);
    const int full_range = illiquid_frame_is_full_range(frame);
    int range_result = illiquid_set_sws_ranges(
        *conversion_context,
        full_range,
        full_range
    );
    if (range_result < 0)
        return range_result;

    CVReturn lock_result = CVPixelBufferLockBaseAddress(pixel_buffer, 0);
    if (lock_result != kCVReturnSuccess)
        return AVERROR_EXTERNAL;

    uint8_t *destination_data[4] = {
        CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, 0),
        CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, 1),
        NULL,
        NULL
    };
    int destination_linesize[4] = {
        (int)CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, 0),
        (int)CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, 1),
        0,
        0
    };
    int result = sws_scale(
        *conversion_context,
        (const uint8_t *const *)frame->data,
        frame->linesize,
        0,
        frame->height,
        destination_data,
        destination_linesize
    );
    CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);
    return result < 0 ? result : 0;
}

static inline int illiquid_copy_biplanar_pixel_buffer_to_bgra(
    CVPixelBufferRef source,
    CVPixelBufferRef destination,
    struct SwsContext **conversion_context
) {
    if (!source || !destination || !conversion_context)
        return AVERROR(EINVAL);
    if (!CVPixelBufferIsPlanar(source) || CVPixelBufferGetPlaneCount(source) != 2)
        return AVERROR(EINVAL);
    if (CVPixelBufferGetPixelFormatType(destination) != kCVPixelFormatType_32BGRA)
        return AVERROR(EINVAL);

    enum AVPixelFormat source_format = illiquid_biplanar_av_pixel_format(
        CVPixelBufferGetPixelFormatType(source)
    );
    if (source_format == AV_PIX_FMT_NONE)
        return AVERROR(EINVAL);

    const int width = (int)CVPixelBufferGetWidth(source);
    const int height = (int)CVPixelBufferGetHeight(source);
    if (width != (int)CVPixelBufferGetWidth(destination)
        || height != (int)CVPixelBufferGetHeight(destination))
        return AVERROR(EINVAL);

    *conversion_context = sws_getCachedContext(
        *conversion_context,
        width,
        height,
        source_format,
        width,
        height,
        AV_PIX_FMT_BGRA,
        SWS_BILINEAR,
        NULL,
        NULL,
        NULL
    );
    if (!*conversion_context)
        return AVERROR(ENOMEM);
    const OSType source_cv_format = CVPixelBufferGetPixelFormatType(source);
    const int source_full_range =
        source_cv_format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        || source_cv_format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    CFTypeRef matrix = CVBufferCopyAttachment(source, kCVImageBufferYCbCrMatrixKey, NULL);
    int matrix_id = SWS_CS_DEFAULT;
    if (matrix) {
        if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2))
            matrix_id = SWS_CS_ITU709;
        else if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020))
            matrix_id = SWS_CS_BT2020;
        else if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995))
            matrix_id = SWS_CS_SMPTE240M;
        CFRelease(matrix);
    }
    const int *coefficients = sws_getCoefficients(matrix_id);
    int range_result = sws_setColorspaceDetails(
        *conversion_context, coefficients, source_full_range,
        coefficients, 1, 0, 1 << 16, 1 << 16
    );
    if (range_result < 0)
        return range_result;

    CVReturn source_lock = CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    if (source_lock != kCVReturnSuccess)
        return AVERROR_EXTERNAL;
    CVReturn destination_lock = CVPixelBufferLockBaseAddress(destination, 0);
    if (destination_lock != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
        return AVERROR_EXTERNAL;
    }

    const uint8_t *source_data[4] = {
        CVPixelBufferGetBaseAddressOfPlane(source, 0),
        CVPixelBufferGetBaseAddressOfPlane(source, 1),
        NULL,
        NULL
    };
    int source_linesize[4] = {
        (int)CVPixelBufferGetBytesPerRowOfPlane(source, 0),
        (int)CVPixelBufferGetBytesPerRowOfPlane(source, 1),
        0,
        0
    };
    uint8_t *destination_data[4] = {
        CVPixelBufferGetBaseAddress(destination),
        NULL,
        NULL,
        NULL
    };
    int destination_linesize[4] = {
        (int)CVPixelBufferGetBytesPerRow(destination),
        0,
        0,
        0
    };
    int result = sws_scale(
        *conversion_context,
        source_data,
        source_linesize,
        0,
        height,
        destination_data,
        destination_linesize
    );
    CVPixelBufferUnlockBaseAddress(destination, 0);
    CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    return result < 0 ? result : 0;
}

static inline void illiquid_free_sws_context(struct SwsContext *context) {
    sws_freeContext(context);
}

static inline int illiquid_audio_frame_sample_rate(const AVFrame *frame) {
    return frame ? frame->sample_rate : 0;
}

static inline int illiquid_audio_frame_channel_count(const AVFrame *frame) {
    return frame ? frame->ch_layout.nb_channels : 0;
}

static inline int illiquid_audio_frame_channel_layout_name(
    const AVFrame *frame,
    char *output,
    size_t output_size
) {
    if (!frame || !output || output_size == 0)
        return AVERROR(EINVAL);
    return av_channel_layout_describe(&frame->ch_layout, output, output_size);
}

static inline void illiquid_write_be16(uint8_t *output, uint16_t value) {
    output[0] = (uint8_t)(value >> 8);
    output[1] = (uint8_t)value;
}

static inline void illiquid_write_be32(uint8_t *output, uint32_t value) {
    output[0] = (uint8_t)(value >> 24);
    output[1] = (uint8_t)(value >> 16);
    output[2] = (uint8_t)(value >> 8);
    output[3] = (uint8_t)value;
}

static inline int illiquid_frame_mastering_display_payload(
    const AVFrame *frame,
    uint8_t *output,
    size_t output_size
) {
    if (!frame || !output || output_size < 24)
        return 0;
    const AVFrameSideData *side_data = av_frame_get_side_data(
        frame,
        AV_FRAME_DATA_MASTERING_DISPLAY_METADATA
    );
    if (!side_data || side_data->size < sizeof(AVMasteringDisplayMetadata))
        return 0;
    const AVMasteringDisplayMetadata *metadata =
        (const AVMasteringDisplayMetadata *)side_data->data;
    if (!metadata->has_primaries || !metadata->has_luminance)
        return 0;

    const int sei_order[3] = { 1, 2, 0 };
    for (int component = 0; component < 3; component++) {
        int source = sei_order[component];
        uint16_t x = (uint16_t)av_clip_uintp2_c(
            (int)llrint(av_q2d(metadata->display_primaries[source][0]) * 50000.0),
            16
        );
        uint16_t y = (uint16_t)av_clip_uintp2_c(
            (int)llrint(av_q2d(metadata->display_primaries[source][1]) * 50000.0),
            16
        );
        illiquid_write_be16(output + component * 4, x);
        illiquid_write_be16(output + component * 4 + 2, y);
    }
    illiquid_write_be16(
        output + 12,
        (uint16_t)av_clip_uintp2_c(
            (int)llrint(av_q2d(metadata->white_point[0]) * 50000.0),
            16
        )
    );
    illiquid_write_be16(
        output + 14,
        (uint16_t)av_clip_uintp2_c(
            (int)llrint(av_q2d(metadata->white_point[1]) * 50000.0),
            16
        )
    );
    illiquid_write_be32(
        output + 16,
        (uint32_t)llrint(av_q2d(metadata->max_luminance) * 10000.0)
    );
    illiquid_write_be32(
        output + 20,
        (uint32_t)llrint(av_q2d(metadata->min_luminance) * 10000.0)
    );
    return 24;
}

static inline int illiquid_frame_content_light_payload(
    const AVFrame *frame,
    uint8_t *output,
    size_t output_size
) {
    if (!frame || !output || output_size < 4)
        return 0;
    const AVFrameSideData *side_data = av_frame_get_side_data(
        frame,
        AV_FRAME_DATA_CONTENT_LIGHT_LEVEL
    );
    if (!side_data || side_data->size < sizeof(AVContentLightMetadata))
        return 0;
    const AVContentLightMetadata *metadata =
        (const AVContentLightMetadata *)side_data->data;
    illiquid_write_be16(output, metadata->MaxCLL);
    illiquid_write_be16(output + 2, metadata->MaxFALL);
    return 4;
}

static inline int illiquid_audio_frame_sample_count(const AVFrame *frame) {
    return frame ? frame->nb_samples : 0;
}

static inline void illiquid_output_audio_layout(AVChannelLayout *layout, int channels) {
    // Match the conventional 5.1 speaker layout exposed by Core Audio. 7.1
    // retains distinct rear and side pairs in FFmpeg's canonical order.
    if (channels == 6)
        av_channel_layout_from_mask(layout, AV_CH_LAYOUT_5POINT1);
    else
        av_channel_layout_default(layout, channels);
}

static inline SwrContext *illiquid_create_audio_resampler(
    const AVFrame *frame,
    int output_sample_rate,
    int output_channels
) {
    if (!frame || output_sample_rate <= 0 || output_channels <= 0)
        return NULL;

    AVChannelLayout output_layout;
    illiquid_output_audio_layout(&output_layout, output_channels);
    SwrContext *context = NULL;
    int result = swr_alloc_set_opts2(
        &context,
        &output_layout,
        AV_SAMPLE_FMT_FLT,
        output_sample_rate,
        &frame->ch_layout,
        (enum AVSampleFormat)frame->format,
        frame->sample_rate,
        0,
        NULL
    );
    av_channel_layout_uninit(&output_layout);
    if (result < 0 || !context) {
        swr_free(&context);
        return NULL;
    }
    result = av_opt_set_double(context, "rematrix_maxval", 1.0, 0);
    if (result < 0) {
        swr_free(&context);
        return NULL;
    }
    if (swr_init(context) < 0) {
        swr_free(&context);
        return NULL;
    }
    return context;
}

static inline enum AVChannel illiquid_output_audio_channel(int channels, int index) {
    if (channels <= 0 || channels > 8 || index < 0 || index >= channels)
        return AV_CHAN_NONE;
    AVChannelLayout layout;
    illiquid_output_audio_layout(&layout, channels);
    enum AVChannel channel = av_channel_layout_channel_from_index(&layout, index);
    av_channel_layout_uninit(&layout);
    return channel;
}

static inline int illiquid_audio_resampler_output_capacity(
    SwrContext *context,
    int input_samples
) {
    return context ? swr_get_out_samples(context, input_samples) : 0;
}

static inline int illiquid_convert_audio_frame(
    SwrContext *context,
    const AVFrame *frame,
    uint8_t *destination,
    int destination_sample_capacity
) {
    if (!context || !frame || !destination)
        return AVERROR(EINVAL);
    uint8_t *output[1] = { destination };
    return swr_convert(
        context,
        output,
        destination_sample_capacity,
        (const uint8_t **)frame->extended_data,
        frame->nb_samples
    );
}

static inline int illiquid_drain_audio_resampler(
    SwrContext *context,
    uint8_t *destination,
    int destination_sample_capacity
) {
    if (!context || !destination)
        return AVERROR(EINVAL);
    uint8_t *output[1] = { destination };
    return swr_convert(context, output, destination_sample_capacity, NULL, 0);
}

static inline void illiquid_reset_audio_resampler(SwrContext *context) {
    if (!context)
        return;
    swr_close(context);
    swr_init(context);
}

static inline void illiquid_free_audio_resampler(SwrContext *context) {
    swr_free(&context);
}

#endif
