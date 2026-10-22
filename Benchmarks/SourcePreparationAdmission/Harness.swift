import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

// This file is compiled with the complete production executor, separately for
// the pinned baseline and candidate. It contains no alternate scheduler.
private struct Configuration {
    let name: String
    let count: Int
    let bursts: Int
    let sleepMicroseconds: Int
    let directoryWork: Bool
    let interactive: Bool

    static let cases: [Configuration] = [
        .init(name: "interactive-single", count: 1, bursts: 2_048,
              sleepMicroseconds: 0, directoryWork: false, interactive: true),
        .init(name: "background-single", count: 1, bursts: 2_048,
              sleepMicroseconds: 0, directoryWork: false, interactive: false),
        .init(name: "burst-8-empty", count: 8, bursts: 256,
              sleepMicroseconds: 0, directoryWork: false, interactive: false),
        .init(name: "burst-32-empty", count: 32, bursts: 64,
              sleepMicroseconds: 0, directoryWork: false, interactive: false),
        .init(name: "burst-64-empty", count: 64, bursts: 32,
              sleepMicroseconds: 0, directoryWork: false, interactive: false),
        .init(name: "burst-8-100us", count: 8, bursts: 64,
              sleepMicroseconds: 100, directoryWork: false, interactive: false),
        .init(name: "burst-32-100us", count: 32, bursts: 16,
              sleepMicroseconds: 100, directoryWork: false, interactive: false),
        .init(name: "burst-64-100us", count: 64, bursts: 8,
              sleepMicroseconds: 100, directoryWork: false, interactive: false),
        .init(name: "burst-32-1ms", count: 32, bursts: 4,
              sleepMicroseconds: 1_000, directoryWork: false, interactive: false),
        .init(name: "burst-64-1ms", count: 64, bursts: 2,
              sleepMicroseconds: 1_000, directoryWork: false, interactive: false),
        .init(name: "burst-32-directory", count: 32, bursts: 16,
              sleepMicroseconds: 0, directoryWork: true, interactive: false),
        .init(name: "burst-64-directory", count: 64, bursts: 8,
              sleepMicroseconds: 0, directoryWork: true, interactive: false),
    ]
}

private struct WorkResult: Sendable {
    let index: Int
    let entries: Int
}

private struct Measurement: Codable {
    let scenario: String
    let requestsPerBurst: Int
    let bursts: Int
    let completedRequests: Int
    let checksum: UInt64
    let wallNanoseconds: UInt64
    let processCPUNanoseconds: UInt64
}

private func processCPUNanoseconds() -> UInt64 {
    var usage = rusage()
    #if os(Linux)
    let status = getrusage(Int32(RUSAGE_SELF.rawValue), &usage)
    #else
    let status = getrusage(RUSAGE_SELF, &usage)
    #endif
    precondition(status == 0)
    let microseconds = Int64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000
        + Int64(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)
    return UInt64(microseconds) * 1_000
}

private func runBurst(
    _ configuration: Configuration,
    executor: SourcePreparationExecutor,
    fixture: URL
) async throws -> UInt64 {
    let operation: @Sendable (Int, @Sendable () throws -> Void) throws -> WorkResult = { index, check in
        try check()
        if configuration.sleepMicroseconds > 0 {
            // A controlled stand-in for short blocking reads. Actual directory
            // enumeration is measured in separate scenarios below.
            Thread.sleep(forTimeInterval: Double(configuration.sleepMicroseconds) / 1_000_000)
        }
        let entries: Int
        if configuration.directoryWork {
            let directory = fixture.appendingPathComponent("directory-\(index)", isDirectory: true)
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            ).reduce(0) { count, url in
                try count + (url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true ? 1 : 0)
            }
        } else {
            entries = 0
        }
        try check()
        return WorkResult(index: index, entries: entries)
    }
    if configuration.interactive {
        let result = try await executor.perform { check in try operation(0, check) }
        precondition(result.index == 0 && result.entries == 0)
        precondition(executor.activeCount == 0)
        return 1
    }
    let checksum = try await withThrowingTaskGroup(of: WorkResult.self) { group in
        for index in 0..<configuration.count {
            group.addTask {
                try await executor.performWhenAvailable { check in try operation(index, check) }
            }
        }
        var seen: UInt64 = 0
        var checksum: UInt64 = 0
        var completed = 0
        for try await result in group {
            precondition((0..<configuration.count).contains(result.index))
            let bit = UInt64(1) << result.index
            precondition(seen & bit == 0, "Duplicate job result")
            seen |= bit
            precondition(result.entries == (configuration.directoryWork ? 16 : 0))
            checksum &+= UInt64(result.index + 1 + result.entries)
            completed += 1
        }
        precondition(completed == configuration.count)
        return checksum
    }
    precondition(executor.activeCount == 0)
    return checksum
}

@main
private struct Main {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3,
              let configuration = Configuration.cases.first(where: { $0.name == arguments[1] }) else {
            fatalError("Usage: benchmark SCENARIO FIXTURE_DIRECTORY")
        }
        let fixture = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let executor = SourcePreparationExecutor(capacity: 2, timeout: 12)
        // Start the concurrency and dispatch pools and warm filesystem caches.
        // Warm-up is identical for both binaries and excluded from measurement.
        for _ in 0..<3 {
            _ = try await runBurst(configuration, executor: executor, fixture: fixture)
        }
        let cpuStart = processCPUNanoseconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        var checksum: UInt64 = 0
        for _ in 0..<configuration.bursts {
            checksum &+= try await runBurst(configuration, executor: executor, fixture: fixture)
        }
        let wallElapsed = DispatchTime.now().uptimeNanoseconds - wallStart
        let cpuElapsed = processCPUNanoseconds() - cpuStart
        let measurement = Measurement(
            scenario: configuration.name,
            requestsPerBurst: configuration.count,
            bursts: configuration.bursts,
            completedRequests: configuration.count * configuration.bursts,
            checksum: checksum,
            wallNanoseconds: wallElapsed,
            processCPUNanoseconds: cpuElapsed
        )
        let data = try JSONEncoder().encode(measurement)
        print(String(decoding: data, as: UTF8.self))
    }
}
