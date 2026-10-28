#include <malloc/malloc.h>
#include <stdint.h>

uint64_t live_heap_bytes(void) {
    malloc_statistics_t statistics = {0};
    // All malloc zones, including allocations made by Swift's task runtime.
    malloc_zone_statistics(NULL, &statistics);
    return (uint64_t)statistics.size_in_use;
}
