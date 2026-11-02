import Foundation
import Dispatch
import IlliquidCore

#if ALLOCATION_METER
@_silgen_name("meter_begin") private func meterBegin()
@_silgen_name("meter_end") private func meterEnd()
@_silgen_name("meter_requests") private func meterRequests() -> UInt64
@_silgen_name("meter_bytes") private func meterBytes() -> UInt64
@_silgen_name("meter_max_request") private func meterMaxRequest() -> UInt64
@_silgen_name("meter_large_count") private func meterLargeCount() -> UInt64
@_silgen_name("meter_large_size") private func meterLargeSize(_ index: UInt64) -> UInt64
@_silgen_name("meter_large_requests") private func meterLargeRequests(_ index: UInt64) -> UInt64
#endif

private enum Failure: Error { case usage, mismatch(String) }
private let patterns = ["shuffled", "sorted", "reversed", "ties", "unicode"]
private let folder = URL(fileURLWithPath: "/Volumes/Media/Season 1", isDirectory: true)

private struct Generator {
    var state: UInt64 = 0x4E41545552414C
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(state % UInt64(bound))
    }
}

private struct Digest {
    var value: UInt64 = 14_695_981_039_346_656_037
    mutating func add(_ number: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            value = (value ^ ((number >> shift) & 255)) &* 1_099_511_628_211
        }
    }
    mutating func add(_ text: String) {
        add(UInt64(text.utf8.count))
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
    }
    mutating func add(_ url: URL) { for part in representation(url) { add(part) } }
    var fingerprint: String { String(value, radix: 16) }
}

// Frozen comparator: never delegate expected ordering to a production helper.
private func referenceLess(_ lhs: URL, _ rhs: URL) -> Bool {
    switch lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) {
    case .orderedAscending: return true
    case .orderedDescending: return false
    case .orderedSame:
        return lhs.path.compare(rhs.path, options: [.literal]) == .orderedAscending
    }
}

private func representation(_ url: URL) -> [String] {
    [url.relativeString, url.absoluteString, url.absoluteURL.absoluteString,
     url.baseURL?.absoluteString ?? "<no-base>", url.path,
     url.hasDirectoryPath ? "directory" : "file"]
}

private func verifyURLs(_ actual: [URL], _ expected: [URL]) throws {
    guard actual.count == expected.count else { throw Failure.mismatch("URL count") }
    for (left, right) in zip(actual, expected) {
        guard left == right,
              zip(representation(left), representation(right)).allSatisfy({ left, right in
                  left.utf8.elementsEqual(right.utf8)
              }) else { throw Failure.mismatch("URL value or exact representation") }
    }
}

private enum Output {
    case urls([URL])
    case playlist([FolderPlaylistItem], URL)

    func verify(_ expected: Self) throws {
        switch (self, expected) {
        case let (.urls(actual), .urls(expected)):
            try verifyURLs(actual, expected)
        case let (.playlist(actual, actualFolder), .playlist(expected, expectedFolder)):
            guard actual.count == expected.count else { throw Failure.mismatch("Item count") }
            try verifyURLs([actualFolder], [expectedFolder])
            for (left, right) in zip(actual, expected) {
                guard left.dateAdded == right.dateAdded else { throw Failure.mismatch("Date metadata") }
                try verifyURLs([left.url], [right.url])
                try verifyURLs(left.externalSubtitleURLs, right.externalSubtitleURLs)
            }
        default: throw Failure.mismatch("Output type")
        }
    }

    // Identical O(1) observer in both variants. Every timed result contributes;
    // full byte-sensitive validation and hashing remain outside the timer.
    @inline(never) func observe(_ iteration: Int) -> UInt64 {
        switch self {
        case .urls(let urls):
            guard !urls.isEmpty else { return 1 }
            return UInt64(urls.count) &+ UInt64(urls[iteration % urls.count].absoluteString.utf8.count)
        case .playlist(let items, _):
            guard !items.isEmpty else { return 1 }
            let item = items[iteration % items.count]
            return UInt64(items.count) &+ UInt64(item.url.absoluteString.utf8.count)
                &+ UInt64(item.externalSubtitleURLs.count)
                &+ (item.dateAdded?.timeIntervalSinceReferenceDate.bitPattern ?? UInt64.max)
        }
    }

