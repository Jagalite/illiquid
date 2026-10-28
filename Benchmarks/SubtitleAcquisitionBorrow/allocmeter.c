/* Benchmark-only allocation request counter. This is not a live-byte, RSS,
 * physical-footprint, or complete allocator census. Instrumented executables
 * are separate from the executables used for timing. */
#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>

static _Atomic int enabled = 0;
static _Atomic uint64_t requests = 0;
static _Atomic uint64_t bytes = 0;

static void record(size_t size) {
    if (atomic_load_explicit(&enabled, memory_order_relaxed)) {
        atomic_fetch_add_explicit(&requests, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&bytes, size, memory_order_relaxed);
    }
}

#if defined(__APPLE__)
#include <mach-o/dyld-interposing.h>

static void *measured_malloc(size_t size) {
    void *result = malloc(size);
    if (result) record(size);
    return result;
}
static void *measured_calloc(size_t count, size_t size) {
    void *result = calloc(count, size);
    if (result) record(count * size);
    return result;
}
static void *measured_realloc(void *pointer, size_t size) {
    void *result = realloc(pointer, size);
    if (result) record(size);
    return result;
}
DYLD_INTERPOSE(measured_malloc, malloc)
DYLD_INTERPOSE(measured_calloc, calloc)
DYLD_INTERPOSE(measured_realloc, realloc)
#elif defined(__GLIBC__)
extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
void *malloc(size_t size) {
    void *result = __libc_malloc(size);
    if (result) record(size);
    return result;
}
void *calloc(size_t count, size_t size) {
    void *result = __libc_calloc(count, size);
    if (result) record(count * size);
    return result;
}
void *realloc(void *pointer, size_t size) {
    void *result = __libc_realloc(pointer, size);
    if (result) record(size);
    return result;
}
#else
#error This benchmark counter requires macOS or Linux with glibc.
#endif

void meter_begin(void) {
    atomic_store(&requests, 0);
    atomic_store(&bytes, 0);
    atomic_store(&enabled, 1);
}
void meter_end(void) { atomic_store(&enabled, 0); }
uint64_t meter_requests(void) { return atomic_load(&requests); }
uint64_t meter_bytes(void) { return atomic_load(&bytes); }
