#ifndef ILLIQUID_COMPLETED_WORK_LIFETIME_HEAP_H
#define ILLIQUID_COMPLETED_WORK_LIFETIME_HEAP_H
#include <stdint.h>
uint64_t work_lifetime_heap_bytes(void);
uint64_t work_lifetime_cpu_nanoseconds(void);
const char *work_lifetime_heap_metric(void);
#endif
