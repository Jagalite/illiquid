#ifndef ILLIQUID_RECOVERY_LIFETIME_PROBE_H
#define ILLIQUID_RECOVERY_LIFETIME_PROBE_H
#include <stdint.h>
#include <libavcodec/packet.h>

typedef struct RecoveryLifetimeSnapshot {
    uint64_t live_buffers;
    uint64_t live_payload_bytes;
    uint64_t live_buffer_extent_bytes;
    uint64_t created_buffers;
    uint64_t freed_buffers;
} RecoveryLifetimeSnapshot;

/* Uses real av_new_packet storage; tracking owns no additional observer ref. */
AVPacket *recovery_lifetime_packet(int32_t size, uint32_t seed, int keyframe);
uint64_t recovery_lifetime_checksum(const AVPacket *packet);
RecoveryLifetimeSnapshot recovery_lifetime_snapshot(void);
#endif
