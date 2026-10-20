import Foundation
import IlliquidCore

// This consumer calls each revision's actual PlaylistMutation.sorted(). Fixture
// construction, item initialization/normalization, and identity-map creation are
// outside timing. The core types and comparators are not copied into the harness.
private let workloadBases = [
    "name-random", "name-sorted", "name-reverse", "name-duplicates",
    "dates-unique", "dates-ties", "dates-missing", "metadata-name",
]

private struct Workload {
    let name: String
    let base: String
    let ascending: Bool
    let order: PlaylistSortOrder

    init?(_ name: String) {
        let suffix: String
        if name.hasSuffix("-asc") {
            suffix = "-asc"
            ascending = true
        } else if name.hasSuffix("-desc") {
            suffix = "-desc"
            ascending = false
        } else {
            return nil
        }
        let base = String(name.dropLast(suffix.count))
        guard workloadBases.contains(base) else { return nil }
        self.name = name
        self.base = base
        self.order = base.hasPrefix("dates-") ? .dateAdded : .name
    }
}

private func shuffled<T>(_ input: [T], seed: UInt64) -> [T] {
    var result = input
    var state = seed
    if result.count > 1 {
        for index in stride(from: result.count - 1, through: 1, by: -1) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            result.swapAt(index, Int(state % UInt64(index + 1)))
        }
    }
    return result
}

private struct Fixture {
    let items: [FolderPlaylistItem]
    private let originalIndices: [URL: Int]

    init(_ items: [FolderPlaylistItem]) {
        self.items = items
        var indices: [URL: Int] = [:]
        indices.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            // Ordinary timing fixtures have unique media URLs and empty subtitle
            // arrays. Duplicate-URL and metadata fixtures carry unique subtitle
            // URLs. Neither branch evaluates FolderPlaylistItem.id.
            let key = item.externalSubtitleURLs.first ?? item.url
            precondition(indices.updateValue(index, forKey: key) == nil,
                         "Fixture identities must be unique")
        }
        originalIndices = indices
    }

    func ordinal(of item: FolderPlaylistItem) -> Int {
        let key = item.externalSubtitleURLs.first ?? item.url
        guard let index = originalIndices[key] else {
            preconditionFailure("Sorter lost a fixture identity")
        }
        return index
    }
}

private func subtitlePayload(index: Int, expanded: Bool) -> [URL] {
    let root = URL(fileURLWithPath: "/fixture-payload/item-\(index)", isDirectory: true)
    if !expanded { return [root.appendingPathComponent("identity.srt")] }
    return [
        "English SDH.ass", "English Commentary.srt", "日本語.ass",
        "Français.srt", "Deutsch.srt", "Spanish Forced.srt",
    ].map { root.appendingPathComponent($0) }
}

private func fixture(size: Int, workload: Workload, seed: UInt64 = 0x5EED) -> Fixture {
    let indices = Array(0..<size)
    let preparedOrder: [Int]
    switch workload.base {
    case "name-sorted":
        preparedOrder = workload.ascending ? indices : Array(indices.reversed())
    case "name-reverse":
        preparedOrder = workload.ascending ? Array(indices.reversed()) : indices
    default:
        preparedOrder = shuffled(indices, seed: seed)
    }
    let items = preparedOrder.map { index in
        let path: String
        switch workload.base {
        case "name-duplicates":
            path = "/fixtures/Collection \(index)/Episode 1.mkv"
        case "metadata-name":
            path = "/fixtures/Show \(index / 25) (2020)/Season 01/"
                + "Show \(index / 25) - S01E\(index % 25).1080p.WEB-DL.HEVC.mkv"
        default:
            path = "/fixtures/Episode \(index).mkv"
        }
        let date: Date?
        switch workload.base {
        case "dates-missing":
            date = nil
        case "dates-ties":
            date = index.isMultiple(of: 7) ? nil
                : Date(timeIntervalSince1970: Double(index % 4) - 2)
        default:
            date = Date(timeIntervalSince1970: Double(index) - Double(size / 2))
        }
        return FolderPlaylistItem(
            url: URL(fileURLWithPath: path, isDirectory: false),
            externalSubtitleURLs: workload.base == "metadata-name"
                ? subtitlePayload(index: index, expanded: true) : [],
            dateAdded: date
        )
    }
    if workload.base == "dates-missing" {
        // FolderPlaylist.init establishes ascending natural-name order before
        // a subsequent explicit date sort. Keep this input ascending for both
        // requested directions, and perform preparation outside all timing.
        return Fixture(items.sorted {
            NaturalFilenameOrdering.areInIncreasingOrder($0.url, $1.url)
        })
    }
    return Fixture(items)
}

