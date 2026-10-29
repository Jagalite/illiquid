#ifndef ILLIQUID_CATALOG_ID_MEMORY_PROBE_H
#define ILLIQUID_CATALOG_ID_MEMORY_PROBE_H

#include <stdint.h>

uint64_t catalog_live_allocated_bytes(void);
uint64_t catalog_cpu_nanoseconds(void);

#endif
