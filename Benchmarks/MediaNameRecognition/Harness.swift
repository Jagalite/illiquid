import Foundation
import MediaRecognition

private struct Workload {
    let name: String
    let paths: [String]
}

private func workloads() -> [Workload] {
    let named = (1...64).map {
        "Archive Show (2019)/Season 02/Archive.Show.S02E\(String(format: "%02d", $0)).A.New.Day.1080p.WEB-DL.mkv"
    }
    let folder = (1...64).map {
        "Archive Show (2019)/Season 02/S02E\(String(format: "%02d", $0)).A.New.Day.mkv"
    }
    let movies = (0..<64).map { index in
        index.isMultiple(of: 2)
            ? "Movies/Film.Title.\(index).(\(1980 + index % 40)).1080p.BluRay.mkv"
            : "Movies/Film Title \(index) (\(1980 + index % 40))/movie.mkv"
    }
    let dated = (0..<64).map { index in
        let day = String(format: "%02d", 1 + index % 28)
        return index.isMultiple(of: 2)
            ? "Daily Program/Daily.Program.2024.06.\(day).Evening.Edition.mkv"
            : "Daily Program/Daily.Program.\(day)-06-2024.Evening.Edition.mkv"
    }
    let plain = (0..<64).map { "Home Videos/Trip.\($0).To.The.Sea.mkv" }
    let names = ["Amélie", "Ame\u{301}lie", "星の旅", "Мост", "العالم", "Cafe\u{301}", "👨‍👩‍👧‍👦", "İstanbul"]
    let tagged = (0..<64).map { index in
        let title = names[index % names.count]
        return index.isMultiple(of: 2)
            ? "\(title) (2020) {tvdb-\(100 + index)}/Season 01/\(title).S01E\(index + 1).[Fansub].{edition-Extended}.mkv"
            : "Films/\(title).(2001).[Remaster].{imdb-tt\(100_000 + index)}.{edition-Director's Cut}.mkv"
    }
    let long = (0..<32).map { index in
        let title = String(repeating: index.isMultiple(of: 2) ? "Long.Film.Name." : "長い映画の名前_", count: 96)
        return index.isMultiple(of: 2)
            ? "\(title) (2020)/Season 02/\(title).S02E03.End.[tag].mkv"
            : "Library/\(title).(2020).[metadata].{edition-Long}.mkv"
    }
    let extras = (0..<16).map { "Film (2020)/Extras/Interview.\($0).mkv" }
    var mixed: [String] = []
    for index in 0..<16 {
        mixed += [named[index], folder[index], movies[index], dated[index], plain[index], tagged[index], extras[index]]
    }
    return [
        .init(name: "mixed-library", paths: mixed),
        .init(name: "named-episodes", paths: named),
        .init(name: "folder-episodes", paths: folder),
        .init(name: "movies", paths: movies),
        .init(name: "dated-episodes", paths: dated),
        .init(name: "plain-unknown", paths: plain),
        .init(name: "tagged-unicode", paths: tagged),
        .init(name: "long-name-stress", paths: long)
    ]
}

