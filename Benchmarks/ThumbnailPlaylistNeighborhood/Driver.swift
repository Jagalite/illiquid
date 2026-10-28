import Foundation
import Dispatch
import IlliquidCore
import IlliquidApp
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct Workload: Codable {
    let name: String
    let mode: String
    let playlist_size: Int
    let position: String
    let discovered_count: Int
    let visible_count: Int
    let recent_count: Int

    init(_ mode: String, _ size: Int, _ position: String, pool: String = "empty") {
        self.mode = mode
        playlist_size = size
        self.position = position
        switch pool {
        case "browser":
            discovered_count = 256; visible_count = 24; recent_count = 16
        case "full":
            discovered_count = 2048; visible_count = 48; recent_count = 128
        default:
            discovered_count = 0; visible_count = 0; recent_count = 0
        }
        name = "\(mode)-\(size)-\(position)-\(pool)"
    }
}

private let workloads: [Workload] = {
    var result = [Workload("neighborhood", 0, "nil"),
                  Workload("neighborhood", 1, "first"),
                  Workload("neighborhood", 8, "middle")]
    for size in [32, 1000, 10000] {
        for position in ["first", "middle", "last", "missing", "nil"] {
            result.append(Workload("neighborhood", size, position))
        }
    }
    for position in ["first", "last", "missing", "nil"] {
        result.append(Workload("neighborhood", 50000, position))
    }
    result += [Workload("candidates", 0, "nil"),
               Workload("candidates", 1, "first"),
               Workload("candidates", 8, "middle")]
    for size in [1000, 10000] {
        for position in ["first", "middle", "last", "missing", "nil"] {
            result.append(Workload("candidates", size, position))
        }
    }
    for pool in ["browser", "full"] {
        for position in ["first", "last", "nil"] {
            result.append(Workload("candidates", 10000, position, pool: pool))
        }
    }
    return result
}()

private let fixedNow = Date(timeIntervalSince1970: 2_000_000)

private struct Fixture {
    let items: [FolderPlaylistItem]
    let current: URL?
    let visible: Set<URL>
    let discovered: [URL]
    let recent: [URL: Date]

    init(_ workload: Workload) {
        let subtitle = URL(fileURLWithPath: "/media/thumbnail-neighborhood/subtitles/English.srt")
        items = (0..<workload.playlist_size).map { index in
            FolderPlaylistItem(
                url: URL(fileURLWithPath: "/media/thumbnail-neighborhood/series-\(index / 100)/episode-\(index).mkv"),
                externalSubtitleURLs: index % 8 == 0 ? [subtitle] : [],
                dateAdded: Date(timeIntervalSince1970: Double(index + 1_000_000)))
        }
        switch workload.position {
        case "first": current = items.first?.url
        case "middle": current = items.isEmpty ? nil : items[items.count / 2].url
        case "last": current = items.last?.url
        case "missing": current = URL(fileURLWithPath: "/media/thumbnail-neighborhood/missing.mkv")
        default: current = nil
        }
        let playlist = items
        discovered = (0..<workload.discovered_count).map { index in
            if !playlist.isEmpty && index % 3 == 0 { return playlist[(index * 7) % playlist.count].url }
            return URL(fileURLWithPath: "/media/thumbnail-neighborhood/browser/video-\(index).mkv")
        }
        visible = Set(discovered.prefix(workload.visible_count))
        var history: [URL: Date] = [:]
        for index in 0..<workload.recent_count {
            let url = index % 2 == 0 && !playlist.isEmpty
                ? playlist[(index * 11) % playlist.count].url
                : URL(fileURLWithPath: "/media/thumbnail-neighborhood/history/video-\(index).mkv")
            history[url] = fixedNow.addingTimeInterval(-Double(index * 3600))
        }
        recent = history
    }

    init(items: [FolderPlaylistItem], current: URL?, visible: Set<URL> = [],
         discovered: [URL] = [], recent: [URL: Date] = [:]) {
        self.items = items; self.current = current; self.visible = visible
        self.discovered = discovered; self.recent = recent
    }

