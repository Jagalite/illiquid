import Foundation
@testable import IlliquidApp

private struct Generator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private struct Scenario {
    let name: String
    let count: Int
    let configuration: SourceTreeSortConfiguration
    var layout = "shuffled"
}

private let nameOrder = SourceTreeSortConfiguration(
    name: .ascending, dateCreated: .off, type: .off
)

private func scenarios() -> [Scenario] {
    var result = [0, 1, 8, 32, 128, 1_000, 10_000].map {
        Scenario(name: "name-\($0)", count: $0, configuration: nameOrder)
    }
    result += [
        Scenario(name: "name-sorted-10000", count: 10_000,
                 configuration: nameOrder, layout: "sorted"),
        Scenario(name: "name-reversed-10000", count: 10_000,
                 configuration: nameOrder, layout: "reversed"),
        Scenario(name: "equal-basenames-1000", count: 1_000,
                 configuration: nameOrder, layout: "equal-basenames"),
        Scenario(name: "duplicate-urls-1000", count: 1_000,
                 configuration: nameOrder, layout: "duplicate-urls"),
        Scenario(name: "type-name-10000", count: 10_000,
                 configuration: .init(name: .ascending, dateCreated: .off, type: .ascending)),
        Scenario(name: "metadata-name-1000", count: 1_000,
                 configuration: nameOrder, layout: "metadata"),
        Scenario(name: "long-name-1000", count: 1_000,
                 configuration: nameOrder, layout: "long-names"),
        Scenario(name: "unique-date-name-10000", count: 10_000,
                 configuration: .init(name: .ascending, dateCreated: .descending, type: .off),
                 layout: "unique-dates"),
        Scenario(name: "tied-date-name-10000", count: 10_000,
                 configuration: .init(name: .ascending, dateCreated: .descending, type: .off)),
        Scenario(name: "type-date-name-10000", count: 10_000,
                 configuration: .init(name: .descending, dateCreated: .ascending, type: .descending)),
        Scenario(name: "date-only-10000", count: 10_000,
                 configuration: .init(name: .off, dateCreated: .descending, type: .off),
                 layout: "unique-dates"),
        Scenario(name: "type-only-10000", count: 10_000,
                 configuration: .init(name: .off, dateCreated: .off, type: .ascending)),
        Scenario(name: "off-8", count: 8,
                 configuration: .init(name: .off, dateCreated: .off, type: .off)),
        Scenario(name: "off-10000", count: 10_000,
                 configuration: .init(name: .off, dateCreated: .off, type: .off)),
    ]
    return result
}

private func entries(count: Int, layout: String, seed: UInt64) -> [SourceTreeEntry] {
    var random = Generator(state: seed)
    let names = [
        "Episode", "Épisode", "映画", "Show & Extras", "café", "cafe\u{301}",
        "EPISODE", "Episode 02", "100% Complete", "A #1", "😀 video",
    ]
    var values = (0..<count).map { index in
        let name = names[index % names.count] + " \(index % 137).mkv"
        let url: URL
        switch layout {
        case "equal-basenames":
            url = URL(fileURLWithPath: "/media/season-\(index)/Episode 2.mkv")
        case "duplicate-urls":
            url = URL(fileURLWithPath: "/media/Episode \(index % 4).mkv")
        case "long-names":
            url = URL(fileURLWithPath: "/media/Shows/A Very Long Series Name (2025)/Season 01/"
                + "A Very Long Series Name (2025) - S01E\(index % 137) - \(name)"
                + " [1080p BluRay HEVC 10bit Multi-Audio DTS-HD MA 5.1].mkv")
        default:
            url = URL(fileURLWithPath: "/media/library/season-\(index % 17)/\(name)")
        }
        var entry = SourceTreeEntry(
            url: url, kind: index % 7 == 0 ? .folder : .media,
            dateAdded: Date(timeIntervalSince1970: Double(index)),
            creationDate: layout == "unique-dates"
                ? Date(timeIntervalSince1970: Double(index))
                : (index % 11 == 0 ? nil : Date(timeIntervalSince1970: Double(index % 5))),
            visibilityPath: "payload-\(index)"
        )
        if layout == "metadata" {
            entry.recognizedMedia = RecognizedMediaName(
                kind: .episode, title: "Series \(index % 31)", year: 2025,
                season: index % 8, episode: index % 137, lastEpisode: nil, airDate: nil,
                episodeTitle: "Episode title \(index)", edition: "Extended",
                catalogIDs: ["tvdb-\(index)", "imdb-tt\(index)"],
                variant: "1080p HEVC 10-bit", metadataSources: [".nfo", "filename"]
            )
        }
        return entry
    }
    if values.count > 1 {
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            values.swapAt(index, Int(random.next() % UInt64(index + 1)))
        }
    }
    if layout == "sorted" || layout == "reversed" {
        // Input preparation is outside all timing intervals.
        values.sort {
            let names = $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
            if names != .orderedSame { return names == .orderedAscending }
            return $0.url.path.compare($1.url.path, options: [.literal]) == .orderedAscending
        }
        if layout == "reversed" { values.reverse() }
    }
    return values
}

