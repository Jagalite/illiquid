#include "Metrics.h"
#include <time.h>
#if defined(__APPLE__)
#include <malloc/malloc.h>
#include <mach/mach.h>
#elif defined(__GLIBC__)
#include <malloc.h>
#include <fcntl.h>
#include <unistd.h>
#if __GLIBC_PREREQ(2, 33)
#define THUMBNAIL_HAS_MALLINFO2 1
#endif
#endif

/* Allocator-accounted live bytes, not an allocation-traffic or peak metric.
   Adapted from the repository's CompletedEffectHistory component benchmark. */
uint64_t thumbnail_heap_bytes(void) {
#if defined(__APPLE__)
    malloc_statistics_t statistics;
    malloc_zone_statistics(NULL, &statistics);
    return (uint64_t)statistics.size_in_use;
#elif defined(THUMBNAIL_HAS_MALLINFO2)
    struct mallinfo2 statistics = mallinfo2();
    return (uint64_t)statistics.uordblks + (uint64_t)statistics.hblkhd;
#else
    return 0;
#endif
}

const char *thumbnail_heap_metric(void) {
#if defined(__APPLE__)
    return "malloc_zone_statistics(NULL).size_in_use";
#elif defined(THUMBNAIL_HAS_MALLINFO2)
    return "mallinfo2.uordblks + mallinfo2.hblkhd";
#else
    return "unsupported";
#endif
}

uint64_t thumbnail_resident_bytes(void) {
#if defined(__APPLE__)
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
        (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return (uint64_t)info.resident_size;
#elif defined(__linux__)
    /* Stack-only /proc parsing avoids allocating while sampling the heap. */
    char buffer[128];
    int fd = open("/proc/self/statm", O_RDONLY);
    if (fd < 0) return 0;
    ssize_t n = read(fd, buffer, sizeof(buffer) - 1);
    close(fd);
    if (n <= 0) return 0;
    buffer[n] = '\0';
    char *cursor = buffer;
    while (*cursor && *cursor != ' ') ++cursor;
    while (*cursor == ' ') ++cursor;
    uint64_t pages = 0;
    while (*cursor >= '0' && *cursor <= '9') {
        pages = pages * 10 + (uint64_t)(*cursor - '0');
        ++cursor;
    }
    long page_size = sysconf(_SC_PAGESIZE);
    return page_size > 0 ? pages * (uint64_t)page_size : 0;
#else
    return 0;
#endif
}

const char *thumbnail_resident_metric(void) {
#if defined(__APPLE__)
    return "task_info(MACH_TASK_BASIC_INFO).resident_size";
#elif defined(__linux__)
    return "/proc/self/statm resident pages * page size";
#else
    return "unsupported";
#endif
}

uint64_t thumbnail_cpu_nanoseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000000000 + (uint64_t)value.tv_nsec;
}
