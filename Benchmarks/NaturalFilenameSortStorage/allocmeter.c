/* Linux/glibc-only benchmark instrumentation; never linked into the player.
 *
 * Counts successful allocation requests and requested bytes, not live heap,
 * allocator capacity, peak memory, RSS, or macOS footprint. Realloc charges its
 * full requested size, even when storage is reused; frees are not subtracted.
 * Failed requests and realloc(p, 0) returning NULL are not counted.
 *
 * Each thread has its own measurement window. Only allocations on the thread
 * calling meter_begin() are recorded, suitable for the synchronous sort probe.
 * Do not migrate a measurement between threads or call the API from signals.
 * Load at process startup (link or LD_PRELOAD): initial-exec TLS and direct
 * __libc_* calls avoid allocator recursion from dlsym or dynamic TLS setup.
 * Internal libc allocations and allocation APIs not wrapped below are excluded.
 */
#define _GNU_SOURCE 1
#include <errno.h>
#include <malloc.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#if !defined(__linux__) || !defined(__GLIBC__)
#error "This allocation meter requires Linux with glibc."
#endif

_Static_assert(sizeof(size_t) <= sizeof(uint64_t), "request size exceeds counter width");

extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
extern void *__libc_memalign(size_t, size_t);

void meter_begin(void);
void meter_end(void);
uint64_t meter_requests(void);
uint64_t meter_bytes(void);
uint64_t meter_max_request(void);
uint64_t meter_large_count(void);
uint64_t meter_large_size(uint64_t index);
uint64_t meter_large_requests(uint64_t index);

enum { LARGE_BUCKETS = 16 };

struct LargeRequest {
    uint64_t size;
    uint64_t requests;
};

struct Meter {
    int active;
    uint64_t requests;
    uint64_t bytes;
    uint64_t max_request;
    size_t large_count;
    struct LargeRequest large[LARGE_BUCKETS];
};

static _Thread_local struct Meter meter
    __attribute__((tls_model("initial-exec")));

static uint64_t saturated_add(uint64_t left, uint64_t right) {
    return right > UINT64_MAX - left ? UINT64_MAX : left + right;
}

static void record(size_t requested_size) {
    if (!meter.active) return;

    const uint64_t size = (uint64_t)requested_size;
    meter.requests = saturated_add(meter.requests, 1);
    meter.bytes = saturated_add(meter.bytes, size);
    if (size > meter.max_request) meter.max_request = size;

    /* Keep the largest 16 distinct sizes, in descending order. Frequencies for
     * retained sizes are exact (until counter saturation); this is not a full
     * histogram. Once evicted, a smaller size can never re-enter the top 16.
     * No allocation, locking, formatting, or symbol lookup occurs here.
     */
    size_t index = 0;
    while (index < meter.large_count && meter.large[index].size > size) ++index;
    if (index < meter.large_count && meter.large[index].size == size) {
        meter.large[index].requests = saturated_add(meter.large[index].requests, 1);
        return;
    }
    if (index == LARGE_BUCKETS) return;
    if (meter.large_count < LARGE_BUCKETS) ++meter.large_count;
    for (size_t position = meter.large_count - 1; position > index; --position) {
        meter.large[position] = meter.large[position - 1];
    }
    meter.large[index] = (struct LargeRequest){ .size = size, .requests = 1 };
}

void *malloc(size_t size) {
    void *result = __libc_malloc(size);
    if (result != NULL) record(size);
    return result;
}

void *calloc(size_t count, size_t size) {
    void *result = __libc_calloc(count, size);
    /* glibc rejects overflow itself; never compute a wrapped request total. */
    if (result != NULL && (size == 0 || count <= SIZE_MAX / size)) {
        record(count * size);
    }
    return result;
}

void *realloc(void *pointer, size_t size) {
    void *result = __libc_realloc(pointer, size);
    if (result != NULL) record(size);
    return result;
}

void *memalign(size_t alignment, size_t size) {
    void *result = __libc_memalign(alignment, size);
    if (result != NULL) record(size);
    return result;
}

void *aligned_alloc(size_t alignment, size_t size) {
    /* Match glibc's C17 alignment check. Like glibc, do not add a size-multiple
     * restriction; __libc_memalign supplies the actual allocation/error path.
     */
    if (alignment == 0 || (alignment & (alignment - 1)) != 0) {
        errno = EINVAL;
        return NULL;
    }
    void *result = __libc_memalign(alignment, size);
    if (result != NULL) record(size);
    return result;
}

int posix_memalign(void **pointer, size_t alignment, size_t size) {
    /* POSIX requires a nonzero power of two divisible by sizeof(void *), an
     * unchanged output pointer on failure, and an unchanged errno in all cases.
     */
    if (alignment == 0 || (alignment & (alignment - 1)) != 0
        || alignment % sizeof(void *) != 0) {
        return EINVAL;
    }
    const int saved_errno = errno;
    void *result = __libc_memalign(alignment, size);
    errno = saved_errno;
    if (result == NULL) return ENOMEM;
    *pointer = result;
    record(size);
    return 0;
}

void meter_begin(void) {
    meter.active = 0;
    meter.requests = 0;
    meter.bytes = 0;
    meter.max_request = 0;
    meter.large_count = 0;
    meter.active = 1;
}

void meter_end(void) { meter.active = 0; }
uint64_t meter_requests(void) { return meter.requests; }
uint64_t meter_bytes(void) { return meter.bytes; }
uint64_t meter_max_request(void) { return meter.max_request; }
uint64_t meter_large_count(void) { return (uint64_t)meter.large_count; }

uint64_t meter_large_size(uint64_t index) {
    return index < meter.large_count ? meter.large[(size_t)index].size : 0;
}

uint64_t meter_large_requests(uint64_t index) {
    return index < meter.large_count ? meter.large[(size_t)index].requests : 0;
}
