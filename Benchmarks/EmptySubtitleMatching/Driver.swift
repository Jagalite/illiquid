import Foundation
import Dispatch

// This driver compiles with the actual seven Foundation-only playlist sources.
// It creates URL values only: fixture setup performs no filesystem operations.
private enum Operation: String {
    case associate
    case makePlaylist
}

private struct Fixture {
    let name: String
    let operation: Operation
    let folderURL: URL
    let mediaURLs: [URL]
    let subtitleURLs: [URL]
    let metadataDates: [URL: Date]
}

private struct MappingEntry: Encodable {
    let mediaURL: String
    let subtitleURLs: [String]
}

private struct ItemReceipt: Encodable {
    let url: String
    let externalSubtitleURLs: [String]
    let dateAddedUnixSeconds: Double?
}

private struct OutputReceipt: Encodable {
    let `case`: String
    let operation: String
    let inputMediaCount: Int
    let inputSubtitleCount: Int
    let mapping: [MappingEntry]?
    let folderURL: String?
    let items: [ItemReceipt]?
}

private struct CancellationReceipt: Encodable {
    let `case`: String
    let mapping: [MappingEntry]
}

private struct DifferentialReport: Encodable {
    let schemaVersion = 1
    let mode = "differential"
    let seed: UInt64
    let caseCount: Int
    let cases: [OutputReceipt]
    let initialCancellation: [CancellationReceipt]
}

private struct BenchmarkReport: Encodable {
    let schemaVersion = 1
    let mode = "benchmark"
    let `case`: String
    let iterations: Int
    let warmupIterations: Int
    let elapsedNanoseconds: UInt64
    let checksum: UInt64
    let warmupChecksum: UInt64
    let perIterationChecksum: UInt64
    let receipt: OutputReceipt
}

private enum DriverError: Error {
    case invalidArguments(String)
    case unexpectedResult(String)
}

private struct DeterministicRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func shuffle<T>(_ input: [T]) -> [T] {
        var result = input
        guard result.count > 1 else { return result }
        for index in stride(from: result.count - 1, through: 1, by: -1) {
            result.swapAt(index, Int(next() % UInt64(index + 1)))
        }
        return result
    }
}

private let differentialSeed: UInt64 = 0x01_11_1D_20_26_10_17

private func folderURL() -> URL {
    URL(fileURLWithPath: "/illiquid-benchmark/subtitle-matching", isDirectory: true)
}

private func fixtureURL(_ name: String) -> URL {
    if name.hasPrefix("https://") || name.hasPrefix("file://") {
        return URL(string: name)!
    }
    return folderURL().appendingPathComponent(name, isDirectory: false)
}

private func fixture(
    _ name: String,
    media: [String],
    subtitles: [String],
    operation: Operation = .associate
) -> Fixture {
    let mediaURLs = media.map(fixtureURL)
    // Fixed, synthetic dates exercise metadata propagation in makePlaylist.
    // This map is prepared outside every measured interval.
    var dates: [URL: Date] = [:]
    if operation == .makePlaylist {
        for (index, url) in mediaURLs.enumerated() where index.isMultiple(of: 5) {
            if let normalized = NormalizedFileURL.normalize(url) {
                dates[normalized] = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            }
        }
    }
    return Fixture(
        name: name, operation: operation, folderURL: folderURL(),
        mediaURLs: mediaURLs, subtitleURLs: subtitles.map(fixtureURL),
        metadataDates: dates
    )
}

private func padded(_ value: Int) -> String {
    let number = String(value)
    return String(repeating: "0", count: max(0, 5 - number.count)) + number
}

private func inventory(
    name: String,
    count: Int,
    subtitleKind: String,
    operation: Operation = .associate
) -> Fixture {
    var random = DeterministicRandom(state: differentialSeed)
    // IDs have the same width at every size; all other filename tokens agree.
    let ids = random.shuffle(Array(0..<count))
    let media = ids.map { "Measured Series S01E\(padded($0)) 1080p WEB-DL x264.mkv" }
    let subtitles: [String]
    switch subtitleKind {
    case "empty":
        subtitles = []
    case "matched":
        subtitles = random.shuffle(ids).map { "Measured Series S01E\(padded($0)).en.srt" }
    case "ambiguous":
        subtitles = ["Measured Series.en.srt"]
    case "unsupported":
        // A nonempty unsupported list must still follow the existing path.
        subtitles = ids.map { "Measured Series S01E\(padded($0)).txt" }
    default:
        preconditionFailure("Unknown fixture subtitle kind: \(subtitleKind)")
    }
    return fixture(name, media: media, subtitles: subtitles, operation: operation)
}

