import Dispatch
import Foundation
import IlliquidCore

#if os(Linux)
import Glibc
#else
import Darwin
#endif

// Exact production code is linked from a separately compiled optimized module.
// Timing includes complete association, count consumption, and result destruction.
// Fixture creation, independent full-result checking, serialization, and warmup
// are excluded. Nothing is subtracted from the measured interval.
private enum SubtitleForm: Equatable, Sendable {
    case oneToOne, paired, multilingual, sparse, unrelated, unsupported, none, broadPrefix
}

private struct CaseSpec: Sendable {
    let name: String
    let size: Int
    let subtitles: SubtitleForm
    var unicode = false
}

private let cases: [CaseSpec] = [
    .init(name: "one_to_one_1", size: 1, subtitles: .oneToOne),
    .init(name: "one_to_one_16", size: 16, subtitles: .oneToOne),
    .init(name: "one_to_one_256", size: 256, subtitles: .oneToOne),
    .init(name: "one_to_one_1024", size: 1024, subtitles: .oneToOne),
    .init(name: "two_subtitles_16", size: 16, subtitles: .paired),
    .init(name: "two_subtitles_256", size: 256, subtitles: .paired),
    .init(name: "multilingual_16", size: 16, subtitles: .multilingual),
    .init(name: "multilingual_256", size: 256, subtitles: .multilingual),
    .init(name: "sparse_1024", size: 1024, subtitles: .sparse),
    .init(name: "unrelated_1024", size: 1024, subtitles: .unrelated),
    .init(name: "unsupported_1024", size: 1024, subtitles: .unsupported),
    .init(name: "empty_0", size: 0, subtitles: .none),
    .init(name: "empty_16", size: 16, subtitles: .none),
    .init(name: "empty_1024", size: 1024, subtitles: .none),
    .init(name: "broad_prefix_256", size: 256, subtitles: .broadPrefix),
    .init(name: "broad_prefix_1024", size: 1024, subtitles: .broadPrefix),
    .init(name: "unicode_256", size: 256, subtitles: .oneToOne, unicode: true),
]

private struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct Options {
    var caseName = "one_to_one_256"
    var iterations = 100
    var warmup = 4

    static let usage = """
    Usage: subtitle-association --case NAME --iterations N [--warmup N]
           subtitle-association --list-cases
           subtitle-association --verify

    One iteration is one complete association call with prepared URLs.
    --warmup defaults to 4; zero is allowed. --verify checks independent expected
    assignments for every timed and edge fixture, then emits every exact media
    URL and ordered subtitle URL array for differential comparison.
    Timed consumption uses media-key count and total subtitle count only.
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

// Implement the public ordering contract directly. Expected associations never
// call the production matcher, tokenizer, or NaturalFilenameOrdering helper.
private func expectedOrder(_ urls: [URL]) -> [URL] {
    urls.sorted { lhs, rhs in
        switch lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame:
            return lhs.path.compare(rhs.path, options: [.literal]) == .orderedAscending
        }
    }
}

private struct Fixture {
    let media: [URL]
    let subtitles: [URL]
    let expected: [URL: [URL]]

    init(media: [URL], subtitles: [URL], assignments: [(URL, [URL])] = []) {
        self.media = media
        self.subtitles = subtitles
        var expected: [URL: [URL]] = [:]
        for url in media { expected[url] = [] }
        for (url, matches) in assignments {
            precondition(expected[url] != nil, "Oracle assignment has no input media key")
            expected[url] = expectedOrder(matches)
        }
        self.expected = expected
    }

    private init(media: [URL], subtitles: [URL], expected: [URL: [URL]]) {
        self.media = media
        self.subtitles = subtitles
        self.expected = expected
    }

    var reversed: Self {
        .init(media: Array(media.reversed()), subtitles: Array(subtitles.reversed()), expected: expected)
    }

    static func make(_ spec: CaseSpec) -> Self {
        let root = URL(fileURLWithPath: "/tmp/illiquid-subtitle-association", isDirectory: true)
        let stems = (0..<spec.size).map { index -> String in
            let digits = String(index + 1)
            let number = String(repeating: "0", count: max(0, 6 - digits.count)) + digits
            return spec.unicode ? "Se\u{301}rie.Cafe\u{301}.東京.第\(number)話"
                : "Example.Series.Episode.\(number)"
        }
        let media = stems.map { root.appendingPathComponent($0 + ".1080p.mkv") }
        var subtitles: [URL] = []
        var assignments: [(URL, [URL])] = []
        switch spec.subtitles {
        case .oneToOne, .paired, .multilingual, .sparse:
            // Deliberately unsorted variants ensure the multilingual cases sort.
            let variants = spec.subtitles == .multilingual
                ? ["ja.srt", "en.forced.ass", "fr.srt", "en.srt", "de.srt", "es.srt"]
                : spec.subtitles == .paired ? ["en.srt", "en.forced.ass"] : ["en.srt"]
            for index in stems.indices {
                if spec.subtitles == .sparse && index % 128 != 0 { continue }
                let matches = variants.map { root.appendingPathComponent(stems[index] + "." + $0) }
                subtitles.append(contentsOf: matches)
                assignments.append((media[index], matches))
            }
        case .unrelated:
            subtitles = (0..<spec.size).map { root.appendingPathComponent("Unrelated.\($0).en.srt") }
        case .unsupported:
            subtitles = stems.map { root.appendingPathComponent($0 + ".txt") }
        case .none:
            break
        case .broadPrefix:
            // Every generic subtitle has equally ranked descendants, so none is
            // assigned. Fixed-width episode numbers keep all weights equal.
            precondition(spec.size > 1 && !spec.unicode)
            subtitles = ["en.srt", "eng.srt", "ja.ass", "fr.srt", "de.srt", "es.srt", "en.forced.ass", "en.sdh.vtt"]
                .map { root.appendingPathComponent("Example.Series." + $0) }
        }
        return .init(media: media, subtitles: subtitles, assignments: assignments)
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
        throw DriverError("Full association differs from independently constructed expected assignments.")
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
    do { try verifyOracle(result, fixture: fixture) }
    catch { throw DriverError("\(name): \(error)") }
    // Preserve array order and duplicate subtitle URLs; sorted JSON object keys
    // only remove irrelevant dictionary iteration order from differential output.
    let associations = Dictionary(uniqueKeysWithValues: result.map {
        ($0.key.absoluteString, $0.value.map(\.absoluteString))
    })
    return VerificationRecord(caseName: name, mediaCount: fixture.media.count,
                              inputSubtitleCount: fixture.subtitles.count, associations: associations)
}

private func edgeFixtures() -> [(String, Fixture)] {
    let root = URL(fileURLWithPath: "/tmp/illiquid-subtitle-association-edges", isDirectory: true)
    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    let movie = url("Movie.mkv")
    let english = url("Movie.en.srt"), forced = url("Movie.forced.ass")
    let low = url("Movie.1080p.mkv"), high = url("Movie.2160p.mp4")
    let release = url("Movie.2160p.en.srt")
    let shortTitle = url("The Last of.mkv"), fullTitle = url("The Last of Us.1080p.mkv")
    let shortSub = url("The Last of.srt"), fullSub = url("The Last of Us.en.srt")
    let show = url("Show.mkv"), showMKV = url("Show Episode 1.mkv"), showMP4 = url("Show Episode 1.mp4")
    let showSub = url("Show.srt")
    let unicode = url("Café 東京.mkv"), unicodeRoman = url("Café 東京 I.1080p.mkv")
    let unicodeSub = url("ｃａｆｅ.東京.en.srt"), unicodeRomanSub = url("CAFE\u{301}.東京.I.en.forced.srt")
    let shortPrefix = url("ABC Chapter.mkv"), longPrefix = url("ABCD Chapter.mkv")
    let shortPrefixSub = url("ABC.srt"), longPrefixSub = url("ABCD.srt")
    let two = url("Movie 2.en.srt"), ten = url("Movie 10.en.srt")
    let tieA = url("a/Movie.en.srt"), tieB = url("b/Movie.en.srt")
    return [
        ("duplicate_inputs", .init(media: [movie, movie, url("notes.txt")],
            subtitles: [english, forced, english, url("Movie.sup")], assignments: [(movie, [english, forced, english])])),
        ("ambiguous_encodes", .init(media: [low, high], subtitles: [english, release], assignments: [(high, [release])])),
        ("qualifier_title", .init(media: [shortTitle, fullTitle], subtitles: [fullSub, shortSub],
            assignments: [(shortTitle, [shortSub]), (fullTitle, [fullSub])])),
        ("exact_beats_fuzzy_tie", .init(media: [showMKV, showMP4, show],
            subtitles: [url("Show Episode 1.en.srt"), showSub], assignments: [(show, [showSub])])),
        ("unicode_specificity", .init(media: [url("Cafe.mkv"), unicode, unicodeRoman], subtitles: [unicodeRomanSub, unicodeSub],
            assignments: [(unicode, [unicodeSub]), (unicodeRoman, [unicodeRomanSub])])),
        ("fuzzy_weight_threshold", .init(media: [shortPrefix, longPrefix], subtitles: [shortPrefixSub, longPrefixSub],
            assignments: [(longPrefix, [longPrefixSub])])),
        ("subtitle_order", .init(media: [movie], subtitles: [ten, tieB, two, tieA], assignments: [(movie, [tieA, tieB, two, ten])])),
        ("unsupported_keys", .init(media: [url("notes.txt"), url("README"), URL(string: "https://example.invalid/Movie.mkv")!],
            subtitles: [english])),
        ("no_media", .init(media: [], subtitles: [english, forced])),
    ]
}

private func verification() throws -> Verification {
    let fixtures = cases.map { ($0.name, Fixture.make($0)) } + edgeFixtures()
    var records: [VerificationRecord] = []
    for (name, fixture) in fixtures {
        records.append(try verificationRecord(name: name, fixture: fixture))
        records.append(try verificationRecord(name: name + "_reversed", fixture: fixture.reversed))
    }
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
private struct SubtitleAssociationBenchmark {
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
            FileHandle.standardError.write(Data("subtitle-association: \(error)\n".utf8))
            exit(1)
        }
    }
}