private func verificationPaths() -> [String] {
    var paths = [
        "", ".", "/", "..", "movie.mkv", "S01E01.mkv", "S01E01E03.mkv",
        "Show (2019)/Season 01/S01E01.mkv", "Show (2019)/Specials/S00E01.mkv",
        "Show/Season 01/S01E01.mkv", "Show/S01E01.mkv", "Show (2019)/S01E01.mkv",
        "[tag]/Season 01/S01E01.mkv", "{tag}/Season 01/S01E01.mkv",
        "{edition-2024}/Season 01/S01E01.mkv", "[tag]/Season 01/[tag].S01E01.mkv",
        "Show (20٢٤)/S01E01.mkv", "Show (20２４)/S01E01.mkv",
        "Show (20٢٤)/Season 01/S01E01.mkv", "Show (20２４)/Season 01/S01E01.mkv",
        "Show (2019)/Season 01/Show.S01E01.mkv", "SHOW (2019)/Season 01/Show.S01E01E03.mkv",
        "Show/S01E9999E0001.Title.mkv", "Show/S001E0001.Title.mkv", "Show/1x001.Title.mkv",
        "Show (2019)/Season 01/S٠1E٠1.mkv", "Show (2019)/Season 01/S０１E０１.mkv",
        "Show.2024-02-29.mkv", "Show.2023-02-29.mkv", "Show.2024-13-01.mkv",
        "Show.2024-00-01.mkv", "Show.2024-01-00.mkv", "Show.2024-04-31.mkv",
        "Show.29-02-2024.mkv", "Show.31-02-2024.mkv", "Show.2024-٠٢-٠١.mkv",
        "Show.20٢٤-02-01.mkv", "Show.2024-０２-０１.mkv", "2024-02-29.mkv",
        "Film (2020)/movie.mkv", "Film (2020)/feature.mkv", "Film (2020)/unrelated.mkv",
        "Film (2020)/Trailers/Film.2024-trailer.mkv", "Film.2020-S01E01-trailer.mkv",
        "Film.2000.(2001).(2002).mkv", "1917 (2019).mkv", "2001.A.Space.Odyssey.(1968).mkv",
        "[2010].Film.{edition-2020}.mkv", "Film.{imdb-tt123}.{tmdb-123}.{IMDB-TT123}.mkv",
        "Film.{tvdb-123}.mkv", "Film.{edition-Director's Cut}.cd1.1080p.mkv",
        "Film.{edition-A}.{edition-B}.mkv", "Film.[[nested]].(2020).mkv",
        "Film.{nested{tag}}.(2020).mkv", "Film.[{cross]tail}.(2020).mkv",
        "Film.{[cross}tail].(2020).mkv", "Film.[unfinished.(2020).mkv",
        "Film.{unfinished.(2020).mkv", "Film.].}.(2020).mkv", "{[x]}.(2020).mkv",
        "Film.\u{0}.(2020).mkv", "Film.\n.(2020).mkv", "Film.\r\n.(2020).mkv",
        "Cafe\u{301}.(2020).mkv", "Café.(2020).mkv", "Film.[\u{301}tag].(2020).mkv",
        "Film.{\u{200D}tag}.(2020).mkv", "Film.［tag］.（2020）.mkv",
        "Σειρά (2019)/Season 01/σειρά.S01E01.mkv", "İ (2019)/Season 01/i.S01E01.mkv",
        "Movie.\u{2028}.(2020).mkv", "Movie.\u{00A0}.(2020).mkv", "Movie.\u{200B}.(2020).mkv"
    ]
    let titles = ["Example", "A.Name", "A_Name", "1917", "", "-()[]", "Café", "Cafe\u{301}", "日本語", "👩🏽‍🚀", "[{cross]tail}", "{[cross}tail]"]
    let folders = ["", "Videos/", "A Name (2018)/", "A Name (2018)/Season 02/", "A Name/Specials/", "A Name (2018)/Extras/"]
    let tags = ["", ".[tag]", ".{tmdb-42}", ".{tvdb-42}", ".{edition-2024}", ".[one]{two}[three]", ".[unclosed", ".{unclosed"]
    let tokens = ["", ".(2001)", ".2001", ".S02E03", ".s02e03e05", ".2x03", ".2024-02-29", ".2023-02-29", ".2024-٠٢-٠١", "-trailer"]
    var random: UInt64 = 0x48B5_719C_A4ED_6503
    func next(_ count: Int) -> Int {
        random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((random >> 32) % UInt64(count))
    }
    for index in 0..<2_000 {
        let folder = folders[next(folders.count)]
        let title = titles[next(titles.count)]
        let tag = tags[next(tags.count)]
        let token = tokens[next(tokens.count)]
        paths.append(folder + title + tag + token + (index.isMultiple(of: 3) ? ".1080p.WEB-DL" : "") + ".mkv")
    }
    for workload in workloads() { paths.append(contentsOf: workload.paths) }
    return paths
}

// Swift String equality permits canonical equivalence. Compare the actual UTF-8
// of every string field so normalization changes cannot disappear in that test.
private struct ExactRecord: Codable, Equatable, Sendable {
    let kind: String
    let title: [UInt8]
    let year: Int?
    let season: Int?
    let episode: Int?
    let lastEpisode: Int?
    let airDate: [UInt8]?
    let episodeTitle: [UInt8]?
    let edition: [UInt8]?
    let catalogIDs: [[UInt8]]
    let variant: [UInt8]?
    let metadataSources: [[UInt8]]
    let seriesTitle: [UInt8]
    let displayName: [UInt8]
    let section: [UInt8]

