#include <malloc/malloc.h>
#include <stdint.h>
#include <time.h>

static inline uint64_t auxiliary_font_live_heap_bytes(void) {
    malloc_statistics_t statistics;
    malloc_zone_statistics(NULL, &statistics);
    return (uint64_t)statistics.size_in_use;
}

static inline uint64_t auxiliary_font_cpu_nanoseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000000000 + (uint64_t)value.tv_nsec;
}
