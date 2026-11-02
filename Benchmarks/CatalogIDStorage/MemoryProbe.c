#include "MemoryProbe.h"
#include <time.h>

#if defined(__APPLE__)
#include <malloc/malloc.h>
#elif defined(__linux__)
#include <malloc.h>
#else
#error "The catalog-ID probe requires Darwin or glibc Linux."
#endif

uint64_t catalog_live_allocated_bytes(void) {
#if defined(__APPLE__)
    malloc_statistics_t stats = {0};
    malloc_zone_statistics(NULL, &stats);
    return (uint64_t)stats.size_in_use;
#else
    struct mallinfo2 stats = mallinfo2();
    return (uint64_t)stats.uordblks + (uint64_t)stats.hblkhd;
#endif
}

uint64_t catalog_cpu_nanoseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) + (uint64_t)value.tv_nsec;
}
