/* Calibrate the benchmark's glibc request counter, without timing production. */
#define _GNU_SOURCE 1
#include <assert.h>
#include <errno.h>
#include <malloc.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

void meter_begin(void);
void meter_end(void);
uint64_t meter_requests(void);
uint64_t meter_bytes(void);
uint64_t meter_max_request(void);
uint64_t meter_large_count(void);
uint64_t meter_large_size(uint64_t);
uint64_t meter_large_requests(uint64_t);

static pthread_barrier_t ready, finished;
static void *other_thread(void *argument) {
    (void)argument;
    pthread_barrier_wait(&ready);
    void *p = malloc(777);
    assert(p);
    free(p);
    pthread_barrier_wait(&finished);
    return NULL;
}

int main(void) {
    meter_begin();
    void *a = malloc(101), *b = calloc(3, 37);
    assert(a && b);
    a = realloc(a, 211);
    void *c = aligned_alloc(64, 256), *d = memalign(32, 123), *e = NULL;
    assert(a && c && d);
    assert(posix_memalign(&e, 64, 321) == 0 && e);
    assert((uintptr_t)c % 64 == 0 && (uintptr_t)d % 32 == 0 && (uintptr_t)e % 64 == 0);
    free(a); free(b); free(c); free(d); free(e);
    meter_end();
    assert(meter_requests() == 6 && meter_bytes() == 1123 && meter_max_request() == 321);
    const uint64_t sizes[] = {321, 256, 211, 123, 111, 101};
    assert(meter_large_count() == 6);
    for (uint64_t i = 0; i < 6; ++i) {
        assert(meter_large_size(i) == sizes[i] && meter_large_requests(i) == 1);
    }

    meter_begin();
    for (size_t i = 1; i <= 20; ++i) { void *p = malloc(i * 31); assert(p); free(p); }
    void *p = malloc(620); assert(p); free(p);
    meter_end();
    assert(meter_requests() == 21 && meter_bytes() == 7130 && meter_large_count() == 16);
    for (uint64_t i = 0; i < 16; ++i) {
        assert(meter_large_size(i) == (20 - i) * 31);
        assert(meter_large_requests(i) == (i == 0 ? 2 : 1));
    }
    assert(meter_large_size(16) == 0 && meter_large_requests(16) == 0);
    p = malloc(800); assert(p); free(p);
    assert(meter_requests() == 21);

    meter_begin();
    p = (void *)(uintptr_t)0x1234;
    errno = EDOM;
    assert(posix_memalign(&p, 3, 17) == EINVAL);
    assert(p == (void *)(uintptr_t)0x1234 && errno == EDOM);
    assert(aligned_alloc(3, 17) == NULL && errno == EINVAL);
    volatile size_t too_many = SIZE_MAX;
    assert(calloc(too_many, 2) == NULL);
    meter_end();
    assert(meter_requests() == 0 && meter_bytes() == 0);

    assert(pthread_barrier_init(&ready, NULL, 2) == 0);
    assert(pthread_barrier_init(&finished, NULL, 2) == 0);
    pthread_t worker;
    assert(pthread_create(&worker, NULL, other_thread, NULL) == 0);
    meter_begin();
    pthread_barrier_wait(&ready);
    pthread_barrier_wait(&finished);
    meter_end();
    assert(meter_requests() == 0);
    assert(pthread_join(worker, NULL) == 0);
    pthread_barrier_destroy(&ready);
    pthread_barrier_destroy(&finished);
    puts("Allocation meter calibration passed: six APIs, byte totals, histogram, failures, disabled window, thread isolation.");
    return 0;
}
