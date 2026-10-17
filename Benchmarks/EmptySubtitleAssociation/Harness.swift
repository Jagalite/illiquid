import Foundation
import IlliquidCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum ProbeError: Error { case invalidArguments, invalidResult(String) }

private struct URLValue: Codable, Equatable {
    let absoluteString: String
    let relativeString: String
    let baseURL: String?

    init(_ url: URL) {
        absoluteString = url.absoluteString
        relativeString = url.relativeString
        baseURL = url.baseURL?.absoluteString
    }
}

private struct AssociationValue: Codable, Equatable {
    let media: URLValue
    let subtitles: [URLValue]
}

private struct ItemValue: Codable, Equatable {
    let url: URLValue
    let id: String
    let externalSubtitleURLs: [URLValue]
    let dateAddedSeconds: Double?
}

private struct Value: Codable, Equatable {
    var associations: [AssociationValue]? = nil
    var folderURL: URLValue? = nil
    var items: [ItemValue]? = nil
}

private struct Fixture {
    let folderURL: URL
    let media: [URL]
    let subtitles: [URL]
    let dates: [URL: Date]

    init(count: Int, style: String, mode: String) throws {
        guard count >= 0, ["ascii", "unicode"].contains(style),
              ["empty", "matched", "unsupported"].contains(mode) else {
            throw ProbeError.invalidArguments
        }
        // Pure URLs and fixed dates: the timed model path never touches disk.
        folderURL = URL(fileURLWithPath: "/IlliquidBenchmark/EmptySubtitleAssociation", isDirectory: true)
        var media: [URL] = [], subtitles: [URL] = [], dates: [URL: Date] = [:]
        for index in 0..<count {
            let title = style == "ascii"
                ? "Series S01E\(index) Episode \(index) 1080p WEB-DL"
                : "世界の物語 Café e\u{301}tude ＡＢＣ 長い番組名 S01E\(index) 第\(index)話 1080p WEB-DL"
            let url = folderURL.appendingPathComponent(title + ".mkv", isDirectory: false)
            media.append(url)
            if index.isMultiple(of: 3) {
                dates[NormalizedFileURL.normalize(url)!] = Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 17))
            }
            if mode == "matched" {
                subtitles.append(folderURL.appendingPathComponent(title + ".en.srt", isDirectory: false))
            } else if mode == "unsupported" {
                subtitles.append(folderURL.appendingPathComponent("notes \(index).txt", isDirectory: false))
            }
        }
        self.media = permuted(media, seed: 0x32a9)
        self.subtitles = permuted(subtitles, seed: 0x76c1)
        self.dates = dates
    }

    init(folder: URL, media: [URL], subtitles: [URL]) {
        folderURL = folder
        self.media = media
        self.subtitles = subtitles
        dates = [:]
    }
}

private func permuted<T>(_ source: [T], seed: UInt64) -> [T] {
    var result = source, state = seed
    guard result.count > 1 else { return result }
    for index in stride(from: result.count - 1, through: 1, by: -1) {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        result.swapAt(index, Int(state % UInt64(index + 1)))
    }
    return result
}

private func associationValue(_ result: [URL: [URL]]) -> Value {
    // Preserve subtitle ordering. Only dictionary entries are canonicalized.
    let values = result.map { AssociationValue(media: URLValue($0.key), subtitles: $0.value.map(URLValue.init)) }
        .sorted {
            if $0.media.absoluteString != $1.media.absoluteString {
                return $0.media.absoluteString < $1.media.absoluteString
            }
            if $0.media.relativeString != $1.media.relativeString {
                return $0.media.relativeString < $1.media.relativeString
            }
            return ($0.media.baseURL ?? "") < ($1.media.baseURL ?? "")
        }
    return Value(associations: values)
}

private func playlistValue(_ result: FolderPlaylist) -> Value {
    Value(folderURL: URLValue(result.folderURL), items: result.items.map {
        ItemValue(url: URLValue($0.url), id: $0.id,
                  externalSubtitleURLs: $0.externalSubtitleURLs.map(URLValue.init),
                  dateAddedSeconds: $0.dateAdded?.timeIntervalSince1970)
    })
}

