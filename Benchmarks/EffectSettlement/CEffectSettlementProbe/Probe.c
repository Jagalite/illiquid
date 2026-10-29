#include "CEffectSettlementProbe.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <time.h>

static void (*begin_meter)(void);
static void (*end_meter)(void);
static uint64_t (*read_requests)(void);
static uint64_t (*read_bytes)(void);

uint64_t settlement_cpu_nanoseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000000000 + (uint64_t)value.tv_nsec;
}

/* Resolution occurs before warmup, fixture construction, or measured windows.
   The optional interposer is the repository's existing glibc allocation meter. */
int settlement_meter_available(void) {
    begin_meter = (void (*)(void))dlsym(RTLD_DEFAULT, "meter_begin");
    end_meter = (void (*)(void))dlsym(RTLD_DEFAULT, "meter_end");
    read_requests = (uint64_t (*)(void))dlsym(RTLD_DEFAULT, "meter_requests");
    read_bytes = (uint64_t (*)(void))dlsym(RTLD_DEFAULT, "meter_bytes");
    return begin_meter && end_meter && read_requests && read_bytes;
}
void settlement_meter_begin(void) { if (begin_meter) begin_meter(); }
void settlement_meter_end(void) { if (end_meter) end_meter(); }
uint64_t settlement_meter_requests(void) { return read_requests ? read_requests() : 0; }
uint64_t settlement_meter_bytes(void) { return read_bytes ? read_bytes() : 0; }

/* Prove that requests are actually intercepted, not merely that the meter's
   symbols exist. Indirect calls prevent an optimizer removing malloc/free.
   Free and all reporting occur after counting has stopped. */
int settlement_meter_self_check(void) {
    void *(*allocate)(size_t) = (void *(*)(size_t))dlsym(RTLD_DEFAULT, "malloc");
    void (*release)(void *) = (void (*)(void *))dlsym(RTLD_DEFAULT, "free");
    if (!allocate || !release || !begin_meter || !end_meter) return 0;
    settlement_meter_begin();
    void *block = allocate(12345);
    settlement_meter_end();
    int passed = block != NULL && settlement_meter_requests() >= 1
        && settlement_meter_bytes() >= 12345;
    if (block) release(block);
    return passed;
}
