#include "StartupMemory.h"
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <sys/resource.h>

int startup_memory_snapshot(StartupMemorySnapshot *snapshot) {
    malloc_statistics_t statistics = {0};
    malloc_zone_statistics(NULL, &statistics);
    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t status = task_info(mach_task_self(), TASK_VM_INFO,
                                    (task_info_t)&info, &count);
    if (status != KERN_SUCCESS) return (int)status;
    struct rusage usage = {0};
    if (getrusage(RUSAGE_SELF, &usage) != 0) return -1;
    snapshot->live_malloc_bytes = statistics.size_in_use;
    snapshot->resident_bytes = info.resident_size;
    snapshot->physical_footprint_bytes = info.phys_footprint;
    snapshot->peak_resident_bytes = (uint64_t)usage.ru_maxrss;
    return 0;
}
