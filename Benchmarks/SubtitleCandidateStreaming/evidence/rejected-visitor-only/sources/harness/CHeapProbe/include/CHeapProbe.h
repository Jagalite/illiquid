#ifndef ILLIQUID_SUBTITLE_CANDIDATE_HEAP_H
#define ILLIQUID_SUBTITLE_CANDIDATE_HEAP_H
#include <stdint.h>
uint64_t subtitle_candidate_heap_bytes(void);
uint64_t subtitle_candidate_cpu_nanoseconds(void);
const char *subtitle_candidate_heap_metric(void);
void subtitle_candidate_consume(uint64_t value);
#endif
