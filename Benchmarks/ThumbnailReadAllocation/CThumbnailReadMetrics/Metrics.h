#ifndef ILLIQUID_THUMBNAIL_READ_METRICS_H
#define ILLIQUID_THUMBNAIL_READ_METRICS_H
#include <stdint.h>
uint64_t thumbnail_heap_bytes(void);
uint64_t thumbnail_resident_bytes(void);
uint64_t thumbnail_cpu_nanoseconds(void);
const char *thumbnail_heap_metric(void);
const char *thumbnail_resident_metric(void);
void meter_begin(void);
void meter_end(void);
uint64_t meter_requests(void);
uint64_t meter_bytes(void);
#endif
