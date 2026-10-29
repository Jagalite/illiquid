#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    void (*begin)(void) = dlsym(RTLD_DEFAULT, "illiquid_effect_probe_begin");
    void (*end)(void) = dlsym(RTLD_DEFAULT, "illiquid_effect_probe_end");
    uint64_t (*calls)(void) = dlsym(RTLD_DEFAULT, "illiquid_effect_probe_calls");
    uint64_t (*bytes)(void) = dlsym(RTLD_DEFAULT, "illiquid_effect_probe_bytes");
    if (!begin || !end || !calls || !bytes) return 2;

    begin();
    end();
    if (calls() != 0 || bytes() != 0) return 3;

    begin();
    volatile unsigned char *first = malloc(37);
    volatile unsigned char *second = calloc(3, 19);
    if (!first || !second) return 4;
    first[0] = 7;
    second[0] = 11;
    first = realloc((void *)first, 131);
    if (!first) return 5;
    if (first[0] != 7 || second[0] != 11) return 6;
    free((void *)second);
    end();
    uint64_t observed_calls = calls();
    uint64_t observed_bytes = bytes();
    free((void *)first);
    if (observed_calls != 3 || observed_bytes != 225) {
        fprintf(stderr, "Unexpected probe result: %llu calls, %llu bytes\n",
                (unsigned long long)observed_calls, (unsigned long long)observed_bytes);
        return 7;
    }
    puts("ALLOCATION_PROBE_PASS calls=3 requested_bytes=225");
    return 0;
}
