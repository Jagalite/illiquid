import Foundation
import Dispatch
@testable import IlliquidCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct Workload: Codable {
    let name: String
    let batch_size: Int
    let kind: String
}

private let workloads = [
    Workload(name: "labels-episodes", batch_size: 128, kind: "episodes"),
    Workload(name: "labels-ranges", batch_size: 128, kind: "ranges"),
    Workload(name: "labels-titles", batch_size: 128, kind: "titles"),
    Workload(name: "labels-unicode", batch_size: 128, kind: "unicode"),
    Workload(name: "labels-mixed", batch_size: 128, kind: "mixed"),
    Workload(name: "labels-mixed-1024", batch_size: 1024, kind: "mixed"),
    Workload(name: "labels-movies-control", batch_size: 128, kind: "movies"),
    Workload(name: "labels-dates-control", batch_size: 128, kind: "dates"),
    Workload(name: "labels-unknown-control", batch_size: 128, kind: "unknown"),
    Workload(name: "labels-negative-control", batch_size: 128, kind: "negative"),
    Workload(name: "labels-overflow-control", batch_size: 128, kind: "overflow"),
    Workload(name: "labels-positive-int32", batch_size: 128, kind: "positive-int32"),
    Workload(name: "recognize-episodes", batch_size: 128, kind: "recognize-episodes"),
    Workload(name: "recognize-mixed", batch_size: 128, kind: "recognize-mixed"),
    Workload(name: "recognize-movies-control", batch_size: 128, kind: "recognize-movies"),
]

private func media(_ index: Int, kind: String) -> RecognizedMediaName {
    if kind == "mixed" {
        return media(index, kind: ["episodes", "ranges", "titles", "movies", "dates", "unknown"][index % 6])
    }
    var type: RecognizedMediaName.Kind = .episode
    var season: Int? = index % 12
    var episode: Int? = index % 10000
    var last: Int?
    var date: String?
    var title: String?
    switch kind {
    case "ranges": last = (episode ?? 0) + 2
    case "titles": title = "An episode title \(index)"
    case "unicode":
        title = String(repeating: "日本語 · Cafe\u{301} · 🐈 ", count: 8) + "\(index)"
        last = index % 3 == 0 ? (episode ?? 0) + 1 : nil
    case "movies": type = .movie
    case "unknown": type = index % 2 == 0 ? .unknown : .extra
    case "dates":
        date = index % 4 == 0 ? "" : "2026-10-\(index % 28 + 1)"
        season = Int.max; episode = Int.min; last = Int.max
        title = index % 2 == 0 ? nil : "Date-based episode \(index)"
    case "negative":
        season = -1 - index % 4; episode = -index - 1
        last = index % 2 == 0 ? -index - 2 : nil
    case "overflow":
        let values = [Int.min, Int.max, Int(Int32.max) + 1, Int(Int32.min) - 1,
                      Int(UInt32.max), Int(UInt32.max) + 1, Int(UInt32.max) + 2]
        season = values[index % values.count]
        episode = values[(index + 1) % values.count]
        last = index % 2 == 0 ? values[(index + 2) % values.count] : nil
    case "positive-int32":
        season = Int(Int32.max) - index
        episode = Int(Int32.max) - index * 7
        last = Int(Int32.max) - index * 3
    default: break
    }
    return RecognizedMediaName(kind: type, title: "Series or movie \(index)",
        year: index % 2 == 0 ? 2020 : nil, season: season, episode: episode,
        lastEpisode: last, airDate: date, episodeTitle: title, edition: nil,
        catalogIDs: [], variant: nil)
}

private struct Fixture {
    let values: [RecognizedMediaName]
    let paths: [String]
    init(_ workload: Workload) {
        if workload.kind.hasPrefix("recognize-") {
            values = []
            paths = (0..<workload.batch_size).map { index in
                let kind = workload.kind == "recognize-mixed" ? index % 3
                    : workload.kind == "recognize-movies" ? 1 : 0
                switch kind {
                case 1: return "Movies/Film \(index) (2020)/Film \(index) (2020).mkv"
                case 2: return "Shows/Series \(index)/Series \(index).2026-10-20.Title.mkv"
                default: return "Shows/Series \(index)/Season \(index % 9)/Series \(index).S\(index % 9)E\(index % 100).Episode title.mkv"
                }
            }
        } else {
            values = (0..<workload.batch_size).map { media($0, kind: workload.kind) }
            paths = []
        }
    }
}

