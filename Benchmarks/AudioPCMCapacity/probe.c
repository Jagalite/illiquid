#include <stdint.h>
#include <time.h>
#ifdef __APPLE__
#include <malloc/malloc.h>
#else
#include <malloc.h>
#endif

/* Allocator live bytes, not RSS, virtual size, or whole-player footprint. */
uint64_t pcm_live_heap(void) {
#ifdef __APPLE__
    malloc_statistics_t stats = {0};
    malloc_zone_statistics(NULL, &stats);
    return stats.size_in_use;
#else
    struct mallinfo2 stats = mallinfo2();
    return (uint64_t)stats.uordblks + (uint64_t)stats.hblkhd;
#endif
}

uint64_t pcm_clock_ns(int cpu) {
    struct timespec time;
    clock_gettime(cpu ? CLOCK_PROCESS_CPUTIME_ID : CLOCK_MONOTONIC, &time);
    return (uint64_t)time.tv_sec * 1000000000 + (uint64_t)time.tv_nsec;
}
