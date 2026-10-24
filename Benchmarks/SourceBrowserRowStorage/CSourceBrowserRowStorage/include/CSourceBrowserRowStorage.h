#ifndef ILLIQUID_SOURCE_BROWSER_ROW_STORAGE_H
#define ILLIQUID_SOURCE_BROWSER_ROW_STORAGE_H
#include <stdint.h>
uint64_t source_browser_heap_bytes(void);
uint64_t source_browser_cpu_nanoseconds(void);
const char *source_browser_heap_metric(void);
#endif
