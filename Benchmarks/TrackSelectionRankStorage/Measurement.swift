import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif
#if TRACK_RANK_ALLOCATIONS
import CCompletionHeap
#endif

// Only the driver is instrumented. The production selection module is compiled
// identically for timing and allocation runs and cannot see these helpers.
private struct TrackRankMeasurement {
    struct Start {
        let wall: UInt64
        let cpu: UInt64
    }

    let elapsedNanoseconds: UInt64
    let cpuNanoseconds: UInt64
    let allocationRequests: UInt64
    let requestedBytes: UInt64

    static var instrumentsAllocations: Bool {
        #if TRACK_RANK_ALLOCATIONS
        true
        #else
        false
        #endif
    }

    static func start() -> Start {
        let cpu = processCPUTime()
        let wall = DispatchTime.now().uptimeNanoseconds
        #if TRACK_RANK_ALLOCATIONS
        precondition(completion_allocation_meter_available() == 1)
        completion_meter_begin()
        #endif
        return Start(wall: wall, cpu: cpu)
    }

    static func finish(_ start: Start) -> Self {
        #if TRACK_RANK_ALLOCATIONS
        completion_meter_end()
        #endif
        let wall = DispatchTime.now().uptimeNanoseconds
        let cpu = processCPUTime()
        #if TRACK_RANK_ALLOCATIONS
        let requests = completion_allocation_requests()
        let bytes = completion_requested_bytes()
        #else
        let requests: UInt64 = 0
        let bytes: UInt64 = 0
        #endif
        return Self(elapsedNanoseconds: wall - start.wall,
                    cpuNanoseconds: cpu - start.cpu,
                    allocationRequests: requests, requestedBytes: bytes)
    }

    private static func processCPUTime() -> UInt64 {
        var value = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }
}