    func neighborhood() -> ThumbnailNeighborhoodProbe.Result {
        ThumbnailNeighborhoodProbe.neighborhood(items, current: current)
    }

    func candidates() -> [ThumbnailPolicy.Candidate] {
        ThumbnailNeighborhoodProbe.candidates(items, current: current, visible: visible,
                                             discovered: discovered, recent: recent)
    }
}

private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
}

private struct URLReceipt: Codable, Equatable {
    let absolute: String
    let relative: String
    let base: String?
    init(_ url: URL) {
        absolute = url.absoluteString; relative = url.relativeString; base = url.baseURL?.absoluteString
    }
}

private struct CandidateReceipt: Codable, Equatable {
    let url: URLReceipt
    let lastUsed: Double?
    let visible: Bool
    let distance: Int?
    init(_ candidate: ThumbnailPolicy.Candidate) {
        url = URLReceipt(candidate.url)
        lastUsed = candidate.lastUsed?.timeIntervalSince1970
        visible = candidate.isVisible; distance = candidate.neighborDistance
    }
}

private struct VerificationReceipt: Codable {
    struct Distance: Codable { let url: URLReceipt; let distance: Int }
    let name: String
    let input_count: Int
    let current: URLReceipt?
    let neighbors: [URLReceipt]
    let distances: [Distance]
    let candidates: [CandidateReceipt]
    let ranked: [[URLReceipt]]

    init(_ name: String, _ fixture: Fixture) {
        let plan = fixture.neighborhood()
        let candidates = fixture.candidates()
        self.name = name; input_count = fixture.items.count
        current = fixture.current.map(URLReceipt.init)
        neighbors = plan.urls.map(URLReceipt.init)
        distances = plan.distances.map { Distance(url: URLReceipt($0.key), distance: $0.value) }
            .sorted { lhs, rhs in
                if lhs.url.absolute != rhs.url.absolute { return lhs.url.absolute < rhs.url.absolute }
                if lhs.url.relative != rhs.url.relative { return lhs.url.relative < rhs.url.relative }
                return (lhs.url.base ?? "") < (rhs.url.base ?? "")
            }
        self.candidates = candidates.map(CandidateReceipt.init)
        ranked = ThumbnailPreferences.Priority.allCases.map { priority in
            var settings = ThumbnailPreferences()
            settings.priority = priority
            return ThumbnailPolicy.ranked(candidates, current: fixture.current,
                folder: URL(fileURLWithPath: "/media/thumbnail-neighborhood/browser", isDirectory: true),
                now: fixedNow, preferences: settings, maximumCount: candidates.count).map(URLReceipt.init)
        }
    }
}

private struct RawItem: Encodable {
    let url: URL
    let externalSubtitleURLs: [URL] = []
}

