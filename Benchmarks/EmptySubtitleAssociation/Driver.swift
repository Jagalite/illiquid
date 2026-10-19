import Dispatch
import Foundation
import IlliquidCore

#if os(Linux)
import Glibc
#else
import Darwin
#endif

// Link against a separately compiled optimized IlliquidCore module containing
// the exact production matcher and its dependencies. Timing includes the complete
// association call, result consumption, and result destruction. URL serialization,
// output sorting, independent empty-input checks, and preflight are outside it.
private enum PathStyle: Equatable, Sendable { case ascii, unicode, long }
private enum SubtitleForm: Sendable { case none, supported, unsupported }

private struct CaseSpec: Sendable {
    let name: String
    let size: Int
    let style: PathStyle
    let subtitles: SubtitleForm
}

private let cases: [CaseSpec] = [
    .init(name: "empty_0", size: 0, style: .ascii, subtitles: .none),
    .init(name: "empty_1", size: 1, style: .ascii, subtitles: .none),
    .init(name: "empty_16", size: 16, style: .ascii, subtitles: .none),
    .init(name: "empty_256", size: 256, style: .ascii, subtitles: .none),
    .init(name: "empty_4096", size: 4096, style: .ascii, subtitles: .none),
    .init(name: "empty_unicode_4096", size: 4096, style: .unicode, subtitles: .none),
    .init(name: "empty_long_4096", size: 4096, style: .long, subtitles: .none),
    .init(name: "supported_16", size: 16, style: .ascii, subtitles: .supported),
    .init(name: "supported_256", size: 256, style: .ascii, subtitles: .supported),
    .init(name: "unsupported_16", size: 16, style: .ascii, subtitles: .unsupported),
    .init(name: "unsupported_256", size: 256, style: .ascii, subtitles: .unsupported)
]

private struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct Options {
    var caseName = "empty_256"
    var iterations = 100
    var warmup = 4

    static let usage = """
    Usage: empty-subtitle-association --case NAME --iterations N [--warmup N]
           empty-subtitle-association --list-cases
           empty-subtitle-association --verify

    One iteration is one complete association call with a prepared fixture.
    --warmup defaults to 4; zero is allowed. --verify emits full associations
    for all cases and edge fixtures, with an independent oracle for empty inputs.
    The timed checksum consumes only result count and total subtitle count.
    """

    init(_ arguments: [String]) throws {
        guard arguments.count.isMultiple(of: 2) else {
            throw DriverError("Every option requires a value.")
        }
        var seen: Set<String> = []
        for offset in stride(from: 0, to: arguments.count, by: 2) {
            let option = arguments[offset], value = arguments[offset + 1]
            guard seen.insert(option).inserted else {
                throw DriverError("Duplicate option: \(option)")
            }
            switch option {
            case "--case": caseName = value
            case "--iterations":
                guard let parsed = Int(value), parsed > 0 else {
                    throw DriverError("--iterations must be positive.")
                }
                iterations = parsed
            case "--warmup":
                guard let parsed = Int(value), parsed >= 0 else {
                    throw DriverError("--warmup must be nonnegative.")
                }
                warmup = parsed
            default: throw DriverError("Unknown option: \(option)")
            }
        }
    }
}

private struct Fixture {
    let media: [URL]
    let subtitles: [URL]

