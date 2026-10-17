import Foundation

/// Synthetic filename workloads: no filesystem traversal, sidecar reads, or
/// network catalog matching. Every timed path also appears in the differential
/// corpus, whose additional edge cases are generated before any measurement.
struct RecognitionBenchmarkCase: Sendable {
    let name: String
    let paths: [String]
}

enum RecognitionCorpus {
    private static let titles = [
        "The Last Lighthouse", "A Quiet Journey", "The River Between",
        "Beyond the Valley", "Summer at Home", "The Northern Line",
        "Morning Light", "An Unexpected Visitor",
    ]

    private static let unicodeTitles = [
        "Amélie", "Cafe\u{301} Society", "千と千尋の神隠し", "Жизнь у моря",
        "العائلة", "가족의 여행", "The 👩🏽‍🚀 Journey", "Cœur de Paris",
    ]

    static func benchmarkCases() -> [RecognitionBenchmarkCase] {
        let plainMovies = (0..<128).map { i in
            "Movies/\(titles[i % titles.count]) \(i) (\(1980 + i % 45)).mkv"
        }
        let releaseMovies = (0..<128).map { i in
            let title = titles[i % titles.count].replacingOccurrences(of: " ", with: ".")
            let release = ["1080p.BluRay.x264", "2160p.WEB-DL.HEVC", "720p.WEBRip", "1080p.AV1"][i % 4]
            return "Movies/\(title).\(i).\(1980 + i % 45).\(release).mkv"
        }
        let namedEpisodes = (0..<128).map { i in
            let show = titles[i % titles.count]
            let token = i.isMultiple(of: 4) ? "\(i % 5 + 1)x\(i % 24 + 1)" : "S\(i % 5 + 1)E\(i % 24 + 1)"
            return "TV/\(show)/\(show).\(token).The Arrival \(i).1080p.mkv"
        }
        let folderEpisodes = (0..<128).map { i in
            let season = i % 5
            let folder = season == 0 ? "Specials" : "Season \(season)"
            let episode = "S\(season)E\(i % 24 + 1)" + (i.isMultiple(of: 8) ? "-E\(i % 24 + 2)" : "")
            return "TV/\(titles[i % titles.count]) (\(2000 + i % 24))/\(folder)/\(episode) - Arrival \(i).mkv"
        }
        let unknown = (0..<128).map { i in
            let name = ["Afternoon walk", "Family picnic", "Mountain trail", "First rehearsal"][i % 4]
            return "Home Videos/\(name) \(i).mp4"
        }
        let unicode = (0..<128).map { i in
            let title = unicodeTitles[i % unicodeTitles.count]
            switch i % 4 {
            case 0: return "Films/\(title) (\(1980 + i % 45)).mkv"
            case 1: return "Séries/\(title)/Season 2/S02E\(i % 24 + 1) - Le retour.mkv"
            case 2: return "家庭/\(title)\u{00A0}\(i).mp4"
            default: return "TV/\(title).S01E\(i % 24 + 1).1080p.mkv"
            }
        }
        let taggedMovies = (0..<128).map { i in
            let provider = ["imdb-tt\(10_000 + i)", "tmdb-\(20_000 + i)"][i % 2]
            let edition = ["Final Cut", "Extended", "Theatrical", "Restored"][i % 4]
            return "Movies/\(titles[i % titles.count]) (\(1980 + i % 45)) {\(provider)}/\(titles[i % titles.count]) (\(1980 + i % 45)) {edition-\(edition)} [1080p] part\(i % 2 + 1).mkv"
        }
        let taggedEpisodes = (0..<128).map { i in
            let folder = i.isMultiple(of: 8) ? "Specials" : "Season 1"
            let season = i.isMultiple(of: 8) ? 0 : 1
            return "TV/\(titles[i % titles.count]) (\(2000 + i % 24)) {tvdb-\(30_000 + i)} {imdb-tt\(40_000 + i)}/\(folder)/S\(season)E\(i % 24 + 1) [GROUP] {edition-Commentary} 1080p.mkv"
        }
        let extras = (0..<128).map { i in
            let title = titles[i % titles.count]
            if i.isMultiple(of: 2) {
                let suffix = ["trailer", "behindthescenes", "deleted", "featurette"][i / 2 % 4]
                return "Movies/\(title) (\(1980 + i % 45))/\(title)-\(suffix).mp4"
            }
            let folder = ["Extras", "Behind the Scenes", "Interviews", "Deleted Scenes"][i / 2 % 4]
            return "Movies/\(title) (\(1980 + i % 45))/\(folder)/On location \(i).mp4"
        }
        let dated = (0..<128).map { i in
            let y = 2000 + i % 25
            let m = i % 12 + 1
            let d = i % 28 + 1
            let token = i.isMultiple(of: 2)
                ? String(format: "%04d-%02d-%02d", y, m, d)
                : String(format: "%02d.%02d.%04d", d, m, y)
            return "Daily Shows/\(titles[i % titles.count])/\(titles[i % titles.count]) - \(token) - Evening edition.mkv"
        }
        let malformed = (0..<128).map { i in
            let suffixes = ["{draft", "[camera", "notes}", "take]", "[mix{raw]}", "{edition-}", "｛draft｝", "｟cut｠"]
            return "Unsorted/\(titles[i % titles.count]) \(i) \(suffixes[i % suffixes.count]).mp4"
        }
        let categories = [plainMovies, releaseMovies, namedEpisodes, folderEpisodes,
                          unknown, unicode, taggedMovies, taggedEpisodes]
        let mixed = (0..<128).map { i in categories[i % categories.count][i] }
        return [
            .init(name: "movies_plain", paths: plainMovies),
            .init(name: "movies_release", paths: releaseMovies),
            .init(name: "episodes_named", paths: namedEpisodes),
            .init(name: "episodes_folders", paths: folderEpisodes),
            .init(name: "unknown_plain", paths: unknown),
            .init(name: "unicode_names", paths: unicode),
            .init(name: "tagged_movies", paths: taggedMovies),
            .init(name: "tagged_episodes", paths: taggedEpisodes),
            .init(name: "extras", paths: extras),
            .init(name: "dated_episodes", paths: dated),
            .init(name: "malformed_tags", paths: malformed),
            .init(name: "mixed_library", paths: mixed),
        ]
    }