private func verification() throws -> [VerificationReceipt] {
    var result = workloads.map { VerificationReceipt($0.name, Fixture($0)) }
    let pool = (0..<25).map {
        FolderPlaylistItem(url: URL(fileURLWithPath: "/media/thumbnail-neighborhood/duplicate-\($0).mkv"))
    }
    for count in 0...24 {
        let items = (0..<count).map { pool[($0 * 7 + count) % 11] }
        let queries: [URL?] = [nil, pool[24].url] + items.map { Optional($0.url) }
        for (queryIndex, current) in queries.enumerated() {
            let fixture = Fixture(items: items, current: current, visible: Set(items.prefix(3).map(\.url)),
                discovered: Array(items.reversed().prefix(8).map(\.url)),
                recent: [pool[0].url: fixedNow, pool[1].url: fixedNow.addingTimeInterval(-900_000)])
            result.append(VerificationReceipt("duplicates-\(count)-query-\(queryIndex)", fixture))
        }
    }
    let rawURLs = [
        URL(string: "file:///media/thumbnail-neighborhood/nested/../episode.mkv")!,
        URL(fileURLWithPath: "/media/thumbnail-neighborhood/episode.mkv"),
        URL(string: "https://example.test/video.mkv?track=1#t=2")!,
        URL(fileURLWithPath: "/media/thumbnail-neighborhood/Café/日本語 第1話.mkv"),
        URL(fileURLWithPath: "/media/thumbnail-neighborhood/Cafe\u{301}/日本語 第1話.mkv"),
        URL(string: "episode.mkv", relativeTo: URL(fileURLWithPath: "/media/thumbnail-neighborhood/", isDirectory: true))!,
    ]
    let decoded = try rawURLs.map { url in
        try JSONDecoder().decode(FolderPlaylistItem.self, from: JSONEncoder().encode(RawItem(url: url)))
    }
    for (index, item) in decoded.enumerated() {
        result.append(VerificationReceipt("decoded-url-\(index)", Fixture(items: decoded,
            current: item.url, visible: [item.url],
            discovered: decoded.reversed().map(\.url), recent: [item.url: fixedNow])))
    }
    return result
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

@inline(__always)
private func signature(_ result: ThumbnailNeighborhoodProbe.Result) -> Int64 {
    Int64(17 + result.urls.count * 31 + result.distances.count * 7 + result.distances.values.reduce(0, +))
}

@inline(__always)
private func signature(_ result: [ThumbnailPolicy.Candidate]) -> Int64 {
    Int64(17 + result.count * 31 + (result.first?.neighborDistance ?? -1)
          + (result.last?.neighborDistance ?? -1))
}

private struct Measurement: Codable {
    let `case`: String
    let iterations: Int
    let wall_ns: UInt64
    let cpu_ns: UInt64
    let checksum: Int64
    let expected_checksum: Int64
    let output_count: Int
    let postflight_matches: Bool
}

private func measure(_ workload: Workload, iterations: Int) -> Measurement {
    precondition(iterations > 0 && iterations <= 10_000_000)
    let fixture = Fixture(workload)
    var checksum: Int64 = 0
    let expectedPerCall: Int64
    let outputCount: Int
    let wall: UInt64
    let cpu: UInt64
    let matches: Bool
    if workload.mode == "neighborhood" {
        let expected = fixture.neighborhood()
        expectedPerCall = signature(expected)
        outputCount = expected.urls.count
        for _ in 0..<16 { withTemporaryObjects { _ = signature(fixture.neighborhood()) } }
        let startCPU = cpuNanoseconds(), startWall = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            checksum &+= withTemporaryObjects { signature(fixture.neighborhood()) }
        }
        wall = DispatchTime.now().uptimeNanoseconds - startWall
        cpu = cpuNanoseconds() - startCPU
        let after = fixture.neighborhood()
        matches = after.urls.map(URLReceipt.init) == expected.urls.map(URLReceipt.init)
            && after.distances == expected.distances
    } else {
        let expected = fixture.candidates()
        expectedPerCall = signature(expected)
        outputCount = expected.count
        for _ in 0..<16 { withTemporaryObjects { _ = signature(fixture.candidates()) } }
        let startCPU = cpuNanoseconds(), startWall = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            checksum &+= withTemporaryObjects { signature(fixture.candidates()) }
        }
        wall = DispatchTime.now().uptimeNanoseconds - startWall
        cpu = cpuNanoseconds() - startCPU
        matches = fixture.candidates().map(CandidateReceipt.init) == expected.map(CandidateReceipt.init)
    }
    return Measurement(case: workload.name, iterations: iterations, wall_ns: wall, cpu_ns: cpu,
        checksum: checksum, expected_checksum: expectedPerCall * Int64(iterations),
        output_count: outputCount, postflight_matches: matches)
}

@main
private enum Main {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--list"] { try emit(workloads); return }
        if arguments == ["--verify"] { try emit(verification()); return }
        if arguments.count == 3, arguments[0] == "--measure",
           let workload = workloads.first(where: { $0.name == arguments[1] }),
           let iterations = Int(arguments[2]), iterations > 0, iterations <= 10_000_000 {
            try emit(measure(workload, iterations: iterations)); return
        }
        FileHandle.standardError.write(Data("Usage: ThumbnailNeighborhoodProbe --list | --verify | --measure NAME ITERATIONS\n".utf8))
        exit(2)
    }
}