private func identities(_ sorted: [SourceTreeEntry], input: [SourceTreeEntry]) -> [Int] {
    let originals = Dictionary(uniqueKeysWithValues: input.map {
        (Int($0.dateAdded!.timeIntervalSince1970), $0)
    })
    precondition(sorted.count == input.count)
    let ids = sorted.map { value -> Int in
        let id = Int(value.dateAdded!.timeIntervalSince1970)
        precondition(originals[id] == value, "Sorting changed an entry payload")
        return id
    }
    precondition(Set(ids).count == input.count, "Sorting dropped or duplicated entries")
    return ids
}

private func output(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

@main
private struct Harness {
    static func main() throws {
        let arguments = CommandLine.arguments
        switch arguments[1] {
        case "environment":
            try output([
                "foundation_locale": Locale.current.identifier,
                "source_tree_entry_stride": MemoryLayout<SourceTreeEntry>.stride,
                "integer_stride": MemoryLayout<Int>.stride,
            ])
        case "list":
            try output(scenarios().map { ["name": $0.name, "count": $0.count] as [String: Any] })
        case "verify":
            var caseNumber = 0
            for count in [0, 1, 2, 8, 32, 129] {
                for layout in ["shuffled", "sorted", "reversed", "equal-basenames", "duplicate-urls",
                               "unique-dates", "metadata", "long-names"] {
                    for seed in 1...4 {
                        let input = entries(count: count, layout: layout, seed: UInt64(seed))
                        for name in SourceTreeSortDirection.allCases {
                            for date in SourceTreeSortDirection.allCases {
                                for type in SourceTreeSortDirection.allCases {
                                    let sorted = SourceTreeSorting.sorted(
                                        input, using: .init(name: name, dateCreated: date, type: type)
                                    )
                                    try output(["case": caseNumber, "ids": identities(sorted, input: input)])
                                    caseNumber += 1
                                }
                            }
                        }
                    }
                }
            }
            // Include every exact timed dataset in the full-output comparison.
            for scenario in scenarios() {
                let input = entries(count: scenario.count, layout: scenario.layout, seed: 4729)
                let sorted = SourceTreeSorting.sorted(input, using: scenario.configuration)
                try output(["case": caseNumber, "ids": identities(sorted, input: input)])
                caseNumber += 1
            }
        case "sample":
            let scenario = scenarios().first { $0.name == arguments[2] }!
            let iterations = Int(arguments[3])!
            precondition(iterations > 0)
            let input = entries(count: scenario.count, layout: scenario.layout, seed: 4729)
            _ = SourceTreeSorting.sorted(input, using: scenario.configuration)
            var checksum = 0
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations {
                let sorted = SourceTreeSorting.sorted(input, using: scenario.configuration)
                // The sorter is in a separately optimized module. Consume the
                // returned value without adding a second O(n) pass to each sort.
                checksum &+= sorted.count
                checksum &+= Int(sorted.first?.dateAdded?.timeIntervalSince1970 ?? 0)
                checksum &+= Int(sorted.last?.dateAdded?.timeIntervalSince1970 ?? 0)
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            try output([
                "scenario": scenario.name, "count": scenario.count,
                "iterations": iterations, "elapsed_ns": elapsed, "checksum": checksum,
            ])
        default:
            preconditionFailure("Expected list, verify, or sample")
        }
    }
}
