#ifndef ILLIQUID_PRESENCE_SNAPSHOT_HEAP_H
#define ILLIQUID_PRESENCE_SNAPSHOT_HEAP_H
#include <stdint.h>
uint64_t presence_heap_bytes(void);
uint64_t presence_cpu_nanoseconds(void);
const char *presence_heap_metric(void);
#endif
