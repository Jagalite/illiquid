#ifndef ILLIQUID_SUBTITLE_LIFETIME_PROBE_H
#define ILLIQUID_SUBTITLE_LIFETIME_PROBE_H

#include "ffmpeg_shim.h"
#include <malloc/malloc.h>
#include <stdint.h>
#include <stdlib.h>

/* Read-only, synchronous observation of live allocation bases. The persistent
 * result header and codec-private caches are deliberately excluded. Never pass
 * cropped local rectangles here: their plane pointer can be an interior pointer.
 */
typedef struct LifetimeSnapshot {
    int has_output;
    unsigned int rectangle_count;
    uint64_t indexed_payload_bytes;
    uint64_t text_payload_bytes;
    uint64_t live_malloc_bytes;
    unsigned int live_allocations;
} LifetimeSnapshot;

static inline void lifetime_count_pointer(
    const void *pointer, const void **seen, unsigned int *seen_count,
    LifetimeSnapshot *snapshot
) {
    if (!pointer) return;
    for (unsigned int index = 0; index < *seen_count; ++index)
        if (seen[index] == pointer) return;
    if (*seen_count >= 4096) abort();
    size_t bytes = malloc_size(pointer);
    if (bytes == 0) abort(); /* Fixtures must expose real malloc allocation bases. */
    seen[(*seen_count)++] = pointer;
    snapshot->live_malloc_bytes += bytes;
    snapshot->live_allocations += 1;
}

static inline LifetimeSnapshot lifetime_snapshot(
    const illiquid_subtitle_result *result
) {
    LifetimeSnapshot value = {0};
    if (!result || !result->has_subtitle) return value;
    value.has_output = result->has_subtitle;
    value.rectangle_count = result->subtitle.num_rects;
    const void *seen[4096];
    unsigned int seen_count = 0;
    lifetime_count_pointer(result->subtitle.rects, seen, &seen_count, &value);
    for (unsigned int index = 0; index < result->subtitle.num_rects; ++index) {
        const AVSubtitleRect *rect = result->subtitle.rects[index];
        if (!rect) continue;
        lifetime_count_pointer(rect, seen, &seen_count, &value);
        for (unsigned int plane = 0; plane < 4; ++plane)
            lifetime_count_pointer(rect->data[plane], seen, &seen_count, &value);
        lifetime_count_pointer(rect->text, seen, &seen_count, &value);
        lifetime_count_pointer(rect->ass, seen, &seen_count, &value);
        if (rect->type == SUBTITLE_BITMAP && rect->data[0] &&
            rect->linesize[0] > 0 && rect->h > 0)
            value.indexed_payload_bytes += (uint64_t)rect->linesize[0] * rect->h;
        if (rect->text) value.text_payload_bytes += strlen(rect->text) + 1;
        if (rect->ass) value.text_payload_bytes += strlen(rect->ass) + 1;
    }
    return value;
}

#endif
