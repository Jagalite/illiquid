#include "CAudioPCMProbe.h"
#include <malloc/malloc.h>
#include <time.h>

uint64_t audio_pcm_heap_bytes(void) {
    malloc_statistics_t statistics;
    malloc_zone_statistics(NULL, &statistics);
    return (uint64_t)statistics.size_in_use;
}

uint64_t audio_pcm_process_cpu_ns(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000000000 + (uint64_t)value.tv_nsec;
}
