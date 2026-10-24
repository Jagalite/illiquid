import Foundation
import Dispatch

// Compiled beside the five complete production source files. No model, parser,
// dictionary layout, or sidecar-reading implementation is substituted here.
private struct Fixture: Decodable {
    let id: String
    let file: String
    let mappings: Int
    let inputBytes: Int
    let keys: [String]
}

private struct CacheFixture: Decodable {
    let id: String
    let root: String
    let files: [String]
    let totalInputBytes: Int
    let sidecarCount: Int
}

private struct Fixtures: Decodable {
    let cases: [Fixture]
    let contract: Fixture
    let cache: CacheFixture
}

private enum Failure: Error { case invalidArguments, invalidFixture(String), missingOwner }

private func value<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }

private func content(_ hint: MediaMetadataHints) -> String? {
    switch hint.content {
    case .movie: "movie"
    case .show: "show"
    case .episode: "episode"
    case nil: nil
    }
}

private func record(_ hint: MediaMetadataHints?) -> Any {
    guard let hint else { return NSNull() }
    return ["content": value(content(hint)), "title": value(hint.title),
            "year": value(hint.year), "season": value(hint.season),
            "episode": value(hint.episode), "lastEpisode": value(hint.lastEpisode),
            "episodeTitle": value(hint.episodeTitle), "catalogIDs": hint.catalogIDs,
            "sources": hint.sources] as [String: Any]
}

private func record(_ name: RecognizedMediaName) -> [String: Any] {
    ["kind": name.kind.rawValue, "title": name.title, "year": value(name.year),
     "season": value(name.season), "episode": value(name.episode),
     "lastEpisode": value(name.lastEpisode), "airDate": value(name.airDate),
     "episodeTitle": value(name.episodeTitle), "edition": value(name.edition),
     "catalogIDs": name.catalogIDs, "variant": value(name.variant),
     "metadataSources": name.metadataSources]
}

// A small observable scalar sink. Exact field values are compared separately in
// the semantic process; timing includes this identical consumer in both builds.
@inline(never) private func consume(_ hint: MediaMetadataHints?) -> UInt64 {
    guard let hint else { return 11 }
    var result = UInt64(hint.title?.utf8.count ?? 0)
    result = result &* 31 &+ UInt64((hint.year ?? -1) + 1)
    result = result &* 31 &+ UInt64((hint.season ?? -1) + 1)
    result = result &* 31 &+ UInt64((hint.episode ?? -1) + 1)
    result = result &* 31 &+ UInt64((hint.lastEpisode ?? -1) + 1)
    result = result &* 31 &+ UInt64(hint.episodeTitle?.utf8.count ?? 0)
    for text in hint.catalogIDs { result = result &* 31 &+ UInt64(text.utf8.count) }
    for text in hint.sources { result = result &* 31 &+ UInt64(text.utf8.count) }
    switch hint.content {
    case .movie: result = result &* 31 &+ 1
    case .show: result = result &* 31 &+ 2
    case .episode: result = result &* 31 &+ 3
    case nil: result = result &* 31
    }
    return result
}

// Only this box owns the measured parsed result/cache. It exists before the
// initial sample and after teardown, so its own fixed allocation is excluded.
private final class Owner {
    var parsed: PlexMatchHints?
    var reader: MediaSidecarReader?

    @inline(never) func install(text: String) throws {
        guard let result = PlexMatchHints.parse(text) else { throw Failure.invalidFixture("parse") }
        parsed = result
    }

    @inline(never) func install(root: URL, files: [URL], expected: Int) throws -> Int {
        let result = MediaSidecarReader()
        for file in files {
            guard try result.recognize(file, within: root).episode != nil else {
                throw Failure.invalidFixture("reader mapping")
            }
        }
        let initialReads = result.filesRead
        for file in files { _ = try result.recognize(file, within: root) }
        guard initialReads == expected, result.filesRead == initialReads else {
            throw Failure.invalidFixture("reader cache/file count")
        }
        reader = result
        return initialReads
    }

    @inline(never) func isLoaded() -> Bool { parsed != nil || reader != nil }
    @inline(never) func validate(key: String) throws -> UInt64 {
        guard let parsed else { throw Failure.missingOwner }
        return consume(parsed.metadata) &+ consume(parsed.episodeHint(for: key, inheritsDescendantMappings: true))
    }

    @inline(never) func validate(root: URL, file: URL) throws -> UInt64 {
        guard let reader else { throw Failure.missingOwner }
        let before = reader.filesRead
        let recognized = try reader.recognize(file, within: root)
        guard reader.filesRead == before, let episode = recognized.episode else {
            throw Failure.invalidFixture("retained cache lookup")
        }
        return UInt64(episode) &+ UInt64(recognized.title.utf8.count)
    }

