#include <malloc/malloc.h>
#include <stdint.h>

/* Allocator-reported in-use storage, not RSS or an application-wide estimate. */
uint64_t plexmatch_heap_in_use(void) {
    malloc_statistics_t statistics = {0};
    malloc_zone_statistics(NULL, &statistics);
    return (uint64_t)statistics.size_in_use;
}
