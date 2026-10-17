import Dispatch
import Foundation
import IlliquidCore

#if os(Linux)
import Glibc
#else
import Darwin
#endif

// Compile and link against a separate optimized IlliquidCore module containing
// the exact production MediaNameRecognition.swift. The timed loop includes
// recognition and an FNV hash of every stored result field. It excludes fixture
// generation, preflight, computed display-field formatting, and JSON encoding.
private let caseNames = [
    "folder_only_year", "folder_only_yearless", "specials", "named_under_year",
    "different_prefix", "direct_year_parent", "direct_yearless_parent",
    "movie", "dated_episode", "unknown", "unicode_folder_only", "mixed"
]

private struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct Options {
    var caseName = "mixed"
    var iterations = 100
    var warmup = 4
    var verify = false

    static let usage = """
    Usage: media-name-recognition-reuse --case NAME --iterations N [--warmup N]
           media-name-recognition-reuse --verify
           media-name-recognition-reuse --list-cases

    Each case uses a deterministic batch of 16 paths. One iteration performs
    one complete recognition call and hashes all stored result fields.
    --warmup defaults to 4; zero is allowed. --verify emits complete result
    records for all case batches and a broader edge corpus, without timing.
    """

    init(_ arguments: [String]) throws {
        var offset = 0
        var seen: Set<String> = []
        while offset < arguments.count {
            let option = arguments[offset]
            guard seen.insert(option).inserted else {
                throw DriverError("Duplicate option: \(option)")
            }
            if option == "--verify" {
                verify = true
                offset += 1
                continue
            }
            guard offset + 1 < arguments.count else {
                throw DriverError("Missing value for \(option).")
            }
            let value = arguments[offset + 1]
            switch option {
            case "--case":
                caseName = value
            case "--iterations":
                guard let parsed = Int(value), parsed > 0 else {
                    throw DriverError("--iterations must be a positive integer.")
                }
                iterations = parsed
            case "--warmup":
                guard let parsed = Int(value), parsed >= 0 else {
                    throw DriverError("--warmup must be a nonnegative integer.")
                }
                warmup = parsed
            default:
                throw DriverError("Unknown option: \(option).")
            }
            offset += 2
        }
        guard caseNames.contains(caseName) else {
            throw DriverError("Unknown case: \(caseName). Use --list-cases.")
        }
    }
}

private enum Fixtures {
    static func paths(for caseName: String) -> [String] {
        (0..<16).map { path(caseName: caseName, offset: $0) }
    }

    private static func path(caseName: String, offset: Int) -> String {
        let episode = String(format: "%02d", offset + 1)
        switch caseName {
        case "folder_only_year":
            return "The Example (2020)/Season 1/S01E\(episode) - Chapter \(offset + 1).mkv"
        case "folder_only_yearless":
            return "The Example/Season 1/S01E\(episode) - Chapter \(offset + 1).mkv"
        case "specials":
            return "The Example (2020)/Specials/S00E\(episode) - Bonus \(offset + 1).mkv"
        case "named_under_year":
            return "The Example (2020)/Season 1/The.Example.S01E\(episode).Chapter.\(offset + 1).1080p.mkv"
        case "different_prefix":
            return "The Example (2020)/Season 1/Another.Series.S02E\(episode).1080p.mkv"
        case "direct_year_parent":
            return "The Example (2020)/S01E\(episode) - Chapter \(offset + 1).mkv"
        case "direct_yearless_parent":
            return "The Example/S01E\(episode).mkv"
        case "movie":
            let year = 1990 + offset
            return "Movies/Movie \(offset + 1) (\(year))/Movie \(offset + 1) (\(year)).1080p.mkv"
        case "dated_episode":
            return "Daily Show/Daily.Show.2024.02.\(episode).Broadcast.mkv"
        case "unknown":
            return "Personal recordings/camera_clip_\(String(format: "%04d", offset + 1)).mkv"
        case "unicode_folder_only":
            let series = offset.isMultiple(of: 2) ? "Série Café 東京" : "Se\u{301}rie Cafe\u{301} 東京"
            return "\(series) (2021)/Season 2/S02E\(episode) - Été à Kyoto 🎬.mkv"
        case "mixed":
            let baseCases = caseNames.dropLast()
            return path(caseName: baseCases[(offset * 7) % baseCases.count], offset: offset)
        default:
            preconditionFailure("Options validation must reject unknown cases.")
        }
    }

