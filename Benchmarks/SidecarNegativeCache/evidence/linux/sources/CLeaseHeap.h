#ifndef ILLIQUID_LEASE_HISTORY_HEAP_H
#define ILLIQUID_LEASE_HISTORY_HEAP_H
#include <stdint.h>
uint64_t lease_history_allocator_bytes(void);
uint64_t lease_history_process_cpu_ns(void);
const char *lease_history_allocator_metric(void);
#endif
