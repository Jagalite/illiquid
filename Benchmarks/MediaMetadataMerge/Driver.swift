import Dispatch
import Foundation
@testable import IlliquidCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private enum API: String, Encodable {
    case overriding, applying, plexmatch
}

private enum Operation {
    case merge(MediaMetadataHints, MediaMetadataHints)
    case apply(RecognizedMediaName, MediaMetadataHints)
    case plex(PlexMatchHints, String, Bool, Int?)
}

private struct Input {
    let id: String
    let operation: Operation
}

private enum Value {
    case hints(MediaMetadataHints)
    case recognized(RecognizedMediaName)
}

/// Every stored public result field. Optional fields omitted by Encodable are
/// nil; arrays preserve duplicate elements, spelling, and ordering.
private struct Snapshot: Encodable, Equatable {
    let type: String
    let content: String?
    let kind: String?
    let title: String?
    let year: Int?
    let season: Int?
    let episode: Int?
    let last_episode: Int?
    let air_date: String?
    let episode_title: String?
    let edition: String?
    let catalog_ids: [String]
    let variant: String?
    let sources: [String]

    init(_ value: Value) {
        switch value {
        case let .hints(hints):
            type = "hints"
            switch hints.content {
            case .movie: content = "movie"
            case .show: content = "show"
            case .episode: content = "episode"
            case nil: content = nil
            }
            kind = nil
            title = hints.title
            year = hints.year
            season = hints.season
            episode = hints.episode
            last_episode = hints.lastEpisode
            air_date = nil
            episode_title = hints.episodeTitle
            edition = nil
            catalog_ids = hints.catalogIDs
            variant = nil
            sources = hints.sources
        case let .recognized(name):
            type = "recognized"
            content = nil
            kind = name.kind.rawValue
            title = name.title
            year = name.year
            season = name.season
            episode = name.episode
            last_episode = name.lastEpisode
            air_date = name.airDate
            episode_title = name.episodeTitle
            edition = name.edition
            catalog_ids = name.catalogIDs
            variant = name.variant
            sources = name.metadataSources
        }
    }
}

private struct Descriptor: Encodable {
    let id: String
    let api: API
    let pool_size: Int
    let description: String
}

private struct Benchmark {
    let descriptor: Descriptor
    let inputs: [Input]
}

private struct VerifiedCase: Encodable {
    let id: String
    let output: Snapshot
}

private struct Verification: Encodable {
    let mode = "verify"
    let case_count: Int
    let cases: [VerifiedCase]
}

