#include <stdint.h>
#include <time.h>
#if defined(__APPLE__)
#include <malloc/malloc.h>
#elif defined(__GLIBC__)
#include <malloc.h>
#endif

uint64_t subtitle_key_heap_bytes(void) {
#if defined(__APPLE__)
    malloc_statistics_t value;
    malloc_zone_statistics(NULL, &value);
    return (uint64_t)value.size_in_use;
#elif defined(__GLIBC__)
    struct mallinfo2 value = mallinfo2();
    return (uint64_t)value.uordblks + (uint64_t)value.hblkhd;
#else
#error "This component meter requires macOS or Linux/glibc 2.33+."
#endif
}

const char *subtitle_key_heap_metric(void) {
#if defined(__APPLE__)
    return "malloc_zone_statistics(NULL).size_in_use";
#else
    return "mallinfo2.uordblks + mallinfo2.hblkhd";
#endif
}

uint64_t subtitle_key_cpu_nanoseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000000000 + (uint64_t)value.tv_nsec;
}
