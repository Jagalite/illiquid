import Foundation

/// Original synthetic filenames, never a scan of a user's media collection.
/// Construct these arrays before timing; generation is not recognition work.
enum RecognitionCorpus {
    static let cases = [
        "episode_prefixed",
        "episode_bare_season",
        "episode_bare_parent_year",
        "episode_explicit_year",
        "episode_specials_multiple",
        "episode_alternate",
        "episode_unicode_tags",
        "movies",
        "dates",
        "extras",
        "unknown",
        "mixed",
    ]

    /// Every timing workload has the same number of paths. The mixed workload
    /// interleaves all families, so branch and regex warmup is not episode-only.
    static func paths(for name: String) -> [String] {
        if name == "mixed" {
            let groups = cases.dropLast().map { paths(for: $0) }
            return (0..<128).map { index in
                groups[index % groups.count][(index * 17) % 128]
            }
        }
        precondition(cases.contains(name), "Unknown recognition workload: \(name)")
        return (0..<128).map { path(for: name, index: $0) }
    }

    /// Compare complete serialized results with the unmodified implementation.
    /// The product code does not generate expected values. Repeated paths are
    /// intentional; canonical-equivalent Unicode spellings must not be removed
    /// with Set<String>, which would collapse distinct UTF-8 inputs.
    static var differentialPaths: [String] {
        var result = cases.flatMap { paths(for: $0) }
        let prefixes = [
            "",
            "Harbor.Lights.",
            "Harbor Lights (2021) - ",
            "PAPER_MOONS.",
            "Caf\u{00E9}.Harbor.",
            "Cafe\u{0301}.Harbor.",
            "[Studio] Cedar Station - ",
            "999.Year.(1999).",
        ]
        let parents = [
            "",
            "Library/",
            "Harbor Lights/Season 01/",
            "Harbor Lights (2021)/Season_001/",
            "Paper Moons/Specials/",
            "Caf\u{00E9} Harbor (2016)/",
            "Cafe\u{0301} Harbor (2016)/Season-2/",
            "2020 (2017) {tmdb-80421}/",
        ]
        let tokens = [
            "S01E01", "s02.e003", "S00E01E02", "S999E9999",
            "S001E0000", "1x001", "99x999", "S1000E01",
            "XS01E01", "S01E\u{0661}\u{0662}",
            "s\u{FF10}\u{FF11}e\u{FF10}\u{FF12}", "2x1234",
        ]
        let suffixes = [
            ".mkv",
            " - First Watch.mkv",
            ".Second_Watch.1080p.WEB-DL.mkv",
            " (2024) {edition-2001 Cut}.mkv",
            " {tvdb-5023} {TMDB-80421}.mkv",
            "-trailer.mkv",
            " - Winter\u{00A0}Light [1080p].mkv",
            " - Finale {edition-Restored} CD2 AV1.mkv",
        ]
        for parent in parents {
            for prefix in prefixes {
                for token in tokens {
                    for suffix in suffixes {
                        result.append(parent + prefix + token + suffix)
                    }
                }
            }
        }

        let years = [
            "1799", "1800", "1899", "1900", "1999", "2000", "2099",
            "2100", "20\u{0661}\u{0662}", "\u{FF12}\u{FF10}\u{FF12}\u{FF10}",
        ]
        for title in ["", "1984", "The 2000 Project", "Harbor (1999) (2021)", "(2021)"] {
            for year in years {
                result.append("\(title) (\(year))/Season 1/\(title) S01E01.mkv")
                result.append("\(title) (\(year))/S01E01.mkv")
                result.append("\(title) \(year)/Season 1/S01E01.mkv")
                result.append("\(title) (\(year)) S01E01 - Launch.mkv")
            }
        }

        result.append(contentsOf: [
            "", "/", ".", "..", "video", "video.mkv", ".mkv",
            "../Harbor Lights (2021)/Season 01/S01E01.mkv",
            "/Library/Harbor Lights (2021)/Season 01/S01E01.mkv",
            "Harbor Lights (2021)//Season 01/S01E01.mkv",
            "Harbor Lights (2021)/Season 01/./S01E01.mkv",
            "Harbor Lights (2021)/Season 01/S01E01.mkv/",
            "Harbor Lights (2021)/Season 01/S01E01",
            "Harbor Lights (2021)/Season 01/.S01E01.mkv",
            "Harbor Lights (2021)/Season 01/S01E01.1080p.mkv",
            "Harbor Lights (2021)/Season 01/S01E01E01.mkv",
            "Harbor Lights (2021)/Season 01/S01E02E01.mkv",
            "Harbor Lights (2021)/Season 01/S01E01E9999.mkv",
            "Harbor Lights (2021)/Season 01/S01E01E10000.mkv",
            "Harbor Lights (2021)/Season 01/S01E01-S01E02.mkv",
            "Harbor Lights (2021)/Season 01/S01E01-E02.mkv",
            "Harbor Lights (2021)/Season 01/S 01 E 01.mkv",
            "Harbor Lights (2021)/Season 01/S01E01e.mkv",
            "Harbor Lights (2021)/Season 01/S01E01\u{0301}.mkv",
            "Harbor Lights (2021)/Season 01/S01E01\nLaunch.mkv",
            "Harbor Lights (2021)/Season 01/[Group] S01E01.mkv",
            "[Harbor Lights (2021)]/Season 01/S01E01.mkv",
            "{edition-2021 Cut}/Season 01/S01E01.mkv",
            "Harbor {tvdb-2021}/Season 01/S01E01.mkv",
            "Harbor {edition-{tmdb-12}} (2021)/Season 01/S01E01.mkv",
            "Harbor (2021)/Season 01/{edition-Unclosed S01E01.mkv",
            "Harbor (2021)/Season 01/[Unclosed S01E01.mkv",
            "Harbor Lights (2021)/Season 01/Harbor Lights (2020) S01E01.mkv",
            "Harbor Lights (2021)/Season 01/harbor lights S01E01.mkv",
            "Harbor Lights (2021)/Season 01/Different Show S01E01.mkv",
            "Caf\u{00E9} Harbor (2016)/Season 1/Cafe\u{0301} Harbor S01E01.mkv",
            "Cafe\u{0301} Harbor (2016)/Season 1/Caf\u{00E9} Harbor S01E01.mkv",
            "\u{0130}STANBUL (2016)/Season 1/istanbul S01E01.mkv",
            "Stra\u{00DF}e (2016)/Season 1/STRASSE S01E01.mkv",
            "\u{661F}\u{306E}\u{6D77} (2022)/Season 1/S01E01 - \u{591C}\u{660E}\u{3051}.mkv",
            "\u{0645}\u{064A}\u{0646}\u{0627}\u{0621} (2022)/Season 1/S01E01.mkv",
            "\u{1F469}\u{200D}\u{1F680} Station (2024)/Season 1/S01E01.mkv",
            "Night Desk.1900-02-29.mkv", "Night Desk.2000-02-29.mkv",
            "Night Desk.2024-02-30.mkv", "Night Desk.31-12-2024.mkv",
            "Night Desk.2024-13-01.mkv", "Night Desk.2024-00-00.mkv",
            "Night Desk.2024-\u{0660}\u{0661}-\u{0660}\u{0662}.mkv",
            "Harbor Lights (2021)/Extras/S01E01 - Launch.mkv",
            "Harbor Lights (2021)/Season 01/S01E01-trailer.mkv",
            "Harbor Lights (2021)/Season 01/S01E01-short.mkv",
            "Harbor Lights (2021)/Specials/S00E00E01.mkv",
            "Harbor Lights (2021)/Season_999/S999E9999.mkv",
            "Harbor Lights (2021)/Season_1000/S01E01.mkv",
            "Harbor Lights (2021)/specials/S01E01.mkv",
        ])
        return result
    }

