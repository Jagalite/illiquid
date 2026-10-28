#include "LifetimeProbe.h"
#include <libavcodec/avcodec.h>
#include <libavutil/buffer.h>
#include <stdatomic.h>
#include <stdlib.h>

typedef struct TrackedOwner {
    AVBufferRef *original;
    uint64_t payload_bytes;
    uint64_t buffer_extent_bytes;
} TrackedOwner;

static _Atomic uint64_t live_buffers, live_payload, live_extent, created, freed;

static void release_tracked(void *opaque, uint8_t *data) {
    (void)data;
    TrackedOwner *owner = opaque;
    /* The sole original reference was moved here, never av_buffer_ref'ed.
       Once this callback runs, unref releases the original native allocation. */
    av_buffer_unref(&owner->original);
    atomic_fetch_sub(&live_buffers, 1);
    atomic_fetch_sub(&live_payload, owner->payload_bytes);
    atomic_fetch_sub(&live_extent, owner->buffer_extent_bytes);
    atomic_fetch_add(&freed, 1);
    free(owner);
}

AVPacket *recovery_lifetime_packet(int32_t size, uint32_t seed, int keyframe) {
    if (size <= 0) return NULL;
    AVPacket *packet = av_packet_alloc();
    if (!packet || av_new_packet(packet, size) < 0) {
        av_packet_free(&packet);
        return NULL;
    }
    if (av_buffer_get_ref_count(packet->buf) != 1) {
        av_packet_free(&packet);
        return NULL;
    }
    TrackedOwner *owner = malloc(sizeof(*owner));
    if (!owner) {
        av_packet_free(&packet);
        return NULL;
    }
    owner->original = packet->buf;
    owner->payload_bytes = (uint64_t)packet->size;
    owner->buffer_extent_bytes = (uint64_t)packet->buf->size;
    AVBufferRef *wrapped = av_buffer_create(packet->buf->data, packet->buf->size,
                                            release_tracked, owner, 0);
    if (!wrapped) {
        /* av_buffer_create leaves data/opaque untouched on failure. */
        free(owner);
        av_packet_free(&packet);
        return NULL;
    }
    packet->buf = wrapped;
    atomic_fetch_add(&live_buffers, 1);
    atomic_fetch_add(&live_payload, owner->payload_bytes);
    atomic_fetch_add(&live_extent, owner->buffer_extent_bytes);
    atomic_fetch_add(&created, 1);
    packet->stream_index = 0;
    packet->pts = seed;
    packet->dts = seed;
    packet->duration = 1;
    if (keyframe) packet->flags |= AV_PKT_FLAG_KEY;
    for (int32_t index = 0; index < size; ++index)
        packet->data[index] = (uint8_t)(seed + (uint32_t)index % 251);
    return packet;
}

uint64_t recovery_lifetime_checksum(const AVPacket *packet) {
    uint64_t result = UINT64_C(14695981039346656037);
    for (int index = 0; index < packet->size; ++index) {
        result ^= packet->data[index];
        result *= UINT64_C(1099511628211);
    }
    return result;
}

RecoveryLifetimeSnapshot recovery_lifetime_snapshot(void) {
    return (RecoveryLifetimeSnapshot){
        atomic_load(&live_buffers), atomic_load(&live_payload),
        atomic_load(&live_extent), atomic_load(&created), atomic_load(&freed)
    };
}
