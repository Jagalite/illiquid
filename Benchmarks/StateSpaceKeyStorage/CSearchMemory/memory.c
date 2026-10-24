#include "CSearchMemory.h"
#include <stdio.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#include <malloc/malloc.h>
#elif defined(__GLIBC__)
#include <malloc.h>
#if __GLIBC_PREREQ(2, 33)
#define SEARCH_HAS_MALLINFO2 1
#endif
#endif

SearchMemorySnapshot search_memory_snapshot(void) {
    SearchMemorySnapshot result = {0};
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) == 0) {
#if defined(__APPLE__)
        result.peak_rss_bytes = (uint64_t)usage.ru_maxrss;
#else
        result.peak_rss_bytes = (uint64_t)usage.ru_maxrss * 1024;
#endif
    }
#if defined(__APPLE__)
    malloc_statistics_t statistics;
    malloc_zone_statistics(NULL, &statistics);
    result.live_allocator_bytes = (uint64_t)statistics.size_in_use;
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        result.current_rss_bytes = (uint64_t)info.resident_size;
        result.physical_footprint_bytes = (uint64_t)info.phys_footprint;
    }
#elif defined(SEARCH_HAS_MALLINFO2)
    struct mallinfo2 statistics = mallinfo2();
    result.live_allocator_bytes = (uint64_t)statistics.uordblks + (uint64_t)statistics.hblkhd;
    FILE *stream = fopen("/proc/self/statm", "r");
    unsigned long total = 0, resident = 0;
    if (stream != NULL) {
        if (fscanf(stream, "%lu %lu", &total, &resident) == 2)
            result.current_rss_bytes = (uint64_t)resident * (uint64_t)sysconf(_SC_PAGESIZE);
        fclose(stream);
    }
#endif
    return result;
}

uint64_t search_cpu_nanoseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000000000 + (uint64_t)value.tv_nsec;
}

const char *search_allocator_metric(void) {
#if defined(__APPLE__)
    return "malloc_zone_statistics(NULL).size_in_use (all zones)";
#elif defined(SEARCH_HAS_MALLINFO2)
    return "mallinfo2.uordblks + mallinfo2.hblkhd";
#else
    return "unsupported";
#endif
}
