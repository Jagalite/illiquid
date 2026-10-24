#include "Probe.h"
#include <mach/mach.h>
#include <mach/task_info.h>
#include <malloc/malloc.h>
#include <stdlib.h>
#include <time.h>

size_t fcr_page_size(void) { return (size_t)vm_page_size; }
uint32_t fcr_required_task_info_count(void) { return TASK_VM_INFO_REV1_COUNT; }

uint64_t fcr_clock_nanoseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &value) != 0) abort();
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) + (uint64_t)value.tv_nsec;
}

void fcr_capture(FCRTrace *trace, unsigned index) {
    if (index >= FCR_STAGE_COUNT) abort();
    FCRSnapshot *sample = &trace->samples[index];
    malloc_statistics_t heap = {0};
    task_vm_info_data_t vm = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    malloc_zone_statistics(NULL, &heap);
    sample->task_info_result = task_info(mach_task_self(), TASK_VM_INFO,
                                        (task_info_t)&vm, &count);
    sample->task_info_count = count;
    sample->malloc_bytes_in_use = heap.size_in_use;
    sample->malloc_blocks_in_use = heap.blocks_in_use;
    sample->malloc_bytes_allocated = heap.size_allocated;
    sample->resident_size = vm.resident_size;
    sample->phys_footprint = vm.phys_footprint;
    sample->internal = vm.internal;
    sample->reusable = vm.reusable;
    sample->compressed = vm.compressed;
    sample->wall_nanoseconds = fcr_clock_nanoseconds();
}

FCRSnapshot fcr_sample(const FCRTrace *trace, unsigned index) {
    if (index >= FCR_STAGE_COUNT) abort();
    return trace->samples[index];
}

FCRAllocationInfo fcr_allocation_info(const void *allocation_base) {
    FCRAllocationInfo info = {0};
    info.address = (uint64_t)(uintptr_t)allocation_base;
    info.page_offset = info.address % fcr_page_size();
    info.zone_name = "none";
    if (allocation_base != NULL) {
        malloc_zone_t *zone = malloc_zone_from_ptr(allocation_base);
        if (zone != NULL) {
            info.malloc_size = malloc_size(allocation_base);
            info.zone_address = (uint64_t)(uintptr_t)zone;
            const char *name = malloc_get_zone_name(zone);
            info.zone_name = name != NULL ? name : "unnamed";
        }
    }
    return info;
}

void *fcr_allocate(size_t bytes, int page_aligned) {
    void *result = NULL;
    if (page_aligned) {
        if (posix_memalign(&result, fcr_page_size(), bytes) != 0) return NULL;
    } else {
        result = malloc(bytes);
    }
    return result;
}

void fcr_release(void *allocation) { free(allocation); }
size_t fcr_pressure_relief(void) { return malloc_zone_pressure_relief(NULL, 0); }

void fcr_fill_pattern(void *destination, size_t count) {
    volatile unsigned char *bytes = destination;
    for (size_t i = 0; i < count; ++i) bytes[i] = (unsigned char)(1 + i % 251);
}

void fcr_dirty(void *destination, size_t count) {
    volatile unsigned char *bytes = destination;
    for (size_t i = 0; i < count; ++i) bytes[i] = 0xa5;
}

void fcr_volatile_copy(const void *source, void *destination, size_t count) {
    const volatile unsigned char *input = source;
    volatile unsigned char *output = destination;
    for (size_t i = 0; i < count; ++i) output[i] = input[i];
}

uint64_t fcr_read_touch(const void *source, size_t count) {
    const volatile unsigned char *bytes = source;
    uint64_t checksum = 0;
    for (size_t i = 0; i < count; ++i) checksum += bytes[i];
    return checksum;
}

int fcr_validate_pattern(const void *source, size_t count, size_t *first_mismatch) {
    const volatile unsigned char *bytes = source;
    for (size_t i = 0; i < count; ++i) {
        if (bytes[i] != (unsigned char)(1 + i % 251)) {
            *first_mismatch = i;
            return 0;
        }
    }
    *first_mismatch = count;
    return 1;
}

int32_t fcr_vm_copy(const void *source, void *destination, size_t count) {
    return vm_copy(mach_task_self(), (vm_address_t)(uintptr_t)source,
                   (vm_size_t)count, (vm_address_t)(uintptr_t)destination);
}