    init(_ value: RecognizedMediaName) {
        kind = value.kind.rawValue
        title = Array(value.title.utf8)
        year = value.year
        season = value.season
        episode = value.episode
        lastEpisode = value.lastEpisode
        airDate = value.airDate.map { Array($0.utf8) }
        episodeTitle = value.episodeTitle.map { Array($0.utf8) }
        edition = value.edition.map { Array($0.utf8) }
        catalogIDs = value.catalogIDs.map { Array($0.utf8) }
        variant = value.variant.map { Array($0.utf8) }
        metadataSources = value.metadataSources.map { Array($0.utf8) }
        seriesTitle = Array(value.seriesTitle.utf8)
        displayName = Array(value.displayName.utf8)
        section = Array(value.section.utf8)
    }

#if DIFFERENTIAL_VERIFY
    // Serialize the frozen type directly. Constructing today's result type
    // here would accidentally test today's derived formatting on both sides.
    init(_ value: BaselineRecognizedMediaName) {
        kind = value.kind.rawValue
        title = Array(value.title.utf8)
        year = value.year
        season = value.season
        episode = value.episode
        lastEpisode = value.lastEpisode
        airDate = value.airDate.map { Array($0.utf8) }
        episodeTitle = value.episodeTitle.map { Array($0.utf8) }
        edition = value.edition.map { Array($0.utf8) }
        catalogIDs = value.catalogIDs.map { Array($0.utf8) }
        variant = value.variant.map { Array($0.utf8) }
        metadataSources = value.metadataSources.map { Array($0.utf8) }
        seriesTitle = Array(value.seriesTitle.utf8)
        displayName = Array(value.displayName.utf8)
        section = Array(value.section.utf8)
    }
#endif
}

private struct ReceiptHash {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037

    mutating func bytes<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for byte in bytes { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
    }

    mutating func text(_ text: String?) {
        guard let text else { bytes([0]); return }
        bytes([1])
        bytes(String(text.utf8.count).utf8)
        bytes([0])
        bytes(text.utf8)
    }

    mutating func record(_ record: RecognizedMediaName) {
        text(record.kind.rawValue)
        text(record.title)
        text(record.year.map { String($0) })
        text(record.season.map { String($0) })
        text(record.episode.map { String($0) })
        text(record.lastEpisode.map { String($0) })
        text(record.airDate)
        text(record.episodeTitle)
        text(record.edition)
        text(String(record.catalogIDs.count))
        for id in record.catalogIDs { text(id) }
        text(record.variant)
        text(String(record.metadataSources.count))
        for source in record.metadataSources { text(source) }
        text(record.seriesTitle)
        text(record.displayName)
        text(record.section)
    }

    var hex: String { String(value, radix: 16) }
}

private enum HarnessError: Error {
    case usage
    case mismatch(index: Int, path: String, baseline: ExactRecord, candidate: ExactRecord)
}

private func printJSON(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

@main
private enum Harness {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--catalog"] {
            try printJSON([
                "workloads": workloads().map { ["name": $0.name, "paths": $0.paths] as [String: Any] },
                "verification_paths": verificationPaths()
            ])
            return
        }
        if arguments == ["--verify"] {
#if DIFFERENTIAL_VERIFY
            var hash = ReceiptHash()
            let paths = verificationPaths()
            for (index, path) in paths.enumerated() {
                let baseline = BaselineMediaNameRecognition.recognize(relativePath: path)
                let candidate = MediaNameRecognition.recognize(relativePath: path)
                let left = ExactRecord(baseline)
                let right = ExactRecord(candidate)
                guard left == right else {
                    throw HarnessError.mismatch(index: index, path: path, baseline: left, candidate: right)
                }
                hash.text(path)
                hash.record(candidate)
            }
            try printJSON(["checks": paths.count, "checksum": hash.hex, "exact_utf8_fields": true])
            return
#else
            throw HarnessError.usage
#endif
        }
        guard arguments.count == 4, arguments[0] == "--case", arguments[2] == "--iterations",
              let iterations = Int(arguments[3]), iterations > 0,
              let workload = workloads().first(where: { $0.name == arguments[1] }) else {
            throw HarnessError.usage
        }
        let operations = workload.paths.count * iterations
        var warmup = ReceiptHash()
        for _ in 0..<2 {
            for path in workload.paths { warmup.record(MediaNameRecognition.recognize(relativePath: path)) }
        }
        // Reserve before timing. Retain every result, then consume all fields
        // after timing, so the interval measures recognition plus result append.
        var results: [RecognizedMediaName] = []
        results.reserveCapacity(operations)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            for path in workload.paths { results.append(MediaNameRecognition.recognize(relativePath: path)) }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        var receipt = ReceiptHash()
        for result in results { receipt.record(result) }
        try printJSON([
            "workload": workload.name, "paths_per_iteration": workload.paths.count,
            "iterations": iterations, "operations": operations, "elapsed_ns": elapsed,
            "checksum": receipt.hex, "warmup_checksum": warmup.hex
        ])
    }
}
