#include <stdint.h>

#if defined(__APPLE__)
#include <malloc/malloc.h>
uint64_t illiquid_live_allocated_bytes(void) {
    malloc_statistics_t statistics;
    malloc_zone_statistics(malloc_default_zone(), &statistics);
    return (uint64_t)statistics.size_in_use;
}
#elif defined(__GLIBC__)
#include <malloc.h>
uint64_t illiquid_live_allocated_bytes(void) {
    struct mallinfo2 statistics = mallinfo2();
    return (uint64_t)statistics.uordblks + (uint64_t)statistics.hblkhd;
}
#else
#error "The live allocation probe supports macOS and glibc Linux only"
#endif