    func add(to digest: inout Digest) {
        switch self {
        case .urls(let urls):
            digest.add("urls"); digest.add(UInt64(urls.count))
            for url in urls { digest.add(url) }
        case .playlist(let items, let folder):
            digest.add("playlist"); digest.add(folder); digest.add(UInt64(items.count))
            for item in items {
                digest.add(item.url); digest.add(UInt64(item.externalSubtitleURLs.count))
                for subtitle in item.externalSubtitleURLs { digest.add(subtitle) }
                digest.add(item.dateAdded == nil ? 0 : 1)
                if let date = item.dateAdded { digest.add(date.timeIntervalSinceReferenceDate.bitPattern) }
            }
        }
    }
}

private func fixture(_ pattern: String, count: Int) -> [URL] {
    let titles = ["Café", "Cafe\u{0301}", "第", "東京", "İstanbul", "🎬"]
    var urls = (0..<count).map { index -> URL in
        let path: String
        if pattern == "ties" {
            path = "/Volumes/Media/Source \(index % max(1, count / 4))/Episode 2.mkv"
        } else if pattern == "unicode" {
            path = "/Volumes/Media/日本語 % #/\(titles[index % titles.count]) \(index + 1) — Episode [1080p].mkv"
        } else {
            path = "/Volumes/Media/Season 1/Episode \(index + 1).mkv"
        }
        return URL(fileURLWithPath: path)
    }
    urls.sort(by: referenceLess)
    if pattern == "reversed" { urls.reverse() }
    if pattern != "sorted", pattern != "reversed", urls.count > 1 {
        var random = Generator()
        for index in stride(from: urls.count - 1, through: 1, by: -1) {
            urls.swapAt(index, random.next(index + 1))
        }
    }
    return urls
}

private struct ItemFixture: Encodable {
    let url: URL
    let externalSubtitleURLs: [URL]
    let dateAdded: Date?
}

private func workload(_ operation: String, urls: [URL]) throws -> (run: () -> Output, expected: Output) {
    if operation == "urls" {
        return ({ .urls(NaturalFilenameOrdering.sort(urls)) }, .urls(urls.sorted(by: referenceLess)))
    }
    // Decoding preserves original URL spelling and unsorted subtitle metadata;
    // rebuilding items in the implementation would change these receipts.
    let fixtures = urls.enumerated().map { index, url in
        ItemFixture(url: url, externalSubtitleURLs: [
            folder.appendingPathComponent("Subtitle \(index) 10.srt"),
            folder.appendingPathComponent("Subtitle \(index) 2.srt"),
        ], dateAdded: index.isMultiple(of: 3) ? nil : Date(timeIntervalSinceReferenceDate: Double(index)))
    }
    let items = try JSONDecoder().decode([FolderPlaylistItem].self, from: JSONEncoder().encode(fixtures))
    let expected = items.sorted { referenceLess($0.url, $1.url) }
    return ({
        let playlist = FolderPlaylist(folderURL: folder, items: items)
        return .playlist(playlist.items, playlist.folderURL)
    }, .playlist(expected, folder))
}

private func layout() -> [String: Int] {
    ["url_stride": MemoryLayout<URL>.stride,
     "item_stride": MemoryLayout<FolderPlaylistItem>.stride,
     "name_stride": MemoryLayout<String>.stride,
     "index_stride": MemoryLayout<Int>.stride,
     "url_name_stride": MemoryLayout<(URL, String)>.stride,
     "item_name_stride": MemoryLayout<(FolderPlaylistItem, String)>.stride]
}

private func emit(_ value: [String: Any]) throws {
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    FileHandle.standardOutput.write(Data([10]))
}

