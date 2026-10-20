import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// One unchanged driver is compiled with each exact production-source snapshot.
private struct CaseSpec: Decodable {
    let id: String
    let scope: String
    let size: Int
    let pattern: String
    let order: String
    let subtitles: Int
}

private struct Request: Decodable {
    let operation: String
    let spec: CaseSpec?
    let iterations: Int?
}

private struct Generator {
    var state: UInt64 = 0x106A_ECDF_1978_0217
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private let fixtureRoot = URL(fileURLWithPath: "/Volumes/IlliquidBenchmark/Media", isDirectory: true)

// Input arrangement is independent of all production sorting entry points.
private func referenceLess(_ lhs: URL, _ rhs: URL) -> Bool {
    switch lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) {
    case .orderedAscending: return true
    case .orderedDescending: return false
    case .orderedSame:
        return lhs.path.compare(rhs.path, options: [.literal]) == .orderedAscending
    }
}

private func edgeURLs() -> [URL] {
    let base = URL(string: "file:///Volumes/IlliquidBenchmark/Media/")!
    return [
        URL(fileURLWithPath: "/Volumes/IlliquidBenchmark/Media/Episode 2.mkv"),
        URL(fileURLWithPath: "/Volumes/IlliquidBenchmark/Media/episode 2.mkv"),
        URL(fileURLWithPath: "/Volumes/IlliquidBenchmark/Media/Episode 02.mkv"),
        URL(fileURLWithPath: "/Volumes/IlliquidBenchmark/Media/Épisode 2.mkv"),
        URL(fileURLWithPath: "/Volumes/IlliquidBenchmark/Media/Café 1.mkv"),
        URL(fileURLWithPath: "/Volumes/IlliquidBenchmark/Media/Cafe\u{301} 1.mkv"),
        URL(fileURLWithPath: "/another/Episode 2.mkv"),
        URL(fileURLWithPath: "/Volumes/IlliquidBenchmark/Media/Episode 2.mkv"),
        URL(fileURLWithPath: "/Volumes/IlliquidBenchmark/Media/Unused/../Episode 2.mkv"),
        URL(fileURLWithPath: "/Volumes/IlliquidBenchmark/Media/Episode%202.mkv"),
        URL(string: "Episode%202.mkv", relativeTo: base)!,
        URL(string: "./Episode%202.mkv", relativeTo: base)!,
        URL(string: "file://localhost/Volumes/IlliquidBenchmark/Media/Episode%202.mkv")!,
        URL(string: "file://LOCALHOST/Volumes/IlliquidBenchmark/Media/Episode%203.mkv")!,
        URL(string: "file://remote.example/Media/Episode%202.mkv")!,
        URL(string: "https://example.invalid/Media/Episode%202.mkv?token=1#chapter")!,
        URL(string: "relative/Episode%202.mkv")!,
        URL(fileURLWithPath: "/Volumes/IlliquidBenchmark/Media/Episode 2#.mkv"),
        // First normalization/sort yields M, N, Z/../A; item normalization
        // exposes A. The baseline final sort must still restore A, M, N.
        URL(string: "file:///tmp/Z/%2E%2E/A/Same.mkv")!,
        URL(string: "file:///tmp/M/Same.mkv")!,
        URL(string: "file:///tmp/N/Same.mkv")!,
    ]
}

private func fixture(_ spec: CaseSpec) -> [URL] {
    var urls: [URL]
    if spec.pattern == "edge" {
        urls = edgeURLs()
    } else {
        let titles = ["Episode", "Épisode", "Café", "Cafe\u{301}", "第", "海", "Ångström", "Österreich"]
        urls = (0..<spec.size).map { index in
            switch spec.pattern {
            case "ties":
                // Equal filenames exercise literal full-path ties. Different
                // parent directories keep these media identities distinct.
                return fixtureRoot.appendingPathComponent("Directory \(index + 1)")
                    .appendingPathComponent("Episode 01.mkv")
            case "multilingual":
                return fixtureRoot.appendingPathComponent("\(titles[index % titles.count]) \(index + 1) — [1080p].mkv")
            default:
                return fixtureRoot.appendingPathComponent("Episode \(index + 1) [1080p].mkv")
            }
        }
    }
    urls.sort(by: referenceLess)
    if spec.order == "reverse" { urls.reverse() }
    if spec.order == "shuffled", urls.count > 1 {
        var generator = Generator()
        for index in stride(from: urls.count - 1, through: 1, by: -1) {
            urls.swapAt(index, Int(generator.next() % UInt64(index + 1)))
        }
    }
    return urls
}

