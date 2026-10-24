#include "CPresenceHeap.h"
#include <time.h>
#if defined(__APPLE__)
#include <malloc/malloc.h>
#elif defined(__GLIBC__)
#include <malloc.h>
#endif

uint64_t presence_heap_bytes(void) {
#if defined(__APPLE__)
    malloc_statistics_t statistics;
    malloc_zone_statistics(NULL, &statistics);
    return (uint64_t)statistics.size_in_use;
#elif defined(__GLIBC__) && __GLIBC_PREREQ(2, 33)
    struct mallinfo2 statistics = mallinfo2();
    return (uint64_t)statistics.uordblks + (uint64_t)statistics.hblkhd;
#else
#error "This benchmark requires the macOS or glibc 2.33+ allocation counters"
#endif
}

const char *presence_heap_metric(void) {
#if defined(__APPLE__)
    return "malloc_zone_statistics(NULL).size_in_use";
#else
    return "mallinfo2.uordblks + mallinfo2.hblkhd";
#endif
}

uint64_t presence_cpu_nanoseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000000000 + (uint64_t)value.tv_nsec;
}
