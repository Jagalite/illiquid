import Foundation

// One driver is compiled unchanged with each variant's exact source files.
// Fixture creation, reference sorting, full equality checks and hashing stay
// outside the timer. The small observer is identical in both timed loops.
@main
struct NaturalFilenameOrderingBenchmark {
    enum Failure: Error {
        case usage
        case mismatch(String)
    }

    struct Generator {
        var state: UInt64 = 0x9e37_79b9_7f4a_7c15

        mutating func next() -> UInt64 {
            state &+= 0x9e37_79b9_7f4a_7c15
            var value = state
            value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
            value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
            return value ^ (value >> 31)
        }
    }

    struct Digest {
        var value: UInt64 = 14_695_981_039_346_656_037

        mutating func add(_ number: UInt64) {
            for shift in stride(from: 0, to: 64, by: 8) {
                value = (value ^ ((number >> shift) & 255)) &* 1_099_511_628_211
            }
        }

        mutating func add(_ string: String) {
            add(UInt64(string.utf8.count))
            for byte in string.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
        }

        mutating func add(_ url: URL) {
            for part in representation(url) { add(part) }
        }

        mutating func add(_ urls: [URL]) {
            add(UInt64(urls.count))
            for url in urls { add(url) }
        }

        mutating func add(_ item: FolderPlaylistItem) {
            add(item.url)
            add(item.externalSubtitleURLs)
            add(item.dateAdded == nil ? 0 : 1)
            if let date = item.dateAdded { add(date.timeIntervalSinceReferenceDate.bitPattern) }
        }

        var receipt: String { String(value, radix: 16) }
    }

