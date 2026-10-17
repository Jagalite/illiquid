import Dispatch
import Foundation
import IlliquidCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// This harness calls the separately supplied, unchanged production source. The
// snapshot contains every stored property and every public computed property.
private struct Snapshot: Encodable {
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

private struct CorpusRecord: Encodable {
    let path: String
    let result: Snapshot
}

private struct Measurement: Encodable {
    let schemaVersion = 1
    let workload: String
    let iterations: Int
    let fixtureCount: Int
    let warmupCount: Int
    let wallNanoseconds: UInt64
    let cpuNanoseconds: UInt64
    let checksum: String
    let warmupChecksum: String
}

private enum Fixtures {
    static let workloads = [
        "dated-forward", "dated-reverse", "dated-invalid", "dated-unicode",
        "movies", "episodes", "ambiguous", "tags"
    ]

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    static func paths(for workload: String) -> [String] {
        (0..<64).map { index in
            let year = 1900 + (index * 7) % 200
            let month = pad(1 + index % 12)
            let day = pad(1 + index % 28)
            switch workload {
            case "dated-forward":
                return "Archives/Daily News - \(year)-\(month)-\(day) - Bulletin \(index).mkv"
            case "dated-reverse":
                return "Archives/Evening Report - \(day).\(month).\(year) - Edition \(index).mp4"
            case "dated-invalid":
                let invalid = ["1900-02-29", "2023-02-29", "2024-04-31", "2024-00-15",
                               "2024-13-01", "2024-01-00", "2024-01-32", "31.11.2024",
                               "29.02.1900", "00.01.2024", "99.12.2024", "2024-99-99"]
                return "News - \(invalid[index % invalid.count]) - Bulletin \(index).mkv"
            case "dated-unicode":
                let dates = ["2024-02-29", "29.02.2024", "20２４-02-29", "2024-٠٢-29",
                             "٢٩.02.2024", "2024-𝟘𝟚-29", "२९.02.2024", "2024-02-２９"]
                return "世界のニュース/📰 Cafe\u{301} 世界 - \(dates[index % dates.count]) - 今日 \(index).mkv"
            case "movies":
                let titles = ["Arrival", "Blade Runner", "七人の侍", "2001 A Space Odyssey",
                              "A Quiet Place", "Café Society", "The Long Goodbye", "東京物語"]
                return "Movies/\(titles[index % titles.count]) (\(year))/\(titles[index % titles.count]).\(year).1080p.WEB-DL.\(index).mkv"
            case "episodes":
                let season = 1 + index % 9
                let episode = 1 + index % 24
                return index.isMultiple(of: 2)
                    ? "TV/The Show (2005)/Season \(pad(season))/S\(pad(season))E\(pad(episode)) - Episode \(index).mkv"
                    : "The.Show.S\(pad(season))E\(pad(episode))-E\(pad(episode + 1)).A.Long.Day.1080p.WEB-DL.mkv"
            case "ambiguous":
                let names = ["vacation", "family", "clip1920x1080", "recording", "S01E01",
                             "Anime - 012", "東京の休日", "A.Cafe\u{301}.Visit"]
                return "Unsorted/\(names[index % names.count]) - \(index).mov"
            case "tags":
                let names = [
                    "Film (1995) {edition-2020 Remaster} [1080p] {imdb-tt0123456}",
                    "Show (2020) S01E02 [Group] {edition-Director Cut} 2160p.HEVC",
                    "📰 世界 - 2024-02-29 [News] {edition-Evening}",
                    "Film [outer[inner]rest] (2001) {tmdb-123}",
                    "Movie (2000) {unclosed [tag] 720p", "Movie (2000) [unclosed {edition-cut}",
                    "Film (1995) {edition-Café} [a][b][c] {tvdb-12}",
                    "Show S00E01 {x}{y}{z} [1080p]"
                ]
                return "Media/\(names[index % names.count]) - \(index).mkv"
            default:
                preconditionFailure("Unknown workload: \(workload)")
            }
        }
    }

