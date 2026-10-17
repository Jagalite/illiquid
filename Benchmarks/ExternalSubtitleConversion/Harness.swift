import Foundation
@testable import ConverterModule
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The complete converter is compiled in a separate optimized module. No
// cross-module optimization is enabled. Input bytes are loaded at runtime.
@main
enum ConversionBenchmark {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count > 1 else { fatalError("Expected generate or measure") }
        switch args[1] {
        case "generate":
            guard args.count == 4, let seed = UInt64(args[3]) else {
                fatalError("generate OUTPUT_DIRECTORY SEED")
            }
            let directory = URL(fileURLWithPath: args[2], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var manifest: [[String: Any]] = []
            for spec in ConversionFixtures.specs {
                let data = Data(ConversionFixtures.source(spec, seed: seed).utf8)
                precondition(data.count < 32 * 1_024 * 1_024, "Fixture exceeds input limit")
                let filename = spec.name + ".txt"
                try data.write(to: directory.appendingPathComponent(filename))
                manifest.append([
                    "name": spec.name, "format": spec.format.rawValue,
                    "cues": spec.cues, "payload": spec.payload,
                    "newline": spec.newline, "path": filename,
                    "input_bytes": data.count, "seed": String(seed),
                ])
            }
            try ConversionReceipt.emit(["fixtures": manifest])
        case "measure":
            guard args.count == 6,
                  let format = FixtureFormat(rawValue: args[3]),
                  let iterations = Int(args[4]), iterations > 0,
                  let warmups = Int(args[5]), warmups >= 0 else {
                fatalError("measure FIXTURE_PATH FORMAT ITERATIONS WARMUPS")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
            let productionFormat: ExternalTextSubtitleConverter.Format = format == .srt ? .srt : .webVTT
            var expectedDigest: String?
            var outputBytes = 0
            func consume(_ output: String) {
                let digest = ConversionReceipt.digest(output.utf8)
                if let expectedDigest { precondition(digest == expectedDigest, "Repeated result changed") }
                else { expectedDigest = digest }
                outputBytes = output.utf8.count
                precondition(outputBytes <= 32 * 1_024 * 1_024, "Fixture output exceeds byte limit")
            }
            for _ in 0..<warmups {
                try scopedAutoreleasePool {
                    guard let source = String(data: data, encoding: .utf8) else { fatalError("Invalid UTF-8") }
                    consume(try ExternalTextSubtitleConverter.convert(source, format: productionFormat))
                    withExtendedLifetime(source) {}
                }
            }
            var observations: [UInt64] = []
            observations.reserveCapacity(iterations)
            for _ in 0..<iterations {
                try scopedAutoreleasePool {
                    // Production converts a newly decoded String once. Reuse
                    // fixture Data, but do not reuse a warmed String value or
                    // its representation/bridging/index caches across calls.
                    guard let source = String(data: data, encoding: .utf8) else { fatalError("Invalid UTF-8") }
                    let start = monotonicNanoseconds()
                    let output = try ExternalTextSubtitleConverter.convert(source, format: productionFormat)
                    let elapsed = monotonicNanoseconds() - start
                    // Hashing, byte counting, output destruction and macOS
                    // autorelease-pool draining all follow the conversion timer.
                    consume(output)
                    observations.append(elapsed)
                    withExtendedLifetime(source) {}
                }
            }
            let total = observations.reduce(UInt64(0), +)
            try ConversionReceipt.emit([
                "iterations": iterations, "warmups": warmups,
                "elapsed_ns": total, "conversion_ns": observations,
                "ns_per_conversion": Double(total) / Double(iterations),
                "input_bytes": data.count, "output_bytes": outputBytes,
                "output_fnv1a64": expectedDigest!, "format": format.rawValue,
                "timer": "clock_gettime(CLOCK_MONOTONIC)",
                "source_lifetime": "Fresh String decoded from preloaded Data before each conversion; decoding excluded; code/runtime warmed",
            ])
        default: fatalError("Unknown operation: \(args[1])")
        }
    }

    private static func monotonicNanoseconds() -> UInt64 {
        var value = timespec()
        precondition(clock_gettime(CLOCK_MONOTONIC, &value) == 0)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    private static func scopedAutoreleasePool<Result>(_ body: () throws -> Result) rethrows -> Result {
        #if canImport(ObjectiveC)
        return try autoreleasepool(invoking: body)
        #else
        return try body()
        #endif
    }
}
