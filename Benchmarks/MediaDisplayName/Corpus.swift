import Foundation
import IlliquidCore

struct DisplayNameWorkload {
    let name: String
    let paths: [String]
    let recognizesInsideTimer: Bool
    let records: [RecognizedMediaName]

    init(_ name: String, paths: [String], recognizesInsideTimer: Bool = false,
         records: [RecognizedMediaName]? = nil) {
        self.name = name
        self.paths = paths
        self.recognizesInsideTimer = recognizesInsideTimer
        self.records = records ?? paths.map(MediaNameRecognition.recognize(relativePath:))
        precondition(self.records.count == paths.count)
    }
}

enum DisplayNameCorpus {
    static func benchmarkCases() -> [DisplayNameWorkload] {
        let titles = ["The Northern Line", "A Quiet Journey", "The River Between", "Morning Light"]
        let unicode = ["千と千尋", "Cafe\u{301} Society", "Жизнь у моря", "The 👩🏽‍🚀 Journey"]
        let numbered = (0..<128).map { i in
            "TV/\(titles[i % titles.count])/\(titles[i % titles.count]).S\(i % 12 + 1)E\(i % 48 + 1).The Arrival \(i).mkv"
        }
        let ranges = (0..<128).map { i in
            "TV/Show/Show.S\(i % 10)E\(i % 24 + 1)-E\(i % 24 + 2).Double Episode \(i).mkv"
        }
        let wide = (0..<128).map { i in "TV/Show/Show.S\(100 + i % 900)E\(1000 + i).mkv" }
        let international = (0..<128).map { i in
            "TV/\(unicode[i % unicode.count])/\(unicode[i % unicode.count]).S\(i % 5)E\(i % 24 + 1).\(unicode[(i + 1) % unicode.count]).mkv"
        }
        let dated = (0..<128).map { i in
            "TV/News/News.2024-02-\(i % 28 + 1 < 10 ? "0" : "")\(i % 28 + 1).Headlines.mkv"
        }
        let movies = (0..<128).map { i in
            "Movies/\(titles[i % titles.count]) \(i) (\(1980 + i % 45)).mkv"
        }
        let unknown = (0..<128).map { i in "Home Videos/Afternoon walk \(i).mp4" }
        let unusualNumbers = [-1, -10, 10_000, Int(Int32.max) + 1, Int(Int32.min) - 1, Int.min, Int.max]
        let unusualRecords = numbered.enumerated().map { i, path in
            var hints = MediaMetadataHints()
            hints.season = unusualNumbers[i % unusualNumbers.count]
            hints.episode = unusualNumbers[(i + 1) % unusualNumbers.count]
            hints.lastEpisode = unusualNumbers[(i + 2) % unusualNumbers.count]
            return MediaNameRecognition.recognize(relativePath: path).applying(hints)
        }
        let mixed = (0..<128).map { i in
            [numbered, ranges, dated, movies, unknown, international][i % 6][i]
        }
        let workloads: [DisplayNameWorkload] = [
            .init("cached-numbered", paths: numbered),
            .init("cached-ranges", paths: ranges),
            .init("cached-wide-numbers", paths: wide),
            .init("cached-unicode-titles", paths: international),
            .init("cached-dated-control", paths: dated),
            .init("cached-movie-control", paths: movies),
            .init("cached-unknown-control", paths: unknown),
            .init("cached-unbounded-control", paths: numbered, records: unusualRecords),
            .init("recognize-numbered", paths: numbered, recognizesInsideTimer: true),
            .init("recognize-ranges", paths: ranges, recognizesInsideTimer: true),
            .init("recognize-mixed", paths: mixed, recognizesInsideTimer: true),
        ]
        for workload in workloads {
            switch workload.name {
            case "cached-numbered", "cached-wide-numbers", "cached-unicode-titles", "recognize-numbered":
                precondition(workload.records.allSatisfy { $0.kind == .episode && $0.airDate == nil })
            case "cached-ranges", "recognize-ranges":
                precondition(workload.records.allSatisfy { $0.kind == .episode && $0.lastEpisode != nil })
            case "cached-dated-control":
                precondition(workload.records.allSatisfy { $0.kind == .episode && $0.airDate != nil })
            case "cached-movie-control":
                precondition(workload.records.allSatisfy { $0.kind == .movie })
            case "cached-unknown-control":
                precondition(workload.records.allSatisfy { $0.kind == .unknown })
            default: break
            }
        }
        return workloads
    }

    static func differentialPaths() -> [String] {
        var paths = benchmarkCases().flatMap(\.paths)
        let titles = ["Show", "Show (2020)", "Cafe\u{301}", "Café", "世界", "👩🏽‍🚀", "[GROUP] Show"]
        let seasons = [0, 1, 9, 10, 99, 100, 999]
        let episodes = [0, 1, 9, 10, 18, 99, 100, 999, 1000, 9999]
        let suffixes = ["", " - Arrival", " - 世界", " - Cafe\u{301}", " [GROUP] 1080p", " {edition-Cut}"]
        for title in titles {
            for season in seasons {
                for episode in episodes {
                    for (index, suffix) in suffixes.enumerated() {
                        let range = index.isMultiple(of: 2) && episode < 9999 ? "-E\(episode + 1)" : ""
                        paths.append("TV/\(title)/Season \(season)/\(title).S\(season)E\(episode)\(range)\(suffix).mkv")
                    }
                }
            }
        }
        paths += [
            "Show/Season 1/S01E01.mkv", "Show/S00E00.mkv", "Show.1x02.mkv",
            "News.2024-02-29.Headlines.mkv", "News.29.02.2024.Headlines.mkv",
            "News.2023-02-29.mkv", "News.20２４-02-29.mkv", "Show.S０１E０２.mkv",
            "Movie (2024).mkv", "Movie (2024)/Extras/Interview.mp4", "Unclassified.mp4",
        ]
        return paths
    }
}