    static let edges: [String] = [
        "", "/", "video.mkv", "S01E01.mkv", "Series/Season 1/S01E01.mkv",
        "Series (2020)/Season.1/S01E01.mkv",
        "Series (2020)/Season_1/S01E01.mkv",
        "Series (2020)/Season-1/1x02.mkv",
        "Series (2020)/SEASON 1/s01e03.mkv",
        "Series (2020)/Specials/S00E01.mkv",
        "Series (2020)/specials/Series.S00E02.extra.mkv",
        "Series (2020)/Season 1/Series (1990).S01E01.mkv",
        "Series (2020)/Season 1/Different (1990).S01E01.mkv",
        "Series (2020)/Season 1/Different.S01E01.mkv",
        "Series (2020)/Season 1/S01E02E04 - Two Chapters.mkv",
        "Series (2020)/Season 1/S01E04E02.mkv",
        "Series (2020)/Season 1/S123E1234.mkv",
        "Series (2020)/Season 1/S1234E12345.mkv",
        "Series (2020)/Season 1/Series.s01.e01.mkv",
        "Series (2020)/Season 1/S٠١E٠٢.mkv",
        "Series (2020)/Season 1/S０１E０２.mkv",
        "Series {tvdb-12345} (2020)/Season 1/S01E01.mkv",
        "Series {tmdb-12345} (2020)/Season 1/S01E01 {edition-Extended}.mkv",
        "Series [remaster] (2020)/Season 1/[group] S01E01 [1080p].mkv",
        "Series {edition-2021} (2020)/Season 1/S01E01.mkv",
        "Series (2020) (2021)/Season 1/S01E01.mkv",
        "Series (2020)/Season 1/S01E01 {malformed.mkv",
        "Series {outer{inner}} (2020)/Season 1/S01E01.mkv",
        "Series (2020)/Season 1/../S01E01.mkv",
        "./Series (2020)/Season 1/S01E01.mkv",
        "/Series (2020)/Season 1/S01E01.mkv",
        "The Last of Us (2023)/Season 1/S01E01 - When You're Lost.mkv",
        "1917 (2019)/1917 (2019).mkv",
        "Movie (2020)/movie.mkv",
        "Movie (2020)/feature.mkv",
        "Movie (2020)/unrelated.mkv",
        "Movie {imdb-tt1234567}/Movie {imdb-tt1234567}.mkv",
        "Movie {tmdb-12345}.mkv",
        "Series {tvdb-12345}.mkv",
        "Movie (2020)-trailer.mkv",
        "Movie (2020)/Trailers/Movie S01E01-trailer.mkv",
        "Movie (2020)/Behind The Scenes/Filming.mkv",
        "Movie (2020)/Extras/Featurette.mkv",
        "Daily.Show.2024.02.29.mkv",
        "Daily.Show.2023.02.29.mkv",
        "Daily.Show.29.02.2024.mkv",
        "Daily.Show.31.04.2024.mkv",
        "Daily.Show.2024.13.01.mkv",
        "Daily.Show.2024.00.01.mkv",
        "Daily.Show.2024.02.٢٩.mkv",
        "Daily.Show.2024.02.２９.mkv",
        "Daily.Show.2024.01.01.1080p.mkv",
        "2024.01.01.mkv",
        "Series (2020)/Season 1/Series.S01E01.2160p.WEB-DL.H265.mkv",
        "Series (2020)/Season 1/Series.S01E01.part2.1080p.mkv",
        "Series (2020)/Season 1/S01E01 - Title.with_underscores.mkv",
        "Série Café 東京 (2021)/Season 1/S01E01.mkv",
        "Se\u{301}rie Cafe\u{301} 東京 (2021)/Season 1/S01E01.mkv",
        "İstanbul (2021)/Season 1/istanbul.S01E01.mkv",
        "Straße (2021)/Season 1/STRASSE.S01E01.mkv",
        "Σειρά (2021)/Season 1/σειρά.S01E01.mkv",
        "🎬 東京 (2021)/Season 1/S01E01 - 家族.mkv",
        "Series (2020)/Season 1/S01E01\n- Multi Line.mkv",
        "Series (2020)/Season 1/S01E01\t- Tab Title.mkv",
        "Series (2020)/Season 1/.mkv",
        "Series (2020)/Season 1/"
    ]
}

// Every public stored field and computed display field is included. Optional
// fields use Codable's normal nil representation consistently in both builds.
private struct RecognitionRecord: Codable {
    let kind: String
    let title: String
    let year: Int?
    let season: Int?
    let episode: Int?
    let lastEpisode: Int?
    let airDate: String?
    let episodeTitle: String?
    let edition: String?
    let catalogIDs: [String]
    let variant: String?
    let metadataSources: [String]
    let seriesTitle: String
    let displayName: String
    let section: String

    init(_ value: RecognizedMediaName) {
        kind = value.kind.rawValue
        title = value.title
        year = value.year
        season = value.season
        episode = value.episode
        lastEpisode = value.lastEpisode
        airDate = value.airDate
        episodeTitle = value.episodeTitle
        edition = value.edition
        catalogIDs = value.catalogIDs
        variant = value.variant
        metadataSources = value.metadataSources
        seriesTitle = value.seriesTitle
        displayName = value.displayName
        section = value.section
    }
}

