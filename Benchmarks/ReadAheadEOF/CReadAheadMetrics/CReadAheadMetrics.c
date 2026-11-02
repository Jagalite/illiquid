#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include "CReadAheadMetrics.h"
#include <errno.h>
#include <sys/resource.h>
#include <time.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#endif

#define NS_PER_SECOND INT64_C(1000000000)

static ReadAheadMetrics failed_metrics(int64_t error)
{
    ReadAheadMetrics result = {0};
    result.error_code = error != 0 ? error : EIO;
    return result;
}

static int checked_nanoseconds(int64_t seconds, int64_t nanos, int64_t *result)
{
    if (seconds < 0 || nanos < 0 || nanos >= NS_PER_SECOND) return EINVAL;
    if (seconds > (INT64_MAX - nanos) / NS_PER_SECOND) return EOVERFLOW;
    *result = seconds * NS_PER_SECOND + nanos;
    return 0;
}

static int cpu_nanoseconds(
    int64_t user_seconds, int64_t user_micros,
    int64_t system_seconds, int64_t system_micros, int64_t *result
)
{
    if (user_micros < 0 || user_micros >= 1000000
        || system_micros < 0 || system_micros >= 1000000) return EINVAL;
    int64_t user = 0, system = 0;
    int error = checked_nanoseconds(user_seconds, user_micros * 1000, &user);
    if (error != 0) return error;
    error = checked_nanoseconds(system_seconds, system_micros * 1000, &system);
    if (error != 0) return error;
    if (user > INT64_MAX - system) return EOVERFLOW;
    *result = user + system;
    return 0;
}

ReadAheadMetrics read_ahead_thread_metrics(void)
{
    ReadAheadMetrics result = {0};
#if defined(__linux__)
    struct rusage usage;
    if (getrusage(RUSAGE_THREAD, &usage) != 0) return failed_metrics(errno);
    struct timespec cpu;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpu) != 0) return failed_metrics(errno);
    int error = checked_nanoseconds(cpu.tv_sec, cpu.tv_nsec, &result.cpu_nanoseconds);
    if (error != 0) return failed_metrics(error);
    result.voluntary_switches = usage.ru_nvcsw;
    result.involuntary_switches = usage.ru_nivcsw;
    result.switches_available = 1;
#elif defined(__APPLE__)
    thread_basic_info_data_t info = {0};
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    mach_port_t thread = mach_thread_self();
    if (thread == MACH_PORT_NULL) return failed_metrics(KERN_FAILURE);
    kern_return_t query = thread_info(
        thread, THREAD_BASIC_INFO, (thread_info_t)&info, &count
    );
    kern_return_t release = mach_port_deallocate(mach_task_self(), thread);
    if (query != KERN_SUCCESS) return failed_metrics(query);
    if (release != KERN_SUCCESS) return failed_metrics(release);
    if (count < THREAD_BASIC_INFO_COUNT) return failed_metrics(EIO);
    int error = cpu_nanoseconds(
        info.user_time.seconds, info.user_time.microseconds,
        info.system_time.seconds, info.system_time.microseconds,
        &result.cpu_nanoseconds
    );
    if (error != 0) return failed_metrics(error);
    /* THREAD_BASIC_INFO provides CPU time, not context-switch counts. */
    result.switches_available = 0;
#else
    return failed_metrics(ENOTSUP);
#endif
    return result;
}

ReadAheadMetrics read_ahead_process_metrics(void)
{
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) return failed_metrics(errno);
    ReadAheadMetrics result = {0};
    int error = cpu_nanoseconds(
        usage.ru_utime.tv_sec, usage.ru_utime.tv_usec,
        usage.ru_stime.tv_sec, usage.ru_stime.tv_usec,
        &result.cpu_nanoseconds
    );
    if (error != 0) return failed_metrics(error);
    result.voluntary_switches = usage.ru_nvcsw;
    result.involuntary_switches = usage.ru_nivcsw;
    result.switches_available = 1;
    return result;
}

int64_t read_ahead_monotonic_nanoseconds(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -(int64_t)(errno ? errno : EIO);
    int64_t result = 0;
    int error = checked_nanoseconds(now.tv_sec, now.tv_nsec, &result);
    return error != 0 ? -(int64_t)error : result;
}

int64_t read_ahead_sleep_until(int64_t deadline)
{
    if (deadline < 0) return -(int64_t)EINVAL;
    for (;;) {
        int64_t now = read_ahead_monotonic_nanoseconds();
        if (now < 0) return now;
        if (now >= deadline) return 0;
        int64_t remaining = deadline - now;
        int64_t seconds = remaining / NS_PER_SECOND;
        struct timespec request = {
            .tv_sec = (time_t)seconds,
            .tv_nsec = (long)(remaining % NS_PER_SECOND)
        };
        if ((int64_t)request.tv_sec != seconds) return -(int64_t)EOVERFLOW;
        if (nanosleep(&request, NULL) != 0 && errno != EINTR) {
            return -(int64_t)(errno ? errno : EIO);
        }
    }
}
