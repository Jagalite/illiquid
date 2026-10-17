#include <time.h>
#include <stdio.h>
#include <stdint.h>
int main(void) {
    struct timespec t;
    uint64_t last = 0;
    for (int i = 0; i < 100000; i++) {
        if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t)) return 2;
        uint64_t now = (uint64_t)t.tv_sec * 1000000000ULL + t.tv_nsec;
        if (now < last) return 3;
        last = now;
    }
    puts("100000 process CPU-clock reads passed");
    return 0;
}
