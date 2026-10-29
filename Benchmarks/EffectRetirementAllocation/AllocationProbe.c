/*
 * Linux/glibc-only allocation-request probe for a synchronous core event.
 * Preload this library only in separate allocation runs, never in timing runs.
 *
 * Count successful malloc/calloc/realloc requests on the calling thread while
 * enabled. Requested bytes are cumulative traffic, not object counts, live or
 * peak bytes, RSS, or allocator usable sizes. Realloc counts the requested new
 * size even if it succeeds in place. Aligned allocators and free are excluded.
 * Direct glibc entry points avoid recursive dlsym allocation. Initial-exec TLS
 * avoids lazy dynamic-TLS allocation inside an intercepted allocator call.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#if !defined(__linux__) || !defined(__GLIBC__)
#error "This allocation-request probe requires Linux with glibc"
#endif

extern void *__libc_malloc(size_t size);
extern void *__libc_calloc(size_t count, size_t size);
extern void *__libc_realloc(void *pointer, size_t size);

static _Thread_local int measuring __attribute__((tls_model("initial-exec")));
static _Thread_local uint64_t requests __attribute__((tls_model("initial-exec")));
static _Thread_local uint64_t requested_bytes __attribute__((tls_model("initial-exec")));

static void observe(size_t size) {
    if (!measuring) return;
    if (requests == UINT64_MAX || requested_bytes > UINT64_MAX - (uint64_t)size) abort();
    requests += 1;
    requested_bytes += (uint64_t)size;
}

void *malloc(size_t size) {
    void *result = __libc_malloc(size);
    if (result) observe(size);
    return result;
}

void *calloc(size_t count, size_t size) {
    void *result = __libc_calloc(count, size);
    if (result) {
        if (count != 0 && size > SIZE_MAX / count) abort();
        observe(count * size);
    }
    return result;
}

void *realloc(void *pointer, size_t size) {
    void *result = __libc_realloc(pointer, size);
    if (result) observe(size);
    return result;
}

void illiquid_effect_probe_begin(void) {
    requests = 0;
    requested_bytes = 0;
    measuring = 1;
}

void illiquid_effect_probe_end(void) { measuring = 0; }
uint64_t illiquid_effect_probe_calls(void) { return requests; }
uint64_t illiquid_effect_probe_bytes(void) { return requested_bytes; }
