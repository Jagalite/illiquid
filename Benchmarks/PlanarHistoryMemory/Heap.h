#ifndef ILLIQUID_PLANAR_HISTORY_HEAP_H
#define ILLIQUID_PLANAR_HISTORY_HEAP_H
#include <stdint.h>
uint64_t planar_history_heap_bytes(void);
uint64_t planar_history_peak_rss_bytes(void);
uint64_t planar_history_cpu_nanoseconds(void);
const char *planar_history_heap_metric(void);
#endif
