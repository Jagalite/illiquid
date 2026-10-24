#ifndef ILLIQUID_DEINTERLACER_LIFETIME_PROBE_H
#define ILLIQUID_DEINTERLACER_LIFETIME_PROBE_H

#include <libavutil/buffer.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
#include <libavutil/mem.h>
#include <pthread.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/*
 * Wrap each real av_frame_get_buffer allocation without taking another
 * observing reference. The wrapper owns the original reference and drops it
 * in its final-release callback. Measurements count AVBufferRef.size, including
 * FFmpeg's padding, rather than allocator buckets or process resident memory.
 */
typedef struct DEProbe {
    pthread_mutex_t lock;
    int64_t live_bytes;
    int64_t live_allocations;
    int64_t total_bytes;
    int64_t total_allocations;
    int64_t freed_allocations;
} DEProbe;

typedef struct DEAllocation {
    DEProbe *probe;
    AVBufferRef *original;
    int64_t bytes;
} DEAllocation;

static inline DEProbe *de_probe_create(void) {
    DEProbe *probe = calloc(1, sizeof(*probe));
    if (probe && pthread_mutex_init(&probe->lock, NULL)) {
        free(probe);
        return NULL;
    }
    return probe;
}

static inline void de_probe_free_buffer(void *opaque, uint8_t *data) {
    (void)data;
    DEAllocation *allocation = opaque;
    DEProbe *probe = allocation->probe;
    av_buffer_unref(&allocation->original);
    pthread_mutex_lock(&probe->lock);
    probe->live_bytes -= allocation->bytes;
    probe->live_allocations--;
    probe->freed_allocations++;
    pthread_mutex_unlock(&probe->lock);
    free(allocation);
}

static inline int de_probe_tag_frame(DEProbe *probe, AVFrame *frame) {
    for (int i = 0; i < AV_NUM_DATA_POINTERS; i++) {
        AVBufferRef *original = frame->buf[i];
        if (!original) continue;
        DEAllocation *allocation = malloc(sizeof(*allocation));
        if (!allocation) return AVERROR(ENOMEM);
        allocation->probe = probe;
        allocation->original = original;
        allocation->bytes = original->size;
        AVBufferRef *wrapped = av_buffer_create(original->data, original->size,
            de_probe_free_buffer, allocation, 0);
        if (!wrapped) {
            free(allocation);
            return AVERROR(ENOMEM);
        }
        pthread_mutex_lock(&probe->lock);
        probe->live_bytes += allocation->bytes;
        probe->live_allocations++;
        probe->total_bytes += allocation->bytes;
        probe->total_allocations++;
        pthread_mutex_unlock(&probe->lock);
        frame->buf[i] = wrapped;
    }
    return 0;
}

static inline int64_t de_probe_live_bytes(DEProbe *probe) {
    pthread_mutex_lock(&probe->lock);
    int64_t result = probe->live_bytes;
    pthread_mutex_unlock(&probe->lock);
    return result;
}

static inline int64_t de_probe_live_allocations(DEProbe *probe) {
    pthread_mutex_lock(&probe->lock);
    int64_t result = probe->live_allocations;
    pthread_mutex_unlock(&probe->lock);
    return result;
}

static inline int64_t de_probe_total_bytes(DEProbe *probe) {
    pthread_mutex_lock(&probe->lock);
    int64_t result = probe->total_bytes;
    pthread_mutex_unlock(&probe->lock);
    return result;
}

static inline int64_t de_probe_total_allocations(DEProbe *probe) {
    pthread_mutex_lock(&probe->lock);
    int64_t result = probe->total_allocations;
    pthread_mutex_unlock(&probe->lock);
    return result;
}

static inline int64_t de_probe_freed_allocations(DEProbe *probe) {
    pthread_mutex_lock(&probe->lock);
    int64_t result = probe->freed_allocations;
    pthread_mutex_unlock(&probe->lock);
    return result;
}

static inline void de_probe_destroy(DEProbe *probe) {
    if (!probe) return;
    /* Every wrapped allocation must be released before its counter owner. */
    if (probe->live_allocations != 0) abort();
    pthread_mutex_destroy(&probe->lock);
    free(probe);
}

static inline int de_visible_size(const AVFrame *frame) {
    return av_image_get_buffer_size(frame->format, frame->width, frame->height, 1);
}

static inline int de_copy_visible(const AVFrame *frame, uint8_t *destination, int size) {
    return av_image_copy_to_buffer(destination, size, (const uint8_t *const *)frame->data,
        frame->linesize, frame->format, frame->width, frame->height, 1);
}

static inline int de_fill_frame(AVFrame *frame, int ordinal) {
    int ten_bit = frame->format == AV_PIX_FMT_YUV420P10LE;
    if (!ten_bit && frame->format != AV_PIX_FMT_YUV420P) return AVERROR(EINVAL);
    for (int plane = 0; plane < 3; plane++) {
        int width = plane ? (frame->width + 1) / 2 : frame->width;
        int height = plane ? (frame->height + 1) / 2 : frame->height;
        for (int y = 0; y < height; y++) {
            uint8_t *row = frame->data[plane] + y * frame->linesize[plane];
            for (int x = 0; x < width; x++) {
                int value = 16 + ((x * 3 + y * 7 + ordinal * 19 + plane * 43) % 220);
                if (ten_bit) {
                    uint16_t sample = (uint16_t)((value << 2) | (x & 3));
                    memcpy(row + x * 2, &sample, sizeof(sample));
                } else {
                    row[x] = (uint8_t)value;
                }
            }
        }
    }
    return 0;
}

#endif