private let benchmarkNames = [
    "empty-0", "empty-1", "empty-32", "empty-250", "empty-1000", "empty-10000",
    "matched-32", "matched-250", "ambiguous-250", "unsupported-250",
    "playlist-empty-250", "playlist-empty-1000", "playlist-matched-250",
]

private func benchmarkFixture(_ name: String) throws -> Fixture {
    switch name {
    case "empty-0", "empty-1", "empty-32", "empty-250", "empty-1000", "empty-10000":
        return inventory(name: name, count: Int(name.dropFirst("empty-".count))!, subtitleKind: "empty")
    case "matched-32", "matched-250":
        return inventory(name: name, count: Int(name.dropFirst("matched-".count))!, subtitleKind: "matched")
    case "ambiguous-250":
        return inventory(name: name, count: 250, subtitleKind: "ambiguous")
    case "unsupported-250":
        return inventory(name: name, count: 250, subtitleKind: "unsupported")
    case "playlist-empty-250", "playlist-empty-1000":
        return inventory(name: name, count: Int(name.dropFirst("playlist-empty-".count))!,
                         subtitleKind: "empty", operation: .makePlaylist)
    case "playlist-matched-250":
        return inventory(name: name, count: 250, subtitleKind: "matched", operation: .makePlaylist)
    default:
        throw DriverError.invalidArguments("Unknown case: \(name). Cases: \(benchmarkNames.joined(separator: ", "))")
    }
}

private func mappingReceipt(_ associations: [URL: [URL]]) -> [MappingEntry] {
    associations.map {
        MappingEntry(mediaURL: $0.key.absoluteString, subtitleURLs: $0.value.map(\.absoluteString))
    }.sorted { $0.mediaURL.utf8.lexicographicallyPrecedes($1.mediaURL.utf8) }
}

// Non-inlined consumption keeps an observable dependency on each returned model.
// Benchmark cases give every media key the same subtitle count, so dictionary
// hash order does not change this inexpensive checksum. Full mappings are checked
// separately outside the timer, including every subtitle's returned order.
@inline(never)
private func consumeAssociations(_ value: [URL: [URL]]) -> UInt64 {
    UInt64(value.count) &* 131 &+ UInt64(value.first?.value.count ?? 0)
}

@inline(never)
private func consumePlaylist(_ value: FolderPlaylist) -> UInt64 {
    UInt64(value.count) &* 131 &+ UInt64(value.items.first?.externalSubtitleURLs.count ?? 0)
}

@inline(never)
private func associateOnce(_ input: Fixture) -> UInt64 {
    let value = ExternalSubtitleMatcher.associate(
        subtitleURLs: input.subtitleURLs, with: input.mediaURLs
    )
    return consumeAssociations(value)
}

@inline(never)
private func playlistOnce(_ input: Fixture) -> UInt64 {
    let value = FolderPlaylistDiscovery.makePlaylist(
        folderURL: input.folderURL, mediaURLs: input.mediaURLs,
        subtitleURLs: input.subtitleURLs, metadataDates: input.metadataDates
    )
    return consumePlaylist(value)
}

private func runIterations(_ input: Fixture, iterations: Int) -> UInt64 {
    var checksum: UInt64 = 0
    switch input.operation {
    case .associate:
        for _ in 0..<iterations { checksum &+= associateOnce(input) }
    case .makePlaylist:
        for _ in 0..<iterations { checksum &+= playlistOnce(input) }
    }
    return checksum
}

