import Darwin
import Foundation

struct AVSyncStabilityMetrics: Equatable, Sendable {
    private(set) var sampleCount = 0
    private(set) var firstDifference = 0.0
    private(set) var lastDifference = 0.0
    private(set) var maximumAbsoluteDifference = 0.0
    private var differences: [Double] = []

    mutating func record(audioPTS: Double, videoPTS: Double) {
        guard audioPTS.isFinite, videoPTS.isFinite, audioPTS > 0, videoPTS > 0 else {
            return
        }
        let difference = audioPTS - videoPTS
        if sampleCount == 0 { firstDifference = difference }
        sampleCount += 1
        lastDifference = difference
        maximumAbsoluteDifference = max(maximumAbsoluteDifference, abs(difference))
        differences.append(difference)
    }

    var drift: Double { lastDifference - firstDifference }

    func steadyStateDrift(
        windowSampleCount: Int = 240,
        edgeExclusionSampleCount: Int = 240
    ) -> Double {
        guard windowSampleCount > 0, differences.count >= 8 else { return drift }
        // Qualification samples every 250 ms. A 60-second run has only ~240
        // observations, so fixed 240+240 windows previously fell back to two
        // endpoint samples and contradicted the steady-state contract. Adapt
        // the same windowing rule to shorter runs without changing the bound.
        let window = min(windowSampleCount, max(1, differences.count / 4))
        let edge = min(edgeExclusionSampleCount, max(1, differences.count / 8))
        let leading = differences[
            edge..<(edge + window)
        ]
        let trailingEnd = differences.count - edge
        let trailing = differences[(trailingEnd - window)..<trailingEnd]
        return trailing.reduce(0, +) / Double(trailing.count)
            - leading.reduce(0, +) / Double(leading.count)
    }
}

enum ProcessResidentMemory {
    static func bytes() -> UInt64? {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }
}

enum ProcessHeapMemory {
    static func bytesInUse() -> UInt64 {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &statistics)
        return UInt64(statistics.size_in_use)
    }
}