    @inline(never) func clear() { parsed = nil; reader = nil }
}

private func allocationSample(install: (Owner) throws -> Void,
                              validate: (Owner) throws -> UInt64) throws -> [String: Any] {
    let owner = Owner()
    // Initialize regexes, Foundation, and the allocator probe before sampling.
    try autoreleasepool { try install(owner); _ = try validate(owner); owner.clear() }
    _ = plexmatch_heap_in_use()
    let initial = plexmatch_heap_in_use()
    try autoreleasepool { try install(owner) }
    guard owner.isLoaded() else { throw Failure.missingOwner }
    let checksum = try autoreleasepool { try validate(owner) }
    let held = plexmatch_heap_in_use()
    // Read the actual retained payload after the probe, not only its presence.
    let heldChecksum = try autoreleasepool { try validate(owner) }
    guard heldChecksum == checksum else { throw Failure.invalidFixture("held payload") }
    autoreleasepool { owner.clear() }
    let released = plexmatch_heap_in_use()
    guard !owner.isLoaded() else { throw Failure.invalidFixture("teardown") }
    return withExtendedLifetime(owner) {
        ["initialInUseBytes": initial, "heldInUseBytes": held,
         "releasedInUseBytes": released,
         "releasedBytes": Int64(held) - Int64(released),
         "heldGrowthBytes": Int64(held) - Int64(initial), "payloadChecksum": String(checksum)]
    }
}

@inline(never) private func parseOnce(_ text: String, key: String) throws -> UInt64 {
    guard let parsed = PlexMatchHints.parse(text) else { throw Failure.invalidFixture("timed parse") }
    return consume(parsed.metadata) &+ consume(parsed.episodeHint(for: key, inheritsDescendantMappings: true))
}

@inline(never) private func rawLookup(_ parsed: PlexMatchHints, key: String) -> UInt64 {
    consume(parsed.episodeHint(for: key, inheritsDescendantMappings: true))
}

@inline(never) private func mergedLookup(_ parsed: PlexMatchHints, key: String) -> UInt64 {
    consume(parsed.hints(for: key, defaultSeason: 9))
}

private func timed(_ iterations: Int, operation: () throws -> UInt64) throws -> (UInt64, UInt64) {
    var checksum: UInt64 = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { checksum &+= try autoreleasepool(invoking: operation) }
    return (DispatchTime.now().uptimeNanoseconds - start, checksum)
}

private func benchmark(targetMS: Double, operation: () throws -> UInt64) throws -> [String: Any] {
    var batch = 1
    var calibration = try timed(batch, operation: operation)
    let calibrationTarget = UInt64(min(5, targetMS / 4) * 1_000_000)
    while calibration.0 < calibrationTarget && batch < 65_536 {
        batch *= 2
        calibration = try timed(batch, operation: operation)
    }
    let estimate = targetMS * 1_000_000 * Double(batch) / Double(max(1, calibration.0))
    let iterations = max(1, min(1_000_000, Int(estimate)))
    let (elapsed, checksum) = try timed(iterations, operation: operation)
    return ["iterations": iterations, "elapsedNanoseconds": elapsed,
            "nanosecondsPerOperation": Double(elapsed) / Double(iterations),
            "checksum": String(checksum), "calibrationIterations": batch]
}

private func sample(_ fixture: Fixture, root: URL, targetMS: Double) throws -> [String: Any] {
    let text = try String(contentsOf: root.appendingPathComponent(fixture.file), encoding: .utf8)
    guard text.utf8.count == fixture.inputBytes else { throw Failure.invalidFixture("input bytes") }
    // The exact same input and key buffers stay alive across both heap probes.
    return try withExtendedLifetime(text) {
        let first = fixture.keys.first ?? "missing.mkv"
        let memory = try allocationSample(install: { try $0.install(text: text) },
                                          validate: { try $0.validate(key: first) })
        let parse = try benchmark(targetMS: targetMS) { try parseOnce(text, key: first) }
        guard let parsed = PlexMatchHints.parse(text) else { throw Failure.invalidFixture(fixture.id) }
        var index = 0
        let missingKeys = (0..<16).map { "__missing__\($0).mkv" }
        let miss = try benchmark(targetMS: targetMS) {
            let key = missingKeys[index % missingKeys.count]; index += 1
            return rawLookup(parsed, key: key)
        }
        var timings: [String: Any] = ["parseLookupAndRelease": parse, "rawMissingLookup": miss]
        if !fixture.keys.isEmpty {
            index = 0
            timings["rawSuccessfulLookup"] = try benchmark(targetMS: targetMS) {
                let key = fixture.keys[index % fixture.keys.count]; index += 1
                return rawLookup(parsed, key: key)
            }
            index = 0
            timings["mergedSuccessfulLookup"] = try benchmark(targetMS: targetMS) {
                let key = fixture.keys[index % fixture.keys.count]; index += 1
                return mergedLookup(parsed, key: key)
            }
        }
        return ["scenario": fixture.id, "mappings": fixture.mappings,
                "inputBytes": fixture.inputBytes, "allocation": memory, "timings": timings]
    }
}

