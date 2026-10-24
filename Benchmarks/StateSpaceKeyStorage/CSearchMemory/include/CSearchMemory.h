#ifndef C_SEARCH_MEMORY_H
#define C_SEARCH_MEMORY_H
#include <stdint.h>

typedef struct {
    uint64_t live_allocator_bytes;
    uint64_t current_rss_bytes;
    uint64_t physical_footprint_bytes;
    uint64_t peak_rss_bytes;
} SearchMemorySnapshot;

SearchMemorySnapshot search_memory_snapshot(void);
uint64_t search_cpu_nanoseconds(void);
const char *search_allocator_metric(void);
#endif
