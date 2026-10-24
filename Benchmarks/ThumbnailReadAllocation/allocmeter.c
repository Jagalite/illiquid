/* Linux/glibc-only test instrumentation. Counts allocation REQUESTS, not live
   heap bytes, RSS, CGImage memory, GPU memory, or macOS footprint. No production use. */
#include <stdlib.h>
#include <stdint.h>
#include <stdatomic.h>
extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
static _Atomic int enabled = 0;
static _Atomic uint64_t requests = 0, bytes = 0;
static void record(size_t size) {
    if (atomic_load_explicit(&enabled,memory_order_relaxed)) {
        atomic_fetch_add_explicit(&requests,1,memory_order_relaxed);
        atomic_fetch_add_explicit(&bytes,size,memory_order_relaxed);
    }
}
void *malloc(size_t n) { void *p=__libc_malloc(n); if(p)record(n); return p; }
void *calloc(size_t n,size_t size) { void *p=__libc_calloc(n,size); if(p)record(n*size); return p; }
void *realloc(void *p,size_t n) { void *q=__libc_realloc(p,n); if(q)record(n); return q; }
void meter_begin(void) { atomic_store(&requests,0); atomic_store(&bytes,0); atomic_store(&enabled,1); }
void meter_end(void) { atomic_store(&enabled,0); }
uint64_t meter_requests(void) { return atomic_load(&requests); }
uint64_t meter_bytes(void) { return atomic_load(&bytes); }
