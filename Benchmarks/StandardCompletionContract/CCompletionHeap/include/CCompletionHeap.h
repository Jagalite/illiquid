#include <stdint.h>
uint64_t completion_heap_bytes(void);
const char *completion_heap_metric(void);
int completion_allocation_meter_available(void);
void completion_meter_begin(void);
void completion_meter_end(void);
uint64_t completion_allocation_requests(void);
uint64_t completion_requested_bytes(void);