    // Deliberately independent of every production ordering helper.
    static func referenceLess(_ lhs: URL, _ rhs: URL) -> Bool {
        switch lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame:
            return lhs.path.compare(rhs.path, options: [.literal]) == .orderedAscending
        }
    }

    static func representation(_ url: URL) -> [String] {
        [url.absoluteString, url.relativeString, url.absoluteURL.absoluteString,
         url.baseURL?.absoluteString ?? "<no-base>", url.path,
         url.hasDirectoryPath ? "directory" : "file"]
    }

    static func verify(_ actual: [URL], _ expected: [URL], context: String) throws {
        guard actual == expected,
              actual.map({ representation($0).map { Array($0.utf8) } })
                == expected.map({ representation($0).map { Array($0.utf8) } }) else {
            throw Failure.mismatch("URL values or representations differ: \(context)")
        }
    }

    static func verify(_ actual: [FolderPlaylistItem], _ expected: [FolderPlaylistItem],
                       context: String) throws {
        guard actual == expected else { throw Failure.mismatch("Playlist items differ: \(context)") }
        try verify(actual.map(\.url), expected.map(\.url), context: context)
        for (left, right) in zip(actual, expected) {
            try verify(left.externalSubtitleURLs, right.externalSubtitleURLs, context: context)
        }
    }

    static func fixture(pattern: String, order: String, count: Int) -> [URL] {
        let languages = ["en", "en-US", "zh-Hant", "日本語", "fr", "de", "pt-BR", "es"]
        let titles = ["Épisode", "E\u{301}pisode", "第", "Δοκιμή", "Straße", "東京"]
        var urls = (0..<count).map { index -> URL in
            let number = index + 1
            let path: String
            switch pattern {
            case "unicode_long":
                let prefix = String(repeating: "Nature & Cities 日本語 — ", count: 4)
                path = "/Volumes/Media/Collections with spaces % #/\(prefix)/"
                    + "\(titles[index % titles.count]) \(number) — \(prefix) [1080p].mkv"
            case "ties":
                path = "/Volumes/Media/Source \(number)/Season 1/Episode 01.mkv"
            case "subtitles":
                path = "/Volumes/Media/Season 1/Episode \(number).\(languages[index % languages.count]).srt"
            default:
                path = "/Volumes/Media/Season 1/Episode \(number).mkv"
            }
            return URL(fileURLWithPath: path)
        }
        // Every order uses the same reference-sorted multiset.
        urls.sort(by: referenceLess)
        if order == "reversed" { urls.reverse() }
        if order == "shuffled", urls.count > 1 {
            var generator = Generator()
            for index in stride(from: urls.count - 1, through: 1, by: -1) {
                urls.swapAt(index, Int(generator.next() % UInt64(index + 1)))
            }
        }
        return urls
    }

    // Observing a varying result position prevents dead-result elimination and
    // contributes to a checked receipt. This O(1) cost is part of both variants.
    @inline(never)
    static func observe(_ urls: [URL], iteration: Int) -> UInt64 {
        guard !urls.isEmpty else { return 1 }
        return UInt64(urls.count) &+ UInt64(urls[iteration % urls.count].absoluteString.utf8.count)
    }

    @inline(never)
    static func observe(_ items: [FolderPlaylistItem], iteration: Int) -> UInt64 {
        guard !items.isEmpty else { return 1 }
        let item = items[iteration % items.count]
        return UInt64(items.count) &+ UInt64(item.url.absoluteString.utf8.count)
            &+ UInt64(item.externalSubtitleURLs.count)
    }

    static func nanoseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000_000_000 + Double(parts.attoseconds) / 1_000_000_000
    }

    static func emit(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }

    static func verifyRepresentations() throws -> (checks: Int, receipt: String) {
        let base = URL(string: "file:///Volumes/Media/Series/")!
        let special = [
            URL(string: "Episode%202.mkv", relativeTo: base)!,
            URL(fileURLWithPath: "/Volumes/Media/Series/Episode 2.mkv"),
            URL(string: "./Episode%202.mkv", relativeTo: base)!,
            URL(string: "file://localhost/Volumes/Media/Series/Episode%202.mkv")!,
            URL(string: "https://example.invalid/Series/Episode%202.mkv?source=1#chapter")!,
        ] + ["Episode 02.mkv", "episode 2.mkv", "EPISODE 2.mkv", "Épisode 2.mkv",
             "E\u{301}pisode 2.mkv", "Episode 10.mkv", "Episode 2%.mkv", "Episode 2#.mkv"]
            .map { URL(fileURLWithPath: "/Volumes/Media/Series/" + $0) }
        var digest = Digest()
        var checks = 0
        // Include equal full paths with different representations and duplicate
        // items with distinct metadata. A changed order must not lose payloads.
        for urls in [special, Array(special.reversed()), [], Array(special.prefix(1)),
                     [special[0], special[1], special[0], special[1]]] {
            let expected = urls.sorted(by: referenceLess)
            let actual = NaturalFilenameOrdering.sort(urls)
            try verify(actual, expected, context: "representation fixture")
            digest.add(actual)
            checks += 1
            let items = urls.enumerated().map { index, url in
                FolderPlaylistItem(url: url, externalSubtitleURLs: Array(special.prefix(index % 4)),
                                   dateAdded: Date(timeIntervalSinceReferenceDate: Double(index)))
            }
            let expectedItems = items.sorted { referenceLess($0.url, $1.url) }
            let playlist = FolderPlaylist(folderURL: base, items: items)
            try verify(playlist.items, expectedItems, context: "item payload fixture")
            for item in playlist.items { digest.add(item) }
            checks += 1
        }
        for count in [0, 1, 2, 8] {
            let urls = fixture(pattern: "subtitles", order: "shuffled", count: count)
            let item = FolderPlaylistItem(url: base.appendingPathComponent("Movie.mkv"),
                                          externalSubtitleURLs: urls)
            try verify(item.externalSubtitleURLs, urls.sorted(by: referenceLess),
                       context: "subtitle fixture")
            digest.add(item)
            checks += 1
        }
        return (checks, digest.receipt)
    }

    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 2, arguments[1] == "--verify-only" {
            let result = try verifyRepresentations()
            try emit(["verification": true, "checks": result.checks,
                      "receipt": result.receipt, "locale": Locale.current.identifier])
            return
        }
        guard arguments.count == 7, ["sort", "playlist", "subtitle_item"].contains(arguments[1]),
              ["natural", "unicode_long", "ties", "subtitles"].contains(arguments[2]),
              ["shuffled", "sorted", "reversed"].contains(arguments[3]),
              let count = Int(arguments[4]), count >= 0,
              let iterations = Int(arguments[5]), iterations > 0,
              let warmup = Int(arguments[6]), warmup > 0 else {
            throw Failure.usage
        }
        let operation = arguments[1], pattern = arguments[2], order = arguments[3]
        let urls = fixture(pattern: pattern, order: order, count: count)
        let folder = URL(fileURLWithPath: "/Volumes/Media/Season 1", isDirectory: true)
        let expectedURLs = urls.sorted(by: referenceLess)
        let clock = ContinuousClock()
        var observed: UInt64 = 0, expectedObservation: UInt64 = 0
        var digest = Digest()
        let elapsed: Double

        if operation == "sort" {
            var result = NaturalFilenameOrdering.sort(urls)
            try verify(result, expectedURLs, context: "before timing")
            for index in 0..<warmup {
                result = NaturalFilenameOrdering.sort(urls)
                observed &+= observe(result, iteration: index)
            }
            observed = 0
            let start = clock.now
            for index in 0..<iterations {
                result = NaturalFilenameOrdering.sort(urls)
                observed &+= observe(result, iteration: index)
            }
            elapsed = nanoseconds(start.duration(to: clock.now))
            try verify(result, expectedURLs, context: "after timing")
            for index in 0..<iterations { expectedObservation &+= observe(expectedURLs, iteration: index) }
            digest.add(result)
        } else if operation == "playlist" {
            let subtitles = fixture(pattern: "subtitles", order: "shuffled", count: 2)
            let items = urls.enumerated().map { index, url in
                FolderPlaylistItem(url: url, externalSubtitleURLs: subtitles,
                                   dateAdded: Date(timeIntervalSinceReferenceDate: Double(index)))
            }
            let expected = items.sorted { referenceLess($0.url, $1.url) }
            var result = FolderPlaylist(folderURL: folder, items: items)
            try verify(result.items, expected, context: "before timing")
            for index in 0..<warmup {
                result = FolderPlaylist(folderURL: folder, items: items)
                observed &+= observe(result.items, iteration: index)
            }
            observed = 0
            let start = clock.now
            for index in 0..<iterations {
                result = FolderPlaylist(folderURL: folder, items: items)
                observed &+= observe(result.items, iteration: index)
            }
            elapsed = nanoseconds(start.duration(to: clock.now))
            try verify(result.items, expected, context: "after timing")
            try verify([result.folderURL], [NormalizedFileURL.normalize(folder) ?? folder], context: "folder")
            for index in 0..<iterations { expectedObservation &+= observe(expected, iteration: index) }
            digest.add(result.folderURL)
            for item in result.items { digest.add(item) }
        } else {
            let media = folder.appendingPathComponent("Movie.mkv")
            var result = FolderPlaylistItem(url: media, externalSubtitleURLs: urls)
            try verify(result.externalSubtitleURLs, expectedURLs, context: "before timing")
            for index in 0..<warmup {
                result = FolderPlaylistItem(url: media, externalSubtitleURLs: urls)
                observed &+= observe(result.externalSubtitleURLs, iteration: index)
            }
            observed = 0
            let start = clock.now
            for index in 0..<iterations {
                result = FolderPlaylistItem(url: media, externalSubtitleURLs: urls)
                observed &+= observe(result.externalSubtitleURLs, iteration: index)
            }
            elapsed = nanoseconds(start.duration(to: clock.now))
            try verify(result.externalSubtitleURLs, expectedURLs, context: "after timing")
            for index in 0..<iterations { expectedObservation &+= observe(expectedURLs, iteration: index) }
            digest.add(result)
        }
        guard observed == expectedObservation else { throw Failure.mismatch("Timed observer differs") }
        try emit(["operation": operation, "pattern": pattern, "order": order, "count": count,
                  "iterations": iterations, "warmup_iterations": warmup, "elapsed_ns": elapsed,
                  "observed": String(observed), "receipt": digest.receipt,
                  "locale": Locale.current.identifier, "full_output_verified": true])
    }
}