private func verifyAssociations(_ result: [URL: [URL]], fixture: Fixture, mode: String) throws {
    // This oracle is independent of matching/tokenization: original URL keys,
    // including unsupported ones, must survive and have empty values.
    if mode == "empty" || mode == "unsupported" {
        guard Set(result.keys) == Set(fixture.media), result.values.allSatisfy(\.isEmpty) else {
            throw ProbeError.invalidResult("The complete original-key empty association map was not retained")
        }
    } else {
        guard result.count == Set(fixture.media).count else {
            throw ProbeError.invalidResult("Matched fixture lost media keys")
        }
        for url in fixture.media {
            let expected = url.deletingPathExtension().appendingPathExtension("en.srt")
            guard result[url] == [expected] else {
                throw ProbeError.invalidResult("Matched control did not assign the exact subtitle")
            }
        }
    }
}

private func verifyPlaylist(_ result: FolderPlaylist, fixture: Fixture, mode: String) throws {
    let expectedURLs = Set(fixture.media.compactMap(NormalizedFileURL.normalize))
    guard result.folderURL == NormalizedFileURL.normalize(fixture.folderURL),
          result.count == expectedURLs.count, Set(result.mediaURLs) == expectedURLs,
          result.items.filter({ $0.dateAdded != nil }).count == fixture.dates.count else {
        throw ProbeError.invalidResult("Playlist folder, identities or count changed")
    }
    for item in result.items {
        guard item.dateAdded == fixture.dates[item.url] else {
            throw ProbeError.invalidResult("Playlist metadata changed")
        }
        if mode == "matched" {
            guard item.externalSubtitleURLs == [item.url.deletingPathExtension().appendingPathExtension("en.srt")] else {
                throw ProbeError.invalidResult("Playlist lost a matched subtitle")
            }
        } else if !item.externalSubtitleURLs.isEmpty {
            throw ProbeError.invalidResult("Playlist acquired an unexpected subtitle")
        }
    }
}

