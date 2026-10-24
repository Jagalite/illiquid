#ifndef ILLIQUID_STARTUP_SNAPSHOT_HEAP_H
#define ILLIQUID_STARTUP_SNAPSHOT_HEAP_H

#include <stdint.h>

uint64_t startup_heap_bytes(void);
const char *startup_heap_metric(void);
uint64_t startup_cpu_nanoseconds(void);

#endif
