import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Compile beside production source and a symbol-renamed copy of the baseline source.
private protocol NameResult {
    var kindName: String { get }
    var title: String { get }
    var year: Int? { get }
    var season: Int? { get }
    var episode: Int? { get }
    var lastEpisode: Int? { get }
    var airDate: String? { get }
    var episodeTitle: String? { get }
    var edition: String? { get }
    var catalogIDs: [String] { get }
    var variant: String? { get }
    var metadataSources: [String] { get }
    var seriesTitle: String { get }
    var displayName: String { get }
    var section: String { get }
}
extension RecognizedMediaName: NameResult { fileprivate var kindName: String { kind.rawValue } }
extension BaselineRecognizedMediaName: NameResult { fileprivate var kindName: String { kind.rawValue } }
#if FOUNDATION_BOUNDARY_PROOF
extension AdaptedRecognizedMediaName: NameResult { fileprivate var kindName: String { kind.rawValue } }
extension AdaptedBaselineRecognizedMediaName: NameResult { fileprivate var kindName: String { kind.rawValue } }
#endif

// Compare every stored field and the strings shown by library projections. Optionals
// and ordered arrays retain their identity; a hash alone is not a correctness oracle.
private struct Snapshot: Equatable {
    static let names = ["kind", "title", "year", "season", "episode", "lastEpisode", "airDate",
                        "episodeTitle", "edition", "variant", "seriesTitle", "displayName", "section"]
    let fields: [String?]
    let catalogIDs: [String]
    let metadataSources: [String]
    init<T: NameResult>(_ value: T) {
        fields = [value.kindName, value.title, value.year.map { String($0) }, value.season.map { String($0) },
                  value.episode.map { String($0) }, value.lastEpisode.map { String($0) }, value.airDate,
                  value.episodeTitle, value.edition, value.variant, value.seriesTitle, value.displayName, value.section]
        catalogIDs = value.catalogIDs
        metadataSources = value.metadataSources
    }
    var json: [String: Any] {
        var result: [String: Any] = ["catalogIDs": catalogIDs, "metadataSources": metadataSources]
        for (name, field) in zip(Self.names, fields) { result[name] = field.map { $0 as Any } ?? NSNull() }
        return result
    }
}

// Consume all stored output bytes with a stable FNV-1a fingerprint. Derived display
// formatting is intentionally outside the timed workload, which measures recognition.
@inline(never) private func fingerprint<T: NameResult>(_ value: T) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    func number(_ value: UInt64) { hash = (hash ^ value) &* 1_099_511_628_211 }
    func string(_ value: String?) {
        guard let value else { number(UInt64.max); return }
        number(UInt64(value.utf8.count))
        for byte in value.utf8 { number(UInt64(byte)) }
    }
    string(value.kindName); string(value.title)
    for value in [value.year, value.season, value.episode, value.lastEpisode] {
        number(UInt64(bitPattern: Int64(value ?? -1)))
    }
    string(value.airDate); string(value.episodeTitle); string(value.edition); string(value.variant)
    for values in [value.catalogIDs, value.metadataSources] {
        number(UInt64(values.count))
        for value in values { string(value) }
    }
    return hash
}

private let scenarios = ["named-episode-no-year", "named-episode-with-year", "bare-season-episode",
                         "bare-parent-year-episode", "unclassified-bare-episode", "mixed-library", "movie-controls"]

private func corpus(_ scenario: String) -> [String] {
    let titles = ["The Office", "Blue Planet", "世界のニュース", "Café Society",
                  "The Expanse", "1883", "City of Glass", "Archive 81"]
    return (0..<64).map { index in
        let title = titles[index % titles.count]
        let year = 2000 + index % 24
        let token = String(format: "S%02dE%02d", 1 + index / 24, 1 + index % 24)
        let tail = " - Episode \(index + 1).1080p.WEB-DL.mkv"
        let showFolder = "TV/\(title) (\(year))/Season \(1 + index / 24)"
        switch scenario {
        case "named-episode-no-year": return "\(showFolder)/\(title) - \(token)\(tail)"
        case "named-episode-with-year": return "\(showFolder)/\(title) (\(year)) - \(token)\(tail)"
        case "bare-season-episode": return "\(showFolder)/\(token)\(tail)"
        case "bare-parent-year-episode": return "TV/\(title) (\(year))/\(token)\(tail)"
        case "unclassified-bare-episode": return "Unsorted/\(token)\(tail)"
        case "movie-controls":
            return "Movies/\(title) (\(year)) {imdb-tt\(1_000_000 + index)}/\(title).\(year).{edition-Final Cut}.2160p.HEVC.mkv"
        case "mixed-library":
            switch index % 8 {
            case 0: return "\(showFolder)/\(title) - \(token)\(tail)"
            case 1: return "\(showFolder)/\(token)\(tail)"
            case 2: return "TV/\(title) (\(year))/\(token)\(tail)"
            case 3: return "Movies/\(title) (\(year))/\(title).\(year).2160p.HEVC.mkv"
            case 4: return "Movies/\(title) (\(year))/Extras/Making Of.mkv"
            case 5: return "News - 2024-02-\(String(format: "%02d", 1 + index % 28)) - Headlines.mkv"
            case 6: return "Personal/vacation_\(index).mp4"
            default: return "Unsorted/\(token)\(tail)"
            }
        default: preconditionFailure("Unknown scenario: \(scenario)")
        }
    }
}

