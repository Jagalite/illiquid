/* Research-only allocation-request counters. No live-byte, peak, or RSS claim.
 * Timing binaries compile this file without FD_METERED and contain no hooks.
 * Metered binaries count successful covered allocator requests on the calling
 * thread. Nested typed/zone calls are counted once, at their outer boundary.
 */
#include <stdint.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <pthread.h>

static _Atomic int enabled;
static _Atomic uint64_t requests, bytes, largest;
static pthread_t owner;
static _Thread_local unsigned depth;

void fd_probe_begin(void) {
    /* Initialize this thread's TLS before enabling interception. */
    depth = 0;
    owner = pthread_self();
    atomic_store(&requests, 0);
    atomic_store(&bytes, 0);
    atomic_store(&largest, 0);
    atomic_store(&enabled, 1);
}
void fd_probe_end(void) { atomic_store(&enabled, 0); }
uint64_t fd_probe_requests(void) { return atomic_load(&requests); }
uint64_t fd_probe_bytes(void) { return atomic_load(&bytes); }
uint64_t fd_probe_largest(void) { return atomic_load(&largest); }

/* Called through a separate C library so the Swift array control must escape. */
uint64_t fd_probe_consume(const void *pointer, size_t count) {
    const volatile unsigned char *p = pointer;
    uint64_t checksum = count;
    for (size_t i = 0; i < count; i += 4096) checksum += p[i];
    if (count) checksum += p[count - 1];
    return checksum;
}

#if defined(FD_METERED)
static int measuring(void) {
    return atomic_load(&enabled) && pthread_equal(owner, pthread_self());
}
static void record(size_t size) {
    atomic_fetch_add(&requests, 1);
    atomic_fetch_add(&bytes, size);
    if (size > atomic_load(&largest)) atomic_store(&largest, size);
}

#if defined(__APPLE__)
#include <malloc/malloc.h>
#include <malloc/_malloc_type.h>

/* dyld exempts the interposing image's own bindings, letting these wrappers
 * call the original implementation. Typed entry points matter for modern
 * Swift runtimes. See Apple's dyld interposing and Swift runtime Heap.cpp.
 */
#define FD_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static const struct { \
        const void *new_function; const void *old_function; \
    } fd_interpose_##replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(uintptr_t)&replacement, (const void *)(uintptr_t)&replacee \
    }

#define FD_POINTER(name, parameters, arguments, requested) \
    static void *fd_##name parameters { \
        if (!measuring()) return name arguments; \
        unsigned nested = depth++; \
        void *result = name arguments; \
        if (!nested && result) record(requested); \
        --depth; return result; \
    } \
    FD_INTERPOSE(fd_##name, name)

FD_POINTER(malloc, (size_t n), (n), n);
FD_POINTER(calloc, (size_t n, size_t s), (n, s), n * s);
FD_POINTER(realloc, (void *p, size_t n), (p, n), n);
FD_POINTER(aligned_alloc, (size_t a, size_t n), (a, n), n);
FD_POINTER(valloc, (size_t n), (n), n);
FD_POINTER(malloc_type_malloc, (size_t n, malloc_type_id_t t), (n, t), n);
FD_POINTER(malloc_type_calloc, (size_t n, size_t s, malloc_type_id_t t), (n, s, t), n * s);
FD_POINTER(malloc_type_realloc, (void *p, size_t n, malloc_type_id_t t), (p, n, t), n);
FD_POINTER(malloc_type_aligned_alloc, (size_t a, size_t n, malloc_type_id_t t), (a, n, t), n);
FD_POINTER(malloc_type_valloc, (size_t n, malloc_type_id_t t), (n, t), n);
FD_POINTER(malloc_zone_malloc, (malloc_zone_t *z, size_t n), (z, n), n);
FD_POINTER(malloc_zone_calloc, (malloc_zone_t *z, size_t n, size_t s), (z, n, s), n * s);
FD_POINTER(malloc_zone_realloc, (malloc_zone_t *z, void *p, size_t n), (z, p, n), n);
FD_POINTER(malloc_zone_memalign, (malloc_zone_t *z, size_t a, size_t n), (z, a, n), n);
FD_POINTER(malloc_zone_valloc, (malloc_zone_t *z, size_t n), (z, n), n);
FD_POINTER(malloc_type_zone_malloc, (malloc_zone_t *z, size_t n, malloc_type_id_t t), (z, n, t), n);
FD_POINTER(malloc_type_zone_calloc, (malloc_zone_t *z, size_t n, size_t s, malloc_type_id_t t), (z, n, s, t), n * s);
FD_POINTER(malloc_type_zone_realloc, (malloc_zone_t *z, void *p, size_t n, malloc_type_id_t t), (z, p, n, t), n);
FD_POINTER(malloc_type_zone_memalign, (malloc_zone_t *z, size_t a, size_t n, malloc_type_id_t t), (z, a, n, t), n);
FD_POINTER(malloc_type_zone_valloc, (malloc_zone_t *z, size_t n, malloc_type_id_t t), (z, n, t), n);

static int fd_posix_memalign(void **p, size_t a, size_t n) {
    if (!measuring()) return posix_memalign(p, a, n);
    unsigned nested = depth++;
    int result = posix_memalign(p, a, n);
    if (!nested && result == 0) record(n);
    --depth; return result;
}
FD_INTERPOSE(fd_posix_memalign, posix_memalign);
static int fd_malloc_type_posix_memalign(void **p, size_t a, size_t n, malloc_type_id_t t) {
    if (!measuring()) return malloc_type_posix_memalign(p, a, n, t);
    unsigned nested = depth++;
    int result = malloc_type_posix_memalign(p, a, n, t);
    if (!nested && result == 0) record(n);
    --depth; return result;
}
FD_INTERPOSE(fd_malloc_type_posix_memalign, malloc_type_posix_memalign);
int fd_probe_available(void) { return 1; }

#elif defined(__GLIBC__)
/* The glibc entry points avoid dlsym recursion during process startup. */
extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
void *malloc(size_t n) {
    void *p = __libc_malloc(n);
    if (p && measuring()) record(n);
    return p;
}
void *calloc(size_t n, size_t s) {
    void *p = __libc_calloc(n, s);
    if (p && measuring()) record(n * s);
    return p;
}
void *realloc(void *p, size_t n) {
    void *q = __libc_realloc(p, n);
    if (q && measuring()) record(n);
    return q;
}
int fd_probe_available(void) { return 1; }
#else
#error "Allocation measurement requires macOS or Linux/glibc"
#endif
#else
int fd_probe_available(void) { return 0; }
#endif