// Codable restoration can bypass FolderPlaylistItem's normalizing initializer.
// These records deliberately retain raw URL spelling, authorities, dot segments,
// and canonical variants so name-mode ID ties cannot be confused with date-mode
// literal-path ties. Encoding/decoding is fixture preparation only.
private struct RawItem: Codable {
    let url: URL
    let externalSubtitleURLs: [URL]
    let dateAdded: Date?
}

private func rawItem(url: URL, ordinal: Int, date: Date?) -> FolderPlaylistItem {
    let payload = RawItem(url: url, externalSubtitleURLs: subtitlePayload(index: ordinal, expanded: false),
                          dateAdded: date)
    let data = try! JSONEncoder().encode(payload)
    return try! JSONDecoder().decode(FolderPlaylistItem.self, from: data)
}

private func adversarial(seed: UInt64?) -> Fixture {
    let rawURLs = [
        "file:///fixtures/Episode%202.mkv", "file:///fixtures/Episode%2010.mkv",
        "file:///fixtures/episode%202.mkv", "file:///fixtures/Episode%2002.mkv",
        "file:///fixtures/A/Equal.mkv", "file:///fixtures/B/Equal.mkv",
        "file:///fixtures/Collection%202/Equal.mkv", "file:///fixtures/Collection%2010/Equal.mkv",
        "file:///fixtures/caf%C3%A9/Equal.mkv", "file:///fixtures/cafe%CC%81/Equal.mkv",
        "file:///fixtures/Folder/../Same.mkv", "file:///fixtures/Same.mkv",
        "file://localhost/fixtures/Same.mkv", "file:///fixtures/./Same.mkv",
        "file:///fixtures/Same.mkv", "file:///fixtures/Same.mkv",
        "file:///fixtures/encoded%20space.mkv", "file:///fixtures/encoded%2520space.mkv",
        "file:///fixtures/encoded%23hash.mkv", "file:///fixtures/encoded%2Fslash.mkv",
        "file:///fixtures/E%CC%81pisode%202.mkv", "file:///fixtures/%C3%89pisode%202.mkv",
        "file:///fixtures/%E7%8C%AB%202.mkv", "file:///fixtures/%E7%8C%AB%2010.mkv",
        "https://example.invalid/fixtures/Equal.mkv?version=2",
        "https://example.invalid/fixtures/Equal.mkv?version=1",
        "https://example.invalid/fixtures/Equal.mkv#fragment",
        "https://example.invalid/fixtures/Equal.mkv",
    ]
    var items = rawURLs.enumerated().map { index, text in
        let date = (8...15).contains(index) || index >= 24
            ? Date(timeIntervalSince1970: 100)
            : index.isMultiple(of: 3) ? nil : Date(timeIntervalSince1970: Double(index % 4) - 2)
        return rawItem(url: URL(string: text)!, ordinal: index, date: date)
    }
    if let seed { items = shuffled(items, seed: seed) }
    return Fixture(items)
}

private func duplicateURLs() -> Fixture {
    let url = URL(fileURLWithPath: "/fixtures/Same.mkv", isDirectory: false)
    return Fixture((0..<129).reversed().map { index in
        FolderPlaylistItem(url: url, externalSubtitleURLs: subtitlePayload(index: index, expanded: true),
                           dateAdded: Date(timeIntervalSince1970: 100))
    })
}

private func checksum(_ ordinals: [Int]) -> String {
    let hash = ordinals.reduce(UInt64(14_695_981_039_346_656_037)) {
        ($0 ^ UInt64($1)) &* 1_099_511_628_211
    }
    return String(hash, radix: 16)
}

private func verifiedOrdinals(_ input: Fixture, order: PlaylistSortOrder, ascending: Bool) -> [Int] {
    let output = PlaylistMutation.sorted(input.items, by: order, ascending: ascending)
    let ordinals = output.map { input.ordinal(of: $0) }
    precondition(output.count == input.items.count && Set(ordinals).count == input.items.count)
    for (item, index) in zip(output, ordinals) {
        let original = input.items[index]
        precondition(item == original, "Sorter changed an item payload")
        // Foundation URL equality and Swift String equality may treat distinct
        // representations as equivalent. Also check their exact serialized text.
        precondition(item.url.absoluteString.utf8.elementsEqual(original.url.absoluteString.utf8),
                     "Sorter changed the media URL text")
        precondition(item.externalSubtitleURLs.count == original.externalSubtitleURLs.count)
        for (left, right) in zip(item.externalSubtitleURLs, original.externalSubtitleURLs) {
            precondition(left.absoluteString.utf8.elementsEqual(right.absoluteString.utf8),
                         "Sorter changed subtitle URL text or ordering")
        }
    }
    return ordinals
}