    private static func path(for name: String, index: Int) -> String {
        let titles = ["Harbor Lights", "Cedar Station", "Paper Moons", "Winter Orchard"]
        let title = titles[index % titles.count]
        let year = 2016 + index % 9
        let season = 1 + index % 8
        let episode = 1 + index % 24
        let token = "S\(twoDigits(season))E\(twoDigits(episode))"
        let tail = ["First Watch", "The Crossing", "Late Arrival", "Morning Light"][index % 4]
        let release = ["1080p.WEB-DL", "2160p.HEVC", "720p.HDTV", "1080p.AV1"][index % 4]
        switch name {
        case "episode_prefixed":
            return "TV/\(title) (\(year))/Season \(twoDigits(season))/\(title.replacingOccurrences(of: " ", with: ".")).\(token).\(tail).\(release).mkv"
        case "episode_bare_season":
            let folder = ["Season \(season)", "Season_\(twoDigits(season))", "season-\(season)", "Season.\(season)"][index % 4]
            return "TV/\(title) (\(year))/\(folder)/\(token) - \(tail).mkv"
        case "episode_bare_parent_year":
            return "TV/\(title) (\(year))/\(token) - \(tail).\(release).mkv"
        case "episode_explicit_year":
            let parentYear = index.isMultiple(of: 4) ? year - 1 : year
            return "TV/\(title) (\(parentYear))/Season \(season)/\(title) (\(year)) - \(token) - \(tail).mkv"
        case "episode_specials_multiple":
            let marker = index.isMultiple(of: 2)
                ? "S00E\(twoDigits(episode))"
                : "S\(twoDigits(season))E\(twoDigits(episode))E\(twoDigits(episode + 1))"
            let folder = index.isMultiple(of: 2) ? "Specials" : "Season \(season)"
            return "TV/\(title) (\(year))/\(folder)/\(marker) - \(tail).\(release).mkv"
        case "episode_alternate":
            let prefix = index.isMultiple(of: 2) ? "\(title) - " : ""
            return "TV/\(title) (\(year))/Season \(season)/\(prefix)\(season)x\(twoDigits(episode)) - \(tail).mkv"
        case "episode_unicode_tags":
            let unicodeTitle = ["Caf\u{00E9} Harbor", "Cafe\u{0301} Harbor", "\u{661F}\u{306E}\u{6D77}", "\u{1F469}\u{200D}\u{1F680} Station"][index % 4]
            return "TV/\(unicodeTitle) (\(year)) {tvdb-\(5000 + index)}/Season \(season)/[Group] \(unicodeTitle) - \(token) - \(tail) {edition-2001 Cut} {TMDB-\(8000 + index)}.\(release).mkv"
        case "movies":
            let movie = ["A Map of Winter", "1984", "The 2000 Project", "Northern Letters"][index % 4]
            switch index % 4 {
            case 0: return "Movies/\(movie) (\(year))/\(movie).\(year).\(release).mkv"
            case 1: return "Movies/\(movie) (\(year))/feature.mkv"
            case 2: return "Movies/\(movie) (\(year))/\(movie) (\(year)) {edition-Restored} CD2.mkv"
            default: return "Movies/\(movie) {tmdb-\(8000 + index)}.\(release).mkv"
            }
        case "dates":
            let date = ["2024-02-29", "31-12-2023", "2023.02.29", "2024_13_01"][index % 4]
            return "TV/Night Desk/\(year)/Night.Desk.\(date).Report.\(index).\(release).mkv"
        case "extras":
            let folder = ["Extras", "Behind the Scenes", "Trailers", "Featurettes"][index % 4]
            return "Movies/\(title) (\(year))/\(folder)/\(title).\(token).Making.Of.\(index)-featurette.mkv"
        case "unknown":
            let raw = ["Family picnic \(index)", "S01E\(twoDigits(episode))", "1080p camera \(index)", "Notes {tvdb-\(5000 + index)}"][index % 4]
            return "Unsorted/\(raw).mp4"
        default:
            preconditionFailure("Unknown recognition workload: \(name)")
        }
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : String(value)
    }
}