private func evaluate(_ input: Fixture) throws -> (receipt: OutputReceipt, signature: UInt64) {
    switch input.operation {
    case .associate:
        let value = ExternalSubtitleMatcher.associate(
            subtitleURLs: input.subtitleURLs, with: input.mediaURLs
        )
        guard Set(value.keys) == Set(input.mediaURLs) else {
            throw DriverError.unexpectedResult("Original media keys were not retained in \(input.name)")
        }
        return (
            OutputReceipt(case: input.name, operation: input.operation.rawValue,
                          inputMediaCount: input.mediaURLs.count, inputSubtitleCount: input.subtitleURLs.count,
                          mapping: mappingReceipt(value), folderURL: nil, items: nil),
            consumeAssociations(value)
        )
    case .makePlaylist:
        let value = FolderPlaylistDiscovery.makePlaylist(
            folderURL: input.folderURL, mediaURLs: input.mediaURLs,
            subtitleURLs: input.subtitleURLs, metadataDates: input.metadataDates
        )
        return (
            OutputReceipt(case: input.name, operation: input.operation.rawValue,
                          inputMediaCount: input.mediaURLs.count, inputSubtitleCount: input.subtitleURLs.count,
                          mapping: nil, folderURL: value.folderURL.absoluteString,
                          items: value.items.map {
                              ItemReceipt(url: $0.url.absoluteString,
                                          externalSubtitleURLs: $0.externalSubtitleURLs.map(\.absoluteString),
                                          dateAddedUnixSeconds: $0.dateAdded?.timeIntervalSince1970)
                          }),
            consumePlaylist(value)
        )
    }
}

private func differentialFixtures() throws -> [Fixture] {
    var result = try benchmarkNames.map(benchmarkFixture)
    result += [
        fixture("empty-duplicate-and-unsupported-media",
                media: ["Movie.mkv", "Movie.mkv", "notes.txt", "cover.jpg",
                        "https://example.invalid/Movie.mkv", "---.mkv", "Café.mkv", "Cafe\u{0301}.mkv"],
                subtitles: []),
        fixture("empty-unsupported-media",
                media: ["notes.txt", "cover.jpg", "https://example.invalid/Feature.mp4"], subtitles: []),
        fixture("subtitles-without-media", media: [],
                subtitles: ["Feature.en.srt", "Feature.fr.vtt", "Feature.txt"]),
        fixture("subtitle-order-and-duplicates", media: ["Feature.mkv"],
                subtitles: ["Feature.fr.srt", "Feature.en.forced.srt", "Feature.en.srt",
                            "Feature.en.srt", "Feature.10.ass", "Feature.2.ass"]),
        fixture("title-language-suffix",
                media: ["The Last.mkv", "The Last of Us.mkv", "It.mkv", "Film US.mkv"],
                subtitles: ["The Last of Us.en.srt", "The Last.en.srt", "It.en.srt", "Film US.srt"]),
        fixture("unicode-folding",
                media: ["Amélie.mkv", "アニメ.mp4", "Мелодия.mkv", "ＡＢＣＤ.mkv", "Cafe\u{0301}.mov"],
                subtitles: ["Amelie.en.srt", "アニメ.ja.srt", "Мелодия.ru.vtt", "ABCD.en.srt", "Café.fr.ass"]),
        fixture("ambiguity-and-specificity",
                media: ["Series 01.mkv", "Series 02.mp4", "Series Extras.mkv"],
                subtitles: ["Series.en.srt", "Series 01.en.srt", "Series 02.fr.vtt", "Series.txt",
                            "https://example.invalid/Series%2001.en.srt"]),
        fixture("empty-token-stems", media: [".mkv", "---.mkv", "a.mkv"],
                subtitles: [".srt", "---.srt", "a.srt", "a.en.srt"]),
        fixture("duplicate-inputs", media: ["Feature.mkv", "Feature.mkv", "Other.mkv"],
                subtitles: ["Feature.en.srt", "Feature.en.srt", "Other.en.vtt"]),
        fixture("extension-classification", media: ["Feature.MKV", "Other.MP4", "Notes.txt"],
                subtitles: ["Feature.en.SRT", "Feature.fr.VTT", "Feature.de.SSA", "Feature.ja.ASS",
                            "Feature.en.IDX", "Feature.en.sub", "Other.en.srt", "Notes.en.srt"]),
        fixture("original-url-identity",
                media: ["file:///illiquid-benchmark/subtitle-matching/A/../Feature.mkv",
                        "file://localhost/illiquid-benchmark/subtitle-matching/Feature.mkv", "Feature.mkv"],
                subtitles: []),
        fixture("playlist-normalization-and-metadata",
                media: ["file:///illiquid-benchmark/subtitle-matching/A/../Feature.mkv",
                        "Feature.mkv", "Cafe\u{0301}.mkv", "Café.mkv", "Episode 10.mp4", "Episode 2.mp4",
                        "https://example.invalid/Feature.mp4"],
                subtitles: ["Feature.en.srt", "Café.fr.srt", "Episode 2.en.vtt"], operation: .makePlaylist),
        fixture("playlist-empty", media: [], subtitles: [], operation: .makePlaylist),
    ]

    var random = DeterministicRandom(state: differentialSeed)
    let titles = ["Measured Series", "Café du Matin", "The Last of Us", "東京物語", "Ｆｅａｔｕｒｅ", "Мелодия"]
    for index in 0..<64 {
        let count = Int(random.next() % 33)
        var media: [String] = []
        var subtitles: [String] = []
        for item in 0..<count {
            let title = titles[Int(random.next() % UInt64(titles.count))]
            let stem = "\(title) S01E\(padded(item))"
            let mediaName = stem + (item.isMultiple(of: 7) ? ".txt" : " 1080p WEB-DL x264.mkv")
            media.append(mediaName)
            if item.isMultiple(of: 11) { media.append(mediaName) }
            switch index % 4 {
            case 0:
                break
            case 1:
                subtitles.append(stem + ".en.srt")
            case 2:
                if item.isMultiple(of: 3) { subtitles.append(title + ".en.srt") }
            default:
                subtitles.append(stem + (item.isMultiple(of: 2) ? ".fr.vtt" : ".txt"))
            }
        }
        result.append(fixture("generated-\(padded(index))",
                              media: random.shuffle(media), subtitles: random.shuffle(subtitles)))
    }
    return result
}

