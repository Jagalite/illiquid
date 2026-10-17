static int laboratory_thread_type = 3;
/* Extracted from Illiquid's pinned shim. Hardware predicates below are Linux-only
 * unreachable adapters: every probe requests prefer_hardware=0. */
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/opt.h>
static inline int illiquid_decoder_supports_videotoolbox(const AVCodecParameters *p) { (void)p; return 0; }
static inline enum AVPixelFormat illiquid_videotoolbox_get_format(AVCodecContext *c, const enum AVPixelFormat *f) { (void)c; (void)f; return AV_PIX_FMT_NONE; }

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
    context->thread_type = laboratory_thread_type;
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
    context->thread_type = laboratory_thread_type;
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

static inline int probe_create_decoder_explicit_auto(
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
    if (software_thread_count >= 0)
        context->thread_count = software_thread_count;
    context->thread_type = laboratory_thread_type;
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
        if (result >= 0 && software_thread_count >= 0)
            context->thread_count = software_thread_count;
    context->thread_type = laboratory_thread_type;
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