private func nanoseconds(_ clock: clockid_t) -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(clock, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private struct Measurement: Codable {
    let operation: String
    let style: String
    let mode: String
    let media_count: Int
    let subtitle_count: Int
    let iterations: Int
    let warmup_iterations: Int
    let elapsed_ns: UInt64
    let cpu_ns: UInt64
    let checksum: UInt64
    let result: Value
}

private func measure(operation: String, style: String, mode: String, count: Int, iterations: Int) throws -> Measurement {
    let fixture = try Fixture(count: count, style: style, mode: mode)
    let warmup = min(iterations, 3)
    var checksum: UInt64 = 0, elapsed: UInt64 = 0, cpu: UInt64 = 0
    let value: Value
    if operation == "associate" {
        var result = ExternalSubtitleMatcher.associate(subtitleURLs: fixture.subtitles, with: fixture.media)
        try verifyAssociations(result, fixture: fixture, mode: mode)
        for _ in 0..<warmup {
            checksum &+= UInt64(ExternalSubtitleMatcher.associate(subtitleURLs: fixture.subtitles, with: fixture.media).count)
        }
        let startCPU = nanoseconds(CLOCK_PROCESS_CPUTIME_ID), start = nanoseconds(CLOCK_MONOTONIC)
        for _ in 0..<iterations {
            result = ExternalSubtitleMatcher.associate(subtitleURLs: fixture.subtitles, with: fixture.media)
            checksum &+= UInt64(result.count)
        }
        elapsed = nanoseconds(CLOCK_MONOTONIC) - start
        cpu = nanoseconds(CLOCK_PROCESS_CPUTIME_ID) - startCPU
        try verifyAssociations(result, fixture: fixture, mode: mode)
        value = associationValue(result)
    } else if operation == "makePlaylist" {
        func build() -> FolderPlaylist {
            FolderPlaylistDiscovery.makePlaylist(folderURL: fixture.folderURL, mediaURLs: fixture.media,
                                                 subtitleURLs: fixture.subtitles, metadataDates: fixture.dates)
        }
        var result = build()
        try verifyPlaylist(result, fixture: fixture, mode: mode)
        for _ in 0..<warmup { checksum &+= UInt64(build().count) }
        let startCPU = nanoseconds(CLOCK_PROCESS_CPUTIME_ID), start = nanoseconds(CLOCK_MONOTONIC)
        for _ in 0..<iterations {
            result = build()
            checksum &+= UInt64(result.count)
        }
        elapsed = nanoseconds(CLOCK_MONOTONIC) - start
        cpu = nanoseconds(CLOCK_PROCESS_CPUTIME_ID) - startCPU
        try verifyPlaylist(result, fixture: fixture, mode: mode)
        value = playlistValue(result)
    } else {
        throw ProbeError.invalidArguments
    }
    return Measurement(operation: operation, style: style, mode: mode, media_count: count,
                       subtitle_count: fixture.subtitles.count, iterations: iterations,
                       warmup_iterations: warmup, elapsed_ns: elapsed, cpu_ns: cpu,
                       checksum: checksum, result: value)
}

private struct DifferentialResult: Codable {
    let name: String
    let operation: String
    let result: Value
}

private func differential() throws -> [DifferentialResult] {
    let folder = URL(fileURLWithPath: "/IlliquidBenchmark/Differential", isDirectory: true)
    func url(_ name: String) -> URL { folder.appendingPathComponent(name, isDirectory: false) }
    let based = URL(string: "Episode%202.mkv", relativeTo: folder)!
    let unicode = [url("Café ＡＢＣ 世界.mkv"), url("Cafe\u{301} ＡＢＣ 世界.mkv")]
    let corpora: [(String, [URL])] = [
        ("zero", []), ("one", [url("Movie.mkv")]),
        ("duplicates", [url("Movie.mkv"), url("Movie.mkv"), url("Episode 2.mp4")]),
        ("unsupported", [url("notes.txt"), url("audio.mp3"), url("folder")]),
        ("original-keys", [based, url("Episode 2.mkv"), URL(string: "https://example.invalid/Movie.mkv")!,
                           URL(string: "file://remote.invalid/Movie.mkv")!, url(".hidden.MKV")]),
        ("unicode", unicode),
    ]
    var results: [DifferentialResult] = []
    for (name, media) in corpora {
        for reverse in [false, true] {
            let fixture = Fixture(folder: folder, media: reverse ? Array(media.reversed()) : media, subtitles: [])
            let associations = ExternalSubtitleMatcher.associate(subtitleURLs: [], with: fixture.media)
            try verifyAssociations(associations, fixture: fixture, mode: "empty")
            results.append(.init(name: name + (reverse ? "-reversed" : "-forward"), operation: "associate",
                                 result: associationValue(associations)))
            let playlist = FolderPlaylistDiscovery.makePlaylist(folderURL: folder, mediaURLs: fixture.media, subtitleURLs: [])
            try verifyPlaylist(playlist, fixture: fixture, mode: "empty")
            results.append(.init(name: name + (reverse ? "-reversed" : "-forward"), operation: "makePlaylist",
                                 result: playlistValue(playlist)))
        }
    }
    for style in ["ascii", "unicode"] {
        for mode in ["empty", "matched", "unsupported"] {
            for count in [0, 1, 8, 128] {
                let fixture = try Fixture(count: count, style: style, mode: mode)
                let associations = ExternalSubtitleMatcher.associate(subtitleURLs: fixture.subtitles, with: fixture.media)
                try verifyAssociations(associations, fixture: fixture, mode: mode)
                let playlist = FolderPlaylistDiscovery.makePlaylist(folderURL: fixture.folderURL, mediaURLs: fixture.media,
                                                                  subtitleURLs: fixture.subtitles, metadataDates: fixture.dates)
                try verifyPlaylist(playlist, fixture: fixture, mode: mode)
                let name = "\(style)-\(mode)-\(count)"
                results.append(.init(name: name, operation: "associate", result: associationValue(associations)))
                results.append(.init(name: name, operation: "makePlaylist", result: playlistValue(playlist)))
            }
        }
    }
    return results
}

@main
private enum Main {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        if arguments == ["differential"] {
            data = try encoder.encode(differential())
        } else if arguments.count == 6, arguments[0] == "measure",
                  let count = Int(arguments[4]), let iterations = Int(arguments[5]), iterations > 0 {
            data = try encoder.encode(measure(operation: arguments[1], style: arguments[2], mode: arguments[3],
                                             count: count, iterations: iterations))
        } else {
            throw ProbeError.invalidArguments
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