    static func visitCorpus(exhaustiveDates: Bool, _ visit: (String) throws -> Void) rethrows {
        for workload in workloads {
            for path in paths(for: workload) { try visit(path) }
        }
        let titles = ["News", "世界のニュース", "Cafe\u{301}", "Café", "📰\u{00a0}News",
                      "[Group] News", "{edition-X} News", "", "2001 A Space Odyssey"]
        let suffixes = ["", " - Headlines", ".1080p.WEB-DL", " [a] {edition-Cut}", " {unclosed", " [unclosed"]
        let dates = ["1900-02-28", "1900-02-29", "2000-02-29", "2001-02-29", "2099-12-31",
                     "2024-02-29", "29.02.2024", "31-04-2024", "2024-99-99", "99.12.2024",
                     "2024-00-00", "00.00.2024", "20２４-02-29", "2024-０２-29", "2024-02-٢٩",
                     "29.٠٢.2024", "٢٩.02.2024", "2024-𝟘𝟚-29", "2024-02-२९"]
        for title in titles {
            for date in dates {
                for suffix in suffixes {
                    try visit("Archive/\(title) - \(date)\(suffix).mkv")
                }
            }
        }
        let fragments = ["", "[", "]", "{", "}", "[]", "{}", "[x]", "{x}", "[x{y}z]",
                         "{x[y]z}", "{{}}", "[[]]", "[\n]", "{\n}", "［x］", "｛x｝",
                         "e\u{301}", "é", "👩‍👩‍👧‍👦", "\u{00a0}", "\u{202f}", "\u{2003}", "\u{200d}",
                         "[\u{301}", "{\u{301}", "[\u{fe0f}", "{\u{fe0f}"]
        for first in fragments {
            for second in fragments {
                try visit("Media/Title\(first) (2000) \(second).mkv")
                try visit("TV/Show (2020)/Season 01/S01E02 - A\(first).B_\(second).mkv")
            }
        }
        for path in ["", "/", ".mkv", "S01E01.mkv", "2024.mkv", "2001 A Space Odyssey (1968).mkv",
                     "Movie (2020)-trailer.mp4", "Show S01E01-deleted.mkv", "Movie (2020)/Extras/Clip.mkv",
                     "Arrival (2016)/movie.mkv", "Arrival (2016)/random.mkv", "Film {imdb-tt01234}.mkv",
                     "Show {tvdb-123}.mkv", "News - 2024-02-29 - 2023-02-29.mkv",
                     "News - 2023-02-29 - 2024-02-29.mkv", "News - 29.02.2024 - 2023-02-29.mkv"] {
            try visit(path)
        }
        // Reverse dates with DD > 31 take the existing first-field-as-year
        // branch; retain its rejection across the complete two-digit DD range.
        for year in [1900, 2000, 2099] {
            for month in [1, 12, 99] {
                for day in 32...99 {
                    try visit("News - \(day).\(pad(month)).\(year) - Headlines.mkv")
                }
            }
        }
        guard exhaustiveDates else { return }
        // Every valid day in the regex-supported 1900...2099 interval, plus
        // month/day boundary values. Both accepted field orders are exercised.
        // This is not every invalid two-digit month/day spelling (00...99).
        for year in 1900...2099 {
            for month in 0...13 {
                for day in 0...32 {
                    try visit("News - \(year)-\(pad(month))-\(pad(day)) - Headlines.mkv")
                    try visit("News - \(pad(day)).\(pad(month)).\(year) - Headlines.mkv")
                }
            }
        }
    }
}

private func encoder() -> JSONEncoder {
    let result = JSONEncoder()
    result.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return result
}

private func checksum(_ values: [RecognizedMediaName]) throws -> String {
    // All-field consumption is deliberately outside the timed interval.
    // Corpus verification also compares complete canonical bytes, not this hash.
    let data = try encoder().encode(values.map(Snapshot.init))
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in data {
        hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
}

private func cpuNanoseconds() -> UInt64 {
    var time = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0)
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

@main
private enum Harness {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["corpus"] || arguments == ["corpus", "--exhaustive-dates"] {
            let json = encoder()
            try Fixtures.visitCorpus(exhaustiveDates: arguments.count == 2) { path in
                var data = try json.encode(CorpusRecord(path: path,
                    result: Snapshot(MediaNameRecognition.recognize(relativePath: path))))
                data.append(10)
                FileHandle.standardOutput.write(data)
            }
            return
        }
        guard arguments.count == 4, arguments[0] == "benchmark",
              Fixtures.workloads.contains(arguments[1]),
              let iterations = Int(arguments[2]), iterations > 0,
              let warmupCount = Int(arguments[3]), warmupCount > 0 else {
            FileHandle.standardError.write(Data("Usage: harness corpus [--exhaustive-dates] | benchmark WORKLOAD ITERATIONS WARMUP\n".utf8))
            exit(2)
        }
        let workload = arguments[1]
        let paths = Fixtures.paths(for: workload)
        let warmup = (0..<warmupCount).map {
            MediaNameRecognition.recognize(relativePath: paths[$0 % paths.count])
        }
        let warmupChecksum = try checksum(warmup)
        var results: [RecognizedMediaName] = []
        results.reserveCapacity(iterations)
        let cpuStart = cpuNanoseconds()
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations {
            results.append(MediaNameRecognition.recognize(relativePath: paths[index % paths.count]))
        }
        let wall = DispatchTime.now().uptimeNanoseconds - start
        let cpu = cpuNanoseconds() - cpuStart
        let measurement = Measurement(workload: workload, iterations: iterations,
            fixtureCount: paths.count, warmupCount: warmupCount, wallNanoseconds: wall,
            cpuNanoseconds: cpu, checksum: try checksum(results), warmupChecksum: warmupChecksum)
        var data = try encoder().encode(measurement)
        data.append(10)
        FileHandle.standardOutput.write(data)
    }
}
