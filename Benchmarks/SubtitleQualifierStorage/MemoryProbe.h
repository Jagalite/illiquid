#ifndef ILLIQUID_SOURCE_PRESENCE_MEMORY_PROBE_H
#define ILLIQUID_SOURCE_PRESENCE_MEMORY_PROBE_H

#include <stdint.h>

uint64_t memory_probe_heap_bytes(void);
uint64_t memory_probe_rss_bytes(void);
uint64_t memory_probe_peak_rss_bytes(void);

#endif
