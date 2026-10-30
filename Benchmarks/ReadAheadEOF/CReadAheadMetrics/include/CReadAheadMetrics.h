#ifndef C_READ_AHEAD_METRICS_H
#define C_READ_AHEAD_METRICS_H
#include <stdint.h>

typedef struct {
    int64_t cpu_nanoseconds;
    int64_t voluntary_switches;
    int64_t involuntary_switches;
    int64_t switches_available;
    int64_t error_code;
} ReadAheadMetrics;

ReadAheadMetrics read_ahead_thread_metrics(void);
ReadAheadMetrics read_ahead_process_metrics(void);
/* Clock/sleep functions return a negative POSIX error on failure. */
int64_t read_ahead_monotonic_nanoseconds(void);
int64_t read_ahead_sleep_until(int64_t deadline);
#endif
