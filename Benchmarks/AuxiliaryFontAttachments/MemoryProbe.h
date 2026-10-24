#ifndef ILLIQUID_AUXILIARY_MEMORY_PROBE_H
#define ILLIQUID_AUXILIARY_MEMORY_PROBE_H

#include <mach/mach.h>
#include <malloc/malloc.h>
#include <stdint.h>
#include <sys/resource.h>
#include <time.h>

typedef struct {
    uint64_t allocator_bytes;
    uint64_t resident_bytes;
    uint64_t peak_resident_bytes;
    uint64_t cpu_nanoseconds;
    int valid;
} AuxiliaryMemorySample;

// Native allocation inventory and RSS are different measures. Sample both
// before any payload hashing, packet tracing, or JSON serialization.
static inline AuxiliaryMemorySample auxiliary_memory_sample(void) {
    malloc_statistics_t allocation = {0};
    malloc_zone_statistics(NULL, &allocation);
    struct mach_task_basic_info task = {0};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t task_result = task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                                         (task_info_t)&task, &count);
    struct rusage usage = {0};
    int usage_result = getrusage(RUSAGE_SELF, &usage);
    struct timespec cpu = {0};
    int cpu_result = clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu);
    AuxiliaryMemorySample result = {
        .allocator_bytes = allocation.size_in_use,
        .resident_bytes = task.resident_size,
        .peak_resident_bytes = (uint64_t)usage.ru_maxrss,
        .cpu_nanoseconds = (uint64_t)cpu.tv_sec * 1000000000 + (uint64_t)cpu.tv_nsec,
        .valid = task_result == KERN_SUCCESS && usage_result == 0 && cpu_result == 0,
    };
    return result;
}

#endif
