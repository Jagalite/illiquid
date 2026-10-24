#ifndef FONT_COPY_RESIDENCY_PROBE_H
#define FONT_COPY_RESIDENCY_PROBE_H

#include <stddef.h>
#include <stdint.h>

#define FCR_STAGE_COUNT 12

typedef struct {
    uint64_t wall_nanoseconds;
    uint64_t malloc_bytes_in_use, malloc_blocks_in_use, malloc_bytes_allocated;
    uint64_t resident_size, phys_footprint, internal, reusable, compressed;
    int32_t task_info_result;
    uint32_t task_info_count;
} FCRSnapshot;

typedef struct { FCRSnapshot samples[FCR_STAGE_COUNT]; } FCRTrace;

typedef struct {
    uint64_t address, page_offset, malloc_size, zone_address;
    const char *zone_name;
} FCRAllocationInfo;

size_t fcr_page_size(void);
uint32_t fcr_required_task_info_count(void);
uint64_t fcr_clock_nanoseconds(void);
void fcr_capture(FCRTrace *trace, unsigned index);
FCRSnapshot fcr_sample(const FCRTrace *trace, unsigned index);
FCRAllocationInfo fcr_allocation_info(const void *allocation_base);
void *fcr_allocate(size_t bytes, int page_aligned);
void fcr_release(void *allocation);
size_t fcr_pressure_relief(void);
void fcr_fill_pattern(void *destination, size_t count);
void fcr_dirty(void *destination, size_t count);
void fcr_volatile_copy(const void *source, void *destination, size_t count);
uint64_t fcr_read_touch(const void *source, size_t count);
int fcr_validate_pattern(const void *source, size_t count, size_t *first_mismatch);
int32_t fcr_vm_copy(const void *source, void *destination, size_t count);

#endif
