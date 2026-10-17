import Foundation
import IlliquidCore

private struct SelectionCase {
    let name: String
    let items: [FolderPlaylistItem]
    let currentURL: URL?
    let fallbackIndex: Int?

    func select() -> Int? {
        PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: currentURL, fallbackIndex: fallbackIndex, in: items
        )
    }

    // Keep the original predicate as a differential oracle. Independently
    // expected indexes also live in PlaylistSelectionIdentityTests.swift.
    func reference() -> Int? {
        if let currentURL,
           let index = items.firstIndex(where: {
               NormalizedFileURL.representsSameFile($0.url, currentURL)
           }) {
            return index
        }
        if let fallbackIndex, items.indices.contains(fallbackIndex) {
            return fallbackIndex
        }
        return items.isEmpty ? nil : items.startIndex
    }
}

private func emit(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

// Decode directly so the corpus includes saved URLs that did not pass through
// FolderPlaylistItem.init's normalization. This is outside all timing blocks.
private func decodedItem(_ url: URL, ordinal: Int) throws -> FolderPlaylistItem {
    let data = try JSONSerialization.data(withJSONObject: [
        "url": url.absoluteString,
        "externalSubtitleURLs": ["file:///Media/subtitle-\(ordinal).srt"],
        "dateAdded": ordinal,
    ])
    return try JSONDecoder().decode(FolderPlaylistItem.self, from: data)
}

private func verify() throws {
    let spellings = [
        "file:///Media/One.mkv", "file:///Media/Two.mkv",
        "file:///Media/Season/../One.mkv", "file://localhost/Media/One.mkv",
        "file://LOCALHOST/Media/Two.mkv", "file:///Media/Caf%C3%A9.mkv",
        "file:///Media/Cafe%CC%81.mkv", "file:///Media/%E5%BD%B1%E9%9B%86.mkv",
        "file:///Media/Movie.mkv", "file:///media/movie.mkv",
        "file:///Media/Movie%252F.mkv", "file:///Media/Movie%2F.mkv",
        "file:///Media/%252E%252E/Movie.mkv", "file:///Media/%2E%2E/Movie.mkv",
        "file:///Media/clip.mkv?ignored=1#chapter", "file:///Media/clip.mkv",
        "file:///Media/a%23b%3Fc.mkv", "file:///Media/a%2523b%253Fc.mkv",
        "file:///Media/%00clip.mkv", "file:///Media/%FFclip.mkv",
        "file:///Media/%F0%9F%8E%AC.mkv", "file:///Media/~user/clip.mkv",
        "file:///Media//", "file:///Media///", "file:///", "file:////",
        "file://server.example/Media/One.mkv", "file://other.example/Media/One.mkv",
        "file://user@localhost/Media/One.mkv", "file://localhost:42/Media/One.mkv",
        "file://127.0.0.1/Media/One.mkv", "file:relative.mkv",
        "https://media.example/One.mkv", "ftp://media.example/One.mkv",
    ]
    var urls = spellings.compactMap { URL(string: $0) }
    for base in ["file:///Media/Season/", "file://server.example/Media/Season/"] {
        urls.append(URL(string: "../One.mkv", relativeTo: URL(string: base)!)!)
    }
    var pool = try urls.enumerated().map { try decodedItem($0.element, ordinal: $0.offset) }
    pool.append(FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/Cafe\u{301}.mkv")))
    let queries: [URL?] = urls.map(Optional.some) + [nil, URL(fileURLWithPath: "/Media/Missing.mkv")]
    var arrays: [[FolderPlaylistItem]] = [
        [], [pool[0]], [pool[26]], Array(pool.prefix(4)),
        [pool[2], pool[0], pool[3], pool[1]],
        Array(pool[26...]), pool, Array(pool.reversed()),
    ]
    var seed: UInt64 = 0x1_111_0123
    func next() -> UInt64 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return seed
    }
    for _ in 0..<16 {
        let count = Int(next() % 49)
        arrays.append((0..<count).map { _ in pool[Int(next() % UInt64(pool.count))] })
    }

    var ordinal = 0
    for (arrayID, items) in arrays.enumerated() {
        let fallbacks: [Int?] = [nil, -1, 0, 1, items.count / 2, items.count - 1, items.count, Int.max]
        for (queryID, query) in queries.enumerated() {
            for (fallbackID, fallback) in fallbacks.enumerated() {
                let fixture = SelectionCase(name: "\(arrayID)/\(queryID)/\(fallbackID)",
                    items: items, currentURL: query, fallbackIndex: fallback)
                let expected = fixture.reference()
                let actual = fixture.select()
                precondition(actual == expected, "Selection mismatch: \(fixture.name)")
                try emit([
                    "case": ordinal, "fixture": fixture.name, "count": items.count,
                    "query": query?.absoluteString as Any? ?? NSNull(),
                    "fallback": fallback as Any? ?? NSNull(),
                    "index": actual as Any? ?? NSNull(),
                ])
                ordinal += 1
            }
        }
    }
    try emit(["event": "verification", "cases": ordinal, "mismatches": 0])
}

private func timedCase(workload: String, size: Int) -> SelectionCase {
    let count = workload == "empty" ? 0 : size
    let isUnicode = workload.hasSuffix("-unicode")
    let items = (0..<count).map { index in
        if workload == "all-invalid-items" {
            return FolderPlaylistItem(url: URL(string: "https://media.example/Episode-\(index).mkv")!)
        }
        let folder = isUnicode ? "/Volumes/Média/影集/Café/シーズン" : "/Volumes/Media/Shows/Series/Season"
        let name = isUnicode ? "Épisode \(index) 🎬.mkv" : "Episode \(index).mkv"
        return FolderPlaylistItem(url: URL(fileURLWithPath: "\(folder)/\(name)", isDirectory: false))
    }
    let current: URL?
    switch workload {
    case "head": current = items.first?.url
    case "middle": current = items.isEmpty ? nil : items[items.count / 2].url
    case "tail", "tail-unicode": current = items.last?.url
    case "missing", "missing-unicode", "all-invalid-items", "empty":
        current = URL(fileURLWithPath: "/Volumes/Media/Shows/Series/Season/Missing.mkv", isDirectory: false)
    case "invalid-current": current = URL(string: "file://server.example/Media/Episode.mkv")!
    case "nil-current": current = nil
    default: fatalError("Unknown workload: \(workload)")
    }
    return SelectionCase(name: workload, items: items, currentURL: current,
                         fallbackIndex: count > 0 ? count / 3 : nil)
}

private func benchmark(workload: String, size: Int, iterations: Int) throws {
    precondition(size >= 0 && iterations > 0)
    let fixture = timedCase(workload: workload, size: size)
    let expected: Int?
    switch workload {
    case "empty": expected = nil
    case "head": expected = size > 0 ? 0 : nil
    case "middle": expected = size > 0 ? size / 2 : nil
    case "tail", "tail-unicode": expected = size > 0 ? size - 1 : nil
    default: expected = size > 0 ? size / 3 : nil
    }
    precondition(fixture.select() == expected)
    // Inputs, expected outputs and warmup are outside the timer. The call below
    // crosses the shared-library boundary; its body is unavailable to this loop.
    for _ in 0..<3 { precondition(fixture.select() == expected) }
    var checksum = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        checksum &+= (fixture.select() ?? -1) &+ 1
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    precondition(checksum == ((expected ?? -1) &+ 1) &* iterations)
    try emit([
        "workload": workload, "size": fixture.items.count, "iterations": iterations,
        "operations": iterations, "wallNanoseconds": elapsed, "checksum": checksum,
    ])
}

@main private enum PlaylistSelectionBenchmark {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 2, args[1] == "verify" {
            try verify()
        } else if args.count == 5, args[1] == "benchmark",
                  let size = Int(args[3]), let iterations = Int(args[4]) {
            try benchmark(workload: args[2], size: size, iterations: iterations)
        } else {
            fatalError("Usage: Harness verify | benchmark WORKLOAD SIZE ITERATIONS")
        }
    }
}
