/* Linux/glibc-only allocation REQUEST traffic. Not retained bytes or RSS.
 * Run in separate processes; do not use an interposed binary for timings. */
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>

extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
static _Atomic int enabled = 0;
static _Atomic uint64_t requests = 0, bytes = 0;

static void record(size_t size) {
    if (atomic_load_explicit(&enabled, memory_order_relaxed)) {
        atomic_fetch_add_explicit(&requests, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&bytes, size, memory_order_relaxed);
    }
}

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

void subtitle_key_meter_reset(void) {
    atomic_store(&enabled, 0);
    atomic_store(&requests, 0);
    atomic_store(&bytes, 0);
}
void subtitle_key_meter_enable(void) { atomic_store(&enabled, 1); }
void subtitle_key_meter_disable(void) { atomic_store(&enabled, 0); }
uint64_t subtitle_key_meter_requests(void) { return atomic_load(&requests); }
uint64_t subtitle_key_meter_bytes(void) { return atomic_load(&bytes); }