private struct Measurement: Encodable {
    let mode = "measure"
    let case_id: String
    let iterations: Int
    let operations: Int
    let pool_size: Int
    let elapsed_ns: UInt64
    let cpu_ns: UInt64
    let checksum: String
    let output: [Snapshot]
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private func evaluate(_ input: Input) -> Value {
    switch input.operation {
    case let .merge(newer, older):
        return .hints(newer.overriding(older))
    case let .apply(name, hints):
        return .recognized(name.applying(hints))
    case let .plex(hints, path, inherits, season):
        return .hints(hints.hints(for: path, inheritsDescendantMappings: inherits, defaultSeason: season))
    }
}

private func catalogIDs(_ count: Int, _ index: Int) -> [String] {
    Array(["imdb-tt\(2_000_000 + index)", "tmdb-\(30_000 + index)", "tvdb-\(40_000 + index)"].prefix(count))
}

private func olderHints(_ index: Int, ids: Int = 0, sources: [String] = []) -> MediaMetadataHints {
    var hints = MediaMetadataHints()
    hints.content = .episode
    hints.title = "Harbour Café \(index)"
    hints.year = 2020 + index % 5
    hints.season = 2 + index % 3
    hints.episode = index + 1
    hints.lastEpisode = index.isMultiple(of: 2) ? index + 2 : nil
    hints.episodeTitle = "Opening \(index)"
    hints.catalogIDs = catalogIDs(ids, index)
    hints.sources = sources
    return hints
}

private func partialHints(_ index: Int) -> MediaMetadataHints {
    var hints = MediaMetadataHints()
    hints.episodeTitle = "Local title \(index)"
    return hints
}

private func recognized(_ index: Int, ids: Int = 0,
                        kind: RecognizedMediaName.Kind = .episode, dated: Bool = false) -> RecognizedMediaName {
    let episode = kind == .episode
    return RecognizedMediaName(
        kind: kind,
        title: "Harbour Café \(index)",
        year: 2020 + index % 5,
        season: episode && !dated ? 2 : nil,
        episode: episode && !dated ? index + 1 : nil,
        lastEpisode: episode && !dated && index.isMultiple(of: 2) ? index + 2 : nil,
        airDate: episode && dated ? "2024-01-\(index < 9 ? "0" : "")\(index + 1)" : nil,
        episodeTitle: episode ? "Filename title \(index)" : nil,
        edition: index.isMultiple(of: 2) ? "Extended" : nil,
        catalogIDs: catalogIDs(ids, index),
        variant: "1080p \(index)",
        metadataSources: ["filename"]
    )
}

private func benchmarks() throws -> [Benchmark] {
    var result: [Benchmark] = []
    func add(_ id: String, _ api: API, _ description: String,
             make: (Int) throws -> Operation) throws {
        let inputs = try (0..<16).map { Input(id: "\(id)-\($0)", operation: try make($0)) }
        result.append(Benchmark(
            descriptor: Descriptor(id: id, api: api, pool_size: inputs.count, description: description),
            inputs: inputs
        ))
    }

    try add("override-empty-both", .overriding, "Two empty hint values") { _ in
        .merge(MediaMetadataHints(), MediaMetadataHints())
    }
    try add("override-ids0-sources0", .overriding, "Partial scalar override, no IDs or sources") {
        .merge(partialHints($0), olderHints($0))
    }
    try add("override-ids0-source1", .overriding, "Episode-only override inherits one metadata source") {
        .merge(partialHints($0), olderHints($0, sources: [".plexmatch"]))
    }
    for count in [1, 3] {
        try add("override-ids\(count)-empty", .overriding, "Empty override inherits \(count) catalog IDs and one source") {
            .merge(MediaMetadataHints(), olderHints($0, ids: count, sources: ["show.nfo"]))
        }
    }
    try add("override-empty-older-new-ids1", .overriding, "One new catalog ID and source against empty hints") { index in
        var newer = partialHints(index)
        newer.catalogIDs = catalogIDs(1, index)
        newer.sources = ["episode.nfo"]
        return .merge(newer, MediaMetadataHints())
    }
    for count in [1, 3] {
        try add("override-ids\(count)-replace-provider", .overriding, "Replace one provider among \(count) existing IDs") { index in
            var newer = partialHints(index)
            newer.catalogIDs = ["imdb-tt\(9_000_000 + index)"]
            newer.sources = ["episode.nfo"]
            return .merge(newer, olderHints(index, ids: count, sources: ["show.nfo"]))
        }
    }
    try add("override-add-providers", .overriding, "Keep an existing IMDb ID and append TMDB/TVDB IDs") { index in
        var newer = partialHints(index)
        newer.catalogIDs = ["tmdb-\(90_000 + index)", "tvdb-\(80_000 + index)"]
        return .merge(newer, olderHints(index, ids: 1))
    }
    try add("override-duplicate-source-order", .overriding, "Deduplicate and sort overlapping source labels") { index in
        var newer = partialHints(index)
        newer.sources = [".plexmatch", "alpha.nfo", "alpha.nfo"]
        return .merge(newer, olderHints(index, ids: 3, sources: ["zeta.nfo", ".plexmatch", "zeta.nfo"]))
    }
    for movieToEpisode in [true, false] {
        let name = movieToEpisode ? "movie-to-episode" : "episode-to-movie"
        try add("override-\(name)", .overriding, "Cross-content identity reset: \(name)") { index in
            var older = olderHints(index, ids: 3, sources: ["old.nfo"])
            older.content = movieToEpisode ? .movie : .episode
            var newer = partialHints(index)
            newer.content = movieToEpisode ? .episode : .movie
            newer.episode = movieToEpisode ? index + 4 : nil
            newer.sources = ["new.nfo"]
            return .merge(newer, older)
        }
    }

    for count in [0, 1, 3] {
        try add("apply-ids\(count)-empty", .applying, "Apply empty hints to filename evidence with \(count) IDs") {
            .apply(recognized($0, ids: count), MediaMetadataHints())
        }
    }
    try add("apply-ids3-replace-provider", .applying, "Replace a TMDB ID while preserving other filename evidence") { index in
        var hints = partialHints(index)
        hints.catalogIDs = ["tmdb-\(90_000 + index)"]
        hints.sources = ["episode.nfo"]
        return .apply(recognized(index, ids: 3), hints)
    }
    try add("apply-ids0-new-ids1", .applying, "Add one catalog ID and source to filename evidence") { index in
        var hints = partialHints(index)
        hints.catalogIDs = catalogIDs(1, index)
        hints.sources = ["episode.nfo"]
        return .apply(recognized(index), hints)
    }
    for movieToEpisode in [true, false] {
        let name = movieToEpisode ? "movie-to-episode" : "episode-to-movie"
        try add("apply-\(name)", .applying, "Cross-content filename identity reset: \(name)") { index in
            var hints = partialHints(index)
            hints.content = movieToEpisode ? .episode : .movie
            hints.episode = movieToEpisode ? index + 4 : nil
            hints.sources = ["new.nfo"]
            return .apply(recognized(index, ids: 3, kind: movieToEpisode ? .movie : .episode), hints)
        }
    }
    try add("apply-extra-unchanged", .applying, "Extras ignore metadata hints") { index in
        .apply(recognized(index, ids: 3, kind: .extra), olderHints(index, ids: 1, sources: ["movie.nfo"]))
    }
    try add("apply-show-without-episode", .applying, "A show title alone cannot classify an unknown file") { index in
        var hints = partialHints(index)
        hints.content = .show
        hints.title = "Folder show \(index)"
        return .apply(recognized(index, ids: 1, kind: .unknown), hints)
    }
    try add("apply-dated-to-numbered-episode", .applying, "An explicit episode replaces prior date/range evidence") { index in
        var hints = partialHints(index)
        hints.episode = index + 4
        hints.lastEpisode = index + 5
        return .apply(recognized(index, ids: 3, dated: true), hints)
    }

    let plexCases: [(String, Int)] = [
        ("mapped-ids0", 0), ("mapped-ids1", 1), ("mapped-ids3", 3),
        ("explicit-season-range", 3), ("descendant-disabled", 3),
        ("missing-path-fallback", 3), ("default-season", 1),
    ]
    for (kind, count) in plexCases {
        try add("plex-\(kind)", .plexmatch, "Complete lookup/merge in preparsed .plexmatch: \(kind)") { index in
            var lines = ["title: Harbour Café \(index)", "year: \(2020 + index % 5)"]
            if kind != "default-season" { lines.append("season: 3") }
            if count >= 1 { lines.append("imdbid: tt\(2_000_000 + index)") }
            if count == 3 {
                lines += ["tmdbid: \(30_000 + index)", "tvdbid: \(40_000 + index)"]
            }
            lines += ["ep: E\(index + 1): Episode.mkv", "ep: S4E2-S4E4: Season 4/Part.mkv"]
            guard let plex = PlexMatchHints.parse(lines.joined(separator: "\n")) else {
                throw Failure("Could not prepare the .plexmatch fixture")
            }
            let path: String
            switch kind {
            case "explicit-season-range", "descendant-disabled": path = "Season 4/Part.mkv"
            case "missing-path-fallback": path = "Missing.mkv"
            default: path = "Episode.mkv"
            }
            return .plex(plex, path, kind != "descendant-disabled", 7 + index % 3)
        }
    }
    return result
}

private func verificationInputs(_ benchmarks: [Benchmark]) -> [Input] {
    var inputs = benchmarks.flatMap(\.inputs)
    // Public hint fields can contain manually constructed IDs. Preserve the
    // existing provider interpretation and duplicate order for these controls.
    let identifiers: [[String]] = [
        [], ["imdb-tt1"], ["tmdb-2", "tvdb-3", "imdb-tt4"],
        ["tmdb-2", "tmdb-2", "imdb-tt4"],
        [""], ["-", "--", "-tmdb--7"], ["TMDB-2", "tmdb-3"],
        ["Café-1", "Cafe\u{0301}-2"], ["tmdb-\u{0301}3", "tvdb-\u{200D}4"],
    ]
    let sourcePairs: [([String], [String])] = [
        ([], []), ([".plexmatch"], []), ([], ["episode.nfo"]),
        (["z.nfo", "a.nfo", "z.nfo"], ["a.nfo", ".plexmatch"]),
        (["Café"], ["Cafe\u{0301}", "Café"]),
    ]
    for olderIDs in identifiers {
        for newerIDs in identifiers {
            for (olderSources, newerSources) in sourcePairs {
                var older = olderHints(4)
                older.catalogIDs = olderIDs
                older.sources = olderSources
                var newer = partialHints(7)
                newer.catalogIDs = newerIDs
                newer.sources = newerSources
                inputs.append(Input(id: "compatibility-merge-\(inputs.count)", operation: .merge(newer, older)))
                let name = RecognizedMediaName(
                    kind: .episode, title: "Exact Cafe\u{0301}", year: 2024,
                    season: 2, episode: 5, lastEpisode: 6, airDate: nil,
                    episodeTitle: "Original", edition: "Extended", catalogIDs: olderIDs,
                    variant: "1080p", metadataSources: olderSources
                )
                inputs.append(Input(id: "compatibility-apply-\(inputs.count)", operation: .apply(name, newer)))
            }
        }
    }
    return inputs
}

@inline(__always)
private func integer(_ value: Int?) -> UInt64 {
    UInt64(bitPattern: Int64(value ?? -1))
}

@inline(__always)
private func textState(_ value: String?) -> UInt64 {
    guard let value else { return 1 }
    return value.isEmpty ? 2 : 3
}

@inline(__always)
private func arrayState(_ values: [String]) -> UInt64 {
    UInt64(values.count) &+ textState(values.first) &+ textState(values.last)
}

/// Bounded scalar observations of every result field. Complete string contents,
/// duplicate IDs and source ordering are checked outside the measured region.
@inline(__always)
private func consume(_ value: Value) -> UInt64 {
    switch value {
    case let .hints(hints):
        let content: UInt64
        switch hints.content {
        case nil: content = 1
        case .movie: content = 2
        case .show: content = 3
        case .episode: content = 4
        }
        return content &+ textState(hints.title) &+ integer(hints.year)
            &+ integer(hints.season) &+ integer(hints.episode) &+ integer(hints.lastEpisode)
            &+ textState(hints.episodeTitle) &+ arrayState(hints.catalogIDs) &+ arrayState(hints.sources)
    case let .recognized(name):
        let kind: UInt64
        switch name.kind {
        case .movie: kind = 1
        case .episode: kind = 2
        case .extra: kind = 3
        case .unknown: kind = 4
        }
        return kind &+ textState(name.title) &+ integer(name.year)
            &+ integer(name.season) &+ integer(name.episode) &+ integer(name.lastEpisode)
            &+ textState(name.airDate) &+ textState(name.episodeTitle) &+ textState(name.edition)
            &+ arrayState(name.catalogIDs) &+ textState(name.variant) &+ arrayState(name.metadataSources)
    }
}

private func cpuNanoseconds() throws -> UInt64 {
    var time = timespec()
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0 else {
        throw Failure("clock_gettime(CLOCK_PROCESS_CPUTIME_ID) failed")
    }
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

private func emit<Value: Encodable>(_ value: Value) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
}

@main
private struct Driver {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let inventory = try benchmarks()
        if args == ["list"] {
            try emit(inventory.map(\.descriptor))
            return
        }
        if args == ["verify"] {
            let outputs = verificationInputs(inventory).map {
                VerifiedCase(id: $0.id, output: Snapshot(evaluate($0)))
            }
            try emit(Verification(case_count: outputs.count, cases: outputs))
            return
        }
        guard args.count == 3, args[0] == "measure",
              let test = inventory.first(where: { $0.descriptor.id == args[1] }),
              let iterations = Int(args[2]), iterations > 0,
              iterations <= Int.max / test.inputs.count else {
            throw Failure("Usage: Driver list | verify | measure CASE ITERATIONS")
        }
        let expectedValues = test.inputs.map(evaluate)
        let expected = expectedValues.map(Snapshot.init)
        let oneIteration = expectedValues.reduce(UInt64(0)) { $0 &+ consume($1) }
        var checksum: UInt64 = 0
        let cpuStart = try cpuNanoseconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            for input in test.inputs { checksum &+= consume(evaluate(input)) }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - wallStart
        let cpu = try cpuNanoseconds() - cpuStart
        guard checksum == oneIteration &* UInt64(iterations) else {
            throw Failure("\(test.descriptor.id): timed result checksum mismatch")
        }
        let observed = test.inputs.map { Snapshot(evaluate($0)) }
        guard observed == expected else { throw Failure("Output changed after timing") }
        try emit(Measurement(
            case_id: test.descriptor.id, iterations: iterations,
            operations: iterations * test.inputs.count, pool_size: test.inputs.count,
            elapsed_ns: elapsed, cpu_ns: cpu, checksum: String(checksum), output: observed
        ))
    }
}