private func cacheSample(_ fixture: CacheFixture, root: URL) throws -> [String: Any] {
    let directory = root.appendingPathComponent(fixture.root)
    let files = fixture.files.map { directory.appendingPathComponent($0) }
    var filesRead = 0
    let memory = try withExtendedLifetime(files) {
        try allocationSample(install: { owner in
            filesRead = try owner.install(root: directory, files: files, expected: fixture.sidecarCount)
        }, validate: { try $0.validate(root: directory, file: files[0]) })
    }
    return ["scenario": fixture.id, "sidecarCount": fixture.sidecarCount,
            "inputBytes": fixture.totalInputBytes, "filesRead": filesRead,
            "secondPassAdditionalReads": 0, "allocation": memory, "timings": [:] as [String: Any]]
}

private func semantic(_ fixtures: Fixtures, root: URL) throws -> [String: Any] {
    var cases: [[String: Any]] = []
    for fixture in fixtures.cases + [fixtures.contract] {
        let text = try String(contentsOf: root.appendingPathComponent(fixture.file), encoding: .utf8)
        guard let parsed = PlexMatchHints.parse(text) else { throw Failure.invalidFixture(fixture.id) }
        let observedMappings = fixture.keys.reduce(0) { total, key in
            total + (parsed.episodeHint(for: key, inheritsDescendantMappings: true) == nil ? 0 : 1)
        }
        if fixture.id != fixtures.contract.id,
           observedMappings != fixture.mappings || Set(fixture.keys).count != fixture.mappings {
            throw Failure.invalidFixture("mapping count: " + fixture.id)
        }
        let queries = fixture.keys + ["__missing__.mkv", "child/__missing__.mkv"]
        let results: [[String: Any]] = queries.map { key in
            ["path": key, "raw": record(parsed.episodeHint(for: key, inheritsDescendantMappings: true)),
             "merged": record(parsed.hints(for: key)),
             "defaultSeason": record(parsed.hints(for: key, defaultSeason: 9)),
             "localOnly": record(parsed.hints(for: key, inheritsDescendantMappings: false))]
        }
        let reader = MediaSidecarReader()
        let directory = root.appendingPathComponent(fixture.file).deletingLastPathComponent()
        var recognized: [[String: Any]] = []
        for key in Array(fixture.keys.prefix(3)) + Array(fixture.keys.suffix(1)) + ["__missing__.mkv"] {
            recognized.append(["path": key,
                "result": record(try reader.recognize(directory.appendingPathComponent(key), within: directory))])
        }
        cases.append(["scenario": fixture.id, "observedMappings": observedMappings, "metadata": record(parsed.metadata),
                      "lookups": results, "reader": recognized])
    }
    let cacheRoot = root.appendingPathComponent(fixtures.cache.root)
    let reader = MediaSidecarReader()
    var cacheResults: [[String: Any]] = []
    for path in fixtures.cache.files {
        cacheResults.append(["path": path,
            "result": record(try reader.recognize(cacheRoot.appendingPathComponent(path), within: cacheRoot))])
    }
    guard reader.filesRead == fixtures.cache.sidecarCount else { throw Failure.invalidFixture("semantic cache") }
    return ["schemaVersion": 1, "cases": cases, "cache": cacheResults, "cacheFilesRead": reader.filesRead]
}

@main private enum Main {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else { throw Failure.invalidArguments }
        let manifest = URL(fileURLWithPath: arguments[2])
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: manifest))
        let root = manifest.deletingLastPathComponent()
        let output: [String: Any]
        if arguments[1] == "semantic" {
            output = try semantic(fixtures, root: root)
        } else if arguments[1] == "sample", arguments.count == 5,
                  let targetMS = Double(arguments[4]), targetMS > 0, targetMS <= 1_000 {
            if arguments[3] == fixtures.cache.id {
                output = try cacheSample(fixtures.cache, root: root)
            } else if let fixture = fixtures.cases.first(where: { $0.id == arguments[3] }) {
                output = try sample(fixture, root: root, targetMS: targetMS)
            } else { throw Failure.invalidArguments }
        } else { throw Failure.invalidArguments }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
