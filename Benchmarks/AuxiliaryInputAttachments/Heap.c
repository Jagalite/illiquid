#include "Heap.h"
#include <malloc/malloc.h>
#include <mach/mach.h>

uint64_t auxiliary_heap_bytes(void) {
    malloc_statistics_t statistics = {0};
    malloc_zone_statistics(NULL, &statistics);
    return (uint64_t)statistics.size_in_use;
}

uint64_t auxiliary_resident_bytes(void) {
    mach_task_basic_info_data_t info = {0};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t status = task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                                    (task_info_t)&info, &count);
    return status == KERN_SUCCESS ? (uint64_t)info.resident_size : 0;
}