private func differentialPaths() -> [String] {
    let titles = ["", "Show", "show", "Show (2020)", "Show.2020", "1883 (2021)", "2001 A Space Odyssey (1968)",
                  "Café", "Cafe\u{301}", "世界のニュース", "🧑🏽‍🚀 Adventures", "İstanbul", "Straße",
                  "Show {tvdb-123}", "{edition-2020 Remaster}", "[2020]", "Show (1995) (2020)", "[Group] Show"]
    let parents = ["", "TV", "Show", "Show (2020)", "show (2020)", "SHOW.2020", "Different (2010)",
                   "Show (2020)/Season 01", "Show/Season 1", "Show (2020)/Specials", "Show {tvdb-123}/Season 03",
                   "Café (2022)/season_009", "Cafe\u{301} (2023)/Season-3", "世界のニュース (2024)/Season.001",
                   "Show (2020)/Season 1000", "Show (2020)/Extras", "Movie (1995)/Behind The Scenes",
                   "\u{200B}", "\u{00AD}", "\u{FEFF}", "\u{200D}", "\u{034F}", "\u{FE0F}",
                   "\u{200B}\u{00AD}\u{FEFF}", " (\u{200B}) ", "\u{200B} (2020)"]
    let tokens = ["S01E02", "s01_e02", "s1-e2-e3", "S00E0000", "S999E9999", "S1000E0001", "S001E10000",
                  "S01E02E01", "S01E02E02", "S01E02E0003", "1x02", "99x999", "100x001", "0x0",
                  "S０１E02", "S01E٠٢", "S𝟘𝟙E02", "xS01E02", "éS01E02", "1S01E02", "1080p", "clip1920x1080",
                  "2024-02-29", "2023-02-29", "1900-02-29", "2000-02-29", "2024-13-01", "2024-00-00",
                  "29.02.2024", "31-04-2024", "2024-０２-29", "٢٩.02.2024", "20２４-02-29"]
    let tails = [".mkv", " - Pilot.1080p.WEB-DL.mkv", ".{edition-Remaster}.{tvdb-9}.mkv",
                 "-deleted.mkv", ".part2.2160p.HEVC.mkv", ".Epilogue.[Group].mp4"]
    var paths = scenarios.flatMap(corpus)
    for (i, title) in titles.enumerated() {
        for (j, parent) in parents.enumerated() {
            for (k, token) in tokens.enumerated() {
                let file = (title.isEmpty ? "" : title + " - ") + token + tails[(i + j + k) % tails.count]
                paths.append((parent.isEmpty ? "" : parent + "/") + file)
            }
        }
    }
    let movieFiles = ["movie.mkv", "video.mkv", "feature.mkv", "main.mkv", "Arrival.1080p.mkv", "random.mkv",
                      "Arrival {imdb-tt2543164}.mkv", "Show {tvdb-1234}.mkv", "Movie (2020)-trailer.mp4",
                      "2001 A Space Odyssey (1968).mkv", "七人の侍 (1954).mkv", "2024.mp4", ".mkv", ""]
    for parent in parents + ["Arrival (2016)", "Arrival (2016) {imdb-tt2543164}"] {
        paths += movieFiles.map { (parent.isEmpty ? "" : parent + "/") + $0 }
    }
    paths += ["\u{200B}/S01E01.mkv", "\u{00AD}/S01E01.mkv", "\u{FEFF}/S01E01.mkv", "\u{200D}/S01E01.mkv",
              "\u{034F}/S01E01.mkv", "\u{FE0F}/S01E01.mkv", " (\u{200B}) /S01E01.mkv", "Season 01/S01E01.mkv",
              "2024/S01E01.mkv", "Show {edition-2005}/S01E01.mkv", "TV/Show (2005)/season ０１/S01E01.mkv",
              "Show (2005)/Season 1000/S01E01.mkv", "TV/Café (2005)/Season 01/Cafe\u{301}.S01E01.mkv",
              "TV/ΟΣ (2005)/Season 01/ος.S01E01.mkv", "TV/Show/Season 01/show.S01E01.mkv",
              "TV/Show (2005)/Season 01/show.(2000).S01E01.mkv"]
    return paths
}

