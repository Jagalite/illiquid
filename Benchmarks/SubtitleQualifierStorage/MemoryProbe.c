#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include "MemoryProbe.h"

#include <sys/resource.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#include <malloc/malloc.h>
#elif defined(__linux__)
#include <fcntl.h>
#include <malloc.h>
#include <unistd.h>
#else
#error "The memory probe supports macOS and glibc Linux."
#endif

uint64_t memory_probe_heap_bytes(void) {
#if defined(__APPLE__)
    malloc_statistics_t statistics = {0};
    malloc_zone_statistics(NULL, &statistics);
    return (uint64_t)statistics.size_in_use;
#else
    const struct mallinfo2 statistics = mallinfo2();
    // Include both arena allocations and separately mapped large allocations.
    return (uint64_t)statistics.uordblks + (uint64_t)statistics.hblkhd;
#endif
}

uint64_t memory_probe_rss_bytes(void) {
#if defined(__APPLE__)
    mach_task_basic_info_data_t information;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&information, &count) != KERN_SUCCESS) {
        return 0;
    }
    return (uint64_t)information.resident_size;
#else
    // Stack storage and read(2) avoid adding a stdio buffer to the heap sample.
    const int descriptor = open("/proc/self/statm", O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) return 0;
    char buffer[128];
    const ssize_t length = read(descriptor, buffer, sizeof(buffer) - 1);
    close(descriptor);
    if (length <= 0) return 0;
    buffer[length] = '\0';
    const char *cursor = buffer;
    while (*cursor >= '0' && *cursor <= '9') ++cursor;
    while (*cursor == ' ' || *cursor == '\t') ++cursor;
    uint64_t resident_pages = 0;
    while (*cursor >= '0' && *cursor <= '9') {
        resident_pages = resident_pages * 10 + (uint64_t)(*cursor - '0');
        ++cursor;
    }
    const long page_bytes = sysconf(_SC_PAGESIZE);
    return page_bytes > 0 ? resident_pages * (uint64_t)page_bytes : 0;
#endif
}

uint64_t memory_probe_peak_rss_bytes(void) {
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) return 0;
#if defined(__APPLE__)
    return (uint64_t)usage.ru_maxrss;
#else
    return (uint64_t)usage.ru_maxrss * 1024;
#endif
}
