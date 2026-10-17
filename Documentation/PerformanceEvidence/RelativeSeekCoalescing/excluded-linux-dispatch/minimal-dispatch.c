#include <dispatch/dispatch.h>
#include <stdio.h>
#include <unistd.h>
static void slow_operation(void *context) {
    (void)context;
    usleep(20000);
}
int main(void) {
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    for (int i = 0; i < 64; i++) dispatch_group_async_f(group, queue, NULL, slow_operation);
    long result = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 2000000000));
    if (result) return 2;
    dispatch_release(group);
    puts("64 plain libdispatch tasks passed");
    return 0;
}
