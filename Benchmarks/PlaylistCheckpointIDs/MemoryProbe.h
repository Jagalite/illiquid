#ifndef ILLIQUID_PLAYLIST_PROJECTION_MEMORY_PROBE_H
#define ILLIQUID_PLAYLIST_PROJECTION_MEMORY_PROBE_H
#include <stdint.h>
enum playlist_projection_memory_field {
    PLAYLIST_MEMORY_BASELINE = 0,
    PLAYLIST_MEMORY_SAMPLED_PEAK = 1,
    PLAYLIST_MEMORY_FINAL = 2,
    PLAYLIST_MEMORY_SAMPLE_COUNT = 3,
    PLAYLIST_MEMORY_WINDOW_NS = 4,
    PLAYLIST_MEMORY_MAX_GAP_NS = 5,
    PLAYLIST_MEMORY_PEAK_RSS_BEFORE = 6,
    PLAYLIST_MEMORY_PEAK_RSS_AFTER = 7
};
int playlist_projection_memory_begin(void);
void playlist_projection_memory_end(void);
uint64_t playlist_projection_memory_value(int field);
#endif
