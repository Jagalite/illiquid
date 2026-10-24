#include <stdint.h>

typedef struct {
    uint64_t live_malloc_bytes;
    uint64_t resident_bytes;
    uint64_t physical_footprint_bytes;
    uint64_t peak_resident_bytes;
} StartupMemorySnapshot;

int startup_memory_snapshot(StartupMemorySnapshot *snapshot);
