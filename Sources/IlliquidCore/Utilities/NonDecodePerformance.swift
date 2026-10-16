import Foundation
#if canImport(os)
import os
#endif

/// Opt-in Instruments intervals for the player shell, never a per-frame log.
/// No media paths, strings derived from filenames, timers, or retained samples.
/// Capture resource baselines WITHOUT this opt-in to avoid observer effects.
public enum NonDecodePerformance {
    public static let isEnabled = Bundle.main.bundleIdentifier == "com.example.IlliquidBenchmark"
        && ProcessInfo.processInfo.environment["ILLIQUID_ENABLE_BENCHMARK_OVERRIDES"] == "1"
        && ProcessInfo.processInfo.environment["ILLIQUID_BENCHMARK_NONDECODE"] == "1"

    #if canImport(os)
    private static let signposter = OSSignposter(subsystem: "com.illiquid.performance", category: "NonDecode")
    #endif

    public struct Interval {
        #if canImport(os)
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
        #endif
    }

    public static func begin(_ name: StaticString) -> Interval? {
        guard isEnabled else { return nil }
        #if canImport(os)
        return Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()))
        #else
        return nil
        #endif
    }

    public static func end(_ interval: Interval?) {
        guard let interval else { return }
        #if canImport(os)
        signposter.endInterval(interval.name, interval.state)
        #else
        _ = interval
        #endif
    }

    /// A scoped synchronous interval; errors and early returns still close it.
    public static func measure<Result>(_ name: StaticString, _ operation: () throws -> Result) rethrows -> Result {
        let interval = begin(name)
        defer { end(interval) }
        return try operation()
    }

    public static func historyPayload(bytes: Int) {
        guard isEnabled else { return }
        #if canImport(os)
        signposter.emitEvent("HistoryPayload", "bytes=\(bytes, privacy: .public)")
        #endif
    }

    public static func residentMemory(bytes: Int, images: Int) {
        guard isEnabled else { return }
        #if canImport(os)
        signposter.emitEvent("ThumbnailResidentMemory", "bytes=\(bytes, privacy: .public) images=\(images, privacy: .public)")
        #endif
    }
}