private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
}

@main
private enum Driver {
    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 2, arguments[1] == "differential" {
            let inputs = try differentialFixtures()
            var receipts: [OutputReceipt] = []
            var cancellation: [CancellationReceipt] = []
            for input in inputs {
                receipts.append(try evaluate(input).receipt)
                if input.operation == .associate {
                    let value = ExternalSubtitleMatcher.associate(
                        subtitleURLs: input.subtitleURLs, with: input.mediaURLs, isCancelled: { true }
                    )
                    guard value.isEmpty else {
                        throw DriverError.unexpectedResult("Initial cancellation was ignored in \(input.name)")
                    }
                    cancellation.append(CancellationReceipt(case: input.name, mapping: mappingReceipt(value)))
                }
            }
            try emit(DifferentialReport(seed: differentialSeed, caseCount: receipts.count,
                                        cases: receipts, initialCancellation: cancellation))
            return
        }

        guard arguments.count == 4, arguments[1] == "benchmark",
              let iterations = Int(arguments[3]), iterations > 0 else {
            throw DriverError.invalidArguments("Usage: Driver differential | Driver benchmark CASE ITERATIONS")
        }
        let input = try benchmarkFixture(arguments[2])
        let warmupIterations = 3
        let warmupChecksum = runIterations(input, iterations: warmupIterations)
        let start = DispatchTime.now().uptimeNanoseconds
        let checksum = runIterations(input, iterations: iterations)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        // Receipt generation, sorting, URL serialization, and JSON encoding are untimed.
        // The returned model is destroyed inside each timed non-inlined call.
        let output = try evaluate(input)
        guard checksum == output.signature &* UInt64(iterations),
              warmupChecksum == output.signature &* UInt64(warmupIterations) else {
            throw DriverError.unexpectedResult("Iteration output checksum changed in \(input.name)")
        }
        try emit(BenchmarkReport(case: input.name, iterations: iterations,
                                 warmupIterations: warmupIterations, elapsedNanoseconds: elapsed,
                                 checksum: checksum, warmupChecksum: warmupChecksum,
                                 perIterationChecksum: output.signature, receipt: output.receipt))
    }
}