@main
struct NaturalFilenameSortStorageBenchmark {
    static func main() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--verify"] {
            let base = URL(string: "file:///Volumes/Media/Series/")!
            let special = [
                URL(string: "Episode%202.mkv", relativeTo: base)!,
                URL(string: "file:///Volumes/Media/Series/../Episode%202.mkv")!,
                URL(string: "file://localhost/Volumes/Media/Series/Episode%202.mkv")!,
                URL(string: "https://a.example.invalid/Episode%202.mkv?v=1#first")!,
                URL(string: "https://b.example.invalid/Episode%202.mkv?v=2#last")!,
                URL(fileURLWithPath: "/Media/Café 2.mkv"),
                URL(fileURLWithPath: "/Media/Cafe\u{0301} 2.mkv"),
            ]
            var digest = Digest(), checks = 0
            for operation in ["urls", "playlist"] {
                var corpora = patterns.flatMap { pattern in
                    [0, 1, 2, 3, 8, 129].map { fixture(pattern, count: $0) }
                }
                corpora += [special, Array(special.reversed()), (0..<257).map { special[3 + $0 % 2] }]
                for urls in corpora {
                    let work = try workload(operation, urls: urls), actual = work.run()
                    try actual.verify(work.expected)
                    actual.add(to: &digest); checks += 1
                }
            }
            try emit(["mode": "verification", "checks": checks, "fingerprint": digest.fingerprint,
                      "locale": Locale.current.identifier, "layout": layout(), "full_output_verified": true])
            return
        }
        let allocations = arguments.first == "--allocations"
        if allocations { arguments.removeFirst() }
        guard arguments.count == 4, ["urls", "playlist"].contains(arguments[0]),
              patterns.contains(arguments[1]), let count = Int(arguments[2]), count >= 0,
              let iterations = Int(arguments[3]), iterations > 0, !allocations || iterations == 1 else {
            throw Failure.usage
        }
        let operation = arguments[0], pattern = arguments[1]
        let work = try workload(operation, urls: fixture(pattern, count: count))
        var result = work.run()
        try result.verify(work.expected)
        var warmupChecksum: UInt64 = 0
        for index in 0..<2 { result = work.run(); warmupChecksum &+= result.observe(index) }
        var checksum: UInt64 = 0, expectedChecksum: UInt64 = 0
        var statistics: [String: Any] = [:]
        let start = DispatchTime.now().uptimeNanoseconds
        if allocations {
            #if ALLOCATION_METER
            meterBegin(); result = work.run(); meterEnd()
            #else
            throw Failure.mismatch("Allocation mode requires ALLOCATION_METER")
            #endif
        } else {
            for index in 0..<iterations { result = work.run(); checksum &+= result.observe(index) }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        #if ALLOCATION_METER
        if allocations {
            statistics = ["allocation_requests": meterRequests(), "allocation_requested_bytes": meterBytes(),
                          "allocation_max_request": meterMaxRequest(), "large_allocations":
                            (0..<meterLargeCount()).map { ["bytes": meterLargeSize($0), "requests": meterLargeRequests($0)] }]
            checksum = result.observe(0)
        }
        #endif
        for index in 0..<iterations { expectedChecksum &+= work.expected.observe(index) }
        guard checksum == expectedChecksum else { throw Failure.mismatch("Timed result checksum") }
        try result.verify(work.expected)
        var digest = Digest(); result.add(to: &digest)
        statistics.merge(["mode": allocations ? "allocations" : "latency", "operation": operation,
            "pattern": pattern, "count": count, "iterations": iterations, "warmup_iterations": 2,
            "elapsed_ns": elapsed, "ns_per_iteration": Double(elapsed) / Double(iterations),
            "checksum": String(checksum), "warmup_checksum": String(warmupChecksum),
            "fingerprint": digest.fingerprint, "locale": Locale.current.identifier,
            "layout": layout(), "full_output_verified": true]) { _, value in value }
        try emit(statistics)
    }
}
