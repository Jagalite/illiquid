#ifndef ILLIQUID_AUXILIARY_HEAP_H
#define ILLIQUID_AUXILIARY_HEAP_H

#include <stdint.h>

uint64_t auxiliary_heap_bytes(void);
uint64_t auxiliary_resident_bytes(void);
uint64_t auxiliary_cpu_nanoseconds(void);

#endif