private struct VerificationEntry: Codable {
    let caseName: String
    let path: String
    let result: RecognitionRecord
}

private struct Verification: Codable {
    let schemaVersion: Int
    let recordCount: Int
    let records: [VerificationEntry]
}

private struct StableHash {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037

    @inline(__always)
    mutating func byte(_ value: UInt8) {
        self.value ^= UInt64(value)
        self.value &*= 1_099_511_628_211
    }

    @inline(__always)
    mutating func string(_ value: String) {
        for value in value.utf8 { byte(value) }
        byte(0xFF) // This byte cannot occur in a valid UTF-8 String.
    }

    @inline(__always)
    mutating func integer(_ value: Int) {
        let bits = UInt64(bitPattern: Int64(value))
        for shift in stride(from: 0, to: 64, by: 8) {
            byte(UInt8(truncatingIfNeeded: bits >> shift))
        }
    }

    @inline(__always)
    mutating func optionalString(_ value: String?) {
        guard let value else { byte(0); return }
        byte(1)
        string(value)
    }

    @inline(__always)
    mutating func optionalInteger(_ value: Int?) {
        guard let value else { byte(0); return }
        byte(1)
        integer(value)
    }

    @inline(__always)
    mutating func strings(_ values: [String]) {
        integer(values.count)
        for value in values { string(value) }
    }

    @inline(__always)
    mutating func append(_ value: RecognizedMediaName) {
        string(value.kind.rawValue)
        string(value.title)
        optionalInteger(value.year)
        optionalInteger(value.season)
        optionalInteger(value.episode)
        optionalInteger(value.lastEpisode)
        optionalString(value.airDate)
        optionalString(value.episodeTitle)
        optionalString(value.edition)
        strings(value.catalogIDs)
        optionalString(value.variant)
        strings(value.metadataSources)
    }
}

@inline(never)
private func recognize(_ path: String) -> RecognizedMediaName {
    MediaNameRecognition.recognize(relativePath: path)
}

@inline(never)
private func run(paths: [String], iterations: Int) -> UInt64 {
    var hash = StableHash()
    for iteration in 0..<iterations {
        hash.append(recognize(paths[iteration % paths.count]))
    }
    return hash.value
}

private func expectedChecksum(_ results: [RecognizedMediaName], iterations: Int) -> UInt64 {
    var hash = StableHash()
    for iteration in 0..<iterations {
        hash.append(results[iteration % results.count])
    }
    return hash.value
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
    let batchSize: Int
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
private struct MediaNameRecognitionReuseBenchmark {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] || arguments == ["-h"] {
                print(Options.usage)
                return
            }
            if arguments == ["--list-cases"] {
                try writeJSON(caseNames)
                return
            }
            let options = try Options(arguments)
            if options.verify {
                var records: [VerificationEntry] = []
                for name in caseNames {
                    for path in Fixtures.paths(for: name) {
                        records.append(VerificationEntry(caseName: name, path: path,
                            result: RecognitionRecord(recognize(path))))
                    }
                }
                for path in Fixtures.edges {
                    records.append(VerificationEntry(caseName: "edge", path: path,
                        result: RecognitionRecord(recognize(path))))
                }
                try writeJSON(Verification(schemaVersion: 1, recordCount: records.count, records: records))
                return
            }

            let paths = Fixtures.paths(for: options.caseName)
            let preflight = paths.map(recognize)
            let expected = expectedChecksum(preflight, iterations: options.iterations)
            let expectedWarmup = expectedChecksum(preflight, iterations: options.warmup)
            let preflightHash = expectedChecksum(preflight, iterations: preflight.count)
            guard run(paths: paths, iterations: options.warmup) == expectedWarmup else {
                throw DriverError("Warmup checksum differs from preflight output.")
            }

            let cpuStarted = try processCPUTimeNanoseconds()
            let started = DispatchTime.now().uptimeNanoseconds
            let checksum = run(paths: paths, iterations: options.iterations)
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            let cpuElapsed = try processCPUTimeNanoseconds() - cpuStarted
            guard checksum == expected else {
                throw DriverError("Timed checksum differs from preflight output.")
            }

            try writeJSON(Measurement(
                caseName: options.caseName, batchSize: paths.count,
                iterations: options.iterations, warmupIterations: options.warmup,
                count: options.iterations, elapsedNs: elapsed, elapsedNanoseconds: elapsed,
                nsPerLookup: Double(elapsed) / Double(options.iterations),
                cpuNs: cpuElapsed, cpuNanoseconds: cpuElapsed,
                cpuNsPerLookup: Double(cpuElapsed) / Double(options.iterations),
                checksum: checksum, expectedChecksum: expected,
                preflightChecksum: preflightHash, verifiedQueries: preflight.count))
        } catch {
            FileHandle.standardError.write(Data("media-name-recognition-reuse: \(error)\n".utf8))
            exit(1)
        }
    }
}
