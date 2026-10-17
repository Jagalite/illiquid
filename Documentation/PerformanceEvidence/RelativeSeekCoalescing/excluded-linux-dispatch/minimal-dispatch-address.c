#define _GNU_SOURCE
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <unistd.h>
#include <signal.h>
#include <ucontext.h>
#include <dlfcn.h>
#include <stdint.h>
static void crash_address(int signal_number, siginfo_t *details, void *context) {
    (void)details;
    ucontext_t *state = context;
    uintptr_t pc = (uintptr_t)state->uc_mcontext.gregs[REG_RIP];
    Dl_info image = {0};
    dladdr((void *)pc, &image);
    char message[1024];
    int count = snprintf(message, sizeof(message),
        "signal=%d image=%s offset=0x%lx pc=0x%lx\n", signal_number,
        image.dli_fname ? image.dli_fname : "unknown",
        (unsigned long)(pc - (uintptr_t)image.dli_fbase), (unsigned long)pc);
    if (count > 0) write(STDERR_FILENO, message, (size_t)count);
    _exit(128 + signal_number);
}
static void slow_operation(void *context) {
    (void)context;
    usleep(20000);
}
int main(void) {
    struct sigaction observer = {0};
    observer.sa_sigaction = crash_address;
    observer.sa_flags = SA_SIGINFO;
    sigaction(SIGILL, &observer, NULL);
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    for (int i = 0; i < 64; i++) dispatch_group_async_f(group, queue, NULL, slow_operation);
    long result = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 2000000000));
    if (result) return 2;
    dispatch_release(group);
    puts("64 plain libdispatch tasks passed");
    return 0;
}
