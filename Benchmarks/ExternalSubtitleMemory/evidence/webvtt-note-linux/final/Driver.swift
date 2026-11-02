import Foundation
@testable import IlliquidNativePlayback
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func usage() -> rusage {
    var value = rusage()
    #if canImport(Darwin)
    let result = getrusage(RUSAGE_SELF, &value)
    #else
    let result = getrusage(Int32(RUSAGE_SELF.rawValue), &value)
    #endif
    precondition(result == 0)
    return value
}

private func cpuNanoseconds(_ value: rusage) -> Int64 {
    Int64(value.ru_utime.tv_sec + value.ru_stime.tv_sec) * 1_000_000_000
        + Int64(value.ru_utime.tv_usec + value.ru_stime.tv_usec) * 1_000
}

private func peakRSSBytes(_ value: rusage) -> Int64 {
    #if canImport(Darwin)
    Int64(value.ru_maxrss)
    #else
    Int64(value.ru_maxrss) * 1_024
    #endif
}

private func wallNanoseconds() -> Int64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_MONOTONIC, &value) == 0)
    return Int64(value.tv_sec) * 1_000_000_000 + Int64(value.tv_nsec)
}

private struct Measurement: Encodable {
    let elapsed_ns: Int64
    let cpu_ns: Int64
    let peak_rss_bytes: Int64
    let preconversion_peak_rss_bytes: Int64
    let input_bytes: Int
    let output_bytes: Int?
    let error: String?
}

@main
enum Driver {
    static func main() throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count == 4, "Usage: driver srt|vtt INPUT OUTPUT")
        precondition(arguments[1] == "srt" || arguments[1] == "vtt")
        let format: ExternalTextSubtitleConverter.Format = arguments[1] == "srt" ? .srt : .webVTT
        // Fixture generation and loading are outside conversion timing. Process
        // peak RSS still includes the executable, Foundation, and loading.
        let source = try String(contentsOfFile: arguments[2], encoding: .utf8)
        let inputBytes = source.utf8.count
        var output: String?
        var conversionError: ExternalTextSubtitleConverter.ConversionError?
        let before = usage()
        let started = wallNanoseconds()
        do {
            output = try ExternalTextSubtitleConverter.convert(source, format: format)
        } catch let error as ExternalTextSubtitleConverter.ConversionError {
            conversionError = error
        }
        let elapsed = wallNanoseconds() - started
        // Capture before output encoding, file writing, hashing, or JSON work.
        let after = usage()
        let error: String?
        switch conversionError {
        case nil: error = nil
        case .missingWebVTTSignature: error = "missingWebVTTSignature"
        case .noValidCues(.srt): error = "noValidCues(srt)"
        case .noValidCues(.webVTT): error = "noValidCues(webVTT)"
        }
        let measurement = Measurement(
            elapsed_ns: elapsed, cpu_ns: cpuNanoseconds(after) - cpuNanoseconds(before),
            peak_rss_bytes: peakRSSBytes(after), preconversion_peak_rss_bytes: peakRSSBytes(before),
            input_bytes: inputBytes,
            output_bytes: output?.utf8.count, error: error
        )
        if let output { try Data(output.utf8).write(to: URL(fileURLWithPath: arguments[3])) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(measurement))
        FileHandle.standardOutput.write(Data([0x0a]))
        withExtendedLifetime(source) {}
    }
}
