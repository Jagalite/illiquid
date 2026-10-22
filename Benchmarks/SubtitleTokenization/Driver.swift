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
// output sorting for verification, fixture-oracle checks, and preflight are outside it.
private enum PathStyle: Sendable { case ascii, unicode, longASCII, lateUnicode, mixed }
private enum SubtitleForm: Sendable { case none, single, languages, unsupported, unrelated, ambiguous }

private struct CaseSpec: Sendable {
    let name: String
    let size: Int
    let style: PathStyle
    let subtitles: SubtitleForm
}

private let cases: [CaseSpec] = [
    .init(name: "ascii_1", size: 1, style: .ascii, subtitles: .single),
    .init(name: "ascii_16", size: 16, style: .ascii, subtitles: .single),
    .init(name: "ascii_256", size: 256, style: .ascii, subtitles: .single),
    .init(name: "ascii_4096", size: 4096, style: .ascii, subtitles: .single),
    .init(name: "languages_16", size: 16, style: .ascii, subtitles: .languages),
    .init(name: "languages_256", size: 256, style: .ascii, subtitles: .languages),
    .init(name: "long_ascii_256", size: 256, style: .longASCII, subtitles: .single),
    .init(name: "unrelated_256", size: 256, style: .ascii, subtitles: .unrelated),
    .init(name: "ambiguous_256", size: 256, style: .ascii, subtitles: .ambiguous),
    .init(name: "empty_256", size: 256, style: .ascii, subtitles: .none),
    .init(name: "unsupported_256", size: 256, style: .ascii, subtitles: .unsupported),
    .init(name: "unicode_16", size: 16, style: .unicode, subtitles: .single),
    .init(name: "unicode_256", size: 256, style: .unicode, subtitles: .single),
    .init(name: "late_unicode_256", size: 256, style: .lateUnicode, subtitles: .single),
    .init(name: "mixed_256", size: 256, style: .mixed, subtitles: .single)
]

private struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct Options {
    var caseName = "ascii_256"
    var iterations = 100
    var warmup = 4

    static let usage = """
    Usage: subtitle-tokenization --case NAME --iterations N [--warmup N]
           subtitle-tokenization --list-cases
           subtitle-tokenization --verify

    One iteration is one complete association call with a prepared fixture.
    --warmup defaults to 4; zero is allowed. --verify emits full associations
    for all cases and edge fixtures, checked against independent fixture oracles.
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
    // The generated inventory defines associations directly. This oracle does
    // not call production matching, normalization, tokenization, or ordering.
    let expected: [URL: [URL]]

    static func make(_ spec: CaseSpec) -> Self {
        let root = URL(fileURLWithPath: "/tmp/illiquid-subtitle-tokenization", isDirectory: true)
        let stems = (0..<spec.size).map { index -> String in
            let digits = String(index + 1)
            let number = String(repeating: "0", count: max(0, 6 - digits.count)) + digits
            let ordinary = "Example.Series.Episode.\(number)"
            let extended = ordinary + "." + Array(repeating: "Extended.Edition.Chapter", count: 6)
                .joined(separator: ".")
            let unicode = "Se\u{301}rie.Cafe\u{301}.東京.第\(number)話"
            switch spec.style {
            case .ascii: return ordinary
            case .unicode: return unicode
            case .longASCII: return extended
            case .lateUnicode: return extended + ".Café"
            case .mixed: return index.isMultiple(of: 2) ? ordinary : unicode
            }
        }
        let media = stems.map { root.appendingPathComponent($0 + ".1080p.WEB-DL.x265.mkv") }
        var expected = Dictionary(uniqueKeysWithValues: media.map { ($0, [URL]()) })
        var subtitles: [URL] = []
        switch spec.subtitles {
        case .none:
            break
        case .single, .languages:
            // These known suffixes are already in natural filename order.
            // The input order is reversed to exercise the production sorting.
            let languages = spec.subtitles == .single ? ["en"] : ["en", "fr", "ja"]
            for (index, stem) in stems.enumerated() {
                let matches = languages.map { root.appendingPathComponent(stem + "." + $0 + ".srt") }
                expected[media[index]] = matches
                subtitles.append(contentsOf: matches)
            }
            subtitles.reverse()
        case .unsupported:
            subtitles = stems.map { root.appendingPathComponent($0 + ".en.txt") }
        case .unrelated:
            subtitles = (0..<spec.size).map { root.appendingPathComponent("Unrelated.Series.\($0).en.srt") }
        case .ambiguous:
            // Every media name has the same token count and this same prefix;
            // the generic subtitle must remain unassigned on an equal-score tie.
            subtitles = [root.appendingPathComponent("Example.Series.en.srt")]
        }
        return Self(media: media, subtitles: subtitles, expected: expected)
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

private func verifyOracle(_ result: [URL: [URL]], fixture: Fixture) throws {
    guard result == fixture.expected else {
        throw DriverError("Association output differs from the independent fixture oracle.")
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
    try verifyOracle(result, fixture: fixture)
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
    let root = URL(fileURLWithPath: "/tmp/illiquid-subtitle-tokenization-edges", isDirectory: true)
    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    func append(_ name: String, _ fixture: Fixture) throws {
        records.append(try verificationRecord(name: name, fixture: fixture))
    }

    let shorter = url("The Last of.mkv"), full = url("The Last of Us.1080p.mkv")
    let shortSubtitle = url("The Last of.srt"), fullSubtitle = url("THE.LAST.OF.US.eng.srt")
    try append("title_language_suffix", .init(media: [shorter, full], subtitles: [fullSubtitle, shortSubtitle],
        expected: [shorter: [shortSubtitle], full: [fullSubtitle]]))

    let hd = url("Movie.1080p.mkv"), uhd = url("Movie.2160p.mp4")
    let generic = url("Movie.en.srt"), specific = url("Movie.2160p.en.srt")
    try append("release_specific_and_ambiguous", .init(media: [hd, uhd], subtitles: [generic, specific],
        expected: [hd: [], uhd: [specific]]))

    let punctuated = url("Punctuation_A-B..Episode_001.mkv")
    let punctuationSubtitle = url("PUNCTUATION.a.b.episode.001.en.srt")
    try append("ascii_separators_and_case", .init(media: [punctuated], subtitles: [punctuationSubtitle],
        expected: [punctuated: [punctuationSubtitle]]))

    let movie = url("The Movie.mkv"), widthSubtitle = url("ＴＨＥ　ＭＯＶＩＥ.en.srt")
    try append("unicode_width_folding", .init(media: [movie], subtitles: [widthSubtitle],
        expected: [movie: [widthSubtitle]]))
    let cafe = url("Café.東京.mkv"), cafeSubtitle = url("CAFE\u{301}.東京.en.srt")
    try append("unicode_diacritic_folding", .init(media: [cafe], subtitles: [cafeSubtitle],
        expected: [cafe: [cafeSubtitle]]))

    let duplicateSubtitle = url("The Movie.en.srt"), unsupported = url("notes.txt")
    try append("duplicate_media_and_subtitle_inputs", .init(media: [movie, movie, unsupported],
        subtitles: [duplicateSubtitle, duplicateSubtitle],
        expected: [movie: [duplicateSubtitle, duplicateSubtitle], unsupported: []]))
    try append("no_media_supported_subtitles", .init(media: [], subtitles: [duplicateSubtitle], expected: [:]))
    try append("all_empty", .init(media: [], subtitles: [], expected: [:]))
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
    let localeIdentifier: String
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
private struct SubtitleTokenizationBenchmark {
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
            try verifyOracle(preflight, fixture: fixture)
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
            try writeJSON(Measurement(caseName: options.caseName, localeIdentifier: Locale.current.identifier,
                mediaCount: fixture.media.count, inputSubtitleCount: fixture.subtitles.count,
                iterations: options.iterations, warmupIterations: options.warmup,
                count: options.iterations, elapsedNs: elapsed, elapsedNanoseconds: elapsed,
                nsPerLookup: Double(elapsed) / Double(options.iterations),
                cpuNs: cpuElapsed, cpuNanoseconds: cpuElapsed,
                cpuNsPerLookup: Double(cpuElapsed) / Double(options.iterations),
                checksum: checksum, expectedChecksum: expected,
                preflightChecksum: preflightHash, verifiedQueries: 1))
        } catch {
            FileHandle.standardError.write(Data("subtitle-tokenization: \(error)\n".utf8))
            exit(1)
        }
    }
}
