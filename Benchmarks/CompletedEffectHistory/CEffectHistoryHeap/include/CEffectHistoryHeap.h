#ifndef ILLIQUID_COMPLETED_EFFECT_HISTORY_HEAP_H
#define ILLIQUID_COMPLETED_EFFECT_HISTORY_HEAP_H
#include <stdint.h>
uint64_t effect_history_heap_bytes(void);
uint64_t effect_history_cpu_nanoseconds(void);
const char *effect_history_heap_metric(void);
#endif