    static func make(_ spec: CaseSpec) -> Self {
        var rootPath = "/tmp/illiquid-empty-subtitle-association"
        if spec.style == .long {
            rootPath += "/" + Array(repeating: "A long descriptive media directory 0123456789", count: 6)
                .joined(separator: "/")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let media = (0..<spec.size).map { index -> URL in
            let digits = String(index + 1)
            let number = String(repeating: "0", count: max(0, 6 - digits.count)) + digits
            let name: String
            switch spec.style {
            case .ascii:
                name = "Example.Series.Episode.\(number)"
            case .unicode:
                name = "Se\u{301}rie.Cafe\u{301}.東京.第\(number)話"
            case .long:
                name = "Example Series Episode \(number) "
                    + Array(repeating: "extended edition chapter", count: 6).joined(separator: " ")
            }
            return root.appendingPathComponent(name).appendingPathExtension("mkv")
        }
        let subtitles: [URL]
        switch spec.subtitles {
        case .none:
            subtitles = []
        case .supported:
            subtitles = media.map { $0.deletingPathExtension().appendingPathExtension("en.srt") }
        case .unsupported:
            subtitles = (0..<spec.size).map {
                root.appendingPathComponent("Notes \($0).txt")
            }
        }
        return Self(media: media, subtitles: subtitles)
    }
}

@inline(never)
private func associate(_ fixture: Fixture) -> [URL: [URL]] {
    ExternalSubtitleMatcher.associate(subtitleURLs: fixture.subtitles, with: fixture.media)
}

private struct Counts {
    let keys: Int
    let subtitles: Int

    init(_ result: [URL: [URL]]) {
        keys = result.count
        subtitles = result.values.reduce(0) { $0 + $1.count }
    }
}

private let initialChecksum: UInt64 = 14_695_981_039_346_656_037

@inline(__always)
private func consume(_ counts: Counts, checksum: inout UInt64) {
    checksum ^= UInt64(counts.keys)
    checksum &*= 1_099_511_628_211
    checksum ^= UInt64(counts.subtitles)
    checksum &*= 1_099_511_628_211
}

@inline(never)
private func run(_ fixture: Fixture, iterations: Int) -> UInt64 {
    var checksum = initialChecksum
    for _ in 0..<iterations {
        let result = associate(fixture)
        consume(Counts(result), checksum: &checksum)
    }
    return checksum
}

private func expectedChecksum(_ counts: Counts, iterations: Int) -> UInt64 {
    var checksum = initialChecksum
    for _ in 0..<iterations { consume(counts, checksum: &checksum) }
    return checksum
}

private func verifyEmptyOracle(_ result: [URL: [URL]], fixture: Fixture) throws {
    guard fixture.subtitles.isEmpty else { return }
    // The public contract initializes every original media URL as an empty
    // association, including unsupported media and duplicate input URLs. This
    // oracle does not call production tokenization, sorting, or normalization.
    let expectedKeys = Set(fixture.media)
    guard result.count == expectedKeys.count,
          result.allSatisfy({ expectedKeys.contains($0.key) && $0.value.isEmpty }) else {
        throw DriverError("Empty-subtitle result differs from the independent key-to-empty-array oracle.")
    }
}

private struct VerificationRecord: Codable {
    let caseName: String
    let mediaCount: Int
    let inputSubtitleCount: Int
    let associations: [String: [String]]
}

private struct Verification: Codable {
    let schemaVersion: Int
    let recordCount: Int
    let records: [VerificationRecord]
}

private func verificationRecord(name: String, fixture: Fixture) throws -> VerificationRecord {
    let result = associate(fixture)
    try verifyEmptyOracle(result, fixture: fixture)
    // Encoder.sortedKeys stabilizes dictionary order. Retain subtitle array
    // order exactly so baseline/candidate comparison also checks ordering.
    let associations = Dictionary(uniqueKeysWithValues: result.map {
        ($0.key.absoluteString, $0.value.map(\.absoluteString))
    })
    return VerificationRecord(caseName: name, mediaCount: fixture.media.count,
                              inputSubtitleCount: fixture.subtitles.count, associations: associations)
}

private func verification() throws -> Verification {
    var records = try cases.map { try verificationRecord(name: $0.name, fixture: .make($0)) }
    let small = Fixture.make(.init(name: "small", size: 2, style: .ascii, subtitles: .supported))
    records.append(try verificationRecord(name: "duplicate_media_empty",
        fixture: .init(media: [small.media[0], small.media[1], small.media[0]], subtitles: [])))
    records.append(try verificationRecord(name: "unsupported_media_empty", fixture: .init(media: [
        URL(string: "https://example.invalid/episode.mkv")!,
        URL(string: "file://remote.invalid/episode.mkv")!,
        URL(fileURLWithPath: "/tmp/notes.txt")
    ], subtitles: [])))
    records.append(try verificationRecord(name: "no_media_supported",
        fixture: .init(media: [], subtitles: small.subtitles)))
    records.append(try verificationRecord(name: "supported_unicode",
        fixture: .make(.init(name: "unicode", size: 4, style: .unicode, subtitles: .supported))))
    return Verification(schemaVersion: 1, recordCount: records.count, records: records)
}

private func processCPUTimeNanoseconds() throws -> UInt64 {
    var timestamp = timespec(tv_sec: 0, tv_nsec: 0)
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &timestamp) == 0 else {
        throw DriverError("Could not read process CPU clock (errno \(errno)).")
    }
    guard timestamp.tv_sec >= 0, timestamp.tv_nsec >= 0 else {
        throw DriverError("Process CPU clock returned a negative timestamp.")
    }
    return UInt64(timestamp.tv_sec) * 1_000_000_000 + UInt64(timestamp.tv_nsec)
}