    static func differentialPaths() -> [String] {
        var paths = benchmarkCases().flatMap(\.paths)
        // Deliberately retain canonically equivalent Unicode strings and repeated
        // paths. Set-based deduplication would discard some byte-distinct probes.
        paths.append(contentsOf: [
            "", ".", "..", "/", "movie", ".mkv", "Movie (2020).mkv", "Movie (2020).",
            "Movie (2020)/main.mkv", "Movie (2020)/video.mkv", "Movie (2020)/unrelated.mkv",
            "Show (2020)/Season 01/S01E02.mkv", "Show/Specials/S00E01.mkv",
            "Show {tvdb-123}/Season 01/S01E02.mkv", "Show {edition-Cut}/Specials/S00E01.mkv",
            "Folder}/Movie {edition-Cut.mkv", "Folder}/Movie {imdb-tt123.mkv",
            "Folder]/Movie [draft.mkv", "{imdb-tt123}/Movie}.mkv",
            "Show {tvdb-123}/Season 01/S01E01 {edition-Cut.mkv",
            "Show}/Season 01/S01E01 {edition-Cut.mkv",
            "Show}/Specials/S00E01 {edition-Cut.mkv",
            "[a{b]c}/Movie (2020).mkv", "Movie [a{b]c} (2020).mkv",
            "Movie {a[b}c] (2020).mkv", "Movie {{edition-Cut}} (2020).mkv",
            "Movie [[draft]] (2020).mkv", "Movie {edition-Cut [draft]} (2020).mkv",
            "Movie {imdb-tt123}{IMDB-TT123}{tmdb-9} (2020).mkv",
            "Movie {edition-Cut}{edition-Other} (2020).mkv",
            "Movie {tmdb-١٢٣} (2020).mkv", "Movie {imdb-tt１２３} (2020).mkv",
            "Show - 2024-02-29.mkv", "Show - 2023-02-29.mkv", "Show - 2024-13-01.mkv",
            "Show - 29.02.2024.mkv", "Show - 31.04.2024.mkv", "Show - ２０２４-02-29.mkv",
            "Show - 2024-٠٢-٢٩.mkv", "Show.S١E٢.mkv", "Show.S01E02E03.mkv",
            "Show - S01E03-E02.mkv", "Show - 1x02.mkv", "S01E01.mkv",
            "Movie 1917 (2019).mkv", "Movie {edition-2024} (2020).mkv",
            "Movie [2024] (2020).mkv", "Movie {tmdb-2024}.mkv",
            "Movie {tvdb-2024}.mkv", "Show (2020)/Season 1/Movie (2021).mkv",
            "Show (2020)/Season 1/S01E01-trailer.mkv", "Show/Extras/S01E01.mkv",
            "Movie \u{00A0}(2020).mkv", "Movie\u{2003}(2020).mkv", "Movie\t(2020).mkv",
            "Movie\n(2020).mkv", "Movie\r\n(2020).mkv", "Movie\u{2028}(2020).mkv",
            "Movie\u{2029}(2020).mkv", "Movie\u{200B}(2020).mkv",
            "Movie ｛edition-Cut｝ (2020).mkv", "Movie ［draft］ (2020).mkv",
            "Movie {\u{301}edition-Cut} (2020).mkv", "Movie [\u{301}draft] (2020).mkv",
            "Movie {edition-Cut}\u{301} (2020).mkv", "Movie [draft]\u{301} (2020).mkv",
            "Movie e\u{301}{edition-Cut} (2020).mkv", "Movie 👩🏽‍🚀[draft] (2020).mkv",
            "Movie {\u{200D}imdb-tt123} (2020).mkv", "Movie {imdb-tt123\u{200D}} (2020).mkv",
            "Parent {edition-Cut}/Folder/../Movie (2020).mkv",
            "./Show/Season 01/S01E02.mkv", "/Show//Season 01/S01E02.mkv",
        ])

        let fragments = [
            "", "{imdb-tt123}", "{TMDB-456}", "{tvdb-789}", "{edition-Final Cut}",
            "{edition-}", "{edition-Cut", "{imdb-tt123", "}", "{", "[", "]",
            "[release]", "[release", "[[nested]]", "{{nested}}", "{a[b}c]", "[a{b]c}",
            "{\u{301}edition-Cut}", "[\u{301}draft]", "{edition-Cut}\u{301}", "[draft]\u{301}",
            "｛edition-Cut｝", "［draft］", "{edition-Cut/Other}", "{tvdb-١٢٣}",
            "{imdb-tt１２３}", "{edition-\nCut}", "{edition-Cut}{edition-Other}",
            "{imdb-tt123}{IMDB-TT123}", "[draft]{edition-Cut}", "[{}]",
        ]
        let stems = [
            "The Journey (2020)", "The.Journey.2020.1080p", "Show.S01E02.Title", "S01E01",
            "Show - 2024-02-29", "Show - 2023-02-29", "Show - 29.02.2024", "Show.1x02",
            "Home video", "Cafe\u{301} (2020)", "Café (2020)", "映画 (2020)",
            "👨‍👩‍👧‍👦 Holiday", "Movie 1917 (2019)", "Show.S00E01-trailer", "Movie {tmdb-123}",
        ]
        let parents = [
            "", "Movies", "Movie (2020)", "Show (2020)/Season 1", "Show (2020)/Specials",
            "Show {tvdb-321}/Season 2", "Show {edition-Cut}/Specials", "Folder}", "Folder]",
            "Folder {edition-Parent}", "Folder {imdb-tt321}", "Folder [draft]", "Extras",
            "Show}/Season 01", "Show]/Specials", "The Journe\u{301}y (2020)",
        ]
        let separators = [" ", ".", "_", "-", "\u{00A0}", "\u{2003}", "\t", "\n", "\u{301}", "\u{200D}"]

        // A fixed LCG makes the mixed corpus reproducible on every platform.
        // It is deliberately not Swift's process-randomized Hasher/random API.
        var generator = Generator(state: 0x6d65_6469_616e_616d)
        for i in 0..<5_120 {
            let parent = parents[generator.index(parents.count)]
            let stem = stems[generator.index(stems.count)]
            let first = fragments[generator.index(fragments.count)]
            let second = fragments[generator.index(fragments.count)]
            let separator = separators[generator.index(separators.count)]
            let raw: String
            switch i % 4 {
            case 0: raw = first + separator + stem + separator + second
            case 1: raw = stem + separator + first + separator + second
            case 2: raw = first + stem + second
            default: raw = stem + separator + first
            }
            let suffix = [".mkv", ".mp4", ".avi", ".mov"][i % 4]
            paths.append((parent.isEmpty ? "" : parent + "/") + raw + suffix)
        }

        // Exhaust every literal marker with adjacent combining/format scalars,
        // across all three title-cleaning and selected-ancestor paths.
        let marks = ["", "\u{301}", "\u{308}", "\u{200D}", "\u{FE0F}", "\u{20E3}"]
        let tokens = ["{edition-Cut}", "{imdb-tt123}", "[draft]", "{a[b}c]", "[a{b]c}", "{{x}}", "[[x]]", "{unfinished"]
        for mark in marks {
            for token in tokens {
                for placement in 0..<16 {
                    let decorated: String
                    switch placement / 4 {
                    case 0: decorated = mark + token
                    case 1: decorated = String(token.prefix(1)) + mark + String(token.dropFirst())
                    case 2: decorated = String(token.dropLast()) + mark + String(token.suffix(1))
                    default: decorated = token + mark
                    }
                    switch placement % 4 {
                    case 0: paths.append("Movie \(decorated) (2020).mkv")
                    case 1: paths.append("Show \(decorated) (2020)/Season 1/S01E01 - Title.mkv")
                    case 2: paths.append("Show \(decorated)/Specials/S00E01.mkv")
                    default: paths.append("Parent}/Movie \(decorated) {edition-Open.mkv")
                    }
                }
            }
        }
        return paths
    }

    private struct Generator {
        var state: UInt64

        mutating func index(_ upperBound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 32) % UInt64(upperBound))
        }
    }
}
