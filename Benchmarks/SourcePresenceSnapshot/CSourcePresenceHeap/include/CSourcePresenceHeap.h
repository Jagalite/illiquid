#ifndef ILLIQUID_SOURCE_PRESENCE_HEAP_H
#define ILLIQUID_SOURCE_PRESENCE_HEAP_H

#include <stdint.h>

uint64_t source_presence_heap_bytes(void);
uint64_t source_presence_cpu_nanoseconds(void);
const char *source_presence_heap_metric(void);
void source_presence_consume(uint64_t value);

#endif
