import Foundation
#if canImport(os)
import os.signpost
#endif

/// Opt-in measurements for an isolated benchmark bundle. Never records media paths.
public enum LifecyclePerformance {
    public static let isEnabled = Bundle.main.bundleIdentifier == "com.example.IlliquidBenchmark"
        && ProcessInfo.processInfo.environment["ILLIQUID_ENABLE_BENCHMARK_OVERRIDES"] == "1"
        && ProcessInfo.processInfo.environment["ILLIQUID_BENCHMARK_LIFECYCLE"] == "1"
    #if canImport(os)
    private static let log = OSLog(subsystem: "com.illiquid.performance", category: .pointsOfInterest)
    #endif

    public static func begin(_ phase: String) -> UInt64 {
        guard isEnabled else { return 0 }
        let start = DispatchTime.now().uptimeNanoseconds
        emit(phase + ".begin", at: start)
        return start
    }

    public static func end(_ phase: String, since start: UInt64) {
        guard isEnabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        emit(phase + ".end", at: now, duration: Double(now - start) / 1_000_000)
    }

    public static func mark(_ phase: String) {
        guard isEnabled else { return }
        emit(phase, at: DispatchTime.now().uptimeNanoseconds)
    }

    private static func emit(_ phase: String, at time: UInt64, duration: Double? = nil) {
        var line = "[lifecycle-performance] phase=\(phase) uptime_ns=\(time)"
        if let duration { line += " duration_ms=\(duration)" }
        #if canImport(os)
        os_signpost(.event, log: log, name: "Lifecycle", "%{public}s", phase)
        #endif
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
