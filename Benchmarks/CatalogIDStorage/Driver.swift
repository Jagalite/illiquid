import CMemoryProbe
import Foundation
import IlliquidCore

// Every measured iteration builds, consumes, and releases a complete output batch.
// Inputs, canonicalization, and JSON formatting stay outside the measured interval.
enum Operation: String, Sendable { case overriding, applying, plex }

struct Fixture: Sendable {
    let name: String
    let description: String
    let operation: Operation
    let outputCount: Int
    let previous: MediaMetadataHints
    let replacement: MediaMetadataHints
    let recognized: RecognizedMediaName
    let plex: PlexMatchHints?
    let paths: [String]

    var metadata: [String: Any] {
        ["name": name, "description": description, "operation": operation.rawValue,
         "outputCount": outputCount, "previousIDCount": previous.catalogIDs.count,
         "replacementIDCount": replacement.catalogIDs.count]
    }
}

struct Outputs {
    var hints: [MediaMetadataHints] = []
    var names: [RecognizedMediaName] = []
    var count: Int { hints.count + names.count }
    var idCount: Int {
        hints.reduce(0) { $0 + $1.catalogIDs.count } + names.reduce(0) { $0 + $1.catalogIDs.count }
    }
}

func hints(_ ids: [String], content: MediaMetadataHints.Content? = .episode) -> MediaMetadataHints {
    var value = MediaMetadataHints()
    value.content = content
    value.catalogIDs = ids
    return value
}

func fixture(_ name: String, _ description: String, _ operation: Operation,
             previousIDs: [String], replacementIDs: [String] = [],
             count: Int = 4096, kindChange: Bool = false) -> Fixture {
    var previous = hints(previousIDs, content: .show)
    previous.title = "Shared Series"
    previous.year = 2001
    previous.sources = [".plexmatch"]
    var replacement = hints(replacementIDs, content: kindChange ? .movie : .episode)
    replacement.season = 2
    replacement.episode = 3
    let recognized = MediaNameRecognition.recognize(relativePath: "Shared.Series.S02E03.mkv")
        .applying(previous)
    var plex: PlexMatchHints?
    var paths: [String] = []
    if operation == .plex {
        // A bounded parsed index is reused across projections. The 16K-output
        // case is a retained-batch stress test, not a 16K-entry .plexmatch file.
        paths = (1...128).map { "clip\($0).mkv" }
        let idLines = previousIDs.map { id -> String in
            let parts = id.split(separator: "-", maxSplits: 1)
            return "\(parts[0])id: \(parts[1])"
        }
        let mapping = paths.enumerated().map { "ep: S2E\($0.offset + 1): \($0.element)" }
        plex = PlexMatchHints.parse((["title: Shared Series", "year: 2001"] + idLines + mapping).joined(separator: "\n"))
        precondition(plex != nil, "The bounded Plex fixture must parse")
    }
    return Fixture(name: name, description: description, operation: operation,
                   outputCount: count, previous: previous, replacement: replacement,
                   recognized: recognized, plex: plex, paths: paths)
}

let ids = ["tvdb-12345", "tmdb-67890", "imdb-tt1234567"]
let fixtures = [
    fixture("override-inherit-1", "Episode-only hints inherit one series ID", .overriding, previousIDs: Array(ids.prefix(1))),
    fixture("override-inherit-3", "Episode-only hints inherit three series IDs", .overriding, previousIDs: ids),
    fixture("override-first-3", "First sidecar supplies three IDs to empty previous metadata", .overriding, previousIDs: [], replacementIDs: ids),
    fixture("apply-inherit-3", "Hints with no IDs preserve filename IDs", .applying, previousIDs: ids),
    fixture("apply-first-3", "Sidecar IDs applied to a filename without IDs", .applying, previousIDs: [], replacementIDs: ids),
    fixture("plex-1", "Parsed Plex episode mappings inherit one shared series ID", .plex, previousIDs: Array(ids.prefix(1))),
    fixture("plex-3", "Parsed Plex episode mappings inherit three shared series IDs", .plex, previousIDs: ids),
    fixture("plex-3-large", "Retained-projection stress: 16,384 Plex mapping outputs", .plex, previousIDs: ids, count: 16384),
    fixture("override-replace-3", "Control: both sides have IDs and one provider is replaced", .overriding, previousIDs: ids, replacementIDs: ["tvdb-999"]),
    fixture("override-empty", "Control: both sides have no IDs", .overriding, previousIDs: []),
    fixture("override-kind-change", "Control: movie transition clears inherited series IDs", .overriding, previousIDs: ids, kindChange: true),
    fixture("override-inherit-64", "Synthetic stress: 64 explicit IDs, including repeated providers", .overriding,
            previousIDs: (1...64).map { "tvdb-\($0)" }),
]

