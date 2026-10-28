#include "MemoryProbe.h"
#if defined(__APPLE__)
#include <malloc/malloc.h>
#elif defined(__GLIBC__)
#include <malloc.h>
#else
#error "Unsupported allocator"
#endif
#include <stddef.h>

/* Single-threaded benchmark only; the production target never links this probe. */
static RestorationMemorySample sample;

static uint64_t live_bytes(void) {
#if defined(__APPLE__)
    malloc_statistics_t statistics = {0};
    /* NULL sums all malloc zones, including the nano allocator. */
    malloc_zone_statistics(NULL, &statistics);
    return (uint64_t)statistics.size_in_use;
#else
    struct mallinfo2 statistics = mallinfo2();
    return (uint64_t)statistics.uordblks + (uint64_t)statistics.hblkhd;
#endif
}

void restoration_memory_begin(void) {
    sample = (RestorationMemorySample){0};
    sample.before_bytes = live_bytes();
}

void restoration_memory_checkpoint(uint64_t unique_count,
                                   uint64_t map_capacity,
                                   uint64_t order_capacity) {
    sample.checkpoint_bytes = live_bytes();
    sample.unique_count = unique_count;
    sample.map_capacity = map_capacity;
    sample.order_capacity = order_capacity;
    sample.checkpoint_count += 1;
}

RestorationMemorySample restoration_memory_sample(void) {
    return sample;
}