private func verify() -> [String: Any] {
    let ordinary = Workload("name-random-asc")!
    var cases: [(String, Fixture)] = [
        ("empty", Fixture([])), ("singleton", fixture(size: 1, workload: ordinary)),
    ]
    for size in [2, 31, 129] {
        for base in workloadBases {
            cases.append(("\(base)-\(size)", fixture(size: size, workload: Workload(base + "-asc")!)))
        }
    }
    cases.append(("adversarial", adversarial(seed: nil)))
    cases.append(("adversarial-shuffled", adversarial(seed: 0x12345678)))
    cases.append(("adversarial-second-seed", adversarial(seed: UInt64.max)))
    cases.append(("complete-ties-with-subtitle-payload", duplicateURLs()))
    var receipts: [[String: Any]] = []
    for (label, input) in cases {
        for order in PlaylistSortOrder.allCases {
            for ascending in [true, false] {
                let ordinals = verifiedOrdinals(input, order: order, ascending: ascending)
                receipts.append(["case": label, "order": order.rawValue, "ascending": ascending,
                                 "count": input.items.count, "ordinals": ordinals,
                                 "checksum": checksum(ordinals)])
            }
        }
    }
    return ["schema_version": 1, "mode": "verify", "cases": cases.count,
            "sorts": receipts.count, "metadata_preserved": true,
            "exact_url_text_preserved": true, "receipts": receipts]
}

@inline(never)
private func sortOnce(_ input: [FolderPlaylistItem], order: PlaylistSortOrder, ascending: Bool) -> [FolderPlaylistItem] {
    PlaylistMutation.sorted(input, by: order, ascending: ascending)
}

// Timing includes complete sorts, returned-array destruction, and the same two
// endpoint URL-map lookups/checksum operations in each revision. Identity maps
// are constructed before warmup. The consumer never reads item.id or performs
// URL normalization, filename extraction, or a full-array verification in this
// measured loop; any such work in sorted() remains part of the production cost.
@inline(never)
private func sortBatch(_ fixture: Fixture, workload: Workload, iterations: Int) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for _ in 0..<iterations {
        let result = sortOnce(fixture.items, order: workload.order, ascending: workload.ascending)
        hash = (hash ^ UInt64(result.count)) &* 1_099_511_628_211
        if let first = result.first, let last = result.last {
            hash = (hash ^ UInt64(fixture.ordinal(of: first))) &* 1_099_511_628_211
            hash = (hash ^ UInt64(fixture.ordinal(of: last))) &* 1_099_511_628_211
        }
    }
    return hash
}

@main
private struct PlaylistSortHarness {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["verify"] { emit(verify()); return }
        if args.count == 3, args[0] == "verify-fixture", let size = Int(args[1]),
           (0...100_000).contains(size), let workload = Workload(args[2]) {
            let input = fixture(size: size, workload: workload)
            let ordinals = verifiedOrdinals(input, order: workload.order, ascending: workload.ascending)
            emit(["schema_version": 1, "mode": "verify-fixture", "size": size,
                  "workload": workload.name, "order": workload.order.rawValue,
                  "ascending": workload.ascending, "ordinals": ordinals,
                  "metadata_preserved": true, "exact_url_text_preserved": true])
            return
        }
        guard args.count == 4, args[0] == "bench", let size = Int(args[1]),
              (0...100_000).contains(size), let workload = Workload(args[2]),
              let iterations = Int(args[3]), (1...1_000_000).contains(iterations) else {
            FileHandle.standardError.write(Data(
                "Expected verify, verify-fixture <size> <workload>, or bench <size> <workload> <iterations>\n".utf8))
            exit(2)
        }
        let input = fixture(size: size, workload: workload)
        let warmup = sortBatch(input, workload: workload, iterations: 2)
        let start = DispatchTime.now().uptimeNanoseconds
        let hash = sortBatch(input, workload: workload, iterations: iterations)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        emit(["schema_version": 1, "mode": "bench", "size": size, "workload": workload.name,
              "order": workload.order.rawValue, "ascending": workload.ascending,
              "iterations": iterations, "elapsed_ns": elapsed,
              "checksum": String(hash, radix: 16), "warmup_checksum": String(warmup, radix: 16)])
    }

    private static func emit(_ object: [String: Any]) {
        var receipt = object
        receipt["locale"] = Locale.current.identifier
        receipt["item_stride"] = MemoryLayout<FolderPlaylistItem>.stride
        receipt["enumerated_item_stride"] = MemoryLayout<(Int, FolderPlaylistItem)>.stride
        receipt["index_stride"] = MemoryLayout<Int>.stride
        let data = try! JSONSerialization.data(withJSONObject: receipt, options: .sortedKeys)
        print(String(decoding: data, as: UTF8.self))
    }
}