@inline(never)
func batch(_ fixture: Fixture) -> Outputs {
    var result = Outputs()
    switch fixture.operation {
    case .overriding:
        result.hints.reserveCapacity(fixture.outputCount)
        for _ in 0..<fixture.outputCount { result.hints.append(fixture.replacement.overriding(fixture.previous)) }
    case .applying:
        result.names.reserveCapacity(fixture.outputCount)
        for _ in 0..<fixture.outputCount { result.names.append(fixture.recognized.applying(fixture.replacement)) }
    case .plex:
        result.hints.reserveCapacity(fixture.outputCount)
        for index in 0..<fixture.outputCount {
            result.hints.append(fixture.plex!.hints(for: fixture.paths[index % fixture.paths.count]))
        }
    }
    return result
}

@inline(never)
func consume(_ outputs: Outputs) -> Int {
    var total = outputs.count
    for value in outputs.hints { total &+= value.catalogIDs.count &+ (value.episode ?? 0) &+ (value.year ?? 0) }
    for value in outputs.names { total &+= value.catalogIDs.count &+ (value.episode ?? 0) &+ (value.year ?? 0) }
    return total
}

func pooled<T>(_ body: () -> T) -> T {
#if canImport(ObjectiveC)
    return autoreleasepool(invoking: body)
#else
    return body()
#endif
}

func optional<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
func content(_ value: MediaMetadataHints.Content?) -> Any {
    switch value { case .movie: return "movie"; case .show: return "show"; case .episode: return "episode"; case nil: return NSNull() }
}
func canonical(_ value: MediaMetadataHints) -> [String: Any] {
    ["content": content(value.content), "title": optional(value.title), "year": optional(value.year),
     "season": optional(value.season), "episode": optional(value.episode), "lastEpisode": optional(value.lastEpisode),
     "episodeTitle": optional(value.episodeTitle), "catalogIDs": value.catalogIDs, "sources": value.sources]
}
func canonical(_ value: RecognizedMediaName) -> [String: Any] {
    ["kind": value.kind.rawValue, "title": value.title, "year": optional(value.year),
     "season": optional(value.season), "episode": optional(value.episode), "lastEpisode": optional(value.lastEpisode),
     "airDate": optional(value.airDate), "episodeTitle": optional(value.episodeTitle), "edition": optional(value.edition),
     "catalogIDs": value.catalogIDs, "variant": optional(value.variant), "metadataSources": value.metadataSources]
}
func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
func checksum(_ outputs: Outputs) -> String {
    // FNV-1a is only an output-consumption fingerprint. Full independently
    // expected canonical cases are also compared by the runner's parity gate.
    let data = json(["hints": outputs.hints.map(canonical), "names": outputs.names.map(canonical)])
    var digest: UInt64 = 14695981039346656037
    for byte in data { digest = (digest ^ UInt64(byte)) &* 1099511628211 }
    return String(digest, radix: 16)
}

@inline(never)
func summary(_ fixture: Fixture) -> (checksum: String, consumed: Int, idCount: Int) {
    pooled {
        let outputs = batch(fixture)
        return (checksum(outputs), consume(outputs), outputs.idCount)
    }
}

func parity() -> [String: Any] {
    let pairs: [([String], [String], [String])] = [
        ([], [], []), (ids, [], ids), ([], ids, ids),
        (ids, ["tvdb-999"], ["tmdb-67890", "imdb-tt1234567", "tvdb-999"]),
        (["tvdb-1", "tvdb-1", "tmdb-2"], [], ["tvdb-1", "tvdb-1", "tmdb-2"]),
        (["tvdb-1", "tmdb-2"], ["tvdb-9", "tvdb-9"], ["tmdb-2", "tvdb-9", "tvdb-9"]),
        (["", "-", "--", "tvdb-1", "tvdb"], [], ["", "-", "--", "tvdb-1", "tvdb"]),
        (["", "-", "--", "tvdb-1", "tvdb"], ["tvdb-8"], ["", "-", "--", "tvdb-8"]),
        (["-tvdb-1", "tvdb-2", "tmdb-3"], ["--tvdb-9"], ["tmdb-3", "--tvdb-9"]),
        (["é-1", "e\u{301}-2", "猫-3"], ["é-9"], ["猫-3", "é-9"]),
        (["tvdb-1", "TVDB-2", "🦊-3"], ["TVDB-9"], ["tvdb-1", "🦊-3", "TVDB-9"]),
    ]
    let seed = MediaNameRecognition.recognize(relativePath: "Show.S02E03-E04.mkv")
    var rows: [[String: Any]] = []
    for (old, incoming, expected) in pairs {
        let older = hints(old)
        let newer = hints(incoming)
        let merged = newer.overriding(older)
        let applied = seed.applying(older).applying(newer)
        precondition(merged.catalogIDs == expected && applied.catalogIDs == expected, "Catalog merge contract changed")
        rows.append(["old": old, "incoming": incoming, "expected": expected,
                     "overriding": canonical(merged), "applying": canonical(applied)])
    }
    var older = hints(ids, content: .show)
    older.sources = ["tvshow.nfo", ".plexmatch", ".plexmatch"]
    older.episode = 2; older.lastEpisode = 4
    var newer = hints([], content: .episode)
    newer.episode = 8; newer.sources = ["episode.nfo"]
    let merged = newer.overriding(older)
    precondition(merged.lastEpisode == nil && merged.catalogIDs == ids)
    precondition(merged.sources == [".plexmatch", "episode.nfo", "tvshow.nfo"])
    let movie = hints([], content: .movie)
    precondition(movie.overriding(older).catalogIDs.isEmpty)
    precondition(seed.applying(older).applying(movie).catalogIDs.isEmpty)
    let extra = MediaNameRecognition.recognize(relativePath: "Show-trailer.mkv")
    precondition(extra.applying(older) == extra)
    let unknown = MediaNameRecognition.recognize(relativePath: "Unclassified.mkv")
    precondition(unknown.applying(hints(ids, content: .show)) == unknown)
    // Retained results and their inputs must remain independent after mutation
    // in either direction, even when their ID buffer initially shares storage.
    var retained = newer.overriding(older)
    retained.catalogIDs[0] = "tvdb-999"
    precondition(older.catalogIDs == ids)
    older.catalogIDs[1] = "tmdb-999"
    precondition(retained.catalogIDs[1] == ids[1])
    var incoming = hints(ids)
    let first = incoming.overriding(hints([]))
    incoming.catalogIDs.removeAll()
    precondition(first.catalogIDs == ids)
    let fixtureRows = fixtures.map { fixture -> [String: Any] in
        let outputs = pooled { batch(fixture) }
        precondition(outputs.count == fixture.outputCount)
        return ["case": fixture.name, "resultChecksum": checksum(outputs),
                "outputCount": outputs.count, "idCount": outputs.idCount,
                "firstHint": outputs.hints.first.map(canonical) ?? [:],
                "firstName": outputs.names.first.map(canonical) ?? [:]]
    }
    return ["cases": rows, "fixtures": fixtureRows,
            "checks": ["provider replacement", "ordering and duplicates", "empty and malformed IDs",
                       "Unicode and case-sensitive providers", "kind changes", "range reset", "source ordering",
                       "extras and unclassified show guard", "copy-on-write independence"]]
}

