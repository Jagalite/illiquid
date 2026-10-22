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
        // Swift 6.2.4/Linux Foundation traps when the frozen baseline decomposes
        // a truly empty path. Keep .mkv and every nonempty directory-only fixture.
        for file in movieFiles where !parent.isEmpty || !file.isEmpty {
            paths.append((parent.isEmpty ? "" : parent + "/") + file)
        }
    }
    paths += ["\u{200B}/S01E01.mkv", "\u{00AD}/S01E01.mkv", "\u{FEFF}/S01E01.mkv", "\u{200D}/S01E01.mkv",
              "\u{034F}/S01E01.mkv", "\u{FE0F}/S01E01.mkv", " (\u{200B}) /S01E01.mkv", "Season 01/S01E01.mkv",
              "2024/S01E01.mkv", "Show {edition-2005}/S01E01.mkv", "TV/Show (2005)/season ０１/S01E01.mkv",
              "Show (2005)/Season 1000/S01E01.mkv", "TV/Café (2005)/Season 01/Cafe\u{301}.S01E01.mkv",
              "TV/ΟΣ (2005)/Season 01/ος.S01E01.mkv", "TV/Show/Season 01/show.S01E01.mkv",
              "TV/Show (2005)/Season 01/show.(2000).S01E01.mkv"]
    // Fail with a diagnostic before invoking either recognizer if corpus edits
    // reintroduce the unsafe input or remove the legitimate empty-basename case.
    guard !paths.contains("") else { fail("Differential corpus contains an empty path") }
    guard paths.contains(".mkv") else { fail("Differential corpus is missing the .mkv fixture") }
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

@main private struct Driver {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--differential"] {
            let paths = differentialPaths()
            // Optional crash receipt: write each input before entering a recognizer.
            // Keep diagnostics separate from the machine-readable result on stdout.
            let trace: FileHandle?
            if let destination = ProcessInfo.processInfo.environment["ILLIQUID_EPISODE_TRACE_PATH"] {
                guard FileManager.default.createFile(atPath: destination, contents: nil),
                      let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: destination))
                else { fail("Cannot create differential input trace") }
                trace = handle
            } else {
                trace = nil
            }
            defer { try? trace?.close() }
            func record(_ implementation: String, _ index: Int, _ path: String) {
                guard let trace else { return }
                let data = try! JSONSerialization.data(withJSONObject: [
                    "implementation": implementation, "index": index, "path": path,
                    "utf8": Array(path.utf8),
                ], options: [.sortedKeys])
                trace.write(data)
                trace.write(Data([0x0a]))
            }
            var checksum: UInt64 = 0
            for (index, path) in paths.enumerated() {
                record("baseline", index, path)
                let baseline = BaselineMediaNameRecognition.recognize(relativePath: path)
                record("candidate", index, path)
                let candidate = MediaNameRecognition.recognize(relativePath: path)
                let before = Snapshot(baseline), after = Snapshot(candidate)
                guard before == after, fingerprint(baseline) == fingerprint(candidate) else {
                    emit(["ok": false, "mode": "differential", "index": index, "path": path,
                          "baseline": before.json, "candidate": after.json])
                    exit(1)
                }
                checksum &+= fingerprint(candidate)
            }
            emit(["ok": true, "mode": "differential", "cases": paths.count, "checksum": String(checksum)])
            return
        }
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
    }
}