// The computed property and recognizer are opaque calls into the separately
// compiled production Core module. Do not enable cross-module optimization.
@inline(never)
private func evaluate(_ fixture: Fixture) -> [String] {
    if !fixture.paths.isEmpty {
        return fixture.paths.map { MediaNameRecognition.recognize(relativePath: $0).displayName }
    }
    return fixture.values.map(\.displayName)
}

private func checksum(_ labels: [String]) -> Int64 {
    labels.enumerated().reduce(Int64(0)) { $0 + Int64($1.offset + 1) * Int64($1.element.utf8.count) }
}

private struct Receipt: Codable {
    let name: String
    let labels: [String]
    let checksum: Int64
    init(_ name: String, _ labels: [String]) {
        self.name = name; self.labels = labels
        checksum = labels.enumerated().reduce(Int64(0)) {
            $0 + Int64($1.offset + 1) * Int64($1.element.utf8.count)
        }
    }
}

private func verification() -> [Receipt] {
    var receipts = workloads.map { Receipt($0.name, evaluate(Fixture($0))) }
    let boundaries: [Int?] = [nil, Int.min, Int(Int32.min) - 1, Int(Int32.min), -100, -10, -1,
        0, 1, 9, 10, 99, 100, 999, 9999, Int(Int32.max), Int(Int32.max) + 1,
        Int(UInt32.max), Int(UInt32.max) + 1, Int(UInt32.max) + 2, Int.max]
    var labels: [String] = []
    for season in boundaries {
        for episode in boundaries {
            for last in [Int?.none, 0, Int.max] {
                let value = RecognizedMediaName(kind: .episode, title: "Series", year: nil,
                    season: season, episode: episode, lastEpisode: last, airDate: nil,
                    episodeTitle: "Cafe\u{301} · 日本語 🐈", edition: nil, catalogIDs: [], variant: nil)
                labels.append(value.displayName)
            }
        }
    }
    receipts.append(Receipt("integer-boundaries", labels))
    return receipts
}

private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
}

@inline(__always)
private func withTemporaryObjects<T>(_ body: () -> T) -> T {
    #if canImport(ObjectiveC)
    return autoreleasepool(invoking: body)
    #else
    return body()
    #endif
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private struct Measurement: Codable {
    let `case`: String
    let iterations: Int
    let labels_per_iteration: Int
    let wall_ns: UInt64
    let cpu_ns: UInt64
    let checksum: Int64
    let expected_checksum: Int64
    let postflight_matches: Bool
}

private func measure(_ workload: Workload, iterations: Int) -> Measurement {
    let fixture = Fixture(workload)
    let expected = evaluate(fixture)
    let expectedChecksum = checksum(expected)
    for _ in 0..<16 { withTemporaryObjects { _ = checksum(evaluate(fixture)) } }
    var total: Int64 = 0
    let startCPU = cpuNanoseconds(), startWall = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        total += withTemporaryObjects { checksum(evaluate(fixture)) }
    }
    let wall = DispatchTime.now().uptimeNanoseconds - startWall
    let cpu = cpuNanoseconds() - startCPU
    let actualBytes = evaluate(fixture).map { Array($0.utf8) }
    return Measurement(case: workload.name, iterations: iterations, labels_per_iteration: expected.count,
        wall_ns: wall, cpu_ns: cpu, checksum: total, expected_checksum: expectedChecksum * Int64(iterations),
        postflight_matches: actualBytes == expected.map { Array($0.utf8) })
}

@main
private enum Main {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--list"] { try emit(workloads); return }
        if args == ["--verify"] { try emit(verification()); return }
        if args.count == 3, args[0] == "--measure",
           let workload = workloads.first(where: { $0.name == args[1] }),
           let iterations = Int(args[2]), iterations > 0, iterations <= 1_000_000 {
            try emit(measure(workload, iterations: iterations)); return
        }
        FileHandle.standardError.write(Data("Usage: EpisodeDisplayNameProbe --list | --verify | --measure NAME ITERATIONS\n".utf8))
        exit(2)
    }
}