let arguments = Array(CommandLine.arguments.dropFirst())
func argument(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
func selected(_ flag: String) -> Fixture {
    guard let name = argument(flag), let fixture = fixtures.first(where: { $0.name == name }) else {
        fatalError("Unknown or missing fixture for \(flag)")
    }
    return fixture
}

let output: Any
if arguments == ["--list"] {
    output = fixtures.map(\.metadata)
} else if arguments == ["--parity"] {
    output = parity()
} else if arguments.contains("--case") {
    let fixture = selected("--case")
    let iterations = Int(argument("--iterations") ?? "1") ?? 0
    let warmup = Int(argument("--warmup") ?? "2") ?? -1
    precondition(iterations > 0 && warmup >= 0)
    // The helper returns scalars only: release reference outputs before timing.
    let reference = summary(fixture)
    let resultChecksum = reference.checksum
    let expected = reference.consumed
    let idCount = reference.idCount
    for _ in 0..<warmup { precondition(pooled { consume(batch(fixture)) } == expected) }
    var consumed = 0
    let cpuStart = catalog_cpu_nanoseconds()
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { consumed &+= pooled { consume(batch(fixture)) } }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let cpu = catalog_cpu_nanoseconds() - cpuStart
    precondition(consumed == expected &* iterations)
    output = ["case": fixture.name, "iterations": iterations, "outputCount": fixture.outputCount,
              "idCount": idCount, "elapsedNanoseconds": elapsed, "cpuNanoseconds": cpu,
              "resultChecksum": resultChecksum, "consumedCount": consumed]
} else if arguments.contains("--memory") {
    let fixture = selected("--memory")
    let reference = summary(fixture)
    _ = pooled { consume(batch(fixture)) }
    let before = catalog_live_allocated_bytes()
    let retained: UInt64 = pooled {
        let outputs = batch(fixture)
        let bytes = withExtendedLifetime(outputs) { catalog_live_allocated_bytes() }
        precondition(checksum(outputs) == reference.checksum)
        precondition(consume(outputs) == reference.consumed && outputs.idCount == reference.idCount)
        return bytes
    }
    let after = withExtendedLifetime((fixture, reference)) { catalog_live_allocated_bytes() }
#if os(macOS)
    let allocator = "malloc_zone_statistics(NULL).size_in_use"
#else
    let allocator = "glibc mallinfo2.uordblks+hblkhd"
#endif
    output = ["case": fixture.name, "outputCount": fixture.outputCount, "idCount": reference.idCount,
              "resultChecksum": reference.checksum, "heapBeforeBytes": before, "heapRetainedBytes": retained,
              "heapAfterReleaseBytes": after, "retainedBytes": Int64(retained) - Int64(before),
              "releasedRetainedBytes": Int64(after) - Int64(before), "memoryAllocator": allocator]
} else {
    fatalError("Use --list, --parity, --case NAME --iterations N [--warmup N], or --memory NAME")
}
FileHandle.standardOutput.write(json(output))
FileHandle.standardOutput.write(Data([10]))
