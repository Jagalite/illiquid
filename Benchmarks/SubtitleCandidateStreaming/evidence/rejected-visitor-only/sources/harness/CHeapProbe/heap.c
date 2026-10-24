#include "CHeapProbe.h"
#include <time.h>
#if defined(__APPLE__)
#include <malloc/malloc.h>
#elif defined(__GLIBC__)
#include <malloc.h>
#if __GLIBC_PREREQ(2, 33)
#define SUBTITLE_CANDIDATE_HAS_MALLINFO2 1
#endif
#endif

uint64_t subtitle_candidate_heap_bytes(void) {
#if defined(__APPLE__)
    malloc_statistics_t statistics;
    malloc_zone_statistics(NULL, &statistics);
    return (uint64_t)statistics.size_in_use;
#elif defined(SUBTITLE_CANDIDATE_HAS_MALLINFO2)
    struct mallinfo2 statistics = mallinfo2();
    return (uint64_t)statistics.uordblks + (uint64_t)statistics.hblkhd;
#else
    return 0;
#endif
}

const char *subtitle_candidate_heap_metric(void) {
#if defined(__APPLE__)
    return "malloc_zone_statistics(NULL).size_in_use";
#elif defined(SUBTITLE_CANDIDATE_HAS_MALLINFO2)
    return "mallinfo2.uordblks + mallinfo2.hblkhd";
#else
    return "unsupported";
#endif
}

uint64_t subtitle_candidate_cpu_nanoseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000000000 + (uint64_t)value.tv_nsec;
}

static volatile uint64_t consumed;
void subtitle_candidate_consume(uint64_t value) { consumed = value; }
