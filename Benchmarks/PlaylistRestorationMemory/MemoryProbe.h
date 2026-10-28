#ifndef ILLIQUID_RESTORATION_MEMORY_PROBE_H
#define ILLIQUID_RESTORATION_MEMORY_PROBE_H

#include <stdint.h>

typedef struct {
    uint64_t before_bytes;
    uint64_t checkpoint_bytes;
    uint64_t unique_count;
    uint64_t map_capacity;
    uint64_t order_capacity;
    uint64_t checkpoint_count;
} RestorationMemorySample;

void restoration_memory_begin(void);
void restoration_memory_checkpoint(uint64_t unique_count,
                                   uint64_t map_capacity,
                                   uint64_t order_capacity);
RestorationMemorySample restoration_memory_sample(void);

#endif
