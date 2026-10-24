#ifndef ILLIQUID_AUXILIARY_FONT_MEMORY_H
#define ILLIQUID_AUXILIARY_FONT_MEMORY_H
#include <malloc/malloc.h>
#include <stdint.h>

// All Darwin allocator zones; not resident pages or process peak memory.
static inline uint64_t illiquid_auxiliary_allocator_live_bytes(void) {
    malloc_statistics_t statistics = {0};
    malloc_zone_statistics(NULL, &statistics);
    return (uint64_t)statistics.size_in_use;
}
#endif
