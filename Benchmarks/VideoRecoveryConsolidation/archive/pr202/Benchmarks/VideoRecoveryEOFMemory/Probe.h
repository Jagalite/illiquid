#ifndef ILLIQUID_RECOVERY_EOF_PROBE_H
#define ILLIQUID_RECOVERY_EOF_PROBE_H

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <pthread.h>
#include <libavcodec/packet.h>
#include <libavutil/buffer.h>
#include <libavutil/error.h>

typedef struct REProbe {
    pthread_mutex_t lock;
    int64_t live_bytes;
    int64_t live_allocations;
    int64_t total_bytes;
    int64_t total_allocations;
    int64_t freed_allocations;
} REProbe;

typedef struct REBufferOwner {
    REProbe *probe;
    AVBufferRef *original;
    int64_t bytes;
} REBufferOwner;

static inline REProbe *re_probe_create(void) {
    REProbe *probe = calloc(1, sizeof(*probe));
    if (probe && pthread_mutex_init(&probe->lock, NULL)) {
        free(probe);
        return NULL;
    }
    return probe;
}

static inline void re_probe_buffer_free(void *opaque, uint8_t *data) {
    (void)data;
    REBufferOwner *owner = opaque;
    REProbe *probe = owner->probe;
    const int64_t bytes = owner->bytes;
    /* The sole original reference was transferred here, never duplicated. */
    av_buffer_unref(&owner->original);
    free(owner);
    pthread_mutex_lock(&probe->lock);
    probe->live_bytes -= bytes;
    probe->live_allocations--;
    probe->freed_allocations++;
    pthread_mutex_unlock(&probe->lock);
}

/*
 * Tag a fresh av_new_packet allocation once, before clones or decoder refs.
 * The counter retains no observer reference and does not copy payload or alter
 * packet metadata/data/size. Bytes are AVBufferRef.size, including input padding
 * but excluding packet/buffer metadata, allocator overhead and resident memory.
 */
static inline int re_probe_tag_packet(REProbe *probe, AVPacket *packet) {
    if (!probe || !packet || !packet->buf ||
        av_buffer_get_ref_count(packet->buf) != 1 ||
        packet->buf->size > INT64_MAX) {
        return AVERROR(EINVAL);
    }
    AVBufferRef *original = packet->buf;
    REBufferOwner *owner = malloc(sizeof(*owner));
    if (!owner) return AVERROR(ENOMEM);
    owner->probe = probe;
    owner->original = original;
    owner->bytes = (int64_t)original->size;
    const int flags = av_buffer_is_writable(original) ? 0 : AV_BUFFER_FLAG_READONLY;
    AVBufferRef *wrapped = av_buffer_create(
        original->data, original->size, re_probe_buffer_free, owner, flags
    );
    if (!wrapped) {
        /* av_buffer_create takes ownership only on success. */
        free(owner);
        return AVERROR(ENOMEM);
    }
    pthread_mutex_lock(&probe->lock);
    probe->total_bytes += owner->bytes;
    probe->total_allocations++;
    probe->live_bytes += owner->bytes;
    probe->live_allocations++;
    pthread_mutex_unlock(&probe->lock);
    packet->buf = wrapped;
    return 0;
}

static inline int64_t re_probe_live_bytes(REProbe *probe) {
    pthread_mutex_lock(&probe->lock);
    int64_t result = probe->live_bytes;
    pthread_mutex_unlock(&probe->lock);
    return result;
}
static inline int64_t re_probe_live_allocations(REProbe *probe) {
    pthread_mutex_lock(&probe->lock);
    int64_t result = probe->live_allocations;
    pthread_mutex_unlock(&probe->lock);
    return result;
}
static inline int64_t re_probe_total_bytes(REProbe *probe) {
    pthread_mutex_lock(&probe->lock);
    int64_t result = probe->total_bytes;
    pthread_mutex_unlock(&probe->lock);
    return result;
}
static inline int64_t re_probe_total_allocations(REProbe *probe) {
    pthread_mutex_lock(&probe->lock);
    int64_t result = probe->total_allocations;
    pthread_mutex_unlock(&probe->lock);
    return result;
}
static inline int64_t re_probe_freed_allocations(REProbe *probe) {
    pthread_mutex_lock(&probe->lock);
    int64_t result = probe->freed_allocations;
    pthread_mutex_unlock(&probe->lock);
    return result;
}
static inline void re_probe_destroy(REProbe *probe) {
    if (!probe) return;
    /* Workers/owners must be released before destroying their counter. */
    pthread_mutex_lock(&probe->lock);
    int invalid = probe->live_allocations != 0 || probe->live_bytes != 0 ||
        probe->freed_allocations != probe->total_allocations;
    pthread_mutex_unlock(&probe->lock);
    if (invalid || pthread_mutex_destroy(&probe->lock)) abort();
    free(probe);
}
#endif