private func representation(_ url: URL) -> [String] {
    [url.absoluteString, url.relativeString, url.absoluteURL.absoluteString,
     url.baseURL?.absoluteString ?? "<no-base>", url.path,
     url.hasDirectoryPath ? "directory" : "file"]
}

private struct Prepared {
    let spec: CaseSpec
    let urls: [URL]
    let items: [FolderPlaylistItem]
    let subtitles: [URL]
    let dates: [URL: Date]
    let folder: URL

    init(_ spec: CaseSpec) {
        self.spec = spec
        urls = fixture(spec)
        folder = spec.pattern == "edge"
            ? URL(fileURLWithPath: "/Volumes/IlliquidBenchmark/Unused/../Media", isDirectory: true)
            : fixtureRoot
        var preparedItems: [FolderPlaylistItem] = []
        var preparedSubtitles: [URL] = []
        var metadataDates: [URL: Date] = [:]
        for (index, url) in urls.enumerated() {
            let associated = spec.subtitles == 0 ? [] : ["ja.srt", "en.srt"].map {
                url.deletingPathExtension().appendingPathExtension($0)
            }
            let date = index % 5 == 0 ? nil : Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            if let date { metadataDates[NormalizedFileURL.normalize(url) ?? url] = date }
            preparedSubtitles.append(contentsOf: associated)
            if spec.scope == "public-constructor" {
                // Duplicate edge URLs intentionally have different metadata.
                preparedItems.append(FolderPlaylistItem(url: url, externalSubtitleURLs: associated, dateAdded: date))
            }
        }
        items = preparedItems
        subtitles = preparedSubtitles
        dates = metadataDates
    }

    @inline(never) func execute() -> FolderPlaylist {
        if spec.scope == "public-constructor" {
            return FolderPlaylist(folderURL: folder, items: items)
        }
        return FolderPlaylistDiscovery.makePlaylist(
            folderURL: folder, mediaURLs: urls, subtitleURLs: subtitles, metadataDates: dates
        )
    }

    func snapshot() -> [String: Any] {
        let result = execute()
        return [
            "folder": representation(result.folderURL),
            "count": result.count,
            "items": result.items.map { item -> [String: Any] in
                ["url": representation(item.url),
                 "external_subtitle_urls": item.externalSubtitleURLs.map(representation),
                 "date_bits": item.dateAdded.map { String($0.timeIntervalSinceReferenceDate.bitPattern) as Any } ?? NSNull()]
            },
        ]
    }
}

@inline(never) private func observe(_ playlist: FolderPlaylist, iteration: Int) -> UInt64 {
    guard !playlist.items.isEmpty else { return 1 }
    let item = playlist.items[iteration % playlist.items.count]
    return UInt64(playlist.items.count) &+ UInt64(item.url.absoluteString.utf8.count)
        &+ UInt64(item.externalSubtitleURLs.count)
        &+ (item.dateAdded?.timeIntervalSinceReferenceDate.bitPattern ?? 0)
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func emit(_ object: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

@main private enum Benchmark {
    static func main() throws {
        var prepared: Prepared?
        while let line = readLine() {
            let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
            switch request.operation {
            case "environment":
                try emit(["locale": Locale.current.identifier,
                          "os": ProcessInfo.processInfo.operatingSystemVersionString,
                          "processors": ProcessInfo.processInfo.processorCount])
            case "verify", "activate":
                guard let spec = request.spec else { fatalError("Missing case specification") }
                prepared = Prepared(spec)
                if request.operation == "verify" {
                    try emit(["id": spec.id, "input_count": prepared!.urls.count, "output": prepared!.snapshot()])
                } else {
                    _ = observe(prepared!.execute(), iteration: 0)
                    try emit(["id": spec.id, "ready": true])
                }
            case "measure":
                guard let input = prepared, let iterations = request.iterations,
                      iterations > 0, iterations <= 10_000_000 else { fatalError("Invalid measurement") }
                var witness: UInt64 = 0
                let cpuStart = cpuNanoseconds()
                let wallStart = DispatchTime.now().uptimeNanoseconds
                for iteration in 0..<iterations {
                    witness &+= observe(input.execute(), iteration: iteration)
                }
                let wall = DispatchTime.now().uptimeNanoseconds - wallStart
                let cpu = cpuNanoseconds() - cpuStart
                try emit(["id": input.spec.id, "iterations": iterations,
                          "wall_ns": wall, "cpu_ns": cpu, "witness": String(witness)])
            default:
                fatalError("Unknown operation: \(request.operation)")
            }
        }
    }
}