private struct Measurement: Codable {
    let caseName: String
    let mediaCount: Int
    let inputSubtitleCount: Int
    let iterations: Int
    let warmupIterations: Int
    let count: Int
    let elapsedNs: UInt64
    let elapsedNanoseconds: UInt64
    let nsPerLookup: Double
    let cpuNs: UInt64
    let cpuNanoseconds: UInt64
    let cpuNsPerLookup: Double
    let checksum: UInt64
    let expectedChecksum: UInt64
    let preflightChecksum: UInt64
    let verifiedQueries: Int
}

private func writeJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([0x0A]))
}

@main
private struct EmptySubtitleAssociationBenchmark {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] || arguments == ["-h"] {
                print(Options.usage)
                return
            }
            if arguments == ["--list-cases"] {
                try writeJSON(cases.map(\.name))
                return
            }
            if arguments == ["--verify"] {
                try writeJSON(verification())
                return
            }
            let options = try Options(arguments)
            guard let spec = cases.first(where: { $0.name == options.caseName }) else {
                throw DriverError("Unknown case: \(options.caseName). Use --list-cases.")
            }
            let fixture = Fixture.make(spec)
            let preflight = associate(fixture)
            try verifyEmptyOracle(preflight, fixture: fixture)
            let counts = Counts(preflight)
            let expected = expectedChecksum(counts, iterations: options.iterations)
            let preflightHash = expectedChecksum(counts, iterations: 1)
            guard run(fixture, iterations: options.warmup)
                    == expectedChecksum(counts, iterations: options.warmup) else {
                throw DriverError("Warmup checksum differs from preflight.")
            }
            let cpuStarted = try processCPUTimeNanoseconds()
            let started = DispatchTime.now().uptimeNanoseconds
            let checksum = run(fixture, iterations: options.iterations)
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            let cpuElapsed = try processCPUTimeNanoseconds() - cpuStarted
            guard checksum == expected else {
                throw DriverError("Timed checksum differs from preflight.")
            }
            try writeJSON(Measurement(caseName: options.caseName,
                mediaCount: fixture.media.count, inputSubtitleCount: fixture.subtitles.count,
                iterations: options.iterations, warmupIterations: options.warmup,
                count: options.iterations, elapsedNs: elapsed, elapsedNanoseconds: elapsed,
                nsPerLookup: Double(elapsed) / Double(options.iterations),
                cpuNs: cpuElapsed, cpuNanoseconds: cpuElapsed,
                cpuNsPerLookup: Double(cpuElapsed) / Double(options.iterations),
                checksum: checksum, expectedChecksum: expected,
                preflightChecksum: preflightHash, verifiedQueries: 1))
        } catch {
            FileHandle.standardError.write(Data("empty-subtitle-association: \(error)\n".utf8))
            exit(1)
        }
    }
}
