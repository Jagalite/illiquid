#if !defined(__APPLE__)
#error "Playlist projection memory sampling requires Darwin."
#endif
#include "MemoryProbe.h"
#include <errno.h>
#include <malloc/malloc.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

/* Dedicated memory runs only. Sampling can miss short-lived peaks; all-zone
   statistics are not atomic. This is live allocator usage, not allocation
   traffic, GPU memory, or whole-player footprint. begin/end/getters are
   serialized on the benchmark's main thread. */
static pthread_t sampler;
static pthread_mutex_t ready_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ready_condition = PTHREAD_COND_INITIALIZER;
static atomic_int stop_requested;
static int ready;
static int active;
static uint64_t values[8];
static uint64_t first_sample_ns;
static uint64_t previous_sample_ns;

static uint64_t monotonic_ns(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) abort();
    return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
}

static uint64_t peak_rss_bytes(void) {
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) abort();
    return (uint64_t)usage.ru_maxrss; /* Darwin reports bytes. */
}

static void sample_heap(void) {
    malloc_statistics_t statistics = {0};
    malloc_zone_statistics(NULL, &statistics);
    const uint64_t heap = (uint64_t)statistics.size_in_use;
    const uint64_t now = monotonic_ns();
    if (values[PLAYLIST_MEMORY_SAMPLE_COUNT] == 0) {
        values[PLAYLIST_MEMORY_BASELINE] = heap;
        first_sample_ns = now;
    } else {
        const uint64_t gap = now - previous_sample_ns;
        if (gap > values[PLAYLIST_MEMORY_MAX_GAP_NS])
            values[PLAYLIST_MEMORY_MAX_GAP_NS] = gap;
    }
    if (heap > values[PLAYLIST_MEMORY_SAMPLED_PEAK])
        values[PLAYLIST_MEMORY_SAMPLED_PEAK] = heap;
    values[PLAYLIST_MEMORY_FINAL] = heap;
    values[PLAYLIST_MEMORY_SAMPLE_COUNT] += 1;
    values[PLAYLIST_MEMORY_WINDOW_NS] = now - first_sample_ns;
    previous_sample_ns = now;
}

static void *sample_thread(void *unused) {
    (void)unused;
    sample_heap();
    if (pthread_mutex_lock(&ready_lock) != 0) abort();
    ready = 1;
    if (pthread_cond_signal(&ready_condition) != 0) abort();
    if (pthread_mutex_unlock(&ready_lock) != 0) abort();
    const struct timespec pause = { .tv_sec = 0, .tv_nsec = 200000 };
    while (!atomic_load_explicit(&stop_requested, memory_order_acquire)) {
        (void)nanosleep(&pause, NULL);
        sample_heap();
    }
    sample_heap();
    values[PLAYLIST_MEMORY_PEAK_RSS_AFTER] = peak_rss_bytes();
    return NULL;
}

int playlist_projection_memory_begin(void) {
    if (active) return EBUSY;
    if (pthread_mutex_lock(&ready_lock) != 0) abort();
    memset(values, 0, sizeof(values));
    ready = 0;
    atomic_store_explicit(&stop_requested, 0, memory_order_release);
    const int error = pthread_create(&sampler, NULL, sample_thread, NULL);
    if (error != 0) {
        if (pthread_mutex_unlock(&ready_lock) != 0) abort();
        return error;
    }
    active = 1;
    while (!ready) {
        if (pthread_cond_wait(&ready_condition, &ready_lock) != 0) abort();
    }
    if (pthread_mutex_unlock(&ready_lock) != 0) abort();
    values[PLAYLIST_MEMORY_PEAK_RSS_BEFORE] = peak_rss_bytes();
    return 0;
}

void playlist_projection_memory_end(void) {
    if (!active) abort();
    atomic_store_explicit(&stop_requested, 1, memory_order_release);
    if (pthread_join(sampler, NULL) != 0) abort();
    active = 0;
}

uint64_t playlist_projection_memory_value(int field) {
    if (active || field < 0 || field >= 8) abort();
    return values[field];
}
