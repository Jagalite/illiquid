#include "Probe.h"
#include <malloc/malloc.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <sys/resource.h>
#include <time.h>

uint64_t probe_cpu_ns(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000000000ULL + (uint64_t)value.tv_nsec;
}

uint64_t probe_heap_in_use(void) {
    malloc_statistics_t value = {0};
    malloc_zone_statistics(NULL, &value);
    return value.size_in_use;
}

uint64_t probe_peak_rss_bytes(void) {
    struct rusage value = {0};
    if (getrusage(RUSAGE_SELF, &value) != 0) return 0;
    // Darwin reports ru_maxrss in bytes.
    return (uint64_t)value.ru_maxrss;
}

// Sampling belongs to a separate cohort; no sampler runs during timing trials.
// This estimates peak live malloc bytes, not allocation churn or complete RSS.
static pthread_t sampler;
static _Atomic bool running = false;
static _Atomic uint64_t sampled_peak = 0;

static void sample(void) {
    uint64_t current = probe_heap_in_use();
    uint64_t previous = atomic_load(&sampled_peak);
    while (current > previous &&
           !atomic_compare_exchange_weak(&sampled_peak, &previous, current)) {}
}

static void *sample_loop(void *unused) {
    (void)unused;
    const struct timespec pause = {.tv_sec = 0, .tv_nsec = 500000};
    while (atomic_load(&running)) {
        sample();
        nanosleep(&pause, NULL);
    }
    sample();
    return NULL;
}

int probe_start_sampling(void) {
    atomic_store(&sampled_peak, probe_heap_in_use());
    atomic_store(&running, true);
    int result = pthread_create(&sampler, NULL, sample_loop, NULL);
    if (result != 0) atomic_store(&running, false);
    return result;
}

void probe_stop_sampling(void) {
    atomic_store(&running, false);
    pthread_join(sampler, NULL);
}

uint64_t probe_sampled_peak_in_use(void) {
    return atomic_load(&sampled_peak);
}