private func emit(_ value: [String: Any]) {
    var output = value
    output["locale_identifier"] = Locale.current.identifier
    output["preferred_languages"] = Locale.preferredLanguages
    let data = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
private func fail(_ message: String) -> Never {
    emit(["ok": false, "error": message])
    exit(1)
}

private func validatedDifferentialPaths() -> [String] {
    let paths = differentialPaths()
    guard paths.count == 16_300, paths.filter({ $0.isEmpty }).count == 1,
          paths.filter({ $0 == ".mkv" }).count == 1,
          paths.filter({ $0.hasSuffix("/") }).count == 27 else {
        fail("Original differential corpus invariants changed")
    }
    return paths
}

#if FOUNDATION_BOUNDARY_PROOF
private func proveFoundationBoundary() {
    // Explicit parent and guard expectations exercise both sides of the boundary.
    // Native Foundation supplies an independent oracle for every entry as well.
    var edges: [(path: String, parent: String, adapted: Bool)] = [
        ("", "", false), ("/", "/", false), ("//", "/", false), ("///", "/", false),
        ("/a", "/", false), ("/a/", "/", false), ("//a///", "/", false),
        ("ab", "", false), ("ab/", "", false), ("a/b", "a", false),
        ("a//b///", "a", false), ("/a/b/", "/a", false),
        ("./a", ".", false), ("../a", "..", false), ("..", "", false),
        (".mkv", "", false), ("Café/世界.mkv", "Café", false),
        ("Cafe\u{301}/S01E02.mkv", "Cafe\u{301}", false),
        ("TV/Show (2020)/Season 01/S01E02.mkv", "TV/Show (2020)/Season 01", false),
    ]
    for scalar in ["a", "é", "中", ".", "\\", "\u{200B}", "\u{00AD}", "\u{FEFF}",
                   "\u{200D}", "\u{034F}", "\u{FE0F}"] {
        for suffix in ["", "/", "///"] { edges.append((scalar + suffix, "", true)) }
    }
    for text in ["😀", "\u{10000}", "e\u{301}", "🧑🏽‍🚀", "\u{200B}\u{00AD}"] {
        for suffix in ["", "/", "///"] { edges.append((text + suffix, "", false)) }
    }
    var rootGuardDetected = 0, slidingPathDetected = 0
    for edge in edges {
        let path = edge.path as NSString
        let native = path.deletingLastPathComponent
        guard native == edge.parent, benchmarkParentPath(path) == native,
              benchmarkNeedsParentPathBoundary(path) == edge.adapted else {
            fail("Focused Foundation boundary mismatch: \(String(reflecting: edge.path))")
        }
        // Deliberate mutants: omitting the root exclusion, and appending a dummy
        // path component to dodge Foundation's assertion. The same parent-path
        // comparison must reject both approaches on these fixtures.
        let scalars = edge.path.unicodeScalars
        let wrongGuard = scalars.first.map { $0.value <= 0xFFFF } == true
            && scalars.dropFirst().allSatisfy { $0.value == 0x2F }
        let wrongParent = wrongGuard ? "" : native
        if wrongParent != native { rootGuardDetected += 1 }
        let slid = (path.appendingPathComponent("__boundary_probe__") as NSString).deletingLastPathComponent
        if slid != native { slidingPathDetected += 1 }
    }
    guard rootGuardDetected > 0, slidingPathDetected > 0 else { fail("Negative controls were not detected") }

    let paths = validatedDifferentialPaths()
    var guardedIndices: [Int] = []
    var checksum: UInt64 = 0
    for (index, path) in (paths + edges.map(\.path)).enumerated() {
        let nativeParent = (path as NSString).deletingLastPathComponent
        guard benchmarkParentPath(path as NSString) == nativeParent else {
            fail("Parent-path mismatch at \(index): \(String(reflecting: path))")
        }
        if index < paths.count, benchmarkNeedsParentPathBoundary(path as NSString) { guardedIndices.append(index) }
        let baseline = BaselineMediaNameRecognition.recognize(relativePath: path)
        let candidate = MediaNameRecognition.recognize(relativePath: path)
        let adaptedBaseline = AdaptedBaselineMediaNameRecognition.recognize(relativePath: path)
        let adaptedCandidate = AdaptedMediaNameRecognition.recognize(relativePath: path)
        let before = Snapshot(baseline), after = Snapshot(candidate)
        guard before == Snapshot(adaptedBaseline), after == Snapshot(adaptedCandidate), before == after,
              fingerprint(baseline) == fingerprint(adaptedBaseline),
              fingerprint(candidate) == fingerprint(adaptedCandidate),
              fingerprint(baseline) == fingerprint(candidate) else {
            emit(["ok": false, "mode": "foundation-proof", "index": index, "path": path,
                  "baseline": before.json, "adapted_baseline": Snapshot(adaptedBaseline).json,
                  "candidate": after.json, "adapted_candidate": Snapshot(adaptedCandidate).json])
            exit(1)
        }
        if index < paths.count { checksum &+= fingerprint(candidate) }
    }
    guard guardedIndices == [16143, 16157, 16171, 16185, 16199, 16213] else {
        fail("Unexpected corpus Foundation boundary indices: \(guardedIndices)")
    }
    emit(["ok": true, "mode": "foundation-proof", "cases": paths.count, "focused_cases": edges.count,
          "parent_path_comparisons": paths.count + edges.count,
          "original_adapted_snapshot_comparisons_per_implementation": paths.count + edges.count,
          "guarded_corpus_indices": guardedIndices, "guarded_corpus_cases_per_implementation": guardedIndices.count,
          "focused_guarded_cases": edges.filter(\.adapted).count,
          "negative_controls": ["incorrect_root_guard_detected": rootGuardDetected,
                                "sliding_path_detected": slidingPathDetected],
          "checksum": String(checksum)])
}
#endif

@main private struct Driver {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--corpus"] {
            emit(["paths": validatedDifferentialPaths()])
            return
        }
        #if FOUNDATION_BOUNDARY_PROOF
        if arguments == ["--foundation-proof"] {
            proveFoundationBoundary()
            return
        }
        #endif
        if arguments == ["--differential"] {
            let paths = validatedDifferentialPaths()
            var checksum: UInt64 = 0
            for (index, path) in paths.enumerated() {
                let baseline = BaselineMediaNameRecognition.recognize(relativePath: path)
                let candidate = MediaNameRecognition.recognize(relativePath: path)
                let before = Snapshot(baseline), after = Snapshot(candidate)
                guard before == after, fingerprint(baseline) == fingerprint(candidate) else {
                    emit(["ok": false, "mode": "differential", "index": index, "path": path,
                          "baseline": before.json, "candidate": after.json])
                    exit(1)
                }
                checksum &+= fingerprint(candidate)
            }
            var report: [String: Any] = ["ok": true, "mode": "differential", "cases": paths.count,
                                       "checksum": String(checksum)]
            #if ADAPTED_FOUNDATION_BOUNDARY
            report["qualification_scope"] = "adapted Foundation boundary"
            let guarded = paths.indices.filter { benchmarkNeedsParentPathBoundary(paths[$0] as NSString) }
            guard guarded == [16143, 16157, 16171, 16185, 16199, 16213] else {
                fail("Unexpected corpus Foundation boundary indices: \(guarded)")
            }
            report["guarded_corpus_indices"] = guarded
            report["guarded_corpus_cases_per_implementation"] = guarded.count
            #else
            report["qualification_scope"] = "native Foundation"
            #endif
            emit(report)
            return
        }
        #if ADAPTED_FOUNDATION_BOUNDARY || FOUNDATION_BOUNDARY_PROOF
        fail("Adapted/proof binaries are correctness-only; timing requires original source")
        #else
        guard arguments.count == 5, arguments[0] == "--benchmark",
              ["baseline", "candidate"].contains(arguments[1]), scenarios.contains(arguments[2]),
              let iterations = Int(arguments[3]), iterations > 0, iterations <= 1_000_000,
              let rounds = Int(arguments[4]), rounds > 0, rounds <= 100 else {
            fail("Usage: --differential | --benchmark baseline|candidate SCENARIO ITERATIONS ROUNDS; scenarios: "
                 + scenarios.joined(separator: ", "))
        }
        let paths = corpus(arguments[2])
        let recognize: (String) -> UInt64 = arguments[1] == "baseline"
            ? { fingerprint(BaselineMediaNameRecognition.recognize(relativePath: $0)) }
            : { fingerprint(MediaNameRecognition.recognize(relativePath: $0)) }
        // Each process warms only its selected implementation. Corpus construction,
        // initial regex compilation, and checksum validation are outside the timer.
        let scanChecksum = paths.reduce(UInt64(0)) { $0 &+ recognize($1) }
        let expected = scanChecksum &* UInt64(iterations)
        for _ in 0..<8 {
            guard paths.reduce(UInt64(0), { $0 &+ recognize($1) }) == scanChecksum else { fail("Unstable warmup output") }
        }
        var samples: [Double] = []
        for _ in 0..<rounds {
            var checksum: UInt64 = 0
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { for path in paths { checksum &+= recognize(path) } }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            guard checksum == expected else { fail("Timed checksum differs from validation scan") }
            samples.append(Double(elapsed) / Double(iterations * paths.count))
        }
        emit(["ok": true, "mode": "benchmark", "implementation": arguments[1], "scenario": arguments[2],
              "corpus_size": paths.count, "iterations": iterations, "rounds": rounds,
              "operations_per_round": iterations * paths.count, "nanoseconds_per_operation": samples,
              "checksum": String(expected)])
        #endif
    }
}
