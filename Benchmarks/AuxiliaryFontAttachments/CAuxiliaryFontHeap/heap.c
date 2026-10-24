#include "heap.h"
#include <stddef.h>
#include <malloc/malloc.h>

uint64_t auxiliary_font_live_bytes(void) {
    malloc_statistics_t statistics = {0};
    malloc_zone_statistics(NULL, &statistics);
    return (uint64_t)statistics.size_in_use;
}
