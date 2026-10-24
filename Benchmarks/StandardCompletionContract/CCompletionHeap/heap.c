#include "CCompletionHeap.h"
#include <stdlib.h>
#include <stdatomic.h>
#if defined(__APPLE__)
#include <malloc/malloc.h>
#elif defined(__GLIBC__)
#include <malloc.h>
#if __GLIBC_PREREQ(2, 33)
#define COMPLETION_HAS_MALLINFO2 1
#endif
#endif

uint64_t completion_heap_bytes(void) {
#if defined(__APPLE__)
    malloc_statistics_t statistics = {0};
    malloc_zone_statistics(NULL, &statistics);
    return (uint64_t)statistics.size_in_use;
#elif defined(COMPLETION_HAS_MALLINFO2)
    struct mallinfo2 statistics = mallinfo2();
    return (uint64_t)statistics.uordblks + (uint64_t)statistics.hblkhd;
#else
    return 0;
#endif
}

const char *completion_heap_metric(void) {
#if defined(__APPLE__)
    return "malloc_zone_statistics(NULL).size_in_use";
#elif defined(COMPLETION_HAS_MALLINFO2)
    return "mallinfo2.uordblks + mallinfo2.hblkhd";
#else
    return "unsupported";
#endif
}

/* Successful malloc/calloc/realloc requests, not live allocations or RSS.
   Linux-only interposition; native macOS reports the live-byte metric above.
   These counters add work, so instrumented times are not speedup evidence. */
static _Atomic int enabled = 0;
static _Atomic uint64_t requests = 0, bytes = 0;
#if defined(__GLIBC__)
extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
static void record(size_t size) {
    if (atomic_load_explicit(&enabled, memory_order_relaxed)) {
        atomic_fetch_add_explicit(&requests, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&bytes, size, memory_order_relaxed);
    }
}
void *malloc(size_t n) { void *p = __libc_malloc(n); if (p) record(n); return p; }
void *calloc(size_t n, size_t s) { void *p = __libc_calloc(n, s); if (p) record(n * s); return p; }
void *realloc(void *p, size_t n) { void *q = __libc_realloc(p, n); if (q) record(n); return q; }
int completion_allocation_meter_available(void) { return 1; }
#else
int completion_allocation_meter_available(void) { return 0; }
#endif
void completion_meter_begin(void) {
    atomic_store(&requests, 0); atomic_store(&bytes, 0); atomic_store(&enabled, 1);
}
void completion_meter_end(void) { atomic_store(&enabled, 0); }
uint64_t completion_allocation_requests(void) { return atomic_load(&requests); }
uint64_t completion_requested_bytes(void) { return atomic_load(&bytes); }
