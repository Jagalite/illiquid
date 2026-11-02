#ifndef ILLIQUID_SOURCE_ROOT_INDEX_PROBE_H
#define ILLIQUID_SOURCE_ROOT_INDEX_PROBE_H
#include <stdint.h>
uint64_t probe_cpu_ns(void);
uint64_t probe_heap_in_use(void);
uint64_t probe_peak_rss_bytes(void);
int probe_start_sampling(void);
void probe_stop_sampling(void);
uint64_t probe_sampled_peak_in_use(void);
#endif
